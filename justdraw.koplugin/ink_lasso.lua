--[[--
The lasso's geometry: which strokes a closed pen path encloses (ADR-55).

Pure arithmetic over flat arrays, with no UI, cache or repository, so every
rule below can be tested on its own and none of it can reach the page.

Why length, not the box centre or the vertices. A long stroke that only grazes
the lasso has its centre inside; a dense scribble has most of its points in one
corner. "Enclosed" should mean "most of the ink is inside", and ink is length.
So a stroke is sampled at the centres of equal intervals of its accumulated
length, at most `MAX_SAMPLES` of them for the whole stroke -- never per
segment, which let short segments dominate and exceeded the cap -- and it is
selected when at least half the samples fall inside. Zero-length segments add
nothing; a stroke of zero length is its one point.

Inside is even-odd, so a self-intersecting lasso behaves predictably, and a
sample exactly on the lasso's edge counts as inside.

Cost is O(n + k·v) per candidate: n stroke points walked once, k ≤ 512 samples
each tested against v ≤ 256 lasso vertices. The path is simplified to that many
vertices only within one screen pixel of the original; a path that cannot be
made that simple is refused rather than decimated by index, which would change
its shape silently.
]]

local Lasso = {
    --- Accepted pen points in one lasso path.
    MAX_POINTS = 2048,
    --- Vertices the inside test works against.
    MAX_VERTICES = 256,
    --- Samples per stroke, in total.
    MAX_SAMPLES = 512,
    --- Fraction of a stroke's length that must lie inside.
    THRESHOLD = 0.5,
}

local ceil, sqrt = math.ceil, math.sqrt

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local newTable
do
    local ok, tnew = pcall(require, "table.new")
    newTable = ok and tnew or function() return {} end
end

-- ----------------------------------------------------------------- path

local Path = {}
Path.__index = Path

--[[--
A reusable buffer for one lasso path, sized before any contact: accepting a
point writes two numbers into slots that already exist. `min_dist` is the
distance, in the caller's units, below which a point is not worth keeping.
]]
function Lasso.newPath(capacity, min_dist)
    capacity = capacity or Lasso.MAX_POINTS
    local xy = newTable(capacity * 2, 0)
    for i = 1, capacity * 2 do xy[i] = 0 end
    return setmetatable({
        xy = xy, n = 0, capacity = capacity, min_dist = min_dist or 0,
        full = false,
        min_x = 0, min_y = 0, max_x = 0, max_y = 0,
    }, Path)
end

function Path:reset(min_dist)
    self.n = 0
    self.full = false
    if min_dist then self.min_dist = min_dist end
end

--[[--
Offer one point. Returns true when kept, false when skipped as too close, and
nil plus `full` once the buffer is full -- the path stops there and the lasso
is refused at the lift, instead of replacing its last vertex over and over and
quietly changing its shape.
]]
function Path:add(x, y)
    if not finite(x) or not finite(y) then return nil, "bad_point" end
    if self.full then return nil, "full" end
    local n = self.n
    if n > 0 then
        local dx, dy = x - self.xy[n * 2 - 1], y - self.xy[n * 2]
        if dx * dx + dy * dy < self.min_dist * self.min_dist then return false end
    end
    if n >= self.capacity then
        self.full = true
        return nil, "full"
    end
    n = n + 1
    self.xy[n * 2 - 1], self.xy[n * 2] = x, y
    self.n = n
    if n == 1 then
        self.min_x, self.max_x, self.min_y, self.max_y = x, x, y, y
    else
        if x < self.min_x then self.min_x = x elseif x > self.max_x then self.max_x = x end
        if y < self.min_y then self.min_y = y elseif y > self.max_y then self.max_y = y end
    end
    return true
end

--- A tap, not a lasso: fewer than three vertices, or a box under `min_size`
--- on either side.
function Path:isTap(min_size)
    if self.n < 3 then return true end
    return self.max_x - self.min_x < min_size or self.max_y - self.min_y < min_size
end

-- ---------------------------------------------------------- simplification

