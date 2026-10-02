--!nonstrict
local shared = require("./modules/shared.luau")
local lastfm = require("./modules/lastfm.luau")
local LastFmRuntime = require("./modules/lastfm-runtime.luau")
local numeric = require("./modules/numeric-utils.luau")
local profiling = require("./modules/profiling.luau")
local lastfmRuntime = LastFmRuntime.new()

local busy, failures, activeGeneration, confirmedGeneration = false, 0, "", ""
local stopBusy, stopGeneration = false, ""
local isolationBusy, isolationCheckedGeneration = false, ""
local startupGeneration, startupChecks, startupStartedMs, startupRecordStartedMs = "", 0, 0, 0
local playbackControlGeneration, playbackControlSocket, playbackControlState = "", "", ""
local playbackControlMs, lastPlaybackControlEvent = 0, ""
local monitorMode, monitorLastLineMs, monitorDisabled = "fallback", 0, false
local playbackSnapshotKey = ""
local observedTrackTitle = ""
local lastObservedPlayerKey = ""
local lastMonitorError = ""
local lastStatusLogKey = ""
local lastFailureLogKey = ""
local recoveryBusy, recoveryGeneration = false, ""
local playingGeneration, playingSinceMs = "", 0
local stalledGeneration, stalledSinceMs = "", 0
local observedAudioGeneration = ""
local observedMarkerGeneration, observationRetryAtMs = "", 0
local monitorBuffer = ""
local STATUS_ERROR = "Radio Tellus cannot check playback right now. Audio may still be playing."
local RECOVERY_MESSAGE = "Radio Tellus is reconnecting to the station."
local CONNECTING_MESSAGE = "Connecting to the station. Waiting for audio."
local STALL_CONFIRMATION_MS = 8000
local STARTUP_INTERVAL_MS, STARTUP_FALLBACK_INTERVAL_MS, ACTIVE_INTERVAL_MS, IDLE_INTERVAL_MS = 100, 500, 3000, 60000
local MONITOR_INTERVAL_MS, MONITOR_STALE_MS = 5000, 6000
local MAX_MONITOR_BUFFER_BYTES = 262144
local STARTUP_GRACE_MS, STARTUP_TIMEOUT_MS = 2000, 20000
local STARTUP_FAST_CHECKS = math.ceil(STARTUP_GRACE_MS / STARTUP_INTERVAL_MS)
local OBSERVATION_RETRY_INTERVAL_MS = 5000
local PAUSE_CONTROL_PENDING_TIMEOUT_MS = shared.PAUSE_COMMAND_TIMEOUT_MS
local STATUS_REQUEST = table.concat({
    '{"command":["get_property","pause"],"request_id":1}',
    '{"command":["get_property","metadata"],"request_id":2}',
    '{"command":["get_property","volume"],"request_id":3}',
    '{"command":["get_property","mute"],"request_id":4}',
    '{"command":["get_property","audio-out-params"],"request_id":5}',
    '{"command":["get_property","core-idle"],"request_id":6}',
}, "\n") .. "\n"
local STEADY_STATUS_REQUEST = table.concat({
    '{"command":["get_property","pause"],"request_id":1}',
    '{"command":["get_property","metadata"],"request_id":2}',
    '{"command":["get_property","volume"],"request_id":3}',
    '{"command":["get_property","mute"],"request_id":4}',
    '{"command":["get_property","audio-out-params"],"request_id":5}',
    '{"command":["get_property","core-idle"],"request_id":6}',
}, "\n") .. "\n"

local function publishChanged(key, value)
    if noctalia.state.get(key) == value then return false end
    noctalia.state.set(key, value)
    return true
end

local function clearTransientPlaybackError()
    local playerError = tostring(noctalia.state.get("player_error") or "")
    if playerError == STATUS_ERROR or playerError == RECOVERY_MESSAGE
        or playerError == CONNECTING_MESSAGE then
        publishChanged("player_error", "")
    end
end

local function setPollingActive(active, starting)
    local interval = IDLE_INTERVAL_MS
    if active then
        interval = starting and (startupChecks < STARTUP_FAST_CHECKS
            and STARTUP_INTERVAL_MS or STARTUP_FALLBACK_INTERVAL_MS) or ACTIVE_INTERVAL_MS
    end
    noctalia.setUpdateInterval(interval)
end

