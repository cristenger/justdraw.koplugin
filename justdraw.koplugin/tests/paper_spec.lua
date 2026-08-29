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
        }
        for _, kind in ipairs({ "ruled", "grid", "dots" }) do
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
        for _, scale in ipairs({ 0.37, 1.18, 2.5 }) do
            local whole = support.newBlitbuffer(300, 300)
            Paper.paint(whole, "grid", scale, 0, 0, 300, 300, MARK)
            local part = support.newBlitbuffer(300, 300)
            Paper.paint(part, "grid", scale, 41, 63, 111, 97, MARK)
            local label = "scale " .. scale
            sameWrites(writesIn(part, 41, 63, 111, 97),
                writesIn(whole, 41, 63, 111, 97), label)
            t:eq(part:writesOutside(41, 63, 111, 97), 0,
                label .. " stays inside the box")
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