local function segmentDistance2(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qy = ax + t * dx - px, ay + t * dy - py
    return qx * qx + qy * qy
end
Lasso.segmentDistance2 = segmentDistance2

--[[--
Reduce a path to at most `max_vertices` vertices, each dropped vertex within
`tolerance` of the kept polyline (Douglas-Peucker, iterative, with an explicit
stack). The closing edge is implicit and unaffected: first and last points are
always kept. Returns a new flat array and its vertex count, or nil and
`too_complex` when the tolerance cannot be met within the vertex budget.
]]
function Lasso.simplify(xy, n, tolerance, max_vertices)
    max_vertices = max_vertices or Lasso.MAX_VERTICES
    if n <= 2 then
        local out = {}
        for i = 1, n * 2 do out[i] = xy[i] end
        return out, n
    end
    local keep = { [1] = true, [n] = true }
    local kept = 2
    local stack = { 1, n }
    local tol2 = tolerance * tolerance
    while #stack > 0 do
        local last = table.remove(stack)
        local first = table.remove(stack)
        local ax, ay = xy[first * 2 - 1], xy[first * 2]
        local bx, by = xy[last * 2 - 1], xy[last * 2]
        local worst, worst_d = nil, tol2
        for i = first + 1, last - 1 do
            local d = segmentDistance2(xy[i * 2 - 1], xy[i * 2], ax, ay, bx, by)
            if d > worst_d then worst, worst_d = i, d end
        end
        if worst then
            keep[worst] = true
            kept = kept + 1
            if kept > max_vertices then return nil, "too_complex" end
            stack[#stack + 1] = first; stack[#stack + 1] = worst
            stack[#stack + 1] = worst; stack[#stack + 1] = last
        end
    end
    local out, m = {}, 0
    for i = 1, n do
        if keep[i] then
            m = m + 1
            out[m * 2 - 1], out[m * 2] = xy[i * 2 - 1], xy[i * 2]
        end
    end
    return out, m
end

-- ----------------------------------------------------------------- inside

--- The polygon's bounding box.
function Lasso.bounds(poly, v)
    local min_x, min_y = poly[1], poly[2]
    local max_x, max_y = min_x, min_y
    for i = 2, v do
        local x, y = poly[i * 2 - 1], poly[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end
    return min_x, min_y, max_x, max_y
end

--[[--
Even-odd inside test against a closed polygon of `v` vertices; a point on an
edge (within `edge_eps` squared) is inside.
]]
function Lasso.inside(poly, v, x, y, edge_eps2)
    edge_eps2 = edge_eps2 or 1e-12
    local inside = false
    local jx, jy = poly[v * 2 - 1], poly[v * 2]
    for i = 1, v do
        local ix, iy = poly[i * 2 - 1], poly[i * 2]
        if segmentDistance2(x, y, jx, jy, ix, iy) <= edge_eps2 then return true end
        if (iy > y) ~= (jy > y) then
            local cross_x = ix + (y - iy) * (jx - ix) / (jy - iy)
            if x < cross_x then inside = not inside end
        end
        jx, jy = ix, iy
    end
    return inside
end

--[[--
The fraction of a stroke's length inside the polygon, and how many samples it
took. Samples are the centres of `k` equal intervals of the accumulated length,
`k = clamp(ceil(length / step), 1, max_samples)`: at most `max_samples` for
the whole stroke, however its points are spaced.
]]
function Lasso.coverage(poly, v, points, n, step, max_samples)
    max_samples = max_samples or Lasso.MAX_SAMPLES
    step = (finite(step) and step > 0) and step or 1
    local length = 0
    for i = 2, n do
        local dx = points[i * 2 - 1] - points[i * 2 - 3]
        local dy = points[i * 2] - points[i * 2 - 2]
        length = length + sqrt(dx * dx + dy * dy)
    end
    if length <= 0 then
        return Lasso.inside(poly, v, points[1], points[2]) and 1 or 0, 1
    end
    local k = ceil(length / step)
    if k < 1 then k = 1 elseif k > max_samples then k = max_samples end
    local interval = length / k
    local hits = 0
    local seg, seg_start = 2, 0
    local ax, ay = points[1], points[2]
    local bx, by = points[3], points[4]
    local seg_len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    for s = 1, k do
        local target = (s - 0.5) * interval
        while seg_start + seg_len < target and seg < n do
            seg_start = seg_start + seg_len
            seg = seg + 1
            ax, ay = bx, by
            bx, by = points[seg * 2 - 1], points[seg * 2]
            seg_len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        end
        local t = seg_len > 0 and (target - seg_start) / seg_len or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        if Lasso.inside(poly, v, ax + t * (bx - ax), ay + t * (by - ay)) then
            hits = hits + 1
        end
    end
    return hits / k, k
end

--- Whether a stroke with this covered fraction is selected.
function Lasso.selects(fraction)
    return fraction >= Lasso.THRESHOLD
end

--- Whether two boxes overlap (edges touching count).
function Lasso.boxesTouch(a_min_x, a_min_y, a_max_x, a_max_y, b_min_x, b_min_y, b_max_x, b_max_y)
    return a_max_x >= b_min_x and b_max_x >= a_min_x
        and a_max_y >= b_min_y and b_max_y >= a_min_y
end

return Lasso
