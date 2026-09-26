--[[--
Surfaces with an edit history (ADR-53): identity through undo/redo, the
all-or-nothing replacement primitive and erase contacts as one entry.

The legacy undo stays pinned by surface_session_spec, which runs every case
on a session without a history and must not change.
]]
return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local SurfaceSession = require("ink_surface_session")
    local History = require("ink_edit_history")
    local Transform = require("ink_canvas_transform")

    local SURFACE = { id = 81, logical_w = 1000, logical_h = 1400 }

    local function transform(w, h)
        return Transform.new{
            logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
            fit_rect = { x = 0, y = 0, w = w or 1000, h = h or 1400 },
            clip_rect = { x = 0, y = 0, w = w or 1000, h = h or 1400 },
        }
    end

    local function fixture(opts)
        opts = opts or {}
        local store = opts.store or support.newCanvasStore({ SURFACE })
        for _, s in ipairs(opts.strokes or {}) do store:putStroke(SURFACE.id, s) end
        local sched = opts.sched or support.newScheduler()
        local notices = {}
        local history = opts.history
        if history == nil then history = History.new{ pool = opts.pool } end
        local session = SurfaceSession.new{
            repository = store,
            surface = SURFACE,
            transform = transform(),
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            queue_opts = opts.queue_opts,
            history = history or nil,
            can_work = opts.can_work,
            on_history_notice = function(what) notices[#notices + 1] = what end,
        }
        session:open()
        sched:drain()
        return session, store, sched, history, notices
    end

    --- The page as a comparable list: sorted by paint order, with rounded
    --- points, width, tool and key. Ids are deliberately left out -- they
    --- change with every COMMIT and every restore.
    local function page(session)
        local out = {}
        local strokes = session:cache():strokes()
        local sorted = {}
        for i = 1, #strokes do sorted[i] = strokes[i] end
        table.sort(sorted, function(a, b)
            local ap, bp = a.paint_seq or a.seq, b.paint_seq or b.seq
            if ap == bp then return a.seq < b.seq end
            return ap < bp
        end)
        for _, m in ipairs(sorted) do
            local points, n = session:cache():readPoints(m)
            local parts = {}
            for i = 1, n * 2 do parts[i] = string.format("%.1f", points[i]) end
            out[#out + 1] = table.concat({ m.key or "?", m.version or "?",
                m.width, m.tool, m.paint_seq or m.seq, table.concat(parts, ",") }, "|")
        end
        return table.concat(out, "\n")
    end

    local function draw(session, points, width, tool)
        local id, err = session:addStroke(points, #points / 2, width or 4, tool or 1)
        assert(id, err)
        return session:cache():metaById(id) or session:cache():metaById(session.queue:realId(id))
    end

    local function eraseLine(session, x0, y0, x1, y1, radius)
        local ctx = session:beginErase()
        session:eraseAt(x0, y0, radius or 18, ctx)
        if x1 then session:eraseAt(x1, y1, radius or 18, ctx) end
        session:endErase(ctx)
    end

    local function queueState(session)
        local q = session.queue
        local parts = {}
        for i = 1, #q.ops do
            local op = q.ops[i]
            parts[#parts + 1] = op.kind .. ":" .. tostring(op.local_id or op.row_id)
        end
        return table.concat(parts, ","), q.bytes, q.next_local
    end

    t:describe("ink_surface_session / history identity")

    t:case("draw A, erase A, undo, undo, redo, redo restores each state exactly", function()
        for _, flush_between in ipairs({ false, true }) do
            local session = fixture()
            local empty = page(session)
            draw(session, { 100, 100, 200, 100, 300, 100 })
            if flush_between then session:flush() end
            local drawn = page(session)
            eraseLine(session, 50, 100, 350, 100, 30)
            if flush_between then session:flush() end
            local erased = page(session)
            t:eq(erased, empty, "the erase took the whole stroke")
            t:check(session:undo(), "undo the erase")
            if flush_between then session:flush() end
            t:eq(page(session), drawn, "the stroke came back with its key")
            t:check(session:undo(), "undo the drawing")
            if flush_between then session:flush() end
            t:eq(page(session), empty, "and went away: the restored stroke was found by key")
            t:eq(session:canUndo(), false, "nothing left")
            t:check(session:redo(), "redo the drawing")
            t:eq(page(session), drawn, "drawn again")
            t:check(session:redo(), "redo the erase")
            t:eq(page(session), erased, "erased again")
            t:eq(session:canRedo(), false, "nothing left to redo")
            session:flush()
        end
    end)

    t:case("a partial erase is one entry: undo puts the whole stroke back", function()
        local session = fixture()
        draw(session, { 100, 100, 200, 100, 300, 100, 400, 100, 500, 100 })
        local drawn = page(session)
        eraseLine(session, 250, 100, 260, 100, 18)
        local cut = page(session)
        t:check(cut ~= drawn, "the stroke was cut")
        t:eq(#session:cache():strokes(), 2, "into two survivors")
        t:check(session:undo(), "undo the erase")
        t:eq(page(session), drawn, "the original is back, fragments gone")
        t:check(session:redo(), "redo")
        t:eq(page(session), cut, "cut again, the same survivors")
    end)

    t:case("fragments cut again within one contact never reach the entry", function()
        local session, _, _, history = fixture()
        draw(session, { 100, 100, 200, 100, 300, 100, 400, 100, 500, 100, 600, 100 })
        local drawn = page(session)
        local ctx = session:beginErase()
        session:eraseAt(200, 100, 18, ctx)
        session:eraseAt(200, 100, 18, ctx)
        session:eraseAt(400, 100, 18, ctx)
        session:eraseAt(400, 100, 18, ctx)
        session:endErase(ctx)
        local e = history:peekUndo()
        t:eq(e.label, "erase", "one erase entry")
        t:eq(#e.before, 1, "only the pre-contact stroke is before")
        t:eq(#e.after, #session:cache():strokes(), "after is exactly the survivors")
        t:check(session:undo(), "undone")
        t:eq(page(session), drawn, "the page is the drawn one")
    end)

    t:case("moving twice keeps the key; undo and redo walk every version with flushes between", function()
        local session = fixture()
        local a = draw(session, { 100, 100, 200, 200 })
        local key = a.key
        local s0 = page(session)
        local r1 = session:replaceStrokes({ key }, { {
            key = key, version = 2, points = { 110, 110, 210, 210 }, n = 2,
            width = 4, tool = 1, paint_seq = a.paint_seq,
        } }, { label = "move", expect_versions = { [key] = 1 } })
        t:check(r1 and r1.accepted, "first move accepted")
        session:flush()
        local s1 = page(session)
        local r2 = session:replaceStrokes({ key }, { {
            key = key, version = 3, points = { 300, 300, 400, 400 }, n = 2,
            width = 4, tool = 1, paint_seq = a.paint_seq,
        } }, { label = "move", expect_versions = { [key] = 2 } })
        t:check(r2 and r2.accepted, "second move accepted")
        local s2 = page(session)
        eraseLine(session, 300, 300, 400, 400, 40)
        local s3 = page(session)
        session:flush()
        t:check(session:undo(), "undo erase"); t:eq(page(session), s2, "back to move 2")
        session:flush()
        t:check(session:undo(), "undo move 2"); t:eq(page(session), s1, "back to move 1")
        t:check(session:undo(), "undo move 1"); t:eq(page(session), s0, "back to the drawing")
        session:flush()
        t:check(session:redo(), "redo move 1"); t:eq(page(session), s1, "move 1")
        t:check(session:redo(), "redo move 2"); t:eq(page(session), s2, "move 2")
        session:flush()
        t:check(session:redo(), "redo erase"); t:eq(page(session), s3, "erased")
    end)

    t:case("a reused row id cannot make undo remove the wrong stroke", function()
        local session, store = fixture()
        draw(session, { 10, 10, 20, 20 })
        local b = draw(session, { 500, 500, 600, 600 })
        session:flush()
        local b_row = b.id
        -- Erase B (the newest row), flush: SQLite frees its row id.
        eraseLine(session, 550, 550, nil, nil, 80)
        session:flush()
        -- The next insert reuses that row id.
        local c = draw(session, { 800, 100, 900, 100 })
        session:flush()
        t:eq(c.id, b_row, "the fake reused the freed row id, as SQLite does")
        local with_c = page(session)
        t:check(session:undo(), "undo drawing C")
        t:check(not page(session):find("800.0,100.0", 1, true), "C went")
        t:check(session:undo(), "undo the erase of B")
        t:check(page(session):find("500.0,500.0", 1, true) ~= nil, "B is back, found by key")
        t:check(session:redo(), "redo the erase")
        t:check(session:redo(), "redo C")
        t:eq(page(session), with_c, "same page as before")
        t:eq(#store.strokes[SURFACE.id], 2, "the store, unflushed since, still holds A and C")
    end)

    t:describe("ink_surface_session / replaceStrokes atomicity")

    local function snapshotAll(session)
        local q, bytes, next_local = queueState(session)
        return table.concat({ page(session), q, tostring(bytes), tostring(next_local),
            tostring(session.next_seq), tostring(session.history:entryCount()),
            tostring(session.history.pool.points) }, "#")
    end

    t:case("every refusal before publication leaves everything as it was", function()
        local session = fixture()
        local a = draw(session, { 100, 100, 200, 200 })
        local b = draw(session, { 300, 300, 400, 400 })
        local before = snapshotAll(session)
        local good = { points = { 1, 1, 2, 2 }, n = 2, width = 4, tool = 1 }
        local cases = {
            { "unknown key", { 999 }, { good } },
            { "duplicate removal", { a.key, a.key }, {} },
            { "stale version", { a.key }, { good }, { expect_versions = { [a.key] = 7 } } },
            { "out of page", { a.key }, { { points = { -1, 5, 2, 2 }, n = 2, width = 4, tool = 1 } } },
            { "NaN", { a.key }, { { points = { 0 / 0, 5 }, n = 1, width = 4, tool = 1 } } },
            { "infinite width", { a.key }, { { points = { 1, 5 }, n = 1, width = math.huge, tool = 1 } } },
            { "unknown style", { a.key }, { { points = { 1, 5 }, n = 1, width = 4, tool = 12345 } } },
            { "count beyond points", { a.key }, { { points = { 1, 5 }, n = 3, width = 4, tool = 1 } } },
            { "live key reused", {}, { { key = b.key, points = { 1, 5 }, n = 1, width = 4, tool = 1 } } },
            { "empty edit", {}, {} },
        }
        for _, c in ipairs(cases) do
            local res, err = session:replaceStrokes(c[2], c[3], c[4])
            t:eq(res, nil, c[1] .. " refused")
            t:check(err ~= nil, c[1] .. " names a reason")
            t:eq(snapshotAll(session), before, c[1] .. " changed nothing")
        end
    end)

    t:case("a batch over the queue's bounds is refused whole, never half-queued", function()
        local session = fixture{ queue_opts = { max_ops = 4, hard_ops = 5 } }
        local a = draw(session, { 100, 100, 200, 200 })
        session:flush()
        local before = snapshotAll(session)
        local specs = {}
        for i = 1, 6 do specs[i] = { points = { i * 10, 10 }, n = 1, width = 4, tool = 1 } end
        local res, err = session:replaceStrokes({ a.key }, specs)
        t:eq(res, nil, "refused")
        t:eq(err, "batch_too_large", "it could not fit even an empty queue")
        t:eq(snapshotAll(session), before, "nothing withdrawn, nothing queued")
    end)

    t:case("withdrawing a pending insert and failing later restores it exactly", function()
        local session = fixture()
        local a = draw(session, { 100, 100, 200, 200 })
        local before = snapshotAll(session)
        local res = session:replaceStrokes({ a.key }, {
            { points = { 10, 10 }, n = 1, width = 4, tool = 1 },
            { points = { -10, 10 }, n = 1, width = 4, tool = 1 },
        })
        t:eq(res, nil, "the second spec refused the batch")
        t:eq(snapshotAll(session), before, "the pending insert of A is still queued")
    end)

    t:case("a repaint failure after acceptance keeps the edit and blocks the surface", function()
        local session, _, sched = fixture()
        local a = draw(session, { 100, 100, 200, 200 })
        local cache = session:cache()
        local real = cache.repair
        cache.repair = function(self, box) self:_fail("chunk failed"); return nil, "chunk failed" end
        local res = session:replaceStrokes({ a.key }, { {
            key = a.key, version = 2, points = { 300, 300, 400, 400 }, n = 2,
            width = 4, tool = 1 } }, { label = "move" })
        t:check(res and res.accepted, "the edit was accepted")
        t:eq(res.repaint_error, "chunk failed", "and the repaint error is reported")
        t:eq(session:canUndo(), false, "the failed raster blocks further edits")
        t:check(session.history:canUndo(), "but the history kept the entry")
        cache.repair = real
        t:check(session:retryLoad(), "a rebuild from the accepted model")
        sched:drain()
        t:eq(session:isReady(), true, "ready again")
        t:check(page(session):find("300.0,300.0", 1, true) ~= nil, "showing the moved stroke")
        t:check(session:undo(), "and undo still reaches it by key")
        t:check(page(session):find("100.0,100.0", 1, true) ~= nil, "back where it was")
    end)

    t:case("a failed COMMIT keeps one pending edit to retry, never a repeated one", function()
        local session, store = fixture()
        local a = draw(session, { 100, 100, 200, 200 })
        session:flush()
        store.fail_transaction = "commit"
        local res = session:replaceStrokes({ a.key }, { {
            key = a.key, version = 2, points = { 300, 300, 400, 400 }, n = 2,
            width = 4, tool = 1 } }, { label = "move" })
        t:check(res and res.accepted, "accepted in memory")
        local ok = session:flush()
        t:eq(ok, nil, "the flush failed")
        t:eq(session:saveFailed(), true, "the surface says so")
        local r2, err = session:replaceStrokes({ a.key }, {}, {})
        t:eq(r2, nil, "further edits refused while unsaved")
        t:eq(err, "save_failed", "with the reason")
        store.fail_transaction = nil
        t:check(session:retrySave(), "retry")
        t:eq(#store.strokes[SURFACE.id], 1, "exactly one row: the move, not two")
        t:check(math.abs(store.strokes[SURFACE.id][1].points[1] - 300) < 0.05, "at the moved place")
    end)

    t:case("ensureCapacity flushes only when allowed, and never for an edit that cannot fit", function()
        local contact = true
        local session = fixture{
            queue_opts = { max_ops = 2, hard_ops = 3 },
            can_work = function() return not contact end,
        }
        draw(session, { 1, 1 }); draw(session, { 2, 2 }); draw(session, { 3, 3 })
        local spec = { points = { 5, 5 }, n = 1, width = 4, tool = 1 }
        local ok, err = session:ensureCapacity({}, { spec })
        t:eq(ok, nil, "no flush under a contact")
        t:eq(err, "contact_active", "with the reason")
        t:eq(session:pendingWrites(), 3, "the queue was not flushed")
        contact = false
        t:eq(session:ensureCapacity({}, { spec }), true, "flushed to make room")
        t:eq(session:pendingWrites(), 0, "flushed")
        local huge = {}
        for i = 1, 5 do huge[i] = spec end
        local no, why = session:ensureCapacity({}, huge)
        t:eq(no, nil, "a batch too large for any queue")
        t:eq(why, "batch_too_large", "is refused without I/O")
    end)

    t:describe("ink_surface_session / erase contact budget")

    t:case("a contact stops cutting at its budget, keeps its cuts and says so once", function()
        local session, _, _, history, notices = fixture{ queue_opts = { max_ops = 3, hard_ops = 4 } }
        for i = 1, 6 do draw(session, { i * 100, 100, i * 100, 300 }); session:flush() end
        session:flush()
        local before = page(session)
        local ctx = session:beginErase()
        for i = 1, 6 do session:eraseAt(i * 100, 200, 20, ctx) end
        session:endErase(ctx)
        t:eq(#notices, 1, "one notice")
        t:eq(notices[1], "erase_limit", "about the limit")
        local e = history:peekUndo()
        t:eq(e.label, "erase", "the accepted cuts are one entry")
        t:check(#e.before + #e.after <= 4, "its inverse fits the queue")
        t:check(#e.before >= 1, "some cuts were made")
        session:flush()
        t:check(session:undo(), "and undone as one")
        t:eq(page(session), before, "every cut stroke is whole again")
    end)

    t:case("an aborted contact still closes its group as an entry", function()
        local session, _, _, history = fixture()
        draw(session, { 100, 100, 300, 100 })
        local ctx = session:beginErase()
        session:eraseAt(200, 100, 18, ctx)
        -- The adapter's discard path ends the erase exactly like a lift.
        session:endErase(ctx)
        session:endErase(ctx)
        t:eq(history:peekUndo().label, "erase", "recorded once")
        t:eq(history:entryCount(), 2, "draw + erase, no duplicate")
    end)

    t:describe("ink_surface_session / pre-session ink")

    t:case("undo walks back into ink that existed before the session, and redo returns it", function()
        local session, _, _, history = fixture{ strokes = {
            { width = 4, tool = 1, n = 2, points = { 10, 10, 20, 20 } },
            { width = 4, tool = 1, n = 2, points = { 30, 30, 40, 40 } },
        } }
        local loaded = page(session)
        draw(session, { 500, 500, 600, 600 })
        t:check(session:undo(), "undo the session's own stroke")
        t:eq(page(session), loaded, "the page as loaded")
        t:eq(session:canUndo(), true, "the frontier is offered")
        t:check(session:undo(), "undo a pre-session stroke")
        t:check(not page(session):find("30.0,30.0", 1, true), "the newest loaded stroke went")
        t:check(session:redo(), "redo it")
        t:eq(page(session), loaded, "back")
        history:invalidate("history_stale")
        t:eq(session:canUndo(), false, "an invalidated history offers no fallback")
    end)

    t:describe("ink_surface_session / detach and re-attach")

    t:case("a history survives closing and reopening its page, keys by row", function()
        local store = support.newCanvasStore({ SURFACE })
        local pool = History.newPool()
        local h = History.new{ pool = pool }
        local s1 = fixture{ store = store, history = h }
        draw(s1, { 100, 100, 200, 200 })
        eraseLine(s1, 150, 150, nil, nil, 80)
        draw(s1, { 300, 300, 400, 400 })
        s1:flush()
        local state = page(s1)
        local detached = s1:detachHistory()
        t:eq(detached, h, "handed back")
        s1:close()
        local s2 = fixture{ store = store, history = h }
        t:eq(page(s2), state, "keys resolved to the same strokes")
        t:check(s2:undo(), "undo the second drawing")
        t:check(s2:undo(), "undo the erase")
        t:check(page(s2):find("100.0,100.0", 1, true) ~= nil, "the first stroke is back")
        t:check(s2:undo(), "undo the first drawing")
        t:eq(#s2:cache():strokes(), 0, "empty")
    end)

    t:case("a page that changed behind the history invalidates it and says so", function()
        local store = support.newCanvasStore({ SURFACE })
        local h = History.new()
        local s1 = fixture{ store = store, history = h }
        draw(s1, { 100, 100, 200, 200 })
        s1:flush()
        s1:detachHistory()
        s1:close()
        store:putStroke(SURFACE.id, { width = 4, tool = 1, n = 1, points = { 9, 9 } })
        local s2, _, _, _, notices = fixture{ store = store, history = h }
        t:eq(notices[1], "history_stale", "the owner is told")
        t:eq(h:canUndo(), false, "nothing to undo")
        t:eq(s2:canUndo(), false, "and no fallback removes ink")
        t:eq(#s2:cache():strokes(), 2, "no ink was removed")
        draw(s2, { 1, 1 })
        t:eq(s2:canUndo(), true, "later edits start a fresh history")
    end)

    t:case("a surface without a history keeps the legacy behaviour and no redo", function()
        local session = fixture{ history = false }
        draw(session, { 100, 100, 200, 200 })
        t:eq(session:canRedo(), false, "no redo")
        t:eq(session:redo(), nil, "redo does nothing")
        t:check(session:undo(), "legacy undo")
        local res, err = session:replaceStrokes({}, { { points = { 1, 1 }, n = 1, width = 4, tool = 1 } })
        t:eq(res, nil, "no replacement without a history")
        t:eq(err, "no_history", "named")
    end)

    t:case("scrubbing one stroke in one contact reserves exactly what its entry keeps", function()
        local session, _, sched, history = fixture()
        local pts = {}
        for i = 0, 60 do pts[#pts + 1] = 100 + i * 10; pts[#pts + 1] = 500 end
        draw(session, pts)
        sched:drain()
        local ctx = session:beginErase()
        -- Left to right, cutting the fragment the previous cut left behind.
        for x = 130, 640, 30 do session:eraseAt(x, 500, 6, ctx) end
        local g = ctx.group
        local live_after, live_before = {}, {}
        for i = 1, #g.after do if g.after[i] and g.after_at[g.after[i].key] == i then live_after[#live_after + 1] = g.after[i] end end
        for i = 1, #g.before do if g.before[i] and g.before_at[g.before[i].key] == i then live_before[#live_before + 1] = g.before[i] end end
        t:eq(g.after_count, #live_after, "the live fragment count is kept, not recounted")
        t:eq(g.before_count, #live_before, "and the originals'")
        local ap, ab = History.costOf(live_after)
        local bp, bb = History.costOf(live_before)
        t:eq(g.after_points, ap, "the group counts only fragments still alive")
        t:eq(g.after_bytes, ab, "in bytes too")
        t:eq(history.open_points, ap + bp, "and reserves exactly that many points")
        t:eq(g.limited, false, "so scrubbing does not hit the limit early")
        session:endErase(ctx)
        t:eq(history.open_points, 0, "the reservation is handed to the entry")
        t:check(session:undo(), "one undo")
        t:eq(#session:cache():strokes(), 1, "brings the whole stroke back")
    end)
end
