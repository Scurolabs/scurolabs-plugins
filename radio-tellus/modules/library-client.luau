--!nonstrict
-- Serializes one entry's library mutations through the shared state service.

local protocol = require("./library-protocol.luau")

local client = {}
client.__index = client

local function callbackResult(callback, result)
    if type(callback) == "function" then
        callback(result and result.ok == true, result and result.error)
    end
end

function client.new(source)
    local self = setmetatable({
        source = source,
        queue = {},
        active = nil,
        ready = noctalia.state.get(protocol.READY_KEY) == true,
    }, client)

    noctalia.state.watch(protocol.READY_KEY, function(value)
        if value ~= true then
            self.ready = false
            if self.active ~= nil then
                noctalia.log("radio-tellus library client service unavailable; pending mutation will be retried")
            end
            self.active = nil
            return
        end
        self.ready = true
        self:drain()
    end)
    noctalia.state.watch(protocol.RESULT_KEY, function(result)
        if type(result) ~= "table" or tostring(result.source or "") ~= self.source
            or self.active == nil or tostring(result.request_id or "") ~= self.active.id then return end
        local active = self.active
        self.active = nil
        table.remove(self.queue, 1)
        protocol.compactEvents(active.key, active.id)
        callbackResult(active.callback, result)
        self:drain()
    end)
    return self
end

function client:drain()
    if not self.ready or self.active ~= nil or #self.queue == 0 then return end
    local nextEvent = self.queue[1]
    self.active = nextEvent
    local accepted = protocol.appendEvent(nextEvent.key, {
        id = nextEvent.id,
        action = nextEvent.action,
        station = nextEvent.station,
        position = nextEvent.position,
    })
    if accepted then return end
    self.active = nil
    table.remove(self.queue, 1)
    callbackResult(nextEvent.callback, { ok = false, error = "Too many library changes are waiting to be saved." })
    self:drain()
end

function client:enqueue(action, station, callback, position)
    if type(action) ~= "string" or type(station) ~= "table" then return false end
    local key = self.source == "playback" and protocol.PLAYBACK_EVENTS_KEY or protocol.PANEL_EVENTS_KEY
    local event = { id = protocol.nextEventId(self.source), key = key, action = action,
        station = station, position = position, callback = callback }
    table.insert(self.queue, event)
    self:drain()
    return true
end

return client
