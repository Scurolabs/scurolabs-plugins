--!nonstrict

local shared = require("./shared.luau")
local sampler = require("./sampler.luau")

local diskstatsPath = "/proc/diskstats"
local countableDevices = {}
local readInFlight = false
local averageWindowMs = shared.averageWindowMs(noctalia.getConfig("average_window_seconds"))
local samplerState = sampler.new(averageWindowMs)

local function discoverRecognizedDevices()
    local names = noctalia.listDir("/sys/block")
    local discoveredDevices = {}
    if type(names) ~= "table" then return nil end

    for _, name in ipairs(names) do
        if shared.isRecognizedDevice(name) then discoveredDevices[name] = true end
    end
    if next(discoveredDevices) == nil then return nil end
    return discoveredDevices
end

local function resetSampler()
    samplerState = sampler.new(averageWindowMs)
end

local function publishUnavailable(errorMessage)
    countableDevices = {}
    resetSampler()
    noctalia.state.set(shared.stateKey, shared.normalizeSample(shared.emptySample(errorMessage)))
end

local function publishWarmup()
    noctalia.state.set(shared.stateKey, shared.normalizeSample(shared.emptySample("warming_up")))
end

local function processDiskstats(contents, requestedDevices)
    local discoveredDevices = discoverRecognizedDevices()
    if discoveredDevices == nil then
        publishUnavailable("device_discovery_unavailable")
        return
    end
    countableDevices = discoveredDevices

    local counters, parseError = shared.parseDiskstats(contents, countableDevices)
    local now = noctalia.nowMs()
    if counters == nil then
        if parseError == "missing_device" then
            local refreshedDevices = discoverRecognizedDevices()
            if refreshedDevices == nil then
                publishUnavailable("device_discovery_unavailable")
                return
            end
            if not shared.sameDeviceSet(requestedDevices, refreshedDevices)
                or not shared.sameDeviceSet(discoveredDevices, refreshedDevices) then
                countableDevices = refreshedDevices
                resetSampler()
                publishWarmup()
                return
            end
        end
        publishUnavailable("diskstats_unavailable")
        return
    end

    local sample, sampleError = sampler.process(samplerState, counters, now)
    if sampleError == "warming_up" then
        publishWarmup()
        return
    end
    if sample == nil then return end
    noctalia.state.set(shared.stateKey, shared.normalizeSample(sample))
end

local function requestSample()
    if readInFlight then return end
    local requestedDevices = discoverRecognizedDevices()
    if requestedDevices == nil then
        publishUnavailable("device_discovery_unavailable")
        return
    end
    countableDevices = requestedDevices
    readInFlight = true
    local accepted = noctalia.readFileAsync(diskstatsPath, function(contents, errorMessage)
        readInFlight = false
        if contents == nil then
            publishUnavailable(errorMessage or "diskstats_read_failed")
            return
        end
        processDiskstats(contents, requestedDevices)
    end)
    if not accepted then
        readInFlight = false
        publishUnavailable("diskstats_read_not_started")
    end
end

local initialDevices = discoverRecognizedDevices()
if initialDevices ~= nil then
    countableDevices = initialDevices
    publishWarmup()
else
    publishUnavailable("device_discovery_unavailable")
end

noctalia.setUpdateInterval(shared.sampleIntervalMs)
requestSample()

function update()
    requestSample()
end

function onConfigChanged()
    local nextAverageWindowMs = shared.averageWindowMs(noctalia.getConfig("average_window_seconds"))
    if nextAverageWindowMs == averageWindowMs then return end
    averageWindowMs = nextAverageWindowMs
    resetSampler()
    noctalia.state.set(shared.stateKey, shared.normalizeSample(shared.emptySample("warming_up")))
end
