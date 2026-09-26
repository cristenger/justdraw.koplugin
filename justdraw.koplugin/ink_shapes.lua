--[[--
Clean shapes, generated -- never recognised from a stroke (U-2, ADR-56).

The reader picks a kind, a size and, for lines and arrows, a direction; this
module turns that into one ordinary stroke: a polyline in the destination's
canvas units, relative to its own corner, ready for `ink_placement`. Because a
shape is a single stroke, undo, the lasso and the eraser treat it as one piece
of ink, with no special case anywhere else.

Sizes are millimetres *on screen* (S 15, M 30, L 60) for the longest side of
the shape's real bounding box -- an arrow's wings included -- so a large arrow
never overhangs what the reader asked for. Angles count counter-clockwise on
screen from "pointing right", which is why y subtracts the sine: screen y grows
downwards.

Pure arithmetic: validated input, a bounded number of points, no state.
]]

local Shapes = {
    KINDS = { "line", "arrow", "square", "rectangle", "circle", "ellipse", "triangle" },
    SIZES = { S = 15, M = 30, L = 60 },
    SIZE_ORDER = { "S", "M", "L" },
    LINE_ANGLES = { 0, 45, 90, 135 },
    ARROW_ANGLES = { 0, 45, 90, 135, 180, 225, 270, 315 },
    DEFAULT = { kind = "line", size = "M", angle = 0 },
    --- Closed curves: one point per this many screen pixels of perimeter,
    --- between the two bounds.
    CURVE_STEP_PX = 6,
    CURVE_MIN = 24,
    CURVE_MAX = 360,
    WING_MM = 3,
    WING_RATIO = 0.2,
    WING_DEGREES = 28,
}

local KIND_SET = {}
for _, k in ipairs(Shapes.KINDS) do KIND_SET[k] = true end

local cos, sin, rad, pi, sqrt, ceil = math.cos, math.sin, math.rad, math.pi, math.sqrt, math.ceil

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function allowedAngles(kind)
    if kind == "line" then return Shapes.LINE_ANGLES end
    if kind == "arrow" then return Shapes.ARROW_ANGLES end
    return nil
end
Shapes.allowedAngles = allowedAngles

--- Options as stored in settings, made safe: anything unknown goes back to
--- the default, and an angle the kind does not offer becomes 0.
function Shapes.normalize(opts)
    opts = type(opts) == "table" and opts or {}
    local kind = KIND_SET[opts.kind] and opts.kind or Shapes.DEFAULT.kind
    local size = Shapes.SIZES[opts.size] and opts.size or Shapes.DEFAULT.size
    local angle = 0
    local angles = allowedAngles(kind)
    if angles then
        for _, a in ipairs(angles) do if a == opts.angle then angle = a end end
    end
    return { kind = kind, size = size, angle = angle }
end

--- Points of the unit shape, in screen-pixel space, before scaling.
local function outline(kind, angle, size_px, wing_px)
    local pts = {}
    local function add(x, y) pts[#pts + 1] = x; pts[#pts + 1] = y end
    if kind == "line" or kind == "arrow" then
        local th = rad(angle)
        local dx, dy = cos(th), -sin(th)
        local tx, ty = size_px * dx, size_px * dy
        add(0, 0); add(tx, ty)
        if kind == "arrow" then
            local w = rad(Shapes.WING_DEGREES)
            for _, sign in ipairs({ 1, -1 }) do
                local c, s = cos(sign * w), sin(sign * w)
                -- The wing points back along the shaft, turned by ±28°.
                local bx, by = -dx, -dy
                local wx, wy = bx * c - by * s, bx * s + by * c
                add(tx + wx * wing_px, ty + wy * wing_px)
                if sign == 1 then add(tx, ty) end
            end
        end
    elseif kind == "square" or kind == "rectangle" then
        local w, h = size_px, kind == "square" and size_px or size_px * 2 / 3
        add(0, 0); add(w, 0); add(w, h); add(0, h); add(0, 0)
    elseif kind == "triangle" then
        local b = size_px
        local h = 0.866 * b
        add(0, h); add(b / 2, 0); add(b, h); add(0, h)
    elseif kind == "circle" or kind == "ellipse" then
        local a = size_px / 2
        local b = kind == "circle" and a or a * 2 / 3
        -- Ramanujan's perimeter; exact for the circle.
        local h = ((a - b) / (a + b)) ^ 2
        local perimeter = pi * (a + b) * (1 + 3 * h / (10 + sqrt(4 - 3 * h)))
        -- The closing point counts inside the budget (§6.1): the whole
        -- curve, closed, is CURVE_MIN..CURVE_MAX points.
        local n = ceil(perimeter / Shapes.CURVE_STEP_PX)
        if n < Shapes.CURVE_MIN - 1 then n = Shapes.CURVE_MIN - 1 end
        if n > Shapes.CURVE_MAX - 1 then n = Shapes.CURVE_MAX - 1 end
        for i = 0, n - 1 do
            local th = 2 * pi * i / n
            add(a + a * cos(th), b - b * sin(th))
        end
        add(pts[1], pts[2])
    end
    return pts
end

--[[--
Generate one shape.

  opts.kind, opts.size ("S"|"M"|"L"), opts.angle   see `normalize`
  opts.mm_to_px   function(mm) -> screen pixels (the layout's own rounding)
  opts.scale      the destination transform's scale (screen px per unit)
  opts.width      logical nib width, as the pen would store it
  opts.tool       the pen's style

Returns `{strokes = {{points, n, width, tool, group = 1}}, w, h}` in canvas
units with the box's corner at 0,0, or nil and `bad_shape`.
]]
function Shapes.generate(opts)
    opts = opts or {}
    if not KIND_SET[opts.kind] or not Shapes.SIZES[opts.size]
        or type(opts.mm_to_px) ~= "function" or not finite(opts.scale) or opts.scale <= 0
        or not finite(opts.width) or opts.width < 0 or not finite(opts.tool) then
        return nil, "bad_shape"
    end
    local angles = allowedAngles(opts.kind)
    local angle = 0
    if angles then
        local ok = false
        for _, a in ipairs(angles) do if a == opts.angle then ok = true end end
        if not ok then return nil, "bad_shape" end
        angle = opts.angle
    end
    local size_px = opts.mm_to_px(Shapes.SIZES[opts.size])
    local wing_px = math.max(opts.mm_to_px(Shapes.WING_MM), Shapes.WING_RATIO * size_px)
    if not finite(size_px) or size_px <= 0 or not finite(wing_px) then return nil, "bad_shape" end
    local pts = outline(opts.kind, angle, size_px, wing_px)
    local n = #pts / 2
    local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, n do
        local x, y = pts[i * 2 - 1], pts[i * 2]
        if x < min_x then min_x = x end
        if x > max_x then max_x = x end
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
    end
    -- The longest side of the real box, wings included, is the asked size.
    local extent = math.max(max_x - min_x, max_y - min_y)
    local k = extent > 0 and size_px / extent or 1
    local to_units = k / opts.scale
    local out = {}
    for i = 1, n do
        out[i * 2 - 1] = (pts[i * 2 - 1] - min_x) * to_units
        out[i * 2] = (pts[i * 2] - min_y) * to_units
    end
    return {
        strokes = { { points = out, n = n, width = opts.width, tool = opts.tool, group = 1 } },
        w = (max_x - min_x) * to_units, h = (max_y - min_y) * to_units,
    }
end

return Shapes
