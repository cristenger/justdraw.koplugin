return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Placement = require("ink_placement")
    local SurfaceSession = require("ink_surface_session")
    local History = require("ink_edit_history")
    local Transform = require("ink_canvas_transform")

    local SURFACE = { id = 93, logical_w = 1000, logical_h = 1400 }

    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore({ SURFACE })
        local sched = support.newScheduler()
        local transform = Transform.new{
            logical_w = SURFACE.logical_w, logical_h = SURFACE.logical_h,
            fit_rect = opts.fit or { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = opts.fit or { x = 0, y = 0, w = 1000, h = 1400 },
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
        local p = { id = 1, notices = {}, repaints = 0 }
        function p:session() return session end
        function p:transform() return transform end
        function p:identity() return self.id end
        function p:repaint() self.repaints = self.repaints + 1 end
        function p:presentCacheBox() end
        function p:setPainter(x) self.painter = x end
        function p:notify(text) self.notices[#self.notices + 1] = text end
        function p:budget() return true end
        local committed = {}
        local payload = opts.payload or {
            strokes = { { points = { 0, 0, 100, 0 }, n = 2, width = 4, tool = 1, group = 1 },
                { points = { 0, 20, 100, 20 }, n = 2, width = 4, tool = 1, group = 1 },
                { points = { 0, 40, 100, 40 }, n = 2, width = 4, tool = 1, group = 2 } },
            w = 100, h = 40,
        }
        local placement = Placement.new{
            presenter = p, kind = opts.kind or "paste",
            source = function() return payload end,
            schedule = function(d, fn) sched:scheduleIn(d, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            can_work = function() return not contact.down end,
            on_committed = function(kind) committed[#committed + 1] = kind end,
            layer_clear = support.recordingClear(),
        }
        return placement, session, p, sched, contact, committed
    end

    local function place(pl, contact, x, y, moves)
        contact.down = true
        local ok, err = pl:contactBegin(x, y)
        for _, m in ipairs(moves or {}) do pl:contactMove(m[1], m[2]) end
        pl:contactEnd()
        contact.down = false
        return ok, err
    end

    t:describe("ink_placement / placing")

    t:case("the payload appears centred on the pen, follows it and lands once, above the page", function()
        local pl, session, p, sched, contact, committed = fixture()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(pl:prepare(), true, "prepared before any contact")
        t:check(p.painter ~= nil, "the preview painter is in place")
        local ok = place(pl, contact, 300, 300, { { 400, 500 } })
        t:eq(ok, true, "placed")
        t:eq(pl.state, "pending", "commit waits for the lift")
        sched:advance(0.2)
        t:eq(committed[1], "paste", "committed once")
        local strokes = session:cache():strokes()
        t:eq(#strokes, 4, "three pasted strokes plus the page's own")
        local pasted = {}
        for _, m in ipairs(strokes) do if m.seq > 1 then pasted[#pasted + 1] = m end end
        t:check(math.abs(pasted[1].min_x - 350) < 0.02, "centred on where the pen lifted, x")
        t:check(math.abs(pasted[1].min_y - 480) < 0.02, "and y")
        t:check(pasted[1].paint_seq > strokes[1].paint_seq, "above the page's ink")
        t:eq(pasted[1].paint_seq, pasted[2].paint_seq, "one group stays one paint order")
        t:check(pasted[3].paint_seq > pasted[1].paint_seq, "and groups keep their order")
        t:check(session:undo(), "one undo")
        t:eq(#session:cache():strokes(), 1, "takes the whole placement back")
    end)

    t:case("the payload is clamped to the page at every edge", function()
        for _, c in ipairs({ { -500, 700 }, { 5000, 700 }, { 500, -500 }, { 500, 5000 } }) do
            local pl, session, _, sched, contact = fixture()
            pl:prepare()
            place(pl, contact, c[1], c[2])
            sched:advance(0.2)
            local m = session:cache():strokes()[1]
            t:check(m.min_x >= 0 and m.max_x <= 1000 and m.min_y >= 0 and m.max_y <= 1400,
                ("inside the page for %d,%d"):format(c[1], c[2]))
        end
    end)

    t:case("a payload larger than the page is refused, never shrunk", function()
        local pl, _, p = fixture{ payload = {
            strokes = { { points = { 0, 0, 1200, 0 }, n = 2, width = 4, tool = 1, group = 1 } },
            w = 1200, h = 0 } }
        local ok, err = pl:prepare()
        t:eq(ok, nil, "refused")
        t:eq(err, "too_large", "as too large")
        t:eq(#p.notices, 1, "and said so")
        t:eq(pl.state, "idle", "nothing left prepared")
    end)

    t:case("a stale preview refuses the contact and prepares again after it", function()
        local pl, _, p, sched, contact = fixture()
        pl:prepare()
        p.id = 2
        local ok, err = place(pl, contact, 300, 300)
        t:eq(ok, nil, "the contact is refused")
        t:eq(err, "not_ready", "because the preview is stale")
        sched:advance(0.2)
        t:eq(pl.state, "ready", "prepared again once the pen lifted")
    end)

    t:case("an aborted contact leaves nothing; a refused commit keeps the tool usable", function()
        local pl, session, p, sched, contact = fixture()
        pl:prepare()
        contact.down = true
        pl:contactBegin(300, 300)
        pl:contactAbort()
        contact.down = false
        sched:advance(0.2)
        t:eq(#session:cache():strokes(), 0, "aborted: nothing written")
        t:eq(pl.state, "ready", "ready for another try")
        local real = session.replaceStrokes
        session.replaceStrokes = function() return nil, "save_failed" end
        place(pl, contact, 300, 300)
        sched:advance(0.2)
        session.replaceStrokes = real
        t:eq(#session:cache():strokes(), 0, "refused: nothing written")
        t:eq(pl.state, "ready", "still ready")
        t:eq(#p.notices, 1, "told")
    end)

    t:case("cancelling drops the preview and any late job", function()
        local pl, session, p, sched, contact = fixture()
        pl:prepare()
        place(pl, contact, 300, 300)
        pl:cancel("tool")
        pl:cancel("tool")
        sched:advance(0.5)
        t:eq(#session:cache():strokes(), 0, "the pending commit never ran")
        t:eq(p.painter, nil, "no painter left")
        t:eq(pl.state, "idle", "idle")
    end)

    t:case("a scaled page with an origin places in canvas units", function()
        local pl, session, _, sched, contact = fixture{ fit = { x = 40, y = 60, w = 500, h = 700 } }
        pl:prepare()
        place(pl, contact, 500, 700)
        sched:advance(0.2)
        local m = session:cache():strokes()[1]
        t:check(math.abs(m.min_x - 450) < 0.02, "canvas x")
        t:check(math.abs(m.min_y - 680) < 0.02, "canvas y")
    end)
end
