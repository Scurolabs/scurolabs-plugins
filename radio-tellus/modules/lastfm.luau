--!nonstrict
-- Last.fm protocol, credential, and metadata-validation boundary.

local md5 = require("./md5.luau")
local numeric = require("./numeric-utils.luau")
local station = require("./station-utils.luau")
local storage = require("./storage-utils.luau")
local lastfm = {}
local urlEncode = station.urlEncode

lastfm.API_ROOT = "https://ws.audioscrobbler.com/2.0/"
lastfm.AUTH_URL = "https://www.last.fm/api/auth/"
lastfm.API_ACCOUNT_URL = "https://www.last.fm/api/account/create"
lastfm.SITE_URL = "https://www.last.fm/"
lastfm.PROFILE_URL = "https://www.last.fm/user/"
lastfm.USER_AGENT = "Radio-Tellus"
lastfm.CREDENTIALS_FILE = "lastfm-credentials.json"
lastfm.MAX_CREDENTIAL_BYTES = 16384
lastfm.MAX_RESPONSE_BYTES = 262144
lastfm.SCROBBLE_QUEUE_FILE = "lastfm-scrobble-queue.json"
lastfm.MAX_QUEUE_BYTES = 262144
lastfm.MAX_QUEUE = 100
lastfm.TRACK_KEY_MAX_BYTES = 360
lastfm.MAX_RECENT_SCROBBLES = 20
lastfm.MAX_API_ERROR_CODE = 1000
-- When Last.fm has no usable duration, the runtime uses the documented
-- four-minute limit as a conservative observed-playback threshold and omits
-- duration from the scrobble request.
lastfm.UNKNOWN_DURATION_SCROBBLE_THRESHOLD_SECONDS = 240
lastfm.STATUS_KEY = "lastfm_status"
lastfm.ACTION_KEY = "lastfm_action"

local runtimeNonce = 0

lastfm.actions = {
    refresh = "refresh",
    credentialsChanged = "credentials_changed",
    authorize = "authorize",
    finishAuthorization = "finish_authorization",
    disconnect = "disconnect",
}

local validStates = {
    disconnected = true,
    waiting_for_radio = true,
    checking = true,
    ready = true,
    playing = true,
    queued = true,
    authorizing = true,
    authorization_ready = true,
    error = true,
}

local REJECTED_TRACK_TEXT = {
    unknown = true,
    ["unknown artist"] = true,
    ["unknown title"] = true,
    untitled = true,
    ["n/a"] = true,
    none = true,
    advertisement = true,
    commercial = true,
    ["station identification"] = true,
    ["spot block start"] = true,
    ["spot block end"] = true,
}

local function cleanText(value, limit)
    return station.singleLine(value, limit or 240)
end

local function cleanSecret(value, limit)
    if type(value) ~= "string" then return nil end
    local text = cleanText(value, limit or 512)
    return text == "" and nil or text
end

local function cleanTrackKey(value)
    if type(value) ~= "string" then return "" end
    local key = value:gsub("[%c]", function(character)
        -- Unit separators are part of the in-memory track identity. Preserve
        -- them so a queued item remains comparable with its current candidate.
        return character == "\31" and character or " "
    end)
    key = station.trim(key)
    if #key <= lastfm.TRACK_KEY_MAX_BYTES then return key end
    -- A prefix is not an identity: distinct long titles can share it. Hash the
    -- complete canonical value so every field remains part of the bounded key.
    return "v1:" .. md5(key)
end

lastfm.cleanSecret = cleanSecret
lastfm.singleLine = cleanText
lastfm.clampInteger = numeric.clampInteger

function lastfm.confirmationSeconds()
    return lastfm.clampInteger(noctalia.getConfig("lastfm_confirmation_seconds"), 30, 15, 120)
end

function lastfm.retryIntervalMs()
    return lastfm.clampInteger(noctalia.getConfig("lastfm_retry_interval_seconds"), 60, 30, 3600) * 1000
end

function lastfm.sendNowPlaying()
    return noctalia.getConfig("lastfm_send_now_playing") ~= false
end

