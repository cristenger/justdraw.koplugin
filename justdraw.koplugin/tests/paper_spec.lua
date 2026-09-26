--[[--
The ruling, and the one property that makes erasing on it work.

Almost everything here is a consequence of a single claim: a mark's place is a
function of its index and the scale, never of the region being painted. State
that as an equality -- paint a box, paint the page and crop it, compare the
pixels -- and the erase repair, the rotation rebuild and the live blit are all
covered at once, because each of them is that same partial paint.

The rest guards the edges a pattern renderer gets wrong: writing outside the
box it was handed, a pitch so fine the page reads as grey, a hairline rounding
away to nothing, and a kind that persists but cannot be drawn.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Paper = require("ink_paper")
    local Repository = require("ink_notebook_repository")

    local MARK = "gray"

    --- Every write inside `rect`, as a comparable "x,y,w,h" set.
    local function writesIn(bb, x, y, w, h)
        local out = {}
        for _, r in ipairs(bb.root.writes) do
            local left = r.x < x and x or r.x
            local top = r.y < y and y or r.y
            local right = r.x + r.w > x + w and x + w or r.x + r.w
            local bottom = r.y + r.h > y + h and y + h or r.y + r.h
            if right > left and bottom > top then
                out[#out + 1] = string.format("%d,%d,%d,%d",
                    left, top, right - left, bottom - top)
            end
        end
        table.sort(out)
        return out
    end

    local function sameWrites(got, expected, label)
        t:eq(#got, #expected, label .. " write count")
        for i = 1, math.min(#got, #expected) do
            t:eq(got[i], expected[i], label .. " write " .. i)
        end
    end

    --- How many marks start strictly inside `extent`: the first sits one
    --- pitch in, the last is the last that still begins on the page. A page
    --- whose height is an exact multiple of the pitch has one fewer than the
    --- division suggests, because that mark would begin off the edge.
    local function markCount(extent, pitch)
        local n, k = 0, 1
        while math.floor(k * pitch + 0.5) < extent do
            n = n + 1
            k = k + 1
        end
        return n
    end

    --- Dot indices that begin inside `extent`, and those that also end inside
    --- it. A dot is centred on its intersection, so the ones against the far
    --- edge are cut by the page rather than dropped.
    local function dotCounts(extent, pitch, size)
        local half = math.floor(size / 2)
        local started, whole, k = 0, 0, 1
        while true do
            local left = math.floor(k * pitch + 0.5) - half
            if left >= extent then break end
            started = started + 1
            if left >= 0 and left + size <= extent then whole = whole + 1 end
            k = k + 1
        end
        return started, whole
    end

    --[[--
    A buffer that records nothing.

    The recording fake allocates two tables per write, which is most of what a
    naive allocation test would end up measuring. This one counts and forgets,
    so any growth left over is the renderer's own.
    ]]
    local function silentBuffer(w, h)
        local bb = { w = w, h = h, writes = 0 }
        function bb:getWidth() return self.w end
        function bb:getHeight() return self.h end
        function bb:paintRect() self.writes = self.writes + 1 end
        return bb
    end

    t:describe("ink_paper / ruling")

    t:case("the drawable kinds are exactly the storable ones", function()
        for kind in pairs(Paper.KINDS) do
            t:eq(Repository.KNOWN_TEMPLATES[kind], true,
                kind .. " is storable")
        end
        for kind in pairs(Repository.KNOWN_TEMPLATES) do
            t:eq(Paper.KINDS[kind], true, kind .. " is drawable")
        end
        -- Blank is the one kind with nothing to draw, and that is how the
        -- renderer recognises it rather than by name.
        t:eq(Paper.PITCH.blank, nil, "blank has no pitch")
        for kind in pairs(Paper.KINDS) do
            if kind ~= "blank" then
                t:eq(type(Paper.PITCH[kind]), "number", kind .. " has a pitch")
            end
        end
    end)

    t:case("blank, unknown and absent kinds paint nothing", function()
        for _, kind in ipairs({ "blank", "future-template", "" }) do
            local bb = support.newBlitbuffer(400, 400)
            t:eq(Paper.paint(bb, kind, 1, 0, 0, 400, 400, MARK), false,
                tostring(kind) .. " paints nothing")
            t:eq(#bb.rects, 0, tostring(kind) .. " writes nothing")
        end
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, nil, 1, 0, 0, 400, 400, MARK), false,
            "no kind paints nothing")
        t:eq(#bb.rects, 0, "no kind writes nothing")
    end)

    t:case("a ruled page is horizontal marks one pitch apart", function()
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, "ruled", 1, 0, 0, 400, 400, MARK), true, "painted")
        local pitch = Paper.PITCH.ruled
        -- Indices start at 1: nothing is pinned to the top edge, where the
        -- editor's paper border already sits.
        t:eq(#bb.rects, markCount(400, pitch), "one mark per pitch")
        for i, r in ipairs(bb.rects) do
            t:eq(r.y, i * pitch, "mark " .. i .. " row")
            t:eq(r.x, 0, "mark " .. i .. " spans from the left")
            t:eq(r.w, 400, "mark " .. i .. " spans the width")
            t:eq(r.c, MARK, "mark " .. i .. " colour")
        end
    end)

    t:case("a squared page adds vertical marks on the same pitch", function()
        local ruled = support.newBlitbuffer(400, 400)
        local grid = support.newBlitbuffer(400, 400)
        Paper.paint(ruled, "ruled", 1, 0, 0, 400, 400, MARK)
        Paper.paint(grid, "grid", 1, 0, 0, 400, 400, MARK)
        local pitch = Paper.PITCH.grid
        local rows = markCount(400, pitch)
        t:eq(#grid.rects, 2 * rows, "rows and columns")
        for i = 1, rows do
            t:eq(grid.rects[i].y, i * pitch, "row " .. i)
            t:eq(grid.rects[rows + i].x, i * pitch, "column " .. i)
            t:eq(grid.rects[rows + i].h, 400, "column " .. i .. " spans height")
        end
        -- Different pitches, so a ruled page and a squared one are not the
        -- same drawing with extra lines.
        t:eq(Paper.PITCH.ruled ~= Paper.PITCH.grid, true, "pitches differ")
        t:eq(#ruled.rects, markCount(400, Paper.PITCH.ruled), "ruled rows")
    end)

    t:case("a dotted page marks the intersections of the same grid", function()
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, "dots", 1, 0, 0, 400, 400, MARK), true, "painted")
        local pitch = Paper.PITCH.dots
        local size = 2
        local started, whole_expected = dotCounts(400, pitch, size)
        t:eq(#bb.rects, started * started, "one dot per intersection")
        -- A dot is centred on its intersection the way a nib is, so the ones
        -- against the far edge are legitimately cut by the page. Clipping
        -- them rather than dropping them is what keeps the box equality below
        -- exact; nothing here may exceed the nominal size.
        local whole = 0
        for _, r in ipairs(bb.rects) do
            t:eq(r.w >= 1 and r.w <= size, true, "dot width")
            t:eq(r.h >= 1 and r.h <= size, true, "dot height")
            if r.w == size and r.h == size then whole = whole + 1 end
        end
        t:eq(whole, whole_expected * whole_expected, "only the far edge is clipped")
        t:eq(bb.rects[1].x, pitch - math.floor(size / 2), "first dot column")
        t:eq(bb.rects[1].y, pitch - math.floor(size / 2), "first dot row")
    end)

    t:case("a narrow ruled page is the ruled page at 5.5 mm", function()
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, "ruled_narrow", 1, 0, 0, 400, 400, MARK), true,
            "painted")
        local pitch = Paper.PITCH.ruled_narrow
        t:eq(pitch, 44, "5.5 mm at 8 units per mm")
        t:eq(#bb.rects, markCount(400, pitch), "one mark per pitch")
        for i, r in ipairs(bb.rects) do
            t:eq(r.y, i * pitch, "mark " .. i .. " row")
            t:eq(r.x, 0, "mark " .. i .. " spans from the left")
            t:eq(r.w, 400, "mark " .. i .. " spans the width")
            t:eq(r.h, 1, "mark " .. i .. " is the ruled page's hairline")
        end
        -- Narrow enough to differ from ruled at every scale that rules at all.
        t:check(Paper.PITCH.ruled_narrow < Paper.PITCH.ruled, "narrower than ruled")
        local fine = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(fine, "ruled_narrow", 0.05, 0, 0, 400, 400, MARK), false,
            "and too fine to rule on a tiny fit, like the others")
    end)

    --- Whether any recorded write covers pixel (`px`, `py`).
    local function marked(bb, px, py)
        for _, r in ipairs(bb.root.writes) do
            if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
                return true
            end
        end
        return false
    end

    --- How many recorded writes cover pixel (`px`, `py`).
    local function coverage(bb, px, py)
        local n = 0
        for _, r in ipairs(bb.root.writes) do
            if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then
                n = n + 1
            end
        end
        return n
    end

    --[[--
    The checklist, pixel by pixel, at scale 1: rules every 64, and on each row
    a 32-pixel square whose left edge is at 48 and whose bottom is 8 above the
    rule. Stated as coordinates rather than as counts, because a box one pixel
    off still has four edges.
    ]]
    t:case("a checklist row is a rule with an outlined box above it", function()
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, "checklist", 1, 0, 0, 400, 400, MARK), true, "painted")
        t:eq(Paper.PITCH.checklist, 64, "8 mm at 8 units per mm")
        local rows = markCount(400, 64)
        t:eq(rows, 6, "rows at 64..384")
        -- Every box whose rule is on the page is whole here: the lowest one
        -- ends at 376, above the edge.
        t:eq(#bb.rects, rows + 4 * rows, "a rule and four edges per row")
        for k = 1, rows do
            local rule = 64 * k
            local bottom, top = rule - 8, rule - 40
            local label = "row " .. k
            t:eq(marked(bb, 200, rule), true, label .. " rule")
            t:eq(marked(bb, 0, rule), true, label .. " rule from the left edge")
            -- The four edges, each at its middle.
            t:eq(marked(bb, 48, top + 16), true, label .. " left edge")
            t:eq(marked(bb, 79, top + 16), true, label .. " right edge")
            t:eq(marked(bb, 64, top), true, label .. " top edge")
            t:eq(marked(bb, 64, bottom - 1), true, label .. " bottom edge")
            -- And the corners, written exactly once each.
            t:eq(coverage(bb, 48, top), 1, label .. " top-left corner once")
            t:eq(coverage(bb, 79, top), 1, label .. " top-right corner once")
            t:eq(coverage(bb, 48, bottom - 1), 1, label .. " bottom-left once")
            t:eq(coverage(bb, 79, bottom - 1), 1, label .. " bottom-right once")
            -- Nothing inside the box, nothing just outside it, and the gap
            -- between the box and its rule is paper.
            t:eq(marked(bb, 64, top + 16), false, label .. " inside is empty")
            t:eq(marked(bb, 49, top + 1), false, label .. " inside the corner")
            t:eq(marked(bb, 78, bottom - 2), false, label .. " inside the far corner")
            t:eq(marked(bb, 47, top + 16), false, label .. " left of the box")
            t:eq(marked(bb, 80, top + 16), false, label .. " right of the box")
            t:eq(marked(bb, 64, top - 1), false, label .. " above the box")
            t:eq(marked(bb, 64, bottom), false, label .. " the gap starts")
            t:eq(marked(bb, 64, rule - 1), false, label .. " the gap ends")
        end
        t:eq(marked(bb, 64, 16), false, "nothing above the first box")
    end)

    t:case("a checklist box keeps its shape and thickness at other scales", function()
        for _, scale in ipairs({ 0.37, 1.18, 2.5 }) do
            local bb = support.newBlitbuffer(400, 400)
            Paper.paint(bb, "checklist", scale, 0, 0, 400, 400, MARK)
            local label = "scale " .. scale
            local thick = math.floor(scale + 0.5)
            if thick < 1 then thick = 1 end
            local side = math.floor(32 * scale + 0.5)
            local left = math.floor(48 * scale + 0.5)
            local bottom = math.floor((64 - 8) * scale + 0.5)
            local top = bottom - side
            local rule = math.floor(64 * scale + 0.5)
            t:eq(marked(bb, left, top + math.floor(side / 2)), true,
                label .. " left edge")
            t:eq(marked(bb, left + thick - 1, top + math.floor(side / 2)), true,
                label .. " left edge is as thick as a rule")
            t:eq(marked(bb, left + thick, top + math.floor(side / 2)), false,
                label .. " and no thicker")
            t:eq(marked(bb, left + side - 1, top + math.floor(side / 2)), true,
                label .. " right edge")
            t:eq(marked(bb, left + side, top + math.floor(side / 2)), false,
                label .. " nothing right of it")
            t:eq(marked(bb, left + math.floor(side / 2), top), true,
                label .. " top edge")
            t:eq(marked(bb, left + math.floor(side / 2), bottom - 1), true,
                label .. " bottom edge")
            t:eq(marked(bb, left + math.floor(side / 2), bottom), false,
                label .. " the gap under the box")
            t:eq(marked(bb, left + math.floor(side / 2), top + math.floor(side / 2)),
                false, label .. " inside is empty")
            t:eq(marked(bb, 300, rule), true, label .. " the rule")
            t:eq(marked(bb, 300, rule + thick - 1), true,
                label .. " the rule's thickness")
            for _, r in ipairs(bb.rects) do
                local thin = r.w < r.h and r.w or r.h
                t:eq(thin, thick, label .. " every mark is one rule thick")
            end
        end
    end)

    --[[--
    A page narrower than the checklist's margin still gets its rows.

    The box sits at a fixed logical distance from the edge, so on a page that
    ends inside it the box is cut by the page -- never moved in to fit, which
    would put it somewhere a whole-page paint does not.
    ]]
    t:case("a narrow page cuts the checklist box rather than moving it", function()
        local cut = support.newBlitbuffer(60, 200)
        t:eq(Paper.paint(cut, "checklist", 1, 0, 0, 60, 200, MARK), true, "painted")
        t:eq(cut:writesOutside(0, 0, 60, 200), 0, "nothing past the page")
        t:eq(marked(cut, 48, 40), true, "the left edge is where it always is")
        t:eq(marked(cut, 59, 24), true, "the top edge runs to the page's edge")
        t:eq(marked(cut, 59, 40), false, "and no right edge is invented")
        for _, r in ipairs(cut.rects) do
            if r.w < r.h then
                t:eq(r.x, 48, "the only vertical marks are the left edges")
            end
        end

        local rules_only = support.newBlitbuffer(40, 200)
        t:eq(Paper.paint(rules_only, "checklist", 1, 0, 0, 40, 200, MARK), true,
            "a page narrower than the margin still rules")
        t:eq(#rules_only.rects, markCount(200, 64), "and holds only its rules")
        for _, r in ipairs(rules_only.rects) do
            t:eq(r.w, 40, "each across the whole page")
        end

        -- The margin is logical: half the scale, half the pixels.
        local half = support.newBlitbuffer(100, 200)
        Paper.paint(half, "checklist", 0.5, 0, 0, 100, 200, MARK)
        t:eq(marked(half, 24, 20), true, "a half-scale box starts at 24")
        t:eq(marked(half, 23, 20), false, "and not before")

        -- A repair to the right of the boxes paints rules and only rules.
        local repair = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(repair, "checklist", 1, 100, 0, 200, 400, MARK), true,
            "the rules are still there")
        for _, r in ipairs(repair.rects) do
            t:eq(r.h, 1, "no box edge reaches past the column")
        end
    end)

    t:case("a box whose rule is off the sheet is not drawn", function()
        -- 420 tall: row 7's rule would be at 448, but its box at 408..440
        -- would start on the page. A tick box with no line is not a row.
        local whole = support.newBlitbuffer(400, 420)
        Paper.paint(whole, "checklist", 1, 0, 0, 400, 420, MARK)
        t:eq(marked(whole, 64, 376 - 1), true, "row 6's box is drawn")
        t:eq(marked(whole, 48, 412), false, "row 7's box is not")
        t:eq(#whole.rects, 6 + 4 * 6, "six rows, six boxes")
        -- And a repair at the foot of the page agrees about it.
        local part = support.newBlitbuffer(400, 420)
        Paper.paint(part, "checklist", 1, 0, 380, 120, 40, MARK)
        sameWrites(writesIn(part, 0, 380, 120, 40),
            writesIn(whole, 0, 380, 120, 40), "the foot of the page")
        t:eq(part:writesOutside(0, 380, 120, 40), 0, "inside the repair")
    end)

    --[[--
    A rotation or a new fit rebuilds the raster at another scale. What makes
    that the same paper is that the count of rows and boxes is a property of
    the page in logical units, and each mark lands where the formula for the
    new scale puts it.
    ]]
    t:case("a rebuild at another scale keeps the checklist pattern", function()
        local LOGICAL_W, LOGICAL_H = 1000, 1400
        local function rebuild(scale)
            local w = math.floor(LOGICAL_W * scale + 0.5)
            local h = math.floor(LOGICAL_H * scale + 0.5)
            local bb = support.newBlitbuffer(w, h)
            Paper.paint(bb, "checklist", scale, 0, 0, w, h, MARK)
            local rules, boxes = 0, 0
            for _, r in ipairs(bb.rects) do
                if r.w == w then rules = rules + 1
                elseif r.w > r.h then boxes = boxes + 1 end
            end
            return bb, rules, boxes / 2
        end
        local portrait, rules_p, boxes_p = rebuild(0.4)
        local landscape, rules_l, boxes_l = rebuild(0.3)
        t:eq(rules_p, 21, "1400 units hold 21 rows")
        t:eq(rules_l, rules_p, "the same rows after the rebuild")
        t:eq(boxes_p, rules_p, "a box on every row")
        t:eq(boxes_l, boxes_p, "and the same boxes")
        for _, case in ipairs({ { portrait, 0.4 }, { landscape, 0.3 } }) do
            local bb, scale = case[1], case[2]
            for _, k in ipairs({ 1, 11, 21 }) do
                local bottom = math.floor((64 * k - 8) * scale + 0.5)
                local left = math.floor(48 * scale + 0.5)
                local label = "scale " .. scale .. " row " .. k
                t:eq(marked(bb, left, bottom - 2), true, label .. " box corner")
                t:eq(marked(bb, 400 * scale, math.floor(64 * k * scale + 0.5)),
                    true, label .. " rule")
            end
        end
    end)

    t:case("the new kinds survive a round trip through the stores", function()
        -- The fake store the session tests use mirrors the repository's
        -- strict acceptance, so it has to accept exactly what draws.
        local store = support.newNotebookStore()
        for _, kind in ipairs({ "ruled_narrow", "checklist" }) do
            t:eq(store:setPageTemplate(1, 11, kind), true, kind .. " accepted")
            t:eq(store:getPage(11).template_kind, kind, kind .. " read back")
            local _, page = store:createNotebook{ title = "N",
                logical_w = 1000, logical_h = 1400, template_kind = kind }
            t:eq(page.template_kind, kind, kind .. " a new notebook's page")
        end
        for kind in pairs(Paper.KINDS) do
            t:eq(store:setPageTemplate(1, 11, kind), true,
                kind .. " is accepted by the fake store")
        end
        t:eq(store:setPageTemplate(1, 11, "future-template"), nil,
            "and a kind that does not draw is still refused")
    end)

    --[[--
    The kinds that already existed paint exactly what they painted before
    narrow ruled and checklist were added: an export, a rebuild and a repair
    of an existing notebook come out pixel for pixel the same.

    Each digest folds every write's "x,y,w,h" in order; the numbers were taken
    from the renderer as it stood before this change, and the counts are there
    so a mismatch says whether marks were added or merely moved.
    ]]
    t:case("the existing kinds paint exactly what they always did", function()
        local function digest(bb)
            local h = 0
            for _, r in ipairs(bb.root.writes) do
                local s = string.format("%d,%d,%d,%d;", r.x, r.y, r.w, r.h)
                for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
            end
            return h, #bb.root.writes
        end
        local pinned = {
            { "ruled", 0.4, 1740523103, 41 }, { "ruled", 1, 379086646, 16 },
            { "ruled", 1.18, 1394529038, 14 }, { "ruled", 2.5, 681809920, 6 },
            { "grid", 0.4, 2140712134, 86 }, { "grid", 1, 1100838291, 33 },
            { "grid", 1.18, 1212824112, 28 }, { "grid", 2.5, 1672893806, 12 },
            { "dots", 0.4, 350597389, 1813 }, { "dots", 1, 192291228, 300 },
            { "dots", 1.18, 1007538635, 192 }, { "dots", 2.5, 639692969, 48 },
        }
        for _, p in ipairs(pinned) do
            local bb = support.newBlitbuffer(600, 800)
            Paper.paint(bb, p[1], p[2], 0, 0, 600, 800, MARK)
            local h, n = digest(bb)
            local label = p[1] .. " at " .. p[2]
            t:eq(n, p[4], label .. " write count")
            t:eq(h, p[3], label .. " digest")
        end
    end)

    --[[--
    The claim the erase repair rests on.

    `ink_canvas_cache:repair` clears a padded box and rules it again before
    replaying the strokes that overlap it. If the ruling's phase depended on
    the box -- as a tiled pattern's would -- every erase would leave a seam,
    and it would only be visible on a device.
    ]]
    t:case("painting a box equals painting the page and cropping it", function()
        local boxes = {
            { 0, 0, 400, 400 },     -- the whole page
            { 37, 51, 90, 120 },    -- an interior box on no particular mark
            { 0, 0, 55, 55 },       -- the top-left corner
            { 340, 330, 60, 70 },   -- the bottom-right corner
            { 96, 0, 8, 400 },      -- a sliver straddling a column
            { 0, 191, 400, 3 },     -- a sliver straddling a row
            { 40, 0, 12, 400 },     -- a sliver on the checklist boxes' left edges
            { 55, 30, 20, 20 },     -- the inside of the first box and its edges
            { 0, 54, 400, 4 },      -- a sliver across the first box's bottom edge
            { 78, 100, 6, 90 },     -- the boxes' right edges, cut mid-box
        }
        for _, kind in ipairs({ "ruled", "ruled_narrow", "grid", "dots", "checklist" }) do
            for i, box in ipairs(boxes) do
                local x, y, w, h = box[1], box[2], box[3], box[4]
                local whole = support.newBlitbuffer(400, 400)
                Paper.paint(whole, kind, 1, 0, 0, 400, 400, MARK)
                local part = support.newBlitbuffer(400, 400)
                Paper.paint(part, kind, 1, x, y, w, h, MARK)
                local label = kind .. " box " .. i
                sameWrites(writesIn(part, x, y, w, h),
                    writesIn(whole, x, y, w, h), label)
                -- And nothing at all outside it: the caller has already told
                -- the screen which rectangle it is about to refresh.
                t:eq(part:writesOutside(x, y, w, h), 0,
                    label .. " stays inside the box")
            end
        end
    end)

    t:case("the same equality holds at a scale that is not 1", function()
        for _, kind in ipairs({ "grid", "ruled_narrow", "checklist" }) do
            for _, scale in ipairs({ 0.37, 1.18, 2.5 }) do
                -- The checklist's column of boxes moves with the scale, so
                -- two of the boxes are placed on it rather than on the page:
                -- a sliver across the boxes' left edges, and a box from
                -- inside them out across their right edges.
                local left = math.floor(48 * scale + 0.5)
                local side = math.floor(32 * scale + 0.5)
                local boxes = {
                    { 41, 63, 111, 97 },
                    { left - 2, 0, 5, 300 },
                    { left + 3, 17, side, 140 },
                }
                local whole = support.newBlitbuffer(300, 300)
                Paper.paint(whole, kind, scale, 0, 0, 300, 300, MARK)
                if kind == "checklist" then
                    local edges = 0
                    for _, r in ipairs(whole.rects) do
                        if r.x == left and r.h > r.w then edges = edges + 1 end
                    end
                    t:check(edges > 0,
                        "scale " .. scale .. " the sliver meets the boxes")
                end
                for i, box in ipairs(boxes) do
                    local x, y, w, h = box[1], box[2], box[3], box[4]
                    local part = support.newBlitbuffer(300, 300)
                    Paper.paint(part, kind, scale, x, y, w, h, MARK)
                    local label = kind .. " scale " .. scale .. " box " .. i
                    sameWrites(writesIn(part, x, y, w, h),
                        writesIn(whole, x, y, w, h), label)
                    t:eq(part:writesOutside(x, y, w, h), 0,
                        label .. " stays inside the box")
                end
            end
        end
    end)

    t:case("marks never round away and never grow into ink", function()
        for _, scale in ipairs({ 0.2, 0.5, 1, 3, 40 }) do
            local bb = support.newBlitbuffer(600, 600)
            local painted = Paper.paint(bb, "ruled", scale, 0, 0, 600, 600, MARK)
            if painted then
                for _, r in ipairs(bb.rects) do
                    t:eq(r.h >= 1, true, "scale " .. scale .. " mark is visible")
                    t:eq(r.h <= 4, true, "scale " .. scale .. " mark is thin")
                end
            end
        end
    end)

    t:case("a pitch too fine to be paper is left blank", function()
        -- 8 logical units per mm, so this is the scale at which a 6 mm rule
        -- would land every few pixels and the page would read as grey.
        local fine = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(fine, "ruled", 0.05, 0, 0, 400, 400, MARK), false,
            "too fine to rule")
        t:eq(#fine.rects, 0, "and nothing is written")
        -- A Paperwhite-sized fit of an A5 page is still comfortably above it.
        local small = support.newBlitbuffer(400, 560)
        t:eq(Paper.paint(small, "ruled", 400 / 1184, 0, 0, 400, 560, MARK), true,
            "a small screen still rules")
    end)

    t:case("corrupt geometry paints nothing rather than something huge", function()
        local cases = {
            { 0 / 0, 0, 0, 400, 400 },
            { 1, 0 / 0, 0, 400, 400 },
            { 1, 0, 0, 0, 400 },
            { 1, 0, 0, -10, 400 },
            { 1, 0, 0, math.huge, math.huge },
            { -1, 0, 0, 400, 400 },
            { math.huge, 0, 0, 400, 400 },
            { 1, 1e9, 1e9, 400, 400 },
        }
        for i, c in ipairs(cases) do
            local bb = support.newBlitbuffer(400, 400)
            local painted = Paper.paint(bb, "grid", c[1], c[2], c[3], c[4], c[5], MARK)
            if painted then
                -- Anything it did accept still has to stay inside the buffer.
                t:eq(bb:writesOutside(0, 0, 400, 400), 0,
                    "case " .. i .. " stays inside the buffer")
                t:eq(#bb.rects <= 400 + 400, true,
                    "case " .. i .. " work stays bounded")
            else
                t:eq(#bb.rects, 0, "case " .. i .. " writes nothing")
            end
        end
        t:eq(Paper.paint(nil, "grid", 1, 0, 0, 400, 400, MARK), false,
            "no buffer paints nothing")
        local bb = support.newBlitbuffer(400, 400)
        t:eq(Paper.paint(bb, "grid", 1, 0, 0, 400, 400, nil), false,
            "no colour paints nothing")
        t:eq(#bb.rects, 0, "and writes nothing")
    end)

    --- The rule `ink_render` states for itself, for the same reason: this runs
    --- inside a rebuild that a rotation can trigger while a page is dense.
    t:case("ruling a page allocates nothing", function()
        local bb = silentBuffer(600, 800)
        local function rule()
            Paper.paint(bb, "dots", 1.18, 0, 0, 600, 800, MARK)
            Paper.paint(bb, "grid", 1.18, 37, 51, 90, 120, MARK)
            Paper.paint(bb, "ruled", 0.4, 0, 0, 600, 800, MARK)
            Paper.paint(bb, "ruled_narrow", 0.7, 0, 0, 600, 800, MARK)
            Paper.paint(bb, "checklist", 1.18, 0, 0, 600, 800, MARK)
            Paper.paint(bb, "checklist", 2.5, 30, 90, 150, 300, MARK)
        end
        for _ = 1, 50 do rule() end
        t:eq(bb.writes > 0, true, "the warm-up actually ruled something")
        -- LuaJIT's trace objects live on the GC heap, so the first rounds
        -- grow while these loops are still being compiled -- under -joff the
        -- very first round is already flat. So the claim is that the growth
        -- *stops*: something allocating per mark would never reach a round
        -- that adds nothing, however long it were warmed up first.
        local settled, last = false, nil
        for _ = 1, 8 do
            collectgarbage()
            collectgarbage()
            local before = collectgarbage("count")
            for _ = 1, 200 do rule() end
            collectgarbage()
            collectgarbage()
            last = collectgarbage("count") - before
            if last <= 0 then settled = true; break end
        end
        t:eq(settled, true,
            "growth reaches zero (last round " .. tostring(last) .. " KiB)")
    end)
end
