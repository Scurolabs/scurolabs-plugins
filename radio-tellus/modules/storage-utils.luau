--!nonstrict
-- Bounded persistence under Noctalia's per-plugin data directory.
-- Leaf filenames keep path validation centralized in this module.

local storage = {}
local CHMOD_COMMAND, MKTEMP_COMMAND = "/usr/bin/chmod", "/usr/bin/mktemp"
local numeric = require("./numeric-utils.luau")

storage.MAX_BYTES = 4194304
local TEMPORARY_FILE_RETENTION_SECONDS = 60

local function safeLeafName(name)
    return type(name) == "string" and #name <= 128
        and name:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
end

local function joinPath(dir, name)
    local normalized = tostring(dir):gsub("/+$", "")
    return (normalized == "" and "/" or normalized .. "/") .. name
end

function storage.dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then noctalia.log("radio-tellus: pluginDataDir failed: " .. tostring(err)) end
    return dir
end

function storage.dataPath(name)
    if not safeLeafName(name) then
        noctalia.log("radio-tellus: refused invalid plugin data filename")
        return nil
    end
    local dir = storage.dataDir()
    return dir and joinPath(dir, name) or nil
end

local function byteLimit(maximum)
    return math.max(1, math.min(storage.MAX_BYTES, numeric.floorOr(maximum, storage.MAX_BYTES)))
end

local function commandSucceeded(result)
    return type(result) == "table" and tonumber(result.exitCode) == 0 and result.timedOut ~= true
end

local function encodeBoundedJson(name, value, maximum)
    local limit = byteLimit(maximum)
    local encoded, encodeError = noctalia.json.encode(value)
    if type(encoded) ~= "string" then
        noctalia.log("radio-tellus: JSON encode failed: " .. tostring(encodeError))
        return nil, "encode_failed"
    end
    if #encoded + 1 > limit then
        noctalia.log("radio-tellus: refused oversized JSON for " .. name)
        return nil, "oversized"
    end
    return encoded
end

local function prepareRead(name, maximum)
    local limit = byteLimit(maximum)
    local path = storage.dataPath(name)
    if path == nil then return nil, "unavailable" end
    if not noctalia.fileExists(path) then return nil, "missing" end
    local info = noctalia.fileInfo(path)
    local size = info and tonumber(info.size) or nil
    if size and size > limit then return nil, "oversized" end
    return path, nil, limit, info
end

local function readText(name, maximum)
    local path, prepareError, limit = prepareRead(name, maximum)
    if path == nil then return nil, prepareError end
    local raw = noctalia.readFile(path)
    if type(raw) ~= "string" then return nil, "unreadable" end
    -- The byte limit still applies when metadata is unavailable or changes during read.
    if #raw > limit then return nil, "oversized" end
    return raw
end

function storage.readJson(name, maximum)
    local raw, readError = readText(name, maximum)
    if raw == nil then return nil, readError end
    local decoded, decodeError = noctalia.json.decode(raw)
    if decoded == nil then return nil, tostring(decodeError or "invalid JSON") end
    return decoded
end

local function readTextAsync(name, maximum, callback)
    if type(callback) ~= "function" then return false end
    local path, prepareError, limit, info = prepareRead(name, maximum)
    if path == nil then callback(nil, prepareError); return false end
    local completed = false
    local function finish(raw, err)
        if completed then return end
        completed = true
        callback(raw, err, info)
    end
    local accepted = noctalia.readFileAsync(path, function(raw, err)
        if type(raw) ~= "string" then finish(nil, err or "unreadable"); return end
        if #raw > limit then finish(nil, "oversized"); return end
        finish(raw, nil, info)
    end)
    if not accepted then finish(nil, "unreadable") end
    return accepted
end

function storage.readJsonAsync(name, maximum, callback)
    if type(callback) ~= "function" then return false end
    return readTextAsync(name, maximum, function(raw, readError, info)
        if raw == nil then callback(nil, readError, info); return end
        local decoded, decodeError = noctalia.json.decode(raw)
        if decoded == nil then callback(nil, tostring(decodeError or "invalid JSON"), info); return end
        callback(decoded, nil, info)
    end)
end