function lastfm.runtimeId()
    runtimeNonce += 1
    local timestamp = numeric.floorOr(noctalia.nowMs(), 0)
    local randomA = math.random(0, 2147483647)
    local randomB = math.random(0, 2147483647)
    return cleanText(table.concat({ tostring(timestamp), tostring(runtimeNonce),
        tostring(randomA), tostring(randomB) }, "-"), 120)
end

local function normalizedCredentials(raw)
    if type(raw) ~= "table" then return {} end
    local credentials = {
        api_key = cleanSecret(raw.api_key, 128),
        api_secret = cleanSecret(raw.api_secret, 512),
        session_key = cleanSecret(raw.session_key, 512),
        username = type(raw.username) == "string" and cleanText(raw.username, 80) or nil,
    }
    if credentials.username == "" then credentials.username = nil end
    return credentials
end

function lastfm.loadCredentials(callback)
    if type(callback) ~= "function" then return false, "callback_required" end
    return storage.readJsonSecure(lastfm.CREDENTIALS_FILE, lastfm.MAX_CREDENTIAL_BYTES, function(raw, err)
        if raw == nil then
            -- A missing file is the normal disconnected state. Other read
            -- errors must remain distinguishable so a refresh cannot discard
            -- a live in-memory session and retry queue merely because storage
            -- is temporarily unavailable or malformed.
            callback(err == "missing" and {} or nil, err == "missing" and nil or err)
            return
        end
        local credentials = normalizedCredentials(raw)
        if next(credentials) == nil then callback(nil, "invalid"); return end
        callback(credentials)
    end)
end

function lastfm.saveCredentials(value, callback)
    if type(callback) ~= "function" then return false, "callback_required" end
    local credentials = normalizedCredentials(value)
    if credentials.api_key == nil or credentials.api_secret == nil then
        callback(false, "Last.fm API key and shared secret are required.")
        return false, "Last.fm API key and shared secret are required."
    end
    if #credentials.api_key < 16 or #credentials.api_key > 128 then
        callback(false, "The Last.fm API key does not look valid.")
        return false, "The Last.fm API key does not look valid."
    end
    local started = storage.writeSecureJson(lastfm.CREDENTIALS_FILE, credentials, lastfm.MAX_CREDENTIAL_BYTES,
        function(saved, err)
            callback(saved, saved and nil or (err or "Last.fm credentials could not be saved."), credentials)
        end)
    if not started then return false, "Last.fm credentials could not be saved." end
    return true
end

function lastfm.clearCredentials()
    local path = storage.dataPath(lastfm.CREDENTIALS_FILE)
    if path == nil then return false, "Last.fm credential storage is unavailable." end
    local removed = true
    local removeError
    if noctalia.fileExists(path) then
        removed, removeError = noctalia.removeFile(path)
    end
    local temporaryRemoved, temporaryError = storage.removeTemporaryFiles(lastfm.CREDENTIALS_FILE, true)
    if not removed then return false, removeError or "Last.fm credentials could not be removed." end
    if not temporaryRemoved then return false, temporaryError or "Temporary Last.fm credentials could not be removed." end
    return true
end

function lastfm.clearScrobbleQueue()
    local path = storage.dataPath(lastfm.SCROBBLE_QUEUE_FILE)
    if path == nil then return false, "Last.fm queue storage is unavailable." end
    local removed, removeError = true, nil
    if noctalia.fileExists(path) then removed, removeError = noctalia.removeFile(path) end
    local temporaryRemoved, temporaryError = storage.removeTemporaryFiles(lastfm.SCROBBLE_QUEUE_FILE, true)
    if not removed then return false, removeError or "Last.fm queued songs could not be removed." end
    if not temporaryRemoved then
        return false, temporaryError or "Temporary Last.fm queued songs could not be removed."
    end
    return true
end

local function validTrackText(value)
    if type(value) ~= "string" then return nil end
    local text = cleanText(value, 160)
    local lowerText = string.lower(text)
    if text == "" or lowerText:find("http://", 1, true) or lowerText:find("https://", 1, true) then return nil end
    if REJECTED_TRACK_TEXT[lowerText] then return nil end
    return text
end

