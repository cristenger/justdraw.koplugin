--[[--
The raster cache: the reason painting a canvas costs the same whether it holds
one stroke or five thousand.

Almost every case here is a *counter*, not a pixel. The claims that matter are
about work that must not happen -- a repaint that decodes no points, an erase
that reads only what is nearby, a sheet dragged to a new height that
re-rasterises nothing -- and the only honest way to state those is to count the
calls and watch them stay still.

The one pixel-level claim is clipping, and it is checked against a blitbuffer
fake that bounds writes the way the real one does, so "nothing was painted
outside the sheet" means the write was dropped rather than merely recorded
somewhere tidy.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Cache = require("ink_canvas_cache")
    local Paper = require("ink_paper")
    local Transform = require("ink_canvas_transform")

    local W, H = 1860, 2480
    local CANVAS = { id = 1, logical_w = W, logical_h = H }

    local function transform(sheet_top, screen_w, screen_h)
        return Transform.new{
            logical_w = W, logical_h = H,
            screen_w = screen_w or W, screen_h = screen_h or H,
            sheet_top = sheet_top or 0,
        }
    end

    --- A short horizontal stroke of `n` points starting at (x, y).
    local function bar(x, y, n, width)
        local points = {}
        for i = 0, (n or 4) - 1 do
            points[#points + 1] = x + i * 10
            points[#points + 1] = y
        end
        return { width = width or 4, tool = 1, points = points, n = n or 4 }
    end

    --- opts.strokes: array of stroke tables to preload. opts.batch, opts.cell,
    --- opts.sheet_top.
    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore({ CANVAS })
        for _, s in ipairs(opts.strokes or {}) do
            store:putStroke(CANVAS.id, s)
        end
        local sched = support.newScheduler()
        local cache = Cache.new{
            repository = store,
            canvas = CANVAS,
            transform = transform(opts.sheet_top),
            batch = opts.batch or 32,
            point_budget = opts.point_budget,
            cell = opts.cell or 100,
            paper_kind = opts.paper_kind,
            schedule = function(fn) sched:schedule(fn) end,
        }
        return cache, store, sched
    end

    -- =================================================================
    t:describe("ink_canvas_cache / building")

    t:case("opening reads stroke metadata and not one point", function()
        local cache, store = fixture{ strokes = { bar(10, 10), bar(500, 500) } }
        cache:open()
        t:eq(store.calls.stroke_list, 1, "the metadata query ran")
        t:eq(store.calls.stroke_read, 0, "and nothing was decoded yet")
        t:eq(cache:isReady(), false, "so the canvas is not ready to edit")
    end)

    t:case("rasterisation happens in bounded batches", function()
        local strokes = {}
        for i = 1, 5 do strokes[i] = bar(i * 100, i * 100) end
        local cache, store, sched = fixture{ strokes = strokes, batch = 2 }
        cache:open()
        sched:tick()
        t:eq(store.calls.stroke_read, 2, "one batch")
        sched:tick()
        t:eq(store.calls.stroke_read, 4, "another")
        t:eq(cache:isReady(), false, "still building")
        sched:drain()
        t:eq(store.calls.stroke_read, 5, "and then every stroke, once each")
        t:eq(cache:isReady(), true, "ready")
    end)

    t:case("one enormous stroke is bounded by points, not counted as one unit", function()
        local cache, store, sched = fixture{
            strokes = { bar(10, 10, 5000) },
            point_budget = 1024,
        }
        cache:open()
        sched:tick()
        t:eq(store.calls.stroke_chunk, 1, "one bounded chunk in the first tick")
        t:eq(cache:isReady(), false, "the rest stays scheduled")
        sched:drain()
        t:eq(cache:isReady(), true, "eventually complete")
        t:check(store.calls.stroke_chunk > 1, "the stroke really was streamed")
    end)

    t:case("a read error fails closed instead of producing an empty ready sheet", function()
        local cache, store, sched = fixture{ strokes = { bar(10, 10) } }
        store.fail_stroke_chunk = 0
        cache:open()
        sched:drain()
        t:eq(cache:isReady(), false, "not editable")
        t:eq(cache:stateName(), "load_failed", "the error remains visible")
        t:check(cache:loadError() ~= nil, "with a retryable reason")
        local dest = support.newBlitbuffer(W, H)
        cache:paintTo(dest)
        t:eq(#dest.blits, 0, "a partial raster is not presented as complete ink")
    end)

    t:case("scheduler batches use keyed reads rather than retained cursors", function()
        local cache, store, sched = fixture{ strokes = { bar(10, 10) } }
        store.openStrokeCursor = function() error("cache retained a cursor", 0) end
        cache:open()
        sched:drain()
        t:eq(cache:stateName(), "ready", "keyed statement closed in its call")
        t:eq(cache:isReady(), true, "no cursor survived a scheduler turn")
    end)

    t:case("corrupt stroke metadata fails closed before reaching the grid", function()
        local cache, store = fixture()
        function store:listStrokes()
            return { {
                id = 1, seq = 1, width = 4, tool = 1, codec = 1,
                point_count = 2, min_x = 100, min_y = 100,
                max_x = 0 / 0, max_y = 100,
            } }
        end
        local ok, err = cache:open()
        t:eq(ok, nil, "the sheet did not open")
        t:eq(err, "stroke_metadata", "with a stable metadata reason")
        t:eq(cache:stateName(), "load_failed", "not as an empty ready sheet")
    end)

    t:case("an empty canvas is ready straight away", function()
        local cache, store = fixture()
        cache:open()
        t:eq(cache:isReady(), true, "nothing to rasterise")
        t:eq(store.calls.stroke_read, 0, "and nothing read")
    end)

    t:case("the buffer is the whole transformed canvas, not the visible sheet", function()
        local cache = fixture{ sheet_top = math.floor(H * 0.6) }
        cache:open()
        local bb = cache:buffer()
        t:eq(bb.w, W, "full width")
        t:eq(bb.h, H, "full height, so dragging the sheet re-rasterises nothing")
    end)

    t:case("the buffer starts filled, so an empty canvas is a blank page", function()
        local cache = fixture()
        cache:open()
        t:eq(#cache:buffer().fills, 1, "filled once, with the background")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / painting")

    local function readyCache(opts)
        local cache, store, sched = fixture(opts)
        cache:open()
        sched:drain()
        return cache, store, sched
    end

    t:case("painting is a blit, not a walk over the strokes", function()
        local cache, store = readyCache{ strokes = { bar(10, 10), bar(300, 300) } }
        local reads = store.calls.stroke_read
        local dest = support.newBlitbuffer(W, H)
        cache:paintTo(dest)
        t:eq(#dest.blits, 1, "one blit")
        t:eq(#dest.rects, 0, "and not a single rectangle painted")
        t:eq(store.calls.stroke_read, reads, "nothing decoded")
    end)

    t:case("ten repaints decode nothing and query nothing", function()
        local cache, store = readyCache{ strokes = { bar(10, 10), bar(300, 300) } }
        local reads, lists = store.calls.stroke_read, store.calls.stroke_list
        local dest = support.newBlitbuffer(W, H)
        for _ = 1, 10 do cache:paintTo(dest) end
        t:eq(store.calls.stroke_read, reads, "no points decoded")
        t:eq(store.calls.stroke_list, lists, "no query issued")
        t:eq(#dest.blits, 10, "just ten blits")
    end)

    t:case("only the visible part of the canvas reaches the screen", function()
        local top = math.floor(H * 0.6)
        local cache = readyCache{ strokes = { bar(10, 10) }, sheet_top = top }
        local dest = support.newBlitbuffer(W, H)
        cache:paintTo(dest)
        local blit = dest.blits[1]
        t:eq(blit.dest_y, top, "landing at the top of the sheet")
        t:eq(blit.h, H - top, "and only as tall as the sheet")
        t:eq(blit.offs_y, 0, "showing the canvas from its first row down")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / editing")

    t:case("a finished stroke goes into the cache without being read back", function()
        local cache, store = readyCache()
        local reads = store.calls.stroke_read
        cache:buffer():clear()
        local s = bar(100, 100)
        cache:addStroke({ id = 99, seq = 1, width = 4, tool = 1,
                          point_count = s.n, min_x = 100, min_y = 100,
                          max_x = 130, max_y = 100 }, s.points, s.n)
        t:eq(store.calls.stroke_read, reads, "the points are already in hand")
        t:check(#cache:buffer().rects > 0, "and it was painted")
    end)

    t:case("replay colors a stroke by its tool", function()
        local cache = readyCache()
        cache:buffer():clear()
        local s = bar(100, 100)
        cache:addStroke({ id = 99, seq = 1, width = 4, tool = 3,
                          point_count = s.n, min_x = 100, min_y = 100,
                          max_x = 130, max_y = 100 }, s.points, s.n)
        local rects = cache:buffer().rects
        t:check(#rects > 0, "the stroke was painted")
        t:eq(rects[#rects].c, "light_gray", "with the marker's color")
    end)

    t:case("drawSegment takes an explicit color and defaults to ink", function()
        local cache = readyCache()
        cache:buffer():clear()
        cache:drawSegment(100, 100, 100, 100, 4, "gray_6")
        local rects = cache:buffer().rects
        t:eq(rects[#rects].c, "gray_6", "the explicit color wins")
        cache:drawSegment(200, 100, 200, 100, 4)
        local rects2 = cache:buffer().rects
        t:eq(rects2[#rects2].c, "black", "and nil defaults to the cache's own ink")
    end)

    t:case("the cache knows when its raster holds gray ink", function()
        -- The fast refresh is forced monochrome on device, so every box
        -- refresh that could cover gray ink must ride a grayscale pass
        -- instead (ADR-36). The flag is monotone within a build -- erasing
        -- the last gray stroke leaves it set, which fails toward correctness.
        local cache = readyCache()
        t:eq(cache:hasGrayInk(), false, "a fresh sheet holds none")
        cache:drawSegment(100, 100, 110, 100, 4)
        t:eq(cache:hasGrayInk(), false, "ink-colored segments leave it unset")
        cache:drawSegment(120, 100, 130, 100, 4, "gray_6")
        t:eq(cache:hasGrayInk(), true, "a live graphite segment sets it")

        local by_meta = readyCache()
        local s = bar(100, 100)
        by_meta:addStroke({ id = 99, seq = 1, width = 4, tool = 65,
                            point_count = s.n, min_x = 100, min_y = 100,
                            max_x = 130, max_y = 100 }, s.points, s.n)
        t:eq(by_meta:hasGrayInk(), true, "a graphite stroke meta sets it")

        local graphite = bar(200, 200)
        graphite.tool = 65
        local replayed = readyCache{ strokes = { bar(10, 10), graphite } }
        t:eq(replayed:hasGrayInk(), true, "a persisted graphite stroke sets it on build")

        local pen_only = readyCache{ strokes = { bar(10, 10), bar(300, 300) } }
        t:eq(pen_only:hasGrayInk(), false, "a pen-only sheet keeps the fast path")
    end)

    t:case("a matching complete live token registers without repainting", function()
        local cache = readyCache()
        local bb = cache:buffer()
        bb:clear()
        local _, raster_cache, raster_generation =
            cache:drawSegment(100, 100, 100, 100, 4)
        local before = #bb.rects
        local ok, err, painted, left, top, right, bottom = cache:addStroke({
            id = -1, seq = 1, width = 4, tool = 1, point_count = 1,
            min_x = 100, min_y = 100, max_x = 100, max_y = 100,
        }, { 100, 100 }, 1, {
            raster_cache = raster_cache,
            raster_generation = raster_generation,
            live_raster_complete = true,
        })
        t:eq(ok, true, "metadata accepted")
        t:eq(err, nil, "without an error")
        t:eq(painted, false, "no fallback rasterisation")
        t:eq(left, nil, "no dirty coverage")
        t:eq(top, nil, "no dirty coverage")
        t:eq(right, nil, "no dirty coverage")
        t:eq(bottom, nil, "no dirty coverage")
        t:eq(#bb.rects, before, "the dot is not painted twice")
        t:eq(cache:strokes()[1].id, -1, "temporary metadata was registered")
        t:check(cache:hitTest(100, 100, 2) ~= nil, "grid/live chunks were indexed")
    end)

    t:case("a generation mismatch falls back once and reports cache coverage", function()
        local cache = readyCache()
        local bb = cache:buffer()
        bb:clear()
        local stale_generation = cache.generation - 1
        local before = #bb.rects
        local ok, err, painted, left, top, right, bottom = cache:addStroke({
            id = -1, seq = 1, width = 4, tool = 1, point_count = 2,
            min_x = 100, min_y = 100, max_x = 110, max_y = 100,
        }, { 100, 100, 110, 100 }, 2, {
            raster_cache = cache,
            raster_generation = stale_generation,
            live_raster_complete = true,
        })
        t:eq(ok, true, "metadata accepted")
        t:eq(err, nil, "without an error")
        t:eq(painted, true, "fallback rasterisation occurred")
        t:check(#bb.rects > before, "the whole stroke was painted once")
        t:check(left >= 0 and top >= 0, "coverage is clipped to the cache")
        t:check(right > left and bottom > top, "coverage is positive half-open")
        t:check(right <= bb:getWidth() and bottom <= bb:getHeight(),
            "coverage cannot escape the cache")
    end)

    t:case("a pending stroke is hit and repaired without a negative SQLite read", function()
        local cache, store = readyCache()
        local s = bar(100, 100)
        cache:addStroke({ id = -1, seq = 1, width = 4, tool = 1,
                          point_count = s.n, min_x = 100, min_y = 100,
                          max_x = 130, max_y = 100 }, s.points, s.n)
        local reads = store.calls.stroke_read
        t:eq(cache:hitTest(115, 100, 2).id, -1, "the live metadata is found")
        t:eq(store.calls.stroke_read, reads, "without repository access")
        t:eq(cache:markPersisted(-1, 77), true, "durable id adopted")
        t:eq(cache:strokes()[1].id, 77, "the public cache key changed")
        t:eq(cache:removeStroke(77) ~= nil, true, "grid and by_id were rekeyed")
    end)

    t:case("pending repair visits nearby chunks, not every live point", function()
        local cache, store = readyCache()
        local points = {}
        for i = 1, 5000 do
            points[#points + 1] = i / 10
            points[#points + 1] = 100
        end
        cache:addStroke({
            id = -1, seq = 1, width = 2, tool = 1, point_count = 5000,
            min_x = 0.1, min_y = 100, max_x = 500, max_y = 100,
        }, points, 5000)
        local reads = store.calls.stroke_read
        local before = #cache:buffer().rects
        cache:repair{ min_x = 450, min_y = 99, max_x = 451, max_y = 101, width = 2 }
        local painted = #cache:buffer().rects - before
        t:eq(store.calls.stroke_read, reads, "pending repair uses live memory")
        t:check(painted < 1500, "only a bounded chunk was replayed (" .. painted .. ")")
    end)

    t:case("erasing repaints only its own corner of the canvas", function()
        local cache = readyCache{
            strokes = { bar(100, 100), bar(1500, 2000) },
            cell = 100,
        }
        local target = cache:strokes()[1]
        local bb = cache:buffer()
        bb:clear()
        local box = cache:removeStroke(target.id)
        t:check(box ~= nil, "the erase reports the region it touched")
        t:check(box.w < W and box.h < H, "which is not the whole canvas")
        t:check(box.x <= 100 and box.y <= 100, "and does cover the stroke")
        t:eq(bb:writesOutside(box.x, box.y, box.w, box.h), 0,
            "nothing at all was painted outside it")
    end)

    t:case("erasing reads back only the strokes the grid puts nearby", function()
        local cache, store = readyCache{
            strokes = { bar(100, 100), bar(120, 100), bar(1500, 2000) },
            cell = 100,
        }
        local reads = store.calls.stroke_read
        cache:removeStroke(cache:strokes()[1].id)
        local extra = store.calls.stroke_read - reads
        t:check(extra <= 1, "the far-away stroke is never decoded (" .. extra .. ")")
    end)

    t:case("erasing a stroke with no neighbours decodes nothing", function()
        local cache, store = readyCache{
            strokes = { bar(100, 100), bar(1500, 2000) }, cell = 100,
        }
        local reads = store.calls.stroke_read
        cache:removeStroke(cache:strokes()[2].id)
        t:eq(store.calls.stroke_read, reads, "there is nothing to repair with")
    end)

    t:case("the sweep collects the cut and its surviving runs", function()
        local cache = readyCache{ strokes = { bar(100, 100, 5, 4) }, cell = 100 }
        local ctx = cache:beginErase()
        -- bar points: x = 100,110,120,130,140 at y = 100. A vertical capsule
        -- through x = 120 with reach 4 + 4/2 kills the two middle segments.
        local hits = cache:eraseSweep(120, 90, 120, 110, 4, ctx)
        cache:endErase(ctx)
        t:eq(#hits, 1, "one stroke under the capsule")
        local hit = hits[1]
        t:eq(hit.n, 5, "with all its points decoded")
        t:eq(#hit.fragments, 2, "cut into two runs")
        t:eq(hit.fragments[1].first, 1, "head from the start")
        t:eq(hit.fragments[1].last, 2, "to before the cut")
        t:eq(hit.fragments[2].first, 4, "tail from after the cut")
        t:eq(hit.fragments[2].last, 5, "to the end")
        t:check(math.abs(hit.removed.min_x - 110) < 0.1
            and math.abs(hit.removed.max_x - 130) < 0.1,
            "the removed box spans the dead segments, dequantised")
    end)

    t:case("the sweep collects every stroke under the capsule, ascending", function()
        local cache = readyCache{
            strokes = { bar(100, 100, 5, 4), bar(100, 110, 5, 4) }, cell = 100,
        }
        local ctx = cache:beginErase()
        local hits = cache:eraseSweep(120, 95, 120, 115, 4, ctx)
        cache:endErase(ctx)
        t:eq(#hits, 2, "both strokes under the capsule were collected")
        t:check(hits[1].meta.seq < hits[2].meta.seq, "in ascending seq order")
        t:eq(#hits[1].fragments, 2, "the first was cut into two runs")
        t:eq(#hits[2].fragments, 2, "and so was the second")
    end)

    t:case("a sweep that misses collects nothing and decodes nothing", function()
        local cache, store = readyCache{ strokes = { bar(100, 100, 5, 4) } }
        local reads = store.calls.stroke_read
        local ctx = cache:beginErase()
        t:eq(cache:eraseSweep(800, 800, 810, 810, 4, ctx), nil, "no hit")
        cache:endErase(ctx)
        t:eq(store.calls.stroke_read, reads, "and not one chunk was read")
    end)

    t:case("a sweep across a chunk seam joins every chunk once", function()
        local points = {}
        for i = 0, 1999 do
            points[#points + 1] = 10 + i * 0.9
            points[#points + 1] = 100
        end
        local cache, store = readyCache{
            strokes = { { width = 4, tool = 1, points = points, n = 2000 } },
        }
        local reads = store.calls.stroke_chunk
        local ctx = cache:beginErase()
        -- Point 1024 -- the seam -- sits at x = 10 + 1023 * 0.9 = 930.7.
        local hits = cache:eraseSweep(930.7, 90, 930.7, 110, 2, ctx)
        cache:endErase(ctx)
        t:eq(#hits, 1, "the seam stroke was found")
        t:eq(hits[1].n, 2000, "joined with the seam point deduplicated")
        t:eq(#hits[1].fragments, 2, "and cut into two runs")
        t:eq(hits[1].fragments[1].first, 1, "head intact")
        t:eq(hits[1].fragments[2].last, 2000, "tail intact")
        t:check(hits[1].fragments[1].last < hits[1].fragments[2].first,
            "with a real gap between them")
        t:check(store.calls.stroke_chunk - reads <= 4,
            "chunks were read through the LRU, not re-decoded per segment")
    end)

    t:case("forgetStroke unindexes without reading or painting anything", function()
        local cache, store = readyCache{
            strokes = { bar(100, 100), bar(1500, 2000) }, cell = 100,
        }
        local target = cache:strokes()[1]
        local reads = store.calls.stroke_read
        local bb = cache:buffer()
        bb:clear()
        local m = cache:forgetStroke(target.id)
        t:eq(m, target, "the forgotten metadata is handed back")
        t:eq(#cache:strokes(), 1, "gone from the list")
        t:eq(cache:hitTest(110, 100, 18), nil, "and from the grid")
        t:eq(#bb.rects, 0, "with not one pixel painted")
        t:eq(store.calls.stroke_read, reads, "and not one chunk read")
        t:eq(cache:forgetStroke(target.id), nil, "forgetting twice is a no-op")
    end)

    t:case("an erased stroke is gone from the canvas's own list", function()
        local cache = readyCache{ strokes = { bar(100, 100), bar(500, 500) } }
        local id = cache:strokes()[1].id
        cache:removeStroke(id)
        t:eq(#cache:strokes(), 1, "one left")
        t:eq(cache:removeStroke(id), nil, "and removing it again does nothing")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / hit testing")

    t:case("a hit finds the stroke under the point", function()
        local cache = readyCache{ strokes = { bar(100, 100), bar(1500, 2000) } }
        local hit = cache:hitTest(110, 100, 18)
        t:check(hit ~= nil, "found")
        t:eq(hit.id, cache:strokes()[1].id, "the near one")
    end)

    t:case("a hit between sparse samples uses segment distance", function()
        local sparse = { width = 2, tool = 1, points = { 100, 100, 200, 100 }, n = 2 }
        local cache = readyCache{ strokes = { sparse } }
        t:check(cache:hitTest(150, 100, 1) ~= nil,
            "the line is erasable between its endpoints")
    end)

    t:case("stroke width expands the grid cells and the geometric reach", function()
        local thick = { width = 20, tool = 1, points = { 95, 10, 95, 40 }, n = 2 }
        local cache = readyCache{ strokes = { thick }, cell = 100 }
        t:check(cache:hitTest(104, 25, 1) ~= nil,
            "the visible edge crosses into the neighbouring cell")
    end)

    t:case("a one-point stroke remains erasable as a dot", function()
        local dot = { width = 2, tool = 1, points = { 100, 100 }, n = 1 }
        local cache = readyCache{ strokes = { dot } }
        t:check(cache:hitTest(101, 100, 1) ~= nil, "point distance includes width")
    end)

    t:case("a multichunk seam is erasable on either side of its joint", function()
        local points = {}
        for i = 1, 1100 do
            points[#points + 1] = i
            points[#points + 1] = 100
        end
        local cache = readyCache{ strokes = {
            { width = 2, tool = 1, points = points, n = 1100 },
        } }
        t:check(cache:hitTest(1023.5, 100, 1) ~= nil,
            "the segment crossing the repeated joint is continuous")
    end)

    t:case("one eraser contact reuses decoded chunks", function()
        local cache, store = readyCache{ strokes = { bar(100, 100) } }
        local ctx = cache:beginErase()
        local before = store.calls.stroke_read
        t:check(cache:hitTest(110, 100, 4, ctx) ~= nil, "first hit")
        local after_first = store.calls.stroke_read
        t:check(cache:hitTest(111, 100, 4, ctx) ~= nil, "second hit")
        t:check(after_first > before, "the chunk was read once for the contact")
        t:eq(store.calls.stroke_read, after_first, "and then came from the LRU")
        t:eq(ctx.stats.chunks_decoded, 1, "one decode is recorded for the operation")
        t:eq(ctx.stats.lru_hits, 1, "the second sample is an observable LRU hit")
        t:check(ctx.stats.candidates >= 2, "candidate work is counted")
        cache:endErase(ctx)
        t:eq(#ctx.order, 0, "lift releases the operation cache")
    end)

    t:case("the eraser LRU never retains more than eight chunks", function()
        local points = {}
        for i = 1, 10000 do
            points[#points + 1] = (i - 1) * (W - 1) / 9999
            points[#points + 1] = 100
        end
        local cache = readyCache{ strokes = {
            { width = 2, tool = 1, points = points, n = 10000 },
        } }
        local ctx = cache:beginErase()
        for chunk_no = 0, 8 do
            local first = chunk_no == 0 and 1
                or chunk_no * 1023 + 1
            local x = points[(first + 20) * 2 - 1]
            t:check(cache:hitTest(x, 100, 1, ctx) ~= nil,
                "chunk " .. chunk_no .. " hit")
            t:check(#ctx.order <= 8, "LRU bound after chunk " .. chunk_no)
        end
        t:eq(#ctx.order, 8, "the ninth decode evicted the oldest")
        cache:endErase(ctx)
    end)

    t:case("a miss is a miss, not the nearest stroke on the page", function()
        local cache = readyCache{ strokes = { bar(100, 100) } }
        t:eq(cache:hitTest(900, 900, 18), nil, "nothing within reach")
    end)

    t:case("the topmost stroke wins when two overlap", function()
        local cache = readyCache{ strokes = { bar(100, 100), bar(100, 100) } }
        local hit = cache:hitTest(105, 100, 18)
        t:eq(hit.id, cache:strokes()[2].id, "the one drawn last")
    end)

    t:case("a hit test on a dense canvas decodes only what is nearby", function()
        local strokes = {}
        for x = 0, 1700, 100 do
            for y = 0, 2300, 100 do
                strokes[#strokes + 1] = bar(x + 5, y + 5, 2)
            end
        end
        local cache, store = readyCache{ strokes = strokes, cell = 100 }
        t:check(#cache:strokes() > 300, "a genuinely dense fixture")
        local reads = store.calls.stroke_read
        cache:hitTest(10, 10, 18)
        local extra = store.calls.stroke_read - reads
        t:check(extra <= 8, "a handful of candidates, not the canvas (" .. extra .. ")")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / live ink")

    t:case("a live segment paints into the cache and reports its box", function()
        local cache = readyCache()
        local bb = cache:buffer()
        bb:clear()
        local box = cache:drawSegment(100, 100, 200, 100, 4)
        t:check(#bb.rects > 0, "painted")
        t:check(box ~= nil and box.w > 0 and box.h > 0, "with a dirty box to refresh")
        t:check(box.x <= 100 and box.x + box.w >= 200, "covering the segment")
    end)

    t:case("live dirty coverage is the half-open union actually painted", function()
        local cache = readyCache()
        local bb = cache:buffer()
        bb:clear()
        local box, raster_cache, raster_generation =
            cache:drawSegment(-10, 20, 10, 20, 4)
        local left, top = bb:getWidth(), bb:getHeight()
        local right, bottom = 0, 0
        for _, rect in ipairs(bb.rects) do
            if rect.x < left then left = rect.x end
            if rect.y < top then top = rect.y end
            if rect.x + rect.w > right then right = rect.x + rect.w end
            if rect.y + rect.h > bottom then bottom = rect.y + rect.h end
        end
        t:eq(box.x, left, "left edge")
        t:eq(box.y, top, "top edge")
        t:eq(box.w, right - left, "half-open width")
        t:eq(box.h, bottom - top, "half-open height")
        t:eq(raster_cache, cache, "token identifies the cache object")
        t:eq(raster_generation, cache.generation, "token identifies its generation")
    end)

    t:case("a live segment outside the canvas paints nothing at all", function()
        local cache = readyCache()
        local bb = cache:buffer()
        bb:clear()
        cache:drawSegment(-500, -500, -400, -500, 4)
        t:eq(#bb.rects, 0, "the buffer bounds the write, so it is simply dropped")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / geometry changes")

    t:case("dragging the sheet to a new height rebuilds nothing", function()
        local cache, store = readyCache{ strokes = { bar(100, 100) } }
        local before, reads = cache:buffer(), store.calls.stroke_read
        cache:setTransform(transform(math.floor(H * 0.6)))
        t:eq(cache:buffer(), before, "the same buffer")
        t:eq(store.calls.stroke_read, reads, "and not one stroke decoded again")
        t:eq(before.freed, false, "nothing was freed")
    end)

    t:case("a rotation rebuilds the cache from the stored vectors", function()
        local cache, store, sched = readyCache{ strokes = { bar(100, 100) } }
        local before, reads = cache:buffer(), store.calls.stroke_read
        cache:setTransform(transform(0, H, W))    -- landscape
        t:eq(before.freed, true, "the old buffer is released")
        t:eq(cache:isReady(), false, "and the canvas is rebuilding")
        sched:drain()
        t:check(store.calls.stroke_read > reads, "the strokes are rasterised again")
        t:check(cache:buffer() ~= before, "into a buffer of the new shape")
        local want_w, want_h = transform(0, H, W):cacheSize()
        t:eq(cache:buffer().w, want_w, "sized to the rotated aspect fit")
        t:eq(cache:buffer().h, want_h, "in both axes")
    end)

    t:case("rotation during loading invalidates the old generation", function()
        local strokes = {}
        for i = 1, 20 do strokes[i] = bar(i * 50, i * 50) end
        local cache, store, sched = fixture{ strokes = strokes, batch = 1 }
        cache:open()
        sched:tick()
        local before = cache:buffer()
        cache:setTransform(transform(0, H, W))
        t:eq(before.freed, true, "the partial old raster was freed")
        sched:drain()
        t:eq(cache:isReady(), true, "only the rotated generation completed")
        t:eq(store.calls.stroke_read, 21,
            "one old cursor plus each stroke of the replacement generation")
    end)

    -- =================================================================
    --[[--
    Ruled paper, and the erase that has to survive it.

    The ruling is composed into this raster rather than painted beneath it
    (ADR-27), which makes the erase repair the load-bearing case: it clears a
    box to a flat colour and, if nothing put the ruling back, would leave a
    white hole in the lines that no later repaint would ever fill.
    ]]
    t:describe("ink_canvas_cache / ruled paper")

    --- Recorded writes of one colour, as a comparable set.
    local function marksIn(bb, color)
        local out = {}
        for _, r in ipairs(bb.root.writes) do
            if r.c == color then
                out[#out + 1] = string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h)
            end
        end
        table.sort(out)
        return out
    end

    t:case("a canvas with no template is built exactly as it always was", function()
        local cache = readyCache()
        local bb = cache:buffer()
        t:eq(cache.paper_kind, nil, "an EPUB canvas row carries no template")
        t:eq(#bb.fills, 1, "one flat fill")
        t:eq(#bb.rects, 1, "and not one write beyond it")
        t:eq(bb.rects[1].c, "white", "the page is white")
    end)

    t:case("a ruled page is ruled once, at build time", function()
        local blank = readyCache()
        local ruled = readyCache{ paper_kind = "ruled" }
        local marks = marksIn(ruled:buffer(), "gray")
        t:eq(#blank:buffer().rects, 1, "a blank page writes only its fill")
        t:check(#marks > 0, "a ruled page writes marks (" .. #marks .. ")")
        t:eq(#ruled:buffer().fills, 1, "over one flat fill, not per mark")
        t:eq(ruled:buffer():writesOutside(0, 0, W, H), 0,
            "and nothing outside the page")
    end)

    t:case("erasing puts the ruling back into the hole it clears", function()
        local cache = readyCache{ paper_kind = "ruled", strokes = { bar(100, 100) } }
        local reference = readyCache{ paper_kind = "ruled" }
        local bb = cache:buffer()
        bb:clear()
        local box = cache:removeStroke(cache:strokes()[1].id)
        t:check(box ~= nil, "the stroke was removed")
        local cleared, ruling = 0, 0
        for _, r in ipairs(bb.rects) do
            if r.c == "white" then cleared = cleared + 1
            elseif r.c == "gray" then ruling = ruling + 1 end
        end
        t:check(cleared >= 1, "the hole was cleared")
        t:check(ruling >= 1, "and ruled again (" .. ruling .. " marks)")
        t:eq(bb:writesOutside(box.x, box.y, box.w, box.h), 0,
            "strictly inside the repaired box")
        -- The repair is not merely *some* ruling: it puts back the rules a
        -- page built from scratch has there, which is what keeps an erased
        -- word from leaving a seam. Rows are what can be compared across the
        -- two: a repair rules the width of its box, a build the whole page.
        local function rowsCrossing(buffer)
            local out = {}
            for _, r in ipairs(buffer.root.writes) do
                if r.c == "gray" and r.y < box.y + box.h
                    and r.y + r.h > box.y then
                    out[#out + 1] = r.y .. "," .. r.h
                end
            end
            table.sort(out)
            return out
        end
        local repaired = rowsCrossing(bb)
        local fresh = rowsCrossing(reference:buffer())
        t:check(#fresh > 0, "the box really does cross a rule")
        t:eq(#repaired, #fresh, "same rules as a fresh page")
        for i = 1, math.min(#repaired, #fresh) do
            t:eq(repaired[i], fresh[i], "rule " .. i .. " row and thickness")
        end
    end)

    t:case("adopting a ruling replays the page, and re-adopting it does not", function()
        local cache, store, sched = readyCache{ strokes = { bar(100, 100) } }
        local before, reads = cache:buffer(), store.calls.stroke_read
        t:eq(cache:needsPaperRebuild("dots"), true, "a new ruling rebuilds")
        t:eq(cache:setPaper("dots"), true, "adopted")
        t:eq(before.freed, true, "the old raster is released")
        t:eq(cache:isReady(), false, "and the page is rebuilding")
        sched:drain()
        t:check(store.calls.stroke_read > reads, "the strokes are replayed")
        t:check(#marksIn(cache:buffer(), "gray") > 0, "onto dotted paper")

        local kept, kept_reads = cache:buffer(), store.calls.stroke_read
        t:eq(cache:needsPaperRebuild("dots"), false, "the same ruling does not")
        t:eq(cache:setPaper("dots"), true, "and is still accepted")
        t:eq(cache:buffer(), kept, "the same buffer")
        t:eq(store.calls.stroke_read, kept_reads, "nothing decoded again")
    end)

    --- The gap in pixels between the first two horizontal rules.
    local function rowPitch(bb)
        local rows = {}
        for _, r in ipairs(bb.root.writes) do
            if r.c == "gray" and r.w > r.h then rows[#rows + 1] = r.y end
        end
        table.sort(rows)
        return rows[2] and (rows[2] - rows[1]) or nil, #rows
    end

    t:case("a rotation re-rules at the new scale, on the same paper", function()
        local cache, _, sched = readyCache{ paper_kind = "grid" }
        local before, rows_before = rowPitch(cache:buffer())
        local rotated = transform(0, H, W)         -- landscape, a new scale
        cache:setTransform(rotated)
        sched:drain()
        local after, rows_after = rowPitch(cache:buffer())
        t:check(after ~= nil, "the rotated page is still ruled")
        -- The pitch is drawn at the new scale...
        t:eq(after, math.floor(Paper.PITCH.grid * rotated.scale + 0.5),
            "the pixel pitch followed the scale")
        t:check(after ~= before, "which is not the pitch it had (" .. before .. ")")
        -- ...but the count is a property of the paper, in logical units, so
        -- rotating a page does not add or remove a single rule.
        t:eq(rows_after, rows_before, "and it is the same sheet of paper")
    end)

    -- =================================================================
    t:describe("ink_canvas_cache / closing")

    t:case("closing releases the buffer", function()
        local cache = readyCache{ strokes = { bar(100, 100) } }
        local bb = cache:buffer()
        cache:close()
        t:eq(bb.freed, true, "freed")
        t:eq(cache:buffer(), nil, "and let go of")
    end)

    t:case("closing stops a build that was still running", function()
        local strokes = {}
        for i = 1, 20 do strokes[i] = bar(i * 50, i * 50) end
        local cache, store, sched = fixture{ strokes = strokes, batch = 2 }
        cache:open()
        sched:tick()
        local reads = store.calls.stroke_read
        cache:close()
        sched:drain()
        t:eq(store.calls.stroke_read, reads, "no work after teardown")
    end)

    t:case("painting after close is a no-op rather than a crash", function()
        local cache = readyCache{ strokes = { bar(100, 100) } }
        cache:close()
        local dest = support.newBlitbuffer(W, H)
        cache:paintTo(dest)
        t:eq(#dest.blits, 0, "nothing painted, nothing raised")
    end)
end
