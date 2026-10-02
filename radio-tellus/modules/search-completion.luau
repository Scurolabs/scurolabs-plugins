--!nonstrict
-- Search request completion state shared by the panel and runtime tests.

local completion = {}

function completion.new(total)
    local pending = math.max(0, math.floor(tonumber(total) or 0))
    return {
        pending = pending,
        failures = 0,
        processingFailures = 0,
        groups = {},
        loading = pending > 0,
    }
end

local function isCurrent(state, current)
    return type(state) == "table" and current == true and state.pending > 0
end

function completion.complete(state, current, parse)
    if not isCurrent(state, current) then return false end
    state.pending -= 1
    if state.pending == 0 then state.loading = false end

    local ok, rows, _, processingFailure = pcall(parse)
    if not ok then rows, processingFailure = nil, true end
    if rows == nil then
        state.failures += 1
        if processingFailure then state.processingFailures += 1 end
    else
        table.insert(state.groups, rows)
    end
    return state.pending == 0
end

function completion.reject(state, current)
    if not isCurrent(state, current) then return false end
    state.pending -= 1
    state.failures += 1
    if state.pending == 0 then state.loading = false end
    return state.pending == 0
end

return completion