local function normalizeLastFmUrl(value)
    if type(value) ~= "string" then return nil end
    local url = cleanText(value, 2048)
    local scheme, authority, path = url:match("^(https?)://([^/?#]+)(/[^?#]*)")
    if scheme == nil or authority == nil or path == nil then return nil end
    local host = string.lower(authority)
    if (scheme ~= "http" and scheme ~= "https")
        or (host ~= "www.last.fm" and host ~= "last.fm")
        or path:sub(1, 7) ~= "/music/" then
        return nil
    end
    return "https://" .. host .. path
end

local function normalizeRecentScrobble(value)
    if type(value) ~= "table" then return nil end
    local artist = validTrackText(value.artist)
    local title = validTrackText(value.title)
    local at = numeric.nonNegativeInteger(value.at)
    if artist == nil or title == nil or at == nil then return nil end
    local lastfmUrl = normalizeLastFmUrl(value.lastfm_url) or lastfm.trackUrl(artist, title)
    return {
        artist = artist,
        title = title,
        key = cleanText(value.key, 360),
        at = at,
        lastfm_url = lastfmUrl,
    }
end

function lastfm.normalizeRecentScrobble(value)
    return normalizeRecentScrobble(value)
end

function lastfm.normalizeRecentScrobbles(value)
    local rows, discarded = {}, false
    if type(value) ~= "table" then return rows, true end
    if #value == 0 and next(value) ~= nil then discarded = true end
    for _, item in ipairs(value) do
        local normalized = normalizeRecentScrobble(item)
        if normalized ~= nil and #rows < lastfm.MAX_RECENT_SCROBBLES then
            table.insert(rows, normalized)
        else
            discarded = true
        end
    end
    return rows, discarded
end

