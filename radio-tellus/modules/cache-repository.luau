--!nonstrict
-- Panel cache ownership. Disk reads are asynchronous and cache files stay disposable.

local storage = require("./storage-utils.luau")
local station = require("./station-utils.luau")
local catalog = require("./catalog.luau")
local profiling = require("./profiling.luau")
local numeric = require("./numeric-utils.luau")

local repository = {}
local MAX_RECENT_CACHES = 8

local function boundedLimit(value)
    return math.max(0, math.min(station.MAX_CATALOG_STATIONS, numeric.floorOr(value, 0)))
end

function repository.new()
    local self = { cache = {}, order = {}, activeName = nil, writes = {}, epoch = 0 }

    function self:touch(name)
        for index, value in ipairs(self.order) do
            if value == name then table.remove(self.order, index); break end
        end
        table.insert(self.order, 1, name)
        while #self.order > MAX_RECENT_CACHES do
            local removed
            for index = #self.order, 1, -1 do
                local candidate = self.order[index]
                local entry = self.cache[candidate]
                if candidate ~= self.activeName and (entry == nil or not entry.loading) then
                    removed = table.remove(self.order, index)
                    break
                end
            end
            if removed == nil then break end
            self.cache[removed] = nil
        end
    end

    function self:setActive(name)
        self.activeName = name
        if name ~= nil then self:touch(name) end
    end

    function self:get(name)
        local entry = self.cache[name]
        if entry ~= nil then self:touch(name) end
        return entry
    end

    function self:isFresh(name, seconds, minimumLimit)
        local entry = self.cache[name]
        if entry == nil or entry.rows == nil then return false end
        local required = boundedLimit(minimumLimit)
        if type(entry.requestedLimit) == "number" and entry.requestedLimit < required then return false end
        if type(entry.requestedLimit) ~= "number" and #entry.rows < required then return false end
        local ttl = math.max(0, numeric.finite(seconds) or 0)
        local modified = numeric.finite(entry.modifiedTime)
        local age = modified and os.time() - modified or nil
        if age ~= nil then return age >= 0 and age < ttl end
        local loaded = numeric.finite(entry.loadedAt)
        local loadedAge = loaded and math.floor(noctalia.nowMs()) - loaded or nil
        return loadedAge ~= nil and loadedAge >= 0 and loadedAge < ttl * 1000
    end

    function self:finish(name, entry, rows, requestedLimit, modifiedTime, errorMessage)
        entry.loading = false
        entry.rows = rows or {}
        entry.requestedLimit = requestedLimit
        entry.modifiedTime = modifiedTime
        entry.loadedAt = math.floor(noctalia.nowMs())
        local waiters = entry.waiters
        entry.waiters = {}
        self:touch(name)
        for _, waiter in ipairs(waiters) do waiter(entry.rows, errorMessage, entry) end
    end

    function self:load(name, maximum, callback, force)
        if type(callback) ~= "function" then return false end
        local entry = self.cache[name]
        if entry ~= nil and entry.loading then
            table.insert(entry.waiters, callback)
            return true
        end
        if entry ~= nil and entry.rows ~= nil and force ~= true then
            profiling.count("cache_hits")
            self:touch(name)
            callback(entry.rows, nil, entry)
            return true
        end
        entry = entry or { rows = nil, requestedLimit = nil, modifiedTime = nil,
            loadedAt = nil, loading = false, waiters = {}, loadSerial = 0 }
        self.cache[name] = entry
        self:touch(name)
        table.insert(entry.waiters, callback)
        entry.loading = true
        entry.loadSerial = (entry.loadSerial or 0) + 1
        profiling.count("cache_misses")
        local epoch = self.epoch
        local loadSerial = entry.loadSerial
        local startedAt = noctalia.nowMs()
        local modifiedTime
        local completed = false
        local function finish(raw, err, info)
            if completed then return end
            completed = true
            if epoch ~= self.epoch or loadSerial ~= entry.loadSerial or not entry.loading then return end
            profiling.duration("cache_read", startedAt)
            local stations = type(raw) == "table" and raw.stations or raw
            local persistedLimit = type(raw) == "table" and type(raw.stations) == "table"
                and raw.requested_limit or nil
            local requestedLimit = persistedLimit ~= nil and boundedLimit(persistedLimit) or nil
            local clean = station.sanitizeStations(stations, maximum)
            local rows = catalog.fromSanitized(clean, maximum)
            modifiedTime = info and tonumber(info.mtime) or modifiedTime
            self:finish(name, entry, rows, requestedLimit, modifiedTime, err)
        end
        local accepted = storage.readJsonAsync(name, storage.MAX_BYTES, finish)
        profiling.count("cache_reads")
        if not accepted and not completed then finish(nil, "unreadable") end
        return accepted
    end

    function self:queueWrite(name, rows, requestedLimit)
        self.writes[name] = {
            rows = catalog.toStations(rows),
            requestedLimit = boundedLimit(requestedLimit),
        }
        return true
    end

    function self:publish(name, rows, requestedLimit)
        local entry = self.cache[name] or { waiters = {} }
        self.cache[name] = entry
        entry.loadSerial = (entry.loadSerial or 0) + 1
        entry.rows = rows or {}
        entry.requestedLimit = boundedLimit(requestedLimit)
        entry.modifiedTime = nil
        entry.loadedAt = math.floor(noctalia.nowMs())
        entry.loading = false
        self:touch(name)
        self:queueWrite(name, entry.rows, entry.requestedLimit)
        local waiters = entry.waiters
        entry.waiters = {}
        for _, waiter in ipairs(waiters) do waiter(entry.rows, nil, entry) end
        return true
    end

    function self:flushWrites()
        local pending = self.writes
        self.writes = {}
        for name, value in pairs(pending) do
            local ok = storage.writeJson(name, {
                stations = station.limitSanitizedStations(value.rows, station.MAX_CATALOG_STATIONS),
                requested_limit = value.requestedLimit,
            }, storage.MAX_BYTES)
            if ok then
                local entry = self.cache[name]
                if entry ~= nil then
                    local path = storage.dataPath(name)
                    local info = path and noctalia.fileInfo(path) or nil
                    entry.modifiedTime = info and tonumber(info.mtime) or entry.modifiedTime
                end
            end
        end
    end

    function self:invalidate()
        self.epoch += 1
        for _, entry in pairs(self.cache) do
            entry.loadSerial = (entry.loadSerial or 0) + 1
            if entry.loading then entry.loading, entry.waiters = false, {} end
        end
    end

    return self
end

return repository
