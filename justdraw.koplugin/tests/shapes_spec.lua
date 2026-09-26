return function(ctx)
    local t = ctx.t
    local Shapes = require("ink_shapes")
    local Codec = require("ink_canvas_codec")

    local function mm(v) return v * 10 end   -- 10 px per mm in these cases

    local function gen(kind, size, angle, scale)
        return assert(Shapes.generate{ kind = kind, size = size or "M", angle = angle or 0,
            mm_to_px = mm, scale = scale or 1, width = 4, tool = 1 })
    end

    local function bbox(s)
        local p, n = s.strokes[1].points, s.strokes[1].n
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, n do
            x0 = math.min(x0, p[i * 2 - 1]); x1 = math.max(x1, p[i * 2 - 1])
            y0 = math.min(y0, p[i * 2]); y1 = math.max(y1, p[i * 2])
        end
        return x0, y0, x1, y1
    end

    t:describe("ink_shapes / geometry")

    t:case("every kind, size and allowed angle is one stroke with its longest side at the size", function()
        for _, kind in ipairs(Shapes.KINDS) do
            for _, size in ipairs(Shapes.SIZE_ORDER) do
                for _, angle in ipairs(Shapes.allowedAngles(kind) or { 0 }) do
                    local s = gen(kind, size, angle, 2)
                    local label = ("%s %s %d°"):format(kind, size, angle)
                    t:eq(#s.strokes, 1, label .. ": one stroke")
                    local x0, y0, x1, y1 = bbox(s)
                    t:check(math.abs(x0) < 1e-9 and math.abs(y0) < 1e-9, label .. ": corner at 0,0")
                    local want = mm(Shapes.SIZES[size]) / 2
                    t:check(math.abs(math.max(x1 - x0, y1 - y0) - want) < 1e-6,
                        label .. ": longest side " .. want .. " units")
                    t:check(math.abs(s.w - (x1 - x0)) < 1e-9 and math.abs(s.h - (y1 - y0)) < 1e-9,
                        label .. ": w and h are the real box")
                end
            end
        end
    end)

    t:case("closed shapes end where they begin; curves are bounded", function()
        for _, kind in ipairs({ "square", "rectangle", "circle", "ellipse", "triangle" }) do
            local s = gen(kind, "L")
            local p, n = s.strokes[1].points, s.strokes[1].n
            t:check(math.abs(p[1] - p[n * 2 - 1]) < 1e-9 and math.abs(p[2] - p[n * 2]) < 1e-9,
                kind .. " is closed")
        end
        local small = gen("circle", "S")
        t:check(small.strokes[1].n >= Shapes.CURVE_MIN + 1, "a small circle has at least 24 segments")
        local huge = assert(Shapes.generate{ kind = "circle", size = "L", mm_to_px = function(v) return v * 1000 end,
            scale = 1, width = 4, tool = 1 })
        t:check(huge.strokes[1].n <= Shapes.CURVE_MAX + 1, "and a huge one at most 360")
        local rect = gen("rectangle", "M")
        t:check(math.abs(rect.w / rect.h - 1.5) < 1e-9, "rectangle is 3:2")
        local ell = gen("ellipse", "M")
        t:check(math.abs(ell.w / ell.h - 1.5) < 0.01, "ellipse is 3:2")
        local tri = gen("triangle", "M")
        t:check(math.abs(tri.h / tri.w - 0.866) < 1e-9, "triangle height is 0.866 of its base")
    end)

    t:case("an arrow points the way its angle says, counter-clockwise on screen", function()
        local right = gen("arrow", "M", 0)
        local p = right.strokes[1].points
        t:check(p[3] > p[1], "0°: the tip is right of the tail")
        local up = gen("arrow", "M", 90)
        p = up.strokes[1].points
        t:check(p[4] < p[2], "90°: the tip is above the tail (screen y down)")
        local shape = gen("arrow", "M", 0).strokes[1]
        t:eq(shape.n, 5, "tail, tip, wing, tip, wing")
        t:eq(shape.points[3], shape.points[7], "the path returns to the tip between wings")
    end)

    t:case("options are validated and normalized", function()
        t:eq(select(2, Shapes.generate{ kind = "star", size = "M", mm_to_px = mm, scale = 1,
            width = 4, tool = 1 }), "bad_shape", "unknown kind")
        t:eq(select(2, Shapes.generate{ kind = "line", size = "M", angle = 30, mm_to_px = mm,
            scale = 1, width = 4, tool = 1 }), "bad_shape", "an angle the line does not offer")
        t:eq(select(2, Shapes.generate{ kind = "line", size = "M", angle = 0, mm_to_px = mm,
            scale = 0 / 0, width = 4, tool = 1 }), "bad_shape", "NaN scale")
        local n = Shapes.normalize{ kind = "circle", size = "XL", angle = 45 }
        t:eq(n.kind, "circle", "known kind kept")
        t:eq(n.size, "M", "unknown size is the default")
        t:eq(n.angle, 0, "a circle has no angle")
        t:eq(Shapes.normalize("garbage").kind, "line", "corrupt settings are the default")
        t:eq(Shapes.normalize{ kind = "arrow", angle = 225 }.angle, 225, "an arrow keeps a diagonal")
    end)

    t:case("a shape survives the codec within one quantum", function()
        local s = gen("ellipse", "L", 0, 0.5)
        local st = s.strokes[1]
        local moved = {}
        for i = 1, st.n * 2 do moved[i] = st.points[i] + 100 end
        local snapped = assert(Codec.snap(moved, st.n, 1860, 2480))
        local back = assert(Codec.join(Codec.encode(snapped, st.n, 1860, 2480), 1860, 2480))
        local worst = 0
        for i = 1, st.n * 2 do worst = math.max(worst, math.abs(back[i] - moved[i])) end
        t:check(worst <= 2480 / 65535, "every point within one quantisation step")
    end)
end
