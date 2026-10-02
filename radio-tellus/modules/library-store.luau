--!nonstrict
-- Panel-facing client for the shared library state service.

local shared = require("./shared.luau")
local protocol = require("./library-protocol.luau")
local Client = require("./library-client.luau")

local store = {}

local function defaultSnapshot()
    return {
        favorites = {}, recent = {}, volume = shared.DEFAULT_VOLUME,
        volume_set = false, muted = false, ready = false, dirty = false,
        error = "", revision = "",
        content_revision = "",
    }
end

function store.new()
    local initial = noctalia.state.get(protocol.SNAPSHOT_KEY)
    local self = {
        snapshot = type(initial) == "table" and initial or defaultSnapshot(),
        data = noctalia.state.get(protocol.DATA_KEY),
        status = noctalia.state.get(protocol.STATUS_KEY),
        loading = noctalia.state.get(protocol.READY_KEY) ~= true,
        waiters = {},
        subscribers = {},
        pendingFavorites = {},
        pendingFavoriteMoves = {},
        client = Client.new("panel"),
    }

    local function notify(err)
        local waiters = self.waiters
        self.waiters = {}
        for _, callback in ipairs(waiters) do callback(self.snapshot, err) end
        for _, callback in ipairs(self.subscribers) do callback(self.snapshot, err) end
    end

    local function currentError()
        local message = tostring(self.snapshot.error or "")
        return message ~= "" and message or nil
    end

    local function rebuildSnapshot()
        local snapshot = self.snapshot
        if type(self.data) == "table" then
            snapshot.favorites = type(self.data.favorites) == "table" and self.data.favorites or {}
            snapshot.recent = type(self.data.recent) == "table" and self.data.recent or {}
            snapshot.ready = self.data.ready == true
            snapshot.content_revision = tostring(self.data.content_revision or "")
        end
        if type(self.status) == "table" then
            snapshot.ready = self.status.ready == true
            snapshot.dirty = self.status.dirty == true
            snapshot.error = tostring(self.status.error or "")
            snapshot.revision = tostring(self.status.revision or "")
        end
        if snapshot.content_revision == nil then snapshot.content_revision = "legacy" end
        self.snapshot = snapshot
        self.loading = snapshot.ready ~= true
    end

    rebuildSnapshot()

    noctalia.state.watch(protocol.DATA_KEY, function(value)
        if type(value) ~= "table" then return end
        self.data = value
        rebuildSnapshot()
        notify(self.snapshot.error ~= "" and self.snapshot.error or nil)
    end)

    noctalia.state.watch(protocol.STATUS_KEY, function(value)
        if type(value) ~= "table" then return end
        self.status = value
        rebuildSnapshot()
        notify(self.snapshot.error ~= "" and self.snapshot.error or nil)
    end)

    noctalia.state.watch(protocol.SNAPSHOT_KEY, function(value)
        if type(value) ~= "table" then return end
        self.snapshot = value
        self.data = value
        self.status = value
        rebuildSnapshot()
        notify(self.snapshot.error ~= "" and self.snapshot.error or nil)
    end)
    noctalia.state.watch(protocol.READY_KEY, function(value)
        self.loading = value ~= true
        if value == true then notify(currentError()) end
    end)

    function self:load(callback)
        if type(callback) == "function" then table.insert(self.waiters, callback) end
        if not self.loading then
            notify(currentError())
            return true
        end
        return true
    end

    function self:subscribe(callback)
        if type(callback) ~= "function" then return false end
        table.insert(self.subscribers, callback)
        return true
    end

    function self:get()
        return self.snapshot
    end

    function self:toggleFavorite(value, callback)
        local station = type(value) == "table" and value.station or value
        if type(station) ~= "table" then return false end
        local key = shared.stationKey(station)
        local current = self.pendingFavorites[key]
        if current == nil then current = shared.isFavorite(self.snapshot.favorites, station) ~= nil end
        local desired = not current
        self.pendingFavorites[key] = desired
        local action = desired and "favorite_on" or "favorite_off"
        local accepted = self.client:enqueue(action, station, function(ok, err)
            if self.pendingFavorites[key] == desired then self.pendingFavorites[key] = nil end
            if type(callback) == "function" then callback(ok, err) end
        end)
        if not accepted and self.pendingFavorites[key] == desired then self.pendingFavorites[key] = nil end
        return accepted
    end

    function self:moveFavorite(value, position, callback)
        local station = type(value) == "table" and value.station or value
        if type(station) ~= "table" or type(position) ~= "number" then return false end
        if position ~= position or position == math.huge or position == -math.huge then return false end
        local target = math.floor(position)
        if target ~= position or target < 1 then return false end
        local key = shared.stationKey(station)
        if key == "" or self.pendingFavoriteMoves[key] ~= nil then return false end
        self.pendingFavoriteMoves[key] = target
        local accepted = self.client:enqueue("favorite_move", station, function(ok, err)
            if self.pendingFavoriteMoves[key] == target then self.pendingFavoriteMoves[key] = nil end
            if type(callback) == "function" then callback(ok, err) end
        end, target)
        if not accepted and self.pendingFavoriteMoves[key] == target then
            self.pendingFavoriteMoves[key] = nil
        end
        return accepted
    end

    function self:hasFavoriteMovePending()
        return next(self.pendingFavoriteMoves) ~= nil
    end

    function self:invalidate()
        self.waiters = {}
    end

    return self
end

return store
