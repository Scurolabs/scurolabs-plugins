--!nonstrict
local shared = require("./modules/shared.luau")
local uiText = require("./modules/ui.luau")

local glyph = noctalia.getConfig("glyph") or "radio"
local showPlaybackStatus = noctalia.getConfig("show_playback_status") ~= false
local showStationName = noctalia.getConfig("show_station_name") ~= false
local stationNameLimit = shared.clampInteger(noctalia.getConfig("station_name_limit"), 24, 8, 60)
local volumeStep = shared.clampInteger(noctalia.getConfig("volume_step"), 5, 1, 20)
local state = tostring(noctalia.state.get("player_state") or "stopped")
local station = tostring(noctalia.state.get("station_name") or "")
local track = tostring(noctalia.state.get("track_title") or "")
local volume = shared.clampInteger(noctalia.state.get("player_volume"), shared.DEFAULT_VOLUME, 0, 100)
local muted = noctalia.state.get("player_muted") == true
local isolation = tostring(noctalia.state.get("playback_isolation") or "")
local playbackError = tostring(noctalia.state.get("player_error") or "")
local renderPending = false

local function applyPlaybackSnapshot(value)
    if type(value) ~= "table" then return end
    state = tostring(value.state or "stopped")
    station = tostring(value.station_name or "")
    track = tostring(value.track_title or "")
    volume = shared.clampInteger(value.volume, volume, 0, 100)
    muted = value.muted == true
    isolation = tostring(value.playback_isolation or "")
    playbackError = tostring(value.player_error or "")
end

local initialPlayback = noctalia.state.get("radio_tellus_playback")
if type(initialPlayback) == "table" then applyPlaybackSnapshot(initialPlayback) end

local function glyphPresentation()
    if showPlaybackStatus and playbackError ~= "" then
        return glyph, "error"
    elseif showPlaybackStatus and state == "playing" and (muted or volume <= 0) then
        return "volume-off", "on_surface_variant"
    elseif showPlaybackStatus and state == "playing" then
        return "antenna-bars-5", "primary"
    elseif showPlaybackStatus and state == "paused" then
        return "player-pause", "on_surface_variant"
    elseif showPlaybackStatus and state == "starting" then
        return "antenna-bars-3", "primary"
    end

    return glyph, "on_surface"
end

local function render()
    local active = state == "playing" or state == "paused" or state == "starting"
    local displayGlyph, glyphColor = glyphPresentation()
    barWidget.setGlyph(displayGlyph)
    barWidget.setGlyphColor(glyphColor)
    if state == "stopped" and playbackError ~= "" then
        barWidget.setText(uiText.tr("bar.station_unavailable"))
    elseif active and showStationName then
        barWidget.setText(shared.truncateCharacters(
            shared.singleLine(station ~= "" and station or uiText.tr("bar.radio"), 200), stationNameLimit))
    else
        barWidget.setText("")
    end

    local errorText = playbackError ~= "" and uiText.literal(playbackError) or ""
    if active then
        local statusKey = state == "paused" and "paused" or (state == "starting" and "connecting" or "playing")
        local status = errorText ~= "" and errorText or uiText.tr("bar." .. statusKey, { station = station })
        local detail = track ~= "" and track ~= station and "\n" .. track or ""
        local volumeText = muted and uiText.tr("bar.muted") or tostring(math.floor(volume)) .. "%"
        local protection = isolation == "full" and "\n" .. uiText.tr("player.full_protection")
            or (isolation == "compatible" and "\n" .. uiText.tr("player.compatible_protection") or "")
        barWidget.setTooltip(status .. detail .. " · " .. volumeText .. protection
            .. "\n" .. uiText.tr("bar.controls"))
    elseif errorText ~= "" then
        barWidget.setTooltip(errorText .. "\n" .. uiText.tr("bar.controls"))
    else
        barWidget.setTooltip(uiText.tr("bar.stopped_tooltip"))
    end
end

local function requestRender()
    renderPending = true
    noctalia.setUpdateInterval(50)
end

noctalia.state.watch("radio_tellus_playback", function(value)
    applyPlaybackSnapshot(value)
    requestRender()
end)

function update()
    if renderPending then
        renderPending = false
        render()
    end
    noctalia.setUpdateInterval(renderPending and 50 or 60000)
end

function onClick()
    noctalia.togglePanel("scurolabs/radio-tellus:panel")
end

function onRightClick()
    shared.stop()
end

function onScroll(axis, steps)
    if axis ~= "vertical" then return end
    volume = shared.clampInteger(volume - (tonumber(steps) or 0) * volumeStep, volume, 0, 100)
    shared.setVolume(volume)
    requestRender()
end

render()
