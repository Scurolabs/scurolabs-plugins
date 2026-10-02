--!nonstrict

local shared = require("./shared.luau")
local sectorSize = 512

local M = {}

local function resetAverageWindow(state)
    state.windowReadBytes = 0
    state.windowWriteBytes = 0
    state.windowElapsedMs = 0
end

function M.new(averageWindowMs)
    return {
        averageWindowMs = averageWindowMs,
        maxSampleGapMs = shared.sampleIntervalMs * 3,
        previousCounters = nil,
        previousCountersAtMs = nil,
        windowReadBytes = 0,
        windowWriteBytes = 0,
        windowElapsedMs = 0,
    }
end

function M.process(state, counters, nowMs)
    if type(nowMs) ~= "number" then
        return nil, "warming_up"
    end

    if state.previousCounters == nil or state.previousCountersAtMs == nil then
        state.previousCounters = counters
        state.previousCountersAtMs = nowMs
        resetAverageWindow(state)
        return nil, "warming_up"
    end

    local elapsedMs = nowMs - state.previousCountersAtMs
    local deltas = shared.counterDeltas(state.previousCounters, counters)
    state.previousCounters = counters
    state.previousCountersAtMs = nowMs

    if not shared.isUsableElapsedMs(elapsedMs, state.maxSampleGapMs) or deltas == nil then
        resetAverageWindow(state)
        return nil, "warming_up"
    end

    state.windowReadBytes = state.windowReadBytes + deltas.readSectors * sectorSize
    state.windowWriteBytes = state.windowWriteBytes + deltas.writeSectors * sectorSize
    state.windowElapsedMs = state.windowElapsedMs + elapsedMs
    if state.windowElapsedMs < state.averageWindowMs then return nil, nil end

    local readBytesPerSec = state.windowReadBytes * 1000 / state.windowElapsedMs
    local writeBytesPerSec = state.windowWriteBytes * 1000 / state.windowElapsedMs
    local sample = {
        ready = true,
        error = "",
        readBytesPerSec = readBytesPerSec,
        writeBytesPerSec = writeBytesPerSec,
        totalBytesPerSec = readBytesPerSec + writeBytesPerSec,
        sampledAtMs = nowMs,
    }
    resetAverageWindow(state)
    return sample, nil
end

return M