function lastfm.parseTrackTitle(value)
    local original = validTrackText(value)
    if original == nil then return nil end
    for _, separator in ipairs({ " — ", " – ", " - " }) do
        local at = original:find(separator, 1, true)
        if at then
            local artist = validTrackText(original:sub(1, at - 1))
            local title = validTrackText(original:sub(at + #separator))
            if artist ~= nil and title ~= nil then return artist, title end
        end
    end
    return nil
end

local function sameText(left, right)
    return string.lower(station.trim(left)) == string.lower(station.trim(right))
end

local function validMusicBrainzId(value)
    if type(value) ~= "string" then return nil end
    local text = station.trim(value):lower()
    if #text ~= 36 or not text:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
        or text == "00000000-0000-0000-0000-000000000000" then
        return nil
    end
    return text
end

local function validTrackNumber(value)
    local number = numeric.nonNegativeInteger(value)
    return number ~= nil and number > 0 and number or nil
end

function lastfm.trackRequestFields(item)
    if type(item) ~= "table" then return nil end
    local artist = validTrackText(item.artist)
    local title = validTrackText(item.title)
    if artist == nil or title == nil then return nil end
    return {
        artist = artist,
        track = title,
        album = validTrackText(item.album),
        albumArtist = validTrackText(item.album_artist),
        trackNumber = validTrackNumber(item.track_number),
        mbid = validMusicBrainzId(item.mbid),
    }
end

local function validGeneration(value)
    local generation = cleanText(value, 120)
    return generation ~= "" and generation or nil
end

function lastfm.candidateFromMetadata(trackTitle, stationName, generation)
    local cleanGeneration = validGeneration(generation)
    if cleanGeneration == nil then return nil, "playback_generation_missing" end
    local artist, title = lastfm.parseTrackTitle(trackTitle)
    if artist == nil or title == nil then return nil, "track_metadata_invalid" end
    local cleanStation = cleanText(stationName, 160)
    if cleanStation ~= "" and (sameText(artist, cleanStation) or sameText(title, cleanStation)) then
        return nil, "track_metadata_matches_station"
    end
    local key = cleanTrackKey(cleanGeneration .. "\31" .. artist .. "\31" .. title)
    return {
        key = key,
        metadata_key = key,
        artist = artist,
        title = title,
        source_artist = artist,
        source_title = title,
        generation = cleanGeneration,
    }
end

function lastfm.occurrenceKey(metadataKey, occurrence, runtimeId)
    local key = cleanTrackKey(metadataKey)
    local serial = numeric.nonNegativeInteger(occurrence)
    if key == "" or serial == nil or serial == 0 then return key end
    local runtime = cleanText(runtimeId, 120)
    local suffix = runtime ~= ""
        and runtime .. "\31" .. tostring(serial)
        or tostring(serial)
    return cleanTrackKey(key .. "\31occurrence\31" .. suffix)
end

local SIGNATURE_EXCLUDED_PARAMETERS = {
    api_sig = true,
    format = true,
    callback = true,
}

local function sortedParameterNames(parameters, excluded)
    local names = {}
    for name, value in pairs(parameters or {}) do
        if value ~= nil and (excluded == nil or excluded[name] ~= true) then
            table.insert(names, tostring(name))
        end
    end
    table.sort(names)
    return names
end

function lastfm.apiSignature(parameters, secret)
    local pieces = {}
    for _, name in ipairs(sortedParameterNames(parameters, SIGNATURE_EXCLUDED_PARAMETERS)) do
        table.insert(pieces, name .. tostring(parameters[name]))
    end
    return md5(table.concat(pieces) .. tostring(secret or ""))
end

local function formEncode(parameters)
    local names = sortedParameterNames(parameters)
    local fields = {}
    for _, name in ipairs(names) do
        table.insert(fields, urlEncode(name) .. "=" .. urlEncode(parameters[name]))
    end
    return table.concat(fields, "&")
end

function lastfm.requestParameters(method, parameters, credentials, authenticated)
    local request = {}
    for name, value in pairs(parameters or {}) do request[name] = value end
    request.method = method
    request.api_key = credentials.api_key
    request.format = "json"
    if authenticated then request.sk = credentials.session_key end
    request.api_sig = lastfm.apiSignature(request, credentials.api_secret)
    return request
end

function lastfm.httpRequest(parameters)
    return {
        url = lastfm.API_ROOT,
        method = "POST",
        body = formEncode(parameters),
        headers = {
            "Accept: application/json",
            "Content-Type: application/x-www-form-urlencoded",
            "User-Agent: " .. lastfm.USER_AGENT,
        },
        follow_redirects = false,
        allow_insecure_tls = false,
    }
end

function lastfm.authorizationUrl(apiKey, token)
    return lastfm.AUTH_URL .. "?api_key=" .. urlEncode(apiKey)
        .. "&token=" .. urlEncode(token)
end

function lastfm.parseApiResponse(response)
    if type(response) ~= "table" then return nil, "network_failure" end
    local transportOk = response.ok == true
    local body = response.body
    if type(body) ~= "string" or #body > lastfm.MAX_RESPONSE_BYTES then
        return nil, transportOk and "response_invalid" or "network_failure"
    end
    local decoded = noctalia.json.decode(body)
    if type(decoded) ~= "table" then
        return nil, transportOk and "response_invalid" or "network_failure"
    end
    -- API error codes from non-200 responses let the runtime distinguish
    -- reauthentication and documented retries from bad requests.
    if decoded.error ~= nil then
        local errorCode = type(decoded.error) == "number"
            and numeric.nonNegativeInteger(decoded.error) or nil
        if errorCode == nil or errorCode < 1 or errorCode > lastfm.MAX_API_ERROR_CODE then
            return nil, "response_invalid"
        end
        -- Keep the stable numeric code for retry and reauthorization policy,
        -- but never retain or log server-controlled error text.
        return nil, "lastfm_" .. tostring(errorCode) .. ":api_error"
    end
    if not transportOk then return nil, "network_failure" end
    local status = numeric.finite(response.status)
    if status == nil or status ~= math.floor(status) then return nil, "response_invalid" end
    -- Last.fm's scrobbling response rules define HTTP 200 as success. A valid
    -- JSON body alone is not sufficient. Without an API error code, the
    -- non-200 response cannot be classified safely, so callers retain it for
    -- a later retry instead of discarding a queued scrobble.
    if status ~= 200 then return nil, "response_invalid" end
    return decoded
end

function lastfm.errorCode(message)
    return type(message) == "string" and tonumber(message:match("^lastfm_(%d+):")) or nil
end

function lastfm.retryableError(message)
    local code = lastfm.errorCode(message)
    -- Last.fm documents service-offline, temporary, and rate-limit failures
    -- as transient. Invalid requests and other API errors require a changed
    -- request or user action.
    return message == "network_failure" or message == "response_invalid"
        or code == 11 or code == 16 or code == 29
end

function lastfm.profileUrl(username)
    local name = cleanText(username, 80)
    if name == "" then return nil end
    return lastfm.PROFILE_URL .. urlEncode(name)
end

function lastfm.sameUsername(left, right)
    local first = cleanText(left, 80)
    local second = cleanText(right, 80)
    return first ~= "" and second ~= "" and string.lower(first) == string.lower(second)
end

function lastfm.trackUrl(artist, title)
    local cleanArtist = cleanText(artist, 160)
    local cleanTitle = cleanText(title, 160)
    if cleanArtist == "" or cleanTitle == "" then return nil end
    return lastfm.SITE_URL .. "music/" .. urlEncode(cleanArtist)
        .. "/_/" .. urlEncode(cleanTitle)
end

function lastfm.exactLastFmTrack(decoded, candidate)
    if type(decoded) ~= "table" or type(decoded.track) ~= "table" then return nil, "track_not_found" end
    local track = decoded.track
    local artist = type(track.artist) == "table" and track.artist.name or track.artist
    if type(candidate) ~= "table" or type(artist) ~= "string" or type(track.name) ~= "string"
        or not sameText(artist, candidate.artist) or not sameText(track.name, candidate.title) then
        return nil, "lastfm_metadata_corrected"
    end
    local durationMs = numeric.finite(track.duration)
    local durationSeconds
    if track.duration == nil or durationMs == 0 then
        -- Live radio metadata may not include a reliable catalogue duration.
        -- The runtime then uses the observed-play floor and omits duration.
        durationSeconds = nil
    elseif durationMs == nil or durationMs < 0 then
        return nil, "track_duration_invalid"
    elseif durationMs <= 30000 then
        return nil, "track_duration_unknown_or_short"
    else
        durationSeconds = durationMs / 1000
    end
    local album = type(track.album) == "table" and track.album or nil
    local albumArtist = album and validTrackText(album.artist) or nil
    if albumArtist ~= nil and sameText(albumArtist, candidate.artist) then albumArtist = nil end
    return {
        artist = candidate.artist,
        title = candidate.title,
        album = album and validTrackText(album.title) or nil,
        album_artist = albumArtist,
        track_number = album and validTrackNumber(album.position) or nil,
        mbid = validMusicBrainzId(track.mbid),
        duration_seconds = durationSeconds,
        lastfm_url = normalizeLastFmUrl(track.url) or lastfm.trackUrl(candidate.artist, candidate.title),
    }
end

function lastfm.scrobbleThresholdSeconds(durationSeconds)
    local duration = numeric.finite(durationSeconds)
    if duration == nil then return lastfm.UNKNOWN_DURATION_SCROBBLE_THRESHOLD_SECONDS end
    if duration <= 30 then return nil end
    return math.min(duration / 2, 240)
end

function lastfm.nowPlayingResult(decoded)
    if type(decoded) ~= "table" or type(decoded.nowplaying) ~= "table" then
        return nil, "now_playing_response_invalid"
    end
    local ignoredMessage = decoded.nowplaying.ignoredMessage
    if type(ignoredMessage) ~= "table" then return nil, "now_playing_response_invalid" end
    local ignoredCode = numeric.nonNegativeInteger(ignoredMessage.code)
    if ignoredCode == nil then return nil, "now_playing_response_invalid" end
    if ignoredCode ~= 0 then return nil, "now_playing_filtered_" .. tostring(ignoredCode) end
    return true
end

function lastfm.scrobbleResult(decoded)
    if type(decoded) ~= "table" or type(decoded.scrobbles) ~= "table" then
        return nil, "scrobble_response_invalid"
    end
    local attributes = decoded.scrobbles["@attr"]
    if type(attributes) ~= "table" then return nil, "scrobble_response_invalid" end
    local accepted = numeric.nonNegativeInteger(attributes.accepted)
    local ignored = numeric.nonNegativeInteger(attributes.ignored)
    -- Radio Tellus submits one track per request. Any other count is not a
    -- trustworthy response for the queued item.
    if accepted == nil or ignored == nil or accepted + ignored ~= 1 then
        return nil, "scrobble_response_invalid"
    end
    return accepted, ignored
end

function lastfm.queueItem(candidate)
    return {
        key = cleanTrackKey(candidate.key),
        artist = candidate.artist,
        title = candidate.title,
        album = candidate.album,
        album_artist = candidate.album_artist,
        track_number = candidate.track_number,
        mbid = candidate.mbid,
        lastfm_url = normalizeLastFmUrl(candidate.lastfm_url)
            or lastfm.trackUrl(candidate.artist, candidate.title),
        timestamp = math.floor(candidate.seen_ms / 1000),
        duration = candidate.duration_seconds,
    }
end

local function normalizeQueueItem(value)
    if type(value) ~= "table" then
        return nil
    end

    local fields = lastfm.trackRequestFields(value)
    local key = cleanTrackKey(value.key)
    local timestamp = numeric.nonNegativeInteger(value.timestamp)
    local duration = numeric.finite(value.duration)
    if fields == nil or key == "" or timestamp == nil then
        return nil
    end
    if duration ~= nil and (duration < 0 or duration > 86400) then
        return nil
    end

    return {
        key = key,
        artist = fields.artist,
        title = fields.track,
        album = fields.album,
        album_artist = fields.albumArtist,
        track_number = fields.trackNumber,
        mbid = fields.mbid,
        lastfm_url = normalizeLastFmUrl(value.lastfm_url)
            or lastfm.trackUrl(fields.artist, fields.track),
        timestamp = timestamp,
        duration = duration,
    }
end

function lastfm.normalizeQueue(value)
    if type(value) ~= "table" or value.schema ~= 1 or type(value.items) ~= "table" then
        return {}, "invalid"
    end

    local queue = {}
    local discarded = false
    for _, item in ipairs(value.items) do
        local normalized = normalizeQueueItem(item)
        if normalized ~= nil and #queue < lastfm.MAX_QUEUE then
            table.insert(queue, normalized)
        else
            discarded = true
        end
    end

    return queue, discarded and "discarded" or nil
end

function lastfm.queueEnvelope(account, queue)
    return {
        schema = 1,
        account = cleanText(account, 80),
        items = queue,
    }
end

function lastfm.defaultStatus()
    return {
        state = "waiting_for_radio",
        message = "waiting_for_radio_tellus",
        username = "",
        artist = "",
        title = "",
        current_validation = "",
        current_message = "",
        delivery_state = "none",
        delivery_message = "",
        delivery_artist = "",
        delivery_title = "",
        delivery_key = "",
        activity_state = "",
        activity_message = "",
        last_saved_artist = "",
        last_saved_title = "",
        last_saved_key = "",
        last_saved_url = "",
        last_saved_at = 0,
        scrobbled = 0,
        queued = 0,
        recent_scrobbles = {},
    }
end

function lastfm.normalizeStatus(value)
    local status = lastfm.defaultStatus()
    if type(value) ~= "table" then return status end
    status.state = validStates[value.state] and value.state or status.state
    status.message = cleanText(value.message, 200)
    status.username = cleanText(value.username, 80)
    status.artist = cleanText(value.artist, 160)
    status.title = cleanText(value.title, 160)
    status.current_validation = cleanText(value.current_validation, 24)
    status.current_message = cleanText(value.current_message, 120)
    status.delivery_state = cleanText(value.delivery_state, 24)
    status.delivery_message = cleanText(value.delivery_message, 120)
    status.delivery_artist = cleanText(value.delivery_artist, 160)
    status.delivery_title = cleanText(value.delivery_title, 160)
    status.delivery_key = cleanText(value.delivery_key, 360)
    status.activity_state = cleanText(value.activity_state, 24)
    status.activity_message = cleanText(value.activity_message, 120)
    status.last_saved_artist = cleanText(value.last_saved_artist, 160)
    status.last_saved_title = cleanText(value.last_saved_title, 160)
    status.last_saved_key = cleanText(value.last_saved_key, 360)
    status.last_saved_url = normalizeLastFmUrl(value.last_saved_url) or ""
    status.last_saved_at = numeric.nonNegativeInteger(value.last_saved_at) or 0
    status.scrobbled = lastfm.clampInteger(value.scrobbled, 0, 0, 1000000)
    status.queued = lastfm.clampInteger(value.queued, 0, 0, lastfm.MAX_QUEUE)
    status.recent_scrobbles = lastfm.normalizeRecentScrobbles(value.recent_scrobbles)
    return status
end

return lastfm
