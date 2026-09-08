--[[--
Where an eraser pass cuts a stroke, computed on plain numbers.

Whole-stroke erase (ADR-7) deletes a word to fix a letter. The alternative
needs one geometric answer shared by every surface: given a stroke's points
and the capsule a moving eraser swept between two samples, which segments
die, which maximal runs survive, and what region stops being ink. This module
is that answer and nothing else -- no raster, no store, no KOReader -- so the
direct route's sidecar arrays and the canvas engine's decoded chunks can both
ask it, and its edge cases can be pinned by tests that need no fixture.

Everything works on flat `{x1, y1, x2, y2, ...}` arrays and answers with
index ranges into them rather than copies: the callers own their memory
budgets, and the miss path -- almost every call -- allocates nothing at all.
The capsule is the load-bearing part: testing two sample circles instead
lets a fast hand slide the eraser between them (ADR-32).
]]

local sqrt = math.sqrt

local Split = {}

--- Squared distance from a point to a segment.
function Split.pointSegmentDistance2(px, py, x0, y0, x1, y1)
    local vx, vy = x1 - x0, y1 - y0
    local len2 = vx * vx + vy * vy
    if len2 == 0 then
        local dx, dy = px - x0, py - y0
        return dx * dx + dy * dy
    end
    local at = ((px - x0) * vx + (py - y0) * vy) / len2
    if at < 0 then at = 0 elseif at > 1 then at = 1 end
    local dx = px - (x0 + at * vx)
    local dy = py - (y0 + at * vy)
    return dx * dx + dy * dy
end

local function orient(ax, ay, bx, by, cx, cy)
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

--- Squared distance between two segments; zero when they cross. Collinear
--- overlap needs no special case: at least one endpoint of one segment lies
--- on the other, so the endpoint distances below already answer zero.
function Split.segmentSegmentDistance2(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
    local d1 = orient(bx0, by0, bx1, by1, ax0, ay0)
    local d2 = orient(bx0, by0, bx1, by1, ax1, ay1)
    local d3 = orient(ax0, ay0, ax1, ay1, bx0, by0)
    local d4 = orient(ax0, ay0, ax1, ay1, bx1, by1)
    if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
        and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)) then
        return 0
    end
    local best = Split.pointSegmentDistance2(ax0, ay0, bx0, by0, bx1, by1)
    local d = Split.pointSegmentDistance2(ax1, ay1, bx0, by0, bx1, by1)
    if d < best then best = d end
    d = Split.pointSegmentDistance2(bx0, by0, ax0, ay0, ax1, ay1)
    if d < best then best = d end
    d = Split.pointSegmentDistance2(bx1, by1, ax0, ay0, ax1, ay1)
    if d < best then best = d end
    return best
end

--- Whether any segment of points[first..last] -- or, when first == last,
--- the lone point -- comes within sqrt(r2) of the eraser capsule.
--- Allocates nothing; this is the gate every miss exits through.
function Split.capsuleHitsRange(points, first, last, ex0, ey0, ex1, ey1, r2)
    if first == last then
        return Split.pointSegmentDistance2(points[first * 2 - 1],
            points[first * 2], ex0, ey0, ex1, ey1) <= r2
    end
    for j = first + 1, last do
        if Split.segmentSegmentDistance2(
            points[j * 2 - 3], points[j * 2 - 2],
            points[j * 2 - 1], points[j * 2],
            ex0, ey0, ex1, ey1) <= r2 then
            return true
        end
    end
    return false
end

