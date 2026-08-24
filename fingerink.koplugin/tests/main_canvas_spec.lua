--[[--
The plugin with a sheet open: the parts only the whole thing can show.

Every module below this has been checked on its own. What is left is what only
appears when they are wired together, and it is mostly about two things.

One is that there is never more than one FingerInk window. The standalone
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

    local SW, SH = Device.screen.w, Device.screen.h

    -- Sheet at 70%: top edge at 240, handle 240..263, canvas below that.
    local SHEET = { x = 100, y = 500 }
    local READER = { x = 100, y = 100 }
    local HANDLE = { x = 100, y = 250 }

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
        local p = support.newPlugin(ctx.FingerInk, env, { document = doc })
        p.canvas_repository = store
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        return p, store, doc
    end

    local function penFrame(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penLift(p, x, y)
        p:onStylusEvent{ slot = 4, id = -1, x = x, y = y }
    end

    local function touchFrame(p, slots)
        return p:onStylusTouchFrame(slots)
    end

    -- =================================================================
    t:describe("main / canvas availability")

    t:case("a fixed-layout document gets no session at all", function()
        ctx.reset()
        local p = support.newPlugin(ctx.FingerInk, env, {})
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
        local p = support.newPlugin(ctx.FingerInk, env, {})
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
        local p = support.newPlugin(ctx.FingerInk, env, { document = doc })
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
        t:eq(ours, 1, "one FingerInk window")
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
        p:onFingerInkUndo()
        t:eq(p.session:pendingWrites(), 0, "Undo cannot enqueue a premature delete")
        t:eq(#p.session:cache():strokes(), 1, "unvalidated metadata stays intact")
        penFrame(p, SHEET.x, SHEET.y)
        penLift(p, SHEET.x, SHEET.y)
        t:eq(p.session:pendingWrites(), 0, "a premature pen sample was ignored")
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

    t:case("a failed Hide keeps the sheet and its retry controls alive", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        store.fail_transaction = "begin"
        local overlay, bar = p.session:overlay(), p.bar
        local ok = p:closeCanvas()
        t:eq(ok, nil, "close reports the save failure")
        t:eq(p.canvas_open, true, "main still agrees the sheet is open")
        t:eq(p.session:overlay(), overlay, "window retained")
        t:eq(p.bar, bar, "toolbar retained for Retry")
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
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
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
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
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
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
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
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        t:check(p.canvas_stroke ~= nil, "a stroke is in progress")
        t:eq(p.canvas_stroke.n, 2, "with both points")
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        t:eq(p.canvas_stroke, nil, "finished")
        t:eq(p.session:pendingWrites(), 1, "and waiting to be written")
    end)

    t:case("the stroke reaches the database when settings are saved", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y + 40)
        penLift(p, SHEET.x + 40, SHEET.y + 40)
        p:onSaveSettings()
        local canvas_id = p.session:activeCanvas().id
        t:eq(#(store.strokes[canvas_id] or {}), 1, "one stroke on this sheet")
    end)

    t:case("a save failure repairs live ink and blocks capture until retry", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 20, SHEET.y)
        penLift(p, SHEET.x + 20, SHEET.y)
        t:eq(p.session:pendingWrites(), 1, "one durable operation is pending")

        -- Begin another stroke before the first one's timer fires. It exists
        -- only in the raster and must be repaired if that timer fails.
        penFrame(p, SHEET.x, SHEET.y + 30)
        penFrame(p, SHEET.x + 20, SHEET.y + 30)
        t:check(p.canvas_stroke ~= nil, "a second live stroke is visible")
        store.fail_transaction = "begin"
        env.UIManager:flush()
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
        store.fail_stroke_chunk = 0
        local sx, sy = p.session:transform():toScreen(150, 100)
        local input, cb = Device.input, Device.input.stylus_callback
        local frame = {
            { slot = 2, id = 1, x = sx, y = sy, tool = Capture.TOOL_ERASER },
            { slot = 4, id = 2, x = sx + 1, y = sy, tool = Capture.TOOL_PEN },
        }
        local ok, err = pcall(function()
            for i = 1, #frame do input.stylus_callback(input, frame[i]) end
        end)
        t:eq(ok, true, "the full routeStylusEvents loop survived: " .. tostring(err))
        t:eq(input.stylus_callback, cb, "the callback remains registered in-frame")
        t:eq(Capture.active, false, "but it is already inert")
        env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "it unhooks on the safe tick")
        t:eq(p.drawing, false, "the failed sheet no longer captures")
        t:eq(p.bar.draw_btn.text, "Retry", "recovery remains reachable")
    end)

    t:case("stored coordinates are the sheet's, not the screen's", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
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
        p:openCanvasHere()
        penFrame(p, READER.x, READER.y)
        t:eq(p.canvas_stroke, nil, "no stroke started")
    end)

    t:case("the pen over the book text is still dominated", function()
        -- Handing the slot back there would let a hold reach the reader from
        -- the same hand that is holding the pen.
        local p = canvasPlugin()
        p:openCanvasHere()
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = READER.x, y = READER.y, tool = 1 },
            true, "kept from the gesture detector")
    end)

    t:case("the pen starting on the toolbar passes through", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local bar = p.bar.dimen
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = bar.x + 5, y = bar.y + 5, tool = 1 },
            false, "so the button gets its tap")
        t:eq(p.canvas_stroke, nil, "and nothing is drawn")
    end)

    t:case("the pen starting on the handle passes through", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        t:eq(p:onStylusEvent{ slot = 4, id = 1, x = HANDLE.x, y = HANDLE.y, tool = 1 },
            false, "so the sheet can be resized with the pen")
    end)

    t:case("a stroke dragged off the sheet ends at the edge", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x, SHEET.y + 40)
        penFrame(p, READER.x, READER.y)
        t:eq(p.canvas_stroke, nil, "the stroke was closed rather than clamped")
        t:eq(p.session:pendingWrites(), 1, "and kept")
    end)

    t:case("undo removes the last stroke from the sheet", function()
        local p, store = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penFrame(p, SHEET.x + 40, SHEET.y)
        penLift(p, SHEET.x + 40, SHEET.y)
        p:onFingerInkUndo()
        p:onSaveSettings()
        local canvas_id = p.session:activeCanvas().id
        t:eq(#(store.strokes[canvas_id] or {}), 0, "it never reached the disk")
    end)

    t:case("undo on an empty sheet says so instead of undoing a page", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        env.notifications = {}
        p:onFingerInkUndo()
        t:eq(#env.notifications, 1, "the reader is told")
    end)

    -- =================================================================
    t:describe("main / touch while a sheet is open")

    t:case("a finger above the sheet still reaches the reader", function()
        -- The point of the whole design: the book is readable with the sheet
        -- open.
        local p = canvasPlugin()
        p:openCanvasHere()
        local kept = touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        t:eq(#kept, 1, "the contact goes to gesture detection")
    end)

    t:case("a palm on the sheet is withheld from gesture detection", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local kept = touchFrame(p, { { slot = 0, id = 1, x = SHEET.x, y = SHEET.y } })
        t:eq(#kept, 0, "no contact, so no hold timer and no page turn")
    end)

    t:case("a palm's lift is withheld too", function()
        -- The detector never opened a contact for it; handing it a lift for
        -- one that does not exist is the kind of thing that strands slots.
        local p = canvasPlugin()
        p:openCanvasHere()
        touchFrame(p, { { slot = 0, id = 1, x = SHEET.x, y = SHEET.y } })
        local kept = touchFrame(p, { { slot = 0, id = -1, x = SHEET.x, y = SHEET.y } })
        t:eq(#kept, 0, "nothing to hand back")
    end)

    t:case("a finger on the toolbar always gets through", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        local bar = p.bar.dimen
        local kept = touchFrame(p, { { slot = 0, id = 1, x = bar.x + 5, y = bar.y + 5 } })
        t:eq(#kept, 1, "Stop is always pressable")
    end)

    t:case("a finger landing while the pen is down is withheld anywhere", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        local kept = touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        t:eq(#kept, 0, "the hand does not turn the page mid-stroke")
    end)

    t:case("a finger already reading when the pen lands has its contact dropped", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        touchFrame(p, { { slot = 0, id = 1, x = READER.x, y = READER.y } })
        local gd = Device.input.gesture_detector
        gd.active_contacts[0] = { slot = 0, pending_hold_timer = true }
        gd.dropped = {}
        penFrame(p, SHEET.x, SHEET.y)
        touchFrame(p, {})
        t:eq(gd.dropped[1], 0, "its hold timer goes with it")
    end)

    t:case("touch navigation comes back when the pen lifts", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        penLift(p, SHEET.x, SHEET.y)
        local kept = touchFrame(p, { { slot = 1, id = 2, x = READER.x, y = READER.y } })
        t:eq(#kept, 1, "reading works again straight away")
    end)

    t:case("a pen slot handed back is not counted as touch", function()
        local p = canvasPlugin()
        p:openCanvasHere()
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
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
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
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
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
        local p = support.newPlugin(ctx.FingerInk, env, {})
        env.UIManager:flush()
        p:teardown()
        t:eq(p.session, nil, "nothing to close")
    end)

    t:case("suspending stops drawing and leaves the sheet consistent", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        penFrame(p, SHEET.x, SHEET.y)
        p:onSuspend()
        t:eq(p.drawing, false, "drawing stopped")
        t:eq(p.canvas_stroke, nil, "and no half a stroke is left dangling")
    end)
end