local function publishPlaybackSnapshot()
    local value = {
        generation = tostring(noctalia.state.get("player_generation") or ""),
        started_ms = numeric.floorOr(noctalia.state.get("player_started_ms"), 0),
        state = tostring(noctalia.state.get("player_state") or "stopped"),
        station = noctalia.state.get("station") or "",
        station_name = noctalia.state.get("station_name") or "",
        track_title = observedTrackTitle,
        volume = numeric.floorOr(noctalia.state.get("player_volume"), shared.DEFAULT_VOLUME),
        muted = noctalia.state.get("player_muted") == true,
        audio_ready = noctalia.state.get("audio_ready") == true,
        playback_isolation = tostring(noctalia.state.get("playback_isolation") or ""),
        player_error = tostring(noctalia.state.get("player_error") or ""),
    }
    local key = table.concat({ value.generation, tostring(value.started_ms), value.state,
        tostring(value.station), tostring(value.station_name), value.track_title,
        tostring(value.volume), tostring(value.muted), tostring(value.audio_ready),
        value.playback_isolation, value.player_error }, "\31")
    if key == playbackSnapshotKey then return end
    playbackSnapshotKey = key
    noctalia.state.set("radio_tellus_playback", value)
end

local function readIsolationMarker(socket, generation)
    if isolationBusy or isolationCheckedGeneration == generation then return end
    local marker = socket:gsub("/mpv%.sock$", "/isolation")
    if marker == socket then isolationCheckedGeneration = generation; return end
    isolationBusy = true
    local quoted = shared.shellQuote(marker)
    local script = shared.socketGuard(socket) .. " && if [ -f " .. quoted .. " ] && [ ! -L " .. quoted .. " ]; then "
        .. "IFS= read -r mode < " .. quoted
        .. "; case $mode in full|compatible) printf '%s' \"$mode\";; esac; fi"
    local accepted = noctalia.runAsync({ "/usr/bin/sh", "-c", script }, function(result)
        isolationBusy = false
        if socket ~= shared.socketPath()
            or generation ~= tostring(noctalia.state.get("player_generation") or "") then return end
        local commandSucceeded = type(result) == "table"
            and result.timedOut ~= true
            and numeric.floorOr(result.exitCode, -1) == 0
        local mode = type(result) == "table" and shared.trim(result.stdout) or ""
        if not commandSucceeded then
            isolationCheckedGeneration = ""
        elseif mode == "full" or mode == "compatible" then
            isolationCheckedGeneration = generation
            publishChanged("playback_isolation", mode)
            publishPlaybackSnapshot()
        else
            -- A successful check with no valid marker is conclusive for this
            -- generation. Only command failures need another attempt.
            isolationCheckedGeneration = generation
        end
    end, 1000)
    if not accepted then
        isolationBusy = false
        isolationCheckedGeneration = ""
    end
end

local function streamMetadataTitle(metadata)
    if type(metadata) ~= "table" or type(metadata["icy-title"]) ~= "string" then return "" end
    return shared.trackTitle(metadata["icy-title"])
end

local function logStatusFailure(stage, generation, details)
    local failureKey = table.concat({ stage, generation, tostring(failures) }, "\31")
    if failures > 2 and failures % 5 ~= 0 then return end
    if failureKey ~= lastFailureLogKey then
        lastFailureLogKey = failureKey
        shared.logPlayback("status_failure", "stage=" .. stage .. " failures=" .. tostring(failures)
            .. (details and " " .. details or ""))
    end
end

local function audioOutputReady(value)
    if type(value) ~= "table" or type(value.format) ~= "string" or shared.trim(value.format) == "" then return false end
    local samplerate = numeric.finite(value.samplerate)
    local channelCount = numeric.finite(value["channel-count"])
    return samplerate ~= nil and samplerate > 0 and channelCount ~= nil and channelCount > 0
end

local function parsePlayerStatus(output)
    local status = {
        audio_ready = false,
        audio_ready_known = false,
        paused_known = false,
    }
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local decoded = noctalia.json.decode(line)
        if type(decoded) == "table" and decoded.error == "success" then
            if decoded.request_id == 1 and type(decoded.data) == "boolean" then
                status.paused, status.paused_known = decoded.data, true
            elseif decoded.request_id == 2 then status.title = streamMetadataTitle(decoded.data)
            elseif decoded.request_id == 3 and type(decoded.data) == "number" then
                local volume = numeric.finite(decoded.data)
                if volume ~= nil then status.volume = shared.clampInteger(volume + 0.5, 0, 0, 100) end
            elseif decoded.request_id == 4 and type(decoded.data) == "boolean" then status.muted = decoded.data
            elseif decoded.request_id == 5 then
                status.audio_ready = audioOutputReady(decoded.data)
                status.audio_ready_known = true
            elseif decoded.request_id == 6 and type(decoded.data) == "boolean" then
                status.core_idle, status.core_idle_known = decoded.data, true
            end
        end
    end
    status.complete = status.paused_known and status.audio_ready_known and status.core_idle_known
    return status
end

shared.hardenDataDir()
local restoredPlayback = shared.restorePlayback()
local recoveredObservedGeneration = shared.recoveredPlaybackGeneration(restoredPlayback)
if recoveredObservedGeneration ~= "" then
    observedAudioGeneration = recoveredObservedGeneration
    observedMarkerGeneration = recoveredObservedGeneration
