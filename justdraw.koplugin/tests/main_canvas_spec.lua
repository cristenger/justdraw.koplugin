--[[--
The plugin with a sheet open: the parts only the whole thing can show.

Every module below this has been checked on its own. What is left is what only
appears when they are wired together, and it is mostly about two things.

One is that there is never more than one JustDraw window. The standalone
toolbar steps down when a sheet opens and comes back when it closes, and
`self.bar` keeps meaning "the toolbar the reader can see" throughout, because
half this file's geometry depends on that being true.

The other is the thing the whole design was for: with a sheet open, the book is
still readable. A finger above the sheet turns the page. A palm on the sheet
does not. And when there is no sheet -- a PDF, a fixed layout, a book the
database cannot identify -- every path here is inert and the plugin behaves
exactly as it did before any of it existed.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Device = ctx.Device
    local Capture = require("ink_capture")
    local Replay = require("input_replay")
    local Style = require("ink_style")

    local SW, SH = Device.screen.w, Device.screen.h

    -- Sheet at 70%: top edge at 240, handle 240..263, canvas below that.
    local SHEET = { x = 100, y = 500 }
    local READER = { x = 100, y = 100 }
    local HANDLE = { x = 100, y = 250 }

    --[[--
    Flush until the sheet index says it is done.

    It reads its metadata a batch per tick and resolves anchors a batch per
    tick after that (ADR-42), so a fixture is ready when it says so and not
    after any fixed number of flushes. `keep_indexing` is for the cases that
    are about the half-built state itself.
    ]]
    local function settleIndex(p)
        local ticks = 0
        while p.session and p.session:isIndexing() do
            env.UIManager:flush()
            ticks = ticks + 1
            if ticks > 200 then error("the sheet index did not settle", 0) end
        end
    end

    --- A plugin over a reflowable document whose canvas store is in memory.
    local function canvasPlugin(opts)
        opts = opts or {}
        ctx.reset{ wacom_protocol = true }
        local doc = support.newDocument{
            here = "/body/p[7]",
            pages = opts.pages or { ["/body/p[7]"] = 1 },
        }
        local store = support.newCanvasStore(opts.canvases or {})
        for _, entry in ipairs(opts.strokes or {}) do
            store:putStroke(entry.canvas_id, entry.stroke)
        end
        local p = support.newPlugin(ctx.JustDraw, env, { document = doc })
        p.canvas_repository = store
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        if not opts.keep_indexing then settleIndex(p) end
        return p, store, doc
    end

    --- A book's worth of sheets, each anchored on its own page.
    local function manySheets(n)
        local canvases, pages = {}, { ["/body/p[7]"] = 1 }
        for i = 1, n do
            canvases[i] = {
                id = i, anchor_kind = "xpointer", anchor_key = "xp:/p" .. i,
                anchor_raw = "/p" .. i, anchor_normalized = "/p" .. i,
                anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
            }
            pages["/p" .. i] = i
        end
        return canvases, pages
    end

    --- The entry that opens or creates the sheet at this position: the one the
    --- reader is looking at when the index is what is holding them up.
    local function openHereItem(p)
        for _, item in ipairs(p:canvasMenu()) do
            if item.text == "Open sheet here" then return item end
        end
    end

    local function penFrame(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    --[[--
    A pen contact-down, shaped the way a Wacom one is.

    KOReader's slot table is persistent and BTN_TOUCH can arrive before any
    ABS update, so the frame that opens a contact still presents the previous
    contact's position. InkStylusGeometry treats it as a baseline rather than
    a point, and the stroke starts at the first pair it can prove -- which is
    the one the caller actually names here.
    ]]
    local function penDown(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, tool = tool or 1 }
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penLift(p, x, y)
        p:onStylusEvent{ slot = 4, id = -1, x = x, y = y }
    end

    --- Give the policy the trusted boundary a real pen leaves behind. Without
    --- one, a lease's very first contact spends a coordinate pair proving
    --- where it is -- true, and covered by its own case, but not what the
    --- cases below are about.
    local function seedPenBaseline(p)
        local geometry = p.stylus_geometry
        if not geometry then return end
        geometry:observe(-1, -1)
        geometry:reset(false)
    end

    --- A sheet open and the pen route actually installed. The stylus callback
    --- only runs while a lease is held, and the lease is what builds the
    --- contact machine, so a case that drives onStylusEvent needs one.
    local function openForPen(p)
        local overlay = p:openCanvasHere()
        p:setDrawing(true)
        seedPenBaseline(p)
        return overlay
    end

    local function touchFrame(p, slots)
        return p:onStylusTouchFrame(slots)
    end

    -- =================================================================
    t:describe("main / canvas availability")

    t:case("a fixed-layout document gets no session at all", function()
        ctx.reset()
        local p = support.newPlugin(ctx.JustDraw, env, {})
        env.UIManager:flush()
        p:onReaderReady()
        t:eq(p.session, nil, "no canvas machinery on a PDF")
        t:eq(p.canvas_open, false, "and nothing to open")
    end)

    t:case("a reflowable document gets one", function()
        local p = canvasPlugin()
        t:check(p.session ~= nil, "there is a session")
        t:eq(p.session:isAvailable(), true, "and it is usable")
    end)

    t:case("the sheet menu is off without a session", function()
        ctx.reset()
        local p = support.newPlugin(ctx.JustDraw, env, {})
        env.UIManager:flush()
        local item = ctx.menuItem(p, "Drawing sheet")
        t:check(item ~= nil, "the entry is there")
        t:eq(item.enabled_func(), false, "and greyed out")
    end)

    t:case("the sheet menu is on with one", function()
        local p = canvasPlugin()
        t:eq(ctx.menuItem(p, "Drawing sheet").enabled_func(), true, "reachable")
    end)

    t:case("the checksum is read from the document's settings", function()
        -- It lives there, not on ReaderUI, and reading the wrong place gives
        -- nil -- which turns the feature off on every book with a message
        -- saying so.
        local p, store = canvasPlugin()
        t:eq(store.identity[1], "test-md5", "the checksum ReaderUI computed")
        t:check(store.identity[2] ~= nil, "and a file size beside it")
    end)

    t:case("a book with no checksum yet leaves canvases off rather than keyed on a path", function()
        ctx.reset{ wacom_protocol = true }
        local doc = support.newDocument{ here = "/p", pages = { ["/p"] = 1 } }
        local p = support.newPlugin(ctx.JustDraw, env, { document = doc })
        p.ui.doc_settings.data.partial_md5_checksum = nil
        p.canvas_repository = support.newCanvasStore({})
        env.UIManager:flush()
        p:onReaderReady()
        t:eq(p.session, nil, "no session")
    end)

    t:case("opening a book twice does not build a second session", function()
        local p = canvasPlugin()
        local first = p.session
        p:onReaderReady()
        t:eq(p.session, first, "the same one")
    end)

    -- =================================================================
    t:describe("main / while the sheet index builds")

    t:case("the entry that is refusing says how far the index has got", function()
        local canvases, pages = manySheets(450)
        local p = canvasPlugin{ canvases = canvases, pages = pages,
                                keep_indexing = true }
        local item = openHereItem(p)
        t:check(item ~= nil, "the entry is there")
        t:eq(item.enabled_func(), false, "greyed out, as it already was")
        t:eq(item.text_func(), "Indexing sheets 200/450",
            "and it says what it is waiting for")
        t:eq(#env.notifications, 0, "no modal and no notification for it")

        settleIndex(p)
        t:eq(openHereItem(p).text_func(), "Open sheet here",
            "and it stops saying it once the sheets are placed")
        t:eq(openHereItem(p).enabled_func(), true, "with creating allowed again")
    end)

    t:case("a count it never got is not reported as a zero", function()
        local p = canvasPlugin()
        p.session.isIndexing = function() return true end
        p.session.indexProgress = function()
            return { phase = "metadata", loaded = 12, total = nil }
        end
        t:eq(openHereItem(p).text_func(), "Indexing sheets 12",
            "what is known is said, what is not is left out")
    end)

    t:case("a batch stands aside while the pen is on the glass", function()
        local canvases, pages = manySheets(450)
        local p, store = canvasPlugin{ canvases = canvases, pages = pages,
                                       keep_indexing = true }
        t:eq(store.calls.list, 1, "one batch has been read")

        p:buildStylusMachine(Device.input)
        seedPenBaseline(p)
        penDown(p, READER.x, READER.y)
        t:eq(p:hasActivePhysicalContact(), true, "the pen is down")

        local delays = {}
        local scheduleIn = env.UIManager.scheduleIn
        env.UIManager.scheduleIn = function(self, delay, fn)
            delays[#delays + 1] = delay
            return scheduleIn(self, delay, fn)
        end
        env.UIManager:flush()
        t:eq(store.calls.list, 1, "nothing was asked of the database")
        -- The live refresh accumulator keeps a cadence timer of its own while
        -- the pen is down (ADR-43), so the index's yield is the tenth of a
        -- second among the delays, not necessarily the first of them.
        local yielded = false
        for i = 1, #delays do if delays[i] == 0.1 then yielded = true end end
        t:eq(yielded, true, "the batch came back a tenth of a second later")

        penLift(p, READER.x + 2, READER.y + 2)
        env.UIManager.scheduleIn = scheduleIn
        t:eq(p:hasActivePhysicalContact(), false, "the glass is clear")
        env.UIManager:flush()
        t:eq(store.calls.list, 2, "and the same build carries on")
        p:releaseStylusMachine()
    end)

    -- =================================================================
    t:describe("main / opening and closing a sheet")

    t:case("opening a sheet creates one and shows one window", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        t:eq(#store.canvases, 1, "a sheet was created")
        t:check(p.canvas_open, "and opened")
        local ours = 0
        for _, e in ipairs(env.UIManager._window_stack) do
            if e.widget == p.session:overlay() then ours = ours + 1 end
        end
        t:eq(ours, 1, "one JustDraw window")
    end)

    t:case("the standalone toolbar steps down for the overlay's", function()
        local p = canvasPlugin()
        local standalone = p.bar
        p:openCanvasHere()
        t:check(p.bar ~= standalone, "a different toolbar")
        t:eq(p.bar, p.session:overlay().bar, "the overlay's own")
        for _, e in ipairs(env.UIManager._window_stack) do
            t:check(e.widget ~= standalone, "and the old one is off the stack")
        end
    end)

    t:case("opening a sheet turns drawing on", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        t:eq(p.drawing, true, "there is no point opening one to look at it")
    end)

    t:case("a populated sheet captures no ink until its chunks validate", function()
        local canvas = {
            id = 41, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { canvas },
            strokes = { { canvas_id = canvas.id, stroke = {
                width = 4, tool = 1, points = { 100, 100, 200, 100 }, n = 2,
            } } },
        }
        p:openCanvas(canvas)
        t:eq(p.drawing, false, "loading is not advertised as Draw")
        t:eq(p.bar.draw_btn.text, "Loading", "the reachable button shows the state")
        p:setDrawing(true)
        t:eq(p.drawing, false, "manual Draw is guarded too")
        p:onJustDrawUndo()
        t:eq(p.session:pendingWrites(), 0, "Undo cannot enqueue a premature delete")
        t:eq(#p.session:cache():strokes(), 1, "unvalidated metadata stays intact")
        -- Drive the pen the way capture would if it were installed, so this
        -- reaches the readiness guard rather than an absent machine.
        p:buildStylusMachine(Device.input)
        seedPenBaseline(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 30, SHEET.y + 30)
        t:eq(p.canvas_stroke, nil, "an unvalidated cache accepts no live stroke")
        penLift(p, SHEET.x + 30, SHEET.y + 30)
        t:eq(p.session:pendingWrites(), 0, "a premature pen sample was ignored")
        p:releaseStylusMachine()
        env.UIManager:flush()
        t:eq(p.session:cache():isReady(), true, "the stored stroke validated")
        t:eq(p.drawing, true, "only then is capture enabled")
        t:eq(store.calls.stroke_chunk, 1, "one persisted chunk was streamed")
    end)

    t:case("an asynchronous load failure turns capture off and remains retryable", function()
        local canvas = {
            id = 42, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { canvas },
            strokes = { { canvas_id = canvas.id, stroke = {
                width = 4, tool = 1, points = { 100, 100, 200, 100 }, n = 2,
            } } },
        }
        store.fail_stroke_chunk = 0
        p:openCanvas(canvas)
        env.UIManager:flush()
        t:eq(p.session:loadFailed(), true, "corruption is visible as load_failed")
        t:eq(p.drawing, false, "the failed sheet does not capture input")
        t:eq(p.canvas_open, true, "Hide and Retry remain reachable")
        t:eq(p.bar.draw_btn.text, "Retry", "the toolbar exposes recovery")
        store.fail_stroke_chunk = nil
        t:eq(p:retryCanvasLoad(), true, "retry starts a fresh generation")
        t:eq(p.bar.draw_btn.text, "Loading", "retry reports its new state")
        env.UIManager:flush()
        t:eq(p.session:cache():isReady(), true, "retry rebuilt the raster")
        t:eq(p.drawing, true, "capture resumes after successful validation")
    end)

    t:case("closing the sheet brings the standalone toolbar back", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        t:eq(p.canvas_open, false, "closed")
        t:eq(p.drawing, false, "and drawing is off")
        t:check(p.bar ~= nil, "the toolbar is back")
        t:eq(p.bar.embedded, false, "as a window of its own")
    end)

    t:case("Hide with a sheet open puts the sheet away", function()
        -- The invariant: drawing is never on without a way to turn it off.
        local p = canvasPlugin()
        p:openCanvasHere()
        p:setBarShown(false)
        t:eq(p.canvas_open, false, "the sheet closed")
        t:eq(p.drawing, false, "and drawing stopped")
    end)

    t:case("the sheet gesture opens a sheet here", function()
        -- The same call the menu makes, bindable to a gesture: without it the
        -- only way back to a closed sheet is four taps into the menu.
        local p = canvasPlugin()
        t:eq(p:onJustDrawSheet(), true, "the event is consumed")
        t:eq(p.canvas_open, true, "and the sheet is up")
    end)

    t:case("the sheet gesture puts an open sheet away", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        t:eq(p:onJustDrawSheet(), true, "the event is consumed")
        t:eq(p.canvas_open, false, "and the sheet is gone")
    end)

    t:case("the sheet gesture on a fixed layout says why, once", function()
        -- A bound gesture that silently does nothing looks broken. The menu
        -- greys its entry out; a gesture has no grey, so it says why instead.
        ctx.reset()
        local p = support.newPlugin(ctx.JustDraw, env, {})
        env.UIManager:flush()
        p:onReaderReady()
        t:eq(p:onJustDrawSheet(), true, "the event is still consumed")
        t:eq(p.canvas_open, false, "nothing opened")
        t:eq(#env.notifications, 1, "the user was told")
        t:check(env.notifications[1]:find("not available", 1, true) ~= nil,
            "and told the sheet is unavailable, not that something failed")
    end)

    t:case("More on the embedded bar offers the sheet actions", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local function row(dialog, text)
            for _, r in ipairs(dialog and dialog.buttons or {}) do
                for _, btn in ipairs(r) do
                    if btn.text == text then return btn end
                end
            end
            return nil
        end
        p.bar.more_btn.callback()
        local dialog = env.dialogs[#env.dialogs]
        t:check(row(dialog, "Close sheet") ~= nil, "the sheet can be closed from the bar")
        t:check(row(dialog, "Delete sheet") ~= nil, "and deleted")
        t:eq(row(dialog, "Export…").enabled, true,
            "an open sheet is something to export")
        row(dialog, "Close sheet").callback()
        t:eq(p.canvas_open, false, "Close sheet puts the sheet away")
    end)

    t:case("Pen style's Marker is available with a sheet open", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local function row(dialog, text)
            for _, r in ipairs(dialog and dialog.buttons or {}) do
                for _, btn in ipairs(r) do
                    if btn.text == text then return btn end
                end
            end
            return nil
        end
        p.bar.more_btn.callback()
        row(env.dialogs[#env.dialogs], "Pen style").callback()
        local styles = env.dialogs[#env.dialogs]
        t:eq(row(styles, "Marker").enabled, true,
            "a sheet is ours to fill, so the marker has somewhere honest to draw")
        row(styles, "Marker").callback()
        t:eq(p.pen_style, 3, "the choice reached the plugin")
    end)

    t:case("a picked choice row never repaints after closing its dialog", function()
        -- Button:onTapSelectButton refreshes a checked button's label AFTER
        -- the callback ran; when the callback closed the dialog, that repaint
        -- stamps the dead row over the panel (the device photo of 2026-09-01:
        -- "Graphite ✓" stuck mid-sheet, clipping the toolbar). Rows that close
        -- on pick must carry the upstream opt-out.
        local p = canvasPlugin()
        p:openCanvasHere()
        for _, open in ipairs({
            { "Pen style", function() return p:showPenStyleDialog() end },
            { "Pen width", function() return p:showPenWidthDialog() end },
            { "Input mode", function() return p:showInputModeDialog() end },
        }) do
            open[2]()
            local dlg = env.dialogs[#env.dialogs]
            local checked = 0
            for _, r in ipairs(dlg.buttons) do
                for _, btn in ipairs(r) do
                    if btn.checked_func then
                        checked = checked + 1
                        t:eq(btn.no_refresh_checkmark, true, open[1] .. " / "
                            .. tostring(btn.text)
                            .. " must not repaint after its dialog closes")
                    end
                end
            end
            t:check(checked >= 3, open[1] .. " offers checked rows")
        end
    end)

    t:case("a failed Hide keeps the sheet and its retry controls alive", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        store.fail_transaction = "begin"
        local overlay, bar = p.session:overlay(), p.bar
        local ok = p:closeCanvas()
        t:eq(ok, nil, "close reports the save failure")
        t:eq(p.canvas_open, true, "main still agrees the sheet is open")
        t:eq(p.session:overlay(), overlay, "window retained")
        t:eq(p.bar, bar, "toolbar retained for Retry")
        t:eq(require("ink_capture").active, false,
            "failed durability disarms input immediately")
        env.UIManager:flush()
        t:eq(p.drawing, false, "new editing is stopped")
        t:eq(p.session:pendingWrites(), 1, "ink retained")
    end)

    t:case("a failed switch retains the old overlay and embedded toolbar", function()
        local first = {
            id = 51, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local second = {
            id = 52, anchor_kind = "xpointer", anchor_key = "xp:/body/p[8]",
            anchor_raw = "/body/p[8]", anchor_normalized = "/body/p[8]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { first, second },
            pages = { ["/body/p[7]"] = 1, ["/body/p[8]"] = 2 },
        }
        p:openCanvas(first)
        p:setDrawing(true)
        seedPenBaseline(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y + 20)
        penLift(p, SHEET.x + 20, SHEET.y + 20)
        t:eq(p.session:pendingWrites(), 1, "a real stroke is waiting behind the switch")
        store.fail_transaction = "begin"
        local old_overlay, old_bar = p.session:overlay(), p.bar
        local opened = p:openCanvas(second)
        t:eq(opened, nil, "the switch was refused")
        t:eq(p.session:activeCanvas().id, first.id, "the old sheet remains active")
        t:eq(p.session:overlay(), old_overlay, "the old window remains stacked")
        t:eq(p.bar, old_bar, "main still owns its embedded toolbar")
        t:eq(p.drawing, false, "capture stays off until Retry succeeds")
        t:eq(p.canvas_open, true, "the visible state remains coherent")
    end)

    t:case("a target load failure keeps the target open with Retry", function()
        local first = {
            id = 53, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local second = {
            id = 54, anchor_kind = "xpointer", anchor_key = "xp:/body/p[8]",
            anchor_raw = "/body/p[8]", anchor_normalized = "/body/p[8]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { first, second },
            pages = { ["/body/p[7]"] = 1, ["/body/p[8]"] = 2 },
        }
        p:openCanvas(first)
        store.fail_stroke_list = "read failed"
        local opened = p:openCanvas(second)
        t:check(opened ~= nil, "the unreadable target presents its recovery surface")
        t:eq(p.session:activeCanvas().id, second.id, "session retains the target")
        t:eq(p.canvas_open, true, "main agrees the failed sheet is open")
        t:check(p.bar ~= nil and p.bar.embedded, "Retry remains in the overlay")
        t:eq(p.bar.draw_btn.text, "Retry", "the failure is explicit, not a blank editable page")
        t:eq(p.drawing, false, "capture is off")
        store.fail_stroke_list = nil
        t:eq(p:retryCanvasLoad(), true, "the target can be retried in place")
        env.UIManager:flush()
        t:eq(p.drawing, true, "successful recovery resumes drawing")
    end)

    t:case("rotation keeps main bound to the overlay's rebuilt toolbar", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local old = p.bar
        p:onScreenResize()
        t:check(p.bar ~= old, "geometry produced a new embedded bar")
        t:eq(p.bar, p.session:overlay().bar, "main adopted the visible bar")
        t:eq(p.bar.embedded, true, "not a standalone replacement")
    end)

    t:case("height changes keep every toolbar action bound to the visible bar", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local old = p.bar
        p.session:overlay():setHeight(40)
        t:check(p.bar ~= old, "the embedded bar was replaced")
        t:eq(p.bar, p.session:overlay().bar, "main owns the replacement")
        p.bar.draw_btn.callback()
        t:eq(p.drawing, false, "Stop on the visible bar controls capture")
        t:eq(p.bar.draw_btn.text, "Draw", "and its own label updates")
    end)

    t:case("changing toolbar side moves the embedded bar and preserves ownership", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local right_x = p.bar.dimen.x
        p:sideItem("Left", "left").callback()
        t:eq(p.bar, p.session:overlay().bar, "main owns the rebuilt left bar")
        t:eq(p.session:overlay().bar_side, "left", "the overlay keeps the preference")
        t:check(p.bar.dimen.x < right_x, "the visible bar moved to the left")
        t:eq(p.drawing, true, "changing chrome did not interrupt ink")
    end)

    t:case("rotation aborts a live stroke before the populated cache reloads", function()
        local canvas = {
            id = 55, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p = canvasPlugin{
            canvases = { canvas },
            strokes = { { canvas_id = canvas.id, stroke = {
                width = 4, tool = 1, points = { 100, 100, 200, 100 }, n = 2,
            } } },
        }
        p:openCanvas(canvas)
        env.UIManager:flush()
        p:setDrawing(true)
        seedPenBaseline(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y + 20)
        t:check(p.canvas_stroke ~= nil, "a stroke is in flight when the screen turns")
        local old_w, old_h = Device.screen.w, Device.screen.h
        Device.screen.w, Device.screen.h = old_h, old_w
        p:onScreenResize()
        t:eq(p.canvas_stroke, nil, "the in-flight stroke was repaired first")
        t:eq(p.drawing, false, "capture is suspended")
        t:eq(p.session:cache():stateName(), "loading", "while vectors replay")
        t:eq(p.bar.draw_btn.text, "Loading", "the rebuilt visible bar reports it")
        env.UIManager:flush()
        t:eq(p.session:cache():isReady(), true, "the rotated raster completes")
        t:eq(p.drawing, true, "and capture resumes only then")
        Device.screen.w, Device.screen.h = old_w, old_h
        p:onScreenResize()
        env.UIManager:flush()
    end)

    t:case("deleting the active sheet clears main and session together", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        local active = p.session:activeCanvas()
        t:eq(p:deleteCanvas(active), true, "deleted")
        t:eq(p.canvas_open, false, "main closed")
        t:eq(p.session:activeCanvas(), nil, "session closed")
        t:eq(#store.canvases, 0, "row gone")
        t:check(p.bar ~= nil and not p.bar.embedded, "standalone toolbar restored")
    end)

    t:case("a failed active delete changes neither UI nor pending ink", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        store.fail_delete_canvas = "disk full"
        local overlay = p.session:overlay()
        local ok = p:deleteCanvas(p.session:activeCanvas())
        t:eq(ok, nil, "delete refused")
        t:eq(p.canvas_open, true, "main remains open")
        t:eq(p.session:overlay(), overlay, "same overlay")
        t:eq(p.session:pendingWrites(), 1, "pending work preserved")
    end)

    t:case("opening where a sheet already exists opens that one", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        local first = p.session:activeCanvas()
        p:closeCanvas()
        p:openCanvasHere()
        t:eq(p.session:activeCanvas().id, first.id, "the same sheet")
        t:eq(#store.canvases, 1, "not a second one on the same paragraph")
    end)

    t:case("several sheets at one position ask rather than guess", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        -- A second sheet, anchored elsewhere but resolving to this page.
        local extra = p.canvas_repository:createCanvas(12, {
            anchor_kind = "xpointer", anchor_key = "xp:/body/p[9]",
            anchor_raw = "/body/p[9]", anchor_normalized = "/body/p[9]",
            logical_w = SW, logical_h = SH,
        })
        p.session.document.pages["/body/p[9]"] = 1
        p.session.index:add(extra, 1)
        env.dialogs = {}
        p:openCanvasHere()
        t:eq(#env.dialogs, 1, "a chooser came up")
        t:eq(p.canvas_open, false, "and nothing was opened behind the reader's back")
    end)

    -- =================================================================
    t:describe("main / regions")

    t:case("the screen is divided toolbar, handle, sheet, book", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local bar = p.bar.dimen
        t:eq(p:regionAt(bar.x + 5, bar.y + 5), "bar", "toolbar")
        t:eq(p:regionAt(HANDLE.x, HANDLE.y), "handle", "handle")
        t:eq(p:regionAt(SHEET.x, SHEET.y), "canvas", "sheet")
        t:eq(p:regionAt(READER.x, READER.y), "reader", "book")
    end)

    t:case("with no sheet open there is only the toolbar and the book", function()
        local p = canvasPlugin()
        local bar = p.bar.dimen
        t:eq(p:regionAt(bar.x + 5, bar.y + 5), "bar", "toolbar")
        t:eq(p:regionAt(SHEET.x, SHEET.y), "reader", "everything else is the book")
    end)

    -- =================================================================
    t:describe("main / drawing on a sheet")

    t:case("the pen inks on the sheet and the stroke is queued on lift", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        t:check(p.canvas_stroke ~= nil, "a stroke is in progress")
        t:eq(p.canvas_stroke.n, 2, "with both points")
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:eq(p.canvas_stroke, nil, "finished")
        t:eq(p.session:pendingWrites(), 1, "and waiting to be written")
    end)

    t:case("a sheet stroke persists its style in the tool column", function()
        local p, store = canvasPlugin()
        openForPen(p)
        local tr = p.session:overlay().transform
        p:startCanvasStroke(100, 100, tr, 3)
        p:endCanvasStroke()
        env.UIManager:flush()
        local rows = store:listStrokes(store.canvases[1].id)
        t:eq(rows[1].tool, 3, "the marker style reached the repository")
        t:eq(rows[1].width, p.pen_width * Style.widthScale(3) / tr.scale,
            "the marker's ×3 nib is baked into the stored width")
    end)

    t:case("the barrel highlighter draws the marker on a sheet", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y, 3)
        penFrame(p, SHEET.x + 40, SHEET.y, 3)
        penLift(p, SHEET.x + 40, SHEET.y)
        env.UIManager:flush()
        local rows = store:listStrokes(store.canvases[1].id)
        t:eq(rows[1].tool, 3, "stored as marker")
    end)

    t:case("canvas lift reuses a complete live raster", function()
        local p = canvasPlugin()
        openForPen(p)
        local cache = p.session:cache()
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        local before = #cache:buffer().writes
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:eq(#cache:buffer().writes, before,
            "registration adds no second raster pass")
        t:eq(#cache:strokes(), 1, "stroke metadata is still indexed")
    end)

    t:case("canvas generation mismatch repaints and presents fallback coverage", function()
        local p = canvasPlugin()
        openForPen(p)
        local cache = p.session:cache()
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        cache.generation = cache.generation + 1
        local before_writes = #cache:buffer().writes
        local before_refreshes = #Device.screen.refreshes
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:check(#cache:buffer().writes > before_writes,
            "stale token rasterizes the finished stroke once")
        t:check(#Device.screen.refreshes > before_refreshes,
            "fallback coverage is copied and refreshed")
    end)

    t:case("gray ink refreshes ride ui: grayscale, and no fence under the pen", function()
        -- On device the fast refresh is forced monochrome and drops gray
        -- (ADR-36) -- but partial is REAGL, whose completion fence with the
        -- pen reporting overflowed evdev and dropped input (crash (7).log,
        -- SYN_DROPPED). Live boxes over gray ink must use ui: it renders
        -- gray AND does not block while the pen reports (ADR-26). Once the
        -- sheet holds gray ink every box may cross it, eraser included.
        local p = canvasPlugin()
        openForPen(p)
        local cache = p.session:cache()
        local function kindsAfter(mark)
            local kinds = {}
            for i = mark + 1, #Device.screen.refreshes do
                kinds[#kinds + 1] = Device.screen.refreshes[i][1]
            end
            return table.concat(kinds, ",")
        end

        local mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        t:check(kindsAfter(mark):find("fast", 1, true) ~= nil,
            "pen ink on a clean sheet refreshes fast")
        t:check(kindsAfter(mark):find("ui", 1, true) == nil,
            "and needs no grayscale pass")

        p:setPenStyle(65)
        mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y + 40)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:check(kindsAfter(mark):find("ui", 1, true) ~= nil,
            "graphite refreshes through ui")
        t:check(kindsAfter(mark):find("fast", 1, true) == nil,
            "never through DU, which would drop it")
        t:check(kindsAfter(mark):find("partial", 1, true) == nil,
            "and never through partial, whose fence drops input under the pen")
        t:eq(cache:hasGrayInk(), true, "the sheet now holds gray ink")

        p:setPenStyle(1)
        mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        t:check(kindsAfter(mark):find("fast", 1, true) == nil
            and kindsAfter(mark):find("partial", 1, true) == nil,
            "a sheet holding gray ink refreshes even pen boxes through ui")

        p:setEraser(true)
        mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y + 40)
        penFrame(p, SHEET.x + 20, SHEET.y + 40)
        penLift(p, SHEET.x + 20, SHEET.y + 40)
        t:check(#Device.screen.refreshes > mark, "the eraser repainted")
        t:check(kindsAfter(mark):find("fast", 1, true) == nil
            and kindsAfter(mark):find("partial", 1, true) == nil,
            "eraser repaints over gray ink ride ui too")
    end)

    t:case("canvas fallback repaint waits until a modal uncovers the overlay", function()
        local p = canvasPlugin()
        local overlay = openForPen(p)
        local cache = p.session:cache()
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        cache.generation = cache.generation + 1

        local modal = { handleEvent = function() return true end }
        env.UIManager:show(modal)
        local before_blits = #Device.screen.bb.blits
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:eq(#Device.screen.bb.blits, before_blits,
            "fallback does not write through the modal")
        t:check(p.canvas_pending_repaint ~= nil,
            "the exact cache generation retains one pending union")

        env.UIManager:close(modal)
        local before_dirty = #env.UIManager.dirty
        overlay:paintTo(Device.screen.bb, 0, 0)
        t:eq(p.canvas_pending_repaint, nil, "overlay paint consumes the union")
        t:eq(#env.UIManager.dirty, before_dirty + 1,
            "uncover schedules one regional cleanup")
        local dirty = env.UIManager.dirty[#env.UIManager.dirty]
        t:eq(dirty[1], nil, "cleanup refresh does not repaint a widget")
        t:eq(dirty[2], "partial", "fallback receives a quality refresh")
    end)

    t:case("canvas framebuffer writes never cover toolbar or handle chrome", function()
        for _, side in ipairs({ "right", "left" }) do
            local p = canvasPlugin()
            local overlay = p:openCanvasHere()
            if side == "left" then p:sideItem("Left", "left").callback() end
            overlay = p.session:overlay()
            local tr = p.session:transform()
            local bar, handle = overlay.bar.dimen, overlay:handleRect()
            local sx = side == "right" and bar.x - 2 or bar.x + bar.w - 2
            local sy = bar.y + 8
            local box = {
                x = sx - tr.offset_x, y = sy - tr.offset_y, w = 5, h = 4,
            }
            local before = #Device.screen.bb.rects
            p:blitCanvasBox(box, tr)
            t:check(#Device.screen.bb.rects > before,
                side .. " toolbar is repainted over an intersecting nib")

            box = {
                x = math.floor(handle.x + handle.w / 2) - tr.offset_x,
                y = handle.y + handle.h - 2 - tr.offset_y,
                w = 5, h = 5,
            }
            before = #Device.screen.bb.rects
            p:blitCanvasBox(box, tr)
            t:check(#Device.screen.bb.rects > before,
                side .. " handle is repainted over an intersecting repair")

            local modal = { handleEvent = function() return true end }
            env.UIManager:show(modal)
            p:blitCanvasBox({
                x = sx - tr.offset_x, y = sy - tr.offset_y, w = 5, h = 4,
            }, tr)
            env.UIManager:close(modal)
            before = #Device.screen.bb.rects
            p:_flushCanvasPendingRepaint(false)
            t:check(#Device.screen.bb.rects > before,
                side .. " deferred repaint restores intersected chrome")
        end
    end)

    t:case("canvas repaint treats a toast as a visual occluder", function()
        local p = canvasPlugin()
        local overlay = p:openCanvasHere()
        local tr = p.session:transform()
        local toast = { toast = true, handleEvent = function() return false end }
        env.UIManager:show(toast)
        local before = #Device.screen.bb.blits
        p:blitCanvasBox({ x = 100, y = 100, w = 10, h = 10 }, tr)
        t:eq(#Device.screen.bb.blits, before,
            "direct ink does not punch through a toast")
        t:check(p.canvas_pending_repaint ~= nil,
            "hidden ink remains bound to the canvas generation")
        env.UIManager:close(toast)
        overlay:paintTo(Device.screen.bb, 0, 0)
        t:eq(p.canvas_pending_repaint, nil,
            "toast uncover consumes the pending repaint")
    end)

    t:case("canvas backpressure repairs ink and recovers after urgent commit", function()
        local p = canvasPlugin()
        openForPen(p)
        local surface = p.session.surface_session
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        surface.queue.hard_ops = 1

        penDown(p, SHEET.x, SHEET.y + 40)
        penFrame(p, SHEET.x + 20, SHEET.y + 40)
        penLift(p, SHEET.x + 20, SHEET.y + 40)
        t:eq(surface.queue:isFailed(), false, "transient pressure is not save_failed")
        t:eq(surface:pendingWrites(), 1, "admitted work remains queued")
        t:eq(#surface:cache():strokes(), 1, "rejected live stroke is repaired")
        t:eq(#env.notifications, 0, "no window opens inside the stylus callback")
        env.UIManager:flush()
        t:eq(surface:pendingWrites(), 0, "urgent action committed the admitted work")
        t:eq(#env.notifications, 1, "one deferred warning is shown")
        t:check(env.notifications[1]:find("write queue is busy", 1, true) ~= nil,
            "warning names the recoverable condition")

        penDown(p, SHEET.x, SHEET.y + 80)
        penLift(p, SHEET.x, SHEET.y + 80)
        t:eq(surface:pendingWrites(), 1, "the next physical contact is accepted")
        t:eq(#surface:cache():strokes(), 2, "durable and new ink remain visible")
    end)

    t:case("canvas backpressure repair never punches through a modal", function()
        local p = canvasPlugin()
        local overlay = openForPen(p)
        local surface = p.session.surface_session
        penDown(p, SHEET.x, SHEET.y)
        penLift(p, SHEET.x, SHEET.y)
        surface.queue.hard_ops = 1

        penDown(p, SHEET.x, SHEET.y + 40)
        penFrame(p, SHEET.x + 20, SHEET.y + 40)
        local modal = { handleEvent = function() return true end }
        env.UIManager:show(modal)
        local before_blits = #Device.screen.bb.blits
        penLift(p, SHEET.x + 20, SHEET.y + 40)
        t:eq(#Device.screen.bb.blits, before_blits,
            "repair remains behind the modal")
        t:check(p.canvas_pending_repaint ~= nil, "repair is retained")

        env.UIManager:close(modal)
        overlay:paintTo(Device.screen.bb, 0, 0)
        t:eq(p.canvas_pending_repaint, nil, "uncover presents the repaired cache")
    end)

    t:case("an oversized canvas operation disarms capture after the frame", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        p.session.addStroke = function() return nil, "operation_too_large" end

        penLift(p, SHEET.x + 20, SHEET.y)
        t:eq(Capture.active, true, "stylus callback leaves this frame filterable")
        t:check(p.canvas_pending_capture_stop ~= nil,
            "domain stop is latched until the residual handler")
        local kept = touchFrame(p, {
            { slot = 0, id = 9, x = SHEET.x, y = SHEET.y, tool = 0 },
        })
        t:eq(#kept, 0, "same-frame palm is filtered before capture stops")
        t:eq(Capture.active, false, "capture becomes inert after filtering")
        t:eq(p.drawing, true, "visible state stays stable through the frame")
        t:eq(p.session.surface_session.queue:isFailed(), false,
            "the domain error is not a transaction failure")
        env.UIManager:flush()
        t:eq(p.drawing, false, "capture is removed from a safe tick")
        t:eq(p.input_lease, nil, "the process lease is released")
    end)

    t:case("canvas fatal teardown preserves the real SYN pipeline", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p.session.addStroke = function() return nil, "operation_too_large" end
        local input = Device.input
        local callback = input.stylus_callback
        local replay = Replay.new{
            mode = "integration", input = input, capture = Capture,
        }
        replay:set(4, {
            id = 1, x = SHEET.x, y = SHEET.y, tool = Capture.TOOL_PEN,
        })
        replay:syn()
        replay:set(4, {
            id = -1, x = SHEET.x, y = SHEET.y, tool = Capture.TOOL_FINGER,
        })
        replay:set(5, {
            id = 2, x = SHEET.x + 20, y = SHEET.y + 20,
            tool = Capture.TOOL_PEN,
        })
        replay:set(0, {
            id = 9, x = SHEET.x + 10, y = SHEET.y + 10,
            tool = Capture.TOOL_FINGER,
        })
        local _, _, dominated = replay:syn()
        t:eq(#dominated, 2, "both stylus slots are dominated")
        t:eq(#input.gesture_detector.last_slots, 0,
            "palm is removed by the wrapped frame handler")
        t:eq(Capture.active, false, "capture stops only after frame filtering")
        t:eq(input.stylus_callback, callback,
            "callback identity survives until the safe tick")
        env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "safe tick removes callback")
        t:eq(p.drawing, false, "visible drawing state follows teardown")
        t:eq(p.router:touchCount(), 0,
            "lease teardown releases the same-frame palm latch")
        t:eq(p.router.pen_down, false,
            "lease teardown also releases physical pen ownership")

        p:setDrawing(true)
        t:eq(p.drawing, true, "drawing can be re-enabled after the domain stop")
        replay:set(0, {
            id = 10, x = READER.x, y = READER.y,
            tool = Capture.TOOL_FINGER,
        })
        replay:syn()
        t:eq(#input.gesture_detector.last_slots, 1,
            "the reused slot reaches GestureDetector in the new lease")
        t:eq(p.router:destinationOf(0), "reader",
            "the old palm classification does not survive reactivation")
        replay:set(0, {
            id = -1, x = READER.x, y = READER.y,
            tool = Capture.TOOL_FINGER,
        })
        replay:syn()
        t:eq(p.router:touchCount(), 0, "the new lease observes the reused-slot lift")
    end)

    t:case("the stroke reaches the database when settings are saved", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        p:onSaveSettings()
        local canvas_id = p.session:activeCanvas().id
        t:eq(#(store.strokes[canvas_id] or {}), 1, "one stroke on this sheet")
    end)

    t:case("a save failure repairs live ink and blocks capture until retry", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        t:eq(p.session:pendingWrites(), 1, "one durable operation is pending")

        -- Begin another stroke before the first one has been written. It
        -- exists only in the raster and must be repaired if the write fails.
        penDown(p, SHEET.x, SHEET.y + 30)
        penFrame(p, SHEET.x + 20, SHEET.y + 30)
        t:check(p.canvas_stroke ~= nil, "a second live stroke is visible")
        store.fail_transaction = "begin"
        -- The timer no longer fires under a contact (ADR-42), so the failure
        -- arrives the only way it now can with the pen down: a lifecycle
        -- gate, which still flushes synchronously.
        env.UIManager:flush()
        t:eq(store.calls.transaction, 0, "the timer stood aside for the pen")
        p:onSaveSettings()
        t:eq(Capture.active, false, "capture became inert in the failure tick")
        t:eq(p.drawing, true, "gesture suppression stays on through that frame")
        local before_repair = #p.session:cache():buffer().rects
        env.UIManager:flush()
        t:eq(p.drawing, false, "capture is visibly stopped from a safe tick")
        t:eq(p.canvas_stroke, nil, "the unqueued stroke was abandoned")
        t:check(#p.session:cache():buffer().rects > before_repair,
            "its dirty region was cleared and rebuilt")
        t:eq(#p.session:cache():strokes(), 1,
            "only the first, queued stroke remains in the raster index")
        t:eq(p.session:pendingWrites(), 1, "the failed write was retained")

        p:setDrawing(true)
        t:eq(p.drawing, false, "Draw is guarded while the queue is failed")
        store.fail_transaction = nil
        t:eq(p.session:retrySave(), true, "explicit retry commits the retained ink")
        t:eq(p.session:saveFailed(), false, "the failure latch clears")
        t:eq(p.drawing, true, "editing resumes after recovery")
    end)

    t:case("a chunk failure inside the eraser cannot unregister mid stylus frame", function()
        local canvas = {
            id = 56, anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]", anchor_normalized = "/body/p[7]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { canvas },
            strokes = { { canvas_id = canvas.id, stroke = {
                width = 4, tool = 1, points = { 100, 100, 200, 100 }, n = 2,
            } } },
        }
        p:openCanvas(canvas)
        env.UIManager:flush()
        p:setEraser(true)
        p:setDrawing(true)
        seedPenBaseline(p)
        store.fail_stroke_chunk = 0
        local sx, sy = p.session:transform():toScreen(150, 100)
        local input, cb = Device.input, Device.input.stylus_callback
        -- Land the contact first: the frame that opens it carries no fresh
        -- position, so nothing erases until the next pair.
        input.stylus_callback(input, { slot = 4, id = 2, tool = Capture.TOOL_ERASER })
        -- Slot 4 is the digitizer's own and really erases. Slot 0 is the palm
        -- KOReader routes here wearing the eraser's tool number; it must not
        -- be handed a callback that unregistered itself earlier in the frame.
        local frame = {
            { slot = 4, id = 2, x = sx, y = sy, tool = Capture.TOOL_ERASER },
            { slot = 0, id = 3, x = sx + 1, y = sy, tool = Capture.TOOL_ERASER },
        }
        local ok, err = pcall(function()
            for i = 1, #frame do input.stylus_callback(input, frame[i]) end
        end)
        t:eq(ok, true, "the full routeStylusEvents loop survived: " .. tostring(err))
        t:eq(input.stylus_callback, cb, "the callback remains registered in-frame")
        t:eq(Capture.active, false, "but it is already inert")
        -- The pen's own contact continues into the next frame while the hook
        -- is still installed and already disarmed. That is the shape that
        -- crashed KOReader when the callback unregistered itself in place.
        local continued, continue_err = pcall(input.stylus_callback, input,
            { slot = 4, id = 2, x = sx + 2, y = sy + 3, tool = Capture.TOOL_ERASER })
        t:eq(continued, true,
            "a later sample of the same contact is safe: " .. tostring(continue_err))
        env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "it unhooks on the safe tick")
        t:eq(p.drawing, false, "the failed sheet no longer captures")
        t:eq(p.bar.draw_btn.text, "Retry", "recovery remains reachable")
    end)

    t:case("the sheet's eraser cuts a stroke instead of swallowing it", function()
        local canvas = {
            id = 57, anchor_kind = "xpointer", anchor_key = "xp:/body/p[8]",
            anchor_raw = "/body/p[8]", anchor_normalized = "/body/p[8]",
            anchor_dom_version = 20240114, logical_w = SW, logical_h = SH,
        }
        local p, store = canvasPlugin{
            canvases = { canvas },
            strokes = { { canvas_id = canvas.id, stroke = {
                width = 4, tool = 1, n = 5,
                points = { 100, 100, 200, 100, 300, 100, 400, 100, 500, 100 },
            } } },
        }
        p:openCanvas(canvas)
        env.UIManager:flush()
        p:setEraser(true)
        p:setDrawing(true)
        seedPenBaseline(p)
        local original = store.strokes[canvas.id][1].id
        local sx, sy = p.session:transform():toScreen(300, 100)
        local input = Device.input
        input.stylus_callback(input, { slot = 4, id = 2, tool = Capture.TOOL_ERASER })
        input.stylus_callback(input,
            { slot = 4, id = 2, x = sx, y = sy, tool = Capture.TOOL_ERASER })
        input.stylus_callback(input,
            { slot = 4, id = -1, x = sx, y = sy, tool = 0 })
        env.UIManager:flush()
        t:eq(#store.strokes[canvas.id], 2, "two fragments were committed")
        t:eq(store.deleted[#store.deleted], original, "and the original deleted")
    end)

    t:case("stored coordinates are the sheet's, not the screen's", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        p:onSaveSettings()
        local s = store.strokes[p.session:activeCanvas().id][1]
        local tr = p.session:transform()
        local want_x, want_y = tr:toCanvas(SHEET.x, SHEET.y)
        t:check(math.abs(s.points[1] - want_x) < 1, "x is a canvas coordinate")
        t:check(math.abs(s.points[2] - want_y) < 1,
            "and y is measured from the top of the sheet, not the screen")
    end)

    t:case("the pen over the book text does not ink", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, READER.x, READER.y)
        t:eq(p.canvas_stroke, nil, "no stroke started")
    end)

    t:case("the pen over the book text is still dominated", function()
        -- Handing the slot back there would let a hold reach the reader from
        -- the same hand that is holding the pen.
        local p = canvasPlugin()
        openForPen(p)
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = READER.x, y = READER.y, tool = 1 },
            true, "kept from the gesture detector")
    end)

    t:case("the pen starting on the toolbar passes through", function()
        local p = canvasPlugin()
        openForPen(p)
        local bar = p.bar.dimen
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = bar.x + 5, y = bar.y + 5, tool = 1 },
            false, "so the button gets its tap")
        t:eq(p.canvas_stroke, nil, "and nothing is drawn")
    end)

    t:case("the pen starting on the handle passes through", function()
        local p = canvasPlugin()
        openForPen(p)
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = HANDLE.x, y = HANDLE.y, tool = 1 },
            false, "so the sheet can be resized with the pen")
    end)

    t:case("a stroke dragged off the sheet ends at the edge", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x, SHEET.y + 40)
        penFrame(p, READER.x, READER.y)
        t:eq(p.canvas_stroke, nil, "the stroke was closed rather than clamped")
        t:eq(p.session:pendingWrites(), 1, "and kept")
    end)

    t:case("undo removes the last stroke from the sheet", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        p:onJustDrawUndo()
        p:onSaveSettings()
        local canvas_id = p.session:activeCanvas().id
        t:eq(#(store.strokes[canvas_id] or {}), 0, "it never reached the disk")
    end)

    t:case("undo on an empty sheet says so instead of undoing a page", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        env.notifications = {}
        p:onJustDrawUndo()
        t:eq(#env.notifications, 1, "the reader is told")
    end)

    -- =================================================================
    t:describe("main / touch while a sheet is open")

    t:case("a finger above the sheet still reaches the reader", function()
        -- The point of the whole design: the book is readable with the sheet
        -- open.
        local p = canvasPlugin()
        openForPen(p)
        local kept = touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        t:eq(#kept, 1, "the contact goes to gesture detection")
    end)

    t:case("a palm on the sheet is withheld from gesture detection", function()
        local p = canvasPlugin()
        openForPen(p)
        local kept = touchFrame(p, { { slot = 0, id = 1, x = SHEET.x, y = SHEET.y } })
        t:eq(#kept, 0, "no contact, so no hold timer and no page turn")
    end)

    t:case("a palm's lift is withheld too", function()
        -- The detector never opened a contact for it; handing it a lift for
        -- one that does not exist is the kind of thing that strands slots.
        local p = canvasPlugin()
        openForPen(p)
        touchFrame(p, { { slot = 0, id = 1, x = SHEET.x, y = SHEET.y } })
        local kept = touchFrame(p, { { slot = 0, id = -1, x = SHEET.x, y = SHEET.y } })
        t:eq(#kept, 0, "nothing to hand back")
    end)

    t:case("a finger on the toolbar always gets through", function()
        local p = canvasPlugin()
        openForPen(p)
        local bar = p.bar.dimen
        local kept = touchFrame(p, { { slot = 0, id = 1, x = bar.x + 5, y = bar.y + 5 } })
        t:eq(#kept, 1, "Stop is always pressable")
    end)

    t:case("a finger landing while the pen is down is withheld anywhere", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        local kept = touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        t:eq(#kept, 0, "the hand does not turn the page mid-stroke")
    end)

    t:case("a finger already reading when the pen lands has its contact dropped", function()
        local p = canvasPlugin()
        openForPen(p)
        touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        local gd = Device.input.gesture_detector
        gd.active_contacts[0] = { slot = 0, pending_hold_timer = true }
        gd.dropped = {}
        penDown(p, SHEET.x, SHEET.y)
        touchFrame(p, {})
        t:eq(gd.dropped[1], 0, "its hold timer goes with it")
    end)

    t:case("a promoted palm on the sheet is not the eraser", function()
        -- Linux gives a rejected touch MT_TOOL_PALM, whose value is KOReader's
        -- ERASER, so a hand resting on the sheet arrives at the stylus
        -- callback looking exactly like the pen's other end. The recording
        -- that motivated this had it erasing whole pages.
        local Replays = require("wacom_scribe_replays")
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        local before = #p.session:cache():strokes()
        t:eq(before, 1, "one stroke on the sheet to erase")

        local input = Device.input
        local replay = Replay.new{ input = input, capture = Capture }
        replay:set(0, { id = 50, x = SHEET.x, y = SHEET.y, tool = Replays.TOOL_FINGER })
        replay:syn()
        replay:set(0, { x = SHEET.x + 5, y = SHEET.y + 5, tool = Replays.TOOL_ERASER })
        replay:syn()

        t:eq(p:hasActivePhysicalContact(), true, "the hand is on the glass")
        t:eq(#p.session:cache():strokes(), before, "and it erased nothing")
        t:eq(p.canvas_stroke, nil, "and drew nothing")
        t:eq(p.canvas_erase_ctx, nil, "and opened no erase context")

        replay:set(0, { id = -1 })
        replay:syn()
        t:eq(p:hasActivePhysicalContact(), false, "its lift releases the sheet")
        t:eq(#p.session:cache():strokes(), before, "with the ink still there")
        t:eq(p.router:touchCount(), 0, "and no router ownership left behind")
    end)

    t:case("the recorded stale pen pair draws no line across the sheet", function()
        local Replays = require("wacom_scribe_replays")
        local p = canvasPlugin()
        openForPen(p)
        local input = Device.input
        local replay = Replay.new{ input = input, capture = Capture }
        local tr = p.session:transform()

        -- The recorded numbers are screen coordinates from a Scribe; map the
        -- two that matter onto this sheet so both contacts land on paper.
        local stale_x, stale_y = SHEET.x, SHEET.y
        local real_x, real_y = SHEET.x + 300, SHEET.y + 120
        replay:set(4, { id = 4, x = stale_x - 4, y = stale_y - 4, tool = Replays.TOOL_PEN })
        replay:syn()
        replay:set(4, { x = stale_x, y = stale_y })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()

        -- A palm in between, then a contact-down frame with no ABS update at
        -- all: the slot still presents the pen's previous position.
        replay:set(0, { id = 40, x = SHEET.x + 10, y = SHEET.y + 10, tool = Replays.TOOL_ERASER })
        replay:syn()
        replay:set(0, { id = -1 })
        replay:syn()
        replay:set(4, { id = 5, tool = Replays.TOOL_PEN })
        replay:syn()
        t:eq(p.canvas_stroke, nil, "the sticky pair started nothing")
        replay:set(4, { x = real_x, y = real_y })
        replay:syn()

        local stroke = p.canvas_stroke
        t:check(stroke ~= nil, "the second contact draws where the pen really is")
        local cx, cy = tr:toCanvas(real_x, real_y)
        t:check(math.abs(stroke[1] - cx) < 1, "starting at the real x")
        t:check(math.abs(stroke[2] - cy) < 1, "and the real y")
        t:eq(stroke.n, 1, "with no segment back to the previous contact")
    end)

    t:case("touch navigation comes back when the pen lifts", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penLift(p, SHEET.x, SHEET.y)
        local kept = touchFrame(p, { { slot = 1, id = 2, x = READER.x, y = READER.y } })
        t:eq(#kept, 1, "reading works again straight away")
    end)

    t:case("a pen slot handed back is not counted as touch", function()
        local p = canvasPlugin()
        openForPen(p)
        local kept = touchFrame(p, { { slot = 4, id = 1, x = READER.x, y = READER.y, tool = 1 } })
        t:eq(#kept, 1, "it is the pen, not a finger")
    end)

    -- =================================================================
    t:describe("main / marks and page turns")

    t:case("a page with a sheet on it gets a mark", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        p:onPageUpdate(1)
        local bb = support.newBlitbuffer(SW, SH)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.rects, 1, "one flag in the margin")
    end)

    t:case("the mark is on the edge away from the toolbar", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        p:onPageUpdate(1)
        local bb = support.newBlitbuffer(SW, SH)
        p:paintTo(bb, 0, 0)
        t:eq(bb.rects[1].x, 0, "left edge, with the toolbar on the right")
    end)

    t:case("painting a mark issues no query and asks the document nothing", function()
        local p, store, doc = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        p:onPageUpdate(1)
        local queries = store.calls.list + store.calls.read
        local checks = doc.in_page_checks
        local bb = support.newBlitbuffer(SW, SH)
        for _ = 1, 10 do p:paintTo(bb, 0, 0) end
        t:eq(store.calls.list + store.calls.read, queries, "no database")
        t:eq(doc.in_page_checks, checks, "no CREngine")
    end)

    t:case("PosUpdate is read as (position, page), not as (page)", function()
        -- readerrolling emits PosUpdate with the scroll offset first. Taking
        -- the first argument as a page number puts every mark on the wrong
        -- page in scroll mode, or on none.
        local p = canvasPlugin()
        p:openCanvasHere()
        p:closeCanvas()
        p:onPosUpdate(48291, 1)
        local bb = support.newBlitbuffer(SW, SH)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.rects, 1, "the mark is on page 1, not on page 48291")
    end)

    t:case("a page with no sheet has no mark", function()
        local p = canvasPlugin()
        p:onPageUpdate(1)
        local bb = support.newBlitbuffer(SW, SH)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.rects, 0, "nothing painted")
    end)

    t:case("a rerender rebuilds the index and reads no ink", function()
        local p, store, doc = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        p:onSaveSettings()
        p:closeCanvas()
        local reads = store.calls.stroke_read
        doc.hash = "layout-b"
        p:onDocumentRerendered()
        env.UIManager:flush()
        t:eq(store.calls.stroke_read, reads, "reflow moves the sheet, not the ink")
    end)

    -- =================================================================
    t:describe("main / shutting down")

    t:case("teardown closes the session and writes what is pending", function()
        local p, store = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        local canvas_id = p.session:activeCanvas().id
        p:teardown()
        t:eq(p.session, nil, "no session left")
        t:eq(p.canvas_open, false, "no sheet open")
        t:eq(#(store.strokes[canvas_id] or {}), 1, "and the stroke was saved")
    end)

    t:case("teardown with no session is harmless", function()
        ctx.reset()
        local p = support.newPlugin(ctx.JustDraw, env, {})
        env.UIManager:flush()
        p:teardown()
        t:eq(p.session, nil, "nothing to close")
    end)

    t:case("suspending stops drawing and leaves the sheet consistent", function()
        local p = canvasPlugin()
        openForPen(p)
        penDown(p, SHEET.x, SHEET.y)
        p:onSuspend()
        t:eq(p.drawing, false, "drawing stopped")
        t:eq(p.canvas_stroke, nil, "and no half a stroke is left dangling")
    end)
    -- =================================================================
    t:describe("main / the book's dossier")

    --[[--
    What a reflowable book offers to export, once there is more than one kind
    of note in it (ADR-40).

    The sheets scope and the dossier disagree about the anchor index on
    purpose: "All drawing sheets" is not offered at all without a reading
    order, while "Document notes" is offered and *disabled*, because a reader
    whose book has notes in it should be told the option exists and is not
    ready rather than left to wonder where it went.
    ]]

    local function scopeNamed(p, value)
        for _, entry in ipairs(p:exportScopes()) do
            if entry.value == value then return entry end
        end
        return nil
    end

    t:case("the sheets scope says what it covers", function()
        local canvases, pages = manySheets(2)
        local p = canvasPlugin{ canvases = canvases, pages = pages }
        local sheets = scopeNamed(p, "sheets")
        t:check(sheets ~= nil, "the scope is there")
        t:eq(sheets.label, "All drawing sheets", "under a name that is not a page")
    end)

    t:case("deciding the scopes reads the index, never a listing of every sheet", function()
        local canvases, pages = manySheets(40)
        local p, store = canvasPlugin{ canvases = canvases, pages = pages }
        local lists = store.calls.list
        local sheets = scopeNamed(p, "sheets")
        t:check(sheets ~= nil, "the scope is still offered")
        t:eq(store.calls.list, lists,
            "and no listCanvases was needed to decide that (ADR-42)")
        -- The enumeration itself is the reader's choice, and pays for itself.
        local built = p:buildExport("sheets")
        t:check(built ~= nil, "the export still enumerates when asked")
        t:check(store.calls.list > lists, "which is where the listing belongs")
    end)

    t:case("a book with sheets offers its whole dossier", function()
        local canvases, pages = manySheets(2)
        local p = canvasPlugin{ canvases = canvases, pages = pages }
        local notes = scopeNamed(p, "notes")
        t:check(notes ~= nil, "the dossier is offered")
        t:check(notes.enabled ~= false, "and it is live once the index is whole")
        local built, err = p:buildExport("notes")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:eq(#built.items, 2, "both sheets")
        t:eq(built.items[1].kind, "sheet", "as sheets")
        t:eq(built.confirm_warning, nil, "with nothing to warn about")
    end)

    t:case("while the index builds, the dossier is offered and refused", function()
        local canvases, pages = manySheets(3)
        local p = canvasPlugin{ canvases = canvases, pages = pages,
            keep_indexing = true }
        p.store:add(2, { n = 2, w = 4, 10, 10, 30, 10 })
        local notes = scopeNamed(p, "notes")
        t:check(notes ~= nil, "the reader can see the option exists")
        t:eq(notes.enabled, false, "and that it is not ready")
        t:eq(notes.reason, "index_incomplete", "for the reason it already knows")
        local built, err = p:buildExport("notes")
        t:check(built == nil, "and asking for it anyway refuses")
        t:eq(err, "index_incomplete", "with the same reason")
        settleIndex(p)
        t:check(scopeNamed(p, "notes").enabled ~= false,
            "once the index is whole it is live")
    end)

    t:case("legacy ink in a book with no sheets is still a dossier", function()
        local p = canvasPlugin()
        p.store:add(4, { n = 2, w = 4, 10, 10, 30, 10 })
        t:check(scopeNamed(p, "notes") ~= nil, "the sidecar is a note")
        t:check(p:canExport(), "and the menu entry is live for it")
        local built, err = p:buildExport("notes")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:eq(#built.items, 1, "one page of legacy ink")
        t:eq(built.items[1].kind, "legacy_page", "as legacy")
        t:check(type(built.confirm_warning) == "string", "and it is warned about")
    end)

    t:case("a book with nothing in it offers no dossier", function()
        local p = canvasPlugin()
        t:eq(scopeNamed(p, "notes"), nil, "nothing to gather")
    end)

    t:describe("main / live boxes reach the panel at a bounded cadence (ADR-43)")

    -- The fake `ui/time` is frozen unless a case moves it; `s(1)` is a
    -- million, the same fixed point the device uses.
    local clock = require("ui/time")
    local function at(seconds) clock._set(seconds * clock.s(1)) end

    -- A contact-down paints nothing -- a single point has no segment, and a
    -- dot is painted at the lift -- so the first *box* of a stroke is its
    -- first penFrame.

    t:case("fifty pen frames inside one interval are one refresh, and the lift flushes the union", function()
        local p = canvasPlugin()
        openForPen(p)
        at(0)
        local mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 1, SHEET.y + 1)
        local first = #Device.screen.refreshes
        t:eq(first, mark + 1, "the first segment of a stroke goes out at once")
        for i = 2, 50 do penFrame(p, SHEET.x + i, SHEET.y + i) end
        t:eq(#Device.screen.refreshes, first, "the next forty-nine are held")
        penLift(p, SHEET.x + 50, SHEET.y + 50)
        t:eq(#Device.screen.refreshes, first + 1, "the lift flushed them as one")
        local r = Device.screen.refreshes[first + 1]
        t:check(r[4] >= 45 and r[5] >= 45, "and the union covers the whole run")
        env.UIManager:flush()
        t:eq(#Device.screen.refreshes, first + 1, "the stale trailing timer found nothing")
    end)

    t:case("a frame past the interval refreshes from the callback, at the cadence", function()
        local p = canvasPlugin()
        openForPen(p)
        at(0)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 5, SHEET.y)          -- the first segment: immediate
        local mark = #Device.screen.refreshes
        at(0.010); penFrame(p, SHEET.x + 10, SHEET.y)
        at(0.015); penFrame(p, SHEET.x + 15, SHEET.y)
        t:eq(#Device.screen.refreshes, mark, "inside the fast interval nothing goes out")
        at(0.021); penFrame(p, SHEET.x + 21, SHEET.y)
        t:eq(#Device.screen.refreshes, mark + 1, "the sample that crossed 20 ms flushed")
        t:eq(Device.screen.refreshes[mark + 1][1], "fast", "as fast on a clean sheet")
    end)

    t:case("gray ink is coalesced on the slow interval and stays ui", function()
        local p = canvasPlugin()
        openForPen(p)
        p:setPenStyle(65)                          -- graphite, as the case above does
        at(0)
        local mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y + 40)
        penFrame(p, SHEET.x + 10, SHEET.y + 40)
        t:eq(#Device.screen.refreshes, mark + 1, "the first gray segment went out")
        t:eq(Device.screen.refreshes[mark + 1][1], "ui", "gray rides ui")
        at(0.05); penFrame(p, SHEET.x + 20, SHEET.y + 40)
        t:eq(#Device.screen.refreshes, mark + 1, "50 ms is inside the slow interval")
        at(0.11); penFrame(p, SHEET.x + 40, SHEET.y + 40)
        t:eq(#Device.screen.refreshes, mark + 2, "110 ms crossed it")
        t:eq(Device.screen.refreshes[mark + 2][1], "ui", "still ui")
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        for i = mark + 1, #Device.screen.refreshes do
            t:check(Device.screen.refreshes[i][1] ~= "fast", "no fast box over a gray sheet")
        end
    end)

    t:case("with live fast off a device whose partial blocks rides ui, not partial", function()
        local p = canvasPlugin()
        openForPen(p)
        p.live_fast = false
        local was = Device.isMTK
        Device.isMTK = function() return true end
        at(0)
        local mark = #Device.screen.refreshes
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 10, SHEET.y + 10)
        penLift(p, SHEET.x + 10, SHEET.y + 10)
        Device.isMTK = was
        t:check(#Device.screen.refreshes > mark, "something went out")
        for i = mark + 1, #Device.screen.refreshes do
            t:eq(Device.screen.refreshes[i][1], "ui",
                "never partial with the pen down on MTK (ADR-26)")
        end
    end)

    t:case("turning Draw off flushes what was pending and leaves no timer", function()
        local p = canvasPlugin()
        openForPen(p)
        at(0)
        penDown(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 5, SHEET.y + 5)
        at(0.005); penFrame(p, SHEET.x + 8, SHEET.y + 8)
        local mark = #Device.screen.refreshes
        p:setDrawing(false)
        t:check(#Device.screen.refreshes >= mark + 1, "the held box went out on stop")
        t:eq(p.live_refresh:hasPending(), false, "nothing pending")
    end)

    t:describe("main / an evdev overflow ends the stroke, it does not bridge it (ADR-44)")

    t:case("a kernel drop mid-stroke persists what was drawn and nothing across the gap", function()
        local p, store = canvasPlugin()
        openForPen(p)
        -- The steer's counters, driven by hand: the harness arms no steer, so
        -- production's `Capture:steerCounts` closure would answer zeros.
        local drops, edges = 0, 0
        p.stylus_sequence.sync_counts = function() return drops, edges end
        penDown(p, SHEET.x + 10, SHEET.y + 10)
        penFrame(p, SHEET.x + 20, SHEET.y + 20)
        penFrame(p, SHEET.x + 30, SHEET.y + 30)
        drops = 1
        penFrame(p, SHEET.x + 30, SHEET.y + 200)   -- the half-updated frame
        penFrame(p, SHEET.x + 200, SHEET.y + 200)
        edges = 1
        penLift(p, SHEET.x + 200, SHEET.y + 200)
        env.UIManager:flush()
        p:onSaveSettings()

        local strokes = store.strokes[p.session:activeCanvas().id] or {}
        t:eq(#strokes, 1, "one stroke reached the store")
        t:eq(strokes[1].n, 3, "with the points from before the drop, and no more")
        t:eq(p.evdev_desyncs, 1, "the plugin counted the desync")
        t:eq(p.evdev_desync_cuts, 1, "and that it cost a stroke")
    end)

    t:describe("main / a sheet is on the panel the moment it opens")

    --[[--
    A sheet with no strokes rasterises synchronously, inside the session's
    open, before the overlay widget exists -- so the `on_ready` that would
    have refreshed it is dropped, and `UIManager:show` without a refresh type
    only repaints. On the device the reader saw the page, unchanged, until
    some later modal flashed the screen (crash.log 2026-09-02, 11909-11930).
    ]]
    t:case("opening a sheet with no strokes enqueues a ui refresh for the overlay itself", function()
        local p = canvasPlugin()
        local before = #env.UIManager.dirty
        local overlay = p:openCanvasHere()
        t:check(overlay ~= nil, "the sheet opened")
        local found = false
        for i = before + 1, #env.UIManager.dirty do
            local d = env.UIManager.dirty[i]
            if d[1] == overlay and d[2] == "ui" and d[3] == nil then found = true end
        end
        t:eq(found, true,
            "the overlay's own full ui refresh, not only the toolbar's region")
    end)
end
