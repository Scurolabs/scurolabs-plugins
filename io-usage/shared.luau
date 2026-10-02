--!nonstrict

local M = {
    stateKey = "sample",
    sampleIntervalMs = 1000,
}

local minStabilityWidth = 40
local maxStabilityWidth = 240
local maxAverageWindowSeconds = 60
local separateDisplaySeparator = " • "

local function validSectorCounter(value)
    return type(value) == "number"
        and value >= 0
        and value == value
        and value ~= math.huge
        and value == math.floor(value)
end

function M.isRecognizedDevice(name)
    return type(name) == "string"
        and name ~= ""
        and not name:match("^dm%-%d+$")
        and not name:match("^loop%d+$")
        and not name:match("^md")
        and not name:match("^ram%d+$")
        and not name:match("^zram%d+$")
        and not name:match("^sr%d+$")
end

function M.parseDiskstats(contents, recognizedDevices)
    if type(contents) ~= "string" or type(recognizedDevices) ~= "table" then
        return nil, "invalid_input"
    end

    local counters = {}
    for line in contents:gmatch("[^\r\n]+") do
        local fields = {}
        for field in line:gmatch("%S+") do
            fields[#fields + 1] = field
        end

        local name = fields[3]
        if #fields >= 10 and recognizedDevices[name] then
            if counters[name] ~= nil then return nil, "duplicate_device" end
            local readSectors = tonumber(fields[6])
            local writeSectors = tonumber(fields[10])
            if not validSectorCounter(readSectors) or not validSectorCounter(writeSectors) then
                return nil, "malformed_counter"
            end
            counters[name] = {
                readSectors = readSectors,
                writeSectors = writeSectors,
            }
        end
    end

    for name in pairs(recognizedDevices) do
        if counters[name] == nil then return nil, "missing_device" end
    end
    for name in pairs(counters) do
        if not recognizedDevices[name] then return nil, "unexpected_device" end
    end
    if next(counters) == nil then return nil, "empty_sample" end
    return counters, nil
end

function M.sameDeviceSet(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for name in pairs(left) do
        if right[name] == nil then return false end
    end
    for name in pairs(right) do
        if left[name] == nil then return false end
    end
    return true
end

function M.counterDeltas(previous, current)
    if type(previous) ~= "table" or type(current) ~= "table" then
        return nil, "invalid_counters"
    end
    if not M.sameDeviceSet(previous, current) then
        return nil, "device_set_changed"
    end

    local readSectors = 0
    local writeSectors = 0
    for name, oldCounters in pairs(previous) do
        local newCounters = current[name]
        if type(oldCounters) ~= "table" or type(newCounters) ~= "table" then
            return nil, "invalid_counters"
        end
        if not validSectorCounter(oldCounters.readSectors)
            or not validSectorCounter(oldCounters.writeSectors)
            or not validSectorCounter(newCounters.readSectors)
            or not validSectorCounter(newCounters.writeSectors) then
            return nil, "invalid_counters"
        end

        local readDelta = newCounters.readSectors - oldCounters.readSectors
        local writeDelta = newCounters.writeSectors - oldCounters.writeSectors
        if readDelta < 0 or writeDelta < 0 then
            return nil, "counter_reset"
        end
        readSectors = readSectors + readDelta
        writeSectors = writeSectors + writeDelta
    end

    return {
        readSectors = readSectors,
        writeSectors = writeSectors,
    }, nil
end

function M.isUsableElapsedMs(value, maximum)
    return type(value) == "number"
        and value > 0
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and type(maximum) == "number"
        and maximum > 0
        and value <= maximum
end

function M.emptySample(errorMessage)
    return {
        ready = false,
        error = errorMessage or "warming_up",
        readBytesPerSec = 0,
        writeBytesPerSec = 0,
        totalBytesPerSec = 0,
        sampledAtMs = 0,
    }
end

local function finiteNonNegative(value)
    local number = tonumber(value)
    if number == nil or number < 0 or number ~= number or number == math.huge then
        return 0
    end
    return number
end

function M.normalizeSample(value)
    local sample = M.emptySample()
    if type(value) ~= "table" then return sample end

    sample.ready = value.ready == true
    sample.error = type(value.error) == "string" and value.error or sample.error
    sample.readBytesPerSec = finiteNonNegative(value.readBytesPerSec)
    sample.writeBytesPerSec = finiteNonNegative(value.writeBytesPerSec)
    sample.totalBytesPerSec = finiteNonNegative(value.totalBytesPerSec)
    sample.sampledAtMs = finiteNonNegative(value.sampledAtMs)

    if sample.totalBytesPerSec == 0 then
        sample.totalBytesPerSec = sample.readBytesPerSec + sample.writeBytesPerSec
    end
    if not sample.ready then
        sample.readBytesPerSec = 0
        sample.writeBytesPerSec = 0
        sample.totalBytesPerSec = 0
    end
    return sample
end

function M.formatRate(bytesPerSec, compact, roundingMode)
    local rate = finiteNonNegative(bytesPerSec)
    local units = { "B/s", "KiB/s", "MiB/s", "GiB/s" }
    local index = 1
    while rate >= 1024 and index < #units do
        rate = rate / 1024
        index = index + 1
    end

    local wholeNumber = roundingMode == "nearest"
    if roundingMode == "nearest" then
        rate = math.floor(rate + 0.5)
    end

    if compact then
        if index == 1 then
            if wholeNumber then return string.format("%.0fB", rate) end
            return string.format("%.1fB", rate)
        end
        if wholeNumber then return string.format("%.0f%s", rate, units[index]:sub(1, 1)) end
        return string.format("%.1f%s", rate, units[index]:sub(1, 1))
    end
    if index == 1 then
        if wholeNumber then return string.format("%.0f %s", rate, units[index]) end
        return string.format("%.1f %s", rate, units[index])
    end
    if wholeNumber then return string.format("%.0f %s", rate, units[index]) end
    return string.format("%.1f %s", rate, units[index])
end

function M.formatDisplayValue(sample, displayMode, roundingMode)
    if type(sample) ~= "table" or sample.ready ~= true then return nil end

    if displayMode == "separate" then
        return M.formatRate(sample.readBytesPerSec, true, roundingMode)
            .. separateDisplaySeparator
            .. M.formatRate(sample.writeBytesPerSec, true, roundingMode)
    end

    local rate = sample.totalBytesPerSec
    if displayMode == "read" then
        rate = sample.readBytesPerSec
    elseif displayMode == "write" then
        rate = sample.writeBytesPerSec
    end
    return M.formatRate(rate, false, roundingMode)
end

function M.stabilityWidth(value)
    if type(value) ~= "number" or value <= 0 or value ~= value or value == math.huge then
        return nil
    end
    local width = math.floor(value)
    if width < minStabilityWidth then return nil end
    return math.min(width, maxStabilityWidth)
end

function M.averageWindowMs(value)
    if type(value) ~= "number" or value < 1 or value ~= value or value == math.huge then
        return 1000
    end
    return math.min(math.floor(value), maxAverageWindowSeconds) * 1000
end

return M
