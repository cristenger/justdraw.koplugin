return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Selection = require("ink_selection")
    local SurfaceSession = require("ink_surface_session")
    local History = require("ink_edit_history")
    local Transform = require("ink_canvas_transform")
    local Clipboard = require("ink_clipboard")

    local SURFACE = { id = 91, logical_w = 1000, logical_h = 1400 }

    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore({ SURFACE })
        local sched = support.newScheduler()
        local transform = Transform.new{
            logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
        }
        local contact = { down = false }
        local session = SurfaceSession.new{
            repository = store, surface = SURFACE, transform = transform,
            history = History.new(),
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(d, fn) sched:scheduleIn(d, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            can_work = function() return not contact.down end,
        }
        session:open()
        sched:drain()
        local p = { repaints = 0, boxes = {}, notices = {}, painter = nil, menu = nil, id = 1,
            session_obj = session, transform_obj = transform }
        function p:session() return self.session_obj end
        function p:transform() return self.transform_obj end
        function p:identity() return self.id end
        function p:repaint() self.repaints = self.repaints + 1 end
        function p:presentCacheBox(box) self.boxes[#self.boxes + 1] = box end
        function p:drawPath() end
        function p:setPainter(x) self.painter = x end
        function p:showMenu(frame, items)
            self.menu = items
            return { x = frame.x, y = frame.y - 40, w = 160, h = 40 }
        end
        function p:hideMenu() self.menu = nil end
        function p:paintMenu() end
        function p:notify(text) self.notices[#self.notices + 1] = text end
        function p:mmToPixels(mm) return mm * 8 end
        function p:budget() return true end
        local sel = Selection.new{
            presenter = p,
            schedule = function(d, fn) sched:scheduleIn(d, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            can_work = function() return not contact.down end,
            clock = function() return sched:now() end,
            clipboard = opts.clipboard,
            layer_clear = support.recordingClear(),
            turn_points = opts.turn_points,
            max_strokes = opts.max_strokes,
        }
        return sel, session, p, sched, contact, store
    end

    local function draw(session, points, tool, width)
        local id = assert(session:addStroke(points, #points / 2, width or 4, tool or 1))
        return session:cache():metaById(id) or session:cache():metaById(session.queue:realId(id))
    end

    --- A rectangular lasso, as pen samples, with the contact down meanwhile.
    local function lasso(sel, contact, x0, y0, x1, y1)
        contact.down = true
        t:eq(sel:contactBegin(x0, y0), true, "lasso starts")
        local pts = { { x1, y0 }, { x1, y1 }, { x0, y1 }, { x0, y0 + 1 } }
        for _, q in ipairs(pts) do sel:contactMove(q[1], q[2]) end
        sel:contactEnd()
        contact.down = false
    end

    local function drag(sel, contact, x, y, dx, dy)
        contact.down = true
        local ok = sel:contactBegin(x, y)
        sel:contactMove(x + dx / 2, y + dy / 2)
        sel:contactMove(x + dx, y + dy)
        sel:contactEnd()
        contact.down = false
        return ok
    end

    local function firstPoint(session, key)
        local m = session:metaByKey(key)
        local pts = session:cache():readPoints(m)
        return pts[1], pts[2]
    end

    t:describe("ink_selection / resolving")

    t:case("a lasso around a stroke selects it once the pen is up", function()
        local sel, session, p, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        draw(session, { 700, 700, 800, 700 })
        contact.down = true
        sel:contactBegin(150, 150)
        sel:contactMove(350, 150); sel:contactMove(350, 250); sel:contactMove(150, 250)
        sel:contactEnd()
        t:eq(sel.state, "resolving", "resolving after the logical end")
        sched:advance(1)
        t:eq(sel.state, "resolving", "nothing happens while the pen is still down")
        contact.down = false
        sched:advance(0.2)
        t:eq(sel.state, "selected", "selected once the contact is gone")
        t:eq(#sel.items, 1, "exactly the enclosed stroke")
        t:eq(sel.items[1].key, a.key, "by key")
        t:check(p.painter ~= nil, "the frame is painted")
        t:check(p.menu ~= nil, "the menu is shown")
    end)

    t:case("a tap or an empty lasso selects nothing", function()
        local sel, session, p, sched, contact = fixture()
        draw(session, { 200, 200, 300, 200 })
        contact.down = true
        sel:contactBegin(10, 10); sel:contactMove(11, 11); sel:contactEnd()
        contact.down = false
        t:eq(sel.state, "idle", "a tap is not a lasso")
        lasso(sel, contact, 600, 600, 900, 900)
        sched:advance(0.2)
        t:eq(sel.state, "idle", "nothing inside: idle")
        t:eq(p.painter, nil, "no painter left behind")
    end)

    t:case("resolving yields in bounded turns and a page change cancels it", function()
        local sel, session, p, sched, contact = fixture{ turn_points = 10 }
        for i = 1, 12 do draw(session, { 100 + i * 10, 200, 100 + i * 10, 260 }) end
        lasso(sel, contact, 50, 150, 400, 300)
        sched:tick()
        t:eq(sel.state, "resolving", "still resolving after one turn")
        p.id = 2  -- the page changed under it
        sched:advance(0.5)
        t:eq(sel.state, "idle", "a stale job ends the selection")
        t:eq(sel.items, nil, "and publishes nothing")
    end)

    t:case("too many strokes is refused with a notice", function()
        local sel, session, p, sched, contact = fixture{ max_strokes = 3 }
        for i = 1, 5 do draw(session, { 100 + i * 20, 200, 100 + i * 20, 260 }) end
        lasso(sel, contact, 50, 150, 400, 300)
        sched:advance(0.5)
        t:eq(sel.state, "idle", "refused")
        t:eq(#p.notices, 1, "told why")
    end)

    t:describe("ink_selection / moving")

    t:case("dragging moves the strokes once, keeps keys and paint order, and is one undo", function()
        local sel, session, p, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        local b = draw(session, { 200, 220, 300, 220 }, 1)
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        t:eq(#sel.items, 2, "both selected")
        local paint_a, paint_b = a.paint_seq, b.paint_seq
        t:eq(drag(sel, contact, 250, 210, 100, 50), true, "a drag inside the frame")
        t:eq(sel.state, "pending", "commit deferred to after the lift")
        sched:advance(0.2)
        t:eq(sel.state, "selected", "committed")
        local x, y = firstPoint(session, a.key)
        t:check(math.abs(x - 300) < 0.05 and math.abs(y - 250) < 0.05, "moved by the drag")
        t:eq(session:metaByKey(a.key).paint_seq, paint_a, "paint order kept")
        t:eq(session:metaByKey(b.key).paint_seq, paint_b, "for both")
        t:eq(session:metaByKey(a.key).version, 2, "a new version of the same key")
        t:check(session:undo(), "one undo")
        x, y = firstPoint(session, a.key)
        t:check(math.abs(x - 200) < 0.05, "back where it was")
        x = firstPoint(session, b.key)
        t:check(math.abs(x - 200) < 0.05, "both of them")
    end)

    t:case("moving twice, with a flush between, never accumulates rounding", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200.3, 200.7, 300.1, 200.2 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        drag(sel, contact, 250, 200, 10.37, 0)
        sched:advance(0.2)
        session:flush()
        drag(sel, contact, 260, 200, -10.37, 0)
        sched:advance(0.2)
        local x = firstPoint(session, a.key)
        local snapped = require("ink_canvas_codec").snap({ 200.3, 200.7 }, 1, 1000, 1400)
        t:eq(x, snapped[1], "back on exactly the stored point")
    end)

    t:case("a drag that quantises to no change records nothing and keeps redo", function()
        local sel, session, _, sched, contact = fixture()
        draw(session, { 200, 200, 300, 200 })
        draw(session, { 600, 600, 700, 600 })
        session:undo()
        t:eq(session:canRedo(), true, "a redo pending")
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        drag(sel, contact, 250, 200, 0.0001, 0)
        sched:advance(0.2)
        t:eq(sel.state, "selected", "still selected")
        t:eq(session:canRedo(), true, "redo survives a no-op move")
        t:eq(sel.masked, true, "the layer still stands in for the originals")
        t:eq(sel.drag_dx, 0, "at their own place")
        sel:clear("tool")
        t:eq(sel.masked, false, "and ending the selection shows them again")
    end)

    t:case("a drag is clamped to the page", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        drag(sel, contact, 250, 200, -5000, -5000)
        sched:advance(0.2)
        local x, y = firstPoint(session, a.key)
        t:eq(x, 0, "stopped at the left edge")
        t:eq(y, 0, "and the top")
    end)

    t:case("a COMMIT while lifted re-keys the masked strokes; the move still lands", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        t:check(a.id < 0, "still a pending insert")
        contact.down = true
        sel:contactBegin(250, 200)
        sel:contactMove(300, 250)
        t:eq(session:cache():isHidden(a), true, "lifted")
        contact.down = false
        session:flush()
        t:check(a.id > 0, "re-keyed by the COMMIT while lifted")
        contact.down = true
        sel:contactEnd()
        contact.down = false
        sched:advance(0.2)
        local x = firstPoint(session, a.key)
        t:check(math.abs(x - 250) < 0.05, "moved")
    end)

    t:case("the pen-down that starts a drag replays nothing: the mask is made at resolve", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        t:eq(session:cache():isHidden(a), true, "masked when the selection resolved")
        local hides, repairs = 0, 0
        local real_hide = session.hideStrokes
        session.hideStrokes = function(...) hides = hides + 1; return real_hide(...) end
        local cache = session:cache()
        local real_repair = cache.repair
        cache.repair = function(...) repairs = repairs + 1; return real_repair(...) end
        contact.down = true
        sel:contactBegin(250, 200)
        sel:contactMove(260, 210)
        t:eq(hides, 0, "no mask made under the pen")
        t:eq(repairs, 0, "and no raster repaired under it")
        sel:contactEnd()
        contact.down = false
        cache.repair = real_repair
        session.hideStrokes = real_hide
        sched:advance(0.2)
        t:eq(session:cache():isHidden(session:metaByKey(a.key)), true,
            "the moved stroke is masked again after the commit")
    end)

    t:case("a refused move puts the originals back, visible and in place", function()
        local sel, session, p, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        local real = session.replaceStrokes
        session.replaceStrokes = function() return nil, "queue_backpressure" end
        drag(sel, contact, 250, 200, 50, 50)
        sched:advance(0.2)
        session.replaceStrokes = real
        t:eq(sel.state, "selected", "back to selected")
        t:eq(session:cache():isHidden(a), true, "still masked while selected, drawn by the layer")
        t:eq(sel.drag_dx, 0, "put back in place")
        local x = firstPoint(session, a.key)
        t:check(math.abs(x - 200) < 0.05, "never moved")
        t:eq(#p.notices, 1, "and the reader was told")
    end)

    t:describe("ink_selection / ending")

    t:case("a rebuild clears the mask before the raster is replaced", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        draw(session, { 700, 700, 800, 700 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        contact.down = true
        sel:contactBegin(250, 200)
        sel:contactMove(260, 210)
        local metas_before = #session:cache():strokes()
        session:setTransform(Transform.new{
            logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
            fit_rect = { x = 0, y = 0, w = 500, h = 700 },
            clip_rect = { x = 0, y = 0, w = 500, h = 700 },
        })
        contact.down = false
        sched:drain()
        t:eq(sel.state, "idle", "cleared")
        t:eq(session:cache():isHidden(a), false, "nothing left hidden")
        t:eq(#session:cache():strokes(), metas_before, "no meta lost")
        t:eq(session:cache():stateName(), "ready", "rebuilt")
    end)

    t:case("clear from every state leaves nothing scheduled or painted", function()
        for _, reason in ipairs({ "tool", "page", "undo", "close", "suspend" }) do
            local sel, session, p, sched, contact = fixture()
            draw(session, { 200, 200, 300, 200 })
            lasso(sel, contact, 150, 150, 350, 260)
            sel:clear(reason)
            sched:advance(1)
            t:eq(sel.state, "idle", reason .. ": idle")
            t:eq(p.painter, nil, reason .. ": no painter")
            t:eq(p.menu, nil, reason .. ": no menu")
        end
    end)

    t:describe("ink_selection / copy, cut, delete")

    t:case("delete is one entry and undo brings the ink back", function()
        local sel, session, _, sched, contact = fixture()
        local a = draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        sel:delete()
        sched:advance(0.2)
        t:eq(sel.state, "idle", "done")
        t:eq(session:metaByKey(a.key), nil, "gone")
        t:check(session:undo(), "undo")
        t:check(session:metaByKey(a.key) ~= nil, "back")
    end)

    t:case("copy keeps an independent snapshot; cut publishes only when accepted", function()
        Clipboard.clear()
        local sel, session, _, sched, contact = fixture{ clipboard = Clipboard }
        draw(session, { 200, 200, 300, 200 })
        lasso(sel, contact, 150, 150, 350, 260)
        sched:advance(0.2)
        t:eq(sel:copy(), true, "copied")
        t:eq(Clipboard.hasContent(), true, "held")
        local first = Clipboard.payload(1)
        first.strokes[1].points[1] = 999
        t:eq(Clipboard.payload(1).strokes[1].points[1], 0, "a payload is a fresh copy")
        local real = session.replaceStrokes
        session.replaceStrokes = function() return nil, "save_failed" end
        Clipboard.set({ { points = { 5, 5 }, n = 1, width = 9, tool = 1 } }, { scale = 1 })
        sel:cut()
        sched:advance(0.2)
        session.replaceStrokes = real
        t:eq(Clipboard.payload(1).strokes[1].width, 9, "a refused cut left the old clipboard")
        t:eq(sel.state, "selected", "still selected")
        sel:cut()
        sched:advance(0.2)
        t:eq(Clipboard.payload(1).strokes[1].width, 4, "an accepted cut published")
        Clipboard.clear()
    end)
end
