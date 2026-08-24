--[[--
Scale.

Not timings. A millisecond measured on a laptop says nothing about a Scribe's
flash or its panel, and a number that means nothing is worse than no number at
all. What these fixtures pin are *contracts* -- the shape of the work, counted:

  opening a book         no point is decoded, however many canvases there are
  turning a page         no query, no xpointer resolved, no CREngine call
  painting a sheet       one blit, whatever is on it
  finishing a stroke     proportional to that stroke, never to the canvas
  erasing                proportional to what is nearby, never to the book
  a very long stroke     bounded chunks, one undo, no seam

Each of these is a thing that can silently become linear in the wrong variable
during a refactor and still look right on a small book.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Cache = require("ink_canvas_cache")
    local Codec = require("ink_canvas_codec")
    local Index = require("ink_anchor_index")
    local Queue = require("ink_canvas_queue")
    local Transform = require("ink_canvas_transform")

    local W, H = 1860, 2480

    -- =================================================================
    t:describe("scale / a book full of closed canvases")

    t:case("200 canvases with 2 million points between them decode none", function()
        local canvases, pages = {}, {}
        local store = support.newCanvasStore(canvases)
        for i = 1, 200 do
            canvases[i] = {
                id = i,
                anchor_kind = "xpointer",
                anchor_raw = "/p" .. i, anchor_normalized = "/p" .. i,
                anchor_dom_version = 20240114,
                logical_w = W, logical_h = H,
            }
            pages["/p" .. i] = i
            -- 200 strokes of 50 points on each: 2,000,000 points in all.
            for k = 1, 200 do
                local points = {}
                for j = 1, 50 do
                    points[#points + 1] = (i * j) % W
                    points[#points + 1] = (k * j) % H
                end
                store:putStroke(i, { width = 4, tool = 1, points = points, n = 50 })
            end
        end

        local doc = support.newDocument{ pages = pages }
        local sched = support.newScheduler()
        local index = Index.new{
            repository = store, document = doc, book_id = 12,
            batch = 8, schedule = function(fn) sched:schedule(fn) end,
        }
        index:open()
        sched:drain()

        t:eq(store.calls.stroke_read, 0, "not one point decoded")
        t:eq(store.calls.stroke_list, 0, "and no canvas was opened")
        t:eq(index:pageOf(200), 200, "while every anchor was placed")
    end)

    t:case("500 anchors on a new layout resolve without a synchronous scan", function()
        local canvases, pages = {}, {}
        for i = 1, 500 do
            canvases[i] = {
                id = i, anchor_kind = "xpointer",
                anchor_raw = "/p" .. i, anchor_normalized = "/p" .. i,
                anchor_dom_version = 20240114,
            }
            pages["/p" .. i] = i
        end
        local doc = support.newDocument{ pages = pages }
        local store = support.newCanvasStore(canvases)
        local sched = support.newScheduler()
        local index = Index.new{
            repository = store, document = doc, book_id = 12,
            batch = 8, schedule = function(fn) sched:schedule(fn) end,
        }
        index:open()

        -- Read fifty pages while it builds.
        local resolved_before = doc.resolutions
        sched:tick()
        local after_one_batch = doc.resolutions
        for page = 1, 50 do
            doc.current_page = page
            index:visibleCanvases(page)
        end
        t:eq(doc.resolutions, after_one_batch, "reading resolved nothing extra")
        t:check(after_one_batch - resolved_before <= 8, "and a batch is a batch")

        sched:drain()
        t:eq(index:isComplete(), true, "it finishes on its own")
        t:eq(store.calls.save, math.ceil(500 / 8),
            "and persists one bounded batch per tick")
        for i = 1, #store.saves do
            local n = 0
            for _ in pairs(store.saves[i].pages) do n = n + 1 end
            t:check(n <= 8, "layout write " .. i .. " stays within the tick budget")
        end
        t:eq(store.saves[#store.saves].finalize, true,
            "only completion performs layout pruning")
    end)

    -- =================================================================
    t:describe("scale / one dense canvas")

    local DENSE = { id = 1, logical_w = W, logical_h = H }

    --- 5,000 strokes of 100 points, spread over the canvas. Built once and
    --- shared: none of these cases mutates the store, and half a million
    --- points is slow enough to be worth not doing four times.
    local dense_store
    local function denseStore()
        if dense_store then return dense_store end
        local store = support.newCanvasStore({ DENSE })
        for i = 1, 5000 do
            local ox = (i * 37) % (W - 100)
            local oy = (i * 61) % (H - 100)
            local points = {}
            for j = 1, 100 do
                points[#points + 1] = ox + j % 50
                points[#points + 1] = oy + j % 50
            end
            store:putStroke(DENSE.id, { width = 4, tool = 1, points = points, n = 100 })
        end
        dense_store = store
        return store
    end

    local function denseCache(store, batch)
        local sched = support.newScheduler()
        local cache = Cache.new{
            repository = store, canvas = DENSE,
            transform = Transform.new{
                logical_w = W, logical_h = H,
                screen_w = W, screen_h = H, sheet_top = 0,
            },
            batch = batch or 64,
            schedule = function(fn) sched:schedule(fn) end,
        }
        return cache, sched
    end

    t:case("half a million points build in cooperative batches", function()
        local store = denseStore()
        local cache, sched = denseCache(store, 64)
        cache:open()
        t:eq(store.calls.stroke_read, 0, "opening reads no points by itself")

        sched:tick()
        t:eq(store.calls.stroke_read, 64, "one batch")
        t:eq(cache:isReady(), false, "and it yields between them")

        local ticks = 1 + sched:drain()
        t:eq(store.calls.stroke_read, 5000, "every stroke once")
        t:check(ticks >= 5000 / 64, "over at least as many ticks as batches")
        t:eq(cache:isReady(), true, "then it is ready")
    end)

    --- One built cache, shared by the three read cases below. Rasterising half
    --- a million points is the expensive part, and none of them needs a fresh
    --- one to prove what it is proving.
    local built_cache, built_store
    local function readyDenseCache()
        if built_cache then return built_cache, built_store end
        built_store = denseStore()
        local cache, sched = denseCache(built_store)
        cache:open()
        sched:drain()
        built_cache = cache
        return built_cache, built_store
    end

    t:case("ten repaints of it decode nothing", function()
        local cache, store = readyDenseCache()
        local reads = store.calls.stroke_read
        local dest = support.newBlitbuffer(W, H)
        for _ = 1, 10 do cache:paintTo(dest) end
        t:eq(store.calls.stroke_read, reads, "not one of the 500,000 points")
        t:eq(#dest.blits, 10, "ten blits, and nothing else")
        t:eq(#dest.rects, 0, "no stroke was replayed")
    end)

    t:case("a hit test in a dense canvas decodes a neighbourhood", function()
        local cache, store = readyDenseCache()
        local reads = store.calls.stroke_read
        cache:hitTest(900, 1200, 18)
        local extra = store.calls.stroke_read - reads
        t:check(extra < 200,
            "a neighbourhood, not five thousand strokes (" .. extra .. ")")
    end)

    t:case("erasing in a dense canvas reads what is nearby, not the canvas", function()
        -- Last of the three, because it is the one that changes the cache.
        local cache, store = readyDenseCache()
        local reads = store.calls.stroke_read
        cache:removeStroke(cache:strokes()[2500].id)
        local extra = store.calls.stroke_read - reads
        t:check(extra < 200, "same bound as the hit test (" .. extra .. ")")
    end)

    -- =================================================================
    t:describe("scale / one very long stroke")

    t:case("a stroke of 12,000 points is stored in bounded chunks", function()
        local points = {}
        for i = 1, 12000 do
            points[#points + 1] = (i * 7) % W
            points[#points + 1] = (i * 11) % H
        end
        local chunks = Codec.encode(points, 12000, W, H)
        t:eq(#chunks, Codec.chunkCount(12000), "as many chunks as predicted")
        local biggest = 0
        for i = 1, #chunks do
            if #chunks[i].points > biggest then biggest = #chunks[i].points end
        end
        t:check(biggest <= Codec.HEADER + 4 * Codec.MAX_POINTS,
            "and no single row is unbounded (" .. biggest .. " bytes)")
    end)

    t:case("a 100,000 point stroke yields at the point budget", function()
        local ONE = { id = 3, logical_w = W, logical_h = H }
        local store = support.newCanvasStore({ ONE })
        local points = {}
        for i = 1, 100000 do
            points[#points + 1] = (i * 7) % W
            points[#points + 1] = (i * 11) % H
        end
        store:putStroke(ONE.id, { width = 4, tool = 1, points = points, n = 100000 })
        local sched = support.newScheduler()
        local budget = 8 * Codec.MAX_POINTS
        local cache = Cache.new{
            repository = store, canvas = ONE,
            transform = Transform.new{
                logical_w = W, logical_h = H,
                screen_w = W, screen_h = H, sheet_top = 0,
            },
            point_budget = budget,
            chunk_budget = 1000,
            schedule = function(fn) sched:schedule(fn) end,
        }
        cache:open()
        local before = store.calls.stroke_chunk
        sched:tick()
        local chunks = store.calls.stroke_chunk - before
        t:check(chunks * Codec.MAX_POINTS <= budget + Codec.MAX_POINTS,
            "one tick is bounded by budget plus one chunk")
        t:eq(cache:isReady(), false, "one huge stroke cannot monopolise the loop")
        local ticks = 1 + sched:drain()
        t:check(ticks > 1, "the work was split over multiple ticks")
        t:eq(cache:isReady(), true, "and all chunks eventually validated")
    end)

    t:case("it comes back continuous, with no seam and no duplicate", function()
        local points = {}
        for i = 1, 12000 do
            points[#points + 1] = (i * 7) % W
            points[#points + 1] = (i * 11) % H
        end
        local back, n = Codec.join(Codec.encode(points, 12000, W, H), W, H)
        t:eq(n, 12000, "every point once")
        local worst = 0
        for i = 1, n * 2 do
            local d = math.abs(back[i] - points[i])
            if d > worst then worst = d end
        end
        t:check(worst <= H / 65535 / 2 + 1e-9, "and in the right place")
    end)

    t:case("it is one stroke to undo, not twelve chunks", function()
        local store = support.newCanvasStore({ { id = 2, logical_w = W, logical_h = H } })
        local ONE = { id = 2, logical_w = W, logical_h = H }
        local points = {}
        for i = 1, 12000 do
            points[#points + 1] = (i * 7) % W
            points[#points + 1] = (i * 11) % H
        end
        store:putStroke(ONE.id, { width = 4, tool = 1, points = points, n = 12000 })
        local sched = support.newScheduler()
        local cache = Cache.new{
            repository = store, canvas = ONE,
            transform = Transform.new{
                logical_w = W, logical_h = H,
                screen_w = W, screen_h = H, sheet_top = 0,
            },
            schedule = function(fn) sched:schedule(fn) end,
        }
        cache:open()
        sched:drain()
        t:eq(#cache:strokes(), 1, "one stroke")
        cache:removeStroke(cache:strokes()[1].id)
        t:eq(#cache:strokes(), 0, "and one undo removes all of it")
    end)

    -- =================================================================
    t:describe("scale / deleting and undoing repeatedly")

    t:case("a thousand draw-and-undo cycles leave nothing pending", function()
        local store = support.newCanvasStore({ DENSE })
        local queue = Queue.new{
            repository = store,
            schedule = function() end,
            unschedule = function() end,
        }
        for i = 1, 1000 do
            local id = queue:addStroke(DENSE, {
                seq = i, width = 4, tool = 1, points = { 1, 1, 2, 2 }, n = 2,
            })
            queue:removeStroke(DENSE, id)
        end
        t:eq(queue:pendingCount(), 0, "each insert was withdrawn, not written")
        queue:flush()
        local n = 0
        for _, list in pairs(store.strokes) do n = n + #list end
        t:eq(n, 0, "and nothing reached the database")
        t:eq(#store.deleted, 0, "nor was a row ever deleted that never existed")
    end)

    t:case("the database is never compacted behind the reader's back", function()
        -- VACUUM rewrites the whole file. On a device, at an unpredictable
        -- moment, that is a pause the reader cannot account for. Freed pages
        -- are reused by SQLite instead; compaction is a deliberate action for
        -- another day.
        local driver = support.newSqlDriver{
            on_open = function(conn) conn:answer("PRAGMA user_version", { { 0 } }) end,
        }
        local Repository = require("ink_canvas_repository")
        local repo = Repository.open{
            path = "/tmp/fingerink-scale.sqlite3", driver = driver, wal = false,
            now = function() return 1 end,
        }
        repo:deleteCanvas(1)
        repo:deleteStroke(1)
        repo:close()
        t:eq(driver.last():saw("VACUUM"), false, "not on delete, and not on close")
    end)
end
