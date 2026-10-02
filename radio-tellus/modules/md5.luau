--!nonstrict
-- Small, self-contained MD5 implementation used for Last.fm API signatures.

local bit = bit32
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local bnot, lrotate = bit.bnot, bit.lrotate

local function add32(a, b)
    return band(a + b, 0xffffffff)
end

local function add4(a, b, c, d)
    return add32(add32(a, b), add32(c, d))
end

local function wordHex(value)
    return string.format(
        "%02x%02x%02x%02x",
        band(value, 0xff),
        band(bit.rshift(value, 8), 0xff),
        band(bit.rshift(value, 16), 0xff),
        band(bit.rshift(value, 24), 0xff)
    )
end

local K = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function paddedBytes(input)
    local bytes = {}
    for index = 1, #input do bytes[index] = string.byte(input, index) end
    table.insert(bytes, 0x80)
    while (#bytes % 64) ~= 56 do table.insert(bytes, 0) end

    local bitLength = #input * 8
    local low = bitLength % 0x100000000
    local high = math.floor(bitLength / 0x100000000)
    for _ = 1, 4 do
        table.insert(bytes, low % 256)
        low = math.floor(low / 256)
    end
    for _ = 1, 4 do
        table.insert(bytes, high % 256)
        high = math.floor(high / 256)
    end
    return bytes
end

local function digest(input)
    local bytes = paddedBytes(input)
    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476

    for offset = 1, #bytes, 64 do
        local words = {}
        for index = 0, 15 do
            local base = offset + index * 4
            words[index] = bytes[base]
                + bytes[base + 1] * 0x100
                + bytes[base + 2] * 0x10000
                + bytes[base + 3] * 0x1000000
        end

        local a, b, c, d = a0, b0, c0, d0
        for index = 0, 63 do
            local f, g
            if index < 16 then
                f = bor(band(b, c), band(bnot(b), d))
                g = index
            elseif index < 32 then
                f = bor(band(d, b), band(bnot(d), c))
                g = (5 * index + 1) % 16
            elseif index < 48 then
                f = bxor(b, bxor(c, d))
                g = (3 * index + 5) % 16
            else
                f = bxor(c, bor(b, bnot(d)))
                g = (7 * index) % 16
            end

            local rotated = lrotate(add4(a, f, K[index + 1], words[g]), S[index + 1])
            a, d, c, b = d, c, b, add32(b, rotated)
        end

        a0, b0, c0, d0 = add32(a0, a), add32(b0, b), add32(c0, c), add32(d0, d)
    end

    return wordHex(a0) .. wordHex(b0) .. wordHex(c0) .. wordHex(d0)
end

return digest
