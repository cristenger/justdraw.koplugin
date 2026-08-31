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

return Split
