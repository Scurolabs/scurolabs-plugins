--!nonstrict
-- Owns durable Radio Tellus state and publishes bounded snapshots to entries.

local shared = require("./modules/shared.luau")
local protocol = require("./modules/library-protocol.luau")
local profiling = require("./modules/profiling.luau")

local state = nil
local loaded = false
local loading = false
local dirty = false
local writeDue = 0
local retryMs = 0
local retryCount = 0
local loadRetryDue = 0
local loadRetryCount = 0
local persistenceError = ""
local processing = { panel = {}, playback = {} }
local processedOrder = { panel = {}, playback = {} }
local pending = { panel = {}, playback = {} }
local acknowledgements = { panel = "", playback = "" }
local liveVolume, liveMuted
local suppressLive = true
local revision = 0
local contentRevision = 0

local STATION_FIELDS = {
    "uuid", "name", "url_resolved", "country", "country_code", "tags",
    "votes", "latitude", "longitude",
}

local function nowMs()
    return math.floor(noctalia.nowMs())
end

local function logLibrary(event, details)
    local safeEvent = shared.singleLine(event, 48)
    if safeEvent == "" then safeEvent = "unknown" end
    local message = "radio-tellus library event=" .. safeEvent
    local safeDetails = shared.singleLine(details, 320)
    if safeDetails ~= "" then message = message .. " " .. safeDetails end
    noctalia.log(message)
end

local function libraryValue()
    local value = state or {
        favorites = {}, recent = {}, volume = shared.DEFAULT_VOLUME,
        volume_set = false, muted = false,
    }
    return value
end

local function stationChanged(left, right)
    for _, field in ipairs(STATION_FIELDS) do
        if left[field] ~= right[field] then return true end
    end
    return false
end

local function publishData()
    profiling.count("library_data_publications")
    local value = libraryValue()
    noctalia.state.set(protocol.DATA_KEY, {
        ready = loaded,
        content_revision = tostring(contentRevision),
        favorites = value.favorites,
        recent = value.recent,
    })
end

local function publishSnapshot(errorMessage, includeData)
    profiling.count("library_status_publications")
    local publishedError = errorMessage ~= nil and tostring(errorMessage) or persistenceError
    local value = libraryValue()
    if includeData ~= false then
        publishData()
        noctalia.state.set(protocol.SNAPSHOT_KEY, {
            ready = loaded,
            dirty = dirty,
            error = publishedError,
            revision = tostring(revision),
            content_revision = tostring(contentRevision),
            favorites = value.favorites,
            recent = value.recent,
            volume = value.volume,
            volume_set = value.volume_set == true,
            muted = value.muted == true,
        })
    end
    noctalia.state.set(protocol.STATUS_KEY, {
        ready = loaded,
        dirty = dirty,
        error = publishedError,
        revision = tostring(revision),
        content_revision = tostring(contentRevision),
    })
    noctalia.state.set(protocol.READY_KEY, loaded and true or false)
end

local function markDirty(delayMs, publish)
    if not loaded or state == nil then return false end
    dirty = true
    writeDue = nowMs() + math.max(0, tonumber(delayMs) or 0)
    retryMs = 0
    if publish ~= false then publishSnapshot() end
    noctalia.setUpdateInterval(50)
    return true
end

local function rememberProcessed(source, id)
    processing[source][id] = true
    table.insert(processedOrder[source], id)
    while #processedOrder[source] > protocol.MAX_TRACKED_EVENT_IDS do
        local oldest = table.remove(processedOrder[source], 1)
        processing[source][oldest] = nil
    end
end

local function applyFavorite(value, desiredFavorite)
    local clean = shared.sanitizeStation(value)
    if clean == nil then return false, "This station cannot be saved." end
    local index = shared.isFavorite(state.favorites, clean)
    local isFavorite = index ~= nil
    if isFavorite == desiredFavorite then
        if desiredFavorite and stationChanged(state.favorites[index], clean) then
            state.favorites[index] = clean
            return true, nil, true
        end
        return true, nil, false
    end
    if desiredFavorite then
        table.insert(state.favorites, 1, clean)
        if #state.favorites > shared.MAX_FAVORITES then table.remove(state.favorites) end
    else
        table.remove(state.favorites, index)
    end
    return true, nil, true
end

local function applyFavoriteMove(value, targetPosition)
    local clean = shared.sanitizeStation(value)
    if clean == nil then return false, "This station cannot be reordered." end
    if type(targetPosition) ~= "number" or targetPosition ~= targetPosition
        or targetPosition == math.huge or targetPosition == -math.huge then
        return false, "The favorite position is invalid."
    end
    local target = math.floor(targetPosition)
    if target ~= targetPosition or target < 1 or target > #state.favorites then
        return false, "The favorite position is outside the saved list."
    end
    local current = shared.isFavorite(state.favorites, clean)
    if current == nil then return false, "This station is no longer a favorite." end
    if current == target then return true, nil, false end
    table.remove(state.favorites, current)
    table.insert(state.favorites, target, clean)
    return true, nil, true
end

