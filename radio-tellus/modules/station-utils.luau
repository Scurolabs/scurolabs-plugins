--!nonstrict
-- Station data validation for display, storage, and playback boundaries.

local station = {}
local numeric = require("./numeric-utils.luau")

station.MAX_CATALOG_STATIONS = 100
station.MAX_CATALOG_CANDIDATES = 200
station.MAX_PERSISTED_STATIONS = 500
station.MAX_JSON_DEPTH = 32
station.MAX_JSON_TOKENS = 20000
station.MAX_RESPONSE_BYTES = 262144

function station.trim(value)
    return noctalia.string.trim(tostring(value or ""))
end

function station.truncateCharacters(value, maximum)
    local text = tostring(value or "")
    local limit = math.max(0, numeric.floorOr(maximum, 0))
    if limit == 0 then return "" end
    if #text <= limit then return text end
    if not text:find("[\128-\255]") then return text:sub(1, limit) end
    local ok, boundary = pcall(utf8.offset, text, limit + 1)
    if ok then return boundary and text:sub(1, boundary - 1) or text end
    return text:sub(1, limit)
end

function station.singleLine(value, limit)
    local maximum = math.max(0, numeric.floorOr(limit, 200))
    if maximum == 0 then return "" end
    local rawLimit = math.min(16384, math.max(256, maximum * 4 + 16))
    local text = tostring(value or "")
    if #text > rawLimit then text = text:sub(1, rawLimit) end
    text = text:gsub("[%c]+", " ")
    return station.truncateCharacters(station.trim(text), maximum)
end

function station.trackTitle(value)
    local original = station.singleLine(value, 160)
    if original == "" then return "" end

    local function cleanPart(raw, limit)
        local part = station.singleLine(raw, limit)
        local marker = part:lower():gsub("[%s_-]+", " ")
        local isSpotMarker = marker == "spot block start" or marker == "spot block end"
        return isSpotMarker and "" or part, isSpotMarker
    end

    -- Known iHeart wrappers are normalized without altering normal titles.
    local title, artist = original:match('^title="([^"]*)",%s*artist="([^"]*)",%s*url=')
    if title then
        local cleanTitle, titleIsMarker = cleanPart(title, 100)
        local cleanArtist, artistIsMarker = cleanPart(artist, 80)
        if titleIsMarker or artistIsMarker then return "" end
        title, artist = cleanTitle, cleanArtist
        if title ~= "" and artist ~= "" then return artist .. " — " .. title end
        if title ~= "" then return title end
        if artist ~= "" then return artist end
    end

    local prefix, text = original:match('^(.-)%s*%-%s*text="([^"]*)"%s+song_spot=')
    if text == nil then text = original:match('^text="([^"]*)"%s+song_spot=') end
    local extracted, prefixIsMarker = cleanPart(prefix, 160)
    local cleanText, textIsMarker = cleanPart(text, 160)
    if prefixIsMarker or textIsMarker then return "" end
    if extracted == "" then extracted = cleanText end
    if extracted == "" then
        -- Malformed provider metadata is ignored. The UI supplies its fallback.
        if original:find("song_spot=", 1, true) and (original:find("MediaBaseId=", 1, true)
            or original:find("itunesTrackId=", 1, true)) then return "" end
        return original
    end
    return extracted
end

function station.urlEncode(value)
    return noctalia.string.urlEncode(tostring(value or ""))
end

function station.countryCode(value)
    local code = station.trim(value):upper()
    return code:match("^[A-Z][A-Z]$") and code or "SE"
end

function station.stationKey(value)
    if type(value) ~= "table" then return "" end
    local uuid = station.singleLine(value.uuid or value.stationuuid, 80)
    return uuid ~= "" and uuid or station.singleLine(value.url_resolved, 4096)
end

function station.matchesSearch(value, query)
    if type(value) ~= "table" then return false end
    local needle = station.trim(query):lower()
    if needle == "" then return true end
    local haystack = tostring(value.name or "") .. " " .. tostring(value.country or "")
        .. " " .. tostring(value.tags or "")
    return haystack:lower():find(needle, 1, true) ~= nil
end

