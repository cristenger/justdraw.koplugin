--[[--
The plugin over a fixed-layout document: page ink through the reader.

Everything below this has its own spec -- the row, the raster, the transform,
the session. What only appears here is the wiring, and it is three promises.

The first is the gate. `Capture:supportsStylus()` decides whether any of this
exists (ADR-41), and with it false the plugin is the one it always was: direct
ink into the sidecar, no session, no menu.

The second is composition. A page-ink raster is a transparent layer over the
book's own page, so every copy of it is an `alphablitFrom` -- a `blitFrom`
would land its alpha-0 pixels as black and put a rectangle over the text --
and nothing that is *taken off* it can be un-painted by copying: erase and undo
have to repaint the page through the view.

The third is that the reader is told why, in words, whenever drawing is
refused. Geometry-changing views offer a separate page sheet; transient or
invalid state keeps its specific error and does not suggest one.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Device = ctx.Device
    local Style = require("ink_style")
    local Capture = require("ink_capture")
    local Blitbuffer = require("ffi/blitbuffer")

    -- A4 in points as MuPDF reports it (595.276 x 841.89), rounded up the way
    -- `DocumentTransform.surfaceSpec` rounds it.
    local PAGE_W, PAGE_H = 596, 842
    -- The fixture's view: the whole page on screen at zoom 0.5, so the page is
    -- 298x421 at the origin and everything right of x=298 or below y=421 is
    -- surround.
    local SCALE = 0.5
    local INK_XY = { x = 100, y = 100 }
    local SURROUND = { x = 380, y = 100 }

    local function pageRow(id, page)
        return {
            id = id,
            anchor_kind = "page",
            anchor_key = "page-ink:" .. tostring(page),
            fixed_page = page,
            surface_role = "page_ink",
            coordinate_space = "native_page",
            logical_w = PAGE_W,
            logical_h = PAGE_H,
        }
    end

    --- A sheet row, which nothing on the page-ink route may touch.
    local function sheetRow(id, xp)
        return {
            id = id, anchor_kind = "xpointer", anchor_key = "xp:" .. xp,
            anchor_raw = xp, logical_w = 600, logical_h = 800,
        }
    end

    local function fixedSheetRow(id, page)
        return {
            id = id, anchor_kind = "page", anchor_key = "pdf-sheet:" .. id,
            fixed_page = page, surface_role = "sheet", coordinate_space = "surface",
            logical_w = 600, logical_h = 800,
        }
    end

    local function bar_stroke()
        return { width = 8, tool = 1, n = 3,
                 points = { 100, 100, 200, 100, 300, 100 } }
    end

    --[[--
    A plugin over a PDF, with its page-ink database in memory.

    `document_cache_opts` is the same seam `canvas_repository` is: the suite's
    fake buffer has no pixels, so the transparent clear an overlay erases
    through arrives injected (see canvas_cache_spec).
    ]]
    local function documentPlugin(opts)
        opts = opts or {}
        local input = { wacom_protocol = true }
        if opts.stylus_api == false then input.stylus_api = false end
        ctx.reset(input)
        local store = opts.store or support.newCanvasStore(opts.canvases or {})
        if opts.read_only then
            store.read_only = true
            function store:findBookId(partial_md5, file_size)
                if not partial_md5 or not file_size then return nil, "no_identity" end
                return 12
            end
        end
        for id, list in pairs(opts.strokes or {}) do
            for _, s in ipairs(list) do store:putStroke(id, s) end
        end
        local p = support.newPlugin(ctx.JustDraw, env, {
            paging = true, view = opts.view, page = opts.page,
            doc_settings = opts.doc_settings,
        })
        p.canvas_repository = store
        p.document_cache_opts = { clear = support.recordingClear() }
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        return p, store
    end

    local function penFrame(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penDown(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, tool = tool or 1 }
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penLift(p, x, y)
        p:onStylusEvent{ slot = 4, id = -1, x = x, y = y }
    end

    --- The trusted boundary a real pen leaves behind, so a case is not about
    --- the lease's very first contact proving where it is.
    local function seedPenBaseline(p)
        local geometry = p.stylus_geometry
        if not geometry then return end
        geometry:observe(-1, -1)
        geometry:reset(false)
    end

    local function startDrawing(p)
        p:setDrawing(true)
        seedPenBaseline(p)
        return p.drawing
    end

    --- Every `setDirty` carrying a region, from `from` onwards.
    local function regionsFrom(from)
        local out = {}
        for i = from, #env.UIManager.dirty do
            local d = env.UIManager.dirty[i]
            if d[3] ~= nil then out[#out + 1] = d end
        end
        return out
    end

    --- Blits of one buffer onto the screen, from `from` onwards.
    local function blitsOf(bb, from)
        local out = {}
        for i = from, #Device.screen.bb.blits do
            local b = Device.screen.bb.blits[i]
            if b.src == bb then out[#out + 1] = b end
        end
        return out
    end

    local function refreshModes(from)
        local out = {}
        for i = from, #Device.screen.refreshes do
            out[#out + 1] = Device.screen.refreshes[i][1]
        end
        return out
    end

    local function has(list, want)
        for i = 1, #list do if list[i] == want then return true end end
        return false
    end

    --- The "Page notes" submenu, rebuilt the way the menu rebuilds it.
    local function pageNotesItem(p, label)
        local entry = ctx.menuItem(p, "Page notes")
        if not entry or not entry.sub_item_table_func then return nil, entry end
        for _, item in ipairs(entry.sub_item_table_func()) do
            if item.text == label then return item, entry end
        end
        return nil, entry
    end

    --- The last widget UIManager was shown, which is where a ConfirmBox lands.
    local function lastShown()
        return env.UIManager.shown[#env.UIManager.shown]
    end

    local function checkSheetOffer()
        local box = lastShown()
        t:check(box and box.ok_callback ~= nil, "a confirmation box is shown")
        t:eq(box and box.ok_text, "Open drawing page", "the affirmative choice is explicit")
        t:eq(box and box.cancel_text, "Cancel", "the reader can leave drawing stopped")
        t:eq(box and box.text, "Direct annotations not available",
            "the fallback prompt stays concise")
        return box
    end

    -- =================================================================
    t:describe("main / page ink / the gate")

    t:case("a runtime with no stylus API gets no page-ink session", function()
        local p, store = documentPlugin{ stylus_api = false }
        t:eq(p.document_session, nil, "the gate is the runtime, not the pen")
        t:eq(#store.canvases, 0, "and nothing was written looking")
    end)

    t:case("with the gate false direct ink is exactly what it was", function()
        local p = documentPlugin{ stylus_api = false }
        p:setDrawing(true)
        t:eq(p.drawing, true, "the finger route still starts")
        p:onTouchFrame{ { slot = 0, id = 1, x = 100, y = 100 } }
        p:onTouchFrame{ { slot = 0, id = 1, x = 140, y = 140 } }
        p:onTouchFrame{ { slot = 0, id = -1 } }
        local page = p.store:get(1)
        t:eq(page and #page, 1, "one stroke reached the sidecar store")
    end)

    t:case("a reflowable document is untouched by any of this", function()
        ctx.reset{ wacom_protocol = true }
        local doc = support.newDocument{ here = "/body/p[7]",
            pages = { ["/body/p[7]"] = 1 } }
        local p = support.newPlugin(ctx.JustDraw, env, { document = doc })
        p.canvas_repository = support.newCanvasStore{}
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        t:check(p.session ~= nil, "the EPUB still gets its sheet session")
        t:eq(p.document_session, nil, "and no page-ink session beside it")
    end)

    -- =================================================================
    t:describe("main / page ink / lifecycle")

    t:case("ReaderReady opens the session and creates nothing", function()
        local p, store = documentPlugin()
        t:check(p.document_session ~= nil, "there is a page-ink session")
        t:eq(p.document_session:page(), 1, "on the page the reader is on")
        t:eq(p.document_session:surface(), nil, "which has no row")
        t:eq(#store.canvases, 0, "and looking created none")
        t:check(p.document_session:transform() == nil
            or p.document_session:viewReason() == nil,
            "the view was probed, not refused")
    end)

    t:case("Draw creates the row before the capture is installed", function()
        local p, store = documentPlugin()
        local log = {}
        local create = store.createCanvas
        store.createCanvas = function(self, ...)
            log[#log + 1] = "row"
            return create(self, ...)
        end
        local input = Device.input
        local register = input.registerStylusCallback
        input.registerStylusCallback = function(self, cb)
            log[#log + 1] = "capture"
            return register(self, cb)
        end
        t:eq(startDrawing(p), true, "drawing started")
        t:eq(log[1], "row", "the surface exists before any contact can arrive")
        t:eq(log[2], "capture", "and only then is the pen hooked")
        t:eq(#store.canvases, 1, "exactly one row")
        t:eq(store.canvases[1].surface_role, "page_ink", "a page-ink row")
        t:eq(store.canvases[1].fixed_page, 1, "for the page being read")
        t:eq(store.canvases[1].logical_w, PAGE_W, "in the page's own units")
    end)

    t:case("SaveSettings flushes the page's ink", function()
        local p, store = documentPlugin()
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        t:eq(p.document_session:pendingWrites(), 1, "one stroke is waiting")
        p:onSaveSettings()
        t:eq(p.document_session:pendingWrites(), 0, "the gate made it durable")
        t:eq(#store:listStrokes(store.canvases[1].id), 1, "it is in the store")
    end)

    t:case("teardown closes the session before it releases the lease", function()
        local p = documentPlugin()
        startDrawing(p)
        local log = {}
        local session = p.document_session
        local close = session.close
        session.close = function(self, o)
            log[#log + 1] = "close"
            return close(self, o)
        end
        local input = Device.input
        local unregister = input.unregisterStylusCallback
        input.unregisterStylusCallback = function(self)
            log[#log + 1] = "release"
            return unregister(self)
        end
        p:teardown()
        t:eq(log[1], "close", "the ink is made durable first")
        t:eq(log[2], "release", "and the capture goes afterwards")
        t:eq(p.document_session, nil, "nothing is left pointing at it")
    end)

    -- =================================================================
    t:describe("main / page ink / drawing")

    t:case("a pen contact inks into the overlay raster", function()
        local p, store = documentPlugin()
        startDrawing(p)
        local cache = p.document_session:cache()
        local bb = cache:buffer()
        t:eq(bb.bbtype, Blitbuffer.TYPE_BB8A, "the raster carries alpha")
        t:eq(#bb.fills, 0, "and nothing filled it opaque")
        local blits_from = #Device.screen.bb.blits
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        t:check(p.document_stroke ~= nil, "a stroke is in progress")
        t:eq(p.document_stroke.n, 2, "with both points")
        t:check(#bb.rects > 0, "the live segment went into the raster")
        local blits = blitsOf(bb, blits_from + 1)
        t:check(#blits > 0, "and the box was copied to the screen")
        for i = 1, #blits do
            t:eq(blits[i].alpha, true,
                "composed, never copied: a BB8A blitFrom lands alpha 0 as black")
        end
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        t:eq(p.document_stroke, nil, "the stroke finished")
        env.UIManager:flush()
        local rows = store:listStrokes(store.canvases[1].id)
        t:eq(#rows, 1, "and one stroke was written")
        t:eq(rows[1].min_x, INK_XY.x / SCALE, "stored in the page's own units")
        t:eq(rows[1].max_x, (INK_XY.x + 40) / SCALE, "toCanvas of the screen points")
        t:eq(rows[1].width, p.pen_width / SCALE,
            "and the nib is the screen width divided by the zoom")
    end)

    t:case("translucent page ink recomposes through the view at the live cadence", function()
        local p = documentPlugin()
        startDrawing(p)
        local cache = p.document_session:cache()
        -- Raster math is checked against native BB8A in brush_native_check.
        cache.translucent_ink = true
        local before = #Device.screen.bb.blits
        local queued = 0
        p.queueDocumentViewRepaint = function() queued = queued + 1 end
        local tr = p.document_session:transform()
        p:blitDocumentBox({x=10,y=10,w=20,h=20},tr)
        t:eq(queued, 1, "first repaint reaches the reader")
        for i=1,50 do p:blitDocumentBox({x=10+i,y=10,w=20,h=20},tr) end
        t:eq(queued, 1, "same-time samples are held by the existing limiter")
        t:eq(#Device.screen.bb.blits, before, "never alpha-composed over an old composite")
        p.live_refresh:flush()
        t:eq(queued, 2, "the tail is recomposed once")
    end)

    t:case("a contact in the surround starts nothing", function()
        local p, store = documentPlugin()
        startDrawing(p)
        t:eq(p:inBar(SURROUND.x, SURROUND.y), false,
            "the point is page surround, not toolbar")
        penDown(p, SURROUND.x, SURROUND.y)
        penFrame(p, SURROUND.x + 20, SURROUND.y + 20)
        t:eq(p.document_stroke, nil, "no page-ink stroke")
        t:eq(p.stroke, nil, "and no direct-ink stroke either (ADR-39)")
        penLift(p, SURROUND.x + 20, SURROUND.y + 20)
        env.UIManager:flush()
        t:eq(#store:listStrokes(store.canvases[1].id), 0, "nothing was written")
        t:eq(p.store:countPages(), 0, "and the sidecar stayed empty")
    end)

    t:case("a page that cannot take ink refuses the point, not the sidecar", function()
        local row = pageRow(1, 1)
        row.logical_w, row.logical_h = 300, 400   -- the page's size changed
        local p = documentPlugin{ canvases = { row } }
        t:eq(p:documentInkActive(), false, "the surface cannot take ink")
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:applyPoint(INK_XY.x + 40, INK_XY.y + 40, nil)
        p:endStroke()
        t:eq(p.stroke, nil, "no direct-ink stroke was started")
        t:eq(p.store:countPages(), 0,
            "on a fixed layout Draw means the page surface and nothing else")
    end)

    t:case("a refused point says why, once, rather than nothing at all", function()
        local row = pageRow(1, 1)
        row.logical_w, row.logical_h = 300, 400   -- the page's size changed
        local p = documentPlugin{ canvases = { row } }
        env.notifications = {}
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:applyPoint(INK_XY.x + 10, INK_XY.y + 10, nil)
        p:applyPoint(INK_XY.x + 20, INK_XY.y + 20, nil)
        t:eq(#env.notifications, 0, "nothing goes up from inside the callback")
        env.UIManager:flush()
        t:eq(#env.notifications, 1, "one sentence for the whole contact")
        t:eq(env.notifications[1],
            "This page's size changed. Its notes are kept but can't be edited.",
            "and it is the reason the surface gave")
    end)

    t:case("a refused contact is told once, not once a tick", function()
        local row = pageRow(1, 1)
        row.logical_w, row.logical_h = 300, 400   -- the page's size changed
        local p = documentPlugin{ canvases = { row } }
        env.notifications = {}
        -- One contact, three frames, a UI tick between each: the tick is what
        -- `notifyDeferred`'s own latch cannot span.
        p:onContactPoint(0, INK_XY.x, INK_XY.y)
        env.UIManager:flush()
        p:onContactPoint(0, INK_XY.x + 10, INK_XY.y + 10)
        env.UIManager:flush()
        p:onContactPoint(0, INK_XY.x + 20, INK_XY.y + 20)
        env.UIManager:flush()
        t:eq(#env.notifications, 1, "one sentence for the whole contact")
        p:endStroke()   -- the lift
        p:onContactPoint(0, INK_XY.x, INK_XY.y)
        env.UIManager:flush()
        t:eq(#env.notifications, 2, "and a new contact may be told again")
    end)

    t:case("nothing inks between the latch and the frame that acts on it", function()
        local p = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 20, INK_XY.y)
        p.document_session.addStroke = function()
            return nil, "operation_too_large"
        end
        penLift(p, INK_XY.x + 20, INK_XY.y)
        t:eq(p.document_pending_capture_stop, true, "the stop is latched")
        local bb = p.document_session:cache():buffer()
        local writes = #bb.writes
        penDown(p, INK_XY.x, INK_XY.y + 60)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 60)
        t:eq(#bb.writes, writes,
            "and the rest of the frame reaches the page raster with nothing")
        t:eq(p.document_stroke, nil, "no stroke was started behind it")
    end)

    t:case("an oversized page stroke disarms capture after the frame", function()
        local p = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 20, INK_XY.y)
        p.document_session.addStroke = function()
            return nil, "operation_too_large"
        end
        penLift(p, INK_XY.x + 20, INK_XY.y)
        t:eq(Capture.active, true, "the stylus callback leaves this frame alone")
        t:eq(p.document_pending_capture_stop, true,
            "the stop is latched for the residual handler")
        p:onStylusTouchFrame{
            { slot = 0, id = 9, x = INK_XY.x, y = INK_XY.y, tool = 0 },
        }
        t:eq(Capture.active, false, "capture becomes inert after filtering")
        t:eq(p.drawing, true, "the visible state holds through the frame")
        env.UIManager:flush()
        t:eq(p.drawing, false, "and stops from a safe tick, like the sheet's")
        t:eq(p.input_lease, nil, "with the process lease released")
    end)

    t:case("nothing in the stylus callback opens a transaction", function()
        local p, store = documentPlugin()
        startDrawing(p)
        local before = store.calls.transaction
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 20, INK_XY.y + 20)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        t:eq(store.calls.transaction, before,
            "the queue defers every write past the contact (ADR-26)")
        env.UIManager:flush()
        t:check(store.calls.transaction > before, "and commits on a later tick")
    end)

    t:case("black ink rides fast, gray ink rides ui, never partial", function()
        local p = documentPlugin()
        startDrawing(p)
        local from = #Device.screen.refreshes
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y)
        penLift(p, INK_XY.x + 40, INK_XY.y)
        local modes = refreshModes(from + 1)
        t:check(has(modes, "fast"), "the pen's black ink takes the fast pass")
        t:eq(has(modes, "partial"), false,
            "and never partial: its fence under the pen overflows evdev")

        p:setPenStyle(Style.GRAPHITE)
        from = #Device.screen.refreshes
        penDown(p, INK_XY.x, INK_XY.y + 60)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 60)
        penLift(p, INK_XY.x + 40, INK_XY.y + 60)
        modes = refreshModes(from + 1)
        t:check(has(modes, "ui"), "gray ink rides the grayscale pass (ADR-36)")
        t:eq(has(modes, "fast"), false, "fast is forced monochrome and drops it")
        t:eq(has(modes, "partial"), false, "and partial still fences")
    end)

    t:case("undo repaints through the view rather than copying the raster", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        local bb = p.document_session:cache():buffer()
        local dirty_from = #env.UIManager.dirty
        local blits_from = #Device.screen.bb.blits
        t:eq(p:onJustDrawUndo(), true, "the event is consumed")
        t:eq(#blitsOf(bb, blits_from + 1), 0,
            "a transparent layer cannot un-paint the screen by copying")
        env.UIManager:flush()
        local regions = regionsFrom(dirty_from + 1)
        t:eq(#regions, 1, "one regional repaint through the reader")
        t:eq(regions[1][1], p.ui, "of the reader widget itself")
        t:eq(regions[1][2], "ui", "and never fast: the page has to be redrawn")
    end)

    t:case("two erase samples in one tick coalesce into one repaint", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        p:setEraser(true)
        local bb = p.document_session:cache():buffer()
        local dirty_from = #env.UIManager.dirty
        local blits_from = #Device.screen.bb.blits
        penDown(p, 50, 50)
        penFrame(p, 90, 50)
        penFrame(p, 130, 50)
        t:eq(#regionsFrom(dirty_from + 1), 0, "nothing is refreshed per sample")
        penLift(p, 130, 50)
        env.UIManager:flush()
        t:eq(#blitsOf(bb, blits_from + 1), 0, "the raster box is never copied out")
        local regions = regionsFrom(dirty_from + 1)
        t:eq(#regions, 1, "the sweep is one repaint")
        t:eq(regions[1][2], "ui", "through the view")
    end)

    -- =================================================================
    t:describe("main / page ink / view events")

    t:case("a page turn aborts the stroke, flushes, then looks up", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
        }
        startDrawing(p)
        local log = {}
        local transaction = store.transaction
        store.transaction = function(self, fn)
            log[#log + 1] = "flush"
            return transaction(self, fn)
        end
        local find = store.findPageInkSurface
        store.findPageInkSurface = function(self, ...)
            log[#log + 1] = "find"
            return find(self, ...)
        end
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        t:eq(p.document_session:pendingWrites(), 1, "a stroke is waiting")
        penDown(p, INK_XY.x, INK_XY.y + 80)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 80)
        t:check(p.document_stroke ~= nil, "and another is live over the turn")
        p.view.state.page = 2
        p:onPageUpdate(2)
        -- Only the page tick, not every pending callback: draining them all
        -- would let the queue's own delayed flush commit first, and what is
        -- being checked here is that the page change is what makes it durable.
        table.remove(env.UIManager._queue)()
        t:eq(p.document_stroke, nil, "the live stroke was abandoned")
        t:eq(log[1], "flush", "the queue is made durable before the page moves")
        t:eq(log[2], "find", "and only then is the next page looked up")
        t:eq(p.document_session:page(), 2, "the session followed")
        t:eq(p.document_session:surface().id, 2, "onto the next page's row")
    end)

    t:case("a failed flush refuses the turn and Retry completes it", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
        }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:eq(p.document_session:saveFailed(), true, "the write failed")
        t:eq(env.notifications[#env.notifications],
            "Could not save ink. It is still here: use Retry saving.",
            "the reader is told the ink is not lost, only not durable")
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.document_session:page(), 1, "the session stayed on the page")
        t:eq(p.document_session:surface().id, 1, "with its surface intact")

        store.fail_transaction = nil
        local retry = pageNotesItem(p, "Retry saving ink")
        t:check(retry ~= nil, "the menu offers Retry saving ink")
        retry.callback()
        env.UIManager:flush()
        t:eq(p.document_session:saveFailed(), false, "the write went through")
        t:eq(p.document_session:page(), 2, "and the held page change completed")
    end)

    t:case("a zoom rebuilds the transform and abandons the live stroke", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        local before = p.document_session:cache().generation
        p.view.state.zoom = 0.75
        p:onZoomUpdate(0.75)
        env.UIManager:flush()
        t:eq(p.document_stroke, nil, "the live stroke was abandoned")
        t:check(math.abs(p.document_session:transform().scale - 0.75) < 1e-9,
            "the transform carries the new scale")
        t:check(p.document_session:cache().generation > before,
            "and the raster was rebuilt from the vectors")
    end)

    t:case("a pan moves the paint rectangle without rebuilding", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        local before = p.document_session:cache().generation
        local x_before = p.document_session:transform():canvasRect().x
        p.view.state.offset.x = 40
        p:onViewRecalculate(p.view.visible_area, nil)
        env.UIManager:flush()
        t:eq(p.document_session:cache().generation, before,
            "the same scale keeps the same raster")
        t:eq(p.document_session:transform():canvasRect().x, x_before + 40,
            "but the page is drawn somewhere else")
    end)

    t:case("a page turn with Draw on gives the next page its surface", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.drawing, true, "Draw is still on")
        local row = store:findPageInkSurface(12, 2)
        t:check(row ~= nil, "and page 2 has a surface to draw on")
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y)
        penLift(p, INK_XY.x + 40, INK_XY.y)
        env.UIManager:flush()
        t:eq(#store:listStrokes(row.id), 1, "and the stroke landed on it")
        t:eq(#store:listStrokes(1), 1, "page 1 kept its own")

        p.view.state.page = 3
        p:onPageUpdate(3)
        env.UIManager:flush()
        t:check(store:findPageInkSurface(12, 3) ~= nil, "page 3 gets one too")
        t:check(store:findPageInkSurface(12, 2) ~= nil, "page 2 keeps its ink")
        p.view.state.page = 4
        p:onPageUpdate(4)
        env.UIManager:flush()
        t:eq(store:findPageInkSurface(12, 3), nil,
            "but page 3, left untouched, is forgotten when it is left")
    end)

    t:case("paging with Draw on and drawing nothing leaves no rows", function()
        local p, store = documentPlugin()
        startDrawing(p)
        for page = 2, 6 do
            p.view.state.page = page
            p:onPageUpdate(page)
            env.UIManager:flush()
        end
        t:eq(p.drawing, true, "Draw stayed on the whole way")
        t:eq(store:countPageInkSurfaces(12), 1,
            "only the page under the reader holds a surface")
        p:teardown()
        t:eq(store:countPageInkSurfaces(12), 0,
            "and the last one goes with the document: reading creates nothing")
    end)

    t:case("the delete entries stay grey through paging with Draw on", function()
        local p, store = documentPlugin()
        startDrawing(p)
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(store:countPageInkSurfaces(12), 1,
            "the page under the reader has a working surface in the database")
        t:eq(p.document_session:countSurfaces(), 0,
            "which is not a page note until something is drawn on it")
        t:eq(pageNotesItem(p, "Delete all page notes").enabled_func(), false,
            "so there is nothing to delete")
        t:eq(pageNotesItem(p, "Delete this page note").enabled_func(), false,
            "and nothing on this page either")

        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y)
        penLift(p, INK_XY.x + 40, INK_XY.y)
        p.document_ink_count = nil
        t:eq(p.document_session:countSurfaces(), 1, "one stroke makes it one")
        t:eq(pageNotesItem(p, "Delete this page note").enabled_func(), true,
            "and there is now something on this page to delete")
    end)

    t:case("an empty row is kept while a write is still owed", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        t:eq(p:onJustDrawUndo(), true, "the page's only stroke is taken back")
        t:eq(#p.document_session:cache():strokes(), 0, "the raster is empty")
        t:check(p.document_session:pendingWrites() > 0, "but a delete is owed")
        p:teardown()
        t:check(store:findPageInkSurface(12, 1) ~= nil,
            "so the row stays: a write in flight is not an empty page")
    end)

    t:case("an empty row is kept when the last write failed", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        p:onJustDrawUndo()
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:eq(p.document_session:saveFailed(), true, "the delete could not commit")
        p:teardown()
        t:check(store:findPageInkSurface(12, 1) ~= nil,
            "the row stays: the work is in memory, not in the raster")
    end)

    t:case("a read-only database is never deleted from", function()
        local p, store = documentPlugin{
            read_only = true, canvases = { pageRow(1, 1) },
        }
        t:eq(p.document_session:isWritable(), false, "nothing may be written")
        p:teardown()
        t:check(store:findPageInkSurface(12, 1) ~= nil,
            "and an empty row of somebody else's is left exactly as it was")
    end)

    t:case("a page turn onto ink keeps Draw while the raster reads", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
            strokes = { [2] = { bar_stroke() } },
        }
        startDrawing(p)
        p.view.state.page = 2
        p:onPageUpdate(2)
        -- Only the page tick: the raster batches on the ticks behind it, and
        -- what is being checked is the state between the two.
        table.remove(env.UIManager._queue)()
        t:eq(p.document_session:stateName(), "loading", "the ink is still coming")
        t:eq(p.drawing, true,
            "and Draw is not taken away for the length of a page load")
        env.UIManager:flush()
        t:eq(p.document_session:stateName(), "ready", "the raster finishes")
        t:eq(p.drawing, true, "with the pen still in the reader's hand")
    end)

    t:case("a page turn onto a view it cannot map stops Draw and says why", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        env.notifications = {}
        p.view.state.page = 2
        p.view.state.zoom = 4
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.drawing, false, "drawing stopped")
        t:eq(#env.notifications, 0, "the confirmation replaces a notification")
        checkSheetOffer()
        t:eq(store:findPageInkSurface(12, 2), nil,
            "and a refused view creates no row")
    end)

    t:case("Retry saving ink turns the page before Draw comes back", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:eq(p.drawing, false, "the failed write stopped drawing")
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.document_session:page(), 1, "and the turn is being held")

        store.fail_transaction = nil
        local page_at_recovery
        local recovered = p.onDocumentInkSaveRecovered
        p.onDocumentInkSaveRecovered = function(plugin, ...)
            page_at_recovery = plugin.document_session:page()
            return recovered(plugin, ...)
        end
        pageNotesItem(p, "Retry saving ink").callback()
        env.UIManager:flush()
        t:eq(page_at_recovery, 2,
            "the held turn is made before the owner hears it may draw again")
        t:eq(p.drawing, true, "Draw came back")
        t:check(store:findPageInkSurface(12, 2) ~= nil,
            "on a surface for the page the reader is actually on")
    end)

    t:case("a retry whose held turn fails does not say drawing may resume", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.document_session:page(), 1, "the turn is being held")

        store.fail_transaction = nil
        store.fail_find_page_ink = "disk error"   -- the held turn cannot land
        local relayed = false
        local recovered = p.onDocumentInkSaveRecovered
        p.onDocumentInkSaveRecovered = function(plugin, ...)
            relayed = true
            return recovered(plugin, ...)
        end
        pageNotesItem(p, "Retry saving ink").callback()
        env.UIManager:flush()
        t:eq(relayed, false,
            "the owner is not told it may draw again on a page that did not open")
        t:eq(p.drawing, false, "so Draw stays off rather than refusing twice")
    end)

    t:case("a retry gives Draw back only to somebody who had it", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        p:setDrawing(false)             -- the reader put the pen down
        store.fail_transaction = "commit"
        env.UIManager:flush()
        store.fail_transaction = nil
        pageNotesItem(p, "Retry saving ink").callback()
        env.UIManager:flush()
        t:eq(p.drawing, false, "the plugin does not decide to start drawing")
    end)

    t:case("explicit Stop while save-failed cancels PDF recovery intent", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:eq(p.drawing, false, "save failure stopped capture")
        t:eq(p.document_drawing_suspended, true, "internal failure retained editing intent")
        p:setDrawing(false) -- also the first step of notes read/view navigation
        store.fail_transaction = nil
        p.document_session:retrySave(); env.UIManager:flush()
        t:eq(p.drawing, false, "successful retry cannot undo explicit Stop")
        t:eq(p.document_drawing_suspended, false, "old recovery intention cleared")
    end)

    t:case("continuous scrolling suspends page ink and says so", function()
        -- With ink on it, so that what resume brings back is a real surface:
        -- an empty row is dropped when its surface closes.
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        p.view.page_scroll = true
        p:onSetScrollMode(true)
        env.UIManager:flush()
        t:eq(p.drawing, false, "drawing was turned off")
        t:eq(p.document_session:stateName(), "suspended", "and the surface put away")
        checkSheetOffer("Direct annotations are unavailable in continuous scrolling.")
        p.view.page_scroll = false
        p:onSetScrollMode(false)
        env.UIManager:flush()
        env.UIManager:flush()   -- the resumed raster rasterises on a tick
        t:eq(p.document_session:stateName(), "ready", "and turning it back off resumes")
        t:eq(#p.document_session:cache():strokes(), 1, "with the page's ink on it")
    end)

    t:case("continuous scrolling says nothing to a reader who was not drawing", function()
        local p = documentPlugin{ canvases = { pageRow(1, 1) } }
        t:eq(p.drawing, false, "nobody is drawing")
        env.notifications = {}
        p.view.page_scroll = true
        p:onSetScrollMode(true)
        env.UIManager:flush()
        t:eq(p.document_session:stateName(), "suspended", "the surface is away")
        t:eq(#env.notifications, 0,
            "and a reader who turned scrolling on is not asking about notes")
    end)

    t:case("a screen resize re-reads the view", function()
        local p = documentPlugin{ canvases = { pageRow(1, 1) } }
        startDrawing(p)
        local before = p.document_session:transform():canvasRect().x
        p.view.state.offset.x = 30
        p:onScreenResize()
        env.UIManager:flush()
        t:eq(p.document_session:transform():canvasRect().x, before + 30,
            "the transform followed the new geometry")
    end)

    -- =================================================================
    t:describe("main / page ink / refusals")

    local REFUSALS = {
        { name = "continuous scrolling", view = { page_scroll = true },
          message = "Direct annotations are unavailable in continuous scrolling." },
        { name = "reflow", view = { configurable = { text_wrap = 1 } },
          message = "Direct annotations cannot be aligned while Reflow is enabled." },
        { name = "Auto Straighten",
          view = { koptinterface = { is_optimizing_page = function() return true end },
            configurable = { text_wrap = 0, auto_straighten = 1 } },
          message = "Direct annotations cannot be aligned while Auto Straighten is enabled." },
        { name = "a rotated page state", view = { state = { rotation = 1 } },
          message = "Direct annotations cannot be aligned while the page is rotated." },
        { name = "a zoom past the raster budget", view = { state = { zoom = 4 } },
          message = "Direct annotations need more page-raster memory at this zoom." },
        { name = "a view before its first recalculate",
          view = { state = { offset = false } },
          message = "Page notes can't be placed on this view.", no_sheet = true },
    }

    for _, refusal in ipairs(REFUSALS) do
        t:case(refusal.name .. " refuses Draw with its own sentence", function()
            local p, store = documentPlugin{ view = refusal.view }
            p:setDrawing(true)
            t:eq(p.drawing, false, "drawing did not start")
            if refusal.no_sheet then
                t:eq(env.notifications[#env.notifications], refusal.message,
                    "the transient refusal keeps its existing message")
            else
                t:eq(#env.notifications, 0, "a usable sheet is offered instead")
                checkSheetOffer().cancel_callback()
            end
            t:eq(#store.canvases, 0, "a refused view creates no row")
        end)
    end

    t:case("dewatermark remains compatible with direct page ink", function()
        local p, store = documentPlugin{ view = {
            koptinterface = { is_optimizing_page = function() return true end },
            configurable = { text_wrap = 0, page_opt = 1, white_threshold = 20,
                auto_straighten = 0 },
        } }
        p:setDrawing(true)
        t:eq(p.drawing, true, "direct drawing starts")
        t:check(store:findPageInkSurface(12, 1) ~= nil, "the direct page surface is used")
        t:eq(p.page_sheet_offer, nil, "no sheet is suggested")
    end)

    t:case("accepting the fallback creates and opens one fixed-page sheet", function()
        local settings = {}
        local p, store = documentPlugin{
            view = { configurable = { text_wrap = 1 } }, doc_settings = settings,
        }
        p:setDrawing(true)
        local box = checkSheetOffer()
        box.ok_callback()
        t:eq(p.canvas_open, true, "one acceptance opens the sheet immediately")
        env.UIManager:flush()
        t:eq(p.session:activeCanvas().anchor_kind, "page", "it is page anchored")
        t:eq(p.session:activeCanvas().fixed_page, 1, "to the current PDF page")
        t:eq(#store:listPageSheets(12, { limit = 10 }), 1, "only one sheet was created")
        t:eq(settings.justdraw_page_sheet_fallback_accepted, true,
            "successful opening remembers fallback for this PDF")
    end)

    t:case("remembered fallback covers other blockers but never replaces direct ink", function()
        local settings = { justdraw_page_sheet_fallback_accepted = true }
        local p, store = documentPlugin{
            view = { state = { rotation = 1 } }, doc_settings = settings,
        }
        p:setDrawing(true)
        env.UIManager:flush()
        t:eq(p.page_sheet_offer, nil, "an acknowledged PDF shows no second prompt")
        t:eq(p.canvas_open, true, "another geometry blocker opens a drawing page")

        p:closeCanvas()
        p.view.state.rotation = 0
        p:refreshDocumentView()
        p:setDrawing(true)
        t:eq(p.drawing, true, "compatible geometry returns to direct annotation")
        t:eq(p.canvas_open, false, "remembering fallback does not force the old sheet")
        t:check(store:findPageInkSurface(12, 1) ~= nil,
            "the compatible page uses its direct-ink surface")
    end)

    t:case("fallback acknowledgement is document-local and resettable", function()
        local accepted = { justdraw_page_sheet_fallback_accepted = true }
        local p = documentPlugin{
            view = { configurable = { text_wrap = 1 } }, doc_settings = accepted,
        }
        t:eq(p.page_sheet_fallback_accepted, true, "the PDF restores its acknowledgement")
        local reset = ctx.menuItem(p, "Reset options for this document")
        t:check(reset and reset.enabled_func(), "the reset action is enabled")
        reset.callback()
        t:eq(accepted.justdraw_page_sheet_fallback_accepted, nil,
            "reset clears only the document preference")
        t:eq(env.notifications[#env.notifications],
            "The drawing-page confirmation will be shown again for this document.",
            "reset explains its scope")
        p:setDrawing(true)
        checkSheetOffer().cancel_callback()

        local other = {}
        local q = documentPlugin{
            view = { configurable = { text_wrap = 1 } }, doc_settings = other,
        }
        q:setDrawing(true)
        checkSheetOffer().cancel_callback()
        t:eq(other.justdraw_page_sheet_fallback_accepted, nil,
            "another PDF still requires acceptance")
    end)

    t:case("the fallback can be accepted while PDF sheets are indexing", function()
        local p, store = documentPlugin{ view = { configurable = { text_wrap = 1 } } }
        p.session.index.state = "metadata"
        local shown = #env.UIManager.shown
        p:setDrawing(true)
        local box = checkSheetOffer()
        box.ok_callback()
        t:check(p.page_sheet_pending ~= nil, "the accepted page request is retained")
        t:eq(#store:listPageSheets(12, { limit = 10 }), 0,
            "nothing is created from a partial index")
        p:setDrawing(true)
        t:eq(#env.UIManager.shown, shown + 1,
            "pressing Draw again does not duplicate the accepted request")
        p.session.index.state = "ready"
        p:onCanvasIndexReady()
        env.UIManager:flush()
        t:eq(p.page_sheet_pending, nil, "the delayed request was consumed")
        t:eq(p.canvas_open, true, "the accepted sheet opens when indexing completes")
        t:eq(#store:listPageSheets(12, { limit = 10 }), 1,
            "and only then is its row created")
    end)

    t:case("a page turn cancels an accepted indexing fallback", function()
        local p, store = documentPlugin{ view = { configurable = { text_wrap = 1 } } }
        p.session.index.state = "metadata"
        p:setDrawing(true)
        checkSheetOffer().ok_callback()
        p.view.state.page = 2
        p:onPageUpdate(2)
        p.session.index.state = "ready"
        p:onCanvasIndexReady()
        env.UIManager:flush()
        t:eq(p.canvas_open, false, "no stale sheet is opened")
        t:eq(#store:listPageSheets(12, { limit = 10 }), 0,
            "and no row is created for either page")
    end)

    t:case("a sheet-index failure clears accepted fallback state", function()
        local p, store = documentPlugin{ view = { configurable = { text_wrap = 1 } } }
        p.session.index.state = "metadata"
        p:setDrawing(true)
        checkSheetOffer().ok_callback()
        p.session:_indexFailed("database is locked")
        t:eq(p.page_sheet_pending, nil, "the delayed request is discarded")
        t:eq(p.page_sheet_fallback_accepted, false,
            "a failed opening is not remembered")
        t:eq(#store:listPageSheets(12, { limit = 10 }), 0, "nothing was created")
        t:check(env.notifications[#env.notifications]:find("Could not list", 1, true) ~= nil,
            "the database error keeps the sheet session's specific message")
    end)

    t:case("fallback prompts are deduplicated and stale acceptance is inert", function()
        local p, store = documentPlugin()
        startDrawing(p)
        local shown = #env.UIManager.shown
        p.view.state.zoom = 4
        p:onZoomUpdate(4)
        p:onViewRecalculate()
        env.UIManager:flush()
        t:eq(#env.UIManager.shown, shown + 1, "repeated recalculation shows one box")
        local accept = checkSheetOffer().ok_callback
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        accept()
        env.UIManager:flush()
        t:eq(#store:listPageSheets(12, { limit = 10 }), 0,
            "the old callback cannot create a sheet on the new page")
    end)

    t:case("restoring compatible geometry closes the pending fallback", function()
        local p, store = documentPlugin{ view = { state = { zoom = 4 } } }
        p:setDrawing(true)
        local accept = checkSheetOffer().ok_callback
        p.view.state.zoom = 0.5
        p:onZoomUpdate(0.5)
        env.UIManager:flush()
        t:eq(p.page_sheet_offer, nil, "the stale box is no longer coordinated")
        accept(); env.UIManager:flush()
        t:eq(#store:listPageSheets(12, { limit = 10 }), 0,
            "its delayed callback cannot switch surfaces")
    end)

    t:case("a zoom past the budget paints nothing", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        startDrawing(p)
        p.view.state.zoom = 4
        p:onZoomUpdate(4)
        env.UIManager:flush()
        t:eq(p.drawing, false, "drawing stopped")
        checkSheetOffer()
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.blits, 0, "a refused view puts nothing on the page")
    end)

    t:case("a page whose size changed keeps its ink and refuses edits", function()
        local row = pageRow(1, 1)
        row.logical_w, row.logical_h = 300, 400
        local p, store = documentPlugin{
            canvases = { row }, strokes = { [1] = { bar_stroke() } },
        }
        p:setDrawing(true)
        t:eq(p.drawing, false, "Draw is refused")
        t:eq(env.notifications[#env.notifications],
            "This page's size changed. Its notes are kept but can't be edited.",
            "and the reader is told the ink is safe")
        t:eq(#store.canvases, 1, "the row is still there")
    end)

    t:case("every reason resolves to one sentence, from one table", function()
        local Session = require("ink_document_ink_session")
        t:check(type(Session.MESSAGES) == "table",
            "the table belongs to the session module")
        t:check(type(Session.FALLBACK_MESSAGE) == "string"
            and #Session.FALLBACK_MESSAGE > 0, "and so does the fallback")
        local n = 0
        for reason, text in pairs(Session.MESSAGES) do
            n = n + 1
            t:check(type(text) == "string" and #text > 0,
                tostring(reason) .. " has a sentence")
        end
        t:check(n >= 20, "covering every reason the feature can answer")
    end)

    t:case("read_only is one sentence whichever path says it", function()
        local p = documentPlugin{
            read_only = true,
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        -- Path one: the session says it itself when the surface opens.
        local from_session = env.notifications[#env.notifications]
        t:check(from_session ~= nil, "the reader was told when the page opened")
        env.notifications = {}
        -- Path two: the reader presses Draw and the wiring translates it.
        p:setDrawing(true)
        t:eq(p.drawing, false, "Draw is refused")
        t:eq(env.notifications[#env.notifications], from_session,
            "and says exactly what the session said")
    end)

    t:case("a read-only database paints page ink and refuses to add", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar_stroke() } },
        }
        -- Reached the way the session reaches it: the repository says so.
        store.read_only = true
        p.document_session.repository.read_only = true
        p:setDrawing(true)
        t:eq(p.drawing, false, "Draw is refused")
        t:check(env.notifications[#env.notifications]:find("read-only", 1, true)
            ~= nil, "and says the database is read-only")
    end)

    -- =================================================================
    t:describe("main / page ink / painting")

    t:case("paintTo paints legacy ink and then the overlay", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        p.store:add(1, { n = 2, w = 4, t = 1, 10, 10, 60, 60 })
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:check(#bb.rects > 0, "the legacy stroke was painted onto the page")
        t:eq(#bb.blits, 1, "and the overlay was composed once over it")
        t:eq(bb.blits[1].alpha, true, "as an alpha composition")
        local r = p.document_session:transform():canvasRect()
        t:eq(bb.blits[1].dest_x, r.x, "at the page's own rectangle")
        t:eq(bb.blits[1].dest_y, r.y, "in both axes")
        t:eq(bb.blits[1].w, r.w, "for exactly the visible width")
    end)

    t:case("no session paints exactly what it always painted", function()
        local p = documentPlugin{ stylus_api = false }
        p.store:add(1, { n = 2, w = 4, t = 1, 10, 10, 60, 60 })
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:check(#bb.rects > 0, "the legacy stroke is painted")
        t:eq(#bb.blits, 0, "and nothing is composed over it")
    end)

    t:case("the marker has a surface on a page-ink document", function()
        local p = documentPlugin()
        t:eq(p:markerAvailable(), true,
            "a page's ink layer is a surface this plugin owns end to end")
        t:eq(p:diagnosticSource(), "page_ink",
            "and a trace taken here is not labelled direct ink")
        local palette = p:showPenSettingsDialog()
        for column = 2, #palette.buttons[3] do
            t:eq(palette.buttons[3][column].enabled, true,
                "PDF palette offers the marker at every width")
        end
        p:closeReaderModal(palette)
        local plain = documentPlugin{ stylus_api = false }
        t:eq(plain:markerAvailable(), false,
            "the framebuffer of the v2026.03 route still is not ours to fill")
        t:eq(plain:diagnosticSource(), "direct", "and it is direct ink")
        palette = plain:showPenSettingsDialog()
        for _, cell in ipairs(palette.buttons[3]) do
            t:eq(cell.enabled, false, "legacy palette preserves the capability gate")
        end
        plain:closeReaderModal(palette)
    end)

    -- =================================================================
    t:describe("main / page ink / menu")

    t:case("the page-notes row is absent where it cannot exist", function()
        local p = documentPlugin{ stylus_api = false }
        t:eq(ctx.menuItem(p, "Page notes"), nil,
            "no row at all on a runtime with no stylus API (ADR-41)")

        ctx.reset{ wacom_protocol = true }
        local doc = support.newDocument{ here = "/body/p[7]",
            pages = { ["/body/p[7]"] = 1 } }
        local epub = support.newPlugin(ctx.JustDraw, env, { document = doc })
        epub.canvas_repository = support.newCanvasStore{}
        env.UIManager:flush()
        epub:onReaderReady()
        env.UIManager:flush()
        t:eq(ctx.menuItem(epub, "Page notes"), nil,
            "and none on a reflowable book, where a sheet is the surface")
        t:eq(ctx.menuItem(epub, "Drawing sheet"), nil,
            "and the redundant sheet submenu is absent")
    end)

    t:case("page notes owns export on a fixed-layout document", function()
        local p = documentPlugin()
        local items = {}
        p:addToMainMenu(items)
        local sub = items.justdraw.sub_item_table
        local notes
        for i = 1, #sub do
            if sub[i].text == "Page notes" then notes = sub[i] end
        end
        t:check(notes ~= nil, "the page-notes row is there")
        local export
        for _, item in ipairs(notes.sub_item_table_func()) do
            if item.text == "Export…" then export = item end
        end
        t:check(export ~= nil, "Export is inside Page notes")
        t:eq(ctx.menuItem(p, "Drawing sheet"), nil, "no sheet submenu")
        local open_sheet = ctx.menuItem(p, "Open page sheet")
        t:check(open_sheet ~= nil, "a direct page-sheet action is always visible")
        t:eq(open_sheet.enabled_func(), true,
            "direct page annotation does not disable separate sheets")
        p:setBarShown(true)
        local more = p:showBarMenu()
        local found
        for _, row in ipairs(more.buttons) do
            for _, button in ipairs(row) do
                if button.text == "Open page sheet" then found = button end
            end
        end
        t:check(found ~= nil and found.enabled, "the toolbar More dialog agrees")
        p:closeReaderModal(more)
    end)

    t:case("a PDF page sheet restores its selected logical page after reopening", function()
        local settings = {}
        local p, store = documentPlugin{ doc_settings = settings }
        t:check(p:resolvePageSheet() ~= nil, "the first page sheet opens")
        local first = p.session:activeCanvas()
        t:check(p:addCanvasPage() ~= nil, "a second logical page is appended")
        local second = p.session:activeCanvas()
        t:check(second.id ~= first.id, "the appended page is active")

        p:onCloseDocument()
        local reopened = documentPlugin{ store = store, doc_settings = settings }
        t:check(reopened:resolvePageSheet() ~= nil, "the page sheet reopens")
        t:eq(reopened.session:activeCanvas().id, second.id,
            "the PDF restores the page selected before it was closed")
    end)

    t:case("Delete this page note takes only this page's row", function()
        local p, store = documentPlugin{
            canvases = { sheetRow(9, "/body/p[7]"), pageRow(1, 1), pageRow(2, 2) },
            strokes = { [1] = { bar_stroke() } },
        }
        local item = pageNotesItem(p, "Delete this page note")
        t:check(item ~= nil, "the entry is offered")
        t:eq(item.enabled_func(), true, "this page has a note")
        item.callback()
        local confirm = lastShown()
        t:check(confirm and confirm.ok_callback ~= nil, "it asks first")
        t:check(confirm.text:find("Drawing sheets and legacy ink", 1, true) ~= nil,
            "naming exactly what is not affected")
        confirm.ok_callback()
        env.UIManager:flush()
        t:eq(store:findPageInkSurface(12, 1), nil, "this page's note is gone")
        t:check(store:findPageInkSurface(12, 2) ~= nil, "page 2 kept its own")
        t:eq(#store:listCanvases(), 1, "and the sheet is untouched")
    end)

    t:case("Delete all page notes leaves every sheet alone", function()
        local p, store = documentPlugin{
            canvases = { sheetRow(9, "/body/p[7]"), pageRow(1, 1), pageRow(2, 2) },
        }
        local item = pageNotesItem(p, "Delete all page notes")
        t:check(item ~= nil, "the entry is offered")
        t:eq(item.enabled_func(), true, "there is something to delete")
        item.callback()
        local confirm = lastShown()
        t:check(confirm and confirm.ok_callback ~= nil, "it asks first")
        confirm.ok_callback()
        env.UIManager:flush()
        t:eq(store:countPageInkSurfaces(12), 0, "every page note went")
        t:eq(#store:listCanvases(), 1, "and the sheet stayed")
        t:eq(pageNotesItem(p, "Delete all page notes").enabled_func(), false,
            "the entry greys itself out again")
    end)

    t:case("Delete all page notes is grey with nothing to delete", function()
        local p = documentPlugin()
        local item = pageNotesItem(p, "Delete all page notes")
        t:check(item ~= nil, "the entry is offered")
        t:eq(item.enabled_func(), false, "and disabled")
    end)

    t:case("the count behind Delete all is not a query per paint", function()
        local p, store = documentPlugin{ canvases = { pageRow(1, 1) } }
        local counted = 0
        local count = store.countPageInkSurfaces
        store.countPageInkSurfaces = function(self, ...)
            counted = counted + 1
            return count(self, ...)
        end
        local item = pageNotesItem(p, "Delete all page notes")
        item.enabled_func()
        item.enabled_func()
        item.enabled_func()
        t:eq(counted, 1, "the answer is cached the way canExport caches its own")
    end)

    t:case("Retry saving ink is offered only after a failed write", function()
        local p, store = documentPlugin()
        t:eq(pageNotesItem(p, "Retry saving ink"), nil, "nothing to retry")
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:check(pageNotesItem(p, "Retry saving ink") ~= nil, "now it is there")
        t:eq(p.drawing, false, "and a failed save stopped drawing")
    end)
    -- =================================================================
    t:describe("main / page ink / the dossier")

    --[[--
    "Document notes" is the whole book on white (ADR-40), and everything about
    it that only appears once the plugin is wired: which scopes a fixed-layout
    reader is offered, what the file is called, and -- the part with two
    surfaces in it -- that "This page" now carries the page's own notes as a
    composed layer over the book's page rather than a rectangle across it.
    ]]

    local function scopeValues(p)
        local out = {}
        for _, entry in ipairs(p:exportScopes()) do out[#out + 1] = entry.value end
        return table.concat(out, " ")
    end

    local function scopeNamed(p, value)
        for _, entry in ipairs(p:exportScopes()) do
            if entry.value == value then return entry end
        end
        return nil
    end

    --- Make this page's document renderable: the suite's fake view has the
    --- fields the transform reads and not the one `drawPage` is.
    local function drawablePage(p)
        local drawn = { count = 0 }
        p.view.document.drawPage = function(_, bb)
            drawn.count = drawn.count + 1
            bb:paintRect(0, 0, 2, 2, "page")
        end
        return drawn
    end

    t:case("a book with page notes offers to export them", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 3) },
            strokes = { [1] = { bar_stroke() } },
        }
        local notes = scopeNamed(p, "notes")
        t:check(notes ~= nil, "the scope is offered: " .. scopeValues(p))
        t:eq(notes.label, "Document notes", "under its own name")
        t:check(notes.enabled ~= false, "and it is live")
    end)

    t:case("a book with nothing in it offers no dossier", function()
        local p = documentPlugin()
        t:eq(scopeNamed(p, "notes"), nil, "nothing to gather")
    end)

    t:case("legacy ink alone is enough to have a dossier", function()
        local p = documentPlugin()
        p.store:add(3, { n = 2, w = 4, 10, 10, 30, 10 })
        t:check(scopeNamed(p, "notes") ~= nil, "the sidecar is a note too")
        t:check(p:canExport(), "and the entry that opens the dialog is live")
    end)

    t:case("the dossier's name says the book and nothing about a page", function()
        local p = documentPlugin{ canvases = { pageRow(1, 3) },
            strokes = { [1] = { bar_stroke() } } }
        t:eq(p:exportStem("notes", "S"), "test Notes S",
            "the book, the word, the stamp")
        t:eq(p:exportScopePage("notes"), nil,
            "one page number in the name of a file holding twenty would be a lie")
    end)

    t:case("the dossier is every note of the book, in order, under a band", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 3), pageRow(2, 1) },
            strokes = { [1] = { bar_stroke() }, [2] = { bar_stroke() } },
        }
        p.store:add(3, { n = 2, w = 4, 10, 10, 30, 10 })
        local built, err = p:buildExport("notes")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:eq(#built.items, 3, "two page notes and one legacy page")
        t:eq(built.items[1].kind .. tostring(built.items[1].page), "page_ink1",
            "page 1 first")
        t:eq(built.items[2].kind, "legacy_page", "then page 3's legacy ink")
        t:eq(built.items[3].kind, "page_ink", "and then page 3's own notes")
        t:check(type(built.flush) == "function", "the ink is made durable first")
        t:check(type(built.finish) == "function", "and released at the end")
        t:check(type(built.cancel) == "function", "and when the reader cancels")
        t:eq(built.flush(), true, "the flush answers for both surfaces")
        t:check(built.pixels > 0, "and it can say how much this will weigh")
    end)

    t:case("PDF sheets and direct page ink share one dossier", function()
        local p = documentPlugin{
            canvases = { fixedSheetRow(1, 2), pageRow(2, 2) },
            strokes = { [1] = { bar_stroke() }, [2] = { bar_stroke() } },
        }
        local built, err = p:buildExport("notes")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:eq(#built.items, 2, "both fixed-page note surfaces are present")
        t:eq(built.items[1].kind, "sheet", "the page sheet is included")
        t:eq(built.items[1].page, 2, "with its fixed-page destination")
        t:eq(built.items[2].kind, "page_ink", "alongside direct ink")
    end)

    t:case("a dossier with legacy ink asks before it reads anything", function()
        local p = documentPlugin{ canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } } }
        t:eq(p:buildExport("notes").confirm_warning, nil,
            "page notes alone need no caveat")
        p.store:add(3, { n = 2, w = 4, 10, 10, 30, 10 })
        local warning = p:buildExport("notes").confirm_warning
        t:check(type(warning) == "string", "legacy ink comes with a sentence")
        t:check(warning:find("zoom", 1, true) ~= nil
            and warning:find("cannot be guaranteed", 1, true) ~= nil,
            "which says what was not stored: " .. tostring(warning))
    end)

    t:case("this page carries its own notes, composed over the book's page", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        local drawn = drawablePage(p)
        p.store:add(1, { n = 2, w = 4, 10, 10, 30, 10 })
        local built, err = p:buildExport("page")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:check(type(built.flush) == "function",
            "the page's notes have to be durable before they are read back")
        t:check(type(built.finish) == "function", "and the raster released")
        t:check(type(built.cancel) == "function", "cancel included")
        local delivered, reason
        built.render(built.items[1], 1, function(r, e) delivered, reason = r, e end)
        t:check(delivered == nil,
            "the overlay is read from the store, so it arrives on a later tick")
        for _ = 1, 20 do
            if delivered then break end
            env.UIManager:flush()
        end
        t:check(delivered ~= nil, "delivered: " .. tostring(reason))
        t:eq(drawn.count, 1, "the document was drawn once")
        t:eq(#delivered.bb.blits, 1, "one layer went over it")
        local layer = delivered.bb.blits[1]
        t:eq(layer.alpha, true,
            "composed, so alpha 0 leaves the book's text alone (ADR-38)")
        t:eq(layer.dest_x, 0, "at the page's own left edge")
        t:eq(layer.dest_y, 0, "and its top")
        t:eq(layer.w, math.floor(PAGE_W * SCALE), "the width of the page at zoom")
        t:eq(layer.h, math.floor(PAGE_H * SCALE), "and its height")
        delivered.release()
        built.finish()
        t:eq(store.calls.stroke_list > 0, true,
            "and the layer was read from the store, not from the live cache")
    end)

    t:case("a page whose notes cannot be reached refuses, and says why", function()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        drawablePage(p)
        store.findPageInkSurface = function() return nil, "database is locked" end
        local built = p:buildExport("page")
        local delivered, reason
        built.render(built.items[1], 1, function(r, e) delivered, reason = r, e end)
        for _ = 1, 20 do
            if reason then break end
            env.UIManager:flush()
        end
        t:check(delivered == nil,
            "a file that quietly left the notes out is worse than none")
        t:eq(reason, "database is locked", "and the reason is the store's")
    end)

    t:case("a view that cannot place the notes refuses too", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        drawablePage(p)
        -- A rotated page state is one of the views the transform cannot map
        -- (ADR-38); the page renders, but the layer over it would be a guess.
        p.view.state.rotation = 90
        local built = p:buildExport("page")
        local delivered, reason
        built.render(built.items[1], 1, function(r, e) delivered, reason = r, e end)
        for _ = 1, 20 do
            if reason then break end
            env.UIManager:flush()
        end
        t:check(delivered == nil, "refused")
        t:eq(reason, "unsupported_rotation", "with the transform's own reason")
    end)

    t:case("a page with no notes exports the way it always did", function()
        local p = documentPlugin()
        drawablePage(p)
        local built = p:buildExport("page")
        local delivered
        built.render(built.items[1], 1, function(r) delivered = r end)
        for _ = 1, 20 do
            if delivered then break end
            env.UIManager:flush()
        end
        t:check(delivered ~= nil, "the page came back")
        t:eq(#delivered.bb.blits, 0, "with nothing composed over it")
        delivered.release()
    end)

    t:describe("main / page ink / no commit under a contact (ADR-42)")

    t:case("the first stroke on a page makes the menu's count stale", function()
        local p = documentPlugin()
        t:eq(startDrawing(p), true, "drawing is on")
        -- Reading it is what caches it, whatever it answers.
        p:documentInkCount()
        t:check(p.document_ink_count ~= nil, "the menu's count is cached")
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 20, INK_XY.y + 20)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        t:eq(p.document_ink_count, nil,
            "the stroke invalidated the cache the menu reads")
    end)

    t:case("the write timer stands aside while the pen is on the glass", function()
        local p, store = documentPlugin()
        t:eq(startDrawing(p), true, "drawing is on")
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 20, INK_XY.y + 20)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)   -- queued on the lift
        t:eq(p.document_session:pendingWrites(), 1, "one operation is waiting")
        penDown(p, INK_XY.x, INK_XY.y + 80)        -- the next contact starts first
        local transactions = store.calls.transaction
        env.UIManager:flush()                      -- the due flush must yield
        t:eq(store.calls.transaction, transactions, "held under the contact")
        t:eq(p.document_session:pendingWrites(), 1, "and the operation is still held")
        penLift(p, INK_XY.x + 40, INK_XY.y + 80)
        env.UIManager:flush()
        t:check(store.calls.transaction > transactions, "committed after the lift")
        t:eq(p.document_session:pendingWrites(), 0, "and the queue drained")
    end)

    -- =================================================================
    t:describe("main / page ink never paints a page the session is not on")

    local function refusedTurn()
        local p, store = documentPlugin{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
            strokes = { [2] = { bar_stroke() } },
        }
        startDrawing(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 30, INK_XY.y + 30)
        penLift(p, INK_XY.x + 30, INK_XY.y + 30)
        store.fail_transaction = "commit"
        env.UIManager:flush()
        t:eq(p.document_session:saveFailed(), true,
            "the page-1 write really failed")
        p.view.state.page = 2
        p:onPageUpdate(2)
        env.UIManager:flush()
        t:eq(p.document_session:page(), 1, "the session is holding page 1")
        return p, store
    end

    t:case("the ordinary deferred-swap window paints no stale page", function()
        local p = documentPlugin{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar_stroke() } },
        }
        p.view.state.page = 2
        p:onPageUpdate(2) -- queues the session swap; do not drain it yet
        t:eq(p.document_session:page(), 1, "the deferred session is still on 1")
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.blits, 0, "page-1 ink was not composed over page 2")
    end)

    t:case("a refused turn stops the old page's ink painting over the new one", function()
        -- A flush that fails keeps the old surface open and refuses the turn,
        -- but the reader has already moved: without this guard the previous
        -- page's raster is blitted onto the page now on screen.
        local p = refusedTurn()
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.blits, 0, "and painted nothing onto page 2")
    end)

    t:case("painting resumes once the retry lands the turn", function()
        local p, store = refusedTurn()
        store.fail_transaction = nil
        p.document_session:retrySave()
        env.UIManager:flush()
        t:eq(p.document_session:page(), 2, "the turn completed")
        t:eq(p.document_session:surface().fixed_page, 2,
            "and the loaded raster belongs to page 2")
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:eq(#bb.blits, 1, "page 2's preloaded ink is composed again")
        t:eq(bb.blits[1].alpha, true, "through the alpha path")
    end)
end
