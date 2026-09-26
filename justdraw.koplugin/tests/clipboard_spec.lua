return function(ctx)
    local t = ctx.t
    local Clipboard = require("ink_clipboard")

    local function stroke(x, y, width, seq, tool)
        return { points = { x, y, x + 10, y + 5 }, n = 2, width = width or 4,
            tool = tool or 1, paint_seq = seq }
    end

    t:describe("ink_clipboard / independence")

    t:case("set copies; payload copies again; nothing reaches back", function()
        Clipboard.clear()
        local src = { stroke(100, 200), stroke(150, 260) }
        t:eq(Clipboard.set(src, { scale = 2 }), true, "set")
        src[1].points[1] = 999
        local a = Clipboard.payload(2)
        t:eq(a.strokes[1].points[1], 0, "relative to the payload's corner, source mutation ignored")
        t:eq(a.w, 60, "width of the payload")
        a.strokes[1].points[1] = 7
        a.strokes[1].width = 70
        local b = Clipboard.payload(2)
        t:eq(b.strokes[1].points[1], 0, "a payload is a fresh copy")
        t:eq(b.strokes[1].width, 4, "every field")
        Clipboard.clear(); Clipboard.clear()
        t:eq(Clipboard.hasContent(), false, "cleared, twice")
    end)

    t:case("payload rescales to keep the copied on-screen size", function()
        Clipboard.set({ stroke(0, 0, 4) }, { scale = 2 })
        local p = Clipboard.payload(1)
        t:eq(p.strokes[1].points[3], 20, "twice the units at half the scale")
        t:eq(p.strokes[1].width, 8, "and twice the width")
        t:eq(select(2, Clipboard.payload(0)), "bad_scale", "zero scale refused")
        t:eq(select(2, Clipboard.payload(0 / 0)), "bad_scale", "NaN scale refused")
        Clipboard.clear()
    end)

    t:case("paint groups keep membership and order, not the old numbers", function()
        Clipboard.set({ stroke(0, 0, 4, 90), stroke(5, 0, 4, 12), stroke(9, 0, 4, 90) }, { scale = 1 })
        local p = Clipboard.payload(1)
        -- Handed out in paint order, whatever order they were gathered in,
        -- so a preview composes the way the commit stacks.
        t:eq(p.strokes[1].group, 1, "the earlier layer first")
        t:eq(p.strokes[1].points[1], 5 - 0, "which is the second stroke copied")
        t:eq(p.strokes[2].group, 2, "then the later layer")
        t:eq(p.strokes[3].group, 2, "fragments of one highlighter stay one group")
        t:eq(p.strokes[2].points[1], 0, "in their copied order")
        Clipboard.clear()
    end)

    t:case("bad input is refused and never replaces the content", function()
        Clipboard.set({ stroke(0, 0, 4) }, { scale = 1 })
        local cases = {
            { "no scale", { stroke(1, 1) }, {} },
            { "infinite scale", { stroke(1, 1) }, { scale = math.huge } },
            { "empty", {}, { scale = 1 } },
            { "NaN point", { { points = { 0 / 0, 1 }, n = 1, width = 4, tool = 1 } }, { scale = 1 } },
            { "count past points", { { points = { 1, 1 }, n = 2.5, width = 4, tool = 1 } }, { scale = 1 } },
            { "pressure misaligned", { { points = { 1, 1, 2, 2 }, n = 2, width = 4, tool = 1,
                pressure = { 1 } } }, { scale = 1 } },
        }
        for _, c in ipairs(cases) do
            local ok, err = Clipboard.set(c[2], c[3])
            t:eq(ok, nil, c[1] .. " refused")
            t:check(err ~= nil, c[1] .. " named")
        end
        t:eq(Clipboard.payload(1).strokes[1].points[3], 10, "the previous content is intact")
        local big = {}
        for i = 1, Clipboard.MAX_STROKES + 1 do big[i] = stroke(i, i) end
        t:eq(select(2, Clipboard.set(big, { scale = 1 })), "too_large", "over the stroke cap")
        Clipboard.clear()
    end)

    t:case("pressure travels with the points", function()
        Clipboard.set({ { points = { 1, 1, 2, 2 }, n = 2, width = 4, tool = 1,
            pressure = { 10, 200 } } }, { scale = 1 })
        local p = Clipboard.payload(1)
        t:eq(p.strokes[1].pressure[2], 200, "copied")
        p.strokes[1].pressure[2] = 0
        t:eq(Clipboard.payload(1).strokes[1].pressure[2], 200, "and independent")
        Clipboard.clear()
    end)
end
