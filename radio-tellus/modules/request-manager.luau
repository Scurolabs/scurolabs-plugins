--!nonstrict
-- Owns accepted asynchronous requests so consumers can ignore stale work.
-- Ordinary Noctalia HTTP has no transport-cancellation handle. Logical
-- cancellation releases the panel slot, while nativeActive remains occupied
-- until the host delivers completion or its finite request timeout fires.

local manager = {}
local profiling = require("./profiling.luau")
local DEFAULT_MAX_ACTIVE = 4
local DEFAULT_MAX_NATIVE_ACTIVE = 8

function manager.new(options)
    local configuredLimit = type(options) == "table" and tonumber(options.maxActive) or nil
    local maxActive = math.floor(configuredLimit or DEFAULT_MAX_ACTIVE)
    if maxActive < 1 then maxActive = DEFAULT_MAX_ACTIVE end
    local configuredNativeLimit = type(options) == "table" and tonumber(options.maxNativeActive) or nil
    local maxNativeActive = math.floor(configuredNativeLimit or DEFAULT_MAX_NATIVE_ACTIVE)
    if maxNativeActive < maxActive then maxNativeActive = maxActive end
    local self = {
        requests = {}, epoch = 0, active = 0, nativeActive = 0,
        maxActive = maxActive, maxNativeActive = maxNativeActive,
    }

    function self:request(kind, requestKey, start, callback)
        if type(start) ~= "function" or type(callback) ~= "function" then
            return false
        end
        local normalizedKind = tostring(kind or "")
        local normalizedKey = tostring(requestKey or "")
        local id = normalizedKind .. "\0" .. normalizedKey
        local existing = self.requests[id]
        if existing ~= nil then
            profiling.count("request_reuses")
            table.insert(existing.waiters, callback)
            return true
        end
        if self.active >= self.maxActive or self.nativeActive >= self.maxNativeActive then
            profiling.count("request_rejections")
            return false
        end

        local request = {
            waiters = { callback }, completed = false, transportCompleted = false, active = true,
            startedAt = noctalia.nowMs(),
        }
        local epoch = self.epoch
        self.active += 1
        self.nativeActive += 1
        profiling.count("request_starts")
        self.requests[id] = request
        local function completeTransport(response, errorMessage)
            if request.transportCompleted then return end
            request.transportCompleted = true
            self.nativeActive = math.max(0, self.nativeActive - 1)
            profiling.duration("request", request.startedAt)
            if request.completed then return end
            request.completed = true
            if request.active then
                request.active = false
                self.active = math.max(0, self.active - 1)
            end
            if self.requests[id] == request then self.requests[id] = nil end
            local waiters = request.waiters
            request.waiters = {}
            if epoch ~= self.epoch then return end
            for _, waiter in ipairs(waiters) do waiter(response, errorMessage) end
        end

        local function cancel()
            if request.completed then return end
            request.waiters = {}
            request.completed = true
            request.active = false
            self.active = math.max(0, self.active - 1)
            if self.requests[id] == request then self.requests[id] = nil end
        end
        request.cancel = cancel

        local started = start(completeTransport)
        local accepted = started == true
        if not accepted then
            if not request.transportCompleted then
                request.transportCompleted = true
                self.nativeActive = math.max(0, self.nativeActive - 1)
            end
            request.completed = true
            if request.active then
                request.active = false
                self.active = math.max(0, self.active - 1)
            end
            request.waiters = {}
            if self.requests[id] == request then self.requests[id] = nil end
        end
        return accepted
    end

    function self:invalidate()
        self.epoch += 1
        local pending = {}
        for _, request in pairs(self.requests) do table.insert(pending, request) end
        for _, request in ipairs(pending) do request.cancel() end
        self.requests = {}
    end

    function self:activeCount()
        return self.active
    end

    function self:nativeActiveCount()
        return self.nativeActive
    end

    return self
end

return manager
