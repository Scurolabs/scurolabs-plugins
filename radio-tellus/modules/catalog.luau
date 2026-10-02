--!nonstrict
-- Panel-facing station rows keep derived values beside the validated station.

local station = require("./station-utils.luau")
local display = require("./station-display.luau")
local profiling = require("./profiling.luau")
local numeric = require("./numeric-utils.luau")
local catalog = {}

-- station.stationKey normalizes and bounds the identity before it reaches the
-- UI. Preserve that exact identity so row keys require no callback hashing.
local function boundedUiKey(key)
    return "station-" .. key
end

local function buildRows(stations, limit)
    profiling.count("catalog_builds")
    local rows = {}
    local maximum = math.max(0, math.min(station.MAX_PERSISTED_STATIONS,
        numeric.floorOr(limit, station.MAX_CATALOG_STATIONS)))
    if type(stations) ~= "table" or maximum == 0 then return rows end
    for _, value in ipairs(stations) do
        if type(value) == "table" then
            local key = station.stationKey(value)
            if key ~= "" then
                table.insert(rows, {
                    station = value,
                    key = key,
                    uiKey = boundedUiKey(key),
                    metadata = display.stationMeta(value),
                })
                profiling.count("rows_constructed")
                if #rows >= maximum then break end
            end
        end
    end
    return rows
end

function catalog.fromSanitized(stations, limit)
    return buildRows(stations, limit)
end

function catalog.toStations(rows)
    local stations = {}
    for _, row in ipairs(rows or {}) do
        if type(row) == "table" and type(row.station) == "table" then
            table.insert(stations, row.station)
        end
    end
    return stations
end

function catalog.limit(rows, limit)
    local bounded = math.max(0, math.min(station.MAX_CATALOG_STATIONS,
        numeric.floorOr(limit, station.MAX_CATALOG_STATIONS)))
    local result = {}
    for index, row in ipairs(rows or {}) do
        if index > bounded then break end
        table.insert(result, row)
    end
    return result
end

function catalog.sortByVotes(rows)
    local ranked = {}
    for index, row in ipairs(rows or {}) do
        local stationValue = type(row) == "table" and row.station
        local votes = type(stationValue) == "table" and numeric.finite(stationValue.votes) or nil
        table.insert(ranked, { row = row, index = index, votes = math.max(0, votes or 0) })
    end
    table.sort(ranked, function(left, right)
        if left.votes == right.votes then return left.index < right.index end
        return left.votes > right.votes
    end)
    local sorted = {}
    for _, item in ipairs(ranked) do table.insert(sorted, item.row) end
    return sorted
end

function catalog.merge(groups, limit)
    local maximum = math.max(0, math.min(station.MAX_CATALOG_STATIONS,
        numeric.floorOr(limit, station.MAX_CATALOG_STATIONS)))
    local rows, seen = {}, {}
    for _, group in ipairs(groups or {}) do
        for _, row in ipairs(group or {}) do
            local key = type(row) == "table" and row.key or ""
            if key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(rows, row)
                if #rows >= maximum then return rows end
            end
        end
    end
    return rows
end

return catalog
