--!nonstrict
-- Shared names and bounded event helpers for the library state service.

local protocol = {}

protocol.SNAPSHOT_KEY = "radio_tellus_library_snapshot"
protocol.DATA_KEY = "radio_tellus_library_data"
protocol.STATUS_KEY = "radio_tellus_library_status"
protocol.READY_KEY = "radio_tellus_library_ready"
protocol.RESULT_KEY = "radio_tellus_library_result"
protocol.PANEL_EVENTS_KEY = "radio_tellus_library_panel_events"
protocol.PLAYBACK_EVENTS_KEY = "radio_tellus_library_playback_events"
protocol.PANEL_ACK_KEY = "radio_tellus_library_panel_ack"
protocol.PLAYBACK_ACK_KEY = "radio_tellus_library_playback_ack"
protocol.MAX_EVENTS = 32
protocol.MAX_TRACKED_EVENT_IDS = protocol.MAX_EVENTS * 2
protocol.MAX_EVENT_ID = 96

local eventSerial = 0

local function boundedEventId(value)
    local text = tostring(value or "")
    if #text > protocol.MAX_EVENT_ID then return text:sub(1, protocol.MAX_EVENT_ID) end
    return text
end

function protocol.nextEventId(source)
    eventSerial += 1
    return boundedEventId(table.concat({ tostring(source or "event"), tostring(math.floor(noctalia.nowMs())),
        tostring(eventSerial), tostring(math.random(100000, 999999)) }, "-"))
end

function protocol.appendEvent(key, event)
    if type(event) ~= "table" or boundedEventId(event.id) == "" then return false end
    local existing = noctalia.state.get(key)
    local events = type(existing) == "table" and existing or {}
    local nextEvents = {}
    for _, value in ipairs(events) do
        if type(value) == "table" and boundedEventId(value.id) ~= boundedEventId(event.id) then
            table.insert(nextEvents, value)
        end
    end
    if #nextEvents >= protocol.MAX_EVENTS then return false end
    table.insert(nextEvents, {
        id = boundedEventId(event.id),
        action = tostring(event.action or ""),
        station = event.station,
        position = event.position,
    })
    noctalia.state.set(key, nextEvents)
    return true
end

function protocol.compactEvents(key, acknowledged)
    local events = noctalia.state.get(key)
    if type(events) ~= "table" then return end
    local compacted, found = {}, false
    for _, event in ipairs(events) do
        if found then table.insert(compacted, event)
        elseif type(event) == "table" and tostring(event.id or "") == tostring(acknowledged or "") then
            found = true
        end
    end
    if found then noctalia.state.set(key, compacted) end
end

return protocol