function station.radioBrowserUuid(value)
    local uuid = station.singleLine(value, 80):lower()
    local hexDigits, separators = uuid:gsub("%-", "")
    if #uuid ~= 36 or separators ~= 4 or uuid:sub(9, 9) ~= "-" or uuid:sub(14, 14) ~= "-"
        or uuid:sub(19, 19) ~= "-" or uuid:sub(24, 24) ~= "-" or #hexDigits ~= 32
        or not hexDigits:match("^%x+$") then
        return nil
    end
    return uuid
end

local function publicIpv4(host)
    if not host:match("^[%d.]+$") then return nil end
    local octets = {}
    for octet in host:gmatch("([^.]+)") do
        if not octet:match("^%d+$") or #octet > 3 then return false end
        local value = tonumber(octet)
        if value == nil or value > 255 then return false end
        table.insert(octets, value)
    end
    if #octets ~= 4 or host:find("..", 1, true) or host:sub(1, 1) == "."
        or host:sub(-1) == "." then return false end
    local first, second, third = octets[1], octets[2], octets[3]
    if first == 0 or first == 10 or first == 127 or first >= 224 then return false end
    if first == 100 and second >= 64 and second <= 127 then return false end
    if first == 169 and second == 254 then return false end
    if first == 172 and second >= 16 and second <= 31 then return false end
    if first == 192 and (second == 0 or second == 168) then return false end
    if first == 192 and second == 88 and third == 99 then return false end
    if first == 198 and (second == 18 or second == 19 or second == 51 and third == 100) then return false end
    if first == 203 and second == 0 and third == 113 then return false end
    return true
end

