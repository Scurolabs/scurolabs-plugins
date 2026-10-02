--!nonstrict
-- Shared persistence and playback helpers used by each Noctalia entry.
-- Entries run in separate VMs, so files persist durable radio state and
-- noctalia.state carries live playback state.

local station = require("./station-utils.luau")
local uiText = require("./ui.luau")
local storage = require("./storage-utils.luau")
local numeric = require("./numeric-utils.luau")
local libraryProtocol = require("./library-protocol.luau")
local shared = {}

shared.API_BASE = "https://all.api.radio-browser.info/json"
shared.USER_AGENT = "Radio-Tellus"
shared.STATE_FILE = "state.json"
shared.DISCOVER_CACHE_FILE = "discover.json"
shared.QUEUE_FILE = "queue.json"
shared.PLAYBACK_FILE = "playback.json"
shared.PLAYBACK_OBSERVATION_FILE = "playback-observation.json"
shared.MAX_CATALOG_STATIONS = station.MAX_CATALOG_STATIONS
shared.MAX_RESPONSE_BYTES = station.MAX_RESPONSE_BYTES
shared.MAX_CONTROL_RESPONSE_BYTES = 262144
shared.MAX_NATIVE_HTTP_REQUESTS = 8
shared.nativeHttpActive = 0
shared.MAX_FAVORITES = 500
shared.MAX_PLAYBACK_QUEUE_STATIONS = shared.MAX_FAVORITES
shared.MAX_RECENT = 100
shared.DEFAULT_VOLUME = 69
shared.PAUSE_COMMAND_TIMEOUT_MS = 1800
shared.PLAYBACK_STARTING_MESSAGE = "The current station is still connecting. Stop it before choosing another station."
local STOP_SOCKET_WAIT_ATTEMPTS, STOP_SOCKET_WAIT_SECONDS = 100, 0.02
local BASH_COMMAND, SH_COMMAND = "/usr/bin/bash", "/usr/bin/sh"
local SOCAT_COMMAND, HEAD_COMMAND, SLEEP_COMMAND = "/usr/bin/socat", "/usr/bin/head", "/usr/bin/sleep"

local PAUSE_REQUEST = table.concat({
    '{"command":["cycle","pause"],"request_id":1}',
    '{"command":["get_property","pause"],"request_id":2}',
}, "\n") .. "\n"
local pauseCommandBusy, pauseEventSerial = false, 0
local pauseControlInstance = tostring(math.floor(noctalia.nowMs())) .. "-"
    .. tostring(math.random(100000, 999999))

-- Validation remains owned by station-utils. This module exposes the shared entry facade.
shared.trim = station.trim
shared.truncateCharacters = station.truncateCharacters
shared.singleLine = station.singleLine
shared.trackTitle = station.trackTitle
shared.urlEncode = station.urlEncode
shared.countryCode = station.countryCode
shared.stationKey = station.stationKey
shared.matchesSearch = station.matchesSearch
shared.radioBrowserUuid = station.radioBrowserUuid
shared.streamAllowed = station.streamAllowed
shared.streamAllowedSanitized = station.streamAllowedSanitized
shared.sanitizeStation = station.sanitizeStation
shared.sanitizeStations = station.sanitizeStations
shared.limitSanitizedStations = station.limitSanitizedStations
shared.parseStationResponse = station.parseStationResponse

shared.clampInteger = numeric.clampInteger

function shared.logPlayback(event, details)
    local safeEvent = shared.singleLine(event, 48)
    if safeEvent == "" then safeEvent = "unknown" end
    local generation = shared.singleLine(noctalia.state.get("player_generation"), 80)
    local state = shared.singleLine(noctalia.state.get("player_state"), 24)
    local message = "radio-tellus playback event=" .. safeEvent
        .. " generation=" .. (generation ~= "" and generation or "none")
        .. " state=" .. (state ~= "" and state or "unknown")
    local safeDetails = shared.singleLine(details, 320)
    if safeDetails ~= "" then message = message .. " " .. safeDetails end
    noctalia.log(message)
end

function shared.historyLimit()
    return shared.clampInteger(noctalia.getConfig("history_limit"), 30, 0, shared.MAX_RECENT)
end

function shared.httpRequest(url)
    return {
        url = url,
        method = "GET",
        headers = { "Accept: application/json", "User-Agent: " .. shared.USER_AGENT },
        follow_redirects = false,
        allow_insecure_tls = false,
    }
end

function shared.httpBounded(request, maximum, callback, oversizeMessage)
    if type(request) ~= "table" or type(callback) ~= "function" or type(noctalia.http) ~= "function" then
        return false
    end
    if shared.nativeHttpActive >= shared.MAX_NATIVE_HTTP_REQUESTS then return false end
    local limit = math.max(1, math.floor(tonumber(maximum) or shared.MAX_CONTROL_RESPONSE_BYTES))
    shared.nativeHttpActive += 1
    local nativeCompleted = false
    local function releaseNative()
        if nativeCompleted then return false end
        nativeCompleted = true
        shared.nativeHttpActive = math.max(0, shared.nativeHttpActive - 1)
        return true
    end
    local accepted = noctalia.http(request, function(response)
        if not releaseNative() then return end
        if type(response) ~= "table" then
            callback(nil, "Could not load the station directory. Check your connection and try again.")
            return
        end
        local body = type(response.body) == "string" and response.body or ""
        if #body > limit then
            callback(nil, oversizeMessage or "The response sent too much data. Try again later.")
            return
        end
        callback(response)
    end)
    if accepted ~= true then
        releaseNative()
        return false
    end
    -- Noctalia's ordinary HTTP API has no transport-cancellation handle.
    -- Callers suppress stale results while the host retains the request until
    -- its bounded native timeout or completion.
    return true
