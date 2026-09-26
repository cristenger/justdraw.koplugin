return function(ctx)
    local t = ctx.t
    local History = require("ink_edit_history")

    local W, H = 1000, 1400

    local function snap(key, points, opts)
        opts = opts or {}
        local s = assert(History.snapshot({
            key = key, version = opts.version or 1, points = points,
            n = #points / 2, width = opts.width or 4, tool = opts.tool or 1,
            paint_seq = opts.paint_seq,
        }, W, H))
        return s
    end

    t:describe("ink_edit_history / snapshots")

    t:case("a snapshot owns its points: mutating the caller's table changes nothing", function()
        local points = { 10, 20, 30, 40 }
        local s = snap(1, points)
        points[1], points[2] = 900, 900
        local back = History.points(s, W, H)
        t:check(math.abs(back[1] - 10) < 0.05 and math.abs(back[2] - 20) < 0.05,
            "the snapshot kept the recorded coordinates")
        back[1] = 500
        local again = History.points(s, W, H)
        t:check(math.abs(again[1] - 10) < 0.05, "each read is a fresh table")
    end)

    t:case("snapshots refuse out-of-page and non-finite points unless clamped", function()
        local s, err = History.snapshot({ key = 1, points = { -5, 10, 20, 20 }, n = 2,
            width = 4, tool = 1 }, W, H)
        t:eq(s, nil, "out of page refused")
        t:eq(err, "out_of_range", "with the reason")
        s = History.snapshot({ key = 1, points = { -5, 10, 20, 20 }, n = 2,
            width = 4, tool = 1 }, W, H, { clamp = true })
        t:check(s ~= nil, "clamped when recording existing ink")
        s, err = History.snapshot({ key = 1, points = { 0 / 0, 10 }, n = 1,
            width = 4, tool = 1 }, W, H, { clamp = true })
        t:eq(s, nil, "NaN refused even when clamping")
        s, err = History.snapshot({ key = 0, points = { 1, 1 }, n = 1,
            width = 4, tool = 1 }, W, H)
        t:eq(err, "bad_snapshot", "a key must be a positive integer")
        s, err = History.snapshot({ key = 1, points = { 1, 1 }, n = 1,
            width = -1, tool = 1 }, W, H)
        t:eq(err, "bad_snapshot", "a negative width is refused")
    end)

    t:describe("ink_edit_history / stacks")

    t:case("record, undo, redo move entries only when committed", function()
        local h = History.new()
        local a = snap(h:newKey(), { 1, 1, 2, 2 })
        t:eq(h:record{ label = "draw", before = {}, after = { a } }, true, "recorded")
        t:eq(h:canUndo(), true, "undo available")
        t:eq(h:canRedo(), false, "no redo yet")
        local e = h:peekUndo()
        t:eq(e.label, "draw", "peek returns the entry")
        e.after[1].width = 99
        t:eq(h:peekUndo().after[1].width, 4, "a peeked copy cannot reach the entry")
        t:eq(h:canRedo(), false, "peeking alone moves nothing (a refused undo keeps both stacks)")
        h:commitUndo()
        t:eq(h:canUndo(), false, "undo consumed")
        t:eq(h:canRedo(), true, "redo available")
        h:commitRedo()
        t:eq(h:canUndo(), true, "redo moved it back")
    end)

    t:case("an accepted edit clears redo; a refused one never reaches the history", function()
        local h = History.new()
        h:record{ before = {}, after = { snap(h:newKey(), { 1, 1 }) } }
        h:commitUndo()
        t:eq(h:canRedo(), true, "redo pending")
        h:record{ before = {}, after = { snap(h:newKey(), { 2, 2 }) } }
        t:eq(h:canRedo(), false, "a new accepted edit invalidates redo")
        local p = h.pool.points
        t:eq(p, 1, "the cleared redo gave its points back")
    end)

    t:case("entry and point limits evict the oldest and mark the history trimmed", function()
        local h = History.new{ max_entries = 3 }
        h:setFrontier({ 99 })
        for i = 1, 5 do
            h:record{ before = {}, after = { snap(h:newKey(), { i, i }) } }
        end
        t:eq(h:entryCount(), 3, "only the newest three kept")
        t:eq(h:isTrimmed(), true, "trimmed")
        for _ = 1, 3 do h:commitUndo() end
        t:eq(h:frontierKey(), nil, "a trimmed history no longer offers its frontier")

        local pool = History.newPool{ max_points = 10, max_bytes = 1e9 }
        local g = History.new{ pool = pool }
        for i = 1, 4 do
            local pts = {}
            for p = 1, 3 do pts[#pts + 1] = p; pts[#pts + 1] = i end
            t:eq(g:record{ before = {}, after = { snap(g:newKey(), pts) } }, true, "recorded " .. i)
        end
        t:eq(pool.points <= 10, true, "the pool never holds more than its points")
        t:eq(g:entryCount(), 3, "the oldest went to make room")
    end)

    t:case("an entry larger than the whole pool is refused before any edit", function()
        local pool = History.newPool{ max_points = 4, max_bytes = 1e9 }
        local h = History.new{ pool = pool }
        local big = {}
        for i = 1, 5 do big[#big + 1] = i; big[#big + 1] = i end
        local s = snap(h:newKey(), big)
        t:eq(h:admits(History.costOf({ s })), false, "admits says no")
        local ok, err = h:record{ before = {}, after = { s } }
        t:eq(ok, nil, "record refuses")
        t:eq(err, "entry_too_large", "with the reason")
        local r, rerr = h:reserveOpen(5, 10)
        t:eq(rerr, "entry_too_large", "an open group cannot grow past the pool either")
        t:eq(r, nil, "nothing reserved")
    end)

    t:case("a shared pool evicts idle histories before the active one", function()
        local pool = History.newPool{ max_points = 6, max_bytes = 1e9 }
        local idle = History.new{ pool = pool }
        idle:record{ before = {}, after = { snap(idle:newKey(), { 1, 1, 2, 2, 3, 3 }) } }
        local active = History.new{ pool = pool }
        active:record{ before = {}, after = { snap(active:newKey(), { 1, 1, 2, 2, 3, 3 }) } }
        active:record{ before = {}, after = { snap(active:newKey(), { 4, 4 }) } }
        t:eq(idle:entryCount(), 0, "the least recently used history paid first")
        t:eq(active:entryCount(), 2, "the active history kept its entries")
    end)

    t:case("the pool's resident count evicts whole histories", function()
        local pool = History.newPool{ max_histories = 2 }
        local a = History.new{ pool = pool }
        local b = History.new{ pool = pool }
        local c = History.new{ pool = pool }
        local evicted = pool:enforceCount(c)
        t:eq(#evicted, 1, "one history over the count")
        t:eq(evicted[1], a, "the least recently used")
        t:eq(a.released, true, "released")
        t:eq(b.released, false, "the others stay")
    end)

    t:describe("ink_edit_history / identity")

    t:case("detach and resolve hand keys back only for exactly the rows it knew", function()
        local h = History.new()
        h:detach({ [5] = { key = 1, version = 2 }, [9] = { key = 2, version = 1 } })
        local metas = { { id = 5 }, { id = 9 } }
        local map = h:resolve(metas)
        t:check(map ~= nil, "resolved")
        t:eq(map[metas[1]].key, 1, "row 5 is key 1")
        t:eq(map[metas[1]].version, 2, "with its version")
        t:eq(h.attached, true, "attached again")

        local g = History.new()
        g:detach({ [5] = { key = 1, version = 1 } })
        local stale, err = g:resolve({ { id = 5 }, { id = 6 } })
        t:eq(stale, nil, "an unknown row refuses the whole resolution")
        t:eq(err, "history_stale", "as stale")
        local k = History.new()
        k:detach({ [5] = { key = 1, version = 1 }, [6] = { key = 2, version = 1 } })
        t:eq(k:resolve({ { id = 5 } }), nil, "a missing row refuses it too")
    end)

    t:case("invalidation empties the history without offering a fallback", function()
        local h = History.new()
        h:setFrontier({ 1, 2 })
        h:record{ before = {}, after = { snap(h:newKey(), { 1, 1 }) } }
        h:invalidate("history_stale")
        t:eq(h:canUndo(), false, "no undo")
        t:eq(h:frontierKey(), nil, "no frontier fallback")
        t:eq(h.pool.points, 0, "memory released")
        h:record{ before = {}, after = { snap(h:newKey(), { 1, 1 }) } }
        t:eq(h:canUndo(), true, "later edits start a new history")
    end)

    t:case("the frontier is offered only once the session's own edits are undone", function()
        local h = History.new()
        h:setFrontier({ 1, 2 })
        t:eq(h:frontierKey(), 2, "newest pre-session stroke first")
        h:record{ before = {}, after = { snap(3, { 1, 1 }) } }
        t:eq(h:frontierKey(), nil, "not while a session edit is undoable")
        h:commitUndo()
        t:eq(h:frontierKey(), 2, "offered again")
        h:commitFrontierUndo(snap(2, { 5, 5 }))
        t:eq(h:frontierKey(), 1, "the frontier advanced")
        t:eq(h:canRedo(), true, "and the taken-back stroke can be redone")
    end)

    t:describe("ink_edit_history / residency")

    --[[--
    The byte budget is an estimate of what the tables and strings retain,
    not of the codec alone. Measure one full pool in this LuaJIT and hold
    the estimate to it: the pool's own count may not be below the heap
    growth by more than a small factor, or the budget would be fiction.
    ]]
    t:case("the pool's byte estimate tracks measured heap growth", function()
        collectgarbage("collect")
        local before = collectgarbage("count") * 1024
        local pool = History.newPool{ max_points = 200000, max_bytes = 64 * 1024 * 1024 }
        local h = History.new{ pool = pool, max_entries = 1000 }
        for e = 1, 200 do
            local pts = {}
            for p = 1, 200 do pts[#pts + 1] = (p * 3 + e) % 1000; pts[#pts + 1] = (p * 7) % 1400 end
            h:record{ before = {}, after = { snap(h:newKey(), pts) } }
        end
        collectgarbage("collect")
        local grown = collectgarbage("count") * 1024 - before
        t:check(pool.bytes > 0, "counted something")
        t:check(grown <= pool.bytes * 1.5, "measured growth " .. math.floor(grown)
            .. " B stays within 1.5x the estimate " .. pool.bytes .. " B")
        t:check(pool.bytes <= grown * 2, "and the estimate is not padded beyond 2x")
    end)
end
