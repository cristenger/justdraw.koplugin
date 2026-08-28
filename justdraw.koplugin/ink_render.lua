--[[--
Stroke rasterisation. Numbers only on every hot path — no tables are created
here, by anything, ever.
]]

local floor, ceil = math.floor, math.ceil
local abs = math.abs

local Render = {}

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function clipAxis(origin, delta, low, high, first, last)
    if delta == 0 then
        if origin < low or origin > high then return nil end
        return first, last
    end
    local a = (low - origin) / delta
    local b = (high - origin) / delta
    if not finite(a) or not finite(b) then return nil end
    if a > b then a, b = b, a end
    if a > first then first = a end
    if b < last then last = b end
    if first > last then return nil end
    return first, last
end

-- Paint one square nib, clipped before it reaches BlitBuffer. Besides keeping
-- corrupt geometry away from the FFI boundary, the scalar return values let
-- callers refresh exactly the half-open area that was actually touched.
local function paintSample(bb, x, y, w, half, color, bw, bh)
    local left = floor(x) - half
    local top = floor(y) - half
    local right = left + w
    local bottom = top + w
    if left < 0 then left = 0 end
    if top < 0 then top = 0 end
    if right > bw then right = bw end
    if bottom > bh then bottom = bh end
    if right <= left or bottom <= top then return false end
    bb:paintRect(left, top, right - left, bottom - top, color)
    return true, left, top, right, bottom
end

--- Paint a w-wide segment from (x0,y0) to (x1,y1) into bb.
function Render.segment(bb, x0, y0, x1, y1, w, color)
    if not bb or not finite(x0) or not finite(y0)
        or not finite(x1) or not finite(y1) or not finite(w)
        or w <= 0 or w ~= floor(w) then
        return false
    end
    local bw, bh = bb:getWidth(), bb:getHeight()
    if not finite(bw) or not finite(bh) or bw < 1 or bh < 1
        or bw ~= floor(bw) or bh ~= floor(bh) then
        return false
    end
    local half = floor(w / 2)
    local dx = x1 - x0
    local dy = y1 - y0
    if not finite(dx) or not finite(dy) then return false end
    local adx = abs(dx)
    local ady = abs(dy)
    local steps = adx > ady and adx or ady
    if not finite(steps) then return false end

    if steps < 1 then
        return paintSample(bb, x0, y0, w, half, color, bw, bh)
    end

    steps = floor(steps)
    local sx = dx / steps
    local sy = dy / steps
    if not finite(sx) or not finite(sy) then return false end

    -- Clip the DDA index range, not the segment endpoints. This preserves the
    -- original sampling phase and therefore the pixels of every in-bounds
    -- segment while bounding a crossing segment by viewport-sized work.
    local clip_left, clip_top = -half, -half
    -- The theoretical inclusive pixel-centre edge is size-1+half. DDA
    -- samples are floored before stamping, so a fractional centre in the next
    -- unit interval can still touch the final pixel. Keep that one-sample
    -- fringe here; paintSample remains the authoritative hard clip.
    local clip_right, clip_bottom = bw + half, bh + half
    if not finite(clip_left) or not finite(clip_top)
        or not finite(clip_right) or not finite(clip_bottom) then
        return false
    end
    local first, last = 0, 1
    first, last = clipAxis(x0, dx,
        clip_left, clip_right, first, last)
    if not first then return false end
    first, last = clipAxis(y0, dy,
        clip_top, clip_bottom, first, last)
    if not first then return false end
    local first_i = floor(first * steps) - 1
    local last_i = ceil(last * steps) + 1
    if first_i < 0 then first_i = 0 end
    if last_i > steps then last_i = steps end
    if first_i > last_i then return false end

    -- A corrupt width can expand the centre-line clip by billions of pixels
    -- even though every eventual paintRect is clipped to this small buffer.
    -- Reject only when the actual DDA loop would exceed a viewport-derived
    -- work budget: ordinary in-bounds strokes and large dots keep their exact
    -- raster, while hostile persisted geometry cannot monopolise the UI loop.
    local max_samples = bw + bh + 16
    if not finite(max_samples)
        or last_i - first_i + 1 > max_samples then
        return false
    end

    local x = x0 + first_i * sx
    local y = y0 + first_i * sy
    local painted, left, top, right, bottom = false
    for _ = first_i, last_i do
        local hit, l, t, r, b = paintSample(
            bb, x, y, w, half, color, bw, bh)
        if hit then
            if not painted then
                painted, left, top, right, bottom = true, l, t, r, b
            else
                if l < left then left = l end
                if t < top then top = t end
                if r > right then right = r end
                if b > bottom then bottom = b end
            end
        end
        x = x + sx
        y = y + sy
    end
    return painted, left, top, right, bottom
end

--- Replay a whole stroke. ox/oy let a caller shift it; both are 0 today.
function Render.stroke(bb, s, ox, oy, color)
    local n = s.n
    local w = s.w
    if n < 1 then return false end
    if n == 1 then
        return Render.segment(bb, ox + s[1], oy + s[2],
            ox + s[1], oy + s[2], w, color)
    end
    local painted, left, top, right, bottom = false
    for i = 1, (n - 1) * 2, 2 do
        local hit, l, t, r, b = Render.segment(bb,
            ox + s[i], oy + s[i + 1],
            ox + s[i + 2], oy + s[i + 3], w, color)
        if hit then
            if not painted then
                painted, left, top, right, bottom = true, l, t, r, b
            else
                if l < left then left = l end
                if t < top then top = t end
                if r > right then right = r end
                if b > bottom then bottom = b end
            end
        end
    end
    return painted, left, top, right, bottom
end

--[[--
Replay a stroke held as a flat point array, scaled and offset.

The canvas keeps its points in its own coordinates and renders them into a
raster cache whose scale depends on the screen, so unlike `Render.stroke` the
transform cannot be folded into the stored numbers. `ox`/`oy` are what let the
same call paint into a viewport over a repaired region: pass the negated origin
of the region and everything outside it is clipped by the buffer itself.

Still no tables allocated, on any path.
]]
function Render.points(bb, points, n, scale, ox, oy, w, color)
    if n < 1 then return false end
    if n == 1 then
        local x, y = ox + points[1] * scale, oy + points[2] * scale
        return Render.segment(bb, x, y, x, y, w, color)
    end
    local painted, left, top, right, bottom = false
    for i = 1, (n - 1) * 2, 2 do
        local hit, l, t, r, b = Render.segment(bb,
            ox + points[i] * scale,     oy + points[i + 1] * scale,
            ox + points[i + 2] * scale, oy + points[i + 3] * scale,
            w, color)
        if hit then
            if not painted then
                painted, left, top, right, bottom = true, l, t, r, b
            else
                if l < left then left = l end
                if t < top then top = t end
                if r > right then right = r end
                if b > bottom then bottom = b end
            end
        end
    end
    return painted, left, top, right, bottom
end

return Render
