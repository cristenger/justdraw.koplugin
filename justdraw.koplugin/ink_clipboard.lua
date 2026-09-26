--[[--
The ink clipboard: what Copy and Cut hold for Paste, for as long as KOReader
runs (§D.7).

Process state, never on disk, reachable from every notebook page and every
sheet. Three rules make it safe to share that widely:

* **Copies both ways.** `set`/`prepare` copy the strokes they are given, and
  `payload` hands out a fresh copy every time. The clipboard never holds a
  table the page, the history or a selection could still change, and a paste
  can never change what the next paste gets.
* **No identities.** Only geometry and style are kept -- points relative to
  the payload's own corner, width, style, the scale they were copied at and
  the relative paint groups. No ids, keys, metas, sessions or paths, so a
  payload outlives the page, the book or the notebook it came from.
* **Paint groups survive.** Fragments of one highlighter stroke share a paint
  order and therefore one coverage (ADR-48); dropping that on copy would give
  a pasted highlight darker seams. Groups are kept as ranks and become new
  paint orders above the destination's ink when pasted.

`payload(dest_scale)` rescales by `source_scale / dest_scale`, so pasted ink
keeps the on-screen size it was copied at (§D.7). A payload larger than the
destination page is refused by the placement, not shrunk.
]]

local Clipboard = {
    MAX_STROKES = 256,
    MAX_POINTS = 65536,
}

local held = nil

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--[[--
Validate and copy a payload without publishing it -- Cut prepares first and
publishes only once its removal was accepted, so a refused cut leaves the
previous clipboard untouched.

`strokes[i] = {points, n, width, tool, paint_seq?, pressure?}` in the source
surface's canvas units; `opts.scale` is that surface's transform scale.
Returns the prepared payload or nil and a reason.
]]
function Clipboard.prepare(strokes, opts)
    opts = opts or {}
    local scale = opts.scale
    if not finite(scale) or scale <= 0 then return nil, "bad_scale" end
    if type(strokes) ~= "table" or #strokes == 0 then return nil, "empty" end
    if #strokes > Clipboard.MAX_STROKES then return nil, "too_large" end
    local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
    local total = 0
    for i = 1, #strokes do
        local s = strokes[i]
        if type(s) ~= "table" or type(s.points) ~= "table" or not finite(s.n)
            or s.n < 1 or s.n ~= math.floor(s.n) or not finite(s.width) or s.width < 0
            or not finite(s.tool) then return nil, "bad_stroke" end
        if s.pressure ~= nil and (type(s.pressure) ~= "table" or #s.pressure ~= s.n) then
            return nil, "bad_pressure"
        end
        total = total + s.n
        if total > Clipboard.MAX_POINTS then return nil, "too_large" end
        for p = 1, s.n do
            local x, y = s.points[p * 2 - 1], s.points[p * 2]
            if not finite(x) or not finite(y) then return nil, "bad_stroke" end
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
        end
    end
    -- Relative paint groups: the order of first appearance of each distinct
    -- paint order, sorted, so both membership and stacking are preserved.
    local orders, seen = {}, {}
    for i = 1, #strokes do
        local order = strokes[i].paint_seq or i
        if not seen[order] then seen[order] = true; orders[#orders + 1] = order end
    end
    table.sort(orders)
    local rank = {}
    for i = 1, #orders do rank[orders[i]] = i end
    local copies = {}
    for i = 1, #strokes do
        local s = strokes[i]
        local points = {}
        for p = 1, s.n do
            points[p * 2 - 1] = s.points[p * 2 - 1] - min_x
            points[p * 2] = s.points[p * 2] - min_y
        end
        local pressure
        if s.pressure then
            pressure = {}
            for p = 1, s.n do pressure[p] = s.pressure[p] end
        end
        copies[i] = { points = points, n = s.n, width = s.width, tool = s.tool,
            group = rank[s.paint_seq or i], pressure = pressure }
    end
    return {
        strokes = copies, w = max_x - min_x, h = max_y - min_y,
        scale = scale, points = total,
    }
end

--- Make a prepared payload the clipboard's content.
function Clipboard.publish(prepared)
    if type(prepared) ~= "table" or not prepared.strokes then return nil, "bad_payload" end
    held = prepared
    return true
end

--- Copy: prepare and publish in one step.
function Clipboard.set(strokes, opts)
    local prepared, err = Clipboard.prepare(strokes, opts)
    if not prepared then return nil, err end
    return Clipboard.publish(prepared)
end

function Clipboard.hasContent()
    return held ~= nil
end

--[[--
A fresh copy of the content for a destination at `dest_scale`: relative
points, width, size, tool and paint group, all rescaled so the ink keeps its
copied on-screen size. Returns nil and a reason when empty or asked for an
impossible scale.
]]
function Clipboard.payload(dest_scale)
    if not held then return nil, "empty" end
    if not finite(dest_scale) or dest_scale <= 0 then return nil, "bad_scale" end
    local k = held.scale / dest_scale
    local strokes = {}
    for i = 1, #held.strokes do
        local s = held.strokes[i]
        local points = {}
        for p = 1, s.n * 2 do points[p] = s.points[p] * k end
        local pressure
        if s.pressure then
            pressure = {}
            for p = 1, s.n do pressure[p] = s.pressure[p] end
        end
        strokes[i] = { points = points, n = s.n, width = s.width * k, tool = s.tool,
            group = s.group, pressure = pressure }
    end
    return { strokes = strokes, w = held.w * k, h = held.h * k, points = held.points }
end

--- Retained points, for the owner's shared editing budget.
function Clipboard.retainedPoints()
    return held and held.points or 0
end

function Clipboard.clear()
    held = nil
    return true
end

return Clipboard
