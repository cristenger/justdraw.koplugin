return function(ctx)
    local t = ctx.t
    local Split = require("ink_stroke_split")

    t:describe("ink_stroke_split / distances")

    t:case("crossing segments measure zero", function()
        t:eq(Split.segmentSegmentDistance2(0, 0, 10, 10, 0, 10, 10, 0), 0,
            "a proper crossing touches")
    end)

    t:case("parallel segments measure the gap", function()
        t:eq(Split.segmentSegmentDistance2(0, 0, 10, 0, 0, 5, 10, 5), 25,
            "5 apart, squared")
    end)

    t:case("collinear overlap measures zero without a special case", function()
        t:eq(Split.segmentSegmentDistance2(0, 0, 10, 0, 4, 0, 6, 0), 0,
            "contained overlap")
        t:eq(Split.segmentSegmentDistance2(0, 0, 10, 0, -5, 0, 15, 0), 0,
            "containing overlap")
    end)

    t:case("a degenerate capsule is the point distance", function()
        local a = Split.segmentSegmentDistance2(0, 0, 10, 0, 5, 7, 5, 7)
        local b = Split.pointSegmentDistance2(5, 7, 0, 0, 10, 0)
        t:eq(a, b, "one sample erases as a circle")
        t:eq(b, 49, "which is the perpendicular")
    end)

    t:describe("ink_stroke_split / splitting")

    --- A horizontal 11-point stroke, x = 0..100 step 10, at y = 0.
    local function line()
        local p = {}
        for i = 0, 10 do p[#p + 1] = i * 10; p[#p + 1] = 0 end
        return p, 11
    end

    t:case("a middle cut leaves the two runs either side", function()
        local p, n = line()
        local fragments, removed = Split.splitByCapsule(p, n, 50, -5, 50, 5, 6, 0)
        t:eq(#fragments, 2, "two survivors")
        t:eq(fragments[1].first, 1, "head starts at the first point")
        t:eq(fragments[1].last, 5, "and ends before the cut")
        t:eq(fragments[2].first, 7, "tail resumes after the cut")
        t:eq(fragments[2].last, 11, "to the last point")
        t:eq(removed.min_x, 40, "removed box spans the dead segments")
        t:eq(removed.max_x, 60, "on both sides of the capsule")
    end)

    t:case("an end cut leaves one run", function()
        local p, n = line()
        local fragments = Split.splitByCapsule(p, n, 0, -5, 0, 5, 6, 0)
        t:eq(#fragments, 1, "one survivor")
        t:eq(fragments[1].first, 2, "the head is gone")
        t:eq(fragments[1].last, 11, "the rest stands")
    end)

    t:case("a cut through everything removes the whole stroke", function()
        local p, n = line()
        local fragments, removed = Split.splitByCapsule(p, n, 50, 0, 50, 0, 1000, 0)
        t:eq(#fragments, 0, "no survivors")
        t:eq(removed.min_x, 0, "the removed box is the stroke")
        t:eq(removed.max_x, 100, "end to end")
    end)

    t:case("a miss answers nil and does not invent a cut", function()
        local p, n = line()
        t:eq(Split.splitByCapsule(p, n, 50, 40, 50, 50, 6, 0), nil, "too far")
        t:eq(Split.capsuleHitsRange(p, 1, n, 50, 40, 50, 50, 36), false,
            "the gate agrees")
    end)

    t:case("a dot within reach goes whole; outside it stays", function()
        local p = { 30, 40 }
        local fragments, removed = Split.splitByCapsule(p, 1, 30, 38, 30, 42, 3, 0)
        t:eq(#fragments, 0, "a dot has no runs to keep")
        t:eq(removed.min_x, 30, "the removed box is the dot")
        t:eq(removed.max_y, 40, "exactly")
        t:eq(Split.splitByCapsule(p, 1, 100, 100, 100, 100, 3, 0), nil, "far dot untouched")
    end)

    t:case("a cut across a bend keeps both arms", function()
        -- A staple shape: up at x=10, across the top, down at x=20.
        local p = { 0, 0, 10, 0, 10, 10, 20, 10, 20, 0, 30, 0 }
        local fragments = Split.splitByCapsule(p, 6, 15, -5, 15, 15, 2, 0)
        t:eq(#fragments, 2, "the top rung is cut, both legs stand")
        t:eq(fragments[1].first, 1, "left leg from the start")
        t:eq(fragments[1].last, 3, "up to the rung")
        t:eq(fragments[2].first, 4, "right leg after the rung")
        t:eq(fragments[2].last, 6, "to the end")
    end)

    t:case("a sliver shorter than the nib is dirt, not ink", function()
        -- 3 points; cutting the long second segment leaves a 2-length stub.
        local p = { 0, 0, 2, 0, 100, 0 }
        local fragments, removed = Split.splitByCapsule(p, 3, 50, -5, 50, 5, 6, 5)
        t:eq(#fragments, 0, "the stub fell with the cut")
        t:eq(removed.min_x, 0, "and its points joined the removed box")
        t:eq(removed.max_x, 100, "with the dead segment's")
    end)
end
