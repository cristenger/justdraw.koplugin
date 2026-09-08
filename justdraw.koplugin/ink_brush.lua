-- Constant-width round nibs for modern surfaces. Historical square-DDA
-- styles remain in ink_render. Scalar scanline intervals bound work to the
-- target, without resampling the centreline or allocating per stamp.
local BB = require("ffi/blitbuffer")
local Style = require("ink_style")
local Render = require("ink_render")
local floor, ceil, sqrt = math.floor, math.ceil, math.sqrt
local min, max = math.min, math.max
local bit = require("bit")
local Brush = {}
-- A fixed paper grain, shared by live/replay/export. Zero means exposed
-- paper. Coordinates, not frame count or random state, select the grain.
local GRAIN = { 0, 102, 68, 153, 102, 204, 68, 153, 102, 0, 204, 102, 68, 153, 102, 204 }

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function slab(p, d, lo, hi, a, b)
    if d == 0 then
        if p < lo or p > hi then return nil end
        return a, b
    end
    local l, r = (lo - p) / d, (hi - p) / d
    if l > r then l, r = r, l end
    a, b = max(a, l), min(b, r)
    if a > b then return nil end
    return a, b
end

local function circleRow(cx, cy, radius2, y, left, right)
    local dy = y - cy
    local q = radius2 - dy * dy
    if q >= 0 then
        local rx = sqrt(q)
        left, right = min(left, cx - rx), max(right, cx + rx)
    end
    return left, right
end

-- Write pointers are private to our unrotated BB8/BB8A cache and its views.
-- KOReader's partial blend retains destination alpha; source-over must set
-- BOTH components here. Source is black, alpha 51/255. No temporary colors.
local function highlightRow(bb, mask, x0, x1, y, ox, oy, alpha)
    local pixels = bb:getPixelP(x0, y)
    local coverage = mask:getPixelP(x0 - ox, y - oy)
    for i = 0, x1 - x0 do
        if coverage[i].a == 0 then
            coverage[i].a = 255
            if alpha then
                local old_a = tonumber(pixels[i].alpha)
                local a = 51 + floor(old_a * 204 / 255 + 0.5)
                pixels[i].a = floor(tonumber(pixels[i].a) * old_a * 204 / (255 * a) + 0.5)
                pixels[i].alpha = a
            else
                pixels[i].a = floor(tonumber(pixels[i].a) * 204 / 255 + 0.5)
            end
        end
    end
end

local function graphiteRow(bb, x0, x1, y, ox, oy, step, alpha)
    local pixels = bb:getPixelP(x0,y)
    local gy = floor((y - oy + 0.5) / step) % 241
    for x = x0, x1 do
        local gx = floor((x - ox + 0.5) / step) % 251
        local seed = (gx * 183631 + gy * 297121 + gx * gy * 13) % 1048573
        local shade = GRAIN[bit.band(bit.bxor(seed, bit.rshift(seed, 7)), 15) + 1]
        if shade ~= 0 then
            pixels[x-x0].a = shade
            if alpha then pixels[x-x0].alpha = 255 end
        end
    end
end

function Brush.segment(bb, x0, y0, x1, y1, width, style, mask, ox, oy, scale, logical_width)
    if not bb or not finite(x0) or not finite(y0) or not finite(x1)
        or not finite(y1) or not finite(width) or width < 1
        or width ~= floor(width) then return false end
    local bw, bh = bb:getWidth(), bb:getHeight()
    ox, oy = ox or 0, oy or 0
    if style == Style.HIGHLIGHTER or style == Style.TEXTURED then
        assert(bb:getRotation() == 0 and bb:getInverse() == 0, "brush requires a normal cache")
        assert(bb:getType() == BB.TYPE_BB8 or bb:getType() == BB.TYPE_BB8A, "unsupported brush target")
    end
    if style == Style.HIGHLIGHTER then
        assert(mask and mask:getType() == BB.TYPE_BB8 and mask:getRotation() == 0,
            "highlighter requires prepared coverage")
        assert(ox == floor(ox) and oy == floor(oy) and ox <= 0 and oy <= 0
            and bw - ox <= mask:getWidth() and bh - oy <= mask:getHeight(), "coverage bounds")
    end
    local grain_step
    if style == Style.TEXTURED then
        scale = scale or 1
        if not finite(scale) or scale <= 0 then return false end
        grain_step = scale * max(0.5, min(1.5, (logical_width or width/scale) / 12))
        if not finite(grain_step) or grain_step <= 0 then return false end
    end
    local radius = width / 2
    local dx, dy = x1 - x0, y1 - y0
    local len2, r2 = dx * dx + dy * dy, radius * radius
    if not finite(len2) or not finite(r2) then return false end
    -- Odd nibs are centred on a pixel; even nibs straddle pixel centres.
    local offset = width % 2 == 1 and 0.5 or 0
    x0, y0, x1, y1 = x0 + offset, y0 + offset, x1 + offset, y1 + offset
    local first = max(0, ceil(min(y0, y1) - radius - 0.5))
    local last = min(bh - 1, floor(max(y0, y1) + radius - 0.5))
    local length = sqrt(len2)
    local ux, uy = 0, 0
    if length > 0 then ux, uy = dx / length, dy / length end
    local painted, left, top, right, bottom = false
    for y = first, last do
        local py = y + 0.5
        local l, r = circleRow(x0, y0, r2, py, math.huge, -math.huge)
        l, r = circleRow(x1, y1, r2, py, l, r)
        if length > 0 then
            -- Intersect a horizontal row with the oriented body rectangle.
            local a, b = slab((py-y0)*uy-x0*ux, ux, 0, length, -0.5, bw-0.5)
            if a then
                a, b = slab((py-y0)*ux+x0*uy, -uy, -radius, radius, a, b)
                if a then l, r = min(l, a), max(r, b) end
            end
        end
        l, r = max(0, ceil(l - 0.5)), min(bw - 1, floor(r - 0.5))
        if l <= r then
            if style == Style.HIGHLIGHTER then
                highlightRow(bb, mask, l, r, y, ox, oy, bb:getType() == BB.TYPE_BB8A)
            elseif style == Style.TEXTURED then
                graphiteRow(bb, l, r, y, ox, oy, grain_step, bb:getType() == BB.TYPE_BB8A)
            else
                Render.safeRect(bb, l, y, r - l + 1, 1, BB.COLOR_BLACK)
            end
            if not painted then
                painted, left, top, right, bottom = true, l, y, r + 1, y + 1
            else
                left, right, bottom = min(left, l), max(right, r + 1), y + 1
            end
        end
    end
    return painted, left, top, right, bottom
end

function Brush.points(bb, points, n, scale, ox, oy, width, style, mask, logical_width)
    if not finite(n) or n < 1 or n ~= floor(n) then return false end
    local painted, left, top, right, bottom = false
    for j = 1, max(1, n - 1) do
        local i = (j - 1) * 2 + 1
        local k = n == 1 and i or i + 2
        local hit, l, t, r, b = Brush.segment(bb,
            points[i]*scale+ox, points[i+1]*scale+oy,
            points[k]*scale+ox, points[k+1]*scale+oy, width, style, mask, ox, oy, scale, logical_width)
        if hit then
            if not painted then
                painted, left, top, right, bottom = true, l, t, r, b
            else
                left, top, right, bottom = min(left,l), min(top,t), max(right,r), max(bottom,b)
            end
        end
    end
    return painted, left, top, right, bottom
end

return Brush