--[[--
Cut a stroke where the capsule touched it.

Returns nil when nothing is within `reach` -- the stroke is untouched and
nothing was allocated. On a hit, returns `fragments, removed_box` as
documented in the header. A surviving run whose polyline is shorter than
`min_keep_len` is dropped with the segments around it: a two-point sliver
where the eraser clipped an end reads as dirt, not as ink someone kept.
]]
function Split.splitByCapsule(points, n, ex0, ey0, ex1, ey1, reach, min_keep_len)
    local r2 = reach * reach
    if n == 1 then
        local x, y = points[1], points[2]
        if Split.pointSegmentDistance2(x, y, ex0, ey0, ex1, ey1) > r2 then
            return nil
        end
        return {}, { min_x = x, min_y = y, max_x = x, max_y = y }
    end
    if not Split.capsuleHitsRange(points, 1, n, ex0, ey0, ex1, ey1, r2) then
        return nil
    end

    local fragments = {}
    local removed = nil
    local run_first = nil
    min_keep_len = min_keep_len or 0

    local function extendRemoved(x, y)
        if not removed then
            removed = { min_x = x, min_y = y, max_x = x, max_y = y }
        else
            if x < removed.min_x then removed.min_x = x
            elseif x > removed.max_x then removed.max_x = x end
            if y < removed.min_y then removed.min_y = y
            elseif y > removed.max_y then removed.max_y = y end
        end
    end

    local function closeRun(last_point)
        if not run_first then return end
        local first_point = run_first
        run_first = nil
        local len = 0
        for i = first_point + 1, last_point do
            local dx = points[i * 2 - 1] - points[i * 2 - 3]
            local dy = points[i * 2] - points[i * 2 - 2]
            len = len + sqrt(dx * dx + dy * dy)
        end
        if len < min_keep_len then
            for i = first_point, last_point do
                extendRemoved(points[i * 2 - 1], points[i * 2])
            end
            return
        end
        fragments[#fragments + 1] = { first = first_point, last = last_point }
    end

    for k = 1, n - 1 do
        if Split.segmentSegmentDistance2(
            points[k * 2 - 1], points[k * 2],
            points[k * 2 + 1], points[k * 2 + 2],
            ex0, ey0, ex1, ey1) <= r2 then
            closeRun(k)
            extendRemoved(points[k * 2 - 1], points[k * 2])
            extendRemoved(points[k * 2 + 1], points[k * 2 + 2])
        else
            if not run_first then run_first = k end
        end
    end
    closeRun(n)
    return fragments, removed
end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Parameter interval of a segment inside a circle, clipped to [0,1].
local function circleInterval(x, y, dx, dy, cx, cy, r2)
    local fx, fy = x - cx, y - cy
    local a = dx * dx + dy * dy
    local b = fx * dx + fy * dy
    local c = fx * fx + fy * fy - r2
    if not finite(a) or not finite(b) or not finite(c) then return nil end
    if a == 0 then if c <= 0 then return 0, 1 end; return nil end
    local discriminant = b * b - a * c
    if not finite(discriminant) or discriminant < 0 then return nil end
    local root = sqrt(discriminant)
    local first, last = (-b - root) / a, (-b + root) / a
    if first < 0 then first = 0 end
    if last > 1 then last = 1 end
    if first > last then return nil end
    return first, last
end

local function slab(p, d, low, high, first, last)
    if d == 0 then
        if p < low or p > high then return nil end
        return first, last
    end
    local a, b = (low - p) / d, (high - p) / d
    if not finite(a) or not finite(b) then return nil end
    if a > b then a, b = b, a end
    if a > first then first = a end
    if b < last then last = b end
    if first > last then return nil end
    return first, last
end

-- A capsule is convex: the union of its body and end-circle intervals is
-- one interval. The sweep's unit vector is computed once per erase query.
local function capsuleInterval(x, y, dx, dy, ex0, ey0, ex1, ey1, ux, uy, len, r, r2)
    local first, last = circleInterval(x, y, dx, dy, ex0, ey0, r2)
    if len == 0 then return first, last end
    local a, b = circleInterval(x, y, dx, dy, ex1, ey1, r2)
    if a then
        if not first or a < first then first = a end
        if not last or b > last then last = b end
    end
    local fx, fy = x - ex0, y - ey0
    a, b = slab(fx * ux + fy * uy, dx * ux + dy * uy, 0, len, 0, 1)
    if a then a, b = slab(-fx * uy + fy * ux, -dx * uy + dy * ux, -r, r, a, b) end
    if a then
        if not first or a < first then first = a end
        if not last or b > last then last = b end
    end
    return first, last
end

--[[--
Exact cuts for modern surfaces (ADR-47). Surviving fragments carry new flat
point arrays because intersections need not coincide with recorded samples.
Legacy sidecars keep splitByCapsule's index-range contract unchanged.
The miss path allocates nothing; no resampling proportional to segment length
is performed. Refused geometry leaves the original untouched.
]]
function Split.clipByCapsule(points, n, ex0, ey0, ex1, ey1, reach, min_keep_len)
    local r2 = reach * reach
    local edx, edy = ex1 - ex0, ey1 - ey0
    local len = sqrt(edx * edx + edy * edy)
    if not finite(r2) or not finite(len) or reach < 0 then return nil end
    if not Split.capsuleHitsRange(points, 1, n, ex0, ey0, ex1, ey1, r2) then return nil end
    local ux, uy = 0, 0
    if len > 0 then ux, uy = edx / len, edy / len end
    local fragments, removed, run = {}, nil, nil
    local function remove(x, y)
        if not removed then removed = { min_x=x, min_y=y, max_x=x, max_y=y }
        else
            removed.min_x = math.min(removed.min_x, x); removed.max_x = math.max(removed.max_x, x)
            removed.min_y = math.min(removed.min_y, y); removed.max_y = math.max(removed.max_y, y)
        end
    end
    local function append(x, y)
        if not run then run = {} end
        local k = #run
        if k > 0 and math.abs(run[k-1]-x) < 1e-9 and math.abs(run[k]-y) < 1e-9 then return end
        run[k+1], run[k+2] = x, y
    end
    local function closeRun()
        if not run then return end
        local length = 0
        for i=3,#run,2 do
            local dx, dy = run[i]-run[i-2], run[i+1]-run[i-1]
            length = length + sqrt(dx*dx+dy*dy)
        end
        if #run < 4 or length < (min_keep_len or 0) then
            for i=1,#run,2 do remove(run[i],run[i+1]) end
        else fragments[#fragments+1] = { points=run, n=#run/2 } end
        run = nil
    end
    if n == 1 then remove(points[1],points[2]); return fragments, removed end
    for i=3,n*2,2 do
        local x,y = points[i-2],points[i-1]
        local dx,dy = points[i]-x,points[i+1]-y
        if not finite(dx) or not finite(dy) then return nil end
        local a,b = capsuleInterval(x,y,dx,dy,ex0,ey0,ex1,ey1,ux,uy,len,reach,r2)
        -- A tangent removes no length. Degenerate samples inside the rubber
        -- still divide the runs, so they cannot bridge a later cut.
        if a and b-a > 1e-12 then
            if a > 0 then append(x,y); append(x+dx*a,y+dy*a) end
            closeRun()
            remove(x+dx*a,y+dy*a); remove(x+dx*b,y+dy*b)
            if b < 1 then append(x+dx*b,y+dy*b); append(points[i],points[i+1]) end
        else
            append(x,y); append(points[i],points[i+1])
        end
    end
    closeRun()
    if not removed then return nil end
    return fragments, removed
end

return Split
