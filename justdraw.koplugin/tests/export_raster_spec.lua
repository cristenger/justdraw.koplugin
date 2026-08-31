--[[--
The off-screen raster an export owns, and the two things that make it safe.

The first is arithmetic: a page must land at the resolution it claims, and no
page may allocate more than the budget however it is shaped. Both are stated
as numbers here, because "300 dpi" and "8 megapixels" are the promises the
memory footprint rests on, and a silent change to either is invisible until a
device runs out.

The second is timing. `InkCanvasCache` reschedules itself between batches and
signals from inside its own loop, so an export that continued from that
callback would be running file writes underneath the cache's stack -- and, if
it closed the cache there, freeing the buffer the loop was about to touch.
Several cases below assert only that *nothing happened yet*: the raster must
still be unsettled when `open` returns, whether it succeeded or failed, and
whether it had strokes to replay or none at all.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Raster = require("ink_export_raster")

    local A5 = { id = 1, logical_w = 1184, logical_h = 1680,
        template_kind = "blank" }
    local LETTER = { id = 2, logical_w = 1727, logical_h = 2235,
        template_kind = "blank" }
    local UNITS_PER_MM = 8

    local function fixture(opts)
        opts = opts or {}
        local surface = opts.surface or A5
        local store = support.newCanvasStore({ surface })
        for _, s in ipairs(opts.strokes or {}) do
            store:putStroke(surface.id, s)
        end
        if opts.fail_stroke_list then
            store.fail_stroke_list = opts.fail_stroke_list
        end
        local sched = support.newScheduler()
        local seen = { ready = 0, error = 0, arg = nil, reason = nil, extra = "unset" }
        local job, err = Raster.open{
            repository = store,
            surface = surface,
            scale = opts.scale or 1,
            paper_kind = opts.paper_kind,
            schedule = function(fn) sched:schedule(fn) end,
            on_ready = function(...)
                seen.ready = seen.ready + 1
                local args = { ... }
                seen.arg = args[1]
                seen.count = select("#", ...)
            end,
            on_error = function(reason, from)
                seen.error = seen.error + 1
                seen.reason = reason
                seen.arg = from
            end,
        }
        return job, seen, sched, store, err
    end

    local function bar(x, y, n)
        local points = {}
        for i = 0, (n or 4) - 1 do
            points[#points + 1] = x + i * 10
            points[#points + 1] = y
        end
        return { width = 4, tool = 1, points = points, n = n or 4 }
    end

    -- =================================================================
    t:describe("export / raster / scale policy")

    t:case("a notebook page renders at a real 300 dots per inch", function()
        local scale = Raster.physicalScale(UNITS_PER_MM, 300)
        t:check(math.abs(scale - (300 / 25.4) / 8) < 1e-12, "pixels per unit")
        local bounded = Raster.boundedScale(A5.logical_w, A5.logical_h, scale)
        t:eq(bounded, scale, "A5 is inside the budget, so nothing is given up")
        local job, _, sched = fixture{ scale = bounded }
        sched:drain()
        local w, h = job:size()
        t:eq(w, 1748, "A5 width in pixels")
        t:eq(h, 2480, "A5 height in pixels")
        job:close()
    end)

    t:case("a page over the budget is reduced, by area and not by one axis", function()
        local target = Raster.physicalScale(UNITS_PER_MM, 300)
        local bounded = Raster.boundedScale(LETTER.logical_w, LETTER.logical_h, target)
        t:check(bounded < target, "the target was not affordable")
        local job, _, sched = fixture{ surface = LETTER, scale = bounded }
        sched:drain()
        local w, h = job:size()
        t:check(w * h <= Raster.MAX_PIXELS,
            string.format("%dx%d = %d is within the budget", w, h, w * h))
        t:check(w * h > Raster.MAX_PIXELS * 0.95,
            "and the reduction was no larger than it had to be")
        job:close()
    end)

    t:case("a tall page is bounded too, which a width-only limit would miss", function()
        local tall = { id = 3, logical_w = 400, logical_h = 40000 }
        local bounded = Raster.boundedScale(tall.logical_w, tall.logical_h, 4)
        t:check(bounded < 4, "reduced")
        local job, _, sched = fixture{ surface = tall, scale = bounded }
        sched:drain()
        local w, h = job:size()
        t:check(w * h <= Raster.MAX_PIXELS, "within budget")
        job:close()
    end)

    t:case("physical and nominal page sizes are computed from what is known", function()
        local w_pt = Raster.physicalPoints(UNITS_PER_MM, A5.logical_w)
        local h_pt = Raster.physicalPoints(UNITS_PER_MM, A5.logical_h)
        -- A5 is 148 x 210 mm.
        t:check(math.abs(w_pt - 419.527) < 0.01, "A5 width in points")
        t:check(math.abs(h_pt - 595.276) < 0.01, "A5 height in points")
        t:check(math.abs(Raster.nominalPoints(1860, 300) - 446.4) < 0.001,
            "a pixel surface at the nominal DPI")
    end)

    t:case("nonsense geometry is refused rather than scaled", function()
        t:check(Raster.physicalScale(0, 300) == nil, "zero units per mm")
        t:check(Raster.physicalScale(8, 0) == nil, "zero dpi")
        t:eq(select(2, Raster.boundedScale(0, 100, 1)), "bad_geometry", "zero width")
        t:eq(select(2, Raster.boundedScale(100, 100, 0)), "bad_geometry", "zero scale")
        t:eq(select(2, Raster.boundedScale(100, 100, 1, 0)), "bad_geometry",
            "zero budget")
    end)

    -- =================================================================
    t:describe("export / raster / lifecycle")

    t:case("open never settles inside its own call, with strokes or without", function()
        local empty, seen_empty, sched_empty = fixture{}
        t:eq(seen_empty.ready, 0, "an empty page has not signalled yet")
        t:check(sched_empty:pending() > 0, "it left work on the scheduler")
        sched_empty:drain()
        t:eq(seen_empty.ready, 1, "and signals once it is drained")
        empty:close()

        local drawn, seen_drawn, sched_drawn = fixture{ strokes = { bar(10, 10) } }
        t:eq(seen_drawn.ready, 0, "a page with ink has not signalled either")
        sched_drawn:drain()
        t:eq(seen_drawn.ready, 1, "and then signals once")
        drawn:close()
    end)

    t:case("a synchronous failure is still delivered on a later tick", function()
        local job, seen, sched = fixture{ fail_stroke_list = "disk gone" }
        t:eq(seen.error, 0, "not reported from inside open")
        t:check(job ~= nil, "a job is still returned to be closed")
        sched:drain()
        t:eq(seen.error, 1, "reported once")
        t:eq(seen.reason, "disk gone", "with the repository's reason")
        t:eq(seen.arg, job, "and the job it belongs to")
        t:check(job:failure() ~= nil, "the job knows it failed")
        t:check(job:buffer() == nil, "and offers no buffer")
        job:close()
    end)

    t:case("readiness hands back the job, because the cache signals with nothing", function()
        local job, seen, sched = fixture{}
        sched:drain()
        t:eq(seen.count, 1, "one argument")
        t:eq(seen.arg, job, "and it is the job")
        t:check(job:isReady(), "which is ready")
        t:check(job:buffer() ~= nil, "and holds the raster")
    end)

    t:case("the buffer lives until close, and close is idempotent", function()
        local job, _, sched = fixture{}
        sched:drain()
        local bb = job:buffer()
        t:check(bb ~= nil, "buffer available while open")
        t:eq(bb.freed, false, "and not freed yet")
        job:close()
        t:eq(bb.freed, true, "close frees it")
        t:check(job:buffer() == nil, "and it is no longer offered")
        t:check(job:close(), "a second close is harmless")
    end)

    t:case("a job closed before it settles delivers nothing at all", function()
        local job, seen, sched = fixture{ strokes = { bar(10, 10) } }
        job:close()
        sched:drain()
        t:eq(seen.ready, 0, "no readiness after close")
        t:eq(seen.error, 0, "and no error either")
    end)

    t:case("the raster is the whole surface, at the scale it was given", function()
        local job, _, sched = fixture{ scale = 2 }
        sched:drain()
        local w, h = job:size()
        t:eq(w, A5.logical_w * 2, "width")
        t:eq(h, A5.logical_h * 2, "height")
        local bb = job:buffer()
        t:eq(bb:getWidth(), w, "the buffer agrees about width")
        t:eq(bb:getHeight(), h, "and about height")
        t:eq(job:transform().scale, 2, "and so does the transform")
        job:close()
    end)

    t:case("roundedPixels is what the cache actually allocates", function()
        --[[--
        The one non-circular statement about the forecast.

        `Export.forecast` counts pixels with `Raster.roundedPixels`, and a test
        that checked that against `roundedPixels` would prove nothing. This
        opens a real raster at an awkward scale and asks the cache how big it
        came out: if the two ever disagree, the number quoted to the reader
        stops describing the buffer that gets reserved.
        ]]
        local scale = 0.7331
        local job, _, sched = fixture{ scale = scale }
        sched:drain()
        local w, h = job:size()
        local pixels, want_w, want_h =
            Raster.roundedPixels(A5.logical_w, A5.logical_h, scale)
        t:eq(w, want_w, "width")
        t:eq(h, want_h, "height")
        t:eq(pixels, w * h, "and the product the forecast uses is the allocation")
        job:close()
    end)

    t:case("a bad request is refused before a cache exists", function()
        local sched = support.newScheduler()
        local base = { repository = support.newCanvasStore({ A5 }), surface = A5,
            scale = 1, schedule = function(fn) sched:schedule(fn) end }
        local function without(key, value)
            local opts = {}
            for k, v in pairs(base) do opts[k] = v end
            opts[key] = value
            return select(2, Raster.open(opts))
        end
        t:eq(without("surface", { id = 1 }), "bad_surface", "no geometry")
        t:eq(without("surface", nil), "bad_surface", "no surface")
        t:eq(without("repository", nil), "no_repository", "no repository")
        t:eq(without("schedule", nil), "no_scheduler", "no scheduler")
        t:eq(without("scale", 0), "bad_geometry", "zero scale")
        t:eq(without("scale", -1), "bad_geometry", "negative scale")
        t:eq(sched:pending(), 0, "and none of them queued any work")
    end)

    -- =================================================================
    t:describe("export / raster / paper")

    t:case("a notebook page carries its ruling into the exported raster", function()
        local ruled = { id = 4, logical_w = 400, logical_h = 600,
            template_kind = "ruled" }
        local job, _, sched = fixture{ surface = ruled, scale = 1 }
        sched:drain()
        local bb = job:buffer()
        -- The background fill is itself one recorded rectangle; anything past
        -- that is the ruling, composed into the raster rather than under it.
        t:check(#bb.rects > 1, "the page was ruled")
        job:close()
    end)

    t:case("an EPUB sheet has no ruling to carry, and gets none", function()
        local canvas = { id = 5, logical_w = 400, logical_h = 600 }
        local job, _, sched = fixture{ surface = canvas, scale = 1 }
        sched:drain()
        local bb = job:buffer()
        t:eq(#bb.rects, 1, "only the background")
        job:close()
    end)

    t:case("ink drawn on the page reaches the raster", function()
        local job, _, sched = fixture{ strokes = { bar(10, 10, 4) } }
        sched:drain()
        local bb = job:buffer()
        t:check(#bb.rects > 1, "the stroke painted something")
        job:close()
    end)
end
