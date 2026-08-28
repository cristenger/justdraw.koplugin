return function(ctx)
    local t = ctx.t
    local Editor = require("ink_notebook_editor")

    t:describe("standalone notebooks / editor window")

    local function newEditor(overrides)
        overrides = overrides or {}
        local runtime = overrides.runtime or { live_fast = true, active_contact = false }
        local snapshot = overrides.snapshot or {
            state = "ready", writable = true, can_ink = true,
            can_navigate = true, can_close = true,
            has_previous = false, has_next = true, page_count = 2,
            can_undo = true, pending_writes = 0,
        }
        local page = { id = 11, logical_w = 1184, logical_h = 1680 }
        local surface = {
            transform = function() return overrides.transform end,
            cache = function() return overrides.cache end,
            isReady = function() return overrides.cache ~= nil end,
        }
        local session = {
            currentPage = function() return page end,
            surface = function() return surface end,
        }
        local controller = { close_ok = true, calls = {} }
        function controller:activeSession() return session end
        function controller:uiSnapshot() return snapshot end
        function controller:closeNotebook()
            self.calls[#self.calls + 1] = "close"
            return self.close_ok and true or nil, self.close_ok and nil or "commit_failed"
        end
        function controller:undo() self.calls[#self.calls + 1] = "undo"; return {} end
        function controller:goPrevious() self.calls[#self.calls + 1] = "previous"; return true end
        function controller:goNext() self.calls[#self.calls + 1] = "next"; return true end
        function controller:appendPage() self.calls[#self.calls + 1] = "add"; return true end
        function controller:deleteNotebook()
            self.calls[#self.calls + 1] = "delete_notebook"
            return self.delete_ok ~= false and true or nil,
                self.delete_ok ~= false and nil or "commit_failed"
        end
        function controller:onScreenResize() self.calls[#self.calls + 1] = "resize"; return true end
        local closed = 0
        local guard = overrides.guard
        local scheduler = overrides.scheduler or ctx.support.newScheduler()
        local editor = Editor:new{
            controller = controller,
            notebook = { id = 1, title = "Notes", page_count = 2 },
            get_rail_side = function() return overrides.side or "right" end,
            set_rail_side = function() end,
            get_eraser = function() return false end,
            set_eraser = function() end,
            get_live_fast = function() return runtime.live_fast end,
            has_active_contact = function() return runtime.active_contact end,
            quality_schedule_in = function(delay, action)
                scheduler:scheduleIn(delay, action)
            end,
            quality_unschedule = function(action) scheduler:unschedule(action) end,
            control_touch_allowed = function() return guard ~= false end,
            show_host_message = overrides.show_host_message,
            show_stylus_diagnostics = overrides.show_stylus_diagnostics,
            on_close = function() closed = closed + 1 end,
        }
        return editor, controller, snapshot, function() return closed end, session,
            runtime, scheduler
    end

    t:case("paper, rail and input regions stay separate", function()
        ctx.reset()
        local editor = newEditor()
        local rail = editor.layout_geometry.rail_rect
        local paper = editor.layout_geometry.paper_rect
        t:check(paper.x + paper.w <= rail.x or rail.x + rail.w <= paper.x,
            "paper and rail do not overlap")
        t:eq(editor:stylusPassthrough(rail.x + 1, rail.y + 1), true,
            "stylus passes through rail")
        t:eq(editor:stylusPassthrough(paper.x + 1, paper.y + 1), false,
            "stylus stays captured on paper")
    end)

    t:case("palm guard blocks control touch without changing stylus geometry", function()
        ctx.reset()
        local editor = newEditor{ guard = false }
        local rail = editor.layout_geometry.rail_rect
        t:eq(editor:touchPassthrough(rail.x + 1, rail.y + 1), false,
            "guard blocks a finger on controls")
        t:eq(editor:stylusPassthrough(rail.x + 1, rail.y + 1), true,
            "pen classification is unchanged")
    end)

    t:case("More exposes English stylus diagnostics after closing itself", function()
        ctx.reset()
        local calls, uncovered = 0, false
        local editor
        editor = newEditor{
            show_stylus_diagnostics = function()
                calls = calls + 1
                uncovered = editor.modal_widget == nil
            end,
        }
        local dialog = editor:showMore()
        local diagnostic
        for i = 1, #dialog.buttons do
            local button = dialog.buttons[i][1]
            if button.text == "Stylus diagnostics" then diagnostic = button end
        end
        t:check(diagnostic ~= nil, "diagnostics is reachable from fullscreen editor")
        diagnostic.callback()
        t:eq(calls, 1, "shared diagnostics callback invoked once")
        t:eq(uncovered, true, "More closed before the privacy flow begins")
    end)

    t:case("save failure publishes a band without changing paper fit", function()
        ctx.reset()
        local snapshot = {
            state = "save_failed", writable = true, can_ink = false,
            can_navigate = false, can_close = false,
            has_previous = false, has_next = false, page_count = 2,
            can_undo = false, pending_writes = 1, error_code = "page_save_failed",
        }
        local editor = newEditor{ snapshot = snapshot }
        local before = editor.layout_geometry.fit_rect:copy()
        editor:onStateChanged()
        local after = editor.layout_geometry.fit_rect
        t:check(editor.interactive_regions.error_band ~= nil, "error region published")
        t:eq(after.x, before.x, "fit x unchanged")
        t:eq(after.y, before.y, "fit y unchanged")
        t:eq(after.w, before.w, "fit width unchanged")
        t:eq(after.h, before.h, "fit height unchanged")
    end)

    t:case("visual close never bypasses the durable domain gate", function()
        ctx.reset()
        local editor, controller, _, closed = newEditor()
        controller.close_ok = false
        t:eq(editor:requestClose(), nil, "failed commit blocks close")
        t:eq(closed(), 0, "window stayed open")
        controller.close_ok = true
        t:eq(editor:requestClose(), true, "durable close succeeds")
        t:eq(closed(), 1, "window closes after domain success")
    end)

    t:case("a failed notebook delete reports through the uncovered host", function()
        ctx.reset()
        local host_message
        local editor, controller = newEditor{
            show_host_message = function(text) host_message = text end,
        }
        controller.delete_ok = false
        editor.on_close = function(window) window:shutdown() end
        local box = editor:confirmDeleteNotebook()
        box.ok_callback()
        t:eq(editor.closed, true, "the successfully closed session leaves the editor")
        t:eq(controller.calls[1], "close", "session closes before deletion")
        t:eq(controller.calls[2], "delete_notebook", "delete is attempted once")
        t:eq(host_message, "Couldn’t delete this notebook. Try again.",
            "the library host receives the actionable failure")
    end)

    t:case("modal passthrough is published before the dialog is shown", function()
        ctx.reset()
        local editor = newEditor()
        local observed
        local old_show = ctx.env.UIManager.show
        ctx.env.UIManager.show = function(manager, widget)
            observed = editor.interactive_regions.modal ~= nil
            old_show(manager, widget)
        end
        local widget = { handleEvent = function() return true end }
        editor:showModalSafely(widget)
        ctx.env.UIManager.show = old_show
        t:eq(observed, true, "full-screen guard preceded show")
    end)

    t:case("informational messages use the same full-screen input guard", function()
        ctx.reset()
        local editor = newEditor()
        local info = editor:_showInfo("Lift the pen and try again.")
        t:check(info ~= nil, "message is shown")
        t:check(editor.interactive_regions.modal ~= nil,
            "message publishes the modal region")
        local paper = editor.layout_geometry.paper_rect
        t:eq(editor:stylusPassthrough(paper.x + 1, paper.y + 1), true,
            "stylus cannot ink under the message")
        editor:shutdown()
    end)

    t:case("rotation republishes a visible modal over the new screen", function()
        ctx.reset()
        local editor = newEditor()
        local widget = { handleEvent = function() return true end }
        editor:showModalSafely(widget)
        local screen = ctx.env.Device.screen
        local old_w, old_h = screen.w, screen.h
        screen.w, screen.h = 800, 600
        t:eq(editor:onSetDimensions(), true, "editor accepts rotated geometry")
        t:eq(editor.interactive_regions.modal.w, 800, "modal guard uses new width")
        t:eq(editor.interactive_regions.modal.h, 600, "modal guard uses new height")
        t:eq(editor:stylusPassthrough(700, 500), true,
            "stylus cannot draw behind the rotated modal")
        screen.w, screen.h = old_w, old_h
        editor:shutdown()
    end)

    t:case("an external top-level dialog guards the complete paper", function()
        ctx.reset()
        local editor = newEditor()
        ctx.env.UIManager:show(editor)
        editor:markShown()
        local paper = editor.layout_geometry.paper_rect
        t:eq(editor:stylusPassthrough(paper.x + 1, paper.y + 1), false,
            "paper is captured while the editor is topmost")
        local external = { handleEvent = function() return true end }
        ctx.env.UIManager:show(external)
        t:eq(editor:stylusPassthrough(paper.x + 1, paper.y + 1), true,
            "an unowned dialog dynamically guards the paper")
        t:eq(editor:touchPassthrough(paper.x + 1, paper.y + 1), true,
            "the dialog can also receive touch")
        ctx.env.UIManager:close(external)
        t:eq(editor:stylusPassthrough(paper.x + 1, paper.y + 1), false,
            "closing the dialog restores paper capture")
        editor:shutdown()
        ctx.env.UIManager:close(editor)
    end)

    t:case("shutdown closes a top-level modal before releasing the editor", function()
        ctx.reset()
        local editor = newEditor()
        ctx.env.UIManager:show(editor)
        editor:markShown()
        local widget = { handleEvent = function() return true end }
        editor:showModalSafely(widget)
        t:eq(#ctx.env.UIManager._window_stack, 2, "editor and modal are shown")
        editor:shutdown()
        t:eq(#ctx.env.UIManager._window_stack, 1, "modal is removed")
        t:eq(ctx.env.UIManager._window_stack[1].widget, editor,
            "only the coordinator-owned editor remains")
        ctx.env.UIManager:close(editor)
    end)

    t:case("modal teardown schedules no callback that retains the editor", function()
        ctx.reset()
        local editor = newEditor()
        local modal = { handleEvent = function() return true end }
        editor:showModalSafely(modal)
        local old_close = ctx.env.UIManager.close
        ctx.env.UIManager.close = function(manager, widget, ...)
            if widget.onCloseWidget then widget:onCloseWidget() end
            return old_close(manager, widget, ...)
        end
        local before = #ctx.env.UIManager._queue
        editor:shutdown()
        ctx.env.UIManager.close = old_close
        t:eq(#ctx.env.UIManager._queue, before,
            "CloseWidget cleanup is synchronous during shutdown")
    end)

    t:case("nested validation messages keep the underlying dialog guarded", function()
        ctx.reset()
        local editor = newEditor()
        local dialog = { handleEvent = function() return true end }
        editor:showModalSafely(dialog)
        local info = editor:_showInfo("Notebook name can’t be empty.")
        t:check(editor.interactive_regions.modal ~= nil, "nested message is guarded")
        editor:_closeModal(info)
        t:check(editor.interactive_regions.modal ~= nil,
            "closing the message keeps the dialog guard")
        t:eq(editor.modal_widget, dialog, "underlying dialog becomes current again")
        editor:shutdown()
        t:eq(next(editor.modal_widgets), nil, "shutdown closes the complete modal stack")
    end)

    t:case("failed rotation keeps the new window envelope", function()
        ctx.reset()
        local editor, controller = newEditor()
        editor:markShown()
        function controller:onScreenResize() return nil, "commit_failed" end
        local screen = ctx.env.Device.screen
        local old_w, old_h = screen.w, screen.h
        screen.w, screen.h = 800, 600
        local ok, err = editor:onSetDimensions()
        t:eq(ok, nil, "durable failure is preserved")
        t:eq(err, "commit_failed", "failure reason is preserved")
        t:eq(editor.dimen.w, 800, "window keeps the rotated width")
        t:eq(editor.dimen.h, 600, "window keeps the rotated height")
        t:eq(editor.ges_events.Tap[1].range.w, 800,
            "gesture envelope also uses the new Screen")
        screen.w, screen.h = old_w, old_h
        editor:shutdown()
    end)

    t:case("retry save reapplies a resize that failed at the durable gate", function()
        ctx.reset()
        local snapshot = {
            state = "save_failed", writable = true, can_ink = false,
            can_navigate = false, can_close = false,
            has_previous = false, has_next = false, page_count = 2,
            can_undo = false, pending_writes = 1, error_code = "page_save_failed",
        }
        local editor, controller = newEditor{ snapshot = snapshot }
        editor:markShown()
        local resize_calls = 0
        function controller:onScreenResize()
            resize_calls = resize_calls + 1
            if resize_calls == 1 then return nil, "commit_failed" end
            return true
        end
        function controller:retrySave()
            snapshot.state = "ready"
            snapshot.error_code = nil
            snapshot.can_ink = true
            snapshot.can_navigate = true
            snapshot.can_close = true
            snapshot.pending_writes = 0
            return true
        end
        t:eq(editor:onSetDimensions(), nil, "first resize stops at failed save")
        t:check(editor.pending_resize ~= nil, "new geometry is retained for retry")
        local dirty_before_retry = #ctx.env.UIManager.dirty
        t:eq(editor:retryError(), true, "retry commits and reapplies geometry")
        t:eq(resize_calls, 2, "resize is retried exactly once")
        t:eq(editor.pending_resize, nil, "successful retry clears pending geometry")
        local full = 0
        for i = dirty_before_retry + 1, #ctx.env.UIManager.dirty do
            if ctx.env.UIManager.dirty[i][2] == "full" then full = full + 1 end
        end
        t:eq(full, 1, "same-scale retry still finishes with one full refresh")
        editor:shutdown()
    end)

    t:case("rotation schedules exactly one full repaint", function()
        ctx.reset()
        local editor, controller = newEditor()
        editor:markShown()
        function controller:onScreenResize()
            editor:onPageReady()
            return true
        end
        local before = #ctx.env.UIManager.dirty
        t:eq(editor:onSetDimensions(), true, "rotation succeeds")
        local full = 0
        for i = before + 1, #ctx.env.UIManager.dirty do
            if ctx.env.UIManager.dirty[i][2] == "full" then full = full + 1 end
        end
        t:eq(full, 1, "synchronous ready and resize are coalesced")
        editor:shutdown()
    end)

    t:case("minimizing an error repaints the entire uncovered band", function()
        ctx.reset()
        local snapshot = {
            state = "save_failed", writable = true, can_ink = false,
            can_navigate = false, can_close = false,
            has_previous = false, has_next = false, page_count = 2,
            can_undo = false, pending_writes = 1, error_code = "page_save_failed",
        }
        local editor = newEditor{ snapshot = snapshot }
        editor:onStateChanged()
        editor:markShown()
        local old = editor.interactive_regions.error_band:copy()
        editor.layout[#editor.layout][1].callback()
        local dirty = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][3]
        t:eq(dirty.y, old.y, "dirty begins at the expanded band")
        t:eq(dirty.h, old.h, "dirty clears all formerly covered pixels")
        editor:shutdown()
    end)

    t:case("an edit repaints the rail only when Undo availability changes", function()
        ctx.reset()
        local editor, _, snapshot, _, session = newEditor()
        editor:markShown()
        local before = #ctx.env.UIManager.dirty
        editor:onEditChanged(session)
        local edit_dirty = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(#ctx.env.UIManager.dirty, before + 1, "edit schedules one repaint")
        t:eq(edit_dirty[1], nil, "rail pixels are not repainted through the editor")
        t:eq(edit_dirty[2], "ui", "control labels use UI refresh")
        t:eq(edit_dirty[3], editor.layout_geometry.rail_rect,
            "only the rail is sent to the panel")
        local controls = editor.control_entries
        local after_edit = #ctx.env.UIManager.dirty
        editor:onEditChanged(session)
        t:eq(#ctx.env.UIManager.dirty, after_edit,
            "a later stroke with Undo already enabled schedules no repaint")
        t:eq(editor.control_entries, controls,
            "a later stroke does not rebuild controls")
        snapshot.pending_writes = 0
        editor:onDurableChanged(session)
        t:eq(#ctx.env.UIManager.dirty, after_edit,
            "commit without a visible status change schedules no repaint")
    end)

    t:case("fast ink cleans one exact union after 350 ms of inactivity", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local buffer = { w = 1000, h = 1400 }
        local cache = { buffer = function() return buffer end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        local before = #ctx.env.UIManager.dirty
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 30 },
            "ink", session, transform, { x = 10, y = 20, w = 20, h = 30 })
        editor:onDirty(Geom:new{ x = 130, y = 240, w = 10, h = 10 },
            "ink", session, transform, { x = 40, y = 60, w = 10, h = 10 })
        local refresh = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(#ctx.env.UIManager.dirty, before + 2, "one refresh per segment is queued")
        t:eq(refresh[1], nil, "editor is not marked for repaint")
        t:eq(refresh[2], "fast", "live ink keeps the fast waveform")
        t:eq(refresh[3].x, 130, "the exact second region starts at x")
        t:eq(refresh[3].y, 240, "the exact second region starts at y")
        editor:onEditChanged(session)
        t:eq(editor.quality_strokes, 1, "segments count as one completed contact")
        t:eq(scheduler:pending(), 1, "one delayed cleanup is armed")
        scheduler:advance(0.349)
        t:eq(#ctx.env.UIManager.dirty, before + 2, "cleanup does not fire early")
        scheduler:advance(0.001)
        local cleanup = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(cleanup[1], nil, "cleanup never repaints the editor")
        t:eq(cleanup[2], "partial", "cleanup uses the quality waveform")
        t:eq(cleanup[3].x, 100, "union keeps its left edge")
        t:eq(cleanup[3].y, 200, "union keeps its top edge")
        t:eq(cleanup[3].w, 40, "union spans both segments")
        t:eq(cleanup[3].h, 50, "union spans both segments vertically")
    end)

    t:case("live-fast off uses partial for ink and eraser with no cleanup", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = false, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        local before = #ctx.env.UIManager.dirty
        for i, kind in ipairs({ "ink", "erase" }) do
            editor:onDirty(Geom:new{ x = 100 + i * 20, y = 200, w = 10, h = 10 },
                kind, session, transform, { x = i * 20, y = 20, w = 10, h = 10 })
        end
        t:eq(#ctx.env.UIManager.dirty, before + 2, "each live dirty is refreshed")
        t:eq(ctx.env.UIManager.dirty[before + 1][2], "partial",
            "ink follows the disabled fast setting")
        t:eq(ctx.env.UIManager.dirty[before + 2][2], "partial",
            "eraser follows the disabled fast setting")
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 0, "partial mode arms no quality cleanup")
        t:eq(editor:_qualityHasUnion(), false, "partial mode retains no fast union")
    end)

    t:case("repair and undo absorb a pending fast union immediately", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        local function dirty(kind, x, y)
            editor:onDirty(Geom:new{ x = x, y = y, w = 20, h = 20 },
                kind, session, transform, { x = x - 80, y = y - 180, w = 20, h = 20 })
        end

        dirty("ink", 100, 200)
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "ink first arms delayed cleanup")
        dirty("repair", 140, 230)
        local repair = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(repair[2], "partial", "repair is never sent as fast")
        t:eq(repair[3].x, 100, "repair absorbs the old union left edge")
        t:eq(repair[3].y, 200, "repair absorbs the old union top edge")
        t:eq(repair[3].w, 60, "repair covers the old and new pixels")
        t:eq(repair[3].h, 50, "repair covers the old and new pixels vertically")
        t:eq(scheduler:pending(), 0, "repair cancels the obsolete timer")
        t:eq(editor:_qualityHasUnion(), false, "repair consumes the union")

        dirty("erase", 200, 260)
        editor:onEditChanged(session)
        dirty("undo", 240, 280)
        local undo = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(undo[2], "partial", "undo is never sent as fast")
        t:eq(undo[3].x, 200, "undo includes prior eraser residue")
        t:eq(undo[3].w, 60, "undo spans the complete destructive region")
        t:eq(scheduler:pending(), 0, "undo leaves no delayed cleanup")
    end)

    t:case("changing live-fast at runtime cleans once and starts fresh", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 20 },
            "ink", session, transform, { x = 10, y = 20, w = 20, h = 20 })
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "fast mode has one pending cleanup")

        runtime.live_fast = false
        editor:onEditChanged(session)
        local transition = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(transition[2], "partial", "turning fast off cleans the old union")
        t:eq(transition[3].x, 100, "the transition cleans only old pixels")
        t:eq(scheduler:pending(), 0, "turning fast off cancels the timer")
        editor:onDirty(Geom:new{ x = 180, y = 240, w = 20, h = 20 },
            "ink", session, transform, { x = 90, y = 60, w = 20, h = 20 })
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "subsequent live ink is partial")

        runtime.live_fast = true
        editor:onEditChanged(session)
        editor:onDirty(Geom:new{ x = 300, y = 300, w = 10, h = 10 },
            "ink", session, transform, { x = 200, y = 120, w = 10, h = 10 })
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "fast",
            "turning fast on takes effect dynamically")
        t:eq(editor:_qualityBox().x, 300, "the new union does not reuse old pixels")
        t:eq(editor.quality_strokes, 0, "a setting boundary is not a stroke")
    end)

    t:case("an active-contact timeout latches without reschedule storms", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1200, h = 1600 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        local paper = editor.layout_geometry.paper_rect
        editor:onDirty(Geom:new{ x = paper.x + 2, y = paper.y + 2, w = 10, h = 10 },
            "ink", session, transform, { x = 2, y = 2, w = 10, h = 10 })
        editor:onEditChanged(session)
        runtime.active_contact = true
        local dirties = #ctx.env.UIManager.dirty
        scheduler:advance(0.35)
        t:eq(#ctx.env.UIManager.dirty, dirties, "timeout does not refresh mid-contact")
        t:eq(editor.quality_waiting_for_contact_end, true,
            "timeout transfers ownership to the contact latch")

        for i = 1, 200 do
            local far = i % 2 == 0
            local x = far and paper.x + paper.w - 12 or paper.x + 2
            local y = far and paper.y + paper.h - 12 or paper.y + 2
            editor:onDirty(Geom:new{ x = x, y = y, w = 10, h = 10 },
                "ink", session, transform, { x = 20, y = 20, w = 10, h = 10 })
        end
        t:eq(scheduler:pending(), 0, "hundreds of dirty boxes arm no new timer")
        runtime.active_contact = false
        editor:onPhysicalContactEnd(session, "lift")
        t:eq(scheduler:pending(), 1, "the physical boundary rearms exactly once")
        editor:onPhysicalContactEnd(session, "duplicate")
        t:eq(scheduler:pending(), 1, "a duplicate boundary cannot rearm")
        scheduler:drain()
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "the latched union is cleaned after lift")
    end)

    t:case("a passthrough lift rearms cleanup without an edit callback", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 10, h = 10 },
            "ink", session, transform, { x = 10, y = 20, w = 10, h = 10 })
        editor:onEditChanged(session)
        runtime.active_contact = true
        scheduler:advance(0.35)
        runtime.active_contact = false
        editor:onPhysicalContactEnd(session, "passthrough")
        t:eq(scheduler:pending(), 1, "physical lift is independent of edit_pending")
        scheduler:advance(0.35)
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "the interrupted burst receives its cleanup")
    end)

    t:case("stroke budget replaces one delayed action with one immediate action", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        for segment = 1, 20 do
            editor:onDirty(Geom:new{ x = 100, y = 200, w = 8, h = 8 },
                "ink", session, transform, { x = 10, y = 20, w = 8, h = 8 })
        end
        editor:onEditChanged(session)
        t:eq(editor.quality_strokes, 1, "twenty segments count as one contact")
        for contact = 2, 8 do
            editor:onDirty(Geom:new{ x = 100 + contact, y = 200, w = 8, h = 8 },
                "ink", session, transform,
                { x = 10 + contact, y = 20, w = 8, h = 8 })
            editor:onEditChanged(session)
        end
        t:eq(editor.quality_strokes, 8, "budget counts completed contacts only")
        t:eq(editor.quality_scheduled_kind, "immediate",
            "the eighth contact promotes the cleanup")
        t:eq(scheduler:pending(), 1, "promotion preserves one stable action")
        scheduler:drain()
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "the promoted action performs one cleanup")
    end)

    t:case("area budget waits for lift when a contact is still active", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1200, h = 1600 } end }
        local runtime = { live_fast = true, active_contact = true }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        local paper = editor.layout_geometry.paper_rect
        local box = Geom:new{
            x = paper.x, y = paper.y,
            w = math.floor(paper.w * 0.6), h = math.floor(paper.h * 0.5),
        }
        editor:onDirty(box, "ink", session, transform,
            { x = 0, y = 0, w = box.w, h = box.h })
        t:eq(editor.quality_scheduled_kind, "immediate",
            "a quarter-paper union promotes on the next tick")
        scheduler:drain()
        t:eq(editor.quality_waiting_for_contact_end, true,
            "the promoted action never refreshes under a pen")
        runtime.active_contact = false
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "lift rearms the promoted action once")
        scheduler:drain()
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "the large union is cleaned after lift")
    end)

    t:case("dirty boxes and cache blits are clipped to the paper", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local buffer = { w = 1000, h = 1400 }
        local cache = { buffer = function() return buffer end }
        local editor, _, _, _, session = newEditor{
            transform = transform, cache = cache,
        }
        local paper = editor.layout_geometry.paper_rect
        local before_dirty = #ctx.env.UIManager.dirty
        local before_blit = #ctx.env.Device.screen.bb.blits
        editor:onDirty(Geom:new{
                x = paper.x - 10, y = paper.y - 20, w = 30, h = 40,
            }, "ink", session, transform,
            { x = 50, y = 60, w = 30, h = 40 })
        local refresh = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][3]
        local blit = ctx.env.Device.screen.bb.blits[#ctx.env.Device.screen.bb.blits]
        t:eq(refresh.x, paper.x, "refresh left is clipped")
        t:eq(refresh.y, paper.y, "refresh top is clipped")
        t:eq(refresh.w, 20, "refresh width stays inside paper")
        t:eq(refresh.h, 20, "refresh height stays inside paper")
        t:eq(blit.offs_x, 60, "cache source follows horizontal clipping")
        t:eq(blit.offs_y, 80, "cache source follows vertical clipping")

        editor:onDirty(Geom:new{
                x = paper.x - 100, y = paper.y, w = 10, h = 10,
            }, "ink", session, transform,
            { x = 0, y = 0, w = 10, h = 10 })
        t:eq(#ctx.env.UIManager.dirty, before_dirty + 1,
            "an empty intersection schedules no refresh")
        t:eq(#ctx.env.Device.screen.bb.blits, before_blit + 1,
            "an empty intersection performs no blit")
    end)

    t:case("already-clipped adapter dirties keep their hot-path objects", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local editor = newEditor()
        local paper = editor.layout_geometry.paper_rect
        local screen_box = Geom:new{
            x = paper.x + 10, y = paper.y + 10, w = 8, h = 8,
        }
        local source_box = { x = 10, y = 10, w = 8, h = 8 }
        local exact_box, exact_source =
            editor:_clipDirtyBox(screen_box, source_box)
        t:eq(exact_box, screen_box, "existing Geom is reused")
        t:eq(exact_source, source_box, "existing cache source is reused")

        editor.quality_min_x, editor.quality_min_y = 0, 0
        editor.quality_max_x, editor.quality_max_y = 1, 1
        editor._qualityBox = function()
            error("quality budget allocated a Geom", 0)
        end
        t:eq(editor:_qualityBudgetReached(), false,
            "budget uses scalar accumulator fields")
    end)

    t:case("live blits restore only intersecting paper chrome on both rail sides", function()
        local Geom = require("ui/geometry")
        local Size = require("ui/size")
        for _, side in ipairs({ "left", "right" }) do
            ctx.reset()
            local transform = {}
            local buffer = { w = 1000, h = 1400 }
            local cache = { buffer = function() return buffer end }
            local editor, _, _, _, session = newEditor{
                side = side, transform = transform, cache = cache,
            }
            local paper = editor.layout_geometry.paper_rect
            local rects = ctx.env.Device.screen.bb.rects
            local rule = Size.border.window

            editor:onDirty(Geom:new{
                    x = paper.x + 7, y = paper.y, w = 20, h = rule + 6,
                }, "ink", session, transform,
                { x = 7, y = 0, w = 20, h = rule + 6 })
            local top = rects[#rects]
            t:eq(top.x, paper.x + 7, side .. " top restore starts at dirty x")
            t:eq(top.y, paper.y, side .. " top restore stays on the border")
            t:eq(top.w, 20, side .. " top restore is region-bounded")
            t:eq(top.h, rule, side .. " top restore has border thickness")

            editor:onDirty(Geom:new{
                    x = paper.x, y = paper.y + rule + 7,
                    w = rule + 6, h = 20,
                }, "ink", session, transform,
                { x = 0, y = rule + 7, w = rule + 6, h = 20 })
            local left = rects[#rects]
            t:eq(left.x, paper.x, side .. " left restore stays on the border")
            t:eq(left.y, paper.y + rule + 7,
                side .. " left restore starts at dirty y")
            t:eq(left.w, rule, side .. " left restore has border thickness")
            t:eq(left.h, 20, side .. " left restore is region-bounded")

            local before = #rects
            editor:onDirty(Geom:new{
                    x = paper.x + rule + 7, y = paper.y + rule + 7,
                    w = 20, h = 20,
                }, "ink", session, transform,
                { x = rule + 7, y = rule + 7, w = 20, h = 20 })
            t:eq(#rects, before, side .. " interior ink repaints no chrome")
        end
    end)

    t:case("a modal preserves visible fast ink and never exposes hidden repairs", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        ctx.env.UIManager:show(editor)
        editor:markShown()
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 20 },
            "ink", session, transform, { x = 10, y = 20, w = 20, h = 20 })
        editor:onEditChanged(session)
        local modal = { handleEvent = function() return true end }
        editor:showModalSafely(modal)
        t:eq(scheduler:pending(), 0, "covering cancels the delayed action")
        t:eq(editor.quality_waiting_for_uncover, true, "visible union is retained")
        local dirties = #ctx.env.UIManager.dirty
        local blits = #ctx.env.Device.screen.bb.blits
        editor:onDirty(Geom:new{ x = 180, y = 260, w = 20, h = 20 },
            "repair", session, transform, { x = 90, y = 80, w = 20, h = 20 })
        t:eq(#ctx.env.UIManager.dirty, dirties, "repair cannot punch through modal")
        t:eq(#ctx.env.Device.screen.bb.blits, blits, "hidden repair is not blitted")
        editor:_closeModal(modal)
        t:eq(scheduler:pending(), 0,
            "the partial repair resolves the quality union synchronously")
        t:eq(#ctx.env.Device.screen.bb.blits, blits + 1,
            "uncover copies the hidden repair once")
        t:eq(#ctx.env.UIManager.dirty, dirties + 1,
            "uncover refreshes the hidden repair and prior fast ink once")
        local refresh = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][3]
        t:eq(refresh.x, 100, "partial union starts at the visible fast ink")
        t:eq(refresh.y, 200, "partial union keeps the visible top")
        t:eq(refresh.w, 100, "partial union reaches the disjoint repair")
        t:eq(refresh.h, 80, "partial union reaches the disjoint repair bottom")
        scheduler:drain()
        t:eq(#ctx.env.UIManager.dirty, dirties + 1,
            "no redundant cleanup remains after the combined partial")
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "uncover cleanup uses partial")
        editor:shutdown()
        ctx.env.UIManager:close(editor)
    end)

    t:case("covered repaint rejects a stale cache generation", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = {
            generation = 1,
            buffer = function() return { w = 1000, h = 1400 } end,
        }
        local editor, _, _, _, session = newEditor{
            transform = transform, cache = cache,
        }
        ctx.env.UIManager:show(editor)
        editor:markShown()
        local modal = { handleEvent = function() return true end }
        editor:showModalSafely(modal)
        local dirties = #ctx.env.UIManager.dirty
        local blits = #ctx.env.Device.screen.bb.blits
        editor:onDirty(Geom:new{ x = 180, y = 260, w = 20, h = 20 },
            "repair", session, transform, { x = 90, y = 80, w = 20, h = 20 })
        t:check(editor.covered_repaint ~= nil, "covered repair is retained")
        cache.generation = 2
        editor:_closeModal(modal)
        t:eq(editor.covered_repaint, nil, "stale generation is discarded")
        t:eq(#ctx.env.Device.screen.bb.blits, blits,
            "stale cache pixels are never copied")
        t:eq(#ctx.env.UIManager.dirty, dirties,
            "stale cache schedules no panel refresh")
        editor:shutdown()
        ctx.env.UIManager:close(editor)
    end)

    t:case("a toast occludes notebook framebuffer writes until repaint", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = {
            buffer = function() return { w = 1000, h = 1400 } end,
            paintTo = function() end,
        }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        ctx.env.UIManager:show(editor)
        editor:markShown()
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 20 },
            "ink", session, transform, { x = 10, y = 20, w = 20, h = 20 })
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "visible ink arms its quality cleanup")
        local toast = { toast = true, handleEvent = function() return false end }
        ctx.env.UIManager:show(toast)
        local dirties = #ctx.env.UIManager.dirty
        local blits = #ctx.env.Device.screen.bb.blits
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 20 },
            "ink", session, transform, { x = 10, y = 20, w = 20, h = 20 })
        t:eq(#ctx.env.Device.screen.bb.blits, blits,
            "ink does not punch through the toast")
        t:eq(#ctx.env.UIManager.dirty, dirties,
            "hidden ink schedules no panel update")
        t:eq(editor.quality_waiting_for_uncover, true,
            "quality state remembers the occluded work")

        ctx.env.UIManager:close(toast)
        editor:paintTo(ctx.env.Device.screen.bb, 0, 0)
        t:eq(scheduler:pending(), 1,
            "underlying repaint rearms one quality cleanup")
        scheduler:drain()
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "toast uncover receives a quality refresh")
        editor:shutdown()
        ctx.env.UIManager:close(editor)
    end)

    t:case("page, rotation and close invalidate scheduled generations", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        local function arm()
            editor:onDirty(Geom:new{ x = 100, y = 200, w = 10, h = 10 },
                "ink", session, transform, { x = 10, y = 20, w = 10, h = 10 })
            editor:onEditChanged(session)
            t:eq(scheduler:pending(), 1, "fixture arms one callback")
            return editor.quality_action
        end
        local function partialCount()
            local count = 0
            for i = 1, #ctx.env.UIManager.dirty do
                if ctx.env.UIManager.dirty[i][2] == "partial" then count = count + 1 end
            end
            return count
        end

        local stale = arm()
        editor:onPageReady()
        t:eq(scheduler:pending(), 0, "page-ready cancels its old timer")
        local before = partialCount()
        stale()
        t:eq(partialCount(), before, "old page callback is inert")

        stale = arm()
        editor:onSetDimensions()
        t:eq(scheduler:pending(), 0, "rotation cancels its old timer")
        before = partialCount()
        stale()
        t:eq(partialCount(), before, "old transform callback is inert")

        stale = arm()
        editor:shutdown()
        t:eq(scheduler:pending(), 0, "shutdown cancels its timer")
        before = partialCount()
        stale()
        t:eq(partialCount(), before, "closed editor callback is inert")
    end)


    t:case("quality state remains constant-sized across a thousand contacts", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache,
        }
        for contact = 1, 1000 do
            editor:onDirty(Geom:new{ x = 100, y = 200, w = 8, h = 8 },
                "ink", session, transform, { x = 10, y = 20, w = 8, h = 8 })
            editor:onEditChanged(session)
        end
        t:eq(editor.quality_strokes, 1000, "only the scalar contact count grows")
        t:eq(editor.quality_boxes, nil, "no per-dirty or per-contact list exists")
        t:eq(editor:_qualityBox().w, 8, "the scalar union remains exact")
        t:eq(scheduler:pending(), 1, "the burst still owns one stable action")
    end)


    t:case("a repair never blits through an external dialog", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local buffer = { w = 1000, h = 1400 }
        local cache = { buffer = function() return buffer end }
        local editor, _, _, _, session = newEditor{
            transform = transform, cache = cache,
        }
        ctx.env.UIManager:show(editor)
        local external = { handleEvent = function() return true end }
        ctx.env.UIManager:show(external)
        local blits = #ctx.env.Device.screen.bb.blits
        local dirties = #ctx.env.UIManager.dirty
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 20, h = 30 },
            "repair", session, transform,
            { x = 10, y = 20, w = 20, h = 30 })
        t:eq(#ctx.env.Device.screen.bb.blits, blits,
            "paper pixels do not overwrite the top-level dialog")
        t:eq(#ctx.env.UIManager.dirty, dirties,
            "no panel refresh exposes the repaired paper early")
        editor:markShown()
        editor:onEditChanged(session)
        t:eq(#ctx.env.Device.screen.bb.blits, blits,
            "a capability change does not paint the rail through the dialog")
        t:eq(#ctx.env.UIManager.dirty, dirties,
            "the guarded rail waits for the uncover repaint")
        ctx.env.UIManager:close(external)
        editor:shutdown()
        ctx.env.UIManager:close(editor)
    end)
end