end

function shared.httpDirectory(url, callback)
    return shared.httpBounded(shared.httpRequest(url), shared.MAX_RESPONSE_BYTES, callback,
        "The station directory sent too much data. Try again later.")
end

shared.dataDir = storage.dataDir
shared.dataPath = storage.dataPath
shared.hardenDataDir = storage.hardenDataDir
shared.writeJson = storage.writeJson

local readJson = storage.readJson
local writeJson = storage.writeJson
local libraryEventSerial = 0

function shared.appendLibraryEvent(source, action, value)
    local clean = shared.sanitizeStation(value)
    if clean == nil or type(action) ~= "string" then return false end
    libraryEventSerial += 1
    local key = source == "playback" and libraryProtocol.PLAYBACK_EVENTS_KEY
        or libraryProtocol.PANEL_EVENTS_KEY
    return libraryProtocol.appendEvent(key, {
        id = libraryProtocol.nextEventId(source .. "-" .. tostring(libraryEventSerial)),
        action = action,
        station = clean,
    })
end

local function defaultState()
    return {
        favorites = {}, recent = {}, volume = shared.DEFAULT_VOLUME,
        volume_set = false, muted = false,
    }
end

local function normalizedState(raw)
    -- Normalization is pure. Callers decide whether the durable file needs
    -- rewriting so ordinary state loads do not become write operations.
    if type(raw) ~= "table" or type(raw.favorites) ~= "table" or type(raw.recent) ~= "table" then
        return nil, "Saved Radio Tellus settings are not usable. The saved file was left unchanged."
    end
    local historyLimit = shared.historyLimit()
    local volume = shared.clampInteger(raw.volume, shared.DEFAULT_VOLUME, 0, 100)
    local volumeSet = raw.volume_set == true
        or (raw.volume_set == nil and tonumber(raw.volume) ~= nil and volume ~= shared.DEFAULT_VOLUME)
    local loaded = {
        favorites = shared.sanitizeStations(raw.favorites, shared.MAX_FAVORITES),
        recent = shared.sanitizeStations(raw.recent, historyLimit),
        volume = volume,
        volume_set = volumeSet,
        muted = raw.muted == true,
    }
    local persistedRecentEntries = 0
    for _ in pairs(raw.recent) do persistedRecentEntries += 1 end
    local needsPrune = (historyLimit == 0 and next(raw.recent) ~= nil)
        or (historyLimit > 0 and persistedRecentEntries > historyLimit)
    return loaded, nil, needsPrune, historyLimit
end

function shared.loadStateAsync(callback)
    if type(callback) ~= "function" then return false end
    local function finish(raw, err)
        if err ~= nil then
            if err == "missing" then
                callback(defaultState(), nil)
                return
            end
            noctalia.log("radio-tellus: could not read saved settings: " .. tostring(err))
            callback(nil, "Saved Radio Tellus settings could not be read. The saved file was left unchanged.")
            return
        end
        if raw == nil then
            noctalia.log("radio-tellus: could not read saved settings: unreadable")
            callback(nil, "Saved Radio Tellus settings could not be read. The saved file was left unchanged.")
            return
        end
        local loaded, stateError, needsPrune = normalizedState(raw)
        if stateError then callback(nil, stateError); return end
        callback(loaded, nil, needsPrune)
    end
    local completed = false
    local function complete(raw, err)
        if completed then return end
        completed = true
        finish(raw, err)
    end
    local accepted = storage.readJsonAsync(shared.STATE_FILE, storage.MAX_BYTES, complete)
    if not accepted and not completed then
        complete(nil, "unreadable")
    end
    return accepted
end

function shared.saveStateValidated(state)
    return writeJson(shared.STATE_FILE, {
        favorites = shared.limitSanitizedStations(state.favorites, shared.MAX_FAVORITES),
        recent = shared.limitSanitizedStations(state.recent, shared.historyLimit()),
        volume = shared.clampInteger(state.volume, shared.DEFAULT_VOLUME, 0, 100),
        volume_set = state.volume_set == true,
        muted = state.muted == true,
    })
end

function shared.isFavorite(favorites, station)
    local key = shared.stationKey(station)
    for index, favorite in ipairs(favorites or {}) do
        if shared.stationKey(favorite) == key then return index end
    end
    return nil
end

function shared.reportClick(station)
    -- Reporting checks the current opt-out setting.
    if noctalia.getConfig("report_clicks") == false or type(station) ~= "table" then return false end
    local uuid = shared.radioBrowserUuid(station.uuid)
    if uuid == nil then return false end
    return shared.httpBounded(shared.httpRequest(shared.API_BASE .. "/url/" .. uuid),
        shared.MAX_CONTROL_RESPONSE_BYTES, function(_) end)
end

function shared.loadCache(name, maximum)
    local raw = readJson(name)
    local stations = type(raw) == "table" and type(raw.stations) == "table" and raw.stations or raw
    local requestedLimit
    if type(raw) == "table" and type(raw.stations) == "table" and raw.requested_limit ~= nil then
        requestedLimit = shared.clampInteger(raw.requested_limit, 0, 0, shared.MAX_CATALOG_STATIONS)
    end
    return shared.sanitizeStations(stations, maximum), requestedLimit
end

local function writeQueue(stations, index)
    return writeJson(shared.QUEUE_FILE, { stations = stations, index = index })
end

