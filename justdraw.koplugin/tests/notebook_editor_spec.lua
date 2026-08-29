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
        function controller:setPageTemplate(kind)
            self.calls[#self.calls + 1] = "paper:" .. tostring(kind)
            if self.paper_err then return nil, self.paper_err end
            snapshot.template_kind = kind
            return true
        end
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
            quality_clock = overrides.quality_clock,
            control_touch_allowed = function() return guard ~= false end,
            partial_blocks_input = overrides.partial_blocks_input,
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

    --[[--
    A rail control is painted at its slot's origin and hit-tested against that
    same rectangle, so a widget bigger than its slot is a control that overdraws
    its neighbour and answers for pixels it does not own. Button grows past the
    `height` it is handed, which is why the slot has to be converted rather than
    passed straight through -- and why the bottom control used to spill off the
    screen edge.
    ]]
    t:case("no control paints outside the slot it is hit-tested against", function()
        ctx.reset()
        local editor = newEditor()
        local screen = editor.layout_geometry.screen_rect
        t:check(#editor.control_entries > 0, "the rail built its controls")
        for i = 1, #editor.control_entries do
            local entry = editor.control_entries[i]
            local size = entry.widget:getSize()
            t:check(size.h <= entry.rect.h,
                "control " .. i .. " fits its slot vertically ("
                    .. size.h .. " <= " .. entry.rect.h .. ")")
            t:check(size.w <= entry.rect.w, "control " .. i .. " fits it horizontally")
            t:check(entry.rect.y + size.h <= screen.y + screen.h,
                "control " .. i .. " stays on the screen")
        end
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

    --[[--
    The paper chooser is the only per-page property the editor can edit, and
    unlike Pen width it changes durable state, so it has to behave like the
    other domain actions: reachable only from More, closing More before it
    opens, and saying why when the domain refuses it.
    ]]
    t:case("More offers Paper style, checked on the page's own ruling", function()
        ctx.reset()
        local editor, controller, snapshot = newEditor()
        snapshot.template_kind = "ruled"
        editor:onStateChanged()

        local more = editor:showMore()
        local entry
        for i = 1, #more.buttons do
            local button = more.buttons[i][1]
            if button.text == "Paper style" then entry = button end
        end
        t:check(entry ~= nil, "Paper style is reachable from More")
        t:eq(entry.enabled, true, "and enabled on a writable notebook")
        entry.callback()
        local chooser = editor.modal_widget
        t:check(chooser ~= nil and chooser ~= more, "More closed before it opened")

        local labels, checked = {}, nil
        for i = 1, #chooser.buttons do
            local button = chooser.buttons[i][1]
            labels[#labels + 1] = button.text
            if button.checked_func and button.checked_func() then
                checked = button.text
            end
        end
        t:eq(table.concat(labels, "|"),
            "Blank|Ruled|Squared|Dotted|Close", "every kind, in English")
        t:eq(checked, "Ruled", "the page's own ruling is the checked one")

        for i = 1, #chooser.buttons do
            if chooser.buttons[i][1].text == "Dotted" then
                chooser.buttons[i][1].callback()
            end
        end
        t:eq(controller.calls[#controller.calls], "paper:dots",
            "the choice reaches the domain")
        t:eq(editor.modal_widget, nil, "and the chooser closed")
    end)

    t:case("a refused paper change says why and leaves the page alone", function()
        ctx.reset()
        local editor, controller, snapshot = newEditor()
        editor:onStateChanged()
        controller.paper_err = "contact_active"
        local chooser = editor:showPaperStyle()
        for i = 1, #chooser.buttons do
            if chooser.buttons[i][1].text == "Squared" then
                chooser.buttons[i][1].callback()
            end
        end
        t:eq(snapshot.template_kind, nil, "nothing changed")
        local info = editor.modal_widget
        t:check(info ~= nil, "a message replaced the chooser")
        t:eq(info.text, "Lift the pen and try again.",
            "the reason the reader can act on")
    end)

    t:case("a read-only notebook cannot be re-ruled", function()
        ctx.reset()
        local editor = newEditor{
            snapshot = {
                state = "ready", writable = false, can_ink = false,
                can_navigate = true, can_close = true,
                has_previous = false, has_next = true, page_count = 2,
                can_undo = false, pending_writes = 0, template_kind = "dots",
            },
        }
        editor:onStateChanged()
        local more = editor:showMore()
        for i = 1, #more.buttons do
            local button = more.buttons[i][1]
            if button.text == "Paper style" then
                t:eq(button.enabled, false, "Paper style is disabled")
            end
        end
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

    --[[--
    A stroke that begins while the cleanup is armed pushes the cleanup back.

    On the Kindle Scribe the cleanup's `partial` is GLR16, which the driver
    promotes to a FULL update and blocks the process on until the panel is
    done; the event loop reads no input meanwhile. Fired between two strokes of
    a word, it eats the start of the second one. So the delay is measured from
    the last lift of a run, not from each lift: a new contact cancels the armed
    timer, and the boundary that ends it rearms.
    ]]
    t:case("a new contact holds the delayed cleanup until its own lift", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        local function ink(x, y)
            editor:onDirty(Geom:new{ x = x, y = y, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        end
        -- First stroke: lift arms the delayed cleanup.
        ink(100, 200)
        runtime.active_contact = false
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "the first lift arms the cleanup")

        -- Second stroke starts 200 ms later, inside the delay window.
        scheduler:advance(0.2)
        runtime.active_contact = true
        local before = #ctx.env.UIManager.dirty
        ink(140, 240)
        t:eq(scheduler:pending(), 0, "a new contact cancels the armed cleanup")
        t:eq(editor.quality_waiting_for_contact_end, true,
            "and hands it to the contact latch")
        scheduler:advance(0.35)
        t:eq(#ctx.env.UIManager.dirty, before + 1,
            "only the fast segment refreshed; no partial fired mid-word")

        -- Its lift rearms; the cleanup lands QUALITY_DELAY after *this* lift.
        runtime.active_contact = false
        editor:onEditChanged(session)
        t:eq(scheduler:pending(), 1, "the second lift rearms exactly once")
        scheduler:advance(0.349)
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "fast",
            "still nothing but fast ink before the delay")
        scheduler:advance(0.001)
        local cleanup = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(cleanup[2], "partial", "one cleanup after the last lift")
        t:eq(cleanup[3].x, 100, "covering the first stroke")
        t:eq(cleanup[3].w, 50, "and the second: nothing was cleaned less, only later")
        t:eq(editor.quality_strokes, 0, "the accumulator was consumed once")
    end)

    --[[--
    Where `partial` blocks the process, the run cleanup must not be one.

    On the Kindle Scribe a partial is GLR16, promoted to FULL and fenced with a
    completion wait inside the process; UIManager reads no input meanwhile.
    The cleanup that ends a run of strokes is the one the pen lands on, so on
    such a device it goes out as `ui` -- no promotion, no completion wait --
    and the full-quality partial is deferred to a rest pass that fires only
    once the pen has stayed away for QUALITY_REST_DELAY.
    ]]
    t:case("on a blocking device the run cleanup is ui and the rest pass is partial", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return true end,
        }
        local function ink(x, y)
            editor:onDirty(Geom:new{ x = x, y = y, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        end
        ink(100, 200); editor:onEditChanged(session)
        ink(140, 240); editor:onEditChanged(session)
        scheduler:advance(0.35)
        local run = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(run[2], "ui", "the run cleanup uses the non-blocking waveform")
        t:eq(run[3].x, 100, "over the whole union")
        t:eq(run[3].w, 50, "of both strokes")
        t:eq(editor:_qualityHasUnion(), true, "the union is kept for the rest pass")
        t:eq(editor.quality_scheduled_kind, "rest", "and a rest pass is armed")
        t:eq(scheduler:pending(), 1, "exactly one")

        -- Two advances rather than 1.99 + 0.01: summed floats land a hair
        -- short of the due time and the fake scheduler, correctly, does not
        -- fire early. Assert "not yet" at a clear margin, then land on it.
        local before = #ctx.env.UIManager.dirty
        scheduler:advance(1.5)
        t:eq(#ctx.env.UIManager.dirty, before, "the rest pass waits out QUALITY_REST_DELAY")
        scheduler:advance(0.5)
        local rest = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(rest[2], "partial", "the rest pass is the full-quality waveform")
        t:eq(rest[3].x, 100, "over the same union")
        t:eq(rest[3].w, 50, "unchanged")
        t:eq(editor:_qualityHasUnion(), false, "and it consumes the union")
        t:eq(scheduler:pending(), 0, "nothing left armed")
    end)

    t:case("a pen back on the glass holds the rest pass too", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return true end,
        }
        local function ink(x, y)
            editor:onDirty(Geom:new{ x = x, y = y, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        end
        ink(100, 200); editor:onEditChanged(session)
        scheduler:advance(0.35)                       -- run cleanup (ui) fired
        t:eq(editor.quality_scheduled_kind, "rest", "rest pass armed")
        scheduler:advance(1.0)
        runtime.active_contact = true
        ink(300, 400)                                 -- a new word starts
        t:eq(scheduler:pending(), 0, "the rest pass is cancelled by the contact")
        t:eq(editor.quality_waiting_for_contact_end, true, "and handed to the latch")
        runtime.active_contact = false
        editor:onEditChanged(session)
        t:eq(editor.quality_scheduled_kind, "delayed",
            "its lift arms a run cleanup again, not the rest pass")
        scheduler:advance(0.35)
        local run = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(run[2], "ui", "which goes out as ui")
        t:eq(run[3].x, 100, "over the union that now spans both words")
        t:eq(run[3].w, 210, "old and new")
    end)

    t:case("the rest pass waits for the pen to stop reporting, not just to stop inking", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local scheduler = ctx.support.newScheduler()
        local editor, _, _, _, session = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            scheduler = scheduler,
            quality_clock = function() return scheduler:now() end,
            partial_blocks_input = function() return true end,
        }
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 10, h = 10 },
            "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        editor:onEditChanged(session)
        scheduler:advance(0.35)                       -- run cleanup (ui)
        t:eq(editor.quality_scheduled_kind, "rest", "rest pass armed")
        scheduler:advance(1.0)
        editor:onStylusFrame()                        -- the pen hovers at t=1.35
        scheduler:advance(0.85)
        editor:onStylusFrame()                        -- and again at t=2.20
        local before = #ctx.env.UIManager.dirty
        scheduler:advance(0.15)                       -- t=2.35: the rest is due
        t:eq(#ctx.env.UIManager.dirty, before, "a hovering pen defers the blocking pass")
        t:eq(editor.quality_scheduled_kind, "rest", "which stays armed")
        t:eq(scheduler:pending(), 1, "exactly once")
        scheduler:advance(1.5)                        -- t=3.85: still short of 2.20+2.0
        t:eq(#ctx.env.UIManager.dirty, before, "and keeps waiting out the full delay")
        scheduler:advance(0.5)                        -- t=4.35 >= 4.20
        local rest = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(rest[2], "partial", "then the quality pass lands")
        t:eq(editor:_qualityHasUnion(), false, "and consumes the union")
        t:eq(scheduler:pending(), 0, "nothing left armed")
    end)

    t:case("a stylus frame while nothing is armed costs one assignment", function()
        ctx.reset()
        local runtime = { live_fast = true, active_contact = false }
        local scheduler = ctx.support.newScheduler()
        local editor = newEditor{
            runtime = runtime, scheduler = scheduler,
            quality_clock = function() return scheduler:now() end,
        }
        scheduler:advance(3.0)
        editor:onStylusFrame()
        t:eq(editor.quality_last_stylus_frame_at, 3.0, "the frame time is recorded")
        t:eq(scheduler:pending(), 0, "and nothing is scheduled")
    end)

    t:case("a budget-driven cleanup is ui on a blocking device and arms the rest pass", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return true end,
        }
        for i = 1, 8 do
            editor:onDirty(Geom:new{ x = 100 + i, y = 200, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
            editor:onEditChanged(session)
        end
        t:eq(editor.quality_scheduled_kind, "immediate", "the budget armed an immediate")
        scheduler:advance(0)
        local fired = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(fired[2], "ui", "a spent budget must not block the pen either")
        t:eq(editor:_qualityHasUnion(), true, "the union is kept for the rest pass")
        t:eq(editor.quality_strokes, 0, "and the stroke count restarts")
        t:eq(editor.quality_scheduled_kind, "rest", "a rest pass is armed")
        scheduler:advance(2.0)
        local rest = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(rest[2], "partial", "which is the one that lands the quality waveform")
        t:eq(editor:_qualityHasUnion(), false, "and consumes the union")
    end)

    t:case("an uncover cleanup is ui on a blocking device", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return true end,
        }
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 10, h = 10 },
            "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        editor:onEditChanged(session)
        editor:_qualityCovered()                      -- a toast or menu came up
        t:eq(scheduler:pending(), 0, "covered: nothing armed")
        editor:_qualityUncovered(true)
        t:eq(editor.quality_scheduled_kind, "immediate", "uncover arms an immediate")
        scheduler:advance(0)
        local fired = ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty]
        t:eq(fired[2], "ui", "that does not block a pen hovering over the closed menu")
        t:eq(editor.quality_scheduled_kind, "rest", "the quality pass waits for the rest")
    end)

    t:case("off a blocking device a budget cleanup is still partial", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return false end,
        }
        for i = 1, 8 do
            editor:onDirty(Geom:new{ x = 100 + i, y = 200, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
            editor:onEditChanged(session)
        end
        scheduler:advance(0)
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "nothing changes where partial does not block")
        t:eq(scheduler:pending(), 0, "and no rest pass is armed")
    end)

    t:case("off a blocking device the run cleanup is still partial", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
            partial_blocks_input = function() return false end,
        }
        editor:onDirty(Geom:new{ x = 100, y = 200, w = 10, h = 10 },
            "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        editor:onEditChanged(session)
        scheduler:advance(0.35)
        t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
            "nothing changes where partial does not block")
        t:eq(scheduler:pending(), 0, "and no rest pass is armed")
    end)

    t:case("a budget-exhausted immediate cleanup is not held", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        -- Eight completed contacts reach the stroke budget.
        for i = 1, 8 do
            editor:onDirty(Geom:new{ x = 100 + i, y = 200, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
            editor:onEditChanged(session)
        end
        t:eq(editor.quality_scheduled_kind, "immediate", "the budget armed an immediate")
        runtime.active_contact = true
        editor:onDirty(Geom:new{ x = 300, y = 200, w = 10, h = 10 },
            "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        t:eq(editor.quality_scheduled_kind, "immediate",
            "a new contact does not hold a budget-driven cleanup")
    end)

    --[[--
    The timing trace is the only thing that can calibrate QUALITY_DELAY: it
    records the lift-to-lift gap the delay has to beat and the moment the
    cleanup fires. Off, it costs one nil check; on, one line per event.
    ]]
    t:case("the refresh trace records lift, arm, hold and fire with timings", function()
        ctx.reset()
        local Geom = require("ui/geometry")
        local transform = {}
        local cache = { buffer = function() return { w = 1000, h = 1400 } end }
        local runtime = { live_fast = true, active_contact = false }
        local clock = 10
        local editor, _, _, _, session, _, scheduler = newEditor{
            transform = transform, cache = cache, runtime = runtime,
        }
        editor.quality_trace = true
        editor.quality_clock = function() return clock end
        local lines = {}
        local logger = require("logger")
        local real_info = logger.info
        logger.info = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            lines[#lines + 1] = table.concat(parts, " ")
        end
        local function ink(x, y)
            editor:onDirty(Geom:new{ x = x, y = y, w = 10, h = 10 },
                "ink", session, transform, { x = 1, y = 1, w = 10, h = 10 })
        end
        ink(100, 200); editor:onEditChanged(session)
        clock = 10.2; runtime.active_contact = true; ink(140, 240)
        clock = 10.5; runtime.active_contact = false; editor:onEditChanged(session)
        scheduler:advance(0.35)
        logger.info = real_info

        local events = {}
        for i = 1, #lines do
            local ev = lines[i]:match("JUSTDRAW%-REFRESH event=(%S+)")
            if ev then events[#events + 1] = ev end
        end
        t:eq(table.concat(events, ","), "lift,arm,hold,lift,arm,fire",
            "the whole sequence is on the log in order")
        t:check(lines[4]:find("since_lift=0.500", 1, true) ~= nil,
            "the second lift carries the lift-to-lift gap: " .. tostring(lines[4]))
        t:check(lines[6]:find("box=50x50", 1, true) ~= nil,
            "the fire names the region it cleaned: " .. tostring(lines[6]))
        t:eq(lines[6]:match("kind=(%a+)"), "delayed",
            "and the kind that fired: " .. tostring(lines[6]))
        for i = 1, #lines do
            t:check(not lines[i]:find("Notes", 1, true), "no notebook identity leaks")
        end

        editor.quality_trace = false
        local n = #lines
        ink(500, 500); editor:onEditChanged(session)
        t:eq(#lines, n, "off, the trace writes nothing")
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