function storage.writeJson(name, value, maximum)
    local path = storage.dataPath(name)
    if path == nil then return false end
    local encoded = encodeBoundedJson(name, value, maximum)
    if encoded == nil then return false end
    local temporary = path .. "." .. tostring(math.floor(noctalia.nowMs()))
        .. "-" .. tostring(math.random(100000, 999999)) .. ".next"
    local ok, err = noctalia.writeFile(temporary, encoded .. "\n")
    if not ok then
        noctalia.log("radio-tellus: could not write " .. name .. ": " .. tostring(err))
        return false
    end
    ok, err = noctalia.renameFile(temporary, path)
    if not ok then
        noctalia.removeFile(temporary)
        noctalia.log("radio-tellus: could not publish " .. name .. ": " .. tostring(err))
    end
    return ok
end

local function isTemporaryName(name, entry)
    if type(entry) ~= "string" then return false end
    local prefix = name .. "."
    if entry:sub(1, #prefix) ~= prefix then return false end
    local suffix = entry:sub(#prefix + 1)
    return suffix:match("^tmp%.[A-Za-z0-9]+$") ~= nil
        or suffix:match("^%d+%-%d+%.next$") ~= nil
end

function storage.removeTemporaryFiles(name, removeRecent)
    if not safeLeafName(name) then return false, "invalid_filename" end
    local dir = storage.dataDir()
    if dir == nil then return false, "unavailable" end
    local entries, err = noctalia.listDir(dir)
    if type(entries) ~= "table" then
        noctalia.log("radio-tellus: could not list temporary files for " .. name .. ": " .. tostring(err))
        return false, "temporary_files_unreadable"
    end
    for _, entry in ipairs(entries) do
        if isTemporaryName(name, entry) then
            local path = joinPath(dir, entry)
            local stale = removeRecent == true
            if not stale then
                local info = noctalia.fileInfo(path)
                local modified = info and tonumber(info.mtime) or nil
                stale = modified ~= nil
                    and math.floor(noctalia.nowMs() / 1000) - modified >= TEMPORARY_FILE_RETENTION_SECONDS
            end
            if stale then
                local removed = noctalia.removeFile(path)
                if not removed then
                    noctalia.log("radio-tellus: could not remove temporary file for " .. name)
                    return false, "temporary_file_remove_failed"
                end
            end
        end
    end
    return true
end

local function runChmod(path, mode, callback)
    if not noctalia.fileExists(CHMOD_COMMAND) then
        if type(callback) == "function" then callback(false, "chmod_unavailable") end
        return false
    end
    local completed = false
    local function finish(ok, err)
        if completed then return end
        completed = true
        if type(callback) == "function" then callback(ok, err) end
    end
    local started = noctalia.runAsync({ CHMOD_COMMAND, mode, path }, function(result)
        local ok = commandSucceeded(result)
        finish(ok, ok and nil or "permission_restriction_failed")
    end, 2000)
    if not started then finish(false, "chmod_not_started") end
    return started
end

function storage.hardenDataDir(callback)
    local dir = storage.dataDir()
    if dir == nil then
        if type(callback) == "function" then callback(false, "unavailable") end
        return false
    end
    return runChmod(dir, "700", function(ok, err)
        if not ok and err == "permission_restriction_failed" then
            noctalia.log("radio-tellus: could not restrict plugin data directory permissions")
        end
        if type(callback) == "function" then callback(ok, err) end
    end)
end

local function runPathSafety(path, callback)
    local pluginDir = noctalia.pluginDir()
    if pluginDir == nil then
        callback(false, "path_check_unavailable")
        return false
    end
    local helper = pluginDir .. "/helpers/stream-path-safety"
    if not noctalia.fileExists(helper) then
        callback(false, "path_check_unavailable")
        return false
    end
    local completed = false
    local function finish(ok, err)
        if completed then return end
        completed = true
        callback(ok, err)
    end
    local started = noctalia.runAsync({ helper, path }, function(result)
        local ok = commandSucceeded(result)
        finish(ok, ok and nil or "path_check_failed")
    end, 2000)
    if not started then finish(false, "path_check_not_started") end
    return started
end

function storage.readJsonSecure(name, maximum, callback)
    if type(callback) ~= "function" then return false end
    local path = storage.dataPath(name)
    if path == nil then callback(nil, "unavailable"); return false end

    local function cleanAndRead()
        local cleaned, cleanupError = storage.removeTemporaryFiles(name)
        if not cleaned then callback(nil, cleanupError); return end
        local raw, readError = storage.readJson(name, maximum)
        callback(raw, readError)
    end

    local function readAfterPathCheck(pathOk, pathError)
        if not pathOk then callback(nil, pathError or "path_check_failed"); return end
        if not noctalia.fileExists(path) then cleanAndRead(); return end
        runChmod(path, "600", function(fileOk, fileError)
            if not fileOk then callback(nil, fileError or "permission_restriction_failed"); return end
            cleanAndRead()
        end)
    end

    local function afterDirectory(ok, directoryError)
        if not ok then callback(nil, directoryError or "permission_restriction_failed"); return end
        runPathSafety(path, readAfterPathCheck)
    end

    local started = runPathSafety(path, function(pathOk, pathError)
        if not pathOk then callback(nil, pathError or "path_check_failed"); return end
        storage.hardenDataDir(afterDirectory)
    end)
    if not started then return false end
    return true
end

function storage.writeSecureJson(name, value, maximum, callback)
    if type(callback) ~= "function" then return false end
    local encoded, encodeError = encodeBoundedJson(name, value, maximum)
    if encoded == nil then callback(false, encodeError); return false end
    local path = storage.dataPath(name)
    local dir = storage.dataDir()
    if path == nil or dir == nil then callback(false, "unavailable"); return false end
    if not noctalia.fileExists(MKTEMP_COMMAND) then
        callback(false, "mktemp_unavailable")
        return false
    end

    local temporary = nil
    local completed = false
    local function finish(ok, err)
        if completed then return end
        completed = true
        if not ok and temporary ~= nil then
            if not noctalia.removeFile(temporary) then
                noctalia.log("radio-tellus: could not remove temporary credential file")
            end
        end
        callback(ok, err)
    end

    local function writeTemporary()
        local written, writeError = noctalia.writeFile(temporary, encoded .. "\n")
        if not written then finish(false, writeError or "temporary_file_write_failed"); return end
        runChmod(temporary, "600", function(fileOk, fileError)
            if not fileOk then finish(false, fileError or "permission_restriction_failed"); return end
            local renamed, renameError = noctalia.renameFile(temporary, path)
            if not renamed then finish(false, renameError or "credential_publish_failed"); return end
            temporary = nil
            finish(true)
        end)
    end

    local function createTemporary(result)
        if not commandSucceeded(result) or result.stdoutTruncated == true then
            finish(false, "temporary_file_create_failed")
            return
        end
        local output = tostring(result.stdout or ""):gsub("[\r\n]+$", "")
        local normalizedDir = tostring(dir):gsub("/+$", "")
        local prefix = (normalizedDir == "" and "/" or normalizedDir .. "/") .. name .. ".tmp."
        local randomPart = output:sub(#prefix + 1)
        if output:sub(1, #prefix) ~= prefix or #randomPart ~= 10
            or randomPart:match("^[A-Za-z0-9]+$") == nil then
            -- mktemp has already created the file. A path matching the safe
            -- template is removed before reporting the creation failure.
            if output:sub(1, #prefix) == prefix
                and randomPart:match("^[A-Za-z0-9]+$") ~= nil then
                noctalia.removeFile(output)
            end
            finish(false, "temporary_file_create_failed")
            return
        end
        temporary = output
        runChmod(temporary, "600", function(fileOk, fileError)
            if not fileOk then finish(false, fileError or "permission_restriction_failed"); return end
            writeTemporary()
        end)
    end

    local function afterDirectory(ok, directoryError)
        if not ok then finish(false, directoryError or "permission_restriction_failed"); return end
        runPathSafety(dir, function(pathOk, pathError)
            if not pathOk then finish(false, pathError or "path_check_failed"); return end
            local started = noctalia.runAsync({ MKTEMP_COMMAND, "-p", dir, name .. ".tmp.XXXXXXXXXX" }, createTemporary, 2000)
            if not started then finish(false, "temporary_file_create_failed") end
        end)
    end

    local started = runPathSafety(dir, function(pathOk, pathError)
        if not pathOk then finish(false, pathError or "path_check_failed"); return end
        storage.hardenDataDir(afterDirectory)
    end)
    if not started then return false end
    return true
end

return storage