function shared.setQueueRows(rows, selected)
    local stations = {}
    for _, row in ipairs(rows or {}) do
        if #stations >= shared.MAX_PLAYBACK_QUEUE_STATIONS then break end
        if type(row) == "table" and type(row.station) == "table" then
            table.insert(stations, row.station)
        end
    end
    -- Catalog rows are created only after station-utils validation. Reusing
    -- their station payload avoids a second full validation pass at playback.
    local selectedKey, index = shared.stationKey(selected), 1
    for candidateIndex, candidate in ipairs(stations) do
        if shared.stationKey(candidate) == selectedKey then index = candidateIndex; break end
    end
    return writeQueue(stations, index)
end

function shared.setQueueValidated(stations, selected)
    local clean = shared.limitSanitizedStations(stations, shared.MAX_PLAYBACK_QUEUE_STATIONS)
    local selectedKey, index = shared.stationKey(selected), 1
    for candidateIndex, station in ipairs(clean) do
        if shared.stationKey(station) == selectedKey then index = candidateIndex; break end
    end
    return writeQueue(clean, index)
end

function shared.loadQueue()
    local raw = readJson(shared.QUEUE_FILE)
    if type(raw) ~= "table" then return {}, 0 end
    local stations = shared.sanitizeStations(raw.stations, shared.MAX_PLAYBACK_QUEUE_STATIONS)
    local index = math.max(1, math.min(#stations, numeric.floorOr(raw.index, 1)))
    return stations, index
end

local function validSocketPath(path)
    local dir = shared.dataDir()
    if type(path) ~= "string" or dir == nil then return nil end
    local escapedDir = dir:gsub("([^%w])", "%%%1")
    local name = path:match("^" .. escapedDir .. "/([^/]+)$")
    if name == "mpv.sock" or (name and name:match("^mpv%-%d+%-%d+%.sock$")) then return path end
    local generation = path:match("^" .. escapedDir .. "/run%-(%d+%-%d+)/mpv%.sock$")
    if generation then return path end
    return nil
end

local function generatedSocketGeneration(path)
    local dir = shared.dataDir()
    if type(path) ~= "string" or dir == nil then return nil end
    local escapedDir = dir:gsub("([^%w])", "%%%1")
    return path:match("^" .. escapedDir .. "/run%-(%d+%-%d+)/mpv%.sock$")
end

local function markerPathForSocket(socket)
    local runtimeDir = socket:match("^(.-/run%-%d+%-%d+)/mpv%.sock$")
    return runtimeDir and runtimeDir .. "/session.pid" or nil
end

local function pendingLaunchForCurrentState()
    local pending = noctalia.state.get("player_launch_pending")
    if type(pending) ~= "table" then return nil end
    local generation = shared.singleLine(pending.generation, 80)
    local socket = validSocketPath(pending.socket)
    local startedMs = numeric.floorOr(pending.started_ms, 0)
    if generation == "" or socket == nil or startedMs <= 0 then return nil end
    if generation ~= tostring(noctalia.state.get("player_generation") or "")
        or tostring(noctalia.state.get("player_state") or "") ~= "starting" then return nil end
    return { generation = generation, socket = socket, started_ms = startedMs }
end

function shared.sessionMarkerPath(socket)
    local valid = validSocketPath(socket)
    return valid and markerPathForSocket(valid) or nil
end

local function playbackRecord()
    local raw = readJson(shared.PLAYBACK_FILE)
    if type(raw) ~= "table" then return nil end
    local socket = validSocketPath(raw.socket)
    local generation = shared.singleLine(raw.generation, 80)
    if socket == nil or generation == "" then return nil end
    local socketGeneration = generatedSocketGeneration(socket)
    if socketGeneration ~= nil and socketGeneration ~= generation then return nil, "generation_mismatch" end
    return {
        socket = socket,
        generation = generation,
        started_ms = numeric.floorOr(raw.started_ms, 0),
        station = shared.sanitizeStation(raw.station),
        secure_session = raw.secure_session == true,
        confirmation_pending = raw.confirmation_pending == true,
        report_click = raw.report_click == true,
    }
end

local function playbackObservationRecord()
    local raw = readJson(shared.PLAYBACK_OBSERVATION_FILE)
    if type(raw) ~= "table" then return nil end
    local socket = validSocketPath(raw.socket)
    local generation = shared.singleLine(raw.generation, 80)
    local startedMs = numeric.floorOr(raw.started_ms, 0)
    if socket == nil or generation == "" or startedMs <= 0 then return nil end
    local socketGeneration = generatedSocketGeneration(socket)
    if socketGeneration ~= nil and socketGeneration ~= generation then return nil end
    return {
        socket = socket,
        generation = generation,
        started_ms = startedMs,
    }
end

function shared.notePlaybackObserved(generation)
    local record = playbackRecord()
    if record == nil or record.generation ~= tostring(generation)
        or record.secure_session ~= true or record.confirmation_pending ~= true then return false end
    local observation = playbackObservationRecord()
    if observation ~= nil and observation.socket == record.socket
        and observation.generation == record.generation
        and observation.started_ms == record.started_ms then return true end
    return shared.writeJson(shared.PLAYBACK_OBSERVATION_FILE, {
        socket = record.socket,
        generation = record.generation,
        started_ms = record.started_ms,
    })
end

function shared.recoveredPlaybackGeneration(record)
    if type(record) ~= "table" or record.secure_session ~= true
        or record.confirmation_pending ~= true then return "" end
    local observation = playbackObservationRecord()
    if observation == nil or observation.socket ~= record.socket
        or observation.generation ~= record.generation
        or observation.started_ms ~= record.started_ms then return "" end
    return record.generation
end

local function clearPlaybackObservation(generation)
    local observation = playbackObservationRecord()
    if observation == nil then return true end
    if generation ~= nil and observation.generation ~= tostring(generation) then return true end
    local path = shared.dataPath(shared.PLAYBACK_OBSERVATION_FILE)
    return path == nil or not noctalia.fileExists(path) or noctalia.removeFile(path)
end

function shared.confirmPlayback(generation)
    local record = playbackRecord()
    if record == nil or record.generation ~= tostring(generation) or record.station == nil then return false end
    if record.confirmation_pending ~= true then return true end
    -- Recording the attempt first prevents duplicate reports after reloads.
    local persisted = shared.writeJson(shared.PLAYBACK_FILE, {
        socket = record.socket,
        generation = record.generation,
        started_ms = record.started_ms,
        station = record.station,
        secure_session = true,
        confirmation_pending = false,
        report_click = record.report_click,
    })
    if not persisted then return false end
    clearPlaybackObservation(generation)
    if not shared.appendLibraryEvent("playback", "record_recent", record.station) then
        noctalia.log("radio-tellus: could not queue the recent station update")
    end
    if record.report_click then shared.reportClick(record.station) end
    return true
end

function shared.playbackConfirmed(generation)
    local record = playbackRecord()
    return record ~= nil
        and record.generation == tostring(generation)
        and record.secure_session == true
        and record.confirmation_pending ~= true
end

function shared.playbackIsActive(status, generation, observedGeneration)
    if type(status) ~= "table"
        or status.audio_ready ~= true
        or status.audio_ready_known ~= true
        or status.core_idle_known ~= true then return false end
    if status.core_idle ~= true then return true end
    return status.paused == true
        and (shared.playbackConfirmed(generation)
            or tostring(observedGeneration or "") == tostring(generation))
end

function shared.socketPath()
    local published = validSocketPath(noctalia.state.get("player_socket"))
    if published then return published end
    local record = playbackRecord()
    if record then return record.socket end
    local legacy = shared.dataPath("mpv.sock")
    return legacy and noctalia.fileExists(legacy) and legacy or nil
end

function shared.restorePlayback()
    local pendingLaunch = pendingLaunchForCurrentState()
    if pendingLaunch ~= nil then
        local pendingRecord = playbackRecord()
        if pendingRecord ~= nil and pendingRecord.generation == pendingLaunch.generation
            and shared.recoveredPlaybackGeneration(pendingRecord) ~= "" then
            -- A marker-backed recovery must get a fresh bounded validation
            -- window on every service reload. Keep the original playback
            -- start time separately for accounting and session identity.
            if numeric.floorOr(noctalia.state.get("player_started_ms"), 0) ~= pendingRecord.started_ms then
                noctalia.state.set("player_started_ms", pendingRecord.started_ms)
            end
            if validSocketPath(noctalia.state.get("player_socket")) ~= pendingRecord.socket then
                noctalia.state.set("player_socket", pendingRecord.socket)
            end
            noctalia.state.set("player_launch_pending", {
                generation = pendingLaunch.generation,
                socket = pendingRecord.socket,
                started_ms = math.floor(noctalia.nowMs()),
            })
            return pendingRecord
        end
        if numeric.floorOr(noctalia.state.get("player_started_ms"), 0) ~= pendingLaunch.started_ms then
            noctalia.state.set("player_started_ms", pendingLaunch.started_ms)
        end
        if validSocketPath(noctalia.state.get("player_socket")) ~= pendingLaunch.socket then
            noctalia.state.set("player_socket", pendingLaunch.socket)
        end
        return nil
    end
    local record, recordError = playbackRecord()
    if record == nil then
        if recordError == "generation_mismatch" then
            shared.clearPlayback(nil)
            shared.clearNowPlaying()
        end
        return nil
    end
    local socketReady = noctalia.fileExists(record.socket)
    local marker = markerPathForSocket(record.socket)
    local launchInFlight = record.confirmation_pending == true and marker ~= nil
    if not socketReady and (marker == nil or not noctalia.fileExists(marker))
        and not launchInFlight then
        -- A detached teardown may finish after this service VM exits. Confirmed
        -- records are removed only when their socket and session marker are gone.
        shared.clearPlayback(nil)
        shared.clearNowPlaying()
        return nil
    end
    noctalia.state.set("player_generation", record.generation)
    noctalia.state.set("player_started_ms", record.started_ms)
    -- The in-memory state cannot prove that a recovered MPV socket is already
    -- producing audio. Let player-status establish the state from MPV before
    -- controls or scrobbling treat the recovered stream as active.
    noctalia.state.set("player_state", "starting")
    noctalia.state.set("track_title", "")
    noctalia.state.set("audio_ready", false)
    noctalia.state.set("playback_isolation", "")
    if record.confirmation_pending == true and record.started_ms > 0 then
        local pendingStartedMs = record.started_ms
        if shared.recoveredPlaybackGeneration(record) ~= "" then
            -- A previously observed session is not confirmed by this marker
            -- alone. It only earns a new deadline to obtain complete live MPV
            -- status and revalidate the still-running session.
            pendingStartedMs = math.floor(noctalia.nowMs())
        end
        noctalia.state.set("player_launch_pending", {
            generation = record.generation,
            socket = record.socket,
            started_ms = pendingStartedMs,
        })
    else
        noctalia.state.set("player_launch_pending", "")
    end
    noctalia.state.set("player_socket", record.socket)
    if not record.secure_session then
        -- Sessions created before the proxy requirement are not adopted.
        shared.stop()
        uiText.notify("Radio Tellus", "An older station session was stopped because it did not meet Radio Tellus safety requirements.", true)
        return nil
    end
    if record.station then
        noctalia.state.set("station", record.station)
        noctalia.state.set("station_name", record.station.name)
    end
    return record
end

local function clearLaunchPending(generation)
    local pending = noctalia.state.get("player_launch_pending")
    if type(pending) ~= "table" then return end
    if generation == nil or tostring(pending.generation or "") == tostring(generation) then
        noctalia.state.set("player_launch_pending", "")
    end
end

local function clearControlPending(generation)
    local pending = noctalia.state.get("player_control_pending")
    if type(pending) ~= "table" then return end
    if generation == nil or tostring(pending.generation or "") == tostring(generation) then
        noctalia.state.set("player_control_pending", "")
    end
end

function shared.clearPlayback(generation)
    if generation ~= nil and tostring(noctalia.state.get("player_generation") or "") ~= tostring(generation) then return end
    local record = playbackRecord()
    if generation == nil or record == nil or record.generation == tostring(generation) then
        local path = shared.dataPath(shared.PLAYBACK_FILE)
        if path and noctalia.fileExists(path) then noctalia.removeFile(path) end
    end
    clearPlaybackObservation(generation)
    clearLaunchPending(generation)
    clearControlPending(generation)
    noctalia.state.set("player_socket", "")
end

function shared.clearNowPlaying()
    noctalia.state.set("player_state", "stopped")
    noctalia.state.set("audio_ready", false)
    noctalia.state.set("station", {})
    noctalia.state.set("station_name", "")
    noctalia.state.set("track_title", "")
    noctalia.state.set("playback_isolation", "")
end

function shared.shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function shared.socketGuard(socket)
    local quoted = shared.shellQuote(socket)
    return "[ -S " .. quoted .. " ] && [ ! -L " .. quoted .. " ]"
end

local function socketCommandScript(socket, command, outputLimit, quiet, waitForClose)
    local quotedSocket = shared.shellQuote(socket)
    local script = shared.socketGuard(socket) .. " && printf %s " .. shared.shellQuote(command)
        .. " | " .. SOCAT_COMMAND .. " -T 1 - UNIX-CONNECT:" .. shared.shellQuote(socket)
    if outputLimit ~= nil then
        script = script .. " | " .. HEAD_COMMAND .. " -c " .. tostring(outputLimit)
    elseif quiet then
        script = script .. " >/dev/null 2>&1"
    end
    if waitForClose then
        script = "(" .. script .. ") && attempt=0 && while [ $attempt -lt "
            .. tostring(STOP_SOCKET_WAIT_ATTEMPTS) .. " ] && [ -e " .. quotedSocket
            .. " -o -L " .. quotedSocket .. " ]; do " .. SLEEP_COMMAND .. " "
            .. tostring(STOP_SOCKET_WAIT_SECONDS) .. "; attempt=$((attempt + 1)); done"
            .. " && [ ! -e " .. quotedSocket .. " ] && [ ! -L " .. quotedSocket .. " ]"
    end
    return script
end

local function sessionStopCommand(socket)
    local valid = validSocketPath(socket)
    local dir = shared.dataDir()
    local generation = valid and generatedSocketGeneration(valid)
    if valid == nil or dir == nil or generation == nil then return nil end
    local pluginDir = noctalia.pluginDir()
    if pluginDir == nil then return nil end
    local session = pluginDir .. "/helpers/stream-session"
    if not noctalia.fileExists(session) then return nil end
    return { session, "--stop", dir, generation }
end

local function resolveSocket(targetSocket)
    if targetSocket == false then return nil, false end
    if targetSocket ~= nil then
        local socket = validSocketPath(targetSocket)
        return socket, socket == nil
    end
    return shared.socketPath(), false
end

local function runSocketCommand(command, targetSocket, callback, timeoutMs, outputLimit, quiet, pipefail, waitForClose)
    local socket = resolveSocket(targetSocket)
    if socket == nil or not noctalia.fileExists(SOCAT_COMMAND) or not noctalia.fileExists(socket) then return false end
    local limit = outputLimit and math.max(1, math.min(65536, numeric.floorOr(outputLimit, 1))) or nil
    local script = socketCommandScript(socket, command, limit, quiet, waitForClose)
    local commandLine = pipefail and { BASH_COMMAND, "-o", "pipefail", "-c", script }
        or { SH_COMMAND, "-c", script }
    return noctalia.runAsync(commandLine, callback, timeoutMs)
end

local function pathIsAbsent(path, callback)
    if not noctalia.fileExists(SH_COMMAND) then
        callback(false)
        return false
    end
    local quoted = shared.shellQuote(path)
    local completed = false
    local function finish(absent)
        if completed then return end
        completed = true
        callback(absent)
    end
    local started = noctalia.runAsync({
        SH_COMMAND, "-c", "[ ! -e " .. quoted .. " ] && [ ! -L " .. quoted .. " ]",
    }, function(result)
        local absent = type(result) == "table"
            and result.timedOut ~= true
            and numeric.floorOr(result.exitCode, -1) == 0
        finish(absent)
    end, 1000)
    if not started then finish(false) end
    return started
end

local function stopCommandSucceeded(result)
    return type(result) == "table"
        and result.timedOut ~= true
        and numeric.floorOr(result.exitCode, -1) == 0
end

local function verifyStopResult(socket, result, done)
    if not stopCommandSucceeded(result) then done(false); return end
    pathIsAbsent(socket, done)
end

local function parsePauseResponse(output)
    local commandSucceeded, paused
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local response = noctalia.json.decode(line)
        if type(response) == "table" and response.error == "success" then
            if response.request_id == 1 then
                commandSucceeded = true
            elseif response.request_id == 2 and type(response.data) == "boolean" then
                paused = response.data
            end
        end
    end
    if commandSucceeded and paused ~= nil then return paused end
    return nil
end

local function pauseControlStillActive(generation, socket)
    local pending = noctalia.state.get("player_control_pending")
    if type(pending) ~= "table"
        or tostring(pending.generation or "") ~= generation
        or tostring(pending.socket or "") ~= socket then return false end
    local control = noctalia.state.get("player_control_state")
    local commandId = tostring(pending.command_id or "")
    local eventId = type(control) == "table" and tostring(control.event_id or "") or ""
    if commandId ~= "" and eventId:sub(1, #commandId + 1) == commandId .. ":" then return false end
    -- The status service owns reconciliation after a lost or timed-out
    -- callback, so the boundary remains a lock until it confirms MPV state.
    return true
end

function shared.socketCommand(command, targetSocket)
    return runSocketCommand(command, targetSocket)
end

function shared.restartPlayer(targetSocket)
    return shared.socketCommand('{"command":["quit"]}\n', targetSocket)
end

function shared.socketRequest(command, callback, timeoutMs, outputLimit, targetSocket)
    return runSocketCommand(command, targetSocket, callback, timeoutMs, outputLimit, nil, true)
end

function shared.stopDetached()
    local socket = shared.socketPath()
    local session = socket and sessionStopCommand(socket)
    if session ~= nil and noctalia.runAsync(session) then return true end
    return shared.socketCommand('{"command":["quit"]}\n')
end

function shared.stopPlayer(done, targetSocket)
    local socket, invalidTarget = resolveSocket(targetSocket)
    if invalidTarget then if done then done(false) end; return false end
    if socket == nil then if done then done(true) end; return true end
    local session = sessionStopCommand(socket)
    if session ~= nil then
        local started
        if done == nil then
            started = noctalia.runAsync(session)
        else
            started = noctalia.runAsync(session, function(result)
                verifyStopResult(socket, result, done)
            end, 5000)
        end
        if started then return true end
    end
    if done == nil then
        return runSocketCommand(
            '{"command":["quit"]}\n', socket, nil, 4000, nil, true, true, true
        )
    end
    local callback = function(result) verifyStopResult(socket, result, done) end
    local function fallbackStop()
        local started = runSocketCommand(
            '{"command":["quit"]}\n', socket, callback, 4000, nil, true, true, true
        )
        if not started then pathIsAbsent(socket, done) end
        return started
    end
    local started = pathIsAbsent(socket, function(absent)
        if absent then done(true); return end
        fallbackStop()
    end)
    return started
end

local REQUIRED_PLAYBACK_COMMANDS = {
    "bash", "chmod", "dirname", "env", "head", "ip", "mkdir", "mpv", "python3", "rm", "rmdir", "stat",
    "setpriv", "sh", "sleep", "socat",
}

local function capturePlayerState(socket)
    return {
        socket = socket,
        generation = tostring(noctalia.state.get("player_generation") or ""),
        started_ms = tonumber(noctalia.state.get("player_started_ms")) or 0,
        state = tostring(noctalia.state.get("player_state") or "stopped"),
        station = noctalia.state.get("station"),
        station_name = noctalia.state.get("station_name"),
        track_title = noctalia.state.get("track_title"),
        isolation = noctalia.state.get("playback_isolation"),
    }
end

local function restorePlayerState(snapshot)
    noctalia.state.set("player_launch_pending", "")
    noctalia.state.set("player_control_pending", "")
    noctalia.state.set("player_generation", snapshot.generation)
    noctalia.state.set("player_started_ms", snapshot.started_ms)
    noctalia.state.set("player_state", snapshot.state)
    noctalia.state.set("station", snapshot.station or {})
    noctalia.state.set("station_name", snapshot.station_name or "")
    noctalia.state.set("track_title", snapshot.track_title or "")
    noctalia.state.set("playback_isolation", snapshot.isolation or "")
    noctalia.state.set("player_socket", snapshot.socket or "")
end

local function playbackCommand(session, dir, generation, isolationMode, streamUrl, volume, muted)
    local protocols = streamUrl:match("^https://")
        and "https,tcp,tls,crypto,httpproxy" or "http,https,tcp,tls,crypto,httpproxy"
    local lavfPolicy = "protocol_whitelist=[" .. protocols .. "]"
    return {
        session, dir, generation, isolationMode, "mpv",
        "--no-config", "--load-scripts=no", "--ytdl=no", "--terminal=no",
        "--really-quiet", "--no-video", "--audio-display=no", "--force-window=no", "--idle=no",
        "--input-terminal=no", "--input-default-bindings=no", "--input-vo-keyboard=no",
        "--tls-verify=yes", "--network-timeout=15", "--load-unsafe-playlists=no",
        "--autoload-files=no", "--sub-auto=no", "--audio-file-auto=no", "--prefetch-playlist=no",
        "--cache-on-disk=no", "--cache-secs=30", "--demuxer-max-bytes=32MiB",
        "--demuxer-max-back-bytes=4MiB", "--stream-lavf-o=" .. lavfPolicy,
        "--demuxer-lavf-o=" .. lavfPolicy, "--user-agent=" .. shared.USER_AGENT,
        "--ao=pulse", "--input-ipc-server=/radio-runtime/mpv.sock",
        "--volume=" .. tostring(volume), muted and "--mute=yes" or "--mute=no", "--", streamUrl,
    }
end

function shared.play(station, volume, done)
    if tostring(noctalia.state.get("player_state") or "stopped") == "starting" then
        return false, shared.PLAYBACK_STARTING_MESSAGE
    end
    local clean, streamError = shared.streamAllowed(station)
    if clean == nil then return false, streamError end
    for _, command in ipairs(REQUIRED_PLAYBACK_COMMANDS) do
        if not noctalia.commandExists(command) then
            noctalia.log("radio-tellus: required playback command is missing: " .. command)
            return false, "Radio Tellus is missing something needed for playback. Check the plugin requirements and try again."
        end
    end
    local isolationMode = tostring(noctalia.getConfig("isolation_mode") or "auto")
    if isolationMode ~= "auto" and isolationMode ~= "full" and isolationMode ~= "compatible" then
        isolationMode = "auto"
    end
    if isolationMode == "full" and not noctalia.commandExists("bwrap") then
        return false, "Full playback protection is unavailable. Choose Automatic or Compatible in Radio settings."
    end
    local dir = shared.dataDir()
    if dir == nil then return false, "Radio Tellus could not prepare its local data. Try again." end
    local pluginDir = noctalia.pluginDir()
    if pluginDir == nil then
        noctalia.log("radio-tellus: pluginDir returned no runtime directory")
        return false, "Radio Tellus could not find its playback files. Check the plugin installation and try again."
    end
    local session = pluginDir .. "/helpers/stream-session"
    if not noctalia.fileExists(session) then return false, "Radio Tellus is missing a playback file. Reinstall the plugin and try again." end
    local chosenVolume = shared.clampInteger(volume, noctalia.state.get("player_volume"), 0, 100)
    local publishedMuted = noctalia.state.get("player_muted")
    local chosenMuted = type(publishedMuted) == "boolean" and publishedMuted or false
    local oldSocket = shared.socketPath()
    local previous = capturePlayerState(oldSocket)
    local generation = tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(math.random(100000, 999999))
    local socket = dir .. "/run-" .. generation .. "/mpv.sock"
    local startedMs = math.floor(noctalia.nowMs())
    local shouldReportClick = noctalia.getConfig("report_clicks") ~= false
    noctalia.state.set("player_generation", generation)
    noctalia.state.set("player_started_ms", startedMs)
    noctalia.state.set("player_state", "starting")
    noctalia.state.set("player_error", "")
    noctalia.state.set("audio_ready", false)
    noctalia.state.set("playback_isolation", "")
    noctalia.state.set("player_control_pending", "")
    noctalia.state.set("player_launch_pending", {
        generation = generation,
        socket = socket,
        started_ms = startedMs,
    })
    noctalia.state.set("player_socket", socket)
    shared.logPlayback("launch_requested", "isolation=" .. isolationMode)
    shared.stopPlayer(function(stopped)
        if tostring(noctalia.state.get("player_generation") or "") ~= generation then return end
        if not stopped then
            shared.logPlayback("previous_stop_failed")
            restorePlayerState(previous)
            local message = "The previous station could not be stopped, so the new station was not started. Try stopping it again."
            noctalia.state.set("player_error", message)
            if done then done(false, message) end
            return
        end
        startedMs = math.floor(noctalia.nowMs())
        noctalia.state.set("player_started_ms", startedMs)
        noctalia.state.set("player_launch_pending", {
            generation = generation,
            socket = socket,
            started_ms = startedMs,
        })
        local prepared = writeJson(shared.PLAYBACK_FILE, {
            socket = socket,
            generation = generation,
            started_ms = startedMs,
            station = clean,
            secure_session = true,
            confirmation_pending = true,
            report_click = shouldReportClick,
        })
        if not prepared then
            shared.logPlayback("launch_prepare_failed")
            shared.clearPlayback(nil)
            shared.clearNowPlaying()
            local message = "Radio Tellus could not prepare the new station. Try again."
            noctalia.state.set("player_error", message)
            if done then done(false, message) end
            return
        end
        local launchVolume = shared.clampInteger(noctalia.state.get("player_volume"), chosenVolume, 0, 100)
        -- A callback would apply the short finite-command timeout and kill the
        -- long-lived session. The monitor reports later socket and playback
        -- failures after this detached launch is accepted.
        local started = noctalia.runAsync(playbackCommand(
            session, dir, generation, isolationMode, clean.url_resolved, launchVolume, chosenMuted
        ))
        if started then
            shared.logPlayback("session_started", "isolation=" .. isolationMode)
            noctalia.state.set("station_name", clean.name)
            noctalia.state.set("station", clean)
            noctalia.state.set("track_title", "")
            noctalia.state.set("player_volume", launchVolume)
        else
            shared.logPlayback("session_launch_rejected")
            shared.clearPlayback(generation)
            shared.clearNowPlaying()
            noctalia.state.set("player_error", "The station could not start playing. Try another station.")
        end
        if done then done(started, started and nil or "The station could not start playing. Try another station.") end
    end, oldSocket or false)
    return true
end

function shared.playQueueStep(delta, done)
    if tostring(noctalia.state.get("player_state") or "stopped") == "starting" then
        return false, shared.PLAYBACK_STARTING_MESSAGE
    end
    local stations, index = shared.loadQueue()
    if #stations == 0 then return false, "There are no stations in the queue yet." end
    index = ((index - 1 + delta) % #stations) + 1
    if not writeQueue(stations, index) then return false, "Your station queue could not be saved. Try again." end
    return shared.play(stations[index], nil, done)
end

local function playableStations(stations)
    local playable = {}
    local allowInsecureHttp = noctalia.getConfig("allow_insecure_http") == true
    for _, candidate in ipairs(stations or {}) do
        if shared.streamAllowedSanitized(candidate, allowInsecureHttp) then
            table.insert(playable, candidate)
        end
    end
    return playable
end

function shared.randomStationValidated(stations)
    local pool = shared.limitSanitizedStations(stations, shared.MAX_CATALOG_STATIONS)
    if #pool == 0 then pool = shared.loadCache(shared.DISCOVER_CACHE_FILE, shared.MAX_CATALOG_STATIONS) end
    local playable = playableStations(pool)
    if #playable == 0 then return nil end
    local current, choices = shared.stationKey(noctalia.state.get("station")), {}
    for _, station in ipairs(playable) do
        if shared.stationKey(station) ~= current then
            table.insert(choices, station)
        end
    end
    if #choices == 0 then choices = playable end
    if #choices == 0 then return nil end
    return choices[math.random(1, #choices)]
end

function shared.stop()
    local socket = shared.socketPath()
    local generation = tostring(noctalia.state.get("player_generation") or "")
    shared.logPlayback("stop_requested")
    shared.stopPlayer(function(stopped)
        if tostring(noctalia.state.get("player_generation") or "") ~= generation then return end
        if stopped then
            shared.logPlayback("stop_completed")
            noctalia.state.set("player_generation", "stopped-" .. tostring(math.floor(noctalia.nowMs())))
            shared.clearNowPlaying()
            noctalia.state.set("player_error", "")
            shared.clearPlayback(nil)
        else
            shared.logPlayback("stop_failed")
            noctalia.state.set("player_error", "The station could not be stopped. Try stopping it again.")
        end
    end, socket or false)
end

function shared.togglePause(done)
    if done ~= nil and type(done) ~= "function" then return false end
    if pauseCommandBusy then
        if done then done(false) end
        return false
    end
    local socket = shared.socketPath()
    local generation = tostring(noctalia.state.get("player_generation") or "")
    local current = tostring(noctalia.state.get("player_state") or "stopped")
    if socket == nil or (current ~= "playing" and current ~= "paused") then
        if done then done(false) end
        return false
    end
    if pauseControlStillActive(generation, socket) then
        if done then done(false) end
        return false
    end

    shared.logPlayback("pause_requested", "previous=" .. current)

    pauseEventSerial += 1
    local commandStartedMs = math.floor(noctalia.nowMs())
    local commandId = table.concat({
        generation,
        pauseControlInstance,
        tostring(commandStartedMs),
        tostring(pauseEventSerial),
    }, ":")
    noctalia.state.set("player_control_pending", {
        generation = generation,
        socket = socket,
        started_ms = commandStartedMs,
        command_id = commandId,
        previous_state = current,
    })
    local function clearPendingControl()
        local pending = noctalia.state.get("player_control_pending")
        if type(pending) == "table" and tostring(pending.command_id or "") == commandId then
            noctalia.state.set("player_control_pending", "")
        end
    end

    pauseCommandBusy = true
    local accepted = shared.socketRequest(PAUSE_REQUEST, function(result)
        local currentSocket = shared.socketPath()
        local currentGeneration = tostring(noctalia.state.get("player_generation") or "")
        local pending = noctalia.state.get("player_control_pending")
        local currentCommand = type(pending) == "table"
            and tostring(pending.command_id or "") == commandId
        if socket ~= currentSocket or generation ~= currentGeneration or not currentCommand then
            pauseCommandBusy = false
            clearPendingControl()
            return
        end
        pauseCommandBusy = false
        local paused
        if type(result) == "table" and result.timedOut ~= true
            and numeric.floorOr(result.exitCode, -1) == 0 then
            paused = parsePauseResponse(result.stdout)
        end
        if paused == nil then
            local exitCode = type(result) == "table" and numeric.floorOr(result.exitCode, -1) or -1
            local timedOut = type(result) == "table" and result.timedOut == true
            shared.logPlayback("pause_failed", "exit=" .. tostring(exitCode)
                .. " timed_out=" .. tostring(timedOut))
            -- Keep the boundary until player-status confirms the resulting
            -- MPV state.
            if done then done(false) end
            return
        end
        local changedMs = math.floor(noctalia.nowMs())
        local state = paused and "paused" or "playing"
        shared.logPlayback("pause_confirmed", "state=" .. state)
        noctalia.state.set("player_state", state)
        noctalia.state.set("player_control_state", {
            generation = generation,
            socket = socket,
            player_state = state,
            changed_ms = changedMs,
            boundary_ms = commandStartedMs,
            event_id = commandId .. ":" .. tostring(changedMs),
        })
        clearPendingControl()
        if done then done(true, paused) end
    end, shared.PAUSE_COMMAND_TIMEOUT_MS, 65536, socket)
    if not accepted then
        shared.logPlayback("pause_request_rejected")
        pauseCommandBusy = false
        clearPendingControl()
        if done then done(false) end
    end
    return accepted
end

function shared.toggleMute()
    local accepted = shared.socketCommand('{"command":["cycle","mute"]}\n')
    shared.logPlayback(accepted and "mute_requested" or "mute_request_rejected")
    return accepted
end

local function normalizedVolume(value)
    return shared.clampInteger(value, shared.DEFAULT_VOLUME, 0, 100)
end

function shared.persistVolume(value)
    local volume = normalizedVolume(value)
    -- The library-state service watches this live value and coalesces the
    -- durable write outside input and render callbacks.
    noctalia.state.set("player_volume", volume)
    return true
end

function shared.setVolume(value, persist)
    local volume = normalizedVolume(value)
    if persist ~= false then shared.persistVolume(volume) end
    if persist == false then noctalia.state.set("player_volume", volume) end
    return shared.socketCommand('{"command":["set_property","volume",' .. tostring(volume) .. ']}\n')
end

return shared
