--[[--
The canvas stroke point format.

This module is a *format*, not behaviour: bytes written by it have to decode
correctly for as long as a reader keeps their notes, so it is deliberately
small, has no dependencies at all, and validates everything on the way back in.

A stroke is stored as one or more chunks. Each chunk is:

    byte  1      codec version
    bytes 2-3    point count, uint16 little-endian
    bytes 4..    two uint16 little-endian per point: x then y

Coordinates are canvas coordinates -- the geometry the canvas was born with --
normalised to 0..65535 on each axis independently, so the blob does not depend
on the screen it was drawn on. `logical_w` and `logical_h` come from the canvas
row and are what turns the integers back into coordinates.

`string.pack` would express this in one line and is not usable: LuaJIT is
Lua 5.1 and does not have it. `string.char` and `string.byte` do.

Chunking bounds the size of every row and of every temporary table built while
rasterising. Chunk boundaries repeat the point they split on, so the segment
across a seam can be drawn from one chunk without holding the next one; `join`
drops that repeat again and refuses a pair that does not line up, because a
mismatched seam means corruption and drawing it would silently produce a jump
across the page.
]]

local byte = string.byte
local char = string.char
local floor = math.floor

local Codec = {
    --- Bumped only for an incompatible payload change. `decode` refuses
    --- anything it does not know rather than guessing at the layout.
    VERSION = 1,
    --- Version byte plus uint16 count.
    HEADER = 3,
    --- Points per chunk, joint point included.
    MAX_POINTS = 1024,
    --- Normalised coordinate range, inclusive.
    SCALE = 65535,
}

local SCALE = Codec.SCALE

-- ------------------------------------------------------------ quantisation

--- Canvas coordinate to 0..SCALE. Out-of-canvas values clamp to the edge: the
--- alternative is wrap-around, which puts a stray point on the far side.
local function quantise(v, logical)
    local q = floor(v / logical * SCALE + 0.5)
    if q < 0 then return 0 end
    if q > SCALE then return SCALE end
    return q
end

local function dequantise(q, logical)
    return q * logical / SCALE
end

local function badNumber(v)
    return type(v) ~= "number" or v ~= v
        or v == math.huge or v == -math.huge
end

-- ----------------------------------------------------------------- encoding

local function validateInput(points, n, logical_w, logical_h)
    if type(n) ~= "number" or n < 1 or n ~= floor(n) or n == math.huge then
        return nil, "empty"
    end
    if type(points) ~= "table" then return nil, "bad_point" end
    if badNumber(logical_w) or badNumber(logical_h)
        or logical_w <= 0 or logical_h <= 0 then
        return nil, "bad_geometry"
    end
    for i = 1, n do
        if badNumber(points[i * 2 - 1]) or badNumber(points[i * 2]) then
            return nil, "bad_point"
        end
    end
    return true
end

Codec.validate = validateInput

