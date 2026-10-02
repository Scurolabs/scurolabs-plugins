--!nonstrict
-- Last.fm orchestration owned by Radio Tellus' player-status entry.

local lastfm = require("./lastfm.luau")
local shared = require("./shared.luau")
local uiText = require("./ui.luau")
local numeric = require("./numeric-utils.luau")
local storage = require("./storage-utils.luau")
local Runtime = {}
Runtime.__index = Runtime

local MAX_NATIVE_HTTP_REQUESTS = 8
local REQUEST_TIMEOUT_MS = 30000
local OBSERVATION_DELTA_CAP_MS = 10000

local function nowMs()
    return numeric.floorOr(noctalia.nowMs(), 0)
end

local function normalizedTime(value)
    return numeric.floorOr(value, nowMs())
end

local function boundedTime(value, currentMs)
    local timestamp = numeric.finite(value)
    if timestamp == nil then return currentMs end
    return math.min(currentMs, math.max(0, math.floor(timestamp)))
end

local function hasNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function hasApiCredentials(credentials)
    return type(credentials) == "table"
        and hasNonEmptyString(credentials.api_key)
        and hasNonEmptyString(credentials.api_secret)
end

local function hasSession(credentials)
    return hasApiCredentials(credentials)
        and hasNonEmptyString(credentials.session_key)
        and hasNonEmptyString(credentials.username)
end

local function accountChanged(previous, current)
    local previousUsername = type(previous) == "table" and previous.username or nil
    local currentUsername = type(current) == "table" and current.username or nil
    return previousUsername ~= nil and currentUsername ~= nil
        and not lastfm.sameUsername(previousUsername, currentUsername)
end

local function logEvent(event, _track, detail)
    local fields = { "radio-tellus: lastfm event=" .. lastfm.singleLine(event, 48) }
    if detail ~= nil and detail ~= "" then
        table.insert(fields, "detail=" .. lastfm.singleLine(detail, 160))
    end
    noctalia.log(table.concat(fields, " "))
end

local function hasPendingRequest(runtime)
    return runtime.pending ~= nil or runtime.scrobble_pending ~= nil
end

local function isTrackRequest(kind)
    return kind == "validate" or kind == "now_playing"
end

local function nextRequestSerial(runtime)
    runtime.request_serial += 1
    return runtime.request_serial
end

local function nextAuthorizationGeneration(runtime)
    runtime.authorization_generation += 1
    return runtime.authorization_generation
end

local function activeRequest(runtime)
    if runtime.pending ~= nil then return "pending", runtime.pending end
    if runtime.scrobble_pending ~= nil then return "scrobble_pending", runtime.scrobble_pending end
    return nil, nil
end

local function currentMessage(candidate, playbackState)
    if candidate.delivery_state == "sending" or candidate.delivery_state == "queued"
        or candidate.delivery_state == "retrying" or candidate.delivery_state == "saved"
        or candidate.delivery_state == "filtered" or candidate.delivery_state == "rejected"
        or candidate.delivery_state == "queue_full" then
        return candidate.delivery_message
    end
    if candidate.validation_message ~= nil then return candidate.validation_message end
    if candidate.validation == "checking" then return "checking_track_with_lastfm" end
    if candidate.validation == "ready" then
        return candidate.duration_seconds == nil
            and "track_validated_waiting_for_unknown_duration_threshold"
            or "track_validated_waiting_for_scrobble_threshold"
    end
    if candidate.validation == "rejected" then return candidate.validation_error or "track_check_failed" end
    if playbackState == "paused" then return "playback_paused_waiting_for_confirmation" end
    return "waiting_for_stable_confirmed_metadata"
end

function Runtime.new()
    return setmetatable({
        credentials = {},
        credentials_loaded = false,
        credentials_loading = false,
        credential_load_waiters = {},
        credential_saving = false,
        credential_disconnect_pending = false,
        credential_removal_pending = false,
        credential_action_pending = nil,
        queue = {},
        queue_loaded = false,
        queue_account = "",
        queue_load_error = nil,
        queue_load_blocked = false,
        queue_retry_ms = 0,
        queue_persist_dirty = false,
        queue_persist_account = "",
        queue_persist_retry_ms = 0,
        last_queue_defer_key = "",
        account_delivery_suspended = false,
        recent_scrobbles = {},
        current = nil,
        pending_transition = nil,
        pending = nil,
        scrobble_pending = nil,
        native_requests = {},
        native_active = 0,
        request_serial = 0,
        occurrence_serial = 0,
        occurrence_runtime_id = lastfm.runtimeId(),
        next_retry_ms = 0,
        scrobbled_count = 0,
        last_activity = nil,
        last_saved = nil,
        last_published_key = "",
        auth_token = nil,
        authorization_generation = 0,
        authorization_previous_username = nil,
        playback_state = "stopped",
    }, Runtime)
end

