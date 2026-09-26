return function(ctx)
    local t = ctx.t
    local Lasso = require("ink_lasso")

    local SQUARE = { 0, 0, 100, 0, 100, 100, 0, 100 }

    local function line(x0, y0, x1, y1, n)
        local pts = {}
        n = n or 2
        for i = 0, n - 1 do
            local f = n == 1 and 0 or i / (n - 1)
            pts[#pts + 1] = x0 + (x1 - x0) * f
            pts[#pts + 1] = y0 + (y1 - y0) * f
        end
        return pts, n
    end

    t:describe("ink_lasso / inside")

    t:case("even-odd, with edges and vertices inside", function()
        t:eq(Lasso.inside(SQUARE, 4, 50, 50), true, "centre")
        t:eq(Lasso.inside(SQUARE, 4, 150, 50), false, "outside")
        t:eq(Lasso.inside(SQUARE, 4, 100, 50), true, "on the right edge")
        t:eq(Lasso.inside(SQUARE, 4, 0, 0), true, "on a vertex")
        t:eq(Lasso.inside(SQUARE, 4, 50, 0), true, "on a horizontal edge")
        -- A bow tie: the crossing region is even-odd, both lobes inside.
        local bow = { 0, 0, 100, 100, 100, 0, 0, 100 }
        t:eq(Lasso.inside(bow, 4, 10, 50), true, "left lobe")
        t:eq(Lasso.inside(bow, 4, 90, 50), true, "right lobe")
        t:eq(Lasso.inside(bow, 4, 50, 10), false, "between the lobes is outside")
        -- Concave: a U shape.
        local u = { 0, 0, 30, 0, 30, 70, 70, 70, 70, 0, 100, 0, 100, 100, 0, 100 }
        t:eq(Lasso.inside(u, 8, 50, 30), false, "inside the U's notch is outside")
        t:eq(Lasso.inside(u, 8, 15, 30), true, "the U's arm is inside")
    end)

    t:describe("ink_lasso / length-weighted coverage")

    t:case("a point stroke and a zero-length stroke are their one point", function()
        local f, k = Lasso.coverage(SQUARE, 4, { 50, 50 }, 1, 1)
        t:eq(f, 1, "inside"); t:eq(k, 1, "one sample")
        f = Lasso.coverage(SQUARE, 4, { 150, 50, 150, 50, 150, 50 }, 3, 1)
        t:eq(f, 0, "coincident points outside")
    end)

    t:case("49, 50 and 51 percent inside, far from the sampling error", function()
        for _, c in ipairs({ { 49, false }, { 50, true }, { 51, true } }) do
            -- A horizontal stroke of length 1000 with c% of it inside x<=2000.
            local wide = { 0, 0, 2000, 0, 2000, 100, 0, 100 }
            local inside_len = c[1] * 10
            local pts = { 2000 - inside_len, 50, 2000 - inside_len + 1000, 50 }
            local f = Lasso.coverage(wide, 4, pts, 2, 1, 512)
            t:check(math.abs(f - c[1] / 100) <= 1 / 512 + 1e-9,
                c[1] .. "%: fraction " .. f)
            t:eq(Lasso.selects(f), c[2], c[1] .. "% selects: " .. tostring(c[2]))
        end
    end)

    t:case("uneven point spacing does not change the answer", function()
        -- Same geometry, once as 2 points, once as 8192 tiny segments bunched
        -- at the outside end: a per-point or per-segment test would flip.
        local sparse = { -30, 50, 70, 50 }
        local dense = {}
        for i = 0, 8190 do dense[#dense + 1] = -30 + i * 0.001; dense[#dense + 1] = 50 end
        dense[#dense + 1] = 70; dense[#dense + 1] = 50
        local fs = Lasso.coverage(SQUARE, 4, sparse, 2, 0.5)
        local fd, kd = Lasso.coverage(SQUARE, 4, dense, #dense / 2, 0.5)
        t:check(math.abs(fs - fd) < 0.01, ("resampling agrees: %.4f vs %.4f"):format(fs, fd))
        t:check(kd <= Lasso.MAX_SAMPLES, "never more than 512 samples for the whole stroke")
        t:eq(Lasso.selects(fd), true, "70% inside is selected")
    end)

    t:case("zero-length segments are skipped, not sampled", function()
        local pts = { 10, 50, 10, 50, 10, 50, 90, 50, 90, 50 }
        local f, k = Lasso.coverage(SQUARE, 4, pts, 5, 1)
        t:eq(f, 1, "all inside"); t:eq(k, 80, "k from the real length")
    end)

    t:describe("ink_lasso / path and simplification")

    t:case("the path buffer is sized once and refuses past capacity", function()
        local path = Lasso.newPath(4, 3)
        t:eq(path:add(0, 0), true, "first")
        t:eq(path:add(1, 1), false, "too close, skipped")
        t:eq(path:add(10, 0), true, "second")
        path:add(10, 10); path:add(0, 10)
        local ok, err = path:add(-10, -10)
        t:eq(ok, nil, "a fifth point is refused")
        t:eq(err, "full", "because the path is full")
        t:eq(path.n, 4, "and the path kept its shape: no vertex replaced")
        t:eq(path:add(0 / 0, 1), nil, "NaN refused")
        t:eq(path:isTap(2), false, "a 10x10 path is a lasso")
        path:reset()
        path:add(0, 0); path:add(1, 0); path:add(1, 1)
        t:eq(path:isTap(2), true, "under 2 units is a tap")
    end)

    t:case("simplification keeps within tolerance or refuses", function()
        local xy, n = {}, 0
        for i = 0, 999 do
            local a = i / 1000 * 2 * math.pi
            n = n + 1
            xy[n * 2 - 1], xy[n * 2] = 500 + 400 * math.cos(a), 500 + 400 * math.sin(a)
        end
        local out, m = Lasso.simplify(xy, n, 1, 256)
        t:check(out ~= nil and m <= 256, "a circle fits in 256 vertices at 1 unit")
        local worst = 0
        for i = 1, n do
            local best = math.huge
            for j = 1, m - 1 do
                local d = Lasso.segmentDistance2(xy[i * 2 - 1], xy[i * 2],
                    out[j * 2 - 1], out[j * 2], out[j * 2 + 1], out[j * 2 + 2])
                if d < best then best = d end
            end
            if best > worst then worst = best end
        end
        t:check(math.sqrt(worst) <= 1 + 1e-9, "every dropped vertex within 1 unit")
        -- A zig-zag with 600 sharp corners cannot fit 256 vertices at 1 unit.
        local zig = {}
        for i = 0, 599 do zig[#zig + 1] = i * 2; zig[#zig + 1] = (i % 2) * 50 end
        local refused, err = Lasso.simplify(zig, 600, 1, 256)
        t:eq(refused, nil, "too complex refused")
        t:eq(err, "too_complex", "named")
    end)

    t:case("a narrow spike survives simplification", function()
        local spike = { 0, 0, 100, 0, 50, 0.5, 51, 80, 52, 0.5, 100, 0.1, 100, 100, 0, 100 }
        local out, m = Lasso.simplify(spike, 8, 1, 256)
        local has_tip = false
        for i = 1, m do if out[i * 2] == 80 then has_tip = true end end
        t:check(has_tip, "the spike's tip is kept")
    end)

    t:describe("ink_lasso / budget")

    t:case("coverage cost is bounded by the sample cap, not the point count", function()
        local pts = {}
        for i = 0, 8191 do pts[#pts + 1] = (i % 200); pts[#pts + 1] = 50 + (i % 7) end
        local poly = {}
        for i = 0, 255 do
            local a = i / 256 * 2 * math.pi
            poly[#poly + 1] = 100 + 90 * math.cos(a); poly[#poly + 1] = 50 + 90 * math.sin(a)
        end
        local calls = 0
        local real = Lasso.inside
        Lasso.inside = function(...) calls = calls + 1; return real(...) end
        local _, k = Lasso.coverage(poly, 256, pts, 8192, 0.01)
        Lasso.inside = real
        t:eq(k, 512, "capped at 512 samples")
        t:eq(calls, 512, "exactly one inside test per sample")
    end)
end