end
lastfmRuntime:initialize()
local initialSocket = shared.socketPath()
local initialState = tostring(noctalia.state.get("player_state") or "stopped")
setPollingActive(initialSocket ~= nil, initialState == "starting")
publishPlaybackSnapshot()

function onConfigChanged()
    lastfmRuntime:onConfigChanged()
end

local function finishLastFmPlayback(currentMs, deliverQueued, boundaryMs)
    lastfmRuntime:stop(currentMs, boundaryMs)
    if deliverQueued then
        -- A stopped stream cannot produce another player-status callback, so a
        -- threshold-qualified scrobble receives one immediate delivery attempt.
        -- Retryable failures remain in the durable account-bound queue.
        lastfmRuntime:tick(currentMs)
    end
end

local function startupBoundaryMs()
    local state = tostring(noctalia.state.get("player_state") or "stopped")
    local startedMs = tonumber(noctalia.state.get("player_started_ms")) or 0
    return state == "starting" and startedMs > 0 and startedMs or nil
end

local function stopFailedPlayback(socket, generation, successMessage, failureMessage)
    if stopBusy and stopGeneration == generation then return end
    stopBusy, stopGeneration = true, generation
    shared.logPlayback("stop_for_failure", "generation=" .. generation)
    local accepted = shared.stopPlayer(function(stopped)
        stopBusy = false
        if socket ~= shared.socketPath()
            or generation ~= tostring(noctalia.state.get("player_generation") or "") then
            stopGeneration = ""
            return
        end
        stopGeneration = ""
        if not stopped then
            shared.logPlayback("stop_for_failure_failed", "generation=" .. generation)
            publishChanged("player_error", failureMessage)
            publishPlaybackSnapshot()
            return
        end
        shared.clearPlayback(generation)
        finishLastFmPlayback(noctalia.nowMs(), true, startupBoundaryMs())
        shared.clearNowPlaying()
        shared.logPlayback("stop_for_failure_completed", "generation=" .. generation)
        publishChanged("player_error", successMessage)
        publishPlaybackSnapshot()
        setPollingActive(false)
    end, socket)
    if not accepted and stopBusy then
        stopBusy, stopGeneration = false, ""
        publishChanged("player_error", failureMessage)
        publishPlaybackSnapshot()
    end
end

local function failUnstartedPlayback(socket, generation)
    shared.logPlayback("startup_timeout", "generation=" .. generation)
    stopFailedPlayback(
        socket,
        generation,
        "The station did not start playing. It may be offline or unavailable.",
        "The station did not start playing and could not be stopped. Try stopping it again."
    )
end

local function startupExpired(generation, now)
    return generation == startupGeneration and startupStartedMs > 0
        and now - startupStartedMs >= STARTUP_TIMEOUT_MS
end

local function pendingLaunchAge(generation, socket, currentMs)
    local pending = noctalia.state.get("player_launch_pending")
    if type(pending) ~= "table"
        or tostring(pending.generation or "") ~= generation
        or tostring(pending.socket or "") ~= socket then return nil end
    local startedMs = numeric.floorOr(pending.started_ms, 0)
    if startedMs <= 0 then return nil end
    return currentMs - startedMs
end

local function clearPendingLaunch(generation, socket)
    local pending = noctalia.state.get("player_launch_pending")
    if type(pending) == "table"
        and tostring(pending.generation or "") == generation
        and tostring(pending.socket or "") == socket then
        noctalia.state.set("player_launch_pending", "")
    end
end

local function handlePlaybackControl(value)
    if type(value) ~= "table" then return end
    local generation = tostring(value.generation or "")
    local socket = tostring(value.socket or "")
    local playerState = tostring(value.player_state or "")
    local changedMs = numeric.floorOr(value.changed_ms, 0)
    local boundaryMs = math.max(0, math.min(changedMs, numeric.floorOr(value.boundary_ms, changedMs)))
    local eventId = tostring(value.event_id or "")
    if eventId == "" or eventId == lastPlaybackControlEvent
        or changedMs <= 0 or (playerState ~= "playing" and playerState ~= "paused") then return end
    if generation ~= tostring(noctalia.state.get("player_generation") or "")
        or socket == "" or socket ~= shared.socketPath() then return end
    if generation == playbackControlGeneration and changedMs < playbackControlMs then return end
    lastPlaybackControlEvent = eventId
    playbackControlGeneration, playbackControlSocket = generation, socket
    playbackControlState, playbackControlMs = playerState, changedMs
    lastfmRuntime:reconcilePlaybackState(playerState, boundaryMs, changedMs, generation)
end

local function pendingPlaybackControl(generation, socket)
    local pending = noctalia.state.get("player_control_pending")
    if type(pending) ~= "table"
        or tostring(pending.generation or "") ~= generation
        or tostring(pending.socket or "") ~= socket then return nil end
    return pending