function Runtime:publish(state, message, messageTrack)
    if type(messageTrack) == "table" then
        self.last_activity = {
            state = state,
            message = message,
            artist = messageTrack.artist or "",
            title = messageTrack.title or "",
            key = messageTrack.key or "",
        }
    end
    local value = lastfm.defaultStatus()
    value.state = state
    value.message = message
    value.username = self.credentials.username or ""
    value.queued = #self.queue
    value.scrobbled = self.scrobbled_count
    if self.current ~= nil then
        value.artist = self.current.artist or ""
        value.title = self.current.title or ""
        value.current_validation = self.current.validation or ""
        value.current_message = currentMessage(self.current, self.playback_state)
        value.delivery_state = self.current.delivery_state or "none"
        value.delivery_message = self.current.delivery_message or ""
    end
    if self.last_activity ~= nil then
        value.activity_state = self.last_activity.state or ""
        value.activity_message = self.last_activity.message or ""
        value.delivery_artist = self.last_activity.artist or ""
        value.delivery_title = self.last_activity.title or ""
        value.delivery_key = self.last_activity.key or ""
    end
    if self.last_saved ~= nil then
        value.last_saved_artist = self.last_saved.artist or ""
        value.last_saved_title = self.last_saved.title or ""
        value.last_saved_key = self.last_saved.key or ""
        value.last_saved_url = self.last_saved.lastfm_url or ""
        value.last_saved_at = self.last_saved.at or 0
    end
    value.recent_scrobbles = self.recent_scrobbles
    local key = table.concat({ value.state, value.message, value.username, value.artist, value.title,
        value.current_validation, value.current_message, value.delivery_state, value.delivery_message,
        value.activity_state, value.activity_message, value.delivery_artist, value.delivery_title,
        value.delivery_key, value.last_saved_artist, value.last_saved_title, value.last_saved_key,
        value.last_saved_url,
        tostring(value.last_saved_at), tostring(value.queued), tostring(value.scrobbled),
        tostring(#self.recent_scrobbles),
        self.recent_scrobbles[1] and self.recent_scrobbles[1].key or "",
        tostring(self.recent_scrobbles[1] and self.recent_scrobbles[1].at or 0) }, "\31")
    if key == self.last_published_key then return false end
    self.last_published_key = key
    noctalia.state.set(lastfm.STATUS_KEY, value)
    return true
end

function Runtime:clearQueuePersistenceState()
    self.queue_persist_dirty = false
    self.queue_persist_account = ""
    self.queue_persist_retry_ms = 0
end

function Runtime:markQueueDirty()
    -- Queue durability is tracked separately from delivery state. A queued
    -- track must remain retryable while its desired queue is not on disk.
    if self.queue_account == "" then
        self:clearQueuePersistenceState()
        return false
    end
    self.queue_persist_dirty = true
    self.queue_persist_account = self.queue_account
    self.queue_persist_retry_ms = 0
    return true
end

function Runtime:persistQueue(track)
    if not self.queue_loaded or self.queue_load_blocked then return false end
    local account = self.queue_account
    if account == "" then return false end
    if self.queue_persist_account ~= ""
        and not lastfm.sameUsername(self.queue_persist_account, account) then
        logEvent("queue_persist_blocked", track, "account_changed")
        return false
    end
    local saved = storage.writeJson(lastfm.SCROBBLE_QUEUE_FILE,
        lastfm.queueEnvelope(account, self.queue), lastfm.MAX_QUEUE_BYTES)
    if saved then
        self:clearQueuePersistenceState()
    else
        self.queue_persist_dirty = true
        self.queue_persist_account = account
        self.queue_persist_retry_ms = nowMs() + lastfm.retryIntervalMs()
        logEvent("queue_persist_failed", track, "storage_write_failed")
    end
    return saved
end

function Runtime:retryQueuePersistence(currentMs)
    if not self.queue_persist_dirty or not self.queue_loaded or self.queue_load_blocked
        or self.queue_account == "" then return false end
    if self.queue_persist_account == ""
        or not lastfm.sameUsername(self.queue_persist_account, self.queue_account) then
        logEvent("queue_persist_blocked", nil, "account_changed")
        return false
    end
    if currentMs < self.queue_persist_retry_ms then return false end
    -- Do not deliver a queue item while the persisted queue still reflects an
    -- older desired state. A restart must see the same queue we deliver.
    local saved = self:persistQueue()
    if saved and self.current ~= nil and self.current.delivery_state == "queued"
        and self.current.delivery_message == "lastfm_queue_persist_failed" then
        self:setCurrentDelivery(self.current, "queued", "song_queued_for_lastfm")
        self:publishCurrent()
    end
    return saved
end

function Runtime:loadQueueForAccount(force)
    if self.queue_loaded and self.queue_persist_dirty and force == true
        and self.queue_account ~= ""
        and lastfm.sameUsername(self.queue_account, self.credentials.username) then
        self:persistQueue()
        return true
    end
    if self.queue_loaded and force ~= true then return true end
    if self.queue_load_blocked then
        self.queue_load_error = "queue_clear_failed"
        self.queue_retry_ms = 0
        logEvent("queue_load_blocked", nil, "previous_queue_clear_failed")
        return false
    end
    if not hasSession(self.credentials) then
        if not self.queue_persist_dirty then self.queue_loaded = false end
        self.queue_retry_ms = 0
        logEvent("queue_waiting_for_session")
        return false
    end

    local raw, readError = storage.readJson(lastfm.SCROBBLE_QUEUE_FILE, lastfm.MAX_QUEUE_BYTES)
    self.queue_account = self.credentials.username or ""
    self.queue_load_error = nil
    if raw == nil and readError == "missing" then
        self.queue = {}
        self.queue_loaded = true
        self:clearQueuePersistenceState()
        self.queue_retry_ms = 0
        self.last_queue_defer_key = ""
        logEvent("queue_loaded", nil, "count=0 source=empty")
        return true
    end
    if raw == nil then
        self.queue_loaded = false
        self.queue_load_error = readError or "invalid"
        self.queue_retry_ms = nowMs() + lastfm.retryIntervalMs()
        logEvent("queue_load_failed", nil, self.queue_load_error)
        return false
    end
    if type(raw) ~= "table" then
        self.queue_loaded = false
        self.queue_load_error = "invalid"
        self.queue_retry_ms = nowMs() + lastfm.retryIntervalMs()
        logEvent("queue_load_failed", nil, self.queue_load_error)
        return false
    end
    if not lastfm.sameUsername(raw.account, self.credentials.username) then
        self.queue = {}
        self.queue_loaded = true
        self:clearQueuePersistenceState()
        self.queue_retry_ms = 0
        self.last_queue_defer_key = ""
        logEvent("queue_account_mismatch", nil, "discarded_saved_items")
        self:persistQueue()
        return true
    end

    local queue, normalizeError = lastfm.normalizeQueue(raw)
    self.queue = queue
    self.queue_loaded = true
    self:clearQueuePersistenceState()
    self.queue_retry_ms = 0
    self.last_queue_defer_key = ""
    if normalizeError ~= nil then
        self.queue_load_error = normalizeError
        logEvent("queue_items_discarded", nil, normalizeError)
        self:persistQueue()
    end
    logEvent("queue_loaded", nil, "count=" .. tostring(#self.queue))
    return true
end

function Runtime:setCurrentDelivery(candidate, state, message)
    if candidate == nil then return end
    candidate.delivery_state = state
    candidate.delivery_message = message or ""
end

function Runtime:setCurrentDeliveryForItem(item, state, message)
    if self.current ~= nil and item ~= nil and self.current.key == item.key then
        self:setCurrentDelivery(self.current, state, message)
    end
end

function Runtime:markSaved(item)
    self.last_saved = {
        artist = item.artist or "",
        title = item.title or "",
        key = item.key or "",
        lastfm_url = item.lastfm_url or lastfm.trackUrl(item.artist, item.title),
        at = nowMs(),
    }
    local recent = lastfm.normalizeRecentScrobble(self.last_saved)
    if recent ~= nil then
        table.insert(self.recent_scrobbles, 1, recent)
        while #self.recent_scrobbles > lastfm.MAX_RECENT_SCROBBLES do
            table.remove(self.recent_scrobbles)
        end
    end
    self.last_activity = {
        state = "ready",
        message = "scrobble_accepted",
        artist = item.artist or "",
        title = item.title or "",
        key = item.key or "",
    }
    if self.current ~= nil and self.current.key == item.key then
        self:setCurrentDelivery(self.current, "saved", "scrobble_accepted")
    end
end

function Runtime:sourceStatus(message)
    if self.credentials_loading then
        self:publish("checking", "loading_lastfm_credentials")
    elseif self.credential_disconnect_pending then
        self:publish("checking", "removing_lastfm_credentials")
    elseif self.credential_removal_pending then
        self:publish("error", "lastfm_credentials_could_not_be_removed")
    elseif self.credential_saving then
        self:publish("checking", "saving_lastfm_credentials")
    elseif not hasApiCredentials(self.credentials) then
        self:publish("disconnected", "connect_lastfm_account")
    elseif not hasSession(self.credentials) then
        self:publish("disconnected", "lastfm_authorization_required")
    else
        self:publish("waiting_for_radio", message or "waiting_for_radio_tellus")
    end
end

function Runtime:finishCredentialLoad(ok, err)
    local waiters = self.credential_load_waiters
    self.credential_load_waiters = {}
    for _, callback in ipairs(waiters) do callback(ok, err) end
end

function Runtime:reloadCredentials(callback, force)
    if type(callback) ~= "function" then return false, "callback_required" end
    if self.credential_saving then return false, "credential_save_in_progress" end
    if self.credentials_loaded and force ~= true then
        callback(true)
        return true
    end
    table.insert(self.credential_load_waiters, callback)
    if self.credentials_loading then return true end

    local hadLoadedCredentials = self.credentials_loaded
    local previousKey = self.credentials.api_key
    local previousSecret = self.credentials.api_secret
    local previousSession = self.credentials.session_key
    local previousUsername = self.credentials.username
    self.credentials_loading = true
    local completed = false
    local function complete(credentials, credentialError)
        if completed then return end
        completed = true
        self.credentials_loading = false
        if self.credential_disconnect_pending then
            self.credentials = {}
            self.credential_action_pending = nil
            self:finishCredentialLoad(false, "disconnected")
            self:completeDisconnect()
            return
        end
        if credentials == nil then
            noctalia.log("radio-tellus: could not reload Last.fm credentials: " .. tostring(credentialError))
            self.credential_action_pending = nil
            self:finishCredentialLoad(false, credentialError)
            return
        end
        self.credentials = credentials
        self.credentials_loaded = true
        local credentialsChanged = self.credentials.api_key ~= previousKey
            or self.credentials.api_secret ~= previousSecret
            or self.credentials.session_key ~= previousSession
            or self.credentials.username ~= previousUsername
        local identityChanged = accountChanged({ username = previousUsername }, self.credentials)
        local apiCredentialsChanged = self.credentials.api_key ~= previousKey
            or self.credentials.api_secret ~= previousSecret
        if credentialsChanged and hadLoadedCredentials then
            self:invalidateAuthorization()
            self:resetAccountBoundState(identityChanged or apiCredentialsChanged, apiCredentialsChanged)
        end
        self:loadQueueForAccount()
        logEvent("credentials_loaded", nil, self.credentials.username ~= nil
            and "session_present" or "session_missing")
        self:finishCredentialLoad(true)
        self:runDeferredCredentialAction()
    end
    local started = lastfm.loadCredentials(complete)
    if not started and not completed then complete(nil, "credential_load_not_started") end
    if not started then return false, "credential_load_not_started" end
    return true
end

function Runtime:saveCredentials(value, callback)
    if self.credential_saving then return false end
    if type(callback) ~= "function" then return false end
    self.credential_saving = true
    local completed = false
    local function complete(saved, err, credentials)
        if completed then return end
        completed = true
        self.credential_saving = false
        local disconnectPending = self.credential_disconnect_pending
        self.credential_disconnect_pending = false
        if disconnectPending then
            -- Disconnect invalidated this save. Complete persistent cleanup
            -- before suppressing the save/authorization continuation so it
            -- cannot open a browser or announce a new authorization state.
            self:disconnect()
            return
        end
        if saved and credentials ~= nil then
            local identityChanged = accountChanged(self.credentials, credentials)
            local apiCredentialsChanged = self.credentials.api_key ~= credentials.api_key
                or self.credentials.api_secret ~= credentials.api_secret
            local credentialsChanged = apiCredentialsChanged
                or self.credentials.session_key ~= credentials.session_key
                or self.credentials.username ~= credentials.username
            self.credentials = credentials
            self.credentials_loaded = true
            if credentialsChanged then
                self:resetAccountBoundState(identityChanged or apiCredentialsChanged, apiCredentialsChanged)
            end
            self:loadQueueForAccount()
        end
        callback(saved, err)
        self:runDeferredCredentialAction()
    end
    local started = lastfm.saveCredentials(value, complete)
    if not started and not completed then self.credential_saving = false end
    return started
end

function Runtime:completeDisconnect()
    self.credential_disconnect_pending = false
    self.credential_action_pending = nil
    local queueCleared, queueError = lastfm.clearScrobbleQueue()
    if not queueCleared then
        noctalia.log("radio-tellus: could not remove Last.fm queued songs: " .. tostring(queueError))
        self:publish("error", "lastfm_queue_could_not_be_removed")
        self:notifyError("Could not remove songs waiting to be sent to Last.fm. Try again.", queueError)
        return false
    end
    local cleared, err = lastfm.clearCredentials()
    if not cleared then
        noctalia.log("radio-tellus: could not remove Last.fm credentials: " .. tostring(err))
        self:publish("error", "lastfm_credentials_could_not_be_removed")
        self:notifyError("Could not remove the saved Last.fm settings. Try again.", err)
        return false
    end
    self.credentials = {}
    self.credentials_loaded = true
    self.queue = {}
    self.queue_loaded = false
    self.queue_account = ""
    self.queue_load_blocked = false
    self:clearQueuePersistenceState()
    self.credential_removal_pending = false
    self.account_delivery_suspended = false
    self.recent_scrobbles = {}
    self.last_activity = nil
    self.last_saved = nil
    self.scrobbled_count = 0
    self:publish("disconnected", "lastfm_account_disconnected")
    return true
end

function Runtime:runDeferredCredentialAction()
    local action = self.credential_action_pending
    self.credential_action_pending = nil
    if action == lastfm.actions.refresh then self:refresh()
    elseif action == lastfm.actions.credentialsChanged then self:credentialsChanged()
    elseif action == lastfm.actions.authorize then self:beginAuthorization()
    elseif action == lastfm.actions.finishAuthorization then self:finishAuthorization() end
end

function Runtime:invalidateAuthorization()
    nextAuthorizationGeneration(self)
    self.auth_token = nil
    self.authorization_previous_username = nil
end

local function isHttpUrl(value)
    return type(value) == "string"
        and (value:match("^https://") ~= nil or value:match("^http://") ~= nil)
end

local function friendlyNotificationDetail(detail)
    if type(detail) ~= "string" or detail == "" then return nil end
    if isHttpUrl(detail) then return detail end
    if detail == "network_failure" then return "Check your internet connection and try again." end
    if detail == "response_invalid" then return "Last.fm sent an unexpected reply. Try again later." end
    if detail:match("^lastfm_%d+:") then
        return "Last.fm did not accept the request. Try again later."
    end
    if detail == "The Last.fm API key does not look valid." then return detail end
    return nil
end

function Runtime:notifyError(title, detail)
    if type(detail) == "string" and detail ~= "" and not isHttpUrl(detail) then
        noctalia.log("radio-tellus: Last.fm user action failed: " .. detail)
    end
    local hint = friendlyNotificationDetail(detail)
    local translatedHint = hint and uiText.literal(hint) or nil
    local message = uiText.literal(title) .. (translatedHint and ("\n" .. translatedHint) or "")
    uiText.notify("Tellus Scrobbler", message, true)
end

function Runtime:requireReauthorization(messageTrack)
    nextAuthorizationGeneration(self)
    self.authorization_previous_username = self.credentials.username
        or self.authorization_previous_username
    self.auth_token = nil
    self.credentials.session_key = nil
    self.credentials.username = nil
    self:saveCredentials(self.credentials, function(saved, err)
        if not saved then
            noctalia.log("radio-tellus: could not clear invalid Last.fm session: " .. tostring(err))
        end
    end)
    self:publish("disconnected", "lastfm_session_invalid_reauthorize", messageTrack)
end

function Runtime:cancelPending()
    local canceledTrackRequest = self.pending
    if hasPendingRequest(self) then
        nextRequestSerial(self)
        self.pending = nil
        self.scrobble_pending = nil
    end
    if canceledTrackRequest ~= nil and canceledTrackRequest.kind == "validate"
        and self.current ~= nil and canceledTrackRequest.candidate_key == self.current.key then
        self.current.validation = "waiting"
        self.current.validation_message = nil
        self.current.next_validation_ms = nowMs()
    end
end

function Runtime:cancelTrackRequest()
    if self.pending ~= nil and isTrackRequest(self.pending.kind) then
        nextRequestSerial(self)
        self.pending = nil
    end
end

function Runtime:resetAccountBoundState(clearQueue, clearActivity)
    self:cancelPending()
    if clearQueue then
        local cleared, clearError = lastfm.clearScrobbleQueue()
        self.queue = {}
        self.queue_loaded = false
        self.queue_account = ""
        self.queue_load_error = nil
        self.queue_load_blocked = not cleared
        self:clearQueuePersistenceState()
        if not cleared then
            logEvent("queue_clear_failed", nil, "account_state_changed")
            noctalia.log("radio-tellus: could not clear Last.fm queued songs during account change: "
                .. tostring(clearError))
        end
    end
    if clearActivity then
        self.last_activity = nil
        self.last_saved = nil
        self.recent_scrobbles = {}
    end
    self.next_retry_ms = 0
    self.scrobbled_count = 0
    if self.current ~= nil then
        local resetMs = nowMs()
        self.current.artist = self.current.source_artist or self.current.artist
        self.current.title = self.current.source_title or self.current.title
        self.current.seen_ms = resetMs
        self.current.played_ms = 0
        self.current.last_observation_ms = resetMs
        self.current.last_player_state = self.playback_state
        self.current.validation = "waiting"
        self.current.validation_message = nil
        self.current.next_validation_ms = nowMs()
        self.current.album = nil
        self.current.album_artist = nil
        self.current.track_number = nil
        self.current.mbid = nil
        self.current.lastfm_url = nil
        self.current.duration_seconds = nil
        self.current.threshold_seconds = nil
        self.current.validation_error = nil
        self.current.delivery_state = "none"
        self.current.delivery_message = ""
        self.current.now_playing_attempted = false
    end
    self.pending_transition = nil
end

function Runtime:startHttp(kind, parameters, callback, candidateKey, statusTrack)
    local pendingField = kind == "scrobble" and "scrobble_pending" or "pending"
    if self[pendingField] ~= nil or self.native_active >= MAX_NATIVE_HTTP_REQUESTS then
        if self.native_active >= MAX_NATIVE_HTTP_REQUESTS then
            logEvent("request_start_throttled", statusTrack, "native_http_limit")
        end
        return false
    end
    local serial = nextRequestSerial(self)
    local request = {
        kind = kind,
        serial = serial,
        started_ms = nowMs(),
        candidate_key = candidateKey,
        status_track = statusTrack,
    }
    self[pendingField] = request
    self.native_requests[serial] = request
    self.native_active += 1
    local function completeNative(response)
        if self.native_requests[serial] ~= request then return end
        self.native_requests[serial] = nil
        self.native_active = math.max(0, self.native_active - 1)
        if self[pendingField] == nil or self[pendingField].serial ~= serial then
            logEvent("stale_callback_ignored", statusTrack, kind)
            return
        end
        self[pendingField] = nil
        callback(response)
    end
    local accepted = shared.httpBounded(lastfm.httpRequest(parameters), lastfm.MAX_RESPONSE_BYTES, completeNative)
    if not accepted then
        self.native_requests[serial] = nil
        self.native_active = math.max(0, self.native_active - 1)
        self[pendingField] = nil
        logEvent("request_start_failed", statusTrack, kind)
        callback(nil)
        return false
    end
    return true
end

function Runtime:requestExpired(currentMs)
    local pendingField, pending = activeRequest(self)
    if pending == nil or currentMs - pending.started_ms < REQUEST_TIMEOUT_MS then return false end
    local kind = pending.kind
    nextRequestSerial(self)
    -- Logical timeout only. The ordinary Noctalia HTTP request remains counted
    -- in native_active until its host callback arrives.
    self[pendingField] = nil
    if kind == "scrobble" then
        self.next_retry_ms = currentMs + lastfm.retryIntervalMs()
        if self.current ~= nil and pending.status_track ~= nil
            and self.current.key == pending.status_track.key then
            self:setCurrentDeliveryForItem(pending.status_track, "retrying", "lastfm_request_timed_out")
        end
        logEvent("scrobble_timeout", pending.status_track, "queued_item_retained")
        self:publish("error", "lastfm_request_timed_out; queued scrobble retained", pending.status_track)
    elseif kind == "validate" and self.current ~= nil and pending.candidate_key == self.current.key then
        self.current.validation = "waiting"
        self.current.validation_message = "lastfm_validation_timed_out"
        self.current.next_validation_ms = currentMs + lastfm.retryIntervalMs()
        logEvent("validation_timeout", self.current)
        self:publish("error", "lastfm_validation_timed_out")
    elseif kind == "validate" then
        -- A candidate that ends during validation cannot publish a timeout for
        -- the replacement track.
    elseif kind == "now_playing" and self.current ~= nil and pending.candidate_key == self.current.key then
        -- Last.fm explicitly requires failed Now Playing requests to remain one-shot.
        logEvent("now_playing_timeout", self.current)
        self:publish("error", "lastfm_now_playing_timed_out")
    elseif kind == "now_playing" then
        -- A track that ends during the one-shot request cannot publish a timeout
        -- for the replacement track.
    else
        self:publish("error", "lastfm_request_timed_out")
    end
    return true
end

function Runtime:beginAuthorization()
    if hasPendingRequest(self) or self.credential_saving then return false end
    if self.account_delivery_suspended then
        self.credential_action_pending = lastfm.actions.authorize
        return self:credentialsChanged()
    end
    if self.credentials_loading then
        self.credential_action_pending = lastfm.actions.authorize
        return true
    end
    return self:reloadCredentials(function(reloaded, credentialError)
        if not reloaded then
            self:publish("error", "lastfm_credentials_could_not_be_loaded")
            self:notifyError("Could not read the saved Last.fm settings. Try saving them again.", credentialError)
            return
        end
        if not hasApiCredentials(self.credentials) then
            self:publish("error", "api_credentials_required")
            self:notifyError("Enter the Last.fm API key and shared secret first.")
            return
        end

        local authorizationGeneration = nextAuthorizationGeneration(self)
        self.authorization_previous_username = self.credentials.username
            or self.authorization_previous_username
        self.auth_token = nil
        self:publish("authorizing", "requesting_lastfm_token")
        local parameters = lastfm.requestParameters("auth.getToken", {}, self.credentials, false)
        self:startHttp("authorize", parameters, function(response)
            if self.authorization_generation ~= authorizationGeneration then return end
            local decoded, err = lastfm.parseApiResponse(response)
            local token = decoded and lastfm.cleanSecret(decoded.token, 512) or nil
            if token == nil then
                self:publish("error", err or "authorization_token_missing")
                self:notifyError("Last.fm authorization could not be started. Check your Last.fm details and try again.", err)
                return
            end
            self.auth_token = token
            self.credentials.session_key = nil
            self.credentials.username = nil
            self:saveCredentials(self.credentials, function(saved, saveError)
                if self.authorization_generation ~= authorizationGeneration
                    or self.auth_token ~= token then return end
                if not saved then
                    self.auth_token = nil
                    self:publish("error", "credentials_could_not_be_saved")
                    self:notifyError("Could not prepare Last.fm authorization. Try again.", saveError)
                    return
                end
                local url = lastfm.authorizationUrl(self.credentials.api_key, token)
                local browserCompleted = false
                local function finishBrowserLaunch(result)
                    if browserCompleted then return end
                    browserCompleted = true
                    if self.authorization_generation ~= authorizationGeneration
                        or self.auth_token ~= token then return end
                    if type(result) ~= "table" or result.exitCode ~= 0 then
                        self.auth_token = nil
                        self:publish("error", "browser_could_not_be_opened")
                        self:notifyError("Could not open Last.fm in your browser. Try authorization again.")
                        return
                    end
                    self:publish("authorization_ready", "approve_access_in_lastfm_then_finish")
                    uiText.notify("Tellus Scrobbler", "Approve access in Last.fm, then choose Finish authorization.")
                end
                local started = noctalia.runAsync({ "/usr/bin/xdg-open", url }, finishBrowserLaunch)
                if not started then
                    finishBrowserLaunch(nil)
                end
            end)
        end)
    end)
end

function Runtime:finishAuthorization()
    if hasPendingRequest(self) or self.credential_saving then return false end
    if self.account_delivery_suspended then
        self.credential_action_pending = lastfm.actions.finishAuthorization
        return self:credentialsChanged()
    end
    if self.credentials_loading then
        self.credential_action_pending = lastfm.actions.finishAuthorization
        return true
    end
    if not hasApiCredentials(self.credentials) or self.auth_token == nil then
        self:publish("error", "authorization_token_missing")
        self:notifyError("Start authorization first, then approve access in Last.fm.")
        return false
    end

    nextAuthorizationGeneration(self)
    self:publish("authorizing", "requesting_lastfm_session")
    local parameters = lastfm.requestParameters("auth.getSession", { token = self.auth_token }, self.credentials, false)
    return self:startHttp("finish_authorization", parameters, function(response)
        local decoded, err = lastfm.parseApiResponse(response)
        local session = decoded and type(decoded.session) == "table" and decoded.session or nil
        local key = session and lastfm.cleanSecret(session.key, 512) or nil
        local username = session and type(session.name) == "string"
            and lastfm.singleLine(session.name, 80) or nil
        if not decoded or key == nil or username == nil or username == "" then
            self:publish("error", err or "lastfm_session_missing")
            self:notifyError("Last.fm authorization did not complete. Try again.", err)
            return
        end
        local previousUsername = self.authorization_previous_username
        local accountChanged = previousUsername ~= nil and not lastfm.sameUsername(previousUsername, username)
        self.authorization_previous_username = nil
        self.credentials.session_key = key
        self.credentials.username = username
        self.auth_token = nil
        if accountChanged then self:resetAccountBoundState(true, true) end
        self:saveCredentials(self.credentials, function(saved, saveError)
            if not saved then
                self.credentials.session_key = nil
                self.credentials.username = nil
                self:publish("error", "credentials_could_not_be_saved")
                self:notifyError("Last.fm could not finish connecting this account. Try again.", saveError)
                return
            end
            self:loadQueueForAccount(true)
            logEvent("authorization_completed")
            self:publish("waiting_for_radio", "lastfm_connected_waiting_for_radio_tellus")
            uiText.notify("Tellus Scrobbler", uiText.tr("lastfm.connected_as", { username = username }))
            self:tick(nowMs())
        end)
    end)
end

function Runtime:disconnect()
    -- Invalidate the live account before any persistent deletion can fail. A
    -- failed cleanup must never leave the old session eligible for delivery.
    self.account_delivery_suspended = true
    self.credential_removal_pending = true
    nextAuthorizationGeneration(self)
    self:cancelPending()
    self.current = nil
    self.auth_token = nil
    self.authorization_previous_username = nil
    self.credentials = {}
    self.credentials_loaded = true
    self.queue = {}
    self.queue_loaded = false
    self.queue_account = ""
    self.queue_load_error = nil
    if self.credentials_loading or self.credential_saving then
        self.credential_action_pending = nil
        self.credential_disconnect_pending = true
        self:publish("checking", "removing_lastfm_credentials")
        return
    end
    self:completeDisconnect()
end

function Runtime:applyValidatedTrack(candidate, checked)
    candidate.validation = "ready"
    candidate.validation_error = nil
    candidate.artist = checked.artist
    candidate.title = checked.title
    candidate.album = checked.album
    candidate.album_artist = checked.album_artist
    candidate.track_number = checked.track_number
    candidate.mbid = checked.mbid
    candidate.lastfm_url = checked.lastfm_url
    candidate.duration_seconds = checked.duration_seconds
    candidate.threshold_seconds = lastfm.scrobbleThresholdSeconds(checked.duration_seconds)
    candidate.next_validation_ms = 0
    candidate.validation_message = nil
    logEvent("track_verified", candidate)
    self:publish("ready", checked.duration_seconds == nil
        and "track_validated_waiting_for_unknown_duration_threshold"
        or "track_validated_waiting_for_scrobble_threshold")
end

function Runtime:handleValidationFailure(candidate, errorMessage, retryable, fallbackError)
    if retryable then
        candidate.validation = "waiting"
        candidate.validation_message = "lastfm_track_check_failed; will retry"
        candidate.next_validation_ms = nowMs() + lastfm.retryIntervalMs()
        logEvent("validation_retry_scheduled", candidate, errorMessage or fallbackError)
        self:publish("error", "lastfm_track_check_failed; will retry")
    else
        candidate.validation = "rejected"
        candidate.validation_error = errorMessage or fallbackError
        logEvent("validation_rejected", candidate, candidate.validation_error)
        self:publish("error", candidate.validation_error)
    end
end

function Runtime:startTrackValidation(candidate)
    if self.pending ~= nil or not hasApiCredentials(self.credentials) then return false end
    candidate.validation = "checking"
    candidate.validation_message = nil
    logEvent("validation_requested", candidate)
    self:publish("checking", "checking_track_with_lastfm")
    local lookupCandidate = { artist = candidate.artist, title = candidate.title }
    local trackFields = lastfm.trackRequestFields(lookupCandidate)
    if trackFields == nil then
        candidate.validation = "rejected"
        candidate.validation_error = "track_metadata_invalid"
        logEvent("validation_rejected", candidate, candidate.validation_error)
        self:publish("error", candidate.validation_error)
        return false
    end
    trackFields.autocorrect = 0
    local parameters = lastfm.requestParameters("track.getInfo", trackFields, self.credentials, false)
    local started = self:startHttp("validate", parameters, function(response)
        if self.current == nil or self.current.key ~= candidate.key then return end
        local decoded, err = lastfm.parseApiResponse(response)
        if not decoded then
            logEvent("validation_failed", candidate, err)
            self:handleValidationFailure(candidate, err, lastfm.retryableError(err), "track_check_failed")
            return
        end
        local checked, checkError = lastfm.exactLastFmTrack(decoded, lookupCandidate)
        if not checked then
            logEvent("validation_rejected", candidate, checkError)
            self:handleValidationFailure(candidate, checkError, false, "track_metadata_not_confirmed_by_lastfm")
            return
        end

        self:applyValidatedTrack(candidate, checked)
    end, candidate.key)
    if not started and candidate.validation == "checking" then
        self:handleValidationFailure(candidate, "request_start_throttled", true, "track_check_failed")
    end
    return started
end

function Runtime:startNowPlaying(candidate)
    if self.pending ~= nil or candidate.now_playing_attempted or not hasSession(self.credentials) then return false end
    local parameters = lastfm.trackRequestFields(candidate)
    if parameters == nil then return false end
    candidate.now_playing_attempted = true
    logEvent("now_playing_requested", candidate)
    parameters.duration = candidate.duration_seconds and math.floor(candidate.duration_seconds) or nil
    parameters = lastfm.requestParameters("track.updateNowPlaying", parameters, self.credentials, true)
    return self:startHttp("now_playing", parameters, function(response)
        local decoded, err = lastfm.parseApiResponse(response)
        if not decoded and lastfm.errorCode(err) == 9 then
            logEvent("now_playing_reauthorization_required", candidate, err)
            self:requireReauthorization()
        elseif not decoded then
            logEvent("now_playing_failed", candidate, err)
            noctalia.log("radio-tellus: Last.fm Now Playing rejected: " .. tostring(err))
        elseif decoded and self.current ~= nil and self.current.key == candidate.key then
            local accepted, responseError = lastfm.nowPlayingResult(decoded)
            if not accepted then
                logEvent("now_playing_response_invalid", candidate, responseError)
                noctalia.log("radio-tellus: Last.fm Now Playing response invalid: " .. tostring(responseError))
            else
                logEvent("now_playing_sent", candidate)
                self:publish("ready", "lastfm_now_playing_sent")
            end
        end
    end, candidate.key, candidate)
end

function Runtime:removeFirstQueueItem()
    local item = table.remove(self.queue, 1)
    if item ~= nil then
        self:markQueueDirty()
        self:persistQueue(item)
    end
    return item
end

function Runtime:startQueuedScrobble(currentMs)
    if not self.queue_loaded or self.queue_load_blocked
        or self.queue_persist_dirty or hasPendingRequest(self)
        or not hasSession(self.credentials) or #self.queue == 0
        or currentMs < self.next_retry_ms then return false end
    local item = self.queue[1]
    local trackFields = lastfm.trackRequestFields(item)
    if trackFields == nil then
        self:removeFirstQueueItem()
        self:setCurrentDeliveryForItem(item, "rejected", "scrobble_metadata_invalid")
        logEvent("scrobble_rejected", item, "scrobble_metadata_invalid")
        self:publish("error", "scrobble_metadata_invalid", item)
        return false
    end
    trackFields.timestamp = item.timestamp
    trackFields.duration = item.duration and math.floor(item.duration) or nil
    trackFields.chosenByUser = 0
    local parameters = lastfm.requestParameters("track.scrobble", trackFields, self.credentials, true)
    if self.current ~= nil and self.current.key == item.key then
        self:setCurrentDelivery(self.current, "sending", "sending_queued_scrobble")
    end
    logEvent("scrobble_requested", item)
    self:publish("queued", "sending_queued_scrobble", item)
    return self:startHttp("scrobble", parameters, function(response)
        local decoded, err = lastfm.parseApiResponse(response)
        if not decoded then
            if lastfm.errorCode(err) == 9 then
                self:setCurrentDeliveryForItem(item, "retrying", "lastfm_session_invalid_reauthorize")
                logEvent("scrobble_reauthorization_required", item, err)
                self:requireReauthorization(item)
            elseif lastfm.retryableError(err) then
                self.next_retry_ms = nowMs() + lastfm.retryIntervalMs()
                self:setCurrentDeliveryForItem(item, "retrying", "scrobble_failed; queued item retained")
                logEvent("scrobble_retry_scheduled", item, err)
                self:publish("error", "scrobble_failed; queued item retained", item)
            else
                self:removeFirstQueueItem()
                self:setCurrentDeliveryForItem(item, "rejected", "scrobble_rejected; queued item discarded")
                logEvent("scrobble_rejected", item, err)
                self:publish("error", "scrobble_rejected; queued item discarded", item)
            end
            return
        end

        local accepted, ignored = lastfm.scrobbleResult(decoded)
        if accepted == nil then
            self.next_retry_ms = nowMs() + lastfm.retryIntervalMs()
            self:setCurrentDeliveryForItem(item, "retrying", "lastfm_scrobble_response_invalid; queued item retained")
            logEvent("scrobble_response_invalid", item, "queued_item_retained")
            self:publish("error", "lastfm_scrobble_response_invalid; queued item retained", item)
            return
        end
        self:removeFirstQueueItem()
        if accepted > 0 and ignored == 0 then
            self.scrobbled_count += accepted
            self:markSaved(item)
            logEvent("scrobble_saved", item)
            self:publishCurrent()
        else
            -- API success can still mean Last.fm filtered the submitted item.
            self:setCurrentDeliveryForItem(item, "filtered", "lastfm_filtered_track_not_scrobbled")
            logEvent("scrobble_filtered", item)
            self:publish("error", "lastfm_filtered_track_not_scrobbled", item)
        end
    end, item.key, item)
end

function Runtime:queueCurrent(candidate)
    if not self.queue_loaded or self.queue_load_blocked then
        local deferKey = tostring(candidate.key or candidate.metadata_key or "")
        if self.last_queue_defer_key ~= deferKey then
            self.last_queue_defer_key = deferKey
            logEvent("scrobble_deferred", candidate, "queue_not_loaded")
        end
        return false
    end
    if candidate.delivery_state == "queue_full" then
        if #self.queue >= lastfm.MAX_QUEUE then
            self:publish("error", "scrobble_queue_full", candidate)
            return false
        end
        self:setCurrentDelivery(candidate, "none", "")
    end
    if candidate.delivery_state ~= nil and candidate.delivery_state ~= "none" then return false end
    if candidate.validation ~= "ready" then return false end
    if not hasSession(self.credentials) then
        logEvent("scrobble_deferred", candidate, "session_missing")
        return false
    end
    if candidate.threshold_seconds == nil then return false end
    if candidate.duration_seconds == nil then
        if candidate.played_ms / 1000 <= candidate.threshold_seconds then return false end
    elseif candidate.played_ms / 1000 < candidate.threshold_seconds then
        return false
    end
    if #self.queue >= lastfm.MAX_QUEUE then
        self:setCurrentDelivery(candidate, "queue_full", "scrobble_queue_full")
        self:publish("error", "scrobble_queue_full", candidate)
        return false
    end
    table.insert(self.queue, lastfm.queueItem(candidate))
    self:markQueueDirty()
    self:setCurrentDelivery(candidate, "queued", "song_queued_for_lastfm")
    local persisted = self:persistQueue(candidate)
    local message = persisted and "song_queued_for_lastfm" or "lastfm_queue_persist_failed"
    logEvent("scrobble_queued", candidate)
    self:setCurrentDelivery(candidate, "queued", message)
    self:publish(persisted and "queued" or "error", message, candidate)
    return true
end

function Runtime:advanceCandidate(candidate, playerState, currentMs)
    if candidate.last_observation_ms ~= nil then
        local previousMs = candidate.last_observation_ms
        if currentMs < previousMs then return false end
        local delta = math.min(OBSERVATION_DELTA_CAP_MS, currentMs - previousMs)
        if candidate.last_player_state == "playing" then candidate.played_ms += delta end
    end
    candidate.last_observation_ms = currentMs
    candidate.last_player_state = playerState
    return true
end

function Runtime:reconcilePlaybackState(playerState, boundaryMs, currentMs, generation)
    if playerState ~= "playing" and playerState ~= "paused" then return false end
    boundaryMs = normalizedTime(boundaryMs)
    currentMs = normalizedTime(currentMs)
    if self.current == nil then return false end
    if generation ~= nil and tostring(generation) ~= ""
        and tostring(generation) ~= tostring(self.current.generation or "") then return false end
    if self.current.last_observation_ms == nil
        or boundaryMs >= self.current.last_observation_ms then
        if not self:advanceCandidate(self.current, playerState, boundaryMs) then return false end
    else
        -- Preserve a newer observation timestamp while replacing its state
        -- with the confirmed result of the control command.
        self.current.last_player_state = playerState
    end
    self.playback_state = playerState
    self:tick(math.max(currentMs, self.current.last_observation_ms or currentMs))
    return true
end

function Runtime:finishCurrent(currentMs, discard)
    self:cancelTrackRequest()
    if self.current == nil then return end
    currentMs = normalizedTime(currentMs)
    currentMs = math.max(currentMs, self.current.last_observation_ms or currentMs)
    self:advanceCandidate(self.current, "paused", currentMs)
    if not discard then self:queueCurrent(self.current) end
    self.current = nil
end

function Runtime:publishCurrent()
    -- Reopening the panel refreshes the service while preserving the desktop
    -- auth flow. Its token remains valid only in this service VM.
    if self.credentials_loading then
        self:publish("checking", "loading_lastfm_credentials")
        return
    elseif self.credential_disconnect_pending then
        self:publish("checking", "removing_lastfm_credentials")
        return
    elseif self.credential_saving then
        self:publish("checking", "saving_lastfm_credentials")
        return
    elseif self.credential_removal_pending then
        self:publish("error", "lastfm_credentials_could_not_be_removed")
        return
    elseif self.account_delivery_suspended then
        self:publish("error", "lastfm_credentials_could_not_be_loaded")
        return
    elseif self.pending ~= nil then
        if self.pending.kind == "authorize" then
            self:publish("authorizing", "requesting_lastfm_token")
            return
        elseif self.pending.kind == "finish_authorization" then
            self:publish("authorizing", "requesting_lastfm_session")
            return
        end
    elseif self.auth_token ~= nil then
        self:publish("authorization_ready", "approve_access_in_lastfm_then_finish")
        return
    elseif self.pending_transition ~= nil then
        -- The last published status remains stable until the replacement
        -- generation is confirmed, preventing station startup from overwriting
        -- a scrobble completion that may arrive during the transition.
        return
    elseif self.scrobble_pending ~= nil then
        self:publish("queued", "sending_queued_scrobble", self.scrobble_pending.status_track)
        return
    end
    if not hasApiCredentials(self.credentials) or not hasSession(self.credentials) then
        self:sourceStatus()
    elseif self.current == nil then
        self:sourceStatus()
    elseif self.current.delivery_state == "sending" then
        self:publish("queued", "sending_queued_scrobble")
    elseif self.current.delivery_state == "retrying" then
        self:publish("error", self.current.delivery_message ~= ""
            and self.current.delivery_message or "scrobble_failed; queued item retained")
    elseif self.current.delivery_state == "saved" then
        self:publish("ready", self.current.delivery_message ~= ""
            and self.current.delivery_message or "scrobble_accepted")
    elseif self.current.delivery_state == "filtered" or self.current.delivery_state == "rejected" then
        self:publish("error", self.current.delivery_message ~= ""
            and self.current.delivery_message or "scrobble_rejected")
    elseif self.current.delivery_state == "queue_full" then
        self:publish("error", self.current.delivery_message ~= ""
            and self.current.delivery_message or "scrobble_queue_full")
    elseif self.current.delivery_state == "queued" then
        self:publish("queued", "song_queued_for_lastfm")
    elseif self.current.validation == "checking" then
        self:publish("checking", "checking_track_with_lastfm")
    elseif self.current.validation == "ready" then
        if self.playback_state == "paused" then
            self:publish("ready", "playback_paused_waiting_to_save")
        else
            self:publish("ready", self.current.duration_seconds == nil
                and "track_validated_waiting_for_unknown_duration_threshold"
                or "track_validated_waiting_for_scrobble_threshold")
        end
    elseif self.current.validation == "rejected" then
        self:publish("error", self.current.validation_error or "track_check_failed")
    elseif self.playback_state == "paused" then
        self:publish("playing", "playback_paused_waiting_for_confirmation")
    else
        self:publish("playing", "waiting_for_stable_confirmed_metadata")
    end
end

function Runtime:observe(snapshot, currentMs)
    if self.account_delivery_suspended then
        self:publishCurrent()
        return
    end
    currentMs = normalizedTime(currentMs)
    local snapshotGeneration = type(snapshot) == "table" and tostring(snapshot.generation or "") or ""
    local generationChanged = self.current ~= nil and snapshotGeneration ~= ""
        and snapshotGeneration ~= tostring(self.current.generation or "")
    if generationChanged then
        if self.pending ~= nil and isTrackRequest(self.pending.kind) then
            local kind = self.pending.kind
            self:cancelTrackRequest()
            if kind == "validate" then
                self.current.validation = "waiting"
                self.current.validation_message = nil
                self.current.next_validation_ms = currentMs
            else
                self.current.now_playing_attempted = false
            end
        end
        if self.pending_transition == nil or self.pending_transition.generation ~= snapshotGeneration then
            self.pending_transition = {
                generation = snapshotGeneration,
                boundary_ms = boundedTime(snapshot.boundary_ms, currentMs),
            }
        end
    elseif self.current ~= nil then
        -- A rolled-back station change resumes the original candidate without
        -- applying the abandoned transition boundary.
        self.pending_transition = nil
    end
    if type(snapshot) ~= "table" or snapshot.audio_ready ~= true
        or snapshot.metadata_confirmed ~= true
        or (snapshot.player_state ~= "playing" and snapshot.player_state ~= "paused") then
        if generationChanged then
            return
        end
        if type(snapshot) == "table" and snapshot.player_state == "starting"
            and self.current ~= nil then
            -- A network recovery temporarily stops audio without changing the
            -- station generation. Preserve the candidate and stop its timer
            -- while the player session reconnects.
            self:advanceCandidate(self.current, "paused", currentMs)
            self.playback_state = "paused"
            self:publishCurrent()
            return
        end
        self:finishCurrent(currentMs)
        self:sourceStatus("waiting_for_confirmed_radio_metadata")
        return
    end

    local candidate, err = lastfm.candidateFromMetadata(
        snapshot.track_title, snapshot.station_name, snapshot.generation
    )
    if candidate == nil then
        if generationChanged then
            return
        end
        self:finishCurrent(currentMs)
        self:sourceStatus(err or "track_metadata_invalid")
        return
    end

    local sameMetadata = self.current ~= nil
        and self.current.metadata_key == candidate.metadata_key
    if self.current == nil or not sameMetadata then
        local finishMs = currentMs
        if self.pending_transition ~= nil and self.pending_transition.generation == candidate.generation then
            finishMs = boundedTime(self.pending_transition.boundary_ms, currentMs)
        end
        self:finishCurrent(finishMs)
        self.pending_transition = nil
        self.occurrence_serial += 1
        candidate.key = lastfm.occurrenceKey(candidate.metadata_key, self.occurrence_serial,
            self.occurrence_runtime_id)
        self.current = candidate
        self.current.seen_ms = currentMs
        self.current.played_ms = 0
        self.current.last_observation_ms = currentMs
        self.current.last_player_state = snapshot.player_state
        self.current.validation = "waiting"
        self.current.validation_message = nil
        self.current.delivery_state = "none"
        self.current.delivery_message = ""
        self.current.next_validation_ms = currentMs + lastfm.confirmationSeconds() * 1000
        logEvent("track_candidate", self.current)
    else
        if not self:advanceCandidate(self.current, snapshot.player_state, currentMs) then return end
    end
    self.playback_state = snapshot.player_state
    self:publishCurrent()
end

function Runtime:tick(currentMs)
    currentMs = normalizedTime(currentMs)
    if self:requestExpired(currentMs) then return end
    if self.account_delivery_suspended or self.credentials_loading or self.credential_saving then
        self:publishCurrent()
        return
    end
    if self.pending_transition ~= nil then
        return
    end
    self:retryQueuePersistence(currentMs)
    if not self.queue_loaded and not self.queue_load_blocked
        and hasSession(self.credentials)
        and currentMs >= self.queue_retry_ms then
        self:loadQueueForAccount()
    end

    if self.pending == nil and self.current ~= nil and self.current.validation == "waiting"
        and currentMs >= (self.current.next_validation_ms or 0)
        and hasApiCredentials(self.credentials) then
        self:startTrackValidation(self.current)
    end
    if self.current ~= nil and self.current.validation == "ready" then
        if self.playback_state == "playing" and lastfm.sendNowPlaying() then
            self:startNowPlaying(self.current)
        end
        self:queueCurrent(self.current)
    end
    if self.queue_loaded and self.pending == nil and self.scrobble_pending == nil and #self.queue > 0 then
        self:startQueuedScrobble(currentMs)
    end
    -- observe() already published a precise source status when no candidate
    -- exists. The generic playback status must not immediately replace it.
    if self.current ~= nil or hasPendingRequest(self) or #self.queue > 0 then
        self:publishCurrent()
    end
end

function Runtime:nextWakeMs(currentMs)
    currentMs = normalizedTime(currentMs)
    local nextWake = currentMs + 60000
    if self.account_delivery_suspended then return nextWake end
    local _, pending = activeRequest(self)
    if pending ~= nil then nextWake = math.min(nextWake, pending.started_ms + REQUEST_TIMEOUT_MS) end
    -- A station transition owns the next observation.  The canceled track
    -- request may have left an expired validation deadline, but waking for it
    -- only burns the player-status startup watchdog while tick() is gated.
    if self.pending_transition ~= nil then return nextWake end
    if hasApiCredentials(self.credentials)
        and self.current ~= nil and self.current.validation == "waiting" then
        nextWake = math.min(nextWake, numeric.floorOr(self.current.next_validation_ms, currentMs))
    end
    if self.next_retry_ms > currentMs then nextWake = math.min(nextWake, self.next_retry_ms) end
    if self.queue_persist_dirty and self.queue_persist_retry_ms > currentMs then
        nextWake = math.min(nextWake, self.queue_persist_retry_ms)
    end
    if not self.queue_loaded and not self.queue_load_blocked
        and hasSession(self.credentials) and self.queue_retry_ms > currentMs then
        nextWake = math.min(nextWake, self.queue_retry_ms)
    end
    if self.current ~= nil and self.current.validation == "ready"
        and self.queue_loaded
        and hasSession(self.credentials)
        and self.playback_state == "playing"
        and (self.current.delivery_state == nil or self.current.delivery_state == "none")
        and #self.queue < lastfm.MAX_QUEUE
        and self.current.threshold_seconds ~= nil then
        local remaining = self.current.threshold_seconds * 1000 - self.current.played_ms
        nextWake = math.min(nextWake, currentMs + math.max(0, remaining))
    end
    return nextWake
end

function Runtime:refresh()
    if self.credential_removal_pending then
        self:publish("error", "lastfm_credentials_could_not_be_removed")
        return false
    end
    if self.credentials_loading or self.credential_saving then
        self.credential_action_pending = lastfm.actions.refresh
        return true
    end
    return self:reloadCredentials(function(reloaded, credentialError)
        if not reloaded then
            self:publish("error", "lastfm_credentials_could_not_be_loaded")
            noctalia.log("radio-tellus: could not refresh Last.fm credentials: " .. tostring(credentialError))
            return
        end
        self.next_retry_ms = 0
        self:publishCurrent()
        self:tick(nowMs())
    end)
end

function Runtime:credentialsChanged()
    self.account_delivery_suspended = true
    self:cancelPending()
    self:invalidateAuthorization()
    if self.credentials_loading or self.credential_saving then
        if self.credential_action_pending == nil then
            self.credential_action_pending = lastfm.actions.credentialsChanged
        end
        return true
    end
    return self:reloadCredentials(function(reloaded, credentialError)
        if not reloaded then
            self:publish("error", "lastfm_credentials_could_not_be_loaded")
            noctalia.log("radio-tellus: could not apply changed Last.fm credentials: " .. tostring(credentialError))
            return
        end
        -- A successful explicit credentials replacement supersedes a failed
        -- removal attempt. Ordinary refresh is blocked while removal remains
        -- pending and cannot reach this callback.
        self.credential_removal_pending = false
        self.account_delivery_suspended = false
        self.next_retry_ms = 0
        self:publishCurrent()
        local deferredAction = self.credential_action_pending
        if deferredAction ~= nil then
            if deferredAction ~= lastfm.actions.credentialsChanged then
                self:runDeferredCredentialAction()
                return
            end
            self.credential_action_pending = nil
        end
        self:tick(nowMs())
    end, true)
end

function Runtime:onConfigChanged()
    self.next_retry_ms = 0
    if self.current ~= nil and self.current.validation == "waiting" then
        self.current.next_validation_ms = nowMs() + lastfm.confirmationSeconds() * 1000
    end
end

function Runtime:handleAction(value)
    if type(value) ~= "string" or value == "" then return end
    local action = value:match("^([%a_]+):%d+$") or value
    if action == lastfm.actions.refresh then self:refresh()
    elseif action == lastfm.actions.credentialsChanged then self:credentialsChanged()
    elseif action == lastfm.actions.authorize then self:beginAuthorization()
    elseif action == lastfm.actions.finishAuthorization then self:finishAuthorization()
    elseif action == lastfm.actions.disconnect then self:disconnect() end
    if noctalia.state.get(lastfm.ACTION_KEY) == value then noctalia.state.set(lastfm.ACTION_KEY, "") end
end

function Runtime:stop(currentMs, boundaryMs)
    currentMs = normalizedTime(currentMs)
    local finishMs = boundedTime(boundaryMs, currentMs)
    if self.pending_transition ~= nil then
        finishMs = boundedTime(self.pending_transition.boundary_ms, currentMs)
    end
    self:finishCurrent(finishMs)
    self.pending_transition = nil
    self:publishCurrent()
end

function Runtime:initialize()
    -- The candidate timer and temporary authorization token are transient. The
    -- account-bound retry queue is loaded before delivery begins.
    self:publish("checking", "loading_lastfm_credentials")
    self:reloadCredentials(function(reloaded, credentialError)
        if not reloaded then
            self:publish("error", "lastfm_credentials_could_not_be_loaded")
            noctalia.log("radio-tellus: could not initialize Last.fm credentials: " .. tostring(credentialError))
            return
        end
        self:publishCurrent()
        self:tick(nowMs())
    end, true)
end

return Runtime