function station.validateStreamUrl(value)
    local url = tostring(value or "")
    local scheme, authority = url:match("^(https?)://([^/%?#]+)")
    if url == "" or #url > 4096 or scheme == nil or authority == nil
        or url:find("%s") or url:find("%c") or url:find("\\", 1, true) then
        return nil, "This station has an invalid stream address and cannot be played."
    end
    if authority:find("@", 1, true) or authority:find("%", 1, true) then
        return nil, "This station has an unsafe stream address and cannot be played."
    end
    if authority:sub(1, 1) == "[" then
        return nil, "This station uses a direct network address that Radio Tellus cannot play. Try another station."
    end
    local host, port = authority:match("^([^:]+):(%d+)$")
    if host == nil then
        if authority:find(":", 1, true) then return nil, "This station has an invalid stream address and cannot be played." end
        host = authority
    elseif tonumber(port) == nil or tonumber(port) < 1 or tonumber(port) > 65535 then
        return nil, "This station has an invalid stream address and cannot be played."
    end
    host = host:lower():gsub("%.$", "")
    if host == "" or #host > 253 or host:sub(1, 1) == "." or host:find("..", 1, true)
        or not host:match("^[a-z0-9.-]+$") then
        return nil, "This station has an invalid stream address and cannot be played."
    end
    local ipv4 = publicIpv4(host)
    if ipv4 == false then return nil, "This station points to a private or reserved address and cannot be played." end
    if ipv4 == nil then
        if not host:find(".", 1, true) then return nil, "This station points to a local address and cannot be played." end
        for label in host:gmatch("([^.]+)") do
            if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
                return nil, "This station has an invalid stream address and cannot be played."
            end
        end
        for _, suffix in ipairs({ ".localhost", ".local", ".localdomain", ".internal", ".home", ".lan" }) do
            if host:sub(-#suffix) == suffix then return nil, "This station points to a local address and cannot be played." end
        end
    end
    return url, nil
end

local function normalizedStation(raw, url)
    local latitude = numeric.finite(raw.latitude or raw.geo_lat)
    local longitude = numeric.finite(raw.longitude or raw.geo_long)
    if latitude == nil or latitude < -90 or latitude > 90 then latitude = nil end
    if longitude == nil or longitude < -180 or longitude > 180 then longitude = nil end
    local name = station.singleLine(raw.name, 200)
    local votes = numeric.finite(raw.votes)
    return {
        uuid = station.singleLine(raw.uuid or raw.stationuuid, 80),
        name = name ~= "" and name or "Unnamed station",
        url_resolved = url,
        country = station.singleLine(raw.country, 100),
        country_code = station.singleLine(raw.country_code or raw.countrycode, 2):upper(),
        tags = station.singleLine(raw.tags, 240),
        votes = math.max(0, math.floor(votes or 0)),
        latitude = latitude,
        longitude = longitude,
    }
end

function station.sanitizeStation(raw)
    if type(raw) ~= "table" then return nil end
    local url = station.validateStreamUrl(raw.url_resolved or raw.url)
    if url == nil then return nil end
    return normalizedStation(raw, url)
end

function station.sanitizeStations(raw, maximum)
    local stations, seen = {}, {}
    if type(raw) ~= "table" then return stations end
    local limit = math.max(0, numeric.floorOr(maximum, station.MAX_CATALOG_STATIONS))
    if limit == 0 then return stations end
    local candidateLimit = math.min(station.MAX_PERSISTED_STATIONS,
        math.max(station.MAX_CATALOG_CANDIDATES, limit))
    for index, candidate in ipairs(raw) do
        if index > candidateLimit then break end
        local clean = station.sanitizeStation(candidate)
        local key = station.stationKey(clean)
        if clean and key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(stations, clean)
            if #stations >= limit then break end
        end
    end
    return stations
end

local function jsonWithinBudget(body)
    local structure = body:gsub("\\.", " ")
    structure = structure:gsub('"[^"]*"', "")
    local _, punctuation = structure:gsub("[,:]", "")
    local _, delimiters = structure:gsub("[%[%]{}]", "")
    if punctuation + delimiters > station.MAX_JSON_TOKENS then return false end
    structure = structure:gsub("[^%[%]{}]", "")
    for _ = 1, station.MAX_JSON_DEPTH do
        local reduced, arrays = structure:gsub("%[%]", "")
        local objects
        reduced, objects = reduced:gsub("{}", "")
        if arrays + objects == 0 then return reduced == "" end
        structure = reduced
    end
    return false
end

function station.limitSanitizedStations(raw, maximum)
    -- This helper only bounds rows that already crossed sanitizeStations or a
    -- response parser. It never replaces validation at an external boundary.
    local stations = {}
    if type(raw) ~= "table" then return stations end
    local limit = math.max(0, numeric.floorOr(maximum, station.MAX_CATALOG_STATIONS))
    if limit == 0 then return stations end
    for _, candidate in ipairs(raw) do
        if type(candidate) == "table" then table.insert(stations, candidate) end
        if #stations >= limit then break end
    end
    return stations
end

function station.streamAllowed(value)
    if type(value) ~= "table" then return nil, "This station has no playable stream." end
    local url, err = station.validateStreamUrl(value.url_resolved or value.url)
    if url == nil then return nil, err end
    if url:match("^http://") and noctalia.getConfig("allow_insecure_http") ~= true then
        return nil, "This station does not use a secure connection. Enable HTTP streams in Radio settings only if you trust the station."
    end
    return normalizedStation(value, url), nil
end

function station.streamAllowedSanitized(value, allowInsecureHttp)
    -- This fast path is only for rows returned by sanitizeStations. Playback
    -- entry points continue to use streamAllowed for untrusted values.
    if type(value) ~= "table" or type(value.url_resolved) ~= "string" then return false end
    if value.url_resolved:match("^http://") and allowInsecureHttp ~= true then return false end
    return true
end

function station.parseStationResponse(response, maximum)
    if type(response) ~= "table" or response.ok ~= true then
        return nil, "Could not load the station directory. Check your connection and try again."
    end
    local status = numeric.floorOr(response.status, 0)
    if status < 200 or status >= 300 then
        return nil, "The station directory did not respond correctly. Try again later."
    end
    if type(response.body) ~= "string" or #response.body > station.MAX_RESPONSE_BYTES then
        return nil, "The station directory sent too much data. Try again later."
    end
    if not jsonWithinBudget(response.body) then
        return nil, "The station directory was too complex to process. Try again later."
    end
    local decoded = noctalia.json.decode(response.body)
    if type(decoded) ~= "table" then return nil, "The station directory sent data Radio Tellus could not use. Try again later." end
    return station.sanitizeStations(decoded, maximum)
end

return station
