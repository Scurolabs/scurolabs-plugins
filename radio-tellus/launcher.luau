--!nonstrict
local shared = require("./modules/shared.luau")
local uiText = require("./modules/ui.luau")
local stationDisplay = require("./modules/station-display.luau")
local protocol = require("./modules/library-protocol.luau")
local initialLibrary = noctalia.state.get(protocol.DATA_KEY) or noctalia.state.get(protocol.SNAPSHOT_KEY)
local favorites = type(initialLibrary) == "table" and initialLibrary.favorites or {}
local activationStations, activationQueue = {}, {}

noctalia.state.watch(protocol.DATA_KEY, function(value)
    if type(value) == "table" and type(value.favorites) == "table" then
        favorites = value.favorites
    end
end)

local function play(station, queue)
    if station == nil then return end
    if tostring(noctalia.state.get("player_state") or "stopped") == "starting" then
        uiText.notify("Radio Tellus", shared.PLAYBACK_STARTING_MESSAGE, true)
        return
    end
    if not shared.setQueueValidated(queue, station) then
        uiText.notify("Radio Tellus", "Your station queue could not be saved. Try again.", true)
        return
    end
    local ok, err = shared.play(station, nil, function(started, asyncError)
        if not started then
            uiText.notify("Radio Tellus", asyncError or "The station could not start playing. Try another station.", true)
        end
    end)
    if not ok then uiText.notify("Radio Tellus", err, true) end
end

function onQuery(query)
    local needle = shared.trim(query)
    activationStations, activationQueue = {}, favorites
    local rows = {
        { id = "open", title = uiText.tr("launcher.open"), subtitle = uiText.tr("launcher.browse"), glyph = "radio" },
        { id = "random", title = uiText.tr("launcher.random"), subtitle = uiText.tr("launcher.cached"), glyph = "arrows-shuffle" },
    }
    for index, station in ipairs(favorites) do
        if shared.matchesSearch(station, needle) then
            local id = "favorite:" .. tostring(index)
            local country = stationDisplay.countryName(station.country, station.country_code)
            activationStations[id] = station
            table.insert(rows, {
                id = id,
                title = station.name,
                subtitle = country ~= "" and uiText.tr("launcher.favorite", { country = country })
                    or uiText.tr("launcher.internet_radio"),
                glyph = "star-filled",
            })
            if #rows >= 42 then break end
        end
    end
    launcher.setResults(query, rows)
end

function onActivate(id)
    if id:match("^favorite:%d+$") then play(activationStations[id], activationQueue); return end
    if id == "random" then
        local stations = shared.loadCache(shared.DISCOVER_CACHE_FILE, shared.MAX_CATALOG_STATIONS)
        local station = shared.randomStationValidated(stations)
        if station then
            play(station, stations)
        elseif #stations == 0 then
            uiText.notify("Radio Tellus", "Open Radio Tellus once to load recent stations, then try again.", true)
        else
            uiText.notify("Radio Tellus", "No saved station is currently safe to play. Open Radio Tellus to refresh the station list.", true)
        end
        return
    end
    noctalia.togglePanel("scurolabs/radio-tellus:panel")
end
