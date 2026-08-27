return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Controller = require("ink_notebook_controller")

    t:describe("ink_notebook_controller / lifecycle")

    t:case("repository opening is lazy", function()
        local opens = 0
        local store = support.newNotebookStore()
        local controller = Controller.new{
            repository_factory = function() opens = opens + 1; return store end,
        }
        t:eq(opens, 0, "constructor performs no I/O")
        t:eq(controller.repository, nil, "no handle retained")
        local rows = controller:listNotebooks()
        t:eq(#rows, 1, "listing works")
        t:eq(opens, 1, "opened on first operation")
        controller:listNotebooks()
        t:eq(opens, 1, "connection reused")
        controller:close()
        t:eq(store.closed, true, "owned connection closed")
    end)

    t:case("walking a clean library seeds maintenance only once", function()
        local store = support.newNotebookStore()
        local sched = support.newScheduler()
        local controller = Controller.new{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
        }
        for _ = 1, 100 do
            t:check(controller:listNotebooks() ~= nil, "metadata page loads")
        end
        t:eq(store.calls.purge, 0, "listing performs no synchronous writer work")
        sched:drain()
        t:eq(store.calls.purge, 1,
            "one clean maintenance probe covers the complete library walk")
    end)

    t:case("opening another notebook durably closes the previous session", function()
        local store = support.newNotebookStore()
        local second = store:createNotebook{
            title = "Second", logical_w = 1000, logical_h = 1400,
        }
        local controller = Controller.new{ repository = store }
        local first_session = controller:openNotebook(1)
        t:check(first_session ~= nil, "first opened")
        local second_session = controller:openNotebook(second.id)
        t:check(second_session ~= nil, "second opened")
        t:eq(first_session:stateName(), "closed", "first fully closed")
        t:eq(controller:activeSession(), second_session, "only second remains")
    end)

    t:case("a failed active flush does not close or replace the session", function()
        local store = support.newNotebookStore()
        local second = store:createNotebook{
            title = "Second", logical_w = 1000, logical_h = 1400,
        }
        local controller = Controller.new{ repository = store }
        local session = controller:openNotebook(1)
        session:surface():addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        store.fail_transaction = "commit"
        local opened = controller:openNotebook(second.id)
        t:eq(opened, nil, "replacement refused")
        t:eq(controller:activeSession(), session, "retryable session retained")
        store.fail_transaction = nil
        t:eq(controller:retrySave(), true, "recovered through controller")
    end)

    t:case("purge is one explicit batch and pauses for loading/contact", function()
        local store = support.newNotebookStore()
        local controller = Controller.new{ repository = store }
        t:check(controller:runOnePurgeBatch() ~= nil, "one batch ran")
        t:eq(store.calls.purge, 1, "not a loop")
        local session = controller:openNotebook(1)
        session.stateName = function() return "loading" end
        t:eq(controller:runOnePurgeBatch(), nil, "loading blocks purge")
        t:eq(store.calls.purge, 1, "still one batch")
    end)

    t:case("page changes invalidate library metadata through the controller", function()
        local store = support.newNotebookStore()
        local changes = 0
        local controller = Controller.new{
            repository = store,
            on_library_changed = function() changes = changes + 1 end,
        }
        local session = controller:openNotebook(1)
        t:eq(session:appendPage(), true, "page appended")
        t:eq(changes, 1, "library can refresh page count and recency")
    end)

    t:case("read-only delete leaves an active notebook open", function()
        local store = support.newNotebookStore()
        local controller = Controller.new{ repository = store }
        local session = controller:openNotebook(1)
        store.read_only = true
        local deleted, delete_err = controller:deleteNotebook(1)
        t:eq(deleted, nil, "delete rejected")
        t:eq(delete_err, "read_only", "stable reason")
        t:eq(controller:activeSession(), session, "view remains open")
        t:eq(session:stateName(), "ready", "active surface remains usable for viewing")
    end)

    t:case("UI callbacks are configured through the public seam", function()
        local store = support.newNotebookStore()
        local states, library = 0, 0
        local controller = Controller.new{ repository = store }
        t:eq(controller:configureInteraction{
            on_state_changed = function() states = states + 1 end,
            on_library_changed = function() library = library + 1 end,
        }, true, "configuration accepted before open")
        local session = controller:openNotebook(1)
        t:check(session ~= nil and states > 0, "state callback is wired")
        session:appendPage()
        t:check(library > 0, "library callback is wired")
        t:eq(controller:configureInteraction{ on_state_changed = function() end },
            nil, "live session cannot be rewired underneath its callbacks")
    end)

    t:case("the UI viewport applies to the first raster, not only resize", function()
        local calls = 0
        local controller = Controller.new{
            repository = support.newNotebookStore(),
            viewport_provider = function(session, _, notebook_id)
                calls = calls + 1
                t:eq(session, nil, "initial geometry precedes session construction")
                t:eq(notebook_id, 1, "provider knows the requested notebook")
                return { x = 20, y = 30, w = 500, h = 700 }
            end,
        }
        local session = controller:openNotebook(1)
        local transform = session and session:surface():transform()
        t:eq(calls, 1, "provider called during open")
        t:eq(transform and transform.fit_rect.w, 500, "chrome was excluded")
        t:eq(transform and transform.scale, 0.5, "first raster uses UI scale")
    end)

    t:case("purge continues one bounded batch per scheduler turn", function()
        local store = support.newNotebookStore()
        local remaining = 2
        function store:purgeDeletedBatch()
            self.calls.purge = self.calls.purge + 1
            if remaining > 0 then
                remaining = remaining - 1
                return { changed = 1 }
            end
            return { changed = 0 }
        end
        local sched = support.newScheduler()
        local controller = Controller.new{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
        }
        controller:schedulePurge()
        t:eq(store.calls.purge, 0, "no synchronous maintenance burst")
        sched:tick()
        t:eq(store.calls.purge, 1, "one batch on first turn")
        sched:drain()
        t:eq(store.calls.purge, 3, "resumed to a clean batch with yields")
        t:eq(controller.purge_requested, false, "cycle settled")
    end)

    t:case("a load failure wakes maintenance paused during first paint", function()
        local store = support.newNotebookStore()
        local sched = support.newScheduler()
        local controller = Controller.new{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
        }
        local session = controller:openNotebook(1)
        session.stateName = function() return "loading" end
        controller:schedulePurge()
        sched:drain()
        t:eq(store.calls.purge, 0, "loading page paused maintenance")
        t:eq(controller.purge_requested, true, "request was retained")
        session.stateName = function() return "load_failed" end
        session:_notifyState()
        sched:drain()
        t:eq(store.calls.purge, 1, "failed first paint released maintenance")
        t:eq(controller.purge_requested, false, "clean batch settled request")
    end)

    t:case("shutdown finishes its own already-deferred input release", function()
        local input = ctx.reset()
        local InputController = require("ink_input_controller")
        local controller = Controller.new{ repository = support.newNotebookStore() }
        local lease = InputController:acquire(controller, {
            backend = "stylus",
            stylus_handler = function() return true end,
            frame_handler = function(slots) return slots end,
        })
        t:check(lease ~= nil, "controller owns the process capture")
        lease:releaseDeferred()
        controller.active_session = {
            input_controller = InputController,
            shutdown = function() return true end,
        }
        t:eq(controller:shutdown(), true, "host teardown completes")
        t:eq(InputController:activeOwner(), nil, "owner is released before next tick")
        t:eq(input.stylus_callback, nil, "stylus callback is removed immediately")
        ctx.env.UIManager:flush()
        t:eq(InputController:activeOwner(), nil,
            "stale scheduled removal cannot resurrect ownership")
    end)
end