--- Encode and release one chunk at a time. The whole input is validated before
--- the callback sees the first blob, so a late bad point cannot leave a
--- partially emitted stroke inside the caller's transaction.
function Codec.eachEncodedChunk(points, n, logical_w, logical_h, callback)
    local valid, err = validateInput(points, n, logical_w, logical_h)
    if not valid then return nil, err end
    if type(callback) ~= "function" then return nil, "no_callback" end

    local first, chunk_no = 1, 0
    while true do
        local last = first + Codec.MAX_POINTS - 1
        if last > n then last = n end
        local count = last - first + 1

        local buf = { char(Codec.VERSION, count % 256, floor(count / 256)) }
        for i = first, last do
            local x = quantise(points[i * 2 - 1], logical_w)
            local y = quantise(points[i * 2], logical_h)
            buf[#buf + 1] = char(x % 256, floor(x / 256), y % 256, floor(y / 256))
        end

        local ok, callback_err = callback(chunk_no, count, table.concat(buf))
        if ok == nil or ok == false then return nil, callback_err or "callback" end
        if last == n then break end
        first = last
        chunk_no = chunk_no + 1
    end
    return true
end

--[[--
Encode `n` points of a flat `{x1, y1, x2, y2, ...}` array.

Returns an array of `{ point_count = k, points = <string> }`, in order, or
nil plus a reason. The reasons are `empty`, `bad_geometry` and `bad_point`;
all three are caller bugs rather than data corruption, and none of them is
worth writing a half-formed stroke over.
]]
function Codec.encode(points, n, logical_w, logical_h)
    local chunks = {}
    local ok, err = Codec.eachEncodedChunk(points, n, logical_w, logical_h,
        function(_, count, blob)
            chunks[#chunks + 1] = { point_count = count, points = blob }
            return true
        end)
    if not ok then return nil, err end
    return chunks
end

-- ----------------------------------------------------------------- decoding

--[[--
Decode one chunk back to a flat point array.

Returns points, count, or nil plus one of `short`, `version`, `count`,
`length`. Every one of those means the bytes are not what this codec wrote,
and the caller's job is to report a damaged canvas rather than to render
whatever the arithmetic produced.
]]
function Codec.decode(blob, logical_w, logical_h)
    if type(blob) ~= "string" or #blob < Codec.HEADER then return nil, "short" end
    if badNumber(logical_w) or badNumber(logical_h)
        or logical_w <= 0 or logical_h <= 0 then
        return nil, "bad_geometry"
    end

    local version, lo, hi = byte(blob, 1, 3)
    if version ~= Codec.VERSION then return nil, "version" end

    local count = lo + hi * 256
    if count < 1 or count > Codec.MAX_POINTS then return nil, "count" end
    if #blob ~= Codec.HEADER + count * 4 then return nil, "length" end

    local points = {}
    local at = Codec.HEADER + 1
    for i = 1, count do
        local xl, xh, yl, yh = byte(blob, at, at + 3)
        points[i * 2 - 1] = dequantise(xl + xh * 256, logical_w)
        points[i * 2] = dequantise(yl + yh * 256, logical_h)
        at = at + 4
    end
    return points, count
end

--[[--
Decode a whole stroke: every chunk in order, with the repeated seam point
dropped.

Returns points, count, or nil plus a reason. `joint` means two consecutive
chunks disagree about the point they share -- corruption, or chunks handed
over out of order, and either way not something to paper over.
]]
function Codec.join(chunks, logical_w, logical_h)
    if type(chunks) ~= "table" or #chunks == 0 then return nil, "empty" end

    local points, n = {}, 0
    for c = 1, #chunks do
        local part, count = Codec.decode(chunks[c].points, logical_w, logical_h)
        if not part then return nil, count end

        local from = 1
        if c > 1 then
            -- The seam has to match to the byte, and it does: both sides were
            -- quantised from the same coordinate.
            if part[1] ~= points[n * 2 - 1] or part[2] ~= points[n * 2] then
                return nil, "joint"
            end
            from = 2
        end
        for i = from, count do
            n = n + 1
            points[n * 2 - 1] = part[i * 2 - 1]
            points[n * 2] = part[i * 2]
        end
    end
    return points, n
end

-- ------------------------------------------------------ incremental decoding

local Decoder = {}
Decoder.__index = Decoder

function Codec.newDecoder(logical_w, logical_h, meta)
    if badNumber(logical_w) or badNumber(logical_h)
        or logical_w <= 0 or logical_h <= 0 then
        return nil, "bad_geometry"
    end
    meta = meta or {}
    if tonumber(meta.codec) ~= Codec.VERSION then return nil, "unsupported_codec" end
    local expected = tonumber(meta.point_count)
    if not expected or expected < 1 then return nil, "stroke_point_count" end
    return setmetatable({
        logical_w = logical_w,
        logical_h = logical_h,
        expected = expected,
        next_chunk = 0,
        total = 0,
        last_x = nil,
        last_y = nil,
    }, Decoder)
end

function Decoder:push(chunk_no, sql_point_count, blob)
    if tonumber(chunk_no) ~= self.next_chunk then return nil, "chunk_order" end
    local points, n = Codec.decode(blob, self.logical_w, self.logical_h)
    if not points then
        if n == "version" then return nil, "unsupported_codec" end
        if n == "length" or n == "short" then return nil, "chunk_length" end
        return nil, "chunk_count"
    end
    if tonumber(sql_point_count) ~= n then return nil, "chunk_count" end

    local from = 1
    if self.next_chunk > 0 then
        if points[1] ~= self.last_x or points[2] ~= self.last_y then
            return nil, "chunk_joint"
        end
        from = 2
    end
    self.total = self.total + n - (from - 1)
    if self.total > self.expected then return nil, "stroke_point_count" end
    self.last_x = points[n * 2 - 1]
    self.last_y = points[n * 2]
    self.next_chunk = self.next_chunk + 1
    return points, n, from
end

function Decoder:finish()
    if self.next_chunk == 0 then return nil, "chunk_count" end
    if self.total ~= self.expected then return nil, "stroke_point_count" end
    return true
end

--[[--
How many chunks `n` points will occupy, without encoding them.

Used to size a progress estimate and to assert the store's own bookkeeping;
kept here so the arithmetic lives next to the loop it mirrors.
]]
function Codec.chunkCount(n)
    if type(n) ~= "number" or n < 1 then return 0 end
    if n <= Codec.MAX_POINTS then return 1 end
    local rest = n - Codec.MAX_POINTS
    local per = Codec.MAX_POINTS - 1
    return 1 + floor((rest + per - 1) / per)
end

return Codec
