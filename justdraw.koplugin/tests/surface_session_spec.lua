return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local SurfaceSession = require("ink_surface_session")
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
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
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
end
