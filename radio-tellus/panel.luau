--!nonstrict
local shared = require("./modules/shared.luau")
local lastfm = require("./modules/lastfm.luau")
local catalog = require("./modules/catalog.luau")
local searchCompletion = require("./modules/search-completion.luau")
local cacheRepository = require("./modules/cache-repository.luau")
local libraryStoreModule = require("./modules/library-store.luau")
local requestManagerModule = require("./modules/request-manager.luau")
local frameSchedulerModule = require("./modules/frame-scheduler.luau")
local uiText = require("./modules/ui.luau")
local nativeUi = ui
local ui = uiText.wrap(nativeUi)

local function tr(key, substitutions)
    return uiText.tr(key, substitutions)
end

local function localizedError(value, fallback)
    local message = type(value) == "string" and value or fallback
    return uiText.literal(message)
end

-- Displayed version comes from plugin.toml. Unavailable manifests show none.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then return "" end
    return shared.singleLine(("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or "", 24)
end)()

local RADIO_TELLUS_PROJECT_URL = "https://github.com/Scurolabs/scurolabs-plugins"
local stations, favorites, recent = {}, {}, {}
local favoriteKeys = {}
local STATIONS_PER_PAGE = 16
local FAVORITE_DRAG_TYPE = "radio-tellus-favorite"
local stationPage = 1
local selectIndex
local PANEL_VIEW_STATE_KEY = "radio_tellus_panel_view"
local PANEL_VIEW_LABELS = {
    discover = tr("view.discover"),
    moods = tr("view.pick_mood"),
    genres = tr("view.pick_genre"),
    places = tr("view.pick_place"),
    favorites = tr("view.favorites"),
    recent = tr("view.recent"),
    scrobbler = tr("view.scrobbler"),
    recent_scrobbles = tr("view.recent_scrobbles"),
}
local function rememberedPanelView()
    local remembered = noctalia.state.get(PANEL_VIEW_STATE_KEY)
    if type(remembered) == "string" and PANEL_VIEW_LABELS[remembered] ~= nil then return remembered end
    return nil
end

local initialView = rememberedPanelView() or "discover"
local view = initialView
local activeLabel = PANEL_VIEW_LABELS[view]
local selectedIndex, selectedStation = 0, nil
local loading, errorText, stateError = false, "", ""
local query, panelOpen = "", false
local searchRevision = 0
local suppressStopOnClose = false
local randomGeneration = 0
local randomLoading = false
local CONNECTING_STATE_MESSAGE = "Connecting to the station. Waiting for audio."
local CONNECTING_MESSAGE = tr("playback.connecting")
local refreshPending, refreshStatus = false, ""
local playerVolume, playerMuted, volumeDraft = shared.DEFAULT_VOLUME, false, nil
local playbackSnapshot = {
    state = "stopped", station = nil, stationName = "", track = "", error = "", isolation = "",
}
local render
local navigationSerial = 0
local cacheRepositoryInstance = cacheRepository.new()
local libraryStore = libraryStoreModule.new()
local requestManager = requestManagerModule.new({ maxActive = 4, maxNativeActive = 8 })
local randomRequestManager = requestManagerModule.new({ maxActive = 1, maxNativeActive = 1 })
local frameScheduler = frameSchedulerModule.new(panel, function()
    if render then render() end
end)

local function requestRender(reason, debounceMs)
    if panelOpen then frameScheduler:request(reason or "state", debounceMs) end
end

local function renderIfOpen()
    requestRender("state")
end

local function invalidateRandomSelection()
    randomGeneration += 1
    randomRequestManager:invalidate()
    if randomLoading then
        randomLoading = false
        loading = false
        refreshPending, refreshStatus = false, ""
        requestRender("random-cancelled")
    end
end

local function beginNavigation()
    navigationSerial += 1
    invalidateRandomSelection()
    requestManager:invalidate()
    return navigationSerial
end

local function navigationIsCurrent(token)
    return panelOpen and token == navigationSerial
end

local function updatePlaybackSnapshot(field, value)
    if field == "state" then playbackSnapshot.state = tostring(value or "stopped")
    elseif field == "station" then playbackSnapshot.station = value
    elseif field == "stationName" then playbackSnapshot.stationName = shared.singleLine(value, 160)
    elseif field == "track" then playbackSnapshot.track = shared.singleLine(value, 160)
    elseif field == "error" then playbackSnapshot.error = shared.singleLine(value, 160)
    elseif field == "isolation" then playbackSnapshot.isolation = tostring(value or "") end
end

local function applyPlaybackSnapshot(value)
    if type(value) ~= "table" then return end
    updatePlaybackSnapshot("state", value.state)
    updatePlaybackSnapshot("station", value.station)
    updatePlaybackSnapshot("stationName", value.station_name)
    updatePlaybackSnapshot("track", value.track_title)
    updatePlaybackSnapshot("error", value.player_error)
    updatePlaybackSnapshot("isolation", value.playback_isolation)
    if volumeDraft == nil then
        playerVolume = shared.clampInteger(value.volume, playerVolume, 0, 100)
    end
    playerMuted = value.muted == true
end

local initialPlaybackSnapshot = noctalia.state.get("radio_tellus_playback")
if type(initialPlaybackSnapshot) == "table" then
    applyPlaybackSnapshot(initialPlaybackSnapshot)
else
    updatePlaybackSnapshot("state", noctalia.state.get("player_state"))
    updatePlaybackSnapshot("station", noctalia.state.get("station"))
    updatePlaybackSnapshot("stationName", noctalia.state.get("station_name"))
    updatePlaybackSnapshot("track", noctalia.state.get("track_title"))
    updatePlaybackSnapshot("error", noctalia.state.get("player_error"))
    updatePlaybackSnapshot("isolation", noctalia.state.get("playback_isolation"))
end

local lastFmStatus = lastfm.normalizeStatus(noctalia.state.get(lastfm.STATUS_KEY))
local lastFmCredentials = {}
local lastFmCredentialsLoaded = false
local lastFmCredentialsLoading, lastFmSavePending = false, false
local lastFmCredentialLoadWaiters = {}
local lastFmCredentialsError
local lastFmApiKey = lastFmCredentials.api_key or ""
local lastFmApiSecret = lastFmCredentials.api_secret or ""
local lastFmFormDirty = false
local lastFmFormRevision, lastFmActionSerial = 0, 0
local lastFmDisconnectPending = false
local lastFmFeedback = lastFmCredentialsError and
    tr("lastfm.credentials_could_not_be_loaded") or ""
local lastFmFeedbackError = lastFmCredentialsError ~= nil

local function lastFmMessage(key)
    return tr("lastfm.messages." .. key)
end

local function lastFmStateMessage(key)
    return tr("lastfm.state." .. key)
end

local LAST_FM_STATUS_LABELS = {
    connect_lastfm_account = lastFmMessage("connect_lastfm_account"),
    lastfm_authorization_required = lastFmMessage("lastfm_authorization_required"),
    lastfm_connected_waiting_for_radio_tellus = lastFmMessage("lastfm_connected_waiting_for_radio_tellus"),
    waiting_for_radio_tellus = lastFmMessage("waiting_for_radio_tellus"),
    waiting_for_confirmed_radio_metadata = lastFmMessage("waiting_for_confirmed_radio_metadata"),
    waiting_for_stable_confirmed_metadata = lastFmMessage("waiting_for_stable_confirmed_metadata"),
    playback_paused_waiting_for_confirmation = lastFmMessage("playback_paused_waiting_for_confirmation"),
    checking_track_with_lastfm = lastFmMessage("checking_track_with_lastfm"),
    track_validated_waiting_for_scrobble_threshold = lastFmMessage("track_validated_waiting_for_scrobble_threshold"),
    track_validated_waiting_for_unknown_duration_threshold = lastFmMessage("track_validated_waiting_for_unknown_duration_threshold"),
    track_not_found = lastFmMessage("track_not_found"),
    track_metadata_unavailable = lastFmMessage("track_metadata_unavailable"),
    lastfm_metadata_corrected = lastFmMessage("lastfm_metadata_corrected"),
    track_duration_unknown_or_short = lastFmMessage("track_duration_unknown_or_short"),
    track_duration_invalid = lastFmMessage("track_duration_invalid"),
    track_check_failed = lastFmMessage("track_check_failed"),
    track_metadata_not_confirmed_by_lastfm = lastFmMessage("track_metadata_not_confirmed_by_lastfm"),
    track_metadata_invalid = lastFmMessage("track_metadata_invalid"),
    track_metadata_matches_station = lastFmMessage("track_metadata_matches_station"),
    playback_generation_missing = lastFmMessage("playback_generation_missing"),
    playback_paused_waiting_to_save = lastFmMessage("playback_paused_waiting_to_save"),
    lastfm_now_playing_sent = lastFmMessage("lastfm_now_playing_sent"),
    scrobble_accepted = lastFmMessage("scrobble_accepted"),
    lastfm_filtered_track_not_scrobbled = lastFmMessage("lastfm_filtered_track_not_scrobbled"),
    scrobble_queue_full = lastFmMessage("scrobble_queue_full"),
    ["scrobble_failed; queued item retained"] = lastFmMessage("scrobble_failed; queued item retained"),
    ["lastfm_request_timed_out; queued scrobble retained"] = lastFmMessage("lastfm_request_timed_out; queued scrobble retained"),
    ["lastfm_scrobble_response_invalid; queued item retained"] = lastFmMessage("lastfm_scrobble_response_invalid; queued item retained"),
    ["scrobble_rejected; queued item discarded"] = lastFmMessage("scrobble_rejected; queued item discarded"),
    ["lastfm_track_check_failed; will retry"] = lastFmMessage("lastfm_track_check_failed; will retry"),
    lastfm_validation_timed_out = lastFmMessage("lastfm_validation_timed_out"),
    lastfm_now_playing_timed_out = lastFmMessage("lastfm_now_playing_timed_out"),
    lastfm_request_timed_out = lastFmMessage("lastfm_request_timed_out"),
    sending_queued_scrobble = lastFmMessage("sending_queued_scrobble"),
    song_queued_for_lastfm = lastFmMessage("song_queued_for_lastfm"),
    lastfm_queue_persist_failed = lastFmMessage("lastfm_queue_persist_failed"),
    scrobble_metadata_invalid = lastFmMessage("scrobble_metadata_invalid"),
    network_failure = lastFmMessage("network_failure"),
    response_invalid = lastFmMessage("response_invalid"),
    lastfm_session_invalid_reauthorize = lastFmMessage("lastfm_session_invalid_reauthorize"),
    lastfm_credentials_could_not_be_loaded = tr("lastfm.credentials_could_not_be_loaded"),
    lastfm_credentials_could_not_be_removed = lastFmMessage("lastfm_credentials_could_not_be_removed"),
    lastfm_queue_could_not_be_removed = lastFmMessage("lastfm_queue_could_not_be_removed"),
    credentials_could_not_be_saved = lastFmMessage("credentials_could_not_be_saved"),
    loading_lastfm_credentials = lastFmMessage("loading_lastfm_credentials"),
    saving_lastfm_credentials = lastFmMessage("saving_lastfm_credentials"),
    removing_lastfm_credentials = lastFmMessage("removing_lastfm_credentials"),
    authorization_token_missing = lastFmMessage("authorization_token_missing"),
    browser_could_not_be_opened = lastFmMessage("browser_could_not_be_opened"),
    lastfm_session_missing = lastFmMessage("lastfm_session_missing"),
    api_credentials_required = lastFmMessage("api_credentials_required"),
    requesting_lastfm_token = lastFmMessage("requesting_lastfm_token"),
    approve_access_in_lastfm_then_finish = lastFmMessage("approve_access_in_lastfm_then_finish"),
    requesting_lastfm_session = lastFmMessage("requesting_lastfm_session"),
    lastfm_account_disconnected = lastFmMessage("lastfm_account_disconnected"),
}

local LAST_FM_STATE_LABELS = {
    disconnected = lastFmStateMessage("disconnected"),
    waiting_for_radio = lastFmStateMessage("waiting_for_radio"),
    checking = lastFmStateMessage("checking"),
    ready = lastFmStateMessage("ready"),
    playing = lastFmStateMessage("playing"),
    queued = lastFmStateMessage("queued"),
    authorizing = lastFmStateMessage("authorizing"),
    authorization_ready = lastFmStateMessage("authorization_ready"),
    error = lastFmStateMessage("error"),
}

local function lastFmStatusLabel(message, state)
    local text = LAST_FM_STATUS_LABELS[message]
        or LAST_FM_STATE_LABELS[state]
    if text == nil and type(message) == "string" and message:match("^lastfm_%d+:") then
        text = lastFmMessage("request_rejected")
    end
    text = text or lastFmMessage("unavailable")
    return text
end

local function lastFmStatusText(status)
    return lastFmStatusLabel(status.message, status.state)
end

local function lastFmCurrentStatusText(status)
    if status.delivery_state == "sending" or status.delivery_state == "queued"
        or status.delivery_state == "retrying" or status.delivery_state == "saved"
        or status.delivery_state == "filtered" or status.delivery_state == "rejected" then
        return lastFmStatusLabel(status.delivery_message, status.state)
    end
    if status.current_validation == "checking" then
        return lastFmStatusLabel("checking_track_with_lastfm", "checking")
    elseif status.current_validation == "ready" then
        return lastFmStatusLabel(status.current_message ~= ""
            and status.current_message or "track_validated_waiting_for_scrobble_threshold", "ready")
    elseif status.current_validation == "rejected" then
        return lastFmStatusLabel(status.message, "error")
    elseif status.current_validation == "waiting" then
        return lastFmStatusLabel(status.current_message ~= ""
            and status.current_message or "waiting_for_stable_confirmed_metadata", "playing")
    end
    return lastFmStatusText(status)
end

local function lastFmActivityText(status)
    local message = status.activity_message
    if message == "" then return "" end
    local text = LAST_FM_STATUS_LABELS[message]
        or (message:match("^lastfm_%d+:") and lastFmMessage("request_rejected"))
        or lastFmMessage("activity")
    if status.delivery_artist ~= "" and status.delivery_title ~= "" then
        return text .. " · " .. status.delivery_artist .. " — " .. status.delivery_title
    end
    return text
end

local SHORTCUTS = {
    previous = tostring(noctalia.getConfig("shortcut_previous") or "Up"),
    next = tostring(noctalia.getConfig("shortcut_next") or "Down"),
    play = tostring(noctalia.getConfig("shortcut_play") or "none"),
    toggle = tostring(noctalia.getConfig("shortcut_toggle") or "space"),
    random = tostring(noctalia.getConfig("shortcut_random") or "r"),
    favorite = tostring(noctalia.getConfig("shortcut_favorite") or "f"),
    mute = tostring(noctalia.getConfig("shortcut_mute") or "m"),
}

local function resetSearch(force, preserveRefresh)
    if not preserveRefresh then refreshPending, refreshStatus = false, "" end
    if force or query ~= "" then searchRevision += 1 end
    query = ""
end

local MOODS = {
    { "Chill", "chillout", "coffee" }, { "Focus", "lofi", "brain" },
    { "Happy", "happy", "mood-smile" }, { "Energy", "dance", "bolt" },
    { "Calm", "ambient", "leaf" }, { "Sleep", "sleep", "moon" },
    { "Romantic", "love", "heart" }, { "Melancholy", "melancholic", "cloud-rain" },
}

local GENRES = {
    { "Pop", "pop", "sparkles" }, { "Rock", "rock", "guitar-pick" },
    { "Electronic", "electronic", "wave-sine" }, { "Hip-hop", "hiphop", "microphone-2" },
    { "Jazz", "jazz", "music" }, { "Classical", "classical", "music" },
    { "Soul & R&B", "soul", "heart" }, { "Reggae", "reggae", "sun" },
    { "Metal", "metal", "flame" }, { "Folk", "folk", "trees" },
    { "Country", "country", "hat-cowboy" }, { "Talk", "talk", "message-circle" },
}

local PLACES = {
    { "Sweden", "SE" }, { "United Kingdom", "GB" }, { "United States", "US" },
    { "France", "FR" }, { "Germany", "DE" }, { "Spain", "ES" },
    { "Italy", "IT" }, { "Brazil", "BR" }, { "Japan", "JP" },
    { "India", "IN" }, { "Australia", "AU" }, { "Canada", "CA" },
}

local PICKER_VIEWS = {
    moods = { prompt = tr("view.pick_mood"), choices = MOODS },
    genres = { prompt = tr("view.pick_genre"), choices = GENRES },
    places = { prompt = tr("view.pick_place"), choices = PLACES },
}

local function configuredLimit()
    return shared.clampInteger(noctalia.getConfig("station_limit"), 40, 10, 100)
end

local function cacheSeconds()
    local hours = shared.clampInteger(noctalia.getConfig("cache_hours"), 6, 1, 72)
    return hours * 3600
end

local function discoverRows()
    local entry = cacheRepositoryInstance:get(shared.DISCOVER_CACHE_FILE)
    if entry == nil then return {} end
    return entry.rows or {}
end

local libraryContentRevision = ""

local function reconcileLibrarySelection(rows, selectedKey)
    if type(rows) ~= "table" or #rows == 0 then
        selectedIndex, selectedStation = 0, nil
        stationPage = 1
        return
    end
    local nextIndex
    if selectedKey ~= "" then
        for index, row in ipairs(rows) do
            if type(row) == "table" and row.key == selectedKey then
                nextIndex = index
                break
            end
        end
    end
    nextIndex = nextIndex or shared.clampInteger(selectedIndex, 1, 1, #rows)
    local nextStation = rows[nextIndex].station
    local nextKey = shared.stationKey(nextStation)
    local selectionChanged = selectedKey ~= nextKey
    selectedIndex = nextIndex
    selectedStation = nextStation
    stationPage = math.floor((selectedIndex - 1) / STATIONS_PER_PAGE) + 1
    if selectionChanged then invalidateRandomSelection() end
end

local function applyLibraryState(state, err)
    local selectedKey = selectedStation ~= nil and shared.stationKey(selectedStation) or ""
    local nextRevision = tostring(state.content_revision or "")
    if nextRevision ~= libraryContentRevision then
        favorites = catalog.fromSanitized(state.favorites, shared.MAX_FAVORITES)
        recent = catalog.fromSanitized(state.recent, shared.MAX_RECENT)
        local nextFavoriteKeys = {}
        for _, favorite in ipairs(favorites) do
            if favorite.key ~= "" then nextFavoriteKeys[favorite.key] = true end
        end
        favoriteKeys = nextFavoriteKeys
        libraryContentRevision = nextRevision
        local rows = view == "favorites" and favorites or view == "recent" and recent or nil
        if rows ~= nil then reconcileLibrarySelection(rows, selectedKey) end
    end
    if volumeDraft == nil then
        local savedVolume = state.volume_set == true and state.volume or shared.DEFAULT_VOLUME
        playerVolume = shared.clampInteger(noctalia.state.get("player_volume"), savedVolume, 0, 100)
    end
    local publishedMuted = noctalia.state.get("player_muted")
    playerMuted = type(publishedMuted) == "boolean" and publishedMuted or state.muted
    local libraryError = type(err) == "string" and err or ""
    if libraryError == "" then libraryError = tostring(state.error or "") end
    stateError = localizedError(libraryError, "")
    if view == "favorites" or view == "recent" then loading = false end
    requestRender("library")
end

local function reloadLibrary()
    libraryStore:load()
end

libraryStore:subscribe(applyLibraryState)

local function displayRows()
    if view == "favorites" then return favorites end
    if view == "recent" then return recent end
    return stations
end

local function favoriteIndexForKey(key)
    if type(key) ~= "string" or key == "" then return nil end
    for index, row in ipairs(favorites) do
        if row.key == key then return index end
    end
    return nil
end

local function favoriteIndexForStation(value)
    local key = shared.stationKey(value)
    if key == "" then return nil end
    return favoriteIndexForKey(key)
end

local function pageCount(rows)
    return math.max(1, math.ceil(#(rows or {}) / STATIONS_PER_PAGE))
end

local function pageBounds(rows)
    local pages = pageCount(rows)
    stationPage = shared.clampInteger(stationPage, 1, 1, pages)
    local first = (stationPage - 1) * STATIONS_PER_PAGE + 1
    return first, math.min(#rows, first + STATIONS_PER_PAGE - 1), pages
end

local function changePage(delta)
    local rows = displayRows()
    local _, _, pages = pageBounds(rows)
    stationPage = shared.clampInteger(stationPage + delta, 1, 1, pages)
    if #rows > 0 then
        local first = (stationPage - 1) * STATIONS_PER_PAGE + 1
        if selectedIndex < first or selectedIndex > math.min(#rows, first + STATIONS_PER_PAGE - 1) then
            selectIndex(first)
        end
    end
    requestRender("page")
end

selectIndex = function(index)
    invalidateRandomSelection()
    local rows = displayRows()
    if #rows == 0 then selectedIndex, selectedStation = 0, nil; return end
    selectedIndex = shared.clampInteger(index, 1, 1, #rows)
    selectedStation = rows[selectedIndex].station
    stationPage = math.floor((selectedIndex - 1) / STATIONS_PER_PAGE) + 1
end

local function selectView(nextView, nextLabel)
    view, activeLabel = nextView, nextLabel
    noctalia.state.set(PANEL_VIEW_STATE_KEY, nextView)
end

local function setStations(nextView, nextLabel, rows)
    selectView(nextView, nextLabel)
    local ordered = rows or {}
    if nextView == "discover" then ordered = catalog.sortByVotes(ordered) end
    stations = catalog.limit(ordered, configuredLimit())
    stationPage = 1
    selectedIndex, selectedStation = 0, nil
    if #displayRows() > 0 then selectIndex(1) end
end

local function parseResponse(response)
    local parsed, err = shared.parseStationResponse(response, shared.MAX_CATALOG_STATIONS)
    if parsed == nil then return nil, err end
    return catalog.fromSanitized(parsed, configuredLimit()), nil
end

local function parseResponseSafe(response, requestError)
    if response == nil then return nil, requestError end
    local ok, rows, parseError = pcall(parseResponse, response)
    if not ok then return nil, tr("errors.directory_processing"), true end
    return rows, parseError, false
end

local function finishRefresh(succeeded)
    if not refreshPending then return end
    refreshPending = false
    refreshStatus = succeeded and tr("updated_just_now") or ""
end

local function popularSearchUrl(field, value, order)
    local filter = field and (field .. "=" .. shared.urlEncode(value) .. "&") or ""
    local ordering = order or "clickcount"
    return shared.API_BASE .. "/stations/search?" .. filter
        .. "hidebroken=true&order=" .. ordering .. "&reverse=true&limit=" .. tostring(configuredLimit())
end

local function fetchUrl(nextView, label, url, cacheName, token)
    loading, errorText = true, ""
    selectView(nextView, label)
    requestRender("navigation")
    local accepted = requestManager:request("stations", url, function(complete)
        return shared.httpDirectory(url, complete)
    end, function(response, requestError)
        if not navigationIsCurrent(token) then return end
        loading = false
        local rows, err = parseResponseSafe(response, requestError)
        if rows == nil then errorText = localizedError(err, tr("errors.load_start")) end
        if rows ~= nil then
            setStations(nextView, label, rows)
            if cacheName and #rows > 0 then
                cacheRepositoryInstance:publish(cacheName, rows, configuredLimit())
            end
            errorText = #rows == 0 and tr("errors.no_playable_stations") or ""
        end
        finishRefresh(rows ~= nil)
        requestRender("navigation-complete")
    end)
    if not accepted and navigationIsCurrent(token) then
        loading, errorText = false, tr("errors.load_start")
        finishRefresh(false)
        requestRender("navigation-error")
    end
end

local function showDiscover(force, preserveRefresh)
    local token = beginNavigation()
    resetSearch(false, preserveRefresh)
    cacheRepositoryInstance:setActive(shared.DISCOVER_CACHE_FILE)
    local cached = force and {} or discoverRows()
    setStations("discover", tr("view.discover"), cached)
    if not force and #cached > 0 and cacheRepositoryInstance:isFresh(
        shared.DISCOVER_CACHE_FILE, cacheSeconds(), configuredLimit()) then
        loading, errorText = false, ""
        requestRender("navigation")
        return
    end
    loading = true
    requestRender("navigation")
    local function continueAfterCache(rows)
        if not navigationIsCurrent(token) then return end
        setStations("discover", tr("view.discover"), rows)
        if not force and #rows > 0 and cacheRepositoryInstance:isFresh(
            shared.DISCOVER_CACHE_FILE, cacheSeconds(), configuredLimit()) then
            loading, errorText = false, ""
            requestRender("navigation-cache")
            return
        end
        fetchUrl("discover", tr("view.discover"), popularSearchUrl(nil, nil, "votes"),
            shared.DISCOVER_CACHE_FILE, token)
    end
    if force then
        fetchUrl("discover", tr("view.discover"), popularSearchUrl(nil, nil, "votes"),
            shared.DISCOVER_CACHE_FILE, token)
    elseif #cached > 0 then
        continueAfterCache(cached)
    else
        cacheRepositoryInstance:load(shared.DISCOVER_CACHE_FILE, shared.MAX_CATALOG_STATIONS,
            continueAfterCache)
    end
end

local function browseTag(section, label, tag, preserveRefresh)
    local token = beginNavigation()
    resetSearch(false, preserveRefresh)
    setStations(section, label, {})
    fetchUrl(section, label, popularSearchUrl("tag", tag), nil, token)
end

local function browsePlace(label, code, force, preserveRefresh)
    local token = beginNavigation()
    resetSearch(false, preserveRefresh)
    local cleanCode = shared.countryCode(code)
    local cacheName = "country-" .. cleanCode .. ".json"
    cacheRepositoryInstance:setActive(cacheName)
    local cached = force and {} or (cacheRepositoryInstance:get(cacheName) or {}).rows or {}
    setStations("places", label, cached)
    if #cached > 0 then
        loading, errorText = false, ""
        requestRender("navigation")
        if not force and cacheRepositoryInstance:isFresh(cacheName, cacheSeconds(), configuredLimit()) then return end
    end
    local function fetchPlace()
        if not navigationIsCurrent(token) then return end
        local url = shared.API_BASE .. "/stations/bycountrycodeexact/" .. cleanCode
            .. "?hidebroken=true&order=clickcount&reverse=true&limit=" .. tostring(configuredLimit())
        fetchUrl("places", label, url, cacheName, token)
    end
    if force or #cached > 0 then
        fetchPlace()
    else
        cacheRepositoryInstance:load(cacheName, shared.MAX_CATALOG_STATIONS, function(rows)
            if not navigationIsCurrent(token) then return end
            setStations("places", label, rows)
            if #rows > 0 and cacheRepositoryInstance:isFresh(cacheName, cacheSeconds(), configuredLimit()) then
                loading, errorText = false, ""
                requestRender("navigation-cache")
                return
            end
            fetchPlace()
        end)
    end
end

local function mergeGroups(groups)
    return catalog.merge(groups, configuredLimit())
end

local function updateSearchQuery(value)
    beginNavigation()
    query = shared.singleLine(value, 120)
    loading, errorText = false, ""
    requestRender("search-input", 150)
end

local function searchRemote(value, preserveRefresh)
    if not preserveRefresh then refreshPending, refreshStatus = false, "" end
    query = shared.singleLine(value ~= nil and value or query, 120)
    if query == "" then showDiscover(false); return end
    local token = beginNavigation()
    local searchState = searchCompletion.new(3)
    loading, errorText = true, ""
    selectView("search", tr("search.results_for", { query = shared.singleLine(query, 48) }))
    requestRender("search-submit")
    for _, field in ipairs({ "name", "country", "tag" }) do
        local url = popularSearchUrl(field, query)
        local accepted = requestManager:request("search-" .. field, url, function(complete)
            return shared.httpDirectory(url, complete)
        end, function(response, requestError)
            local terminal = searchCompletion.complete(searchState, navigationIsCurrent(token), function()
                return parseResponseSafe(response, requestError)
            end)
            if not navigationIsCurrent(token) then return end
            loading = searchState.loading
            if terminal then
                local merged = mergeGroups(searchState.groups)
                setStations("search", activeLabel, merged)
                if #merged == 0 then
                    if searchState.failures == 3 then
                        errorText = searchState.processingFailures > 0
                            and tr("errors.directory_processing")
                            or tr("errors.load_stations")
                    else
                        errorText = tr("errors.no_stations_matched")
                    end
                end
                finishRefresh(searchState.failures < 3)
                requestRender("search-complete")
            end
        end)
        if not accepted then
            searchCompletion.reject(searchState, navigationIsCurrent(token))
            if navigationIsCurrent(token) then requestRender("search-error") end
        end
    end
    if searchState.pending == 0 then
        loading, errorText = false, tr("errors.load_start")
        finishRefresh(false)
        requestRender("search-error")
    end
end

local function submitSearch(value)
    local submittedQuery = type(value) == "string" and value or query
    searchRemote(submittedQuery)
end

local function showLibrary(kind, preserveRefresh)
    resetSearch(false, preserveRefresh)
    beginNavigation()
    loading, errorText = libraryStore.loading, ""
    selectView(kind, kind == "favorites" and tr("view.favorites") or tr("view.recent"))
    local snapshot = libraryStore:get()
    applyLibraryState(snapshot, snapshot.error ~= "" and snapshot.error or nil)
    stationPage = 1
    selectedIndex, selectedStation = 0, nil
    if #displayRows() > 0 then selectIndex(1) end
    requestRender("navigation")
end

local function showPicker(kind)
    local picker = PICKER_VIEWS[kind]
    if picker == nil then return end
    resetSearch(false)
    beginNavigation()
    loading, errorText = false, ""
    setStations(kind, picker.prompt, {})
    requestRender("navigation")
end

local function showScrobbler()
    resetSearch(false)
    beginNavigation()
    loading, errorText = false, ""
    selectView("scrobbler", tr("view.scrobbler"))
    selectedIndex, selectedStation = 0, nil
    requestRender("navigation")
end

local function showRecentScrobbles()
    resetSearch(false)
    beginNavigation()
    loading, errorText = false, ""
    selectView("recent_scrobbles", tr("view.recent_scrobbles"))
    selectedIndex, selectedStation = 0, nil
    requestRender("navigation")
end

function onBackToScrobbler()
    showScrobbler()
end

function onShowRecentScrobbles()
    showRecentScrobbles()
end

local function playbackFinished(started, asyncError)
    if started then
        errorText = ""
    else
        errorText = localizedError(asyncError, tr("errors.station_start"))
    end
    requestRender("playback")
end

local function previewVolume(value)
    local volume = shared.clampInteger(value, playerVolume, 0, 100)
    volumeDraft, playerVolume = volume, volume
    shared.setVolume(volume, false)
    requestRender("volume")
end

local function commitVolume()
    -- Live MPV volume updates during the drag. Only the final value is durable,
    -- with onClose covering an interrupted interaction.
    if volumeDraft == nil then return end
    local volume = volumeDraft
    playerVolume = volume
    local saved, err = shared.persistVolume(volume)
    if saved then
        volumeDraft = nil
    else
        stateError = localizedError(err, tr("errors.volume_save"))
        noctalia.log("radio-tellus: final volume value remains pending after save failure")
    end
end

local function playStation(station, queue)
    if station == nil then return end
    invalidateRandomSelection()
    errorText = ""
    if tostring(noctalia.state.get("player_state") or "stopped") == "starting" then
        errorText = shared.PLAYBACK_STARTING_MESSAGE
        requestRender("playback")
        return
    end
    if not shared.setQueueRows(queue or displayRows(), station) then
        errorText = tr("errors.queue_save")
        requestRender("playback")
        return
    end
    local ok, err = shared.play(station, playerVolume, playbackFinished)
    if not ok then errorText = localizedError(err, tr("errors.station_start")); requestRender("playback") end
end

local function tuneRandom(allowClosed)
    beginNavigation()
    local generation = randomGeneration
    randomLoading = true
    loading, errorText = true, ""
    requestRender("random-start")
    refreshPending, refreshStatus = false, ""
    local httpsFilter = noctalia.getConfig("allow_insecure_http") == true and "" or "&is_https=true"
    -- Cache-busting ensures each click reaches the randomizer.
    local cachebuster = tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(generation)
    local url = shared.API_BASE .. "/stations/search?hidebroken=true&order=random&limit=1"
        .. httpsFilter .. "&cachebuster=" .. cachebuster
    local accepted = randomRequestManager:request("random", url, function(complete)
        return shared.httpDirectory(url, complete)
    end, function(response, requestError)
        if generation ~= randomGeneration or (not allowClosed and not panelOpen) then return end
        randomLoading = false
        loading = false
        local parsed, err = response ~= nil and shared.parseStationResponse(response, 1) or nil, requestError
        local rows = parsed ~= nil and catalog.fromSanitized(parsed, 1) or nil
        if rows == nil or #rows == 0 then
            errorText = localizedError(err, tr("errors.random_not_found"))
            requestRender("random-error")
            return
        end
        local station = rows[1].station
        playStation(station, rows)
        requestRender("random-complete")
    end)
    if not accepted and generation == randomGeneration then
        randomLoading = false
        loading, errorText = false, tr("errors.random_start")
        requestRender("random-error")
    end
end

local function refreshCurrent()
    refreshPending, refreshStatus = true, ""
    if view == "discover" then showDiscover(true, true); return end
    if view == "search" and query ~= "" then searchRemote(query, true); return end
    if view == "favorites" or view == "recent" then showLibrary(view, true); finishRefresh(true); requestRender("refresh"); return end
    local picker = PICKER_VIEWS[view]
    for _, choice in ipairs(picker and picker.choices or {}) do
        if choice[1] == activeLabel then
            if view == "places" then browsePlace(choice[1], choice[2], true, true) else browseTag(view, choice[1], choice[2], true) end
            return
        end
    end
    finishRefresh(false)
    requestRender("refresh")
end

local function canRefresh()
    if loading then return false end
    local picker = PICKER_VIEWS[view]
    if picker then return activeLabel ~= picker.prompt end
    return view ~= "search" or query ~= ""
end

local function toggleFavorite(station)
    if station == nil then return end
    libraryStore:toggleFavorite(station, function(_, err)
        applyLibraryState(libraryStore:get(), err)
        if view == "favorites" then
            selectedIndex, selectedStation = 0, nil
            if #favorites > 0 then selectIndex(1) end
        end
        requestRender("library-mutation")
    end)
end

local function queueFavoriteReorder(station, targetIndex)
    if view ~= "favorites" or station == nil then return end
    local currentIndex = favoriteIndexForStation(station)
    if currentIndex == nil then return end
    if libraryStore:hasFavoriteMovePending() then
        noctalia.log("radio-tellus favorite reorder ignored pending_move")
        return
    end
    noctalia.log("radio-tellus favorite reorder requested from=" .. tostring(currentIndex)
        .. " to=" .. tostring(targetIndex))
    local accepted = libraryStore:moveFavorite(station, targetIndex, function(ok, err)
        local callbackError = not ok and localizedError(err, tr("errors.favorite_reorder_rejected")) or nil
        if callbackError ~= nil then
            noctalia.log("radio-tellus favorite reorder failed target=" .. tostring(targetIndex)
                .. " error=" .. shared.singleLine(callbackError, 160))
        else
            noctalia.log("radio-tellus favorite reorder completed target=" .. tostring(targetIndex))
        end
        applyLibraryState(libraryStore:get(), callbackError)
        if view == "favorites" then
            local movedIndex = favoriteIndexForStation(station)
            if movedIndex ~= nil then selectIndex(movedIndex) end
        end
        requestRender("favorite-reorder")
    end)
    if not accepted then
        local rejection = tr("errors.favorite_reorder_queue")
        stateError = rejection
        noctalia.log("radio-tellus favorite reorder queue_rejected target=" .. tostring(targetIndex))
        requestRender("favorite-reorder-rejected")
    else
        requestRender("favorite-reorder-pending")
    end
end

local function favoriteTargetPosition(sourceIndex, gapIndex, count)
    if type(sourceIndex) ~= "number" or type(gapIndex) ~= "number"
        or type(count) ~= "number" then return nil end
    if sourceIndex < 1 or sourceIndex > count or gapIndex < 1 or gapIndex > count + 1 then return nil end
    if gapIndex > sourceIndex then return gapIndex - 1 end
    return gapIndex
end

local function favoriteDropValue(gapIndex)
    return tostring(libraryContentRevision) .. ":" .. tostring(gapIndex)
end

function onFavoriteDropped(payload, value)
    if view ~= "favorites" then return end
    if type(payload) ~= "string" or payload == "" then
        noctalia.log("radio-tellus favorite reorder rejected invalid_payload")
        return
    end
    local revision, gapText
    if type(value) == "string" then revision, gapText = string.match(value, "^(.*):(%d+)$") end
    if revision == nil or gapText == nil then
        noctalia.log("radio-tellus favorite reorder rejected invalid_gap value=" .. tostring(value))
        return
    end
    if revision ~= libraryContentRevision then
        noctalia.log("radio-tellus favorite reorder rejected stale_revision expected="
            .. shared.singleLine(libraryContentRevision, 48) .. " received=" .. shared.singleLine(revision, 48))
        return
    end
    local gapIndex = tonumber(gapText)
    if gapIndex == nil or gapIndex ~= gapIndex or gapIndex == math.huge or gapIndex == -math.huge
        or math.floor(gapIndex) ~= gapIndex then
        noctalia.log("radio-tellus favorite reorder rejected invalid_gap value=" .. tostring(gapText))
        return
    end
    local sourceIndex = favoriteIndexForKey(payload)
    local targetIndex = favoriteTargetPosition(sourceIndex, gapIndex, #favorites)
    if sourceIndex == nil or targetIndex == nil then
        noctalia.log("radio-tellus favorite reorder rejected stale_drop gap=" .. tostring(gapIndex))
        return
    end
    if targetIndex == sourceIndex then return end
    local row = favorites[sourceIndex]
    if type(row) ~= "table" or type(row.station) ~= "table" then
        noctalia.log("radio-tellus favorite reorder rejected missing_station gap=" .. tostring(gapIndex))
        return
    end
    queueFavoriteReorder(row.station, targetIndex)
end

local function playerAction(action)
    if action ~= "mute" then invalidateRandomSelection() end
    if action == "toggle" then shared.togglePause()
    elseif action == "mute" then shared.toggleMute()
    elseif action == "stop" then shared.stop()
    elseif action == "previous" or action == "next" then
        local ok, err = shared.playQueueStep(action == "previous" and -1 or 1, playbackFinished)
        if not ok then errorText = localizedError(err, tr("errors.station_start")) end
    end
    requestRender("player-action")
end

local function requestLastFmAction(action)
    lastFmActionSerial += 1
    noctalia.state.set(lastfm.ACTION_KEY, action .. ":" .. lastFmActionSerial)
end

local function finishLastFmCredentialReload(succeeded, err)
    local waiters = lastFmCredentialLoadWaiters
    lastFmCredentialLoadWaiters = {}
    for _, callback in ipairs(waiters) do callback(succeeded, err) end
end

local function reloadLastFmCredentials(force, onComplete)
    if lastFmFormDirty and force ~= true then
        if type(onComplete) == "function" then onComplete(false, "form_dirty") end
        return false
    end
    if lastFmCredentialsLoaded and force ~= true then
        if type(onComplete) == "function" then onComplete(true) end
        return true
    end
    if type(onComplete) == "function" then table.insert(lastFmCredentialLoadWaiters, onComplete) end
    if lastFmCredentialsLoading then return true end
    lastFmCredentialsLoading = true
    local completed = false
    local function complete(loaded, err)
        if completed then return end
        completed = true
        lastFmCredentialsLoading = false
        if loaded == nil then
            lastFmCredentialsError = err or "unreadable"
            noctalia.log("radio-tellus: could not read Last.fm credentials for the panel: " .. tostring(lastFmCredentialsError))
            lastFmFeedback = tr("lastfm.credentials_could_not_be_loaded")
            lastFmFeedbackError = true
            finishLastFmCredentialReload(false, lastFmCredentialsError)
            renderIfOpen()
            return
        end
        if lastFmCredentialsError ~= nil then lastFmFeedback, lastFmFeedbackError = "", false end
        lastFmCredentialsError = nil
        lastFmCredentials = loaded
        lastFmCredentialsLoaded = true
        lastFmApiKey = lastFmCredentials.api_key or ""
        lastFmApiSecret = lastFmCredentials.api_secret or ""
        lastFmFormDirty = false
        lastFmFormRevision += 1
        finishLastFmCredentialReload(true)
        renderIfOpen()
    end
    local started = lastfm.loadCredentials(complete)
    if not started and not completed then complete(nil, "credential_load_not_started") end
    return started
end

local function currentLastFmApiCredentials()
    return lastfm.cleanSecret(lastFmApiKey, 128), lastfm.cleanSecret(lastFmApiSecret, 512)
end

local function lastFmApiCredentialsAreSaved()
    local apiKey, apiSecret = currentLastFmApiCredentials()
    return apiKey ~= nil and apiSecret ~= nil
        and apiKey == lastFmCredentials.api_key
        and apiSecret == lastFmCredentials.api_secret
end

local function lastFmAccountLabel(credentialsNeedSave, connected, authorizationReady, apiCredentialsSaved)
    if credentialsNeedSave then return tr("lastfm.account_details_changed") end
    if connected then return tr("lastfm.connected_as", { username = lastFmCredentials.username }) end
    if authorizationReady then return tr("lastfm.authorization_waiting") end
    if apiCredentialsSaved then return tr("lastfm.details_saved_authorization_required") end
    return tr("lastfm.no_account")
end

local function saveLastFmCredentials(refreshService)
    if lastFmCredentialsLoading or lastFmSavePending then return false end
    local apiKey, apiSecret = currentLastFmApiCredentials()
    if apiKey == nil or apiSecret == nil then
        lastFmFeedback = lastFmMessage("api_credentials_required")
        lastFmFeedbackError = true
        renderIfOpen()
        return false
    end
    local sameAccount = lastFmCredentials.api_key == apiKey and lastFmCredentials.api_secret == apiSecret
    lastFmSavePending = true
    lastFmFeedback = lastFmMessage("saving_lastfm_credentials")
    lastFmFeedbackError = false
    renderIfOpen()
    local completed = false
    local started = lastfm.saveCredentials({
        api_key = apiKey,
        api_secret = apiSecret,
        session_key = sameAccount and lastFmCredentials.session_key or nil,
        username = sameAccount and lastFmCredentials.username or nil,
    }, function(saved, err)
        if completed then return end
        completed = true
        if not saved then
            lastFmSavePending = false
            noctalia.log("radio-tellus: could not save Last.fm credentials from the panel: " .. tostring(err))
            lastFmFeedback = lastFmMessage("credentials_could_not_be_saved")
            lastFmFeedbackError = true
            renderIfOpen()
            return
        end
        -- Suspend the service before any asynchronous panel verification. The
        -- secure writer has published the new file, so the service must stop
        -- using the previous session immediately after this success callback.
        if refreshService then requestLastFmAction(lastfm.actions.credentialsChanged) end
        -- The secure writer's rename completes before this success check. Reading
        -- through the secure path also repairs permissions and removes stale
        -- credential temp files before the UI reports success.
        reloadLastFmCredentials(true, function(loaded, verificationError)
            lastFmSavePending = false
            if not loaded then
                if verificationError ~= nil then
                    noctalia.log("radio-tellus: saved Last.fm credentials could not be verified by the panel: "
                        .. tostring(verificationError))
                end
                renderIfOpen()
                return
            end
            lastFmFeedback = sameAccount and tr("lastfm.details_saved")
                or tr("lastfm.details_saved_authorize_to_resume")
            lastFmFeedbackError = false
            renderIfOpen()
        end)
    end)
    if not started and not completed then
        lastFmSavePending = false
        lastFmFeedback = lastFmMessage("credentials_could_not_be_saved")
        lastFmFeedbackError = true
        renderIfOpen()
    end
    return started
end

function onLastFmApiKeyChanged(value)
    if lastFmCredentialsLoading or lastFmSavePending then return end
    lastFmApiKey = tostring(value or "")
    lastFmFormDirty = true
    requestRender("lastfm-api-key")
end

function onLastFmApiSecretChanged(value)
    if lastFmCredentialsLoading or lastFmSavePending then return end
    lastFmApiSecret = tostring(value or "")
    lastFmFormDirty = true
    requestRender("lastfm-api-secret")
end

function onSaveLastFmCredentials()
    saveLastFmCredentials(true)
end

function onAuthorizeLastFm()
    requestLastFmAction(lastfm.actions.authorize)
end

function onFinishLastFmAuthorization()
    requestLastFmAction(lastfm.actions.finishAuthorization)
end

function onDisconnectLastFm()
    if lastFmCredentialsLoading or lastFmSavePending then return end
    lastFmFormDirty = false
    lastFmDisconnectPending = true
    requestLastFmAction(lastfm.actions.disconnect)
    lastFmFeedback = tr("lastfm.disconnecting")
    lastFmFeedbackError = false
    renderIfOpen()
end

local function openLastFmUrl(url, failureMessage)
    if url == nil or not noctalia.runAsync({ "/usr/bin/xdg-open", url }) then
        lastFmFeedback = failureMessage
        lastFmFeedbackError = true
    end
    renderIfOpen()
end

function onOpenRadioTellusProject()
    local function notifyFailure()
        uiText.notify("Radio Tellus", "Could not open the Radio Tellus GitHub project.", true)
    end
    local accepted = noctalia.runAsync({ "/usr/bin/xdg-open", RADIO_TELLUS_PROJECT_URL }, function(result)
        if type(result) ~= "table" or result.exitCode ~= 0 then notifyFailure() end
    end)
    if not accepted then
        notifyFailure()
    end
end

function onOpenLastFmApiAccount()
    openLastFmUrl(lastfm.API_ACCOUNT_URL, tr("errors.lastfm_api_open"))
end

function onOpenLastFmSite()
    openLastFmUrl(lastfm.SITE_URL, tr("errors.lastfm_site_open"))
end

function onOpenLastFmProfile()
    openLastFmUrl(lastfm.profileUrl(lastFmCredentials.username), tr("errors.lastfm_profile_open"))
end

function onOpenLastFmTrack()
    openLastFmUrl(lastfm.trackUrl(lastFmStatus.artist, lastFmStatus.title),
        tr("errors.lastfm_track_open"))
end

function onOpenLastFmSavedTrack()
    local url = lastFmStatus.last_saved_url ~= "" and lastFmStatus.last_saved_url
        or lastfm.trackUrl(lastFmStatus.last_saved_artist, lastFmStatus.last_saved_title)
    openLastFmUrl(url,
        tr("errors.lastfm_saved_track_open"))
end

local function activateStation(station, index)
    if station == nil then return end
    if index ~= nil then selectIndex(index) end
    local state = tostring(noctalia.state.get("player_state") or "stopped")
    local active = state ~= "stopped"
        and shared.stationKey(noctalia.state.get("station")) == shared.stationKey(station)
    if active and state == "starting" then return end
    if active and (state == "playing" or state == "paused") then
        playerAction("toggle")
    else
        playStation(station)
    end
end

local function stationRow(row, index, playerState, playingKey)
    local station, key = row.station, row.key
    local playing = playingKey ~= "" and playingKey == key
    local connecting = playing and playerState == "starting"
    local selected = selectedIndex == index
    local saved = favoriteKeys[key] == true
    local actions = {
        ui.button({ key = row.uiKey .. "-favorite", glyph = saved and "star-filled" or "star", variant = "ghost", controlSize = "sm", tooltip = saved and "Remove favorite" or "Add favorite", onClick = function() toggleFavorite(station) end }),
    }
    local playButton = ui.button({
        key = row.uiKey .. "-play",
        glyph = playing and playerState == "playing" and "player-pause" or "player-play",
        variant = playing and "primary" or "ghost", controlSize = "sm", enabled = not connecting,
        tooltip = connecting and "Connecting…" or (playing and playerState == "playing" and "Pause station"
            or (playing and playerState == "paused" and "Resume station" or "Play station")),
        onClick = function() activateStation(station, index); requestRender("playback") end,
    })
    table.insert(actions, playButton)
    local stationContent = ui.row({
        key = row.uiKey .. "-content", flexGrow = 1, align = "center", gap = 7,
        onClick = function()
            selectIndex(index)
            if tostring(noctalia.getConfig("row_click_action") or "play") ~= "select" then
                activateStation(station, index)
            end
            requestRender("selection")
        end,
    }, {
        ui.glyph({ name = playing and "antenna-bars-5" or "radio", size = 17, color = playing and "primary" or "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 1 }, {
            nativeUi.label({ text = station.name, maxLines = 1, fontSize = 13, fontWeight = playing and "bold" or "medium" }),
            nativeUi.label({ text = row.metadata, maxLines = 1, fontSize = 10, color = "on_surface_variant" }),
        }),
    })
    local children = {}
    if view == "favorites" then
        table.insert(children, ui.dragSource({
            key = row.uiKey .. "-grip", dragType = FAVORITE_DRAG_TYPE, payload = row.key,
            enabled = not libraryStore:hasFavoriteMovePending(), previewAncestor = 1,
            liftFromLayout = true, width = 24, height = 24, align = "center", justify = "center",
            tooltip = "Drag favorite to reorder",
        }, {
            ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
        }))
    end
    table.insert(children, stationContent)
    for _, action in ipairs(actions) do table.insert(children, action) end
    return ui.row({
        key = row.uiKey, align = "center", gap = 7, paddingH = 9, paddingV = 6,
        fill = playing and "primary/0.16" or (selected and "surface_variant" or "surface"), radius = 7,
    }, children)
end

local function favoriteInsertionZone(gapIndex)
    return ui.dropZone({
        key = "favorite-gap-" .. tostring(gapIndex),
        accepts = { FAVORITE_DRAG_TYPE },
        value = favoriteDropValue(gapIndex),
        onDrop = "onFavoriteDropped",
        enabled = not libraryStore:hasFavoriteMovePending(),
        height = 3,
        radius = 6,
        expandOnDrag = true,
        hitSlop = 28,
    })
end

local function pageControlSlot(direction, enabled, gapIndex)
    local previous = direction == "previous"
    local text = previous and "Previous" or "Next"
    local button = ui.button({
        text = text,
        variant = "ghost",
        controlSize = "sm",
        enabled = enabled,
        onClick = function() changePage(previous and -1 or 1) end,
    })
    if view == "favorites" and enabled and not libraryStore:hasFavoriteMovePending() then
        button = ui.dropZone({
            key = "favorite-page-" .. direction,
            accepts = { FAVORITE_DRAG_TYPE },
            value = favoriteDropValue(gapIndex),
            onDrop = "onFavoriteDropped",
            width = 86,
            height = 32,
            align = "center",
            justify = "center",
            radius = 6,
        }, { button })
    end
    return ui.row({
        width = 86,
        align = "center",
        justify = previous and "start" or "end",
    }, { button })
end

local function playerCard(state, playingStation, playingKey)
    local stationName = playbackSnapshot.stationName
    local track = playbackSnapshot.track
    local playbackError = playbackSnapshot.error
    local isolation = playbackSnapshot.isolation
    local running = state ~= "stopped"
    local connecting = state == "starting" and playbackError == CONNECTING_STATE_MESSAGE
    local hasPlaybackError = playbackError ~= "" and not connecting
    local detail
    if connecting then
        detail = CONNECTING_MESSAGE
    elseif hasPlaybackError then
        detail = playbackError
    elseif not running then
        detail = tr("player.select_station")
    else
        detail = (track ~= "" and track ~= stationName) and track
            or (state == "paused" and tr("player.paused") or tr("player.live_now"))
    end
    local title = not running and hasPlaybackError and tr("player.station_unavailable")
        or (running and (stationName ~= "" and stationName or tr("player.unknown_station"))
        or tr("player.no_station"))
    local titleIsMetadata = running and stationName ~= ""
    local detailIsMetadata = running and track ~= "" and track ~= stationName
    if running and isolation == "full" then detail = detail .. "  ·  " .. tr("player.full_protection")
    elseif running and isolation == "compatible" then detail = detail .. "  ·  " .. tr("player.compatible_protection") end
    return ui.row({ align = "center", gap = 9, padding = 10, minHeight = 64, fill = "surface_variant", radius = 10 }, {
        ui.glyph({ name = running and "antenna-bars-5" or "radio", size = 28, color = running and "primary" or "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 3 }, {
            (titleIsMetadata and nativeUi.label or ui.label)({ text = title, maxLines = 1, fontSize = 14, fontWeight = "bold" }),
            (detailIsMetadata and nativeUi.label or ui.label)({ text = detail, maxLines = 1, fontSize = 11, color = hasPlaybackError and "error" or "on_surface_variant" }),
            ui.row({ align = "center", gap = 4, width = 190 }, {
                ui.button({ glyph = playerMuted and "volume-off" or "volume", variant = playerMuted and "primary" or "ghost", controlSize = "sm", enabled = running, tooltip = "Mute", onClick = function() playerAction("mute") end }),
                ui.slider({ key = "volume", min = 0, max = 100, step = 1, value = volumeDraft or playerVolume, controlSize = "sm", enabled = state ~= "starting", width = 118, onChange = previewVolume, onDragEnd = function() commitVolume(); requestRender("volume-commit") end }),
                ui.label({ text = tostring(math.floor(playerVolume)) .. "%", width = 32, textAlign = "end", fontSize = 10, color = "on_surface_variant" }),
            }),
        }),
        ui.separator({ orientation = "vertical", thickness = 1, height = 44 }),
        ui.row({ align = "center", gap = 3 }, {
            ui.button({ glyph = favoriteKeys[playingKey] and "star-filled" or "star", variant = "ghost", controlSize = "sm", enabled = playingKey ~= "", tooltip = "Favorite playing station", onClick = function() toggleFavorite(playingStation) end }),
            ui.button({ glyph = "arrows-shuffle", glyphSize = 18, variant = "ghost", controlSize = "md", tooltip = "Random station", onClick = tuneRandom }),
            ui.button({ glyph = "player-skip-back", glyphSize = 19, variant = "ghost", controlSize = "md", tooltip = "Previous", onClick = function() playerAction("previous") end }),
            ui.button({ glyph = state == "playing" and "player-pause" or "player-play", glyphSize = 22, variant = "primary", controlSize = "lg", enabled = state ~= "starting", tooltip = state == "starting" and "Connecting…" or "Play / pause", onClick = function() if running then playerAction("toggle") else playStation(selectedStation) end end }),
            ui.button({ glyph = "player-skip-forward", glyphSize = 19, variant = "ghost", controlSize = "md", tooltip = "Next", onClick = function() playerAction("next") end }),
            ui.button({ glyph = "player-stop", glyphSize = 18, variant = "ghost", controlSize = "md", tooltip = "Stop", onClick = function() playerAction("stop") end }),
        }),
    })
end

local function lastFmCard()
    local authorizationReady = lastFmStatus.state == "authorization_ready"
    local authorizing = lastFmStatus.state == "authorizing"
    local connected = lastFmCredentials.session_key ~= nil and lastFmCredentials.username ~= nil
    local hasCredentials = lastFmApiKey ~= "" and lastFmApiSecret ~= ""
    local apiCredentialsSaved = lastFmApiCredentialsAreSaved()
    local credentialsNeedSave = hasCredentials and not apiCredentialsSaved
    local credentialsBusy = lastFmCredentialsLoading or lastFmSavePending
    local showAuthorize = apiCredentialsSaved and not connected and not authorizationReady and not authorizing
    local hasTrack = lastFmStatus.artist ~= "" and lastFmStatus.title ~= ""
    local trackIsConfirmed = hasTrack and lastFmStatus.current_validation == "ready"
    local confirmedTrackUrl = trackIsConfirmed and lastfm.trackUrl(lastFmStatus.artist, lastFmStatus.title) or nil
    local hasSavedTrack = lastFmStatus.last_saved_artist ~= "" and lastFmStatus.last_saved_title ~= ""
    local savedTrackUrl = not hasTrack and hasSavedTrack and
        (lastFmStatus.last_saved_url ~= "" and lastFmStatus.last_saved_url
            or lastfm.trackUrl(lastFmStatus.last_saved_artist, lastFmStatus.last_saved_title)) or nil
    local statusText = lastFmCurrentStatusText(lastFmStatus)
    local activityText = lastFmActivityText(lastFmStatus)
    local currentHasError = lastFmStatus.current_validation == "rejected"
        or lastFmStatus.current_message == "lastfm_track_check_failed; will retry"
        or lastFmStatus.current_message == "lastfm_validation_timed_out"
        or lastFmStatus.delivery_state == "retrying"
        or lastFmStatus.delivery_state == "filtered"
        or lastFmStatus.delivery_state == "rejected"
        or lastFmStatus.delivery_message == "lastfm_queue_persist_failed"
    local visibleError = currentHasError or (not hasTrack and lastFmStatus.state == "error")
    local statusColor = currentHasError and "error"
        or (trackIsConfirmed and "primary" or "on_surface_variant")
    local trackTitle = hasTrack and lastFmStatus.title
        or (hasSavedTrack and lastFmStatus.last_saved_title or tr("waiting_verified_song"))
    local trackArtist = hasTrack and lastFmStatus.artist
        or (hasSavedTrack and lastFmStatus.last_saved_artist or tr("song_details_pending"))
    local trackTitleIsMetadata = hasTrack or hasSavedTrack
    local trackArtistIsMetadata = hasTrack or hasSavedTrack
    local trackGlyph = hasTrack and "music" or (hasSavedTrack and "circle-check" or "radio")
    local trackLabel = trackIsConfirmed and tr("verified_for_lastfm")
        or (hasSavedTrack and not hasTrack and tr("lastfm_saved_song") or tr("current_song"))
    local trackSurface = visibleError and "error/0.12"
        or (trackIsConfirmed and "primary/0.14" or (hasSavedTrack and "tertiary/0.10" or "surface"))
    local trackAccent = visibleError and "error"
        or (trackIsConfirmed and "primary" or (hasSavedTrack and "tertiary" or "on_surface_variant"))
    if visibleError then statusColor = "error" end
    local account = lastFmAccountLabel(credentialsNeedSave, connected, authorizationReady, apiCredentialsSaved)
    return ui.column({ gap = 8, padding = 12, fill = "surface_variant", radius = 10 }, {
        ui.column({ key = "lastfm-track-card", gap = 6, padding = 15, fill = trackSurface,
            border = trackAccent, borderWidth = 1, radius = 11, minHeight = 145 }, {
            ui.row({ align = "center", justify = "end" }, {
                ui.label({ text = account, maxLines = 1, fontSize = 12,
                    color = visibleError and "error" or "on_surface_variant" }),
            }),
            ui.row({ align = "center", gap = 13 }, {
                ui.row({ align = "center", justify = "center", width = 62, height = 62,
                    fill = trackAccent .. "/0.18", radius = 31 }, {
                    ui.glyph({ name = trackGlyph, size = 31, color = trackAccent }),
                }),
                ui.column({ gap = 4, flexGrow = 1 }, {
                    ui.label({ text = trackLabel,
                        fontSize = 12, fontWeight = "medium", color = trackAccent }),
                    (trackTitleIsMetadata and nativeUi.label or ui.label)({ text = trackTitle, maxLines = 2, fontSize = 21, fontWeight = "bold", color = "on_surface" }),
                    (trackArtistIsMetadata and nativeUi.label or ui.label)({ text = trackArtist, maxLines = 2, fontSize = 14, color = "on_surface_variant" }),
                }),
            }),
            ui.separator({ thickness = 1, color = trackAccent .. "/0.28" }),
            ui.row({ align = "center", gap = 10 }, {
                ui.column({ gap = 3, flexGrow = 1 }, {
                    ui.label({ text = "Status", fontSize = 11, fontWeight = "medium", color = "on_surface_variant" }),
                    ui.label({ text = statusText, maxLines = 2, fontSize = 13, color = statusColor }),
                    activityText ~= "" and ui.label({ text = tr("lastfm.activity_prefix", { activity = activityText }),
                        maxLines = 2, fontSize = 12, color = "on_surface_variant" }) or ui.box({ height = 0 }),
                }),
                confirmedTrackUrl ~= nil and ui.button({ text = "Open Last.fm track", glyph = "external-link",
                    variant = "outline", controlSize = "sm", onClick = "onOpenLastFmTrack" })
                    or (savedTrackUrl ~= nil and ui.button({ text = "Open saved track", glyph = "external-link",
                        variant = "outline", controlSize = "sm", onClick = "onOpenLastFmSavedTrack" })
                    or ui.box({ height = 0 })),
            }),
        }),
        ui.column({ gap = 6, padding = 10, fill = "surface", radius = 10 }, {
            ui.row({ align = "center", gap = 7 }, {
                ui.glyph({ name = "user", size = 18, color = "primary" }),
                ui.label({ text = "Last.fm account", fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
                connected and ui.button({ text = "Open profile", glyph = "external-link", variant = "outline", controlSize = "sm",
                    onClick = "onOpenLastFmProfile" }) or ui.box({ height = 0 }),
            }),
            ui.row({ gap = 8 }, {
                ui.column({ gap = 4, flexGrow = 1 }, {
                    ui.label({ text = "API key", fontSize = 11, color = "on_surface_variant" }),
                    ui.input({ key = "lastfm-api-key-" .. tostring(lastFmFormRevision), value = lastFmApiKey,
                        placeholder = "Last.fm API key", fontSize = 13, enabled = not credentialsBusy,
                        onChange = "onLastFmApiKeyChanged" }),
                }),
                ui.column({ gap = 4, flexGrow = 1 }, {
                    ui.label({ text = "Shared secret", fontSize = 11, color = "on_surface_variant" }),
                    ui.input({ key = "lastfm-api-secret-" .. tostring(lastFmFormRevision), value = lastFmApiSecret,
                        placeholder = "Last.fm shared secret", fontSize = 13, password = true, enabled = not credentialsBusy,
                        onChange = "onLastFmApiSecretChanged" }),
                }),
            }),
            ui.row({ align = "center", gap = 7 }, {
                ui.button({ text = "Save API credentials", variant = credentialsNeedSave and "primary" or "outline", controlSize = "sm",
                    enabled = credentialsNeedSave and not credentialsBusy,
                    onClick = "onSaveLastFmCredentials" }),
                showAuthorize and ui.button({ text = "Authorize Last.fm", glyph = "external-link", variant = "primary", controlSize = "sm",
                    enabled = not credentialsBusy, onClick = "onAuthorizeLastFm" }) or ui.box({ height = 0 }),
                authorizationReady and ui.button({ text = "Complete Last.fm authorization", glyph = "circle-check", variant = "secondary", controlSize = "sm",
                    enabled = not credentialsBusy, onClick = "onFinishLastFmAuthorization" }) or ui.box({ height = 0 }),
                ui.button({ text = "Disconnect Last.fm", glyph = "unlink", variant = "destructive", controlSize = "sm",
                    enabled = not credentialsBusy and (connected or lastFmStatus.queued > 0 or hasCredentials),
                    onClick = "onDisconnectLastFm" }),
            }),
        }),
        ui.label({ text = "Radio Tellus checks each song with Last.fm before saving it. Songs waiting to be sent are retained safely and retried after a restart.",
            maxLines = 2, fontSize = 12, color = "on_surface_variant" }),
        lastFmFeedback ~= "" and ui.label({ text = lastFmFeedback, maxLines = 2, fontSize = 12,
            color = lastFmFeedbackError and "error" or "tertiary" }) or ui.box({ height = 0 }),
        ui.row({ key = "lastfm-footer", align = "center", justify = "start", gap = 8 }, {
            ui.button({ text = "Create Last.fm API account", variant = "outline", height = 24, fontSize = 10,
                onClick = "onOpenLastFmApiAccount" }),
            ui.button({ text = "powered by AudioScrobbler", variant = "outline", height = 24, fontSize = 10,
                onClick = "onOpenLastFmSite" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = tr("lastfm.songs_saved_session", { count = lastFmStatus.scrobbled }),
                fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
            ui.button({ text = "Recent scrobbles", glyph = "history", variant = "outline", height = 24, fontSize = 10,
                onClick = "onShowRecentScrobbles" }),
        }),
    })
end

local function copyRecentScrobble(item)
    if type(item) ~= "table" or type(item.artist) ~= "string" or type(item.title) ~= "string" then
        uiText.notify("Radio Tellus", "This scrobble has no copyable song details.", true)
        return
    end
    local text = item.artist .. " - " .. item.title
    local copied = type(noctalia.copyToClipboard) == "function"
        and noctalia.copyToClipboard(text, "text/plain") == true
    if copied then
        uiText.notify("Radio Tellus", "Copied the song artist and title to the clipboard.")
    else
        uiText.notify("Radio Tellus", "Could not copy the song artist and title to the clipboard.", true)
    end
end

local function openRecentScrobble(item)
    if type(item) ~= "table" or type(item.lastfm_url) ~= "string" or item.lastfm_url == "" then
        uiText.notify("Radio Tellus", "This scrobble has no Last.fm page.", true)
        return
    end
    openLastFmUrl(item.lastfm_url, tr("errors.lastfm_track_open"))
end

local function recentScrobblesContent()
    local rows = {}
    for index, item in ipairs(lastFmStatus.recent_scrobbles) do
        table.insert(rows, ui.column({ key = "recent-scrobble-" .. tostring(index) .. "-" .. tostring(item.at),
            gap = 2, padding = 10, fill = "surface_variant", radius = 8 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.column({ gap = 2, flexGrow = 1 }, {
                    nativeUi.label({ text = item.title, maxLines = 2, fontSize = 14, fontWeight = "bold", color = "on_surface" }),
                    nativeUi.label({ text = item.artist, maxLines = 1, fontSize = 12, color = "on_surface_variant" }),
                }),
                ui.button({ text = "Copy", glyph = "copy", variant = "outline", controlSize = "sm",
                    tooltip = "Copy artist and title", onClick = function() copyRecentScrobble(item) end }),
                ui.button({ text = "Open Last.fm", glyph = "external-link", variant = "outline", controlSize = "sm",
                    tooltip = "Open the Last.fm track page", onClick = function() openRecentScrobble(item) end }),
            }),
        }))
    end
    if #rows == 0 then
        table.insert(rows, ui.label({ text = "No Radio Tellus songs have been saved yet.",
            fontSize = 12, color = "on_surface_variant" }))
    end
    return ui.column({ key = "recent-scrobbles-view", flexGrow = 1, gap = 8 }, {
        ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = "Recent Radio Tellus scrobbles", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ text = "Back to Scrobbler", glyph = "arrow-left", variant = "ghost", controlSize = "sm",
                onClick = "onBackToScrobbler" }),
        }),
        ui.scroll({ key = "recent-scrobbles-list", flexGrow = 1, gap = 6, align = "stretch",
            fill = "surface/0.55", radius = 8 }, rows),
    })
end

local function choiceButton(section, choice)
    local label, value, glyph = choice[1], choice[2], choice[3]
    return ui.button({ key = "choice-" .. section .. "-" .. value, text = label, glyph = glyph,
        variant = activeLabel == label and "primary" or "outline", controlSize = "sm", flexGrow = 1,
        onClick = function() if section == "places" then browsePlace(label, value) else browseTag(section, label, value) end end })
end

local function choiceGrid(section, choices)
    local rows = {}
    for first = 1, #choices, 4 do
        local buttons = {}
        for index = first, math.min(first + 3, #choices) do table.insert(buttons, choiceButton(section, choices[index])) end
        table.insert(rows, ui.row({ gap = 5 }, buttons))
    end
    return ui.column({ gap = 5 }, rows)
end

local function browserHeader()
    local picker = PICKER_VIEWS[view]
    if picker then return choiceGrid(view, picker.choices) end
    return ui.box({ height = 0 })
end

local function stationBrowserContent(rows, current, message, pages)
    local first, last = pageBounds(current)
    local favoriteReorderPending = view == "favorites" and libraryStore:hasFavoriteMovePending()
    return ui.column({ key = "station-browser-content", flexGrow = 1, gap = 8 }, {
        browserHeader(),
        ui.column({ gap = 3, paddingH = 4 }, {
            ui.row({ align = "center", gap = 6 }, {
                ui.label({ text = activeLabel, fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
                loading and ui.label({ text = "Loading…", fontSize = 11, color = "primary" }) or ui.box({ width = 0 }),
                refreshStatus ~= "" and ui.label({ text = refreshStatus, fontSize = 11, color = "primary" }) or ui.box({ width = 0 }),
                favoriteReorderPending and ui.label({ text = "Saving order…", fontSize = 11, color = "primary" }) or ui.box({ width = 0 }),
                ui.label({ text = tr("station_count", { count = #current }), fontSize = 11, color = "on_surface_variant" }),
                ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", width = 34, height = 32, enabled = canRefresh(), tooltip = "Reload stations", onClick = refreshCurrent }),
            }),
            message ~= "" and ui.label({ text = message, maxLines = 2, fontSize = 12, color = "error" }) or ui.box({ height = 0 }),
        }),
        ui.scroll({ key = "stations-" .. view .. "-" .. activeLabel .. "-page-" .. tostring(stationPage), flexGrow = 1, gap = 3, align = "stretch", fill = "surface/0.55", radius = 8 }, rows),
        ui.row({ align = "center", paddingH = 4 }, {
            pageControlSlot("previous", stationPage > 1, first - 1),
            ui.label({ text = tr("page", { current = stationPage, total = pages }),
                fontSize = 11, color = "on_surface_variant", flexGrow = 1, textAlign = "center" }),
            pageControlSlot("next", stationPage < pages, last + 2),
        }),
    })
end

local function openRadioSettings()
    suppressStopOnClose = true
    panel.close()
    noctalia.openSettings()
end

render = function()
    if not panelOpen then return end
    local playerState = playbackSnapshot.state
    local playbackError = playbackSnapshot.error
    local connecting = playerState == "starting" and playbackError == CONNECTING_STATE_MESSAGE
    local message = uiText.literal(errorText)
    if message == "" and playbackError ~= "" and not connecting then message = uiText.literal(playbackError) end
    if message == "" then message = uiText.literal(stateError) end
    local playingStation = playerState ~= "stopped" and playbackSnapshot.station or nil
    local playingKey = playingStation ~= nil and shared.stationKey(playingStation) or ""
    local content
    if view == "scrobbler" then
        content = ui.scroll({ key = "scrobbler-view", flexGrow = 1, gap = 8, align = "stretch" }, {
            lastFmCard(),
        })
    elseif view == "recent_scrobbles" then
        content = recentScrobblesContent()
    else
        local rows, current = {}, displayRows()
        local first, last, pages = pageBounds(current)
        if loading and #current == 0 then table.insert(rows, ui.label({ text = "Loading stations…", textAlign = "center", color = "on_surface_variant", fontSize = 11 })) end
        if view == "favorites" and first <= last then
            table.insert(rows, favoriteInsertionZone(first))
        end
        for index = first, last do
            local row = current[index]
            table.insert(rows, stationRow(row, index, playerState, playingKey))
            if view == "favorites" then
                table.insert(rows, favoriteInsertionZone(index + 1))
            end
        end
        content = stationBrowserContent(rows, current, message, pages)
    end

    panel.render(ui.column({ flexGrow = 1, gap = 9, padding = 12 }, {
        ui.column({ gap = 6, height = 70 }, {
            ui.row({ align = "center", gap = 6 }, {
                ui.column({ gap = 0 }, {
                    ui.row({ align = "center", gap = 6 }, {
                        ui.label({ text = "Radio Tellus", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
                        ui.label({ text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
                    }),
                    ui.label({ text = "Internet radio from around the world", fontSize = 11, color = "on_surface_variant" }),
                }),
                ui.spacer({ flexGrow = 1 }),
                ui.button({ glyph = "brand-github", variant = "ghost", controlSize = "sm", tooltip = "Open ScuroLabs plugins on GitHub", onClick = onOpenRadioTellusProject }),
                ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Radio settings", onClick = openRadioSettings }),
                ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = function() panel.close() end }),
            }),
            ui.input({ key = "radio-search-" .. tostring(searchRevision), value = query, placeholder = "Search station names…", controlSize = "sm", submitOnEnter = true, onChange = updateSearchQuery, onSubmit = submitSearch }),
        }),
        ui.separator({ thickness = 1 }),
        ui.column({ key = "radio-tellus-content", flexGrow = 1, gap = 8 }, {
            playerCard(playerState, playingStation, playingKey),
            ui.row({ gap = 4, align = "center" }, {
                ui.button({ text = "Discover", glyph = "compass", variant = view == "discover" and "primary" or "ghost", controlSize = "sm", onClick = function() showDiscover(false) end }),
                ui.button({ text = "Moods", glyph = "mood-smile", variant = view == "moods" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("moods") end }),
                ui.button({ text = "Genres", glyph = "category", variant = view == "genres" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("genres") end }),
                ui.button({ text = "Places", glyph = "world", variant = view == "places" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("places") end }),
                ui.button({ text = "Favorites", glyph = "star", variant = view == "favorites" and "primary" or "ghost", controlSize = "sm", onClick = function() showLibrary("favorites") end }),
                ui.button({ text = "Recent", glyph = "history", variant = view == "recent" and "primary" or "ghost", controlSize = "sm", onClick = function() showLibrary("recent") end }),
                ui.button({ text = "Scrobbler", glyph = "music", variant = view == "scrobbler" and "primary" or "ghost", controlSize = "sm", onClick = showScrobbler }),
            }),
            content,
        }),
    }))
end

noctalia.state.watch("radio_tellus_playback", function(value)
    applyPlaybackSnapshot(value)
    renderIfOpen()
end)
noctalia.state.watch(lastfm.STATUS_KEY, function(value)
    lastFmStatus = lastfm.normalizeStatus(value)
    local disconnected = lastFmStatus.message == "lastfm_account_disconnected"
    if disconnected then
        lastFmDisconnectPending = false
        lastFmFeedback = lastFmMessage("lastfm_account_disconnected")
        lastFmFeedbackError = false
        lastFmCredentials = {}
        lastFmCredentialsLoaded = false
        lastFmCredentialsError = nil
        lastFmApiKey, lastFmApiSecret = "", ""
        lastFmFormDirty = false
        lastFmFormRevision += 1
    elseif lastFmDisconnectPending and lastFmStatus.state == "error" then
        lastFmDisconnectPending = false
        lastFmFeedback = lastFmStatusText(lastFmStatus)
        lastFmFeedbackError = true
    end
    if disconnected or lastFmStatus.username ~= (lastFmCredentials.username or "") then
        reloadLastFmCredentials(true)
    end
    if view == "scrobbler" or view == "recent_scrobbles" then renderIfOpen() end
end)

function onOpen(_context)
    suppressStopOnClose = false
    panelOpen = true
    frameScheduler:openPanel()
    reloadLastFmCredentials(false)
    requestLastFmAction(lastfm.actions.refresh)
    resetSearch(true)
    reloadLibrary()
    -- A failed close-time save leaves the draft in memory for a retry when
    -- the panel is opened again. reloadLibrary preserves that draft.
    if volumeDraft ~= nil then commitVolume() end
    local openView = tostring(noctalia.getConfig("startup_view") or "discover")
    if openView == "scrobbler" then
        showScrobbler()
    elseif openView == "recent_scrobbles" then
        showRecentScrobbles()
    elseif openView == "favorites" or openView == "recent" then
        showLibrary(openView)
    elseif PICKER_VIEWS[openView] then
        showPicker(openView)
    else
        showDiscover(false)
    end
end

function onClose()
    commitVolume()
    panelOpen = false
    beginNavigation()
    requestManager:invalidate()
    libraryStore:invalidate()
    cacheRepositoryInstance:invalidate()
    cacheRepositoryInstance:flushWrites()
    frameScheduler:closePanel()
    local shouldStop = noctalia.getConfig("stop_on_panel_close") == true and not suppressStopOnClose
    suppressStopOnClose = false
    if shouldStop then shared.stop() end
end

function onFrameTick()
    frameScheduler:flush()
end

function onKey(chord, pressed)
    if not pressed then return end
    if chord == SHORTCUTS.previous then selectIndex(selectedIndex - 1); requestRender("selection")
    elseif chord == SHORTCUTS.next then selectIndex(selectedIndex + 1); requestRender("selection")
    elseif chord == SHORTCUTS.play and query == "" then activateStation(selectedStation, selectedIndex)
    elseif chord == SHORTCUTS.toggle then
        if playbackSnapshot.state == "stopped" then playStation(selectedStation) else playerAction("toggle") end
    elseif chord == SHORTCUTS.random then tuneRandom()
    elseif chord == SHORTCUTS.favorite then toggleFavorite(selectedStation)
    elseif chord == SHORTCUTS.mute then playerAction("mute") end
end

function onIpc(event, _payload)
    if event == "random" then tuneRandom(true)
    elseif event == "discover" then showDiscover(true)
    elseif event == "scrobbler" then showScrobbler() end
end