local function applyRecent(value)
    local clean = shared.sanitizeStation(value)
    if clean == nil then return false, "This station cannot be saved." end
    local limit = shared.historyLimit()
    if limit == 0 then return true, nil, false end
    local key = shared.stationKey(clean)
    local nextRecent = { clean }
    for _, recent in ipairs(state.recent) do
        if shared.stationKey(recent) ~= key and #nextRecent < limit then table.insert(nextRecent, recent) end
    end
    local changed = #nextRecent ~= #state.recent
    if not changed then
        for index, recent in ipairs(nextRecent) do
            if stationChanged(recent, state.recent[index]) then changed = true; break end
        end
    end
    state.recent = nextRecent
    return true, nil, changed
end

local function eventList(source)
    return source == "playback" and noctalia.state.get(protocol.PLAYBACK_EVENTS_KEY)
        or noctalia.state.get(protocol.PANEL_EVENTS_KEY)
end

local function processEvents(source)
    if not loaded or type(state) ~= "table" then return end
    local events = eventList(source)
    if type(events) ~= "table" then return end
    local acknowledged = acknowledgements[source]
    local afterAck = acknowledged == ""
    if not afterAck then
        local acknowledgedInList = false
        for _, event in ipairs(events) do
            if type(event) == "table" and tostring(event.id or "") == acknowledged then
                acknowledgedInList = true
                break
            end
        end
        afterAck = not acknowledgedInList
    end
    for _, event in ipairs(events) do
        local id = tostring(type(event) == "table" and event.id or "")
        if id == acknowledged then afterAck = true
        elseif afterAck and id ~= "" and not processing[source][id] then
            local ok, err
            local changed
            if event.action == "favorite_on" then
                ok, err, changed = applyFavorite(event.station, true)
            elseif event.action == "favorite_off" then
                ok, err, changed = applyFavorite(event.station, false)
            elseif event.action == "favorite_move" then
                ok, err, changed = applyFavoriteMove(event.station, event.position)
            elseif event.action == "record_recent" then ok, err, changed = applyRecent(event.station)
            else ok, err = false, "Unknown library action." end
            local includeStationName = event.action ~= "record_recent"
            local stationName = includeStationName and type(event.station) == "table"
                and shared.singleLine(event.station.name, 96) or ""
            local mutationDetails = "source=" .. shared.singleLine(source, 16)
                .. " id=" .. shared.singleLine(id, 96)
                .. " action=" .. shared.singleLine(event.action, 48)
                .. " ok=" .. tostring(ok == true)
                .. " changed=" .. tostring(changed == true)
            if stationName ~= "" then mutationDetails = mutationDetails .. " station=" .. stationName end
            if event.position ~= nil then mutationDetails = mutationDetails .. " position=" .. tostring(event.position) end
            if err ~= nil then mutationDetails = mutationDetails .. " error=" .. tostring(err) end
            logLibrary("mutation", mutationDetails)
            rememberProcessed(source, id)
            pending[source][#pending[source] + 1] = { id = id, action = event.action, ok = ok, error = err }
            if changed then contentRevision += 1 end
            if not ok and (changed or dirty) then
                noctalia.state.set(protocol.RESULT_KEY, {
                    source = source, request_id = id, ok = false, error = err or "Library mutation rejected.",
                    revision = tostring(revision),
                })
            end
            if changed or dirty then
                markDirty(50, false)
                publishSnapshot(nil, changed == true)
            else
                noctalia.state.set(protocol.RESULT_KEY, {
                    source = source, request_id = id, ok = ok == true,
                    action = event.action, error = err, revision = tostring(revision),
                })
                acknowledgements[source] = id
                local eventKey = source == "playback"
                    and protocol.PLAYBACK_EVENTS_KEY or protocol.PANEL_EVENTS_KEY
                noctalia.state.set(source == "playback" and protocol.PLAYBACK_ACK_KEY or protocol.PANEL_ACK_KEY, id)
                protocol.compactEvents(eventKey, id)
                pending[source][#pending[source]] = nil
            end
        end
    end
end

local function applyLiveValues()
    if not loaded or state == nil then return end
    local changed = false
    if liveVolume ~= nil then
        local value = shared.clampInteger(liveVolume, state.volume, 0, 100)
        if state.volume ~= value or state.volume_set ~= true then
            state.volume, state.volume_set, changed = value, true, true
        end
    end
    if liveMuted ~= nil then
        local value = liveMuted == true
        if state.muted ~= value then state.muted, changed = value, true end
    end
    if changed then
        markDirty(150, false)
        publishSnapshot(nil, false)
    end
end

local function finishWrite(ok)
    if not ok then
        retryCount += 1
        retryMs = math.min(30000, 1000 * (2 ^ math.min(retryCount - 1, 5)))
        writeDue = nowMs() + retryMs
        logLibrary("persist_failed", "retry_ms=" .. tostring(retryMs))
        persistenceError = "Radio Tellus settings could not be saved. Retrying."
        publishSnapshot(nil, false)
        return
    end
    retryCount = 0
    retryMs = 0
    persistenceError = ""
    dirty = false
    revision += 1
    local persistedEvents = 0
    for _, values in pairs(pending) do persistedEvents += #values end
    logLibrary("persisted", "revision=" .. tostring(revision) .. " events=" .. tostring(persistedEvents))
    publishSnapshot(nil, false)
    for source, values in pairs(pending) do
        local lastId = ""
        for _, value in ipairs(values) do
            lastId = value.id
            noctalia.state.set(protocol.RESULT_KEY, {
                source = source, request_id = value.id, ok = value.ok == true,
                action = value.action, error = value.error,
                revision = tostring(revision),
            })
        end
        if lastId ~= "" then
            acknowledgements[source] = lastId
            noctalia.state.set(source == "playback" and protocol.PLAYBACK_ACK_KEY or protocol.PANEL_ACK_KEY, lastId)
            local eventKey = source == "playback"
                and protocol.PLAYBACK_EVENTS_KEY or protocol.PANEL_EVENTS_KEY
            protocol.compactEvents(eventKey, lastId)
        end
        pending[source] = {}
    end
    noctalia.setUpdateInterval(60000)
end

local function writePending()
    if not dirty or state == nil then return end
    local ok = shared.saveStateValidated(state)
    finishWrite(ok)
end

local function finishLoad(snapshot, err, needsPrune)
    loading = false
    if err ~= nil then
        loaded = false
        state = nil
        dirty = false
        retryMs = 0
        loadRetryCount += 1
        local delay = math.min(30000, 1000 * (2 ^ math.min(loadRetryCount - 1, 5)))
        loadRetryDue = nowMs() + delay
        logLibrary("load_failed", "retry_ms=" .. tostring(delay) .. " error=" .. tostring(err))
        publishSnapshot(err, false)
        noctalia.setUpdateInterval(delay)
        return
    end
    loadRetryCount = 0
    loadRetryDue = 0
    state = snapshot or {
        favorites = {}, recent = {}, volume = shared.DEFAULT_VOLUME,
        volume_set = false, muted = false,
    }
    loaded = true
    revision = 1
    contentRevision = 1
    if noctalia.state.get("player_volume") == nil then
        noctalia.state.set("player_volume", state.volume_set == true and state.volume or shared.DEFAULT_VOLUME)
    end
    if noctalia.state.get("player_muted") == nil then
        noctalia.state.set("player_muted", state.muted == true)
    end
    suppressLive = false
    acknowledgements.panel = tostring(noctalia.state.get(protocol.PANEL_ACK_KEY) or "")
    acknowledgements.playback = tostring(noctalia.state.get(protocol.PLAYBACK_ACK_KEY) or "")
    if needsPrune == true then
        contentRevision += 1
        markDirty(0, false)
    end
    logLibrary("loaded", "favorites=" .. tostring(#state.favorites)
        .. " recent=" .. tostring(#state.recent)
        .. " normalized=" .. tostring(needsPrune == true)
        .. (err ~= nil and " error=" .. tostring(err) or ""))
    applyLiveValues()
    publishSnapshot(err, true)
    processEvents("panel")
    processEvents("playback")
    if not dirty then noctalia.setUpdateInterval(60000) end
end

local function loadState()
    if loading then return end
    loading = true
    publishSnapshot("Loading Radio Tellus settings.")
    local completed = false
    local function complete(snapshot, err, needsPrune)
        if completed then return end
        completed = true
        finishLoad(snapshot, err, needsPrune)
    end
    local accepted = shared.loadStateAsync(complete)
    if not accepted and not completed then
        complete(nil, "Saved Radio Tellus settings could not be loaded.")
    end
end

noctalia.state.watch(protocol.PANEL_EVENTS_KEY, function() processEvents("panel") end)
noctalia.state.watch(protocol.PLAYBACK_EVENTS_KEY, function() processEvents("playback") end)
noctalia.state.watch(protocol.PANEL_ACK_KEY, function(value) acknowledgements.panel = tostring(value or "") end)
noctalia.state.watch(protocol.PLAYBACK_ACK_KEY, function(value) acknowledgements.playback = tostring(value or "") end)
noctalia.state.watch("player_volume", function(value)
    liveVolume = value
    if suppressLive then return end
    applyLiveValues()
end)
noctalia.state.watch("player_muted", function(value)
    liveMuted = value == true
    if suppressLive then return end
    applyLiveValues()
end)

loadState()

function update()
    if not loaded then
        if not loading and nowMs() >= loadRetryDue then loadState() end
        return
    end
    processEvents("panel")
    processEvents("playback")
    if dirty and nowMs() >= writeDue then writePending() end
    if dirty then noctalia.setUpdateInterval(math.max(50, math.min(1000, writeDue - nowMs())))
    else noctalia.setUpdateInterval(60000) end
end

function onConfigChanged()
    if not loaded or state == nil then return end
    local historyLimit = shared.historyLimit()
    if #state.recent > historyLimit then
        state.recent = shared.sanitizeStations(state.recent, historyLimit)
        contentRevision += 1
        markDirty(0, false)
        publishSnapshot(nil, true)
    else
        publishSnapshot(nil, false)
    end
end

function onExit()
    if dirty then writePending() end
end

return {
    update = update,
    onConfigChanged = onConfigChanged,
    onExit = onExit,
}
