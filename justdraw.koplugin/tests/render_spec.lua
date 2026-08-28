return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Render = require("ink_render")

    local function reference(bb, x0, y0, x1, y1, w, color)
        local half = math.floor(w / 2)
        local dx, dy = x1 - x0, y1 - y0
        local steps = math.max(math.abs(dx), math.abs(dy))
        if steps < 1 then
            bb:paintRect(math.floor(x0) - half,
                math.floor(y0) - half, w, w, color)
            return
        end
        steps = math.floor(steps)
        local sx, sy = dx / steps, dy / steps
        local x, y = x0, y0
        for _ = 0, steps do
            bb:paintRect(math.floor(x) - half,
                math.floor(y) - half, w, w, color)
            x, y = x + sx, y + sy
        end
    end

    local function sameRects(got, expected, label)
        t:eq(#got, #expected, label .. " count")
        for i = 1, math.min(#got, #expected) do
            for _, key in ipairs{ "x", "y", "w", "h", "c" } do
                t:eq(got[i][key], expected[i][key],
                    label .. " rectangle " .. i .. " " .. key)
            end
        end
    end

    t:describe("ink_render / clipped DDA")

    t:case("fully visible segments preserve the original DDA output", function()
        local cases = {
            { 10, 10, 20, 10, 3 },
            { 10, 10, 10, 20, 4 },
            { 10, 10, 20, 20, 3 },
            { 20, 20, 10, 10, 4 },
        }
        for i, c in ipairs(cases) do
            local got = support.newBlitbuffer(40, 40)
            local expected = support.newBlitbuffer(40, 40)
            local painted = Render.segment(got,
                c[1], c[2], c[3], c[4], c[5], 7)
            reference(expected, c[1], c[2], c[3], c[4], c[5], 7)
            t:eq(painted, true, "case " .. i .. " painted")
            sameRects(got.rects, expected.rects, "case " .. i)
        end
    end)

    t:case("coverage is the positive half-open union of clipped writes", function()
        local bb = support.newBlitbuffer(20, 20)
        local painted, left, top, right, bottom =
            Render.segment(bb, -10, 5, 10, 5, 4, 1)
        t:eq(painted, true, "crossing paints")
        t:eq(left, 0, "left is clipped")
        t:eq(top, 3, "top")
        t:eq(right, 12, "exclusive right")
        t:eq(bottom, 7, "exclusive bottom")
        t:check(right - left > 0 and bottom - top > 0, "positive dimensions")
        t:eq(bb:writesOutside(0, 0, 20, 20), 0, "no write escaped")
    end)

    t:case("dot branches share segment validation and clipping", function()
        local function checkAll(x, y, visible, label)
            local a = support.newBlitbuffer(10, 10)
            local b = support.newBlitbuffer(10, 10)
            local c = support.newBlitbuffer(10, 10)
            local pa = Render.segment(a, x, y, x, y, 3, 1)
            local pb = Render.stroke(b, { n = 1, w = 3, x, y }, 0, 0, 1)
            local pc = Render.points(c, { x, y }, 1, 1, 0, 0, 3, 1)
            t:eq(pa, visible, label .. " segment")
            t:eq(pb, visible, label .. " stroke")
            t:eq(pc, visible, label .. " points")
        end
        checkAll(5, 5, true, "inside")
        checkAll(0, 5, true, "left border")
        checkAll(9, 5, true, "right border")
        checkAll(5, 0, true, "top border")
        checkAll(5, 9, true, "bottom border")
        checkAll(-100, -100, false, "outside")
    end)

    t:case("a nib larger than the viewport is clipped before paintRect", function()
        local bb = support.newBlitbuffer(10, 8)
        local painted, left, top, right, bottom =
            Render.segment(bb, 5, 4, 5, 4, 1000, 1)
        t:eq(painted, true, "the visible intersection is painted")
        t:eq(#bb.rects, 1, "one bounded write")
        t:eq(bb.rects[1].x, 0, "bounded x")
        t:eq(bb.rects[1].y, 0, "bounded y")
        t:eq(bb.rects[1].w, 10, "never passes the huge width")
        t:eq(bb.rects[1].h, 8, "never passes the huge height")
        t:eq(left, 0, "coverage left")
        t:eq(top, 0, "coverage top")
        t:eq(right, 10, "coverage right")
        t:eq(bottom, 8, "coverage bottom")
    end)

    t:case("a corrupt nib cannot expand a long segment into unbounded work", function()
        local bb = support.newBlitbuffer(20, 20)
        local painted, left, top, right, bottom =
            Render.segment(bb, -5000, 10, 5000, 10, 10000, 1)
        t:eq(painted, false, "unsafe raster work fails closed")
        t:eq(left, nil, "no partial coverage escapes")
        t:eq(top, nil, "no partial top")
        t:eq(right, nil, "no partial right")
        t:eq(bottom, nil, "no partial bottom")
        t:eq(#bb.rects, 0, "budget is checked before the first paintRect")
    end)

    t:case("persisted-style corrupt stroke width remains bounded on replay", function()
        local bb = support.newBlitbuffer(20, 20)
        local stroke = {
            n = 2, w = 1e9,
            -1e9, 10, 1e9, 10,
        }
        local painted = Render.stroke(bb, stroke, 0, 0, 1)
        t:eq(painted, false, "corrupt stored stroke fails closed")
        t:eq(#bb.rects, 0, "replay performs no partial raster work")
    end)

    t:case("huge offscreen segments do no raster work", function()
        local bb = support.newBlitbuffer(20, 20)
        local painted, left, top, right, bottom =
            Render.segment(bb, -1e9, -1e9, -1e9 + 100, -1e9, 3, 1)
        t:eq(painted, false, "fully outside")
        t:eq(left, nil, "no coverage")
        t:eq(top, nil, "no coverage")
        t:eq(right, nil, "no coverage")
        t:eq(bottom, nil, "no coverage")
        t:eq(#bb.rects, 0, "zero paintRect calls")
    end)

    t:case("a billion-pixel crossing costs only viewport-sized work", function()
        local bb = support.newBlitbuffer(20, 20)
        local painted, left, top, right, bottom =
            Render.segment(bb, -1e9, 10, 1e9, 10, 3, 1)
        t:eq(painted, true, "crossing paints")
        t:check(#bb.rects <= 30, "bounded calls (" .. #bb.rects .. ")")
        t:eq(left, 0, "coverage starts at viewport")
        t:eq(right, 20, "coverage ends at viewport")
        t:check(top >= 0 and bottom <= 20, "vertical coverage is bounded")
    end)

    t:case("fractional floor fringes at two edges are not clipped away", function()
        local got = support.newBlitbuffer(40, 30)
        local expected = support.newBlitbuffer(40, 30)
        local x0, y0 = -96.278377958461, 90.663645119164
        local x1, y1 = 47.424371445518, 32.824729986404
        local painted = Render.segment(got, x0, y0, x1, y1, 10, 1)
        reference(expected, x0, y0, x1, y1, 10, 1)
        t:eq(painted, true, "the three edge stamps remain visible")
        sameRects(got.rects, expected.rects, "fractional edge")
    end)

    t:case("non-finite arithmetic fails closed", function()
        local bb = support.newBlitbuffer(20, 20)
        t:eq(Render.segment(bb, -1e308, 10, 1e308, 10, 3, 1),
            false, "overflowing delta")
        t:eq(Render.segment(bb, math.huge, 10, 0, 10, 3, 1),
            false, "infinite endpoint")
        t:eq(Render.segment(bb, 1, 1, 2, 2, math.huge, 1),
            false, "infinite width")
        t:eq(Render.segment(bb, 1, 1, 2, 2, 0, 1),
            false, "zero width")
        t:eq(#bb.rects, 0, "no invalid input reached paintRect")
    end)
end
