--[[--
Point codec: the on-disk representation of a canvas stroke.

The reason this is a separate module with its own suite is that it is the only
part of the canvas that is a *format*. Everything else can be changed freely;
a blob written today has to decode next year, so the checks here are about
bytes and boundaries rather than behaviour.
]]

return function(ctx)
    local t = ctx.t
    local Codec = require("ink_canvas_codec")

    local W, H = 1860, 2480

    --- Flat point array of `n` points along a diagonal, in canvas coordinates.
    local function diagonal(n)
        local p = {}
        for i = 1, n do
            p[#p + 1] = (i - 1) % W
            p[#p + 1] = (i - 1) % H
        end
        return p
    end

    --- Largest coordinate error the quantiser is allowed to introduce.
    local function tolerance(logical)
        return logical / 65535 / 2 + 1e-9
    end

    local function maxError(want, got, n)
        local ex, ey = 0, 0
        for i = 1, n do
            local dx = math.abs(want[i * 2 - 1] - got[i * 2 - 1])
            local dy = math.abs(want[i * 2] - got[i * 2])
            if dx > ex then ex = dx end
            if dy > ey then ey = dy end
        end
        return ex, ey
    end

    -- =================================================================
    t:describe("ink_canvas_codec / round trip")

    t:case("a single point survives", function()
        local chunks = Codec.encode({ 100, 200 }, 1, W, H)
        t:eq(#chunks, 1, "one chunk")
        t:eq(chunks[1].point_count, 1, "carrying one point")
        local pts, n = Codec.decode(chunks[1].points, W, H)
        t:eq(n, 1, "decodes to one point")
        local ex, ey = maxError({ 100, 200 }, pts, 1)
        t:check(ex <= tolerance(W) and ey <= tolerance(H), "within quantiser tolerance")
    end)

    t:case("a whole stroke survives within tolerance", function()
        local want = diagonal(500)
        local chunks = Codec.encode(want, 500, W, H)
        local got, n = Codec.join(chunks, W, H)
        t:eq(n, 500, "same point count")
        local ex, ey = maxError(want, got, 500)
        t:check(ex <= tolerance(W), "x within tolerance, worst " .. ex)
        t:check(ey <= tolerance(H), "y within tolerance, worst " .. ey)
    end)

    t:case("the extremes land exactly on the extremes", function()
        local chunks = Codec.encode({ 0, 0, W, H }, 2, W, H)
        local pts = Codec.join(chunks, W, H)
        t:eq(pts[1], 0, "x min")
        t:eq(pts[2], 0, "y min")
        t:eq(pts[3], W, "x max")
        t:eq(pts[4], H, "y max")
    end)

    t:case("a blob is exactly header plus four bytes per point", function()
        local chunks = Codec.encode(diagonal(7), 7, W, H)
        t:eq(#chunks[1].points, Codec.HEADER + 4 * 7, "no padding, no slack")
    end)

    t:case("the version byte is the first byte", function()
        local chunks = Codec.encode({ 1, 1 }, 1, W, H)
        t:eq(chunks[1].points:byte(1), Codec.VERSION, "version leads the blob")
    end)

    -- =================================================================
    t:describe("ink_canvas_codec / chunking")

    t:case("a stroke at the chunk limit stays in one chunk", function()
        local chunks = Codec.encode(diagonal(Codec.MAX_POINTS), Codec.MAX_POINTS, W, H)
        t:eq(#chunks, 1, "exactly one")
        t:eq(chunks[1].point_count, Codec.MAX_POINTS, "full")
    end)

    t:case("one point past the limit opens a second chunk", function()
        local n = Codec.MAX_POINTS + 1
        local chunks = Codec.encode(diagonal(n), n, W, H)
        t:eq(#chunks, 2, "two chunks")
        -- The second carries the joint point plus the new one.
        t:eq(chunks[2].point_count, 2, "joint point is repeated, not dropped")
    end)

    t:case("no chunk ever exceeds the limit", function()
        local n = 10000
        local chunks = Codec.encode(diagonal(n), n, W, H)
        local over = 0
        for i = 1, #chunks do
            if chunks[i].point_count > Codec.MAX_POINTS then over = over + 1 end
        end
        t:eq(over, 0, "every chunk is bounded")
    end)

    t:case("a long stroke rejoins with no seam and no duplicates", function()
        local n = 10000
        local want = diagonal(n)
        local chunks = Codec.encode(want, n, W, H)
        t:check(#chunks > 1, "the fixture really does span chunks")
        local got, back = Codec.join(chunks, W, H)
        t:eq(back, n, "every point comes back exactly once")
        local ex, ey = maxError(want, got, n)
        t:check(ex <= tolerance(W) and ey <= tolerance(H), "and in the right place")
    end)

    t:case("the joint point is identical on both sides of the seam", function()
        local n = Codec.MAX_POINTS + 50
        local chunks = Codec.encode(diagonal(n), n, W, H)
        local a = Codec.decode(chunks[1].points, W, H)
        local b = Codec.decode(chunks[2].points, W, H)
        local last = Codec.MAX_POINTS
        t:eq(b[1], a[last * 2 - 1], "x matches across the seam")
        t:eq(b[2], a[last * 2], "y matches across the seam")
    end)

    t:case("chunkCount agrees with what encode actually produces", function()
        for _, n in ipairs({ 1, 2, 1023, 1024, 1025, 2046, 2047, 2048, 10000 }) do
            local chunks = Codec.encode(diagonal(n), n, W, H)
            t:eq(Codec.chunkCount(n), #chunks, "n = " .. n)
        end
    end)

    t:case("chunkCount of an empty stroke is zero", function()
        t:eq(Codec.chunkCount(0), 0, "nothing to store")
        t:eq(Codec.chunkCount(nil), 0, "and a missing count is not an error here")
    end)

    -- =================================================================
    t:describe("ink_canvas_codec / refusals")

    t:case("an empty stroke is refused, not encoded as nothing", function()
        local chunks, err = Codec.encode({}, 0, W, H)
        t:eq(chunks, nil, "no chunks")
        t:eq(err, "empty", "and it says why")
    end)

    t:case("a canvas with no area is refused", function()
        local _, err = Codec.encode({ 1, 1 }, 1, 0, H)
        t:eq(err, "bad_geometry", "zero width")
        local _, err2 = Codec.encode({ 1, 1 }, 1, W, -3)
        t:eq(err2, "bad_geometry", "negative height")
    end)

    t:case("a missing coordinate is refused rather than written as zero", function()
        local _, err = Codec.encode({ 1, 1, 2 }, 2, W, H)
        t:eq(err, "bad_point", "the truncated pair is caught")
    end)

    t:case("out-of-canvas points are clamped, not wrapped", function()
        local chunks = Codec.encode({ -50, H + 900 }, 1, W, H)
        local pts = Codec.join(chunks, W, H)
        t:eq(pts[1], 0, "below zero clamps to the edge")
        t:eq(pts[2], H, "past the far edge clamps to the edge")
    end)

    t:case("a truncated payload is refused", function()
        local chunks = Codec.encode(diagonal(10), 10, W, H)
        local blob = chunks[1].points
        local pts, err = Codec.decode(blob:sub(1, #blob - 1), W, H)
        t:eq(pts, nil, "nothing decoded")
        t:eq(err, "length", "the length check catches it")
    end)

    t:case("a payload with trailing junk is refused", function()
        local chunks = Codec.encode(diagonal(10), 10, W, H)
        local _, err = Codec.decode(chunks[1].points .. "\0\0\0\0", W, H)
        t:eq(err, "length", "extra bytes are corruption, not padding")
    end)

    t:case("a blob shorter than the header is refused", function()
        local _, err = Codec.decode("\1\2", W, H)
        t:eq(err, "short", "caught before any arithmetic on the count")
    end)

    t:case("an unknown codec version is refused, not guessed at", function()
        local chunks = Codec.encode(diagonal(3), 3, W, H)
        local blob = string.char(99) .. chunks[1].points:sub(2)
        local _, err = Codec.decode(blob, W, H)
        t:eq(err, "version", "a future format is not decoded by this one")
    end)

    t:case("a chunk claiming more points than the limit is refused", function()
        -- 2000 points claimed, header says so, payload is sized to match.
        local count = 2000
        local blob = string.char(Codec.VERSION, count % 256, math.floor(count / 256))
            .. string.rep("\0\0\0\0", count)
        local _, err = Codec.decode(blob, W, H)
        t:eq(err, "count", "the chunk bound is enforced on the way in too")
    end)

    t:case("a chunk claiming zero points is refused", function()
        local _, err = Codec.decode(string.char(Codec.VERSION, 0, 0), W, H)
        t:eq(err, "count", "an empty chunk is corruption")
    end)

    t:case("a seam that does not line up is refused", function()
        local n = Codec.MAX_POINTS + 10
        local chunks = Codec.encode(diagonal(n), n, W, H)
        -- Corrupt the joint point of the second chunk.
        local b = chunks[2].points
        chunks[2].points = b:sub(1, Codec.HEADER) .. "\255\255\255\255" .. b:sub(Codec.HEADER + 5)
        local pts, err = Codec.join(chunks, W, H)
        t:eq(pts, nil, "the join fails")
        t:eq(err, "joint", "rather than silently drawing a jump")
    end)

    t:case("join refuses an out-of-order chunk list", function()
        local n = Codec.MAX_POINTS + 10
        local chunks = Codec.encode(diagonal(n), n, W, H)
        chunks[1], chunks[2] = chunks[2], chunks[1]
        local pts = Codec.join(chunks, W, H)
        t:eq(pts, nil, "reordered chunks do not decode")
    end)

    -- =================================================================
    t:describe("ink_canvas_codec / golden vector")

    --[[
    The one check that would notice a well-intentioned refactor changing the
    bytes. Every field is spelled out: version, little-endian count, then two
    little-endian uint16 per point.
    ]]
    t:case("a known stroke encodes to known bytes", function()
        -- A 2-point stroke on a 100x100 canvas: (0,0) and (100,50).
        -- (100,50) normalises to (65535, 32768) -- 50/100*65535 = 32767.5,
        -- rounded half up.
        local chunks = Codec.encode({ 0, 0, 100, 50 }, 2, 100, 100)
        local want = string.char(
            1,              -- version
            2, 0,           -- point count, uint16 LE
            0, 0, 0, 0,     -- (0, 0)
            255, 255,       -- x = 65535
            0, 128          -- y = 32768
        )
        t:eq(chunks[1].points, want, "byte for byte")
    end)

    t:case("the golden bytes decode back to the golden stroke", function()
        local blob = string.char(1, 2, 0, 0, 0, 0, 0, 255, 255, 0, 128)
        local pts, n = Codec.decode(blob, 100, 100)
        t:eq(n, 2, "two points")
        t:eq(pts[1], 0, "x0")
        t:eq(pts[2], 0, "y0")
        t:eq(pts[3], 100, "x1")
        t:check(math.abs(pts[4] - 50) < 0.01, "y1 back within a hundredth")
    end)
end
