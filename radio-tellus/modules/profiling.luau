--!nonstrict
-- Optional counters stay silent unless the maintainer explicitly enables them.

local profiling = { enabled = false, counters = {}, samples = {}, maximums = {} }
local getenv = noctalia.getenv
if type(getenv) == "function" then profiling.enabled = getenv("RADIO_TELLUS_PROFILE") == "1" end

local function updateMaximum(key, value)
    if value > (profiling.maximums[key] or 0) then profiling.maximums[key] = value end
end

function profiling.count(name, amount)
    if not profiling.enabled then return end
    local key = tostring(name or "operation")
    profiling.counters[key] = (profiling.counters[key] or 0) + (tonumber(amount) or 1)
end

function profiling.duration(name, startedAt)
    if not profiling.enabled then return end
    local elapsed = math.max(0, math.floor(noctalia.nowMs()) - (tonumber(startedAt) or 0))
    local key = tostring(name or "operation") .. ".duration_ms"
    profiling.count(key, elapsed)
    profiling.samples[key] = (profiling.samples[key] or 0) + 1
    updateMaximum(key, elapsed)
end

function profiling.snapshot()
    local copy = { counters = {}, samples = {}, maximums = {} }
    for key, value in pairs(profiling.counters) do copy.counters[key] = value end
    for key, value in pairs(profiling.samples) do copy.samples[key] = value end
    for key, value in pairs(profiling.maximums) do copy.maximums[key] = value end
    return copy
end

function profiling.report()
    if not profiling.enabled then return false end
    local snapshot = profiling.snapshot()
    noctalia.log("radio-tellus profile: " .. tostring(noctalia.json.encode(snapshot)))
    return true
end

return profiling
