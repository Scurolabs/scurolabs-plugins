--!nonstrict
-- Numeric normalization at configuration, state, and protocol boundaries.

local numeric = {}

function numeric.finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

function numeric.floorOr(value, fallback)
    return math.floor(numeric.finite(value) or numeric.finite(fallback) or 0)
end

function numeric.clampInteger(value, fallback, minimum, maximum)
    local number = numeric.floorOr(value, fallback)
    return math.max(minimum, math.min(maximum, number))
end

function numeric.nonNegativeInteger(value)
    local number = numeric.finite(value)
    if number == nil or number < 0 or number ~= math.floor(number) then return nil end
    return number
end

return numeric
