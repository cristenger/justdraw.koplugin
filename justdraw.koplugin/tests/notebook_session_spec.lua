return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Session = require("ink_notebook_session")

    local function page(id, key)
        return { id = id, notebook_id = 1, sort_key = key,
            logical_w = 1000, logical_h = 1400, template_kind = "blank" }
    end

    local function fixture(opts)
        opts = opts or {}
        local pages = opts.pages or { page(11, 1024), page(12, 2048) }
        local store = support.newNotebookStore{ pages = pages }
        if opts.stroke_on then
            store:putStroke(opts.stroke_on, {
                width = 4, tool = 1, points = { 1, 1, 20, 20 }, n = 2,
            })
        end
        local sched = support.newScheduler()
        local input = { current = nil, contact = false, acquired = 0, released = 0 }
        function input:acquire(owner, spec)
            if self.current then return nil, "already_installed" end
            self.acquired = self.acquired + 1
            self.spec = spec
            local controller = self
            local lease = { owner = owner, active = true }
            function lease:hasActiveContact() return self.active and controller.contact end
            function lease:release()
                if not self.active then return true end
                self.active = false
                controller.current = nil
                controller.released = controller.released + 1
                return true
            end
            lease.releaseDeferred = lease.release
            self.current = lease
            return lease
        end
        local aborted = 0
        local session = Session.new{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
            input_controller = input,
            capture_spec = function() return { backend = "stylus" } end,
            abort_contact = function()
                aborted = aborted + 1
                input.contact = false
            end,
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
        }
        return session, store, sched, input, function() return aborted end
    end

    t:describe("ink_notebook_session / navigation gates")

    t:case("ordinal navigation preserves page ordering and durable selection", function()
        local session, store, sched, input = fixture{
            pages = { page(11, 1024), page(40, 4096), page(99, 8192) }, stroke_on = 99,
        }
        session:open(1)
        t:eq(session:uiSnapshot().page_position, 1, "first ordinal")
        local queries = store.calls.page_position
        for _ = 1, 100 do session:uiSnapshot() end
        session:flush()
        t:eq(store.calls.page_position, queries, "snapshots and ordinary flush do no ordinal SQL")
        t:eq(session:goToPagePosition(1), true, "same page is a no-op")
        t:eq(store.calls.page_at_position, 0, "same page needs no lookup")
        input.contact = true
        local ok, err = session:goToPagePosition(3)
        t:eq(ok, nil, "contact refuses jump")
        t:eq(err, "contact_active", "contact guard preserved")
        t:eq(store.calls.page_at_position, 0, "contact refused before lookup")
        input.contact = false
        t:eq(session:goToPagePosition(3), true, "direct jump accepted")
        t:eq(session:uiSnapshot().page_position, nil, "old ordinal hidden during loading")
        t:eq(store.notebooks[1].current_page_id, 11, "destination not yet durable")
        sched:drain()
        t:eq(session:currentPage().id, 99, "ID resolved from ordinal")
        t:eq(session:uiSnapshot().page_position, 3, "destination ordinal")
        t:eq(store.calls.page_at_position, 1, "one direct lookup")
        t:eq(session:goToPagePosition(2), true, "middle page")
        t:eq(session:softDeleteCurrentPage(), true, "middle removed")
        sched:drain()
        t:eq(session:uiSnapshot().page_count, 2, "two active pages")
        local actual = session:currentPage().id == 99 and 2 or 1
        t:eq(session:uiSnapshot().page_position, actual, "ordinal follows tombstone")
    end)

    t:case("ordinal errors keep readable ink and failed commits retain the old page", function()
        local session, store = fixture()
        store.fail_page_position = "read_error"
        session:open(1)
        t:eq(session:uiSnapshot().page_position, nil, "cosmetic fallback")
        t:eq(session:stateName(), "ready", "ink remains usable")
        store.fail_page_position = nil
        local surface = session:surface()
        store.fail_page_at_position = "read_error"
        t:eq(session:goToPagePosition(2), nil, "lookup failed")
        t:eq(session:surface(), surface, "old cache retained")
        store.fail_page_at_position = nil
        surface:addStroke({1, 1, 2, 2}, 2, 4, 1)
        store.fail_transaction = "commit"
        t:eq(session:goToPagePosition(2), nil, "commit failed")
        t:eq(session:surface(), surface, "old ink remains retryable")
        t:eq(store.notebooks[1].current_page_id, 11, "old durable selection")
        store.fail_transaction = nil
        t:eq(session:retrySave(), true, "save retry")
        t:eq(session:goToPagePosition(2), true, "jump after retry")
        t:eq(session:uiSnapshot().page_position, 2, "position recovered")
    end)

    t:case("ordinal jumps are read-only compatible and range checked", function()
        local session, store = fixture()
        store.read_only = true
        session:open(1)
        t:eq(session:goToPagePosition(2), true, "reading does not require writes")
        t:eq(session:uiSnapshot().page_position, 2, "readonly position")
        local queries = store.calls.page_at_position
        for _, bad in ipairs({ 0, -1, 3, 2.5, math.huge, 0/0, "2" }) do
            local ok, err = session:goToPagePosition(bad)
            t:eq(ok, nil, "invalid position")
            t:eq(err, "bad_position", "range reason")
        end
        t:eq(store.calls.page_at_position, queries, "invalid inputs perform no lookup")
    end)

    t:case("a failed ordinal destination stays unconfirmed until retry finishes", function()
        local session, store, sched = fixture{ stroke_on = 12 }
        session:open(1)
        store.fail_stroke_cursor = "broken destination"
        t:eq(session:goToPagePosition(2), true, "destination load started")
        sched:drain()
        t:eq(session:stateName(), "load_failed", "failure remains retryable")
        t:eq(session:uiSnapshot().page_position, nil, "no confirmed destination number")
        t:eq(store.notebooks[1].current_page_id, 11, "old durable page preserved")
        store.fail_stroke_cursor = nil
        t:eq(session:retryLoad(), true, "load retry")
        sched:drain()
        t:eq(session:uiSnapshot().page_position, 2, "ordinal confirmed after loading")
        t:eq(store.notebooks[1].current_page_id, 12, "then selection is durable")
    end)

    t:case("only the page that reaches ready becomes current on disk", function()
        local session, store, sched = fixture{ stroke_on = 12 }
        t:eq(session:open(1), true, "opened first page")
        t:eq(store.notebooks[1].current_page_id, 11, "first page persisted")
        t:eq(session:goToPage(12), true, "second load started")
        t:eq(session:stateName(), "loading", "not ready yet")
        t:eq(store.notebooks[1].current_page_id, 11, "old durable page retained")
        sched:drain()
        t:eq(session:stateName(), "ready", "load completed")
        t:eq(store.notebooks[1].current_page_id, 12, "then current persisted")
    end)

    t:case("a commit failure blocks page change, append and close", function()
        local session, store, _, input = fixture()
        session:open(1)
        local surface = session:surface()
        surface:addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        store.fail_transaction = "commit"
        t:eq(session:goNext(), nil, "navigation blocked")
        t:eq(session:currentPage().id, 11, "old page retained")
        t:eq(session:surface(), surface, "cache and queue retained")
        t:eq(session:appendPage(), nil, "append blocked")
        t:eq(session:close(), nil, "close blocked")
        store.fail_transaction = nil
        t:eq(session:retrySave(), true, "retry succeeds")
        t:check(input.current ~= nil, "capture resumes after durable recovery")
        t:eq(session:goNext(), true, "navigation resumes")
    end)

    t:case("a save failure with a contact still down aborts newer live input", function()
        local session, store, sched, input, aborted = fixture()
        session:open(1)
        session:surface():addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        input.contact = true
        store.fail_transaction = "commit"
        -- The queue's timer stands aside while a contact is live (ADR-42), so
        -- it never reaches the store here; a lifecycle gate is what still
        -- commits under the pen, and what surfaces the failure.
        sched:tick()
        t:eq(store.calls.transaction, 0, "the timer stood aside for the contact")
        t:eq((session:flush()), nil, "the lifecycle flush is what fails")
        t:eq(session:stateName(), "save_failed", "and the failure is visible")
        t:eq(aborted(), 1, "newer in-flight contact is repaired and retired")
        t:eq(input.contact, false, "no live contact survives inert capture")
        t:eq(input.current, nil, "failed session releases input ownership")
    end)

    t:case("rotation aborts an active contact before rebuilding capture", function()
        local session, _, _, input, aborted = fixture()
        session:open(1)
        input.contact = true
        local ok = session:onScreenResize(
            { x = 0, y = 0, w = 700, h = 1000 },
            { x = 0, y = 0, w = 700, h = 1000 })
        t:eq(ok, true, "rotation completed")
        t:eq(aborted(), 1, "incomplete stroke aborted")
        t:eq(input.contact, false, "contact state cleared")
        t:check(input.released >= 1, "old capture released")
        t:check(input.current ~= nil, "capture reacquired only for ready page")
    end)

    t:case("page deletion keeps one active page and refuses the last", function()
        local session, store = fixture()
        session:open(1)
        t:eq(session:softDeleteCurrentPage(), true, "current page deleted")
        t:eq(session:currentPage().id, 12, "neighbour opened")
        t:eq(store.notebooks[1].page_count, 1, "metadata updated")
        local result, err = session:softDeleteCurrentPage()
        t:eq(result, nil, "last page kept")
        t:eq(err, "last_page", "stable reason")
    end)

    t:case("load failure keeps a retry path and never acquires input", function()
        local session, store, sched, input = fixture{ stroke_on = 11 }
        store.fail_stroke_cursor = "broken chunk"
        session:open(1)
        sched:drain()
        t:eq(session:stateName(), "load_failed", "failure retained")
        t:eq(input.current, nil, "loading page cannot consume pen")
        store.fail_stroke_cursor = nil
        t:eq(session:retryLoad(), true, "retry scheduled")
        sched:drain()
        t:eq(session:stateName(), "ready", "recovered")
        t:check(input.current ~= nil, "input acquired after ready")
    end)

    t:case("failed destination load does not delete the previous current page", function()
        local session, store, sched = fixture{ stroke_on = 12 }
        session:open(1)
        store.fail_stroke_cursor = "broken destination"
        t:eq(session:softDeleteCurrentPage(), true, "destination load started")
        sched:drain()
        t:eq(session:stateName(), "load_failed", "destination failed")
        t:eq(store.notebooks[1].current_page_id, 11, "durable current stayed old")
        t:eq(session:flush(), nil, "SaveSettings cannot select an unreadable page")
        t:eq(session:close(), nil, "normal close preserves the load retry")
        t:eq(store.notebooks[1].current_page_id, 11, "flush still left durable current old")
        t:eq(store.pages[1].deleted_at, nil, "requested delete was not committed")
        t:eq(session:flush(), nil, "SaveSettings cannot commit the pending delete")
        t:eq(session:close(), nil, "normal close preserves delete/load retry")
        t:eq(store.pages[1].deleted_at, nil, "close did not tombstone readable page")
    end)

    t:case("current-page metadata failure retries before input returns", function()
        local session, store, sched, input = fixture{ stroke_on = 12 }
        session:open(1)
        store.fail_select_page = "state write failed"
        session:goToPage(12)
        sched:drain()
        t:eq(session:stateName(), "save_failed", "metadata write is a save gate")
        t:eq(input.current, nil, "pen remains paused")
        t:eq(session:goToPage(11), nil, "navigation cannot overwrite pending state")
        t:eq(session:appendPage(), nil, "append is gated by metadata")
        t:eq(session:flush(), nil, "SaveSettings reports metadata failure")
        t:eq(session:onScreenResize(
            { x = 0, y = 0, w = 900, h = 1200 },
            { x = 0, y = 0, w = 900, h = 1200 }), nil,
            "resize cannot rearm input through the gate")
        t:eq(input.current, nil, "capture remains paused")
        t:eq(session:close(), nil, "close preserves the retry path")
        t:eq(session:stateName(), "save_failed", "session remains recoverable")
        store.fail_select_page = nil
        t:eq(session:retrySave(), true, "metadata retry succeeds")
        t:eq(store.notebooks[1].current_page_id, 12, "new page is now durable")
        t:eq(session:uiSnapshot().page_position, 2, "metadata retry also refreshes ordinal")
        t:check(input.current ~= nil, "input resumes afterward")
    end)

    t:case("suspend aborts the in-flight contact and releases capture", function()
        local session, _, _, input, aborted = fixture()
        session:open(1)
        input.contact = true
        t:eq(session:onSuspend(), true, "suspend handled")
        t:eq(aborted(), 1, "contact aborted")
        t:eq(input.current, nil, "capture paused")
        t:eq(session:onResume(), true, "resume handled")
        t:check(input.current ~= nil, "capture restored after wake")
    end)

    t:case("a future-schema read-only page never captures input", function()
        local session, store, _, input = fixture()
        store.read_only = true
        t:eq(session:open(1), true, "metadata and raster remain readable")
        t:eq(session:stateName(), "ready", "page can still be viewed")
        t:eq(input.acquired, 0, "pen is not swallowed by a non-writable page")
    end)

    t:case("future-schema pages navigate in memory with no writes", function()
        local session, store, _, input = fixture()
        store.read_only = true
        store.fail_select_page = "read_only write attempted"
        session:open(1)
        t:eq(session:goNext(), true, "next page can be viewed")
        t:eq(session:currentPage().id, 12, "memory view advanced")
        t:eq(session:stateName(), "ready", "navigation did not become save_failed")
        t:eq(input.acquired, 0, "read-only navigation never captures pen")
        t:eq(store.calls.select_page, 0, "current page was not persisted")
        t:eq(session:appendPage(), nil, "append rejected before switching")
        t:eq(session:softDeleteCurrentPage(), nil, "delete rejected before switching")
        t:eq(session:currentPage().id, 12, "rejected edits preserve current view")
        t:eq(session:close(), true, "read-only view closes cleanly")
    end)

    t:case("an invalid destination transform leaves the old raster usable", function()
        local fail_page
        local session, _, _, input = fixture()
        session.transform_factory = function(page)
            if page.id == fail_page then return nil, "bad_geometry" end
            return require("ink_canvas_transform").new{
                logical_w = page.logical_w, logical_h = page.logical_h,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            }
        end
        session:open(1)
        local old_surface = session:surface()
        fail_page = 12
        local switched, switch_err = session:goToPage(12)
        t:eq(switched, nil, "switch refused")
        t:eq(switch_err, "bad_geometry", "real geometry error")
        t:eq(session:surface(), old_surface, "old raster retained")
        t:eq(session:stateName(), "ready", "old page remains usable")
        t:check(input.current ~= nil, "old capture never released")
    end)

    t:case("append and delete prevalidate destination geometry", function()
        local rejected = {}
        local session, store = fixture()
        session.transform_factory = function(page)
            if rejected[page.id] then return nil, "bad_geometry" end
            return require("ink_canvas_transform").new{
                logical_w = page.logical_w, logical_h = page.logical_h,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            }
        end
        session:open(1)
        local old_surface = session:surface()
        -- A prospective page has no id yet; geometry is rejected before SQL.
        session.transform_factory = function(page)
            if page.id == nil then return nil, "bad_geometry" end
            return require("ink_canvas_transform").new{
                logical_w = page.logical_w, logical_h = page.logical_h,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            }
        end
        t:eq(session:appendPage(), nil, "append load refused")
        t:eq(session:surface(), old_surface, "append kept old raster")
        t:eq(store.notebooks[1].page_count, 2, "no invisible page was inserted")
        session.transform_factory = function(page)
            if rejected[page.id] then return nil, "bad_geometry" end
            return require("ink_canvas_transform").new{
                logical_w = page.logical_w, logical_h = page.logical_h,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            }
        end
        rejected[12] = true
        t:eq(session:softDeleteCurrentPage(), nil, "delete switch refused")
        t:eq(session:surface(), old_surface, "delete kept old raster")
        t:eq(store.pages[1].deleted_at, nil, "old page was not tombstoned")
    end)

    t:case("disjoint viewport blocks open, resize and append", function()
        local unopened, unopened_store = fixture()
        unopened.clip_rect = { x = 2000, y = 0, w = 1000, h = 1400 }
        local opened, open_err = unopened:open(1)
        t:eq(opened, nil, "initial invisible page refused")
        t:eq(open_err, "bad_geometry", "open reports geometry")
        t:eq(unopened_store.notebooks[1].current_page_id, 11,
            "open performed no metadata write")

        local session, store, _, input = fixture()
        session:open(1)
        local old_surface = session:surface()
        local resized, resize_err = session:onScreenResize(
            { x = 0, y = 0, w = 1000, h = 1400 },
            { x = 2000, y = 0, w = 1000, h = 1400 })
        t:eq(resized, nil, "disjoint resize refused")
        t:eq(resize_err, "bad_geometry", "resize reports geometry")
        t:eq(session:surface(), old_surface, "old raster remains")
        t:check(input.current ~= nil, "old capture is restored")

        session.clip_rect = { x = 2000, y = 0, w = 1000, h = 1400 }
        local appended, append_err = session:appendPage()
        t:eq(appended, nil, "invisible append refused before SQL")
        t:eq(append_err, "bad_geometry", "append reports geometry")
        t:eq(store.notebooks[1].page_count, 2, "no page row was created")
    end)

    t:case("a failed input callback is explicit and retryable", function()
        local session, _, _, input = fixture()
        session:open(1)
        local dead = input.current
        dead.active = false
        input.current = nil
        input.spec.on_error("handler boom")
        t:eq(session:stateName(), "input_failed", "dead input is visible")
        t:eq(session.input_lease, nil, "dead lease reference cleared")
        t:eq(session:retryInput(), true, "input can be rearmed deliberately")
        t:check(input.current ~= nil, "new lease installed")
    end)

    t:case("a domain failure disarms input on a safe scheduled boundary", function()
        local session, _, sched, input, aborted = fixture()
        session:open(1)
        input.contact = true
        local lease = input.current
        function lease:releaseDeferred(after)
            self.active = false
            sched:schedule(function()
                input.current = nil
                input.released = input.released + 1
                after()
            end)
            return true
        end

        t:eq(session:failInputDeferred("operation_too_large"), true,
            "the expected domain error is accepted")
        t:eq(lease.active, false, "capture becomes inert immediately")
        t:eq(aborted(), 0, "adapter cleanup is outside the callback frame")
        t:eq(session:stateName(), "input_failed",
            "the explicit Retry input state is already latched")
        sched:drain()
        t:eq(aborted(), 1, "live input is repaired on the safe tick")
        t:eq(input.current, nil, "the global lease is released")
        t:eq(session.input_lease, nil, "the session drops the old lease")
        t:eq(session:retryInput(), true, "the user can rearm input explicitly")
    end)

    t:case("resume never retries a failed input handler implicitly", function()
        local session, _, _, input = fixture()
        session:open(1)
        input.current.active = false
        input.current = nil
        input.spec.on_error("handler boom")
        local acquired = input.acquired
        local resumed, resume_err = session:onResume()
        t:eq(resumed, nil, "resume preserves explicit failure")
        t:eq(resume_err, "handler boom", "original failure remains visible")
        t:eq(input.acquired, acquired, "no callback was reinstalled")
        t:eq(session:stateName(), "input_failed", "Retry Input remains available")
    end)

    t:case("navigation preserves input failure until explicit retry", function()
        local session, _, _, input = fixture()
        session:open(1)
        input.current.active = false
        input.current = nil
        input.spec.on_error("handler boom")
        local acquired = input.acquired
        t:eq(session:goNext(), true, "view navigation remains available")
        t:eq(session:currentPage().id, 12, "page changed")
        t:eq(session:stateName(), "input_failed", "failure survived page open")
        t:eq(input.acquired, acquired, "navigation did not reinstall callback")
        t:eq(session:appendPage(), true, "page creation remains available")
        t:eq(session:stateName(), "input_failed", "append also preserves failure")
        t:eq(input.acquired, acquired, "append did not reinstall callback")
        t:eq(session:retryInput(), true, "user can retry deliberately")
        t:eq(input.acquired, acquired + 1, "only explicit retry reacquired")
    end)

    t:case("forced shutdown never leaks input after a failed commit", function()
        local session, store, _, input = fixture()
        session:open(1)
        session:surface():addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        input.contact = true
        store.fail_transaction = "commit"
        t:eq(session:shutdown(), nil, "durability failure remains visible")
        t:eq(session:stateName(), "closed", "host resources are nevertheless closed")
        t:eq(input.current, nil, "global capture released")
        t:eq(session:surface(), nil, "retry-only raster discarded at host death")
    end)

    t:case("forced shutdown reports a current-page metadata failure", function()
        local session, store, sched, input = fixture{ stroke_on = 12 }
        session:open(1)
        store.fail_select_page = "state write failed"
        session:goToPage(12)
        sched:drain()
        local stopped, stop_err = session:shutdown()
        t:eq(stopped, nil, "metadata loss is not reported as a clean close")
        t:eq(stop_err, "state write failed", "original failure remains visible")
        t:eq(store.notebooks[1].current_page_id, 11, "durable page was not changed")
        t:eq(input.current, nil, "input was still released")
        t:eq(session:stateName(), "closed", "host resources were force-closed")
    end)

    t:case("UI snapshot is query-free and reflects cached capabilities", function()
        local session, store = fixture()
        local previous_calls, next_calls = 0, 0
        local previous, next_page = store.previousPage, store.nextPage
        function store:previousPage(page_)
            previous_calls = previous_calls + 1
            return previous(self, page_)
        end
        function store:nextPage(page_)
            next_calls = next_calls + 1
            return next_page(self, page_)
        end
        session:open(1)
        local before_previous, before_next = previous_calls, next_calls
        local snapshot = session:uiSnapshot()
        local second = session:uiSnapshot()
        t:eq(snapshot.state, "ready", "ready state")
        t:eq(snapshot.has_previous, false, "first-page flag cached")
        t:eq(snapshot.has_next, true, "next-page flag cached")
        t:eq(snapshot.page_count, 2, "page count is metadata")
        t:eq(snapshot.can_close, true, "healthy session can close")
        t:eq(snapshot.ordinal, nil, "no ordinal query contract")
        t:eq(previous_calls, before_previous, "snapshot did not query previous")
        t:eq(next_calls, before_next, "snapshot did not query next")
        t:check(snapshot ~= second, "each snapshot is a fresh table")
    end)

    t:case("destination load failure is not closeable but initial failure is", function()
        local initial, initial_store, initial_sched = fixture{ stroke_on = 11 }
        initial_store.fail_stroke_cursor = "broken initial"
        initial:open(1); initial_sched:drain()
        t:eq(initial:uiSnapshot().can_close, true, "initial failed load can return to library")

        local destination, store, sched = fixture{ stroke_on = 12 }
        destination:open(1)
        store.fail_stroke_cursor = "broken destination"
        destination:goNext(); sched:drain()
        t:eq(destination:uiSnapshot().can_close, false,
            "pending current-page metadata blocks close")
    end)

    t:case("a closed session never advertises another UI close action", function()
        local session = fixture()
        session:open(1)
        t:eq(session:close(), true, "session closed")
        t:eq(session:uiSnapshot().can_close, false, "closed capability is inert")
    end)

    --[[--
    Changing the paper is a rebuild, not an edit.

    The ruling is composed into the raster (ADR-27), so adopting a new one
    replays the page the way a rotation does -- and has to release and
    reacquire capture around it for the same reason, or a contact would go on
    writing into a buffer that no longer exists.
    ]]
    t:case("a new ruling is persisted and rebuilds through the capture gates", function()
        local session, store, sched, input = fixture()
        session:open(1)
        sched:drain()
        local released, acquired = input.released, input.acquired
        t:eq(session:setPageTemplate("dots"), true, "accepted")
        t:eq(store.pages[1].template_kind, "dots", "persisted")
        t:eq(input.released, released + 1, "capture released for the rebuild")
        sched:drain()
        t:eq(session:stateName(), "ready", "the raster came back")
        t:eq(input.acquired, acquired + 1, "and capture with it")
        t:eq(session:uiSnapshot().template_kind, "dots", "published to the UI")
        -- Idempotent: the same ruling is not a reason to throw a raster away.
        released = input.released
        t:eq(session:setPageTemplate("dots"), true, "same ruling accepted")
        t:eq(input.released, released, "and rebuilds nothing")
    end)

    t:case("a page added after a ruling change inherits it", function()
        local session, store, sched = fixture()
        session:open(1)
        sched:drain()
        session:setPageTemplate("ruled")
        sched:drain()
        t:eq(session:appendPage(), true, "appended")
        sched:drain()
        t:eq(session:currentPage().template_kind, "ruled", "inherited")
        t:eq(store.pages[#store.pages].template_kind, "ruled", "and persisted")
    end)

    t:case("a ruling change is refused for the reasons a rotation is", function()
        local session, store, sched, input = fixture()
        session:open(1)
        sched:drain()

        input.contact = true
        local ok, err = session:setPageTemplate("grid")
        t:eq(ok, nil, "refused under a live contact")
        t:eq(err, "contact_active", "with the reason the editor can act on")
        t:eq(store.pages[1].template_kind, "blank", "and nothing was written")
        input.contact = false

        session:surface():addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        store.fail_transaction = "commit"
        sched:drain()
        ok, err = session:setPageTemplate("grid")
        t:eq(ok, nil, "refused while a commit is broken")
        t:eq(err, "save_failed", "stable reason")
        t:eq(store.pages[1].template_kind, "blank", "still nothing written")
    end)

    t:case("a future-schema notebook keeps its ruling and refuses a new one", function()
        local session, store, sched = fixture()
        store.read_only = true
        session:open(1)
        sched:drain()
        local ok, err = session:setPageTemplate("dots")
        t:eq(ok, nil, "refused")
        t:eq(err, "read_only", "stable reason")
        t:eq(store.pages[1].template_kind, "blank", "nothing written")
    end)

    t:case("a rejected ruling leaves the page and its raster alone", function()
        local session, store, sched = fixture()
        session:open(1)
        sched:drain()
        store.fail_set_template = "not_found"
        local ok, err = session:setPageTemplate("dots")
        t:eq(ok, nil, "refused")
        t:eq(err, "not_found", "the repository's reason survives")
        t:eq(session:currentPage().template_kind, "blank", "page unchanged")
        t:eq(session:stateName(), "ready", "and the raster was never thrown away")
    end)

    t:case("input mode reconfiguration releases before reacquiring", function()
        local session, _, _, input = fixture()
        session:open(1)
        local acquired, released = input.acquired, input.released
        local applied = false
        t:eq(session:reconfigureInput(function() applied = true end), true,
            "reconfiguration succeeds")
        t:eq(applied, true, "setting applied between leases")
        t:eq(input.released, released + 1, "old callback released")
        t:eq(input.acquired, acquired + 1, "new callback acquired")
    end)
end
