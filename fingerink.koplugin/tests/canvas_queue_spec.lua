--[[--
When a stroke reaches the disk, and what happens when it cannot.

Writing on every lift puts a database commit in the middle of handwriting.
Writing only on close loses whatever the reader wrote since they last opened
the book. So the queue is a bounded compromise: a stroke is held in memory for
at most a quarter of a second, eight operations or sixty-four kilobytes, and it
is flushed unconditionally at every point KOReader tells us the session might
be about to end.

`onSaveSettings` is the mandatory one. `Device:_beforeSuspend` calls
`UIManager:flushSettings()` and only *then* emits `Suspend`, so a plugin that
saved in `onSuspend` would already have missed its chance.

The other half is that a failure never silently loses work. A failed flush
keeps the queue exactly as it was, refuses further edits and says so; it does
not mark anything committed, and it does not reach for a fresh database.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Queue = require("ink_canvas_queue")

    local CANVAS = { id = 1, logical_w = 1000, logical_h = 1000 }

    local function stroke(n, seq)
        local points = {}
        for i = 1, (n or 4) do
            points[#points + 1] = i * 3
            points[#points + 1] = i * 5
        end
        return { seq = seq, width = 4, tool = 1, points = points, n = n or 4 }
    end

    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore({ CANVAS })
        local sched = support.newScheduler()
        local errors = {}
        local scheduled, unscheduled = {}, {}
        local queue = Queue.new{
            repository = store,
            max_ops = opts.max_ops,
            max_bytes = opts.max_bytes,
            delay = opts.delay,
            schedule = function(delay, fn)
                scheduled[#scheduled + 1] = { delay = delay, fn = fn }
                sched:schedule(fn)
            end,
            unschedule = function(fn)
                unscheduled[#unscheduled + 1] = fn
            end,
            on_error = function(err) errors[#errors + 1] = err end,
        }
        return queue, store, sched, { errors = errors, scheduled = scheduled,
                                      unscheduled = unscheduled }
    end

    local function strokeCount(store)
        local n = 0
        for _, list in pairs(store.strokes) do n = n + #list end
        return n
    end

    -- =================================================================
    t:describe("ink_canvas_queue / batching")

    t:case("a finished stroke is held, not written", function()
        local queue, store = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        t:eq(strokeCount(store), 0, "nothing on disk yet")
        t:eq(queue:pendingCount(), 1, "one operation waiting")
    end)

    t:case("holding a stroke schedules the flush that will write it", function()
        local queue, store, sched, log = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        t:eq(#log.scheduled, 1, "one timer armed")
        t:check(log.scheduled[1].delay > 0, "after a delay, not immediately")
        sched:drain()
        t:eq(strokeCount(store), 1, "and then it is written")
        t:eq(queue:pendingCount(), 0, "with nothing left over")
    end)

    t:case("a second stroke does not arm a second timer", function()
        local queue, _, _, log = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:addStroke(CANVAS, stroke(4, 2))
        t:eq(#log.scheduled, 1, "the first timer still covers both")
    end)

    t:case("enough operations flush without waiting for the timer", function()
        local queue, store = fixture{ max_ops = 3 }
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:addStroke(CANVAS, stroke(4, 2))
        t:eq(strokeCount(store), 0, "under the limit")
        queue:addStroke(CANVAS, stroke(4, 3))
        t:eq(strokeCount(store), 3, "and at the limit it goes now")
        t:eq(queue:pendingCount(), 0, "queue drained")
    end)

    t:case("enough bytes flush without waiting either", function()
        -- A single very long stroke can exceed the byte bound on its own,
        -- which is the case the count alone would miss.
        local queue, store = fixture{ max_bytes = 200 }
        queue:addStroke(CANVAS, stroke(500, 1))
        t:eq(strokeCount(store), 1, "written straight away")
    end)

    t:case("a flush is one transaction, whatever it holds", function()
        local queue, store = fixture{ max_ops = 4 }
        for i = 1, 4 do queue:addStroke(CANVAS, stroke(4, i)) end
        t:eq(store.calls.transaction, 1, "four strokes, one transaction")
    end)

    t:case("flushing an empty queue does nothing at all", function()
        local queue, store = fixture()
        t:eq(queue:flush(), true, "reports success")
        t:eq(store.calls.transaction, 0, "without opening a transaction")
    end)

    t:case("the pending timer is cancelled by reference, not by handle", function()
        -- UIManager:unschedule takes the function it was given. Treating
        -- scheduleIn's return value as a handle silently cancels nothing.
        local queue, _, sched, log = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        t:eq(#log.unscheduled, 1, "cancelled")
        t:eq(log.unscheduled[1], log.scheduled[1].fn, "the same function object")
        sched:drain()
    end)

    -- =================================================================
    t:describe("ink_canvas_queue / undo before the write")

    t:case("undoing a still-pending stroke drops its insert", function()
        local queue, store = fixture()
        local id = queue:addStroke(CANVAS, stroke(4, 1))
        queue:removeStroke(CANVAS, id)
        t:eq(queue:pendingCount(), 0, "the insert is simply gone")
        queue:flush()
        t:eq(strokeCount(store), 0, "so it is never written and never deleted")
        t:eq(#store.deleted, 0, "no delete was issued for a row that never existed")
    end)

    t:case("undoing one pending stroke leaves the others queued", function()
        local queue, store = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        local second = queue:addStroke(CANVAS, stroke(4, 2))
        queue:addStroke(CANVAS, stroke(4, 3))
        queue:removeStroke(CANVAS, second)
        t:eq(queue:pendingCount(), 2, "two left")
        queue:flush()
        t:eq(strokeCount(store), 2, "and two written")
    end)

    t:case("undoing a written stroke queues a delete against its real row", function()
        local queue, store = fixture()
        local id = queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        local real = store.strokes[CANVAS.id][1].id
        queue:removeStroke(CANVAS, id)
        queue:flush()
        t:eq(store.deleted[1], real, "the row the insert actually created")
        t:eq(strokeCount(store), 0, "and it is gone")
    end)

    t:case("a local id keeps meaning the same stroke after it is written", function()
        local queue, store = fixture()
        local id = queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        t:eq(queue:realId(id), store.strokes[CANVAS.id][1].id,
            "so the cache never has to learn a new identity mid-session")
    end)

    -- =================================================================
    t:describe("ink_canvas_queue / failure")

    t:case("a failed flush keeps every operation", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:addStroke(CANVAS, stroke(4, 2))
        local ok = queue:flush()
        t:eq(ok, nil, "reported as failed")
        t:eq(queue:pendingCount(), 2, "and nothing was thrown away")
    end)

    t:case("a failed flush marks nothing as written", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        local id = queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        t:eq(queue:realId(id), nil, "no row id was invented")
        t:eq(strokeCount(store), 0, "and no row exists")
    end)

    t:case("a failure is reported once, to somebody who can show it", function()
        local queue, store, _, log = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        t:eq(#log.errors, 1, "the caller hears about it")
        t:check(log.errors[1] ~= nil, "with a reason to put on screen")
    end)

    t:case("editing stops after a failure rather than piling up", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        t:eq(queue:isFailed(), true, "the queue knows it is stuck")
        local id, err = queue:addStroke(CANVAS, stroke(4, 2))
        t:eq(id, nil, "further work is refused")
        t:eq(err, "failed", "with a reason the UI can act on")
    end)

    t:case("a retry writes exactly what was still pending", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:addStroke(CANVAS, stroke(4, 2))
        queue:flush()
        store.fail_transaction = nil
        t:eq(queue:retry(), true, "the retry works")
        t:eq(strokeCount(store), 2, "both strokes, once each")
        t:eq(queue:isFailed(), false, "and the queue is usable again")
    end)

    t:case("a retry that fails again leaves the queue intact", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        queue:retry()
        t:eq(queue:pendingCount(), 1, "still there to try again")
        t:eq(queue:isFailed(), true, "and still stuck")
    end)

    t:case("a successful flush does not rewrite what it already wrote", function()
        local queue, store = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:flush()
        queue:flush()
        t:eq(strokeCount(store), 1, "written once")
        t:eq(store.calls.transaction, 1, "and the second flush did nothing")
    end)

    -- =================================================================
    t:describe("ink_canvas_queue / shutting down")

    t:case("closing flushes what is left", function()
        local queue, store = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:close()
        t:eq(strokeCount(store), 1, "written on the way out")
    end)

    t:case("closing cancels the pending timer", function()
        local queue, _, _, log = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:close()
        t:eq(log.unscheduled[1], log.scheduled[1].fn, "by reference")
    end)

    t:case("closing with a failed flush says so rather than pretending", function()
        local queue, store = fixture()
        store.fail_transaction = "begin"
        queue:addStroke(CANVAS, stroke(4, 1))
        local ok = queue:close()
        t:eq(ok, nil, "the caller is told the work is not durable")
        t:eq(queue:pendingCount(), 1, "and it is still in hand")
    end)

    t:case("a flush after closing does not write again", function()
        local queue, store = fixture()
        queue:addStroke(CANVAS, stroke(4, 1))
        queue:close()
        queue:flush()
        t:eq(strokeCount(store), 1, "once")
    end)
end
