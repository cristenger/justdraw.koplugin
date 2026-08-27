return function(ctx)
    local t = ctx.t
    local Editor = require("ink_notebook_editor")

    t:describe("standalone notebooks / editor window")

    local function newEditor(overrides)
        overrides = overrides or {}
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
        local editor = Editor:new{
            controller = controller,
            notebook = { id = 1, title = "Notes", page_count = 2 },
            get_rail_side = function() return overrides.side or "right" end,
            set_rail_side = function() end,
            get_eraser = function() return false end,
            set_eraser = function() end,
            has_active_contact = function() return false end,
            control_touch_allowed = function() return guard ~= false end,
            show_host_message = overrides.show_host_message,
            on_close = function() closed = closed + 1 end,
        }
        return editor, controller, snapshot, function() return closed end, session
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

    t:case("live ink refreshes its Geom without repainting the editor", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local buffer = { w = 1000, h = 1400 }
        local cache = { buffer = function() return buffer end }
        local editor, _, _, _, session = newEditor{
            transform = transform, cache = cache,
        }
        local before = #ctx.env.UIManager.dirty
        local screen_box = Geom:new{ x = 100, y = 200, w = 20, h = 30 }
        editor:onDirty(screen_box, "stroke", session, transform,
            { x = 10, y = 20, w = 20, h = 30 })
        local refresh = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(#ctx.env.UIManager.dirty, before + 1, "one panel refresh is queued")
        t:eq(refresh[1], nil, "editor is not marked for repaint")
        t:eq(refresh[2], "fast", "live ink keeps the fast waveform")
        t:eq(refresh[3], screen_box, "the exact Geom region is refreshed")
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