end

local function controlEventCompletesPending(pending)
    if type(pending) ~= "table" then return false end
    local commandId = tostring(pending.command_id or "")
    local control = noctalia.state.get("player_control_state")
    if commandId == "" or type(control) ~= "table"
        or tostring(control.generation or "") ~= tostring(pending.generation or "")
        or tostring(control.socket or "") ~= tostring(pending.socket or "") then return false end
    local eventId = tostring(control.event_id or "")
    return eventId:sub(1, #commandId + 1) == commandId .. ":"
end

local function playbackControlPending(generation, socket, now)
    local pending = pendingPlaybackControl(generation, socket)
    if pending == nil or controlEventCompletesPending(pending) then return false end
    local startedMs = numeric.floorOr(pending.started_ms, 0)
    local age = now - startedMs
    return startedMs > 0 and age <= PAUSE_CONTROL_PENDING_TIMEOUT_MS
end

local function reconcilePendingPlaybackControl(generation, socket, status, currentMs)
    local pending = pendingPlaybackControl(generation, socket)
    if pending == nil or controlEventCompletesPending(pending)
        or status.paused == nil then return false end
    local startedMs = numeric.floorOr(pending.started_ms, 0)
    local playerState = status.paused and "paused" or "playing"
    local previousState = tostring(pending.previous_state or "")
    local stateChanged = (previousState == "playing" or previousState == "paused")
        and playerState ~= previousState
    if startedMs <= 0 or (not stateChanged and currentMs - startedMs <= PAUSE_CONTROL_PENDING_TIMEOUT_MS) then return false end
    -- A lost control callback still leaves the recorded command start as the
    -- boundary. Re-anchor the runtime there before observing the
    -- current MPV state so a polling delay is not charged as playing time.
    lastfmRuntime:reconcilePlaybackState(playerState, startedMs, currentMs, generation)
    local current = noctalia.state.get("player_control_pending")
    if type(current) == "table" and tostring(current.command_id or "") == tostring(pending.command_id or "") then
        noctalia.state.set("player_control_pending", "")
    end
    return true
end

local function processPlayerStatus(status, generation, socket, requestStartedMs)
    profiling.count("player_status_processes")
    local currentGeneration = tostring(noctalia.state.get("player_generation") or "")
    if socket ~= shared.socketPath() or generation ~= currentGeneration then return end
    handlePlaybackControl(noctalia.state.get("player_control_state"))
    local observationMs = noctalia.nowMs()
    local currentPlayerState = tostring(noctalia.state.get("player_state") or "stopped")
    reconcilePendingPlaybackControl(generation, socket, status, observationMs)
    local controlPending = playbackControlPending(generation, socket, observationMs)
    failures = 0
    clearTransientPlaybackError()
    lastMonitorError = ""
    -- MPV reports core-idle=true while a confirmed session is paused. Keep
    -- that established session active without allowing an initial paused or
    -- incomplete snapshot to confirm playback.
    local streamActive = shared.playbackIsActive(status, generation, observedAudioGeneration)
    if streamActive and status.paused == false and observedAudioGeneration ~= generation then
        observedAudioGeneration = generation
        observationRetryAtMs = 0
    end
    if streamActive and observedAudioGeneration == generation
        and observedMarkerGeneration ~= generation and observationMs >= observationRetryAtMs then
        if shared.notePlaybackObserved(generation) then
            observedMarkerGeneration = generation
        else
            observationRetryAtMs = observationMs + OBSERVATION_RETRY_INTERVAL_MS
        end
    end
    local stalled = status.audio_ready and status.paused == false
        and status.core_idle_known == true and status.core_idle == true
    local observedPlayerState = streamActive
        and (status.paused and "paused" or "playing") or "starting"
    if stalled then
        if stalledGeneration ~= generation then
            stalledGeneration, stalledSinceMs = generation, observationMs
        end
    else
        stalledGeneration, stalledSinceMs = "", 0
    end
    if streamActive and observedPlayerState == "playing" then
        if playingGeneration ~= generation or currentPlayerState ~= "playing" then
            playingGeneration, playingSinceMs = generation, observationMs
        end
    elseif streamActive and observedPlayerState == "paused" then
        playingGeneration, playingSinceMs = generation, 0
    elseif not stalled and currentPlayerState ~= "playing" then
        playingGeneration, playingSinceMs = "", 0
    end
    local confirmedStall = stalled
        and stalledGeneration == generation
        and stalledSinceMs > 0
        and observationMs - stalledSinceMs >= STALL_CONFIRMATION_MS
        and playingGeneration == generation
        and playingSinceMs > 0
        and observationMs - playingSinceMs >= STALL_CONFIRMATION_MS
    if streamActive then
        clearPendingLaunch(generation, socket)
        recoveryBusy, recoveryGeneration = false, ""
    end
    if streamActive and playbackControlGeneration == generation
        and playbackControlSocket == socket and playbackControlMs >= requestStartedMs then
        observedPlayerState = playbackControlState
    end
    if confirmedStall
        and (not recoveryBusy or recoveryGeneration ~= generation) then
        recoveryBusy, recoveryGeneration = true, generation
        shared.restartPlayer(socket)
        publishChanged("player_state", "starting")
        publishChanged("audio_ready", false)
        publishChanged("player_error", RECOVERY_MESSAGE)
        observedPlayerState = "starting"
    end
    local statusLogKey = table.concat({ generation, observedPlayerState,
        tostring(streamActive), tostring(status.paused), tostring(status.core_idle) }, "\31")
    if statusLogKey ~= lastStatusLogKey then
        lastStatusLogKey = statusLogKey
        shared.logPlayback("status", "observed=" .. observedPlayerState
            .. " audio_ready=" .. tostring(streamActive)
            .. " paused=" .. tostring(status.paused)
            .. " core_idle=" .. tostring(status.core_idle))
    end
    if not controlPending then
        if streamActive then
            publishChanged("player_state", observedPlayerState)
            setPollingActive(true, false)
            if generation ~= confirmedGeneration then
                local confirmed = shared.confirmPlayback(generation)
                if confirmed == true then confirmedGeneration = generation end
            end
        elseif stalled or currentPlayerState == "starting" then
            publishChanged("player_state", "starting")
        else
            publishChanged("player_state", "stopped")
        end
    elseif currentPlayerState == "starting" then
        local callbackNow = noctalia.nowMs()
        local callbackLaunchAge = pendingLaunchAge(generation, socket, callbackNow)
        if startupExpired(generation, callbackNow)
            or (callbackLaunchAge ~= nil and callbackLaunchAge >= STARTUP_TIMEOUT_MS) then
            failUnstartedPlayback(socket, generation)
            return
        end
    end
    -- A missing stream title marks the transition between tracks. Reusing
    -- the previous title could leave the panel stale or associate new
    -- playback with the old song.
    local trackTitle = status.title or ""
    observedTrackTitle = trackTitle
    publishChanged("track_title", trackTitle)
    publishChanged("audio_ready", streamActive == true)
    if status.volume then publishChanged("player_volume", status.volume) end
    if status.muted ~= nil then publishChanged("player_muted", status.muted) end
    if not controlPending then
        local playerKey = table.concat({ generation, observedPlayerState, trackTitle,
            tostring(status.audio_ready == true), tostring(status.paused == true) }, "\31")
        if playerKey ~= lastObservedPlayerKey then
            lastObservedPlayerKey = playerKey
            profiling.count("lastfm_observations")
        end
        -- Timing must advance on every complete fallback snapshot. The key
        -- above only deduplicates diagnostics, not playback accounting.
        lastfmRuntime:observe({
            player_state = observedPlayerState,
            audio_ready = streamActive == true,
            metadata_confirmed = streamActive == true and generation == confirmedGeneration
                and trackTitle ~= "",
            track_title = trackTitle,
            station_name = noctalia.state.get("station_name"),
            generation = generation,
            boundary_ms = tonumber(noctalia.state.get("player_started_ms")) or 0,
        }, observationMs)
        lastfmRuntime:tick(observationMs)
    end
    publishPlaybackSnapshot()
end

function onExit(_signal, reason)
    -- Reloads retain playback. Real teardown stops it.
    -- Detached control can finish after this VM exits.
    profiling.report()
    if reason ~= "reload" then
        -- The in-memory scrobbler session ends before the service VM disappears.
        -- Teardown does not start another network request.
        finishLastFmPlayback(noctalia.nowMs(), false, startupBoundaryMs())
        shared.stopDetached()
    end
end

local function pollUpdate()
    local now = noctalia.nowMs()
    if busy or stopBusy then return end
    local socket = shared.socketPath()
    if socket == nil then
        observedTrackTitle = ""
        startupGeneration, startupChecks, startupStartedMs, startupRecordStartedMs = "", 0, 0, 0
        setPollingActive(false)
        finishLastFmPlayback(now, true, startupBoundaryMs())
        lastfmRuntime:tick(now)
        shared.clearNowPlaying()
        clearTransientPlaybackError()
        publishPlaybackSnapshot()
        local nextWake = lastfmRuntime:nextWakeMs(now)
        noctalia.setUpdateInterval(math.max(50, math.min(IDLE_INTERVAL_MS, nextWake - now)))
        return
    end
    local generation = tostring(noctalia.state.get("player_generation") or "")
    local playerState = tostring(noctalia.state.get("player_state") or "stopped")
    setPollingActive(true, playerState == "starting")
    if playerState == "starting" then
        local recordStartedMs = numeric.floorOr(noctalia.state.get("player_started_ms"), 0)
        if generation ~= startupGeneration or startupStartedMs <= 0
            or recordStartedMs ~= startupRecordStartedMs then
            startupGeneration, startupChecks, startupStartedMs = generation, 0, now
            startupRecordStartedMs = recordStartedMs
        end
        startupChecks += 1
    else
        startupGeneration, startupChecks, startupStartedMs, startupRecordStartedMs = "", 0, 0, 0
    end
    -- nowMs is wall clock time, so the poll bound keeps startup finite across a clock rollback.
    local launchAge = pendingLaunchAge(generation, socket, now)
    local launchTimedOut = launchAge ~= nil and launchAge >= STARTUP_TIMEOUT_MS
    local launchPending = launchAge ~= nil and launchAge < STARTUP_TIMEOUT_MS
    local startupTimedOut = playerState == "starting"
        and startupExpired(generation, now)
    if not noctalia.fileExists("/usr/bin/socat") then
        if startupTimedOut or launchTimedOut then failUnstartedPlayback(socket, generation) end
        return
    end
    if not noctalia.fileExists(socket) then
        local age = startupStartedMs > 0 and now - startupStartedMs or 0
        local marker = shared.sessionMarkerPath(socket)
        local helperPresent = marker ~= nil and noctalia.fileExists(marker)
        if playerState == "starting" and not startupTimedOut and not launchTimedOut
            and (launchPending or age < STARTUP_GRACE_MS
            or (helperPresent and age >= 0 and age < STARTUP_TIMEOUT_MS)) then return end
        stopFailedPlayback(
            socket,
            generation,
            "The station stopped responding or could not be played. Try another station.",
            "The station stopped responding and could not be stopped. Try stopping it again."
        )
        return
    end
    if startupTimedOut then failUnstartedPlayback(socket, generation); return end
    if generation ~= activeGeneration then
        failures, activeGeneration, isolationCheckedGeneration = 0, generation, ""
    end
    if tostring(noctalia.state.get("playback_isolation") or "") == "" then
        readIsolationMarker(socket, generation)
    end
    busy = true
    local requestStartedMs = noctalia.nowMs()
    local needsFullStatus = playerState == "starting" or generation ~= confirmedGeneration
    local statusRequest = needsFullStatus and STATUS_REQUEST or STEADY_STATUS_REQUEST
    local started = shared.socketRequest(statusRequest, function(result)
        busy = false
        if socket ~= shared.socketPath()
            or generation ~= tostring(noctalia.state.get("player_generation") or "") then return end
        if type(result) ~= "table" then
            failures += 1
            logStatusFailure("socket_request", generation, "result=missing")
            if failures >= 2 then
                publishChanged("player_error", STATUS_ERROR)
                publishPlaybackSnapshot()
            end
            return
        end
        local status = parsePlayerStatus(result.stdout)
        if status.paused == nil then
            failures += 1
            local commandFailed = numeric.floorOr(result.exitCode, -1) ~= 0
            local timedOut = result.timedOut == true
            local detail = "exit=" .. tostring(numeric.floorOr(result.exitCode, -1))
                .. " timed_out=" .. tostring(timedOut)
            local resultError = shared.singleLine(result.stderr or result.error, 180)
            if resultError ~= "" then detail = detail .. " detail=" .. resultError end
            logStatusFailure("socket_status", generation, detail)
            if failures >= 2 and commandFailed and not timedOut then
                -- Timeout failures may be transient. Socket removal is deferred
                -- until a non-timeout failure.
                stopFailedPlayback(
                    socket,
                    generation,
                    "The station stopped responding or could not be played. Try another station.",
                    "The station stopped responding and could not be stopped. Try stopping it again."
                )
            elseif failures >= 2 then
                publishChanged("player_error", STATUS_ERROR)
                publishPlaybackSnapshot()
            end
            return
        end
        if status.complete ~= true then return end
        processPlayerStatus(status, generation, socket, requestStartedMs)
    end, 1800, 16384, socket)
    if not started then
        busy = false
        failures += 1
        logStatusFailure("socket_request_start", generation, "accepted=false")
        if failures >= 2 then
            publishChanged("player_error", STATUS_ERROR)
            publishPlaybackSnapshot()
        end
    end
end

local function monitorStatus(value)
    if type(value) ~= "table" or value.kind ~= "status" then return nil end
    if value.ok ~= true then return false end
    if value.complete ~= true then
        profiling.count("incomplete_monitor_statuses")
        return nil
    end
    local paused = nil
    if type(value.paused) == "boolean" then paused = value.paused end
    local muted = nil
    if type(value.muted) == "boolean" then muted = value.muted end
    local coreIdle = false
    if type(value.core_idle) == "boolean" then coreIdle = value.core_idle end
    local status = {
        paused = paused,
        paused_known = value.paused_known == true,
        title = type(value.title) == "string" and shared.trackTitle(value.title) or "",
        muted = muted,
        audio_ready = value.audio_ready == true,
        audio_ready_known = value.audio_ready_known == true,
        core_idle = coreIdle,
        core_idle_known = value.core_idle_known == true,
        complete = value.complete == true,
        initial = value.initial == true,
    }
    if status.paused == nil or not status.paused_known then return false end
    if not status.complete or not status.audio_ready_known or not status.core_idle_known then return nil end
    if type(value.volume) == "number" then
        local volume = numeric.finite(value.volume)
        if volume ~= nil then status.volume = shared.clampInteger(volume + 0.5, 0, 0, 100) end
    end
    return status
end

local function observeLastFmSnapshot(currentMs)
    local playerState = tostring(noctalia.state.get("player_state") or "stopped")
    if playerState ~= "playing" and playerState ~= "paused" and playerState ~= "starting" then return end
    lastfmRuntime:observe({
        player_state = playerState,
        audio_ready = noctalia.state.get("audio_ready") == true,
        metadata_confirmed = noctalia.state.get("audio_ready") == true
            and observedTrackTitle ~= ""
            and confirmedGeneration == tostring(noctalia.state.get("player_generation") or ""),
        track_title = observedTrackTitle,
        station_name = noctalia.state.get("station_name"),
        generation = tostring(noctalia.state.get("player_generation") or ""),
        boundary_ms = numeric.floorOr(noctalia.state.get("player_started_ms"), 0),
    }, currentMs)
end

local function disableMonitor()
    if monitorDisabled then return end
    monitorDisabled = true
    monitorMode = "fallback"
    shared.logPlayback("monitor_disabled", "reason=stale_output")
    shared.writeJson("monitor-control.json", { mode = "disabled" })
end

local function processMonitorRecord(line)
    local recordMs = noctalia.nowMs()
    local decoded = noctalia.json.decode(tostring(line or ""))
    if type(decoded) ~= "table" then
        if lastMonitorError ~= "invalid_output" then
            lastMonitorError = "invalid_output"
            shared.logPlayback("monitor_error", "error=invalid_output")
        end
        return
    end
    if decoded.kind == "heartbeat" then
        if decoded.ipc_ready == true then monitorLastLineMs = recordMs end
        return
    end
    if decoded.kind ~= "status" then return end
    monitorLastLineMs = recordMs
    if decoded.ok ~= true then
        local monitorError = tostring(decoded.error or "unknown_monitor_error")
        local monitorDetail = shared.singleLine(decoded.detail, 180)
        if monitorError ~= lastMonitorError then
            lastMonitorError = monitorError
            shared.logPlayback("monitor_error", "error=" .. monitorError
                .. (monitorDetail ~= "" and " detail=" .. monitorDetail or ""))
        end
        local playerState = tostring(noctalia.state.get("player_state") or "stopped")
        if monitorError == "socket_unavailable" or monitorError == "socket_read_failed"
            or monitorError == "ipc_unresponsive" then
            failures = 0
            if playerState == "playing" or playerState == "paused" then
                publishChanged("player_state", "starting")
                publishChanged("audio_ready", false)
                publishChanged("player_error", RECOVERY_MESSAGE)
            elseif playerState == "starting" then
                publishChanged("player_error", CONNECTING_MESSAGE)
            end
            publishPlaybackSnapshot()
            return
        end
    end
    local status = monitorStatus(decoded)
    if status == nil then return end
    if status == false then
        failures += 1
        local rejection = "kind=" .. tostring(decoded.kind)
            .. " ok=" .. tostring(decoded.ok)
            .. " complete=" .. tostring(decoded.complete)
            .. " paused=" .. tostring(decoded.paused)
            .. " paused_known=" .. tostring(decoded.paused_known)
            .. " audio_ready_known=" .. tostring(decoded.audio_ready_known)
            .. (decoded.error ~= nil and " error=" .. tostring(decoded.error) or "")
        logStatusFailure("monitor_status", tostring(decoded.generation or ""),
            "error=invalid_status " .. rejection)
        if failures >= 2 then
            publishChanged("player_error", STATUS_ERROR)
            publishPlaybackSnapshot()
        end
        return
    end
    if status.initial then return end
    local socket = shared.socketPath()
    if socket == nil then return end
    processPlayerStatus(status, tostring(decoded.generation or ""), socket, monitorLastLineMs)
end

local function processMonitorLine(line)
    local chunk = tostring(line or "")
    if chunk == "" then return end
    monitorBuffer ..= chunk
    if #monitorBuffer > MAX_MONITOR_BUFFER_BYTES then
        monitorBuffer = ""
        if lastMonitorError ~= "oversized_output" then
            lastMonitorError = "oversized_output"
            shared.logPlayback("monitor_error", "error=oversized_output")
        end
        return
    end

    local processedRecord = false
    while true do
        local newline = monitorBuffer:find("\n", 1, true)
        if newline == nil then break end
        local record = monitorBuffer:sub(1, newline - 1):gsub("\r$", "")
        monitorBuffer = monitorBuffer:sub(newline + 1)
        if record ~= "" then
            processMonitorRecord(record)
            processedRecord = true
        end
    end

    local decoded = noctalia.json.decode(monitorBuffer)
    if type(decoded) == "table" then
        processMonitorRecord(monitorBuffer)
        monitorBuffer = ""
    elseif processedRecord and monitorBuffer == "" then
        return
    end
end

local function startPersistentMonitor()
    if not noctalia.fileExists("/usr/bin/python3") then
        shared.logPlayback("monitor_unavailable", "reason=python3_missing")
        return
    end
    local pluginDir, dataDir = noctalia.pluginDir(), shared.dataDir()
    if pluginDir == nil or dataDir == nil then
        shared.logPlayback("monitor_unavailable", "reason=data_directory_missing")
        return
    end
    if not shared.writeJson("monitor-control.json", { mode = "active" }) then
        shared.logPlayback("monitor_unavailable", "reason=control_file_write_failed")
        return
    end
    local helper = pluginDir .. "/helpers/player-monitor.py"
    if not noctalia.fileExists(helper) then
        shared.logPlayback("monitor_unavailable", "reason=helper_missing")
        return
    end
    local command = 'P=$PPID; while kill -0 "$P" 2>/dev/null; do /usr/bin/python3 '
        .. shared.shellQuote(helper) .. " --data-dir " .. shared.shellQuote(dataDir) .. "; /usr/bin/sleep 1; done"
    if noctalia.runStream(command, processMonitorLine) then
        monitorMode = "stream"
        monitorLastLineMs = noctalia.nowMs()
        shared.logPlayback("monitor_started")
    else
        shared.logPlayback("monitor_unavailable", "reason=stream_start_rejected")
    end
end

function update()
    if monitorMode ~= "stream" or monitorDisabled then
        pollUpdate()
        return
    end
    if busy or stopBusy then return end
    local now = noctalia.nowMs()
    local socket = shared.socketPath()
    if socket == nil then
        observedTrackTitle = ""
        startupGeneration, startupChecks, startupStartedMs, startupRecordStartedMs = "", 0, 0, 0
        setPollingActive(false)
        finishLastFmPlayback(now, true, startupBoundaryMs())
        lastfmRuntime:tick(now)
        shared.clearNowPlaying()
        clearTransientPlaybackError()
        publishPlaybackSnapshot()
        local nextWake = lastfmRuntime:nextWakeMs(now)
        noctalia.setUpdateInterval(math.max(50, math.min(IDLE_INTERVAL_MS, nextWake - now)))
        return
    end
    local generation = tostring(noctalia.state.get("player_generation") or "")
    local playerState = tostring(noctalia.state.get("player_state") or "stopped")
    setPollingActive(true, false)
    if playerState == "starting" then
        local recordStartedMs = numeric.floorOr(noctalia.state.get("player_started_ms"), 0)
        if generation ~= startupGeneration or startupStartedMs <= 0
            or recordStartedMs ~= startupRecordStartedMs then
            startupGeneration, startupChecks, startupStartedMs = generation, 0, now
            startupRecordStartedMs = recordStartedMs
        end
        startupChecks += 1
        if startupExpired(generation, now)
            or (pendingLaunchAge(generation, socket, now) or 0) >= STARTUP_TIMEOUT_MS then
            failUnstartedPlayback(socket, generation)
            return
        end
    else
        startupGeneration, startupChecks, startupStartedMs, startupRecordStartedMs = "", 0, 0, 0
    end
    if monitorLastLineMs > 0 and now - monitorLastLineMs > MONITOR_STALE_MS then
        disableMonitor()
        pollUpdate()
        return
    end
    observeLastFmSnapshot(now)
    lastfmRuntime:tick(now)
    local nextWake = lastfmRuntime:nextWakeMs(now)
    noctalia.setUpdateInterval(math.max(50, math.min(MONITOR_INTERVAL_MS, nextWake - now)))
end

noctalia.state.watch(lastfm.ACTION_KEY, function(value) lastfmRuntime:handleAction(value) end)
noctalia.state.watch("player_control_state", handlePlaybackControl)
noctalia.state.watch("player_socket", function(value)
    local active = tostring(value or "") ~= ""
    local state = tostring(noctalia.state.get("player_state") or "stopped")
    setPollingActive(active, state == "starting")
    if active and not busy then update() end
    if not active then
        finishLastFmPlayback(noctalia.nowMs(), true, startupBoundaryMs())
        publishPlaybackSnapshot()
        if not busy then update() end
    end
end)

startPersistentMonitor()
update()
