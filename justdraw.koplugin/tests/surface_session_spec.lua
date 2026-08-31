return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local SurfaceSession = require("ink_surface_session")
    local Codec = require("ink_canvas_codec")
    local Transform = require("ink_canvas_transform")

    local SURFACE = { id = 71, logical_w = 1000, logical_h = 1400 }

    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore({ SURFACE })
        if opts.stroke then store:putStroke(SURFACE.id, opts.stroke) end
        local sched = support.newScheduler()
        local session = SurfaceSession.new{
            repository = store,
            surface = SURFACE,
            transform = Transform.new{
                logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            },
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            max_open_points = opts.max_open_points,
            queue_opts = opts.queue_opts,
        }
        return session, store, sched
    end

    t:describe("ink_surface_session / generic durability")

    t:case("opens and edits a surface with no book fields", function()
        local session, store = fixture()
        t:eq(session:open(), true, "opened")
        t:eq(session:stateName(), "ready", "empty surface is ready")
        local id = session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:check(id ~= nil, "stroke accepted")
        t:eq(session:pendingWrites(), 1, "queued")
        t:eq(session:flush(), true, "durable")
        t:eq(#store.strokes[SURFACE.id], 1, "stored")
    end)

    t:case("a failed commit preserves cache and blocks new ink until retry", function()
        local session, store = fixture()
        session:open()
        session:addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        local cache = session:cache()
        store.fail_transaction = "commit"
        local ok = session:flush()
        t:eq(ok, nil, "commit failure surfaced")
        t:eq(session:stateName(), "save_failed", "state blocks editing")
        t:eq(session:addStroke({ 3, 3 }, 1, 4, 1), nil, "no ghost ink accepted")
        t:eq(session:cache(), cache, "retry objects retained")
        t:eq(session:close(), nil, "close is a durable gate")
        store.fail_transaction = nil
        t:eq(session:retrySave(), true, "same operations retry")
        t:eq(session:stateName(), "ready", "editing recovered")
        t:eq(#store.strokes[SURFACE.id], 1, "insert was not duplicated")
    end)

    t:case("a read failure remains retryable", function()
        local session, store, sched = fixture{ stroke = {
            width = 4, tool = 1, points = { 1, 1, 2, 2 }, n = 2,
        } }
        store.fail_stroke_cursor = "read failed"
        session:open()
        sched:drain()
        t:eq(session:stateName(), "load_failed", "failure is visible")
        t:check(session:cache() ~= nil, "cache retained")
        store.fail_stroke_cursor = nil
        t:eq(session:retryLoad(), true, "reload started")
        sched:drain()
        t:eq(session:stateName(), "ready", "reload completed")
    end)

    t:case("sequence lookup failure is a retryable load failure", function()
        local session, store = fixture()
        function store:nextSeq() return nil, "sequence read failed" end
        local ok, err = session:open()
        t:eq(ok, nil, "opening reports the synchronous failure")
        t:eq(err, "sequence read failed", "real reason retained")
        t:eq(session:stateName(), "load_failed", "not falsely ready")
        t:eq(session:isReady(), false, "cache readiness cannot mask metadata failure")
        t:eq(session:addStroke({ 1, 1 }, 1, 4, 1), nil,
            "failed sequence metadata cannot accept ink")
        function store:nextSeq() return 1 end
        t:eq(session:retryLoad(), true, "metadata can retry")
        t:eq(session:stateName(), "ready", "recovered")
    end)

    t:case("invalid finite data never enters the queue or raster", function()
        local session = fixture()
        session:open()
        local before = #session:cache():strokes()
        local id = session:addStroke({ 1, 1, math.huge, 2 }, 2, 4, 1)
        t:eq(id, nil, "infinite point rejected")
        t:eq(session:pendingWrites(), 0, "nothing queued")
        t:eq(#session:cache():strokes(), before, "nothing painted")
    end)

    t:case("cache rejection withdraws the queue-first insert", function()
        local session, store = fixture()
        session:open()
        local cache = session:cache()
        local original = cache.addStroke
        cache.addStroke = function() return nil, "cache rejected" end
        local before_seq = session.next_seq
        local id, err = session:addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        cache.addStroke = original
        t:eq(id, nil, "surface reports the cache rejection")
        t:eq(err, "cache rejected", "with the original reason")
        t:eq(session:pendingWrites(), 0, "queued insert was withdrawn")
        t:eq(session.next_seq, before_seq, "sequence was not consumed")
        t:eq(store.calls.transaction, 0, "rollback required no SQLite")
    end)

    t:case("the queue estimator matches every encoded chunk and seam", function()
        local session = fixture()
        session:open()
        local function actualBytes(n)
            local points = {}
            for i = 1, n do
                points[i * 2 - 1] = (i - 1) % SURFACE.logical_w
                points[i * 2] = (i - 1) % SURFACE.logical_h
            end
            local bytes = 0
            local ok = Codec.eachEncodedChunk(points, n,
                SURFACE.logical_w, SURFACE.logical_h, function(_, _, blob)
                    bytes = bytes + #blob
                    return true
                end)
            t:eq(ok, true, "encoding succeeds")
            return bytes
        end
        for _, n in ipairs{ 1, 1024, 1025, 8192 } do
            t:eq(session.queue.estimate_insert_bytes(n), actualBytes(n),
                "exact encoded bytes for " .. n .. " points")
        end
        t:eq(session.queue.max_single_op_bytes,
            session.queue.estimate_insert_bytes(8192),
            "production ceiling derives from the shared open-stroke limit")
    end)

    t:case("a complete live raster token avoids repaint at registration", function()
        local session = fixture()
        session:open()
        local cache = session:cache()
        local _, raster_cache, raster_generation =
            cache:drawSegment(10, 10, 20, 20, 4)
        local before = #cache:buffer().writes
        local id, err, painted, left, top, right, bottom = session:addStroke(
            { 10, 10, 20, 20 }, 2, 4, 1, {
                raster_cache = raster_cache,
                raster_generation = raster_generation,
                live_raster_complete = true,
            })
        t:check(id ~= nil, "stroke registered")
        t:eq(err, nil, "without an error")
        t:eq(painted, false, "registration skips the second raster pass")
        t:eq(left, nil, "no fallback coverage")
        t:eq(top, nil, "no fallback coverage")
        t:eq(right, nil, "no fallback coverage")
        t:eq(bottom, nil, "no fallback coverage")
        t:eq(#cache:buffer().writes, before, "no new paintRect calls")
        t:eq(#cache:strokes(), 1, "metadata is still registered")
    end)

    t:case("an old raster generation repaints once and returns coverage", function()
        local session, _, sched = fixture()
        session:open()
        local cache = session:cache()
        local _, raster_cache, raster_generation =
            cache:drawSegment(10, 10, 20, 20, 4)
        session:setTransform(Transform.new{
            logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
            fit_rect = { x = 0, y = 0, w = 500, h = 700 },
            clip_rect = { x = 0, y = 0, w = 500, h = 700 },
        })
        sched:drain()
        local before = #cache:buffer().writes
        local id, err, painted, left, top, right, bottom = session:addStroke(
            { 10, 10, 20, 20 }, 2, 4, 1, {
                raster_cache = raster_cache,
                raster_generation = raster_generation,
                live_raster_complete = true,
            })
        t:check(id ~= nil, "stroke registered after rebuild")
        t:eq(err, nil, "without an error")
        t:eq(painted, true, "stale token falls back to a full stroke paint")
        t:check(left >= 0 and top >= 0, "coverage starts in the cache")
        t:check(right > left and bottom > top, "coverage is positive half-open")
        t:check(#cache:buffer().writes > before, "fallback painted exactly now")
    end)

    t:case("queue backpressure leaves cache and sequence untouched until commit", function()
        local session, store, sched = fixture{
            queue_opts = { max_ops = 1, max_bytes = 1000000 },
        }
        session:open()
        local first = session:addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        local second = session:addStroke({ 3, 3, 4, 4 }, 2, 4, 1)
        t:check(first ~= nil and second ~= nil, "hard ceiling admits soft plus one")
        local before_seq = session.next_seq
        local before_cache = #session:cache():strokes()
        local rejected, reason =
            session:addStroke({ 5, 5, 6, 6 }, 2, 4, 1)
        t:eq(rejected, nil, "the next operation is rejected")
        t:eq(reason, "queue_backpressure", "as transient pressure")
        t:eq(session.next_seq, before_seq, "sequence is not consumed")
        t:eq(#session:cache():strokes(), before_cache, "cache is not mutated")
        t:eq(store.calls.transaction, 0, "addStroke did no SQLite")
        sched:tick()
        t:eq(#store.strokes[SURFACE.id], 2, "urgent commit drains admitted ink")
        t:check(session:cache():strokes()[1].id > 0
            and session:cache():strokes()[2].id > 0,
            "async commit publishes durable IDs to the cache")
        t:eq(session.queue:realId(first), nil,
            "the queue retains no reconciled local-ID mapping")
        t:check(session:addStroke({ 7, 7, 8, 8 }, 2, 4, 1) ~= nil,
            "the next stroke works without Retry")
    end)

    t:describe("ink_surface_session / partial erase")

    local BAR5 = { width = 4, tool = 1, n = 5,
        points = { 100, 100, 200, 100, 300, 100, 400, 100, 500, 100 } }

    t:case("the eraser cuts a stroke into fragments, atomically", function()
        local session, store, sched = fixture{ stroke = BAR5 }
        session:open()
        sched:drain()
        t:eq(session:isReady(), true, "ready")
        local original = session:cache():strokes()[1].id
        local ctx = session:beginErase()
        local box = session:eraseAt(300, 100, 18, ctx)
        session:endErase(ctx)
        t:check(box ~= nil, "the cut reports a dirty region")
        local metas = session:cache():strokes()
        t:eq(#metas, 2, "two fragments remain")
        t:eq(metas[1].point_count, 2, "the head kept its two points")
        t:eq(metas[2].point_count, 2, "the tail kept its two points")
        t:check(metas[1].from_erase and metas[2].from_erase,
            "both are marked as erase debris")
        t:eq(session:pendingWrites(), 3,
            "two inserts and one delete travel in the same flush")
        t:eq(session.maintenance_pending, true,
            "a persisted original schedules maintenance")
        t:eq(session:flush(), true, "durable")
        t:eq(#store.strokes[SURFACE.id], 2, "the store holds the fragments")
        t:eq(store.deleted[1], original, "and the original row is gone")
    end)

    t:case("a fast pass cannot slide between two eraser samples", function()
        local session, _, sched = fixture{ stroke = BAR5 }
        session:open()
        sched:drain()
        local ctx = session:beginErase()
        t:eq(session:eraseAt(300, 400, 18, ctx), nil, "far below: nothing yet")
        local box = session:eraseAt(300, 50, 18, ctx)
        session:endErase(ctx)
        t:check(box ~= nil, "the capsule between the samples cut the stroke")
        t:eq(#session:cache():strokes(), 2, "into two fragments")
    end)

    t:case("a refused enqueue leaves the stroke whole", function()
        local session, store, sched = fixture{
            stroke = BAR5,
            queue_opts = { hard_ops = 1 },
        }
        session:open()
        sched:drain()
        local ctx = session:beginErase()
        t:eq(session:eraseAt(300, 400, 18, ctx), nil, "far miss arms the anchor")
        local box, err = session:eraseAt(300, 100, 18, ctx)
        t:eq(box, nil, "the sample was skipped")
        t:eq(err, "queue_backpressure", "with the queue's own reason")
        t:eq(ctx.sweep_x, 300, "the refused span's anchor is restored")
        t:eq(ctx.sweep_y, 400, "so the next sample re-sweeps it")
        session:endErase(ctx)
        t:eq(#session:cache():strokes(), 1, "the original is untouched")
        t:eq(session:cache():strokes()[1].point_count, 5, "with all its points")
        t:eq(session:flush(), true, "the queue drains cleanly")
        t:eq(#store.strokes[SURFACE.id], 1, "the store never saw fragments")
        t:eq(#store.deleted, 0, "nor a delete")
    end)

    t:case("one sample cuts every stroke under the capsule", function()
        local session, store, sched = fixture{ stroke = { width = 4, tool = 1, n = 5,
            points = { 100, 110, 200, 110, 300, 110, 400, 110, 500, 110 } } }
        store:putStroke(SURFACE.id, { width = 4, tool = 1, n = 5,
            points = { 100, 130, 200, 130, 300, 130, 400, 130, 500, 130 } })
        session:open()
        sched:drain()
        local ctx = session:beginErase()
        local box = session:eraseAt(300, 120, 18, ctx)
        session:endErase(ctx)
        t:check(box ~= nil, "the union of both repairs is reported")
        t:eq(#session:cache():strokes(), 4, "both strokes became two fragments each")
        t:eq(session:pendingWrites(), 6, "two inserts and a delete per stroke")
        t:eq(session:flush(), true, "one durable flush")
        t:eq(#store.strokes[SURFACE.id], 4, "the store holds all four fragments")
        t:eq(#store.deleted, 2, "and both originals are gone")
    end)

    t:case("undo after a cut removes the last drawn stroke, not a fragment", function()
        local session, _, sched = fixture{ stroke = BAR5 }
        session:open()
        sched:drain()
        local b = session:addStroke({ 800, 800, 900, 900 }, 2, 4, 1)
        t:check(b ~= nil, "stroke B drawn on top")
        local ctx = session:beginErase()
        t:check(session:eraseAt(300, 100, 18, ctx) ~= nil, "A was cut")
        session:endErase(ctx)
        t:eq(#session:cache():strokes(), 3, "B plus two fragments of A")
        t:eq(session:canUndo(), true, "undo is offered")
        t:check(session:undo() ~= nil, "and taken")
        local metas = session:cache():strokes()
        t:eq(#metas, 2, "B is gone, the fragments survived")
        t:check(metas[1].from_erase and metas[2].from_erase,
            "only erase debris remains")
        t:eq(session:canUndo(), false, "which undo does not offer to remove")
    end)
end
