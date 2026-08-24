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
            cell = opts.cell or 100,
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
