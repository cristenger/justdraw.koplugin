--[[--
JustDraw — draw on book pages with a finger.

The side toolbar is the control surface: it is a normal widget sitting above
ReaderUI, and the capture handler passes through any contact that starts inside
it, so Draw/Stop stays reachable even while every other single-finger touch is
being swallowed. Drawing can never be on without the toolbar visible.

Two input backends share that toolbar. `finger` is the legacy route: one
contact draws, two pass through. `stylus` uses KOReader's stylus callback for
the pen and suppresses every remaining touch, because the callback on its own
only hides the pen from gesture detection and would leave a palm free to turn
pages. See ADR-11 and ADR-12.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Version = require("version")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local CanvasSession = require("ink_canvas_session")
local Capture = require("ink_capture")
local Compat = require("ink_compat")
local InputController = require("ink_input_controller")
local InkBar = require("ink_bar")
local NotebookController = require("ink_notebook_controller")
local NotebookInput = require("ink_notebook_input")
local Limits = require("ink_limits")
local Render = require("ink_render")
local Router = require("ink_contact_router")
local Stack = require("ink_stack")
local Store = require("ink_store")
local StylusTrace = require("ink_stylus_trace")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SUSPENDED = -1   -- draw_slot sentinel: ignore this contact until it lifts

local INPUT_MODES = { auto = true, stylus = true, finger = true }
local function updateLiveRasterToken(stroke, box, cache, generation)
    if stroke.live_raster_complete == false then return end
    if not box or not cache or generation == nil then
        stroke.live_raster_complete = false
        return
    end
    if stroke.raster_cache == nil then
        stroke.raster_cache = cache
        stroke.raster_generation = generation
        stroke.live_raster_complete = true
    elseif stroke.raster_cache ~= cache
        or stroke.raster_generation ~= generation then
        stroke.live_raster_complete = false
    end
end

-- The margin flag that says "there is a sheet anchored here". Drawn on the
-- edge opposite the toolbar, so the two never overlap.
local MARK_W, MARK_H = 6, 28

-- Reasons Capture can refuse, mapped to something a user can act on.
local INPUT_ERRORS = {
    no_stylus_api = _("Stylus input requires KOReader v2026.07 or newer"),
    stylus_callback_busy = _("Another plugin is already using stylus input"),
    no_gesture_detector = _("JustDraw: cannot hook touch input"),
    -- Not a refusal: drawing still starts, on the finger route. It is the
    -- answer to "my pen does nothing", given before the user has to ask.
    pen_unavailable = _("Pen input needs KOReader v2026.07 or newer. Drawing with finger."),
    no_input = _("JustDraw: cannot hook touch input"),
    already_installed = _("JustDraw: input is already captured"),
    handler_error = _("JustDraw: drawing stopped after an input error"),
}

local JustDraw = WidgetContainer:extend{
    name = "justdraw",
    is_doc_only = false,
}

-- ---------------------------------------------------------------- lifecycle

function JustDraw:init()
    -- FileManager only passes `ui`; ReaderUI additionally exposes document,
    -- view and doc_settings. Keep notebook construction document-free so the
    -- same library can be opened safely from either host.
    self.is_docless = self.ui.document == nil
    self.notebooks = nil
    self.notebook_input = nil
    self.notebook_ui = nil
    self.screen_resize_serial = 0
    self.screen_resize_pending = false
    self.drawing = false
    self.eraser = false
    self.bar = nil
    self.pen_width = Compat.readSetting(G_reader_settings, "pen_width", PEN_MEDIUM)
    self.live_fast = Compat.readSetting(G_reader_settings, "live_fast", true)
    self.bar_side = Compat.readSetting(G_reader_settings, "bar_side", "right")
    self.notebook_rail_side = Compat.readSetting(G_reader_settings, "notebook_rail_side")
    if self.notebook_rail_side ~= "left" and self.notebook_rail_side ~= "right" then
        self.notebook_rail_side = "right"
    end

    local mode = Compat.readSetting(G_reader_settings, "input_mode")
    self.input_mode = INPUT_MODES[mode] and mode or "auto"
    self.input_backend = nil
    self.input_lease = nil

    self.contacts = {}
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    self.stroke = nil

    self.stylus_active = false
    self.stylus_passthrough = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_stale_xy = false
    self.stylus_inked = false
    self.stylus_tool = nil
    self.stylus_lift_x, self.stylus_lift_y = nil, nil
    self.max_open_points = Limits.MAX_OPEN_POINTS
    self.max_contact_samples = Limits.MAX_CONTACT_SAMPLES
    self.stylus_sample_count = 0
    self.stylus_budget_notified = false
    self.trace_route_reason = nil

    self.stylus_trace = nil
    self.trace_event_ordinal = 0
    self.trace_frame_ordinal = 0
    self.trace_source = nil
    self.pen_notice_shown = false

    -- The EPUB canvas. Everything about it stays nil until a reflowable
    -- document is ready, and every entry point checks `canvas_open`, so a PDF
    -- session behaves exactly as it did before any of this existed.
    self.session = nil
    self.router = nil
    self.canvas_open = false
    self.canvas_erase_ctx = nil
    self.canvas_erase_x, self.canvas_erase_y = nil, nil
    self.canvas_stroke = nil
    self.canvas_backpressure_notified = false
    self.canvas_backpressure_notice_pending = false
    self.stroke_budget_notice_pending = false
    self.canvas_pending_repaint = nil
    self.canvas_pending_capture_stop = nil
    --- Left nil in production, where the session opens its own connection.
    --- The suite runs under a bare interpreter that cannot load the SQLite
    --- driver at all, so it hands one in.
    self.canvas_repository = nil

    self.ui.menu:registerToMainMenu(self)
    if self.is_docless then return end

    local pages
    pages, self.stroke_storage_id, self.stroke_storage_present =
        Compat.readDataSetting(self.ui.doc_settings, "strokes")
    self.store = Store.new(pages)
    self.direct_ink_clear_all = false

    self:registerDispatcher()
    self.view:registerViewModule("justdraw", self)

    if Compat.readSetting(G_reader_settings, "bar_shown", true) ~= false then
        UIManager:nextTick(function() self:setBarShown(true) end)
    end
end

--- Return the headless notebook domain without opening its SQLite database.
function JustDraw:notebookController()
    if self.notebooks then return self.notebooks end
    self.notebook_input = NotebookInput.new{
        get_mode = function() return self.input_mode end,
        get_pen_width = function() return self.pen_width end,
        get_eraser = function() return self.eraser end,
        on_error = function(reason) self:notify(reason or "input_failed") end,
        on_domain_error = function(reason, session)
            if reason ~= "operation_too_large" or not session
                or type(session.failInputDeferred) ~= "function" then
                return
            end
            local ok, err = session:failInputDeferred(reason)
            if not ok then
                logger.err("JustDraw notebooks: input teardown failed:", err)
            end
        end,
        get_stylus_trace = function() return self:activeStylusTrace("notebook") end,
    }
    local adapter = self.notebook_input
    self.notebooks = NotebookController.new{
        require_viewport = true,
        schedule = function(fn) UIManager:nextTick(fn) end,
        scheduleIn = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        notify = function(text) self:notify(text) end,
        before_open = function(_, controller)
            return self:prepareNotebookHandoff(controller)
        end,
        session_opts = {
            capture_spec = function(session, page, transform)
                return adapter:captureSpec(session, page, transform)
            end,
            abort_contact = function(session) return adapter:abort(session) end,
        },
    }
    return self.notebooks
end

function JustDraw:notebookUI()
    if self.notebook_ui then return self.notebook_ui end
    local NotebookUI = require("ink_notebook_ui")
    self.notebook_ui = NotebookUI.new{
        plugin = self,
        controller = self:notebookController(),
    }
    return self.notebook_ui
end

function JustDraw:openNotebookLibrary()
    return self:notebookUI():openLibrary()
end

function JustDraw:setNotebookRailSide(side)
    if side ~= "left" and side ~= "right" then return nil, "bad_side" end
    if self.notebook_rail_side == side then return true end
    self.notebook_rail_side = side
    Compat.saveSetting(G_reader_settings, "notebook_rail_side", side)
    return true
end

function JustDraw:prepareNotebookHandoff(controller)
    if self.canvas_open then
        local closed, close_err = self:closeCanvas()
        if not closed then return nil, close_err end
    end
    local lease = self.input_lease
    if lease and lease:hasActiveContact() then return nil, "contact_active" end
    if lease then
        if not self.is_docless and self.drawing then
            self:setDrawing(false)
            if self.input_lease then return nil, "release_failed" end
        else
            local released, release_err = lease:release()
            if not released then return nil, release_err end
            self.input_lease = nil
        end
    end
    local owner = InputController:activeOwner()
    if owner and owner ~= controller then return nil, "already_installed" end
    return true
end

-- Public UI seam: visual code supplies only regions and
-- repaint policy. Hardware input and persistence stay below it.
function JustDraw:configureNotebookInteraction(opts)
    local controller = self:notebookController()
    opts = opts or {}
    local configured, configure_err = controller:configureInteraction{
        viewport_provider = opts.viewport_provider,
        transform_factory = opts.transform_factory,
        fit_rect = opts.fit_rect,
        clip_rect = opts.clip_rect,
        align_x = opts.align_x,
        align_y = opts.align_y,
        on_page_ready = opts.on_page_ready,
        on_dirty_box = opts.on_dirty_box,
        on_state_changed = opts.on_state_changed,
        on_durable_change = opts.on_durable_change,
        on_library_changed = opts.on_library_changed,
    }
    if not configured then return nil, configure_err end
    self.notebook_input:configure(opts)
    return true
end

function JustDraw:registerDispatcher()
    -- Gesture Manager persists Dispatcher action IDs. Keep these legacy IDs
    -- and events so assignments made before the rename continue to work; only
    -- their visible titles use the current brand.
    Dispatcher:registerAction("fingerink_toggle", {
        category = "none", event = "FingerInkToggle", reader = true,
        title = _("JustDraw: toggle drawing"),
    })
    Dispatcher:registerAction("fingerink_eraser", {
        category = "none", event = "FingerInkEraser", reader = true,
        title = _("JustDraw: toggle eraser"),
    })
    Dispatcher:registerAction("fingerink_undo", {
        category = "none", event = "FingerInkUndo", reader = true,
        title = _("JustDraw: undo stroke"),
    })
    Dispatcher:registerAction("fingerink_bar", {
        category = "none", event = "FingerInkBar", reader = true,
        title = _("JustDraw: toggle toolbar"),
    })
end

--[[--
Start the canvas session, once the document is ready.

Not in `init`: half the book's identity is `partial_md5_checksum`, which
ReaderUI computes on its way to emitting this event. Only reflowable documents
get one -- a canvas anchored by xpointer means nothing in a fixed layout, and
`anchor_kind = 'page'` is reserved for when it does.
]]
function JustDraw:onReaderReady(config)
    if self.is_docless or self.session or not self.ui.rolling or not self.ui.document then return end

    -- The checksum lives in the document's settings, not on ReaderUI, which
    -- computes it there on its way to emitting this event
    -- (readerui.lua:473 @ v2026.07). Statistics reads it the same way.
    local settings = config or self.ui.doc_settings

    self.session = CanvasSession.new{
        document = self.ui.document,
        identity = {
            partial_md5 = settings:readSetting("partial_md5_checksum"),
            file_size = self:documentSize(),
        },
        file = self.ui.document.file,
        dom_version = settings:readSetting("cre_dom_version"),
        repository = self.canvas_repository,
        plugin = self,
        ui = self.ui,
        schedule = function(fn) UIManager:nextTick(fn) end,
        scheduleIn = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        notify = function(text) self:notify(text) end,
    }
    if not self.session:open() then
        self.session = nil
        return
    end
    self.router = Router.new{
        backend = self.input_backend or "finger",
        regions = function(x, y) return self:regionAt(x, y) end,
        dialogOnTop = function() return self:dialogOnTop() end,
    }
    self:onPageUpdate(self:currentPage())
end

--- The other half of the book's identity. `lfs` is not in the test harness and
--- is not worth requiring for a value the caller can also supply.
function JustDraw:documentSize()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not self.ui.document or not self.ui.document.file then return nil end
    return lfs.attributes(self.ui.document.file, "size")
end

function JustDraw:onCloseDocument()
    self:teardown()
end

function JustDraw:onCloseWidget()
    self:teardown()
end

function JustDraw:onSuspend()
    if self.notebooks then self.notebooks:onSuspend() end
    if not self.is_docless then self:setDrawing(false) end
end

function JustDraw:onResume()
    if self.notebooks then
        local resumed, resume_err = self.notebooks:onResume()
        if not resumed then logger.warn("JustDraw: notebook resume failed:", resume_err) end
    end
    if self.notebook_ui then self.notebook_ui:onResume() end
end

--[[--
Every exit path lands here. It has to do exactly what stopping does, including
dropping the stroke in flight: an unfinished stroke is not in the store yet, so
leaving it dangling loses it silently and leaks contact state into whatever
document is opened next in the same session.
]]
function JustDraw:teardown()
    self.screen_resize_serial = self.screen_resize_serial + 1
    self.screen_resize_pending = false
    if self.notebook_ui then
        local closed, close_err = self.notebook_ui:shutdown()
        if not closed then
            logger.warn("JustDraw: notebook UI close failed during teardown:", close_err)
        end
        self.notebook_ui = nil
        self.notebooks = nil
        self.notebook_input = nil
    elseif self.notebooks then
        local closed, close_err = self.notebooks:shutdown()
        if not closed then
            logger.warn("JustDraw: notebook close failed during teardown:", close_err)
        end
        self.notebooks = nil
        self.notebook_input = nil
    end
    if self.is_docless then return end
    -- Before the session goes: abortStroke reaches the sheet's stroke through
    -- it, and an unfinished stroke is not in any store yet.
    self:abortStroke()
    if self.session then
        self.session:close{ force = true }
        self.session = nil
        self.router = nil
        self.canvas_open = false
        self.canvas_pending_repaint = nil
    end
    if self.input_lease then self.input_lease:release() end
    self.input_lease = nil
    self:resetContacts()
    self:resetStylusState()
    self.input_backend = nil
    self.drawing = false
    if self.bar then
        UIManager:close(self.bar)
        self.bar = nil
    end
end

--[[--
The durable-save gate for canvas ink.

`Device:_beforeSuspend` calls `UIManager:flushSettings()` and only then emits
`Suspend`, and the close path emits this before DocSettings is written and the
document closed. Saving in `onSuspend` would already be too late.
]]
function JustDraw:onSaveSettings()
    if self.notebooks then
        local saved, save_err = self.notebooks:onFlushSettings()
        if not saved then
            logger.warn("JustDraw: SaveSettings notebook flush failed:", save_err)
        end
    end
    if self.is_docless then return end
    if self.session then
        local saved, save_err = self.session:flush()
        if not saved then
            -- Queue already retained the operations and emitted the reader's
            -- deduplicated notification; this log makes the lifecycle gate's
            -- failed return explicit without claiming settings were durable.
            logger.warn("JustDraw: SaveSettings canvas flush failed:", save_err)
        end
    end
    local explicit_clear = self.direct_ink_clear_all
    if explicit_clear then
        Compat.delSetting(self.ui.doc_settings, "strokes")
        self.stroke_storage_id = Compat.current_id
        self.stroke_storage_present = false
        self.direct_ink_clear_all = false
    end
    if not self.store:isEmpty() then
        Compat.saveDataSetting(self.ui.doc_settings, "strokes",
            self.stroke_storage_id, self.store.pages)
        self.stroke_storage_present = true
    elseif not explicit_clear and self.stroke_storage_present then
        -- Undo, eraser and Clear page may remove the last active stroke. Keep
        -- an empty value under that active identity so readDataSetting cannot
        -- fall back to and expose (or later delete) an inactive divergent key.
        Compat.saveDataSetting(self.ui.doc_settings, "strokes",
            self.stroke_storage_id, self.store.pages)
    end
end

function JustDraw:clearWholeDocumentInk()
    self.store:clearAll()
    self.direct_ink_clear_all = true
    self:repaint()
end

--- Rotation and resize invalidate the bar's fixed position; rebuild it.
function JustDraw:rebuildBar()
    if not self.bar then return end
    UIManager:close(self.bar)
    self.bar = nil
    UIManager:nextTick(function() self:setBarShown(true) end)
end

function JustDraw:_applyScreenResize()
    if self.notebook_ui then
        local resized, resize_err = self.notebook_ui:onScreenResize()
        if not resized then
            logger.warn("JustDraw: notebook UI resize failed:", resize_err)
        end
    elseif self.notebooks then
        local resized, resize_err = self.notebooks:onScreenResize()
        if not resized then
            logger.warn("JustDraw: notebook resize failed:", resize_err)
        end
    end
    if self.is_docless then return end
    local overlay = self.session and self.session:overlay()
    if overlay then
        overlay:onScreenResize()
        self.bar = overlay.bar
    else
        self:rebuildBar()
    end
end

function JustDraw:onScreenResize()
    -- A real ScreenResize/SetDimensions after rotation supersedes the deferred
    -- SetRotationMode reconciliation below.
    self.screen_resize_serial = self.screen_resize_serial + 1
    self.screen_resize_pending = false
    self:resetStylusTraceContactHistory()
    return self:_applyScreenResize()
end

function JustDraw:onSetRotationMode()
    if self.screen_resize_pending then return end
    self:resetStylusTraceContactHistory()
    self.screen_resize_pending = true
    self.screen_resize_serial = self.screen_resize_serial + 1
    local serial = self.screen_resize_serial
    -- FileManager changes Screen dimensions after broadcasting SetRotationMode
    -- to plugin children. Reconcile on the next tick, when the host has applied
    -- the rotation. A subsequent ScreenResize invalidates this callback.
    UIManager:nextTick(function()
        if not self.screen_resize_pending or self.screen_resize_serial ~= serial then return end
        self.screen_resize_pending = false
        self:_applyScreenResize()
    end)
end

-- ----------------------------------------------------------- canvas events

--- A page turn. Only the marks are recomputed; the index answers from memory.
function JustDraw:onPageUpdate(page)
    if self.session then self.session:setPage(page or self:currentPage()) end
end

--[[--
`PosUpdate` carries `(pos, pageno)` -- the scroll position first
(readerrolling.lua:1089 @ v2026.07). Aliasing it to `onPageUpdate` would hand a
byte offset to something that looks up canvases by page number, and every mark
in scroll mode would land on the wrong page or on none.
]]
function JustDraw:onPosUpdate(_, page)
    self:onPageUpdate(page)
end

--- Font, margin or line-height change. The page index is rebuilt; not one
--- stroke is read, written or moved.
function JustDraw:onDocumentRerendered()
    if self.session then self.session:invalidate() end
end

--- The asynchronous page index has caught up with the current layout. Session
--- already recomputed `marks_here`; repaint so the first visible page does not
--- wait for an unrelated PageUpdate before showing its sheet markers.
function JustDraw:onCanvasIndexReady()
    if self.session then UIManager:setDirty(self.ui, "ui") end
end

-- ----------------------------------------------------------------- toolbar

function JustDraw:setBarShown(on)
    on = on and true or false
    -- With a sheet open the toolbar is the overlay's child, not a window of
    -- ours. "Hide" then means put the sheet away -- the invariant is still
    -- that drawing is never on without a way to turn it off.
    if self.canvas_open then
        if not on then self:closeCanvas() end
        return
    end
    Compat.saveSetting(G_reader_settings, "bar_shown", on)

    if on then
        if self.bar then return end
        self.bar = InkBar:new{ plugin = self, side = self.bar_side }
        UIManager:show(self.bar, "ui", self.bar.dimen)
    else
        -- Invariant: drawing is never on without a way to turn it off.
        self:setDrawing(false)
        if not self.bar then return end
        local dimen = self.bar.dimen
        UIManager:close(self.bar)
        self.bar = nil
        UIManager:setDirty(self.ui, "ui", dimen)
    end
end

function JustDraw:onJustDrawBar()
    self:setBarShown(self.bar == nil)
    return true
end

function JustDraw:inBar(x, y)
    return self.bar ~= nil and self.bar:contains(x, y)
end

--[[--
True while a menu or dialog is open over the reader.

Drawing mode eats single-finger touches before UIManager ever sees them, which
would otherwise make an open menu impossible to dismiss — tapping outside it is
the only way to close one. So drawing yields for as long as one is up.
]]
--- Whichever JustDraw window is currently the topmost: the canvas overlay
--- when a sheet is open, the standalone toolbar otherwise.
function JustDraw:topWindow()
    local overlay = self.session and self.session:overlay()
    if overlay then return overlay end
    return self.bar
end

function JustDraw:dialogOnTop()
    local top = self:topWindow()
    if not top then return false end
    local below = Stack.below(top)
    return below ~= nil and below ~= self.ui
end

--[[--
Which part of the screen this point belongs to.

With no sheet open there are only two answers and only the toolbar matters.
With one open this is the router's geometry oracle, and the order is the one
that keeps Stop reachable: toolbar, handle, sheet, book.

Everything inside the sheet answers "canvas", letterbox margins included. They
are not a drawing surface -- the transform refuses to ink there -- but they do
belong to the sheet, and a page turn under the sheet would be worse than
nothing happening.
]]
function JustDraw:regionAt(x, y)
    local overlay = self.session and self.session:overlay()
    if not overlay then
        return self:inBar(x, y) and "bar" or "reader"
    end
    if overlay.bar:contains(x, y) then return "bar" end
    if overlay:inHandle(x, y) then return "handle" end
    if overlay:inSheet(x, y) then return "canvas" end
    return "reader"
end

-- ------------------------------------------------------------------- state

function JustDraw:notify(text)
    UIManager:show(Notification:new{ text = text })
end

function JustDraw:notifyCanvasBackpressure()
    if self.canvas_backpressure_notice_pending then return end
    self.canvas_backpressure_notice_pending = true
    local generation = self.drawing_generation or 0
    local active = self.session and self.session:activeCanvas()
    local canvas_id = active and active.id
    UIManager:nextTick(function()
        self.canvas_backpressure_notice_pending = false
        local current = self.session and self.session:activeCanvas()
        if (self.drawing_generation or 0) ~= generation
            or not self.canvas_open or not current or current.id ~= canvas_id then
            return
        end
        self:notify(_("Stroke was not saved because the write queue is busy. Try again."))
    end)
end

function JustDraw:notifyStrokeBudget()
    if self.stroke_budget_notice_pending then return end
    self.stroke_budget_notice_pending = true
    local generation = self.drawing_generation or 0
    UIManager:nextTick(function()
        self.stroke_budget_notice_pending = false
        if (self.drawing_generation or 0) ~= generation then return end
        self:notify(_("Stroke stopped because the pen contact did not end. Lift the pen and try again."))
    end)

end
function JustDraw:currentPage()
    return self.view.state.page or 1
end

--[[--
Which capture backend to install, or nil plus a reason.

`auto` falls back to finger rather than to stylus on purpose. The stylus
backend swallows all touch, so picking it on a device with no pen would leave
the user unable to draw at all.

`wacom_protocol` is the only capability flag KOReader offers here and it is
narrow: the three Kindle Scribes and the reMarkable set it, Kobo never does.
Kobo stylus devices report their tool through ABS_MT_TOOL_TYPE instead and do
work, but they have to be opted in with the explicit `stylus` mode, which
deliberately does not require the flag.

isSDL deliberately does *not* widen `auto`. koreader-base does translate SDL3
pen events into the pen slot with a real tool, so a graphics tablet would work
— but a plain mouse goes to slot 0 or 1 with no ABS_MT_TOOL_TYPE at all, so it
never reaches the stylus callback and the residual filter would swallow it.
Auto-selecting stylus in the emulator would mean the mouse could not draw.
Testers with a tablet pick `stylus` by hand.
]]
function JustDraw:resolveInputBackend()
    local mode = self.input_mode
    if mode == "finger" then return "finger" end

    local has_api = Capture:supportsStylus()
    if mode == "stylus" then
        if not has_api then return nil, "no_stylus_api" end
        return "stylus"
    end

    if has_api and Device.input.wacom_protocol == true then
        return "stylus"
    end
    return "finger"
end

function JustDraw:reportInputFailure(reason)
    logger.warn("JustDraw: cannot start drawing:", reason)
    self:notify(INPUT_ERRORS[reason] or INPUT_ERRORS.no_gesture_detector)
end

--[[--
Emergency stop after an input handler raised. Capture has already unhooked
itself by the time this runs; this is the plugin-side half. Guarded so a second
call — Capture disarming and the handler disarming again — stays silent.
]]
function JustDraw:disarmInput(err)
    if not self.drawing and self.input_backend == nil then return end
    self:resetStylusTraceContactHistory()
    logger.err("JustDraw: disarming input capture after a handler error:", err)
    self.drawing = false
    self.input_backend = nil
    if self.input_lease then self.input_lease:release() end
    self.input_lease = nil
    self:abortStroke()
    self:resetContacts()
    self:resetStylusState()
    self:notify(INPUT_ERRORS.handler_error)
    if self.bar then self.bar:update(true) end
end

function JustDraw:setDrawing(on)
    on = on and true or false
    if on == self.drawing then return end
    if on and self.canvas_open and self.session and not self.session:isWritable() then
        self:notify(_("This sheet is read-only"))
        return
    end
    if on and self.canvas_open and self.session then
        if self.session:saveFailed() then
            self:notify(_("Could not save ink. Use Retry saving before drawing again."))
            return
        end
        local cache = self.session:cache()
        if not cache or not cache:isReady() then
            self:notify(_("This sheet's ink is still loading"))
            return
        end
    end

    -- Reusing Wacom's fixed slot/id after a lease replacement is a new
    -- diagnostic epoch even when the old lease never observed a physical
    -- lift. Never let trace deltas bridge that boundary.
    self:resetStylusTraceContactHistory()
    self.drawing_generation = (self.drawing_generation or 0) + 1

    if on then
        -- Resolve before touching the toolbar: a refusal must not leave the
        -- bar forced on and the preference rewritten.
        local backend, reason = self:resolveInputBackend()
        if not backend then
            return self:reportInputFailure(reason)
        end
        if not self.bar then self:setBarShown(true) end

        local lease
        if backend == "stylus" then
            lease, reason = InputController:acquire(self, {
                backend = "stylus",
                stylus_handler = function(slot) return self:onStylusEvent(slot) end,
                frame_handler = function(slots) return self:onStylusTouchFrame(slots) end,
                has_active_contact = function() return self.stylus_active end,
                on_error = function(err) self:disarmInput(err) end,
            })
        else
            lease, reason = InputController:acquire(self, {
                backend = "finger",
                frame_handler = function(slots) return self:onTouchFrame(slots) end,
                has_active_contact = function() return self.n_contacts > 0 end,
                on_error = function(err) self:disarmInput(err) end,
            })
        end
        -- Drawing only goes on after a complete install, never before.
        if not lease then
            return self:reportInputFailure(reason)
        end

        self.input_lease = lease
        self.input_backend = backend
        self.drawing = true
        if self.router then self.router:setBackend(backend) end
        logger.info("JustDraw: drawing on, mode", self.input_mode, "backend", backend)
        self:notePenUnavailable(backend)
    else
        self:abortStroke()
        if self.input_lease then self.input_lease:release() end
        self.input_lease = nil
        self:resetContacts()
        self:resetStylusState()
        self.input_backend = nil
        self.drawing = false
        logger.info("JustDraw: drawing off")
    end
    if self.bar then self.bar:update(true) end
end

--[[--
Say it out loud when a device that has a pen ends up on the finger route.

`auto` needs two things and only reports neither: the runtime's stylus callback
API, and a device that claims a pen digitizer. A Kindle Scribe on KOReader
v2026.03 has the second and not the first, so drawing starts, the finger inks,
the pen does nothing, and nothing on screen connects those facts.

Once per session. Repeating it on every Draw would be nagging about something
the user cannot fix without reflashing.
]]
function JustDraw:notePenUnavailable(backend)
    if backend ~= "finger" or self.pen_notice_shown then return end
    if self.input_mode ~= "auto" then return end
    if Device.input == nil or Device.input.wacom_protocol ~= true then return end
    self.pen_notice_shown = true
    logger.warn("JustDraw: device reports a pen digitizer but this runtime has no stylus API")
    self:notify(INPUT_ERRORS.pen_unavailable)
end

function JustDraw:setInputMode(mode)
    if not INPUT_MODES[mode] or mode == self.input_mode then return true end
    -- The menu item is disabled while drawing, but the guard belongs here:
    -- swapping backends inside a live contact sequence tears down capture
    -- mid-stroke, and the menu is not the only possible caller.
    if self.drawing then
        logger.warn("JustDraw: refusing to change input mode while drawing")
        return nil, "contact_active"
    end
    local function apply()
        self.input_mode = mode
        Compat.saveSetting(G_reader_settings, "input_mode", mode)
    end
    if self.notebooks and self.notebooks:activeSession() then
        local changed, change_err = self.notebooks:reconfigureInput(apply)
        if not changed then return nil, change_err end
    else
        apply()
    end
    logger.info("JustDraw: input mode set to", mode)
    return true
end

function JustDraw:setEraser(on)
    if on and self.canvas_open and self.session and not self.session:isWritable() then
        self:notify(_("This sheet is read-only"))
        return
    end
    self.eraser = on and true or false
    if not self.eraser then self:endCanvasErase() end
    if self.eraser and not self.drawing then
        self:setDrawing(true)   -- also updates the bar
    elseif self.bar then
        self.bar:update(true)
    end
end

function JustDraw:resetContacts()
    for slot in pairs(self.contacts) do
        self.contacts[slot] = nil
    end
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    -- Every caller reaches this only after capture has been released or made
    -- inert. The frame wrapper cannot observe later physical lifts, so contact
    -- ownership ends with the lease and reused slots must start unclassified.
    if self.router then self.router:reset() end
end

--- Per-sequence pen state. `stylus_lift_x/y` deliberately survives, because it
--- is how the next contact-down detects stale coordinates.
function JustDraw:resetStylusState()
    self.stylus_active = false
    self.stylus_passthrough = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_stale_xy = false
    self.stylus_inked = false
    self.stylus_tool = nil
    self.stylus_sample_count = 0
    self.stylus_budget_notified = false
    self.trace_route_reason = nil
end

function JustDraw:onJustDrawToggle()
    self:setDrawing(not self.drawing)
    return true
end

function JustDraw:onJustDrawEraser()
    self:setEraser(not self.eraser)
    return true
end

-- ------------------------------------------------------------------- input

--[[--
Called on every touch frame while drawing mode is on, before GestureDetector
sees it. Capture only: it reads contacts to draw from and maintains the
passthrough latch. Since ADR-13 what reaches the app is decided per gesture in
InkBar:suppresses, so this always returns true.
]]
function JustDraw:onTouchFrame(slots)
    if self.canvas_open then
        local kept = self:routeCanvasFinger(slots)
        self:_flushPendingCanvasCaptureStop()
        return kept
    end

    if not self.passthrough and self:dialogOnTop() then
        -- Latches for the whole contact sequence, and re-latches on the next
        -- one, so drawing resumes by itself once the dialog is gone.
        self.passthrough = true
        self:abortStroke()
    end

    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev.slot or 0
        local id = ev.id

        if id and id >= 0 then
            if not self.contacts[slot] then
                self.contacts[slot] = true
                self.n_contacts = self.n_contacts + 1
                if self.n_contacts > 1 and not self.passthrough then
                    self.passthrough = true
                    self:abortStroke()
                end
            end
            if not self.passthrough and ev.x and ev.y then
                self:onContactPoint(slot, ev.x, ev.y)
            end
        else
            if self.contacts[slot] then
                self.contacts[slot] = nil
                self.n_contacts = self.n_contacts - 1
            end
            if self.n_contacts <= 0 then
                self.n_contacts = 0
                if not self.passthrough then
                    self:endStroke()
                end
                self.passthrough = false
                self.draw_slot = nil
            end
        end
    end

    return true
end

--- Finger route. `tool` is always nil here and exists only so both backends
--- share one entry point; see applyPoint.
function JustDraw:onContactPoint(slot, raw_x, raw_y, tool)
    local x, y = Capture.toScreen(raw_x, raw_y)

    if self.draw_slot == nil then
        if self:inBar(x, y) then
            -- Contact started on the toolbar: hand the whole sequence to
            -- GestureDetector so the button gets its tap.
            self.passthrough = true
            self:abortStroke()
            return
        end
        self.draw_slot = slot
    elseif self.draw_slot ~= slot then
        return
    end

    if self:inBar(x, y) then
        -- Dragged onto the toolbar. End the stroke at the edge rather than
        -- painting over the buttons.
        self:endStroke()
        self.draw_slot = SUSPENDED
        return
    end

    self:applyPoint(x, y, tool)
end

--[[--
The single place that decides ink versus erase, shared by both backends.

`tool` is whatever KOReader reported for this contact, or nil on the finger
route. A physical eraser wins over the toolbar's setting; everything else —
pen, highlighter, and the TOOL_TYPE_FINGER a pen slot reports on its way out of
proximity — defers to it.
]]
function JustDraw:applyPoint(x, y, tool)
    if self.canvas_open then return self:applyCanvasPoint(x, y, tool) end
    if tool == Capture.TOOL_ERASER or self.eraser then
        self:eraseAt(x, y)
    elseif self.stroke then
        self:addPoint(x, y)
    else
        self:startStroke(x, y)
    end
end

-- ------------------------------------------------------------- stylus input

--[[--
Called for every pen slot KOReader routes to us, before gesture detection.
Returning true dominates the slot: KOReader drops it from MTSlots and the
gesture detector never sees it.

Two properties of the slot data shape this function, and both are easy to get
wrong (c.f. frontend/device/input.lua:1381-1450):

  * the table is Input's own persistent `ev_slots[n]`, reused frame after
    frame, so `id`, `x` and `y` all survive a contact lift. Only transitions of
    `id` open and close strokes; coordinates alone never mean "there is
    contact", and a repeated lift must be idempotent because hover frames keep
    re-delivering `id == -1`.
  * `tool` can be TOOL_TYPE_FINGER on the pen slot, because leaving proximity
    writes exactly that, and the slot is still routed here by slot number. So
    `tool` picks ink-or-erase, never draw-or-not.

The domination decision is latched at contact-down and cannot change before the
lift. Flipping it mid-sequence corrupts GestureDetector's bookkeeping: true to
false makes it open a fresh contact mid-stroke and emit a spurious tap on lift,
and false to true strands a contact that never sees its lift, leaving a pending
hold timer that blocks the slot until the next dropContacts().
]]
function JustDraw:_routeLegacyStylusEvent(slot)
    local id, x, y, tool = slot.id, slot.x, slot.y, slot.tool

    -- Hover before this slot ever carried a tracking id. Consume, change nothing.
    if id == nil then return true end

    if id >= 0 and self.canvas_pending_capture_stop then
        self.stylus_suspended = true
        self.stylus_dominated = true
        return true
    end

    if id >= 0 then
        if not self.stylus_active then
            self.stylus_active = true
            -- The pen is on the page from this frame, even though where is
            -- not known yet. A finger arriving in that window is no less of a
            -- palm for being one frame early.
            if self.router and self.canvas_open then self.router:penContact(nil, nil) end
            self.stylus_passthrough = self:dialogOnTop()
            self.stylus_geom_latched = self.stylus_passthrough
            self.stylus_sample_count = 0
            self.stylus_budget_notified = false
            self.stylus_dominated = false
            self.stylus_suspended = false
            -- Coordinates are sticky. A contact-down frame that only carried
            -- BTN_TOUCH still presents the *previous* sequence's position, and
            -- latching or painting from it would either lose this whole stroke
            -- or ink a phantom dot at the old spot.
            self.stylus_stale_xy = x ~= nil
                and x == self.stylus_lift_x and y == self.stylus_lift_y
        end
        if self.stylus_passthrough then return false end

        if self.stylus_sample_count >= (self.max_contact_samples or Limits.MAX_CONTACT_SAMPLES) then
            if not self.stylus_suspended then
                self:abortStroke()
                self.stylus_suspended = true
                self.trace_route_reason = "sample_budget"
                if not self.stylus_budget_notified then
                    self.stylus_budget_notified = true
                    self:notifyStrokeBudget()
                end
            end
            self.stylus_dominated = true
            return true
        end
        self.stylus_sample_count = self.stylus_sample_count + 1

        -- Remember the last tool that was not the TOOL_TYPE_FINGER a pen slot
        -- reports on its way out of proximity. The lift frame often carries
        -- exactly that, and a point recovered from it must not silently become
        -- ink when the user was erasing.
        if tool ~= nil and tool ~= Capture.TOOL_FINGER then
            self.stylus_tool = tool
        end

        -- A dialog opened mid-stroke. Stop inking, but keep dominating to the
        -- lift: handing the slot back now would make GestureDetector open a
        -- fresh contact mid-stroke and emit a spurious tap.
        if self.stylus_dominated and not self.stylus_suspended and self:dialogOnTop() then
            self:abortStroke()
            self.stylus_suspended = true
        end

        if x and y and not self.stylus_stale_xy then
            local sx, sy = Capture.toScreen(x, y)
            if not self.stylus_geom_latched then
                self.stylus_geom_latched = true
                -- Only reachable before the first dominated frame, so the
                -- decision can still go to passthrough without a flip.
                if self.router and self.canvas_open then
                    self.router:penContact(sx, sy)
                end
                if not self.stylus_dominated and self:penPassesThrough(sx, sy) then
                    self.stylus_passthrough = true
                    return false
                end
            end
            self:onStylusPoint(sx, sy, tool)
        end
        -- Only the contact-down frame can be carrying stale coordinates.
        self.stylus_stale_xy = false
        self.stylus_dominated = true
        return true
    end

    -- Contact lift. Remember where it happened, for the staleness check above.
    if x and y then
        self.stylus_lift_x, self.stylus_lift_y = x, y
    end
    if not self.stylus_active then
        return not self.stylus_passthrough
    end
    local was_passthrough = self.stylus_passthrough
    -- A contact-down frame judged stale is sometimes a false positive: the pen
    -- really did come back down where it lifted last time. If the sequence
    -- produced no point at all, recover it from the lift frame, which by now
    -- carries a real position.
    if not was_passthrough and not self.stylus_inked
        and not self.stylus_suspended and x and y then
        local sx, sy = Capture.toScreen(x, y)
        self:onStylusPoint(sx, sy, self.stylus_tool)
    end
    if not was_passthrough then
        self:endStroke()
    end
    if self.router then self.router:penUp() end
    self:resetStylusState()
    return not was_passthrough
end
--- Describe the existing host FSM without retaining KOReader's mutable slot.
function JustDraw:_legacyStylusTraceState()
    if self.stylus_passthrough then return "active_pass" end
    if self.stylus_suspended then return "suspended" end
    if self.stylus_active then
        if not self.stylus_geom_latched then return "geometry_pending" end
        if self.stylus_inked then return "active_draw" end
        return "active_block"
    end
    return "idle"
end

local function legacyTraceDelivery(state)
    return state ~= "active_pass" and state ~= "forwarded_wait_lift"
end

function JustDraw:_recordLegacyStylusTrace(trace, slot_number, id, tool,
        x, y, timev, before_state, before_delivery, delivery, decision, reason)
    self.trace_event_ordinal = self.trace_event_ordinal + 1
    local dx, dy, dt = trace:deltas(slot_number, id, tool, x, y, timev)
    trace:record(self.trace_event_ordinal, self.trace_frame_ordinal + 1,
        slot_number, id, tool, x, y, timev,
        before_state, self:_legacyStylusTraceState(),
        before_delivery, delivery, decision, reason, dx, dy, dt)
end

--- Trace the current production route until a Scribe recording selects a
--- geometry policy for InkStylusSequence. With Diagnostics off this is one
--- nil check plus the existing host call and allocates no per-sample tables.
function JustDraw:onStylusEvent(slot)
    local trace = self:activeStylusTrace(self:diagnosticSource())
    if not trace then return self:_routeLegacyStylusEvent(slot) end

    local slot_number, id = slot.slot, slot.id
    local x, y, tool, timev = slot.x, slot.y, slot.tool, slot.timev
    local before_state = self:_legacyStylusTraceState()
    local before_delivery = legacyTraceDelivery(before_state)
    local dialog_before = self:dialogOnTop()
    self.trace_route_reason = nil
    local delivery = self:_routeLegacyStylusEvent(slot)
    local after_state = self:_legacyStylusTraceState()
    local decision, reason
    if id == nil then
        decision, reason = "discard", "hover"
    elseif id < 0 then
        if before_state == "idle" then
            decision, reason = "discard", "late_lift"
        elseif before_state == "geometry_pending" then
            decision = "lift"
            reason = x ~= nil and y ~= nil and "pending_dot" or "pending_discard"
        else
            decision, reason = "lift", "owner_lift"
        end
    elseif delivery == false then
        decision, reason = "pass", "route_pass"
    elseif after_state == "geometry_pending" then
        decision, reason = "pending", "geometry_pending"
    elseif after_state == "suspended" then
        if self.trace_route_reason == "point_budget"
            or self.trace_route_reason == "sample_budget" then
            decision, reason = "abort_budget", self.trace_route_reason
        else
            decision = "suspend"
            reason = dialog_before and "abort_suspend" or "finish_suspend"
        end
    elseif after_state == "active_draw" then
        decision = before_state == "active_draw" and "append" or "begin"
        reason = "accepted"
    elseif after_state == "active_block" then
        decision, reason = "accept", "route_block"
    else
        decision, reason = "accept", "route_draw"
    end
    self:_recordLegacyStylusTrace(trace, slot_number, id, tool, x, y, timev,
        before_state, before_delivery, delivery, decision, reason)
    return delivery
end

function JustDraw:_afterLegacyStylusFrame()
    local trace = self:activeStylusTrace(self:diagnosticSource())
    if not trace then return end
    trace:afterFrame()
    self.trace_frame_ordinal = self.trace_frame_ordinal + 1
end

--[[--
Whether a pen contact starting here belongs to somebody else.

With no sheet open that is the toolbar and nothing else, exactly as before.
With one open the resize handle joins it: dragging the sheet with the pen has
to work, and a stroke is not what the reader meant there.
]]
function JustDraw:penPassesThrough(x, y)
    if self.canvas_open then
        local region = self:regionAt(x, y)
        return region == "bar" or region == "handle"
    end
    return self:inBar(x, y)
end

--[[--
Why the pen route is or is not running, in one place.

This is the first thing to look at when the pen does nothing. The symptom on
its own already says a lot -- if a finger draws, the effective backend is
`finger`, because the stylus route never inks touch -- but it does not say
*which* precondition failed, and there are three.

Deliberately callable with drawing off and no backend installed. That is the
only state anybody is in when they ask this question.
]]
function JustDraw:diagnosticReport()
    local input = Device.input or {}
    local backend, reason = self:resolveInputBackend()
    local r = {
        version   = Version:getCurrentRevision(),
        model     = Device.model,
        mode      = self.input_mode,
        backend   = backend,
        reason    = reason,
        stylus_api = Capture:supportsStylus(),
        wacom     = input.wacom_protocol == true,
        pen_slot  = input.pen_slot,
        tool_types = input.TOOL_TYPE_PEN ~= nil,
        callback_taken = input.stylus_callback ~= nil,
    }

    -- The first unmet precondition, in the order the user can act on them.
    if r.mode == "finger" then
        r.blocker = _("Input mode is set to Finger. Set it to Automatic or Stylus.")
    elseif not r.stylus_api then
        r.blocker = _("This KOReader has no stylus API. The pen route needs v2026.07 or newer.")
    elseif r.callback_taken and backend ~= "stylus" then
        r.blocker = _("Another plugin already owns the stylus input callback.")
    elseif backend ~= "stylus" then
        r.blocker = _("This device does not report a pen digitizer. Set Input mode to Stylus by hand.")
    end
    return r
end

--- The report as lines, for the log and for the on-screen message.
function JustDraw:diagnosticLines()
    local r = self:diagnosticReport()
    local lines = {
        "KOReader: " .. tostring(r.version),
        "Device: " .. tostring(r.model),
        "Input mode: " .. tostring(r.mode) .. "  ->  backend: " .. tostring(r.backend),
        "Stylus API: " .. tostring(r.stylus_api)
            .. "   tool types: " .. tostring(r.tool_types),
        "Pen digitizer flag: " .. tostring(r.wacom)
            .. "   pen slot: " .. tostring(r.pen_slot),
        "Callback owned by another plugin: " .. tostring(r.callback_taken),
    }
    if r.blocker then lines[#lines + 1] = "" ; lines[#lines + 1] = r.blocker end
    return lines, r
end

function JustDraw:diagnosticSource()
    if self.canvas_open then return "epub_canvas" end
    return "direct"
end

function JustDraw:startDiagnostics(source, opts)
    source = source or self:diagnosticSource()
    opts = opts or {}
    if self.stylus_trace and self.stylus_trace:isActive() then
        self.stylus_trace:stop("reset")
    end
    local lines = self:diagnosticLines()
    for i = 1, #lines do
        if lines[i] ~= "" then logger.info("JUSTDRAW-DIAG", lines[i]) end
    end
    local emit = opts.emit or function(line) logger.info(line) end
    self.stylus_trace = StylusTrace.new{
        source = source,
        emit = emit,
        now = opts.now,
        duration_seconds = opts.duration_seconds,
        max_events = opts.max_events,
    }
    self.trace_event_ordinal = 0
    self.trace_frame_ordinal = 0
    self.trace_source = source
    emit("JUSTDRAW-STYLUS trace_start source=" .. source)
    return lines
end

function JustDraw:activeStylusTrace(source)
    local trace = self.stylus_trace
    if not trace or not trace:isActive() then
        self.stylus_trace = nil
        return nil
    end
    if source and trace.source ~= source then return nil end
    return trace
end

function JustDraw:resetStylusTraceContactHistory()
    local trace = self.stylus_trace
    if trace and type(trace.resetContactHistory) == "function" then
        trace:resetContactHistory()
    end
end

--- Warn before coordinates enter the local log, then show the capability report.
function JustDraw:showDiagnostics(source)
    local dialog
    dialog = ConfirmBox:new{
        text = _("Pen coordinates will be written to the local KOReader log for up to 60 seconds. JustDraw does not upload them; shared logs may contain them."),
        ok_text = _("Start"),
        ok_callback = function()
            UIManager:close(dialog)
            local lines = self:startDiagnostics(source)
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        end,
    }
    UIManager:show(dialog)
    return dialog
end

--[[--
One drawing point from the pen. Starting on the toolbar is already settled by
the latch, so the only case left is a stroke dragged *onto* the bar, which ends
at the edge rather than scribbling over the buttons.
]]
function JustDraw:onStylusPoint(x, y, tool)
    if self.stylus_suspended then return end

    if self.canvas_open then
        local region = self:regionAt(x, y)
        if region == "bar" or region == "handle" then
            -- Dragged onto the toolbar or the handle: end at the edge rather
            -- than scribbling over them.
            self:endCanvasStroke()
            self.stylus_suspended = true
            return
        end
        -- Over the book's text the pen stays dominated -- so the palm rule
        -- holds and no page turns under the reader's hand -- but the text is
        -- not a drawing surface in v1.
        if self:applyCanvasPoint(x, y, tool) then
            self.stylus_inked = true
        end
        return
    end

    if self:inBar(x, y) then
        self:endStroke()
        self.stylus_suspended = true
        return
    end
    self.stylus_inked = true
    self:applyPoint(x, y, tool)
end

--[[--
Residual contact bookkeeping for the stylus backend.

Runs after onStylusEvent within the same input frame, because
Input:routeStylusEvents is called immediately before feedEvent in every
handleTouchEv variant. So the pen's decision for this frame is already made and
a dominated pen slot is already gone from `slots`. That ordering is what lets
this function promise never to touch `self.stroke` — a palm landing mid-stroke
is precisely what the stylus backend exists to ignore.

Since ADR-13 it does not decide what gets emitted. Suppression lives in
InkBar:suppresses, per gesture and by position. What stays here is the state
that decision reads: how many non-pen contacts are down, and whether any of them
started on the toolbar. Always returns true.
]]
function JustDraw:onStylusTouchFrame(slots)
    if self.canvas_open then
        local kept = self:routeCanvasTouch(slots)
        self:_afterLegacyStylusFrame()
        self:_flushPendingCanvasCaptureStop()
        return kept
    end

    if not self.passthrough and self:dialogOnTop() then
        self.passthrough = true
    end

    for i = 1, #slots do
        local ev = slots[i]
        -- A pen slot handed back to the UI is not residual touch.
        if not Capture:isStylusSlot(ev) then
            local slot = ev.slot or 0
            local id = ev.id

            if id and id >= 0 then
                if not self.contacts[slot] then
                    -- "new" until this contact's first frame with coordinates
                    -- says where it started. The latch is per slot: a palm
                    -- that landed off the toolbar must not answer for the
                    -- finger reaching for Stop, which is the only way out.
                    self.contacts[slot] = "new"
                    self.n_contacts = self.n_contacts + 1
                end
                if self.contacts[slot] == "new" and ev.x and ev.y then
                    local x, y = Capture.toScreen(ev.x, ev.y)
                    if self:inBar(x, y) then
                        self.contacts[slot] = "bar"
                        self.passthrough = true
                    else
                        self.contacts[slot] = "page"
                    end
                end
            else
                if self.contacts[slot] then
                    self.contacts[slot] = nil
                    self.n_contacts = self.n_contacts - 1
                end
                if self.n_contacts <= 0 then
                    self.n_contacts = 0
                    self.passthrough = false
                end
            end
        end
    end

    self:_afterLegacyStylusFrame()
    return true
end

-- --------------------------------------------------------- canvas routing

--[[--
Residual touch while a sheet is open, on the pen route.

Slots the router calls palms are withheld from GestureDetector entirely -- down
frame and lift alike. Withholding only the down would leave the detector a lift
for a contact it never opened; withholding neither would let a palm's `hold`
reach the book, and a gesture carries no slot number, so by then there is
nothing left to tell it from the reader's own.

A contact whose first frame carried no coordinates has already gone through by
the time the next one places it. `dropContact` retires that one, per slot, so a
finger on the toolbar is untouched.
]]
function JustDraw:routeCanvasTouch(slots)
    local router = self.router
    if not router then return true end

    local kept = {}
    for i = 1, #slots do
        local ev = slots[i]
        if Capture:isStylusSlot(ev) then
            -- A pen slot handed back to the UI is not residual touch.
            kept[#kept + 1] = ev
        else
            local slot = ev.slot or 0
            local id = ev.id
            if id and id >= 0 then
                local before = router:destinationOf(slot)
                local sx, sy
                if ev.x and ev.y then sx, sy = Capture.toScreen(ev.x, ev.y) end
                local dest = router:touchContact(slot, sx, sy)
                if dest == "palm" then
                    if before == nil then Capture:dropContact(slot) end
                else
                    kept[#kept + 1] = ev
                end
            else
                local dest = router:destinationOf(slot)
                router:touchUp(slot)
                if dest ~= "palm" then kept[#kept + 1] = ev end
            end
        end
    end

    for _, slot in ipairs(router:takeCancelled()) do
        Capture:dropContact(slot)
    end
    return kept
end

--[[--
Touch while a sheet is open, on the finger route.

A single contact on the sheet draws; everything else -- the toolbar, the
handle, the book above the sheet -- goes to GestureDetector as usual, which is
what keeps page turning alive. A second contact landing on the sheet abandons
the stroke and hands both back, the same bargain ADR-3 makes for direct ink.
]]
function JustDraw:routeCanvasFinger(slots)
    local router = self.router
    if not router then return true end

    local kept = {}
    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev.slot or 0
        local id = ev.id
        if id and id >= 0 then
            local sx, sy
            if ev.x and ev.y then sx, sy = Capture.toScreen(ev.x, ev.y) end
            local dest = router:touchContact(slot, sx, sy)
            if dest == "canvas" then
                if self.draw_slot == nil then
                    self.draw_slot = slot
                elseif self.draw_slot ~= slot then
                    self:abortCanvasStroke()
                    self.draw_slot = SUSPENDED
                end
                if self.draw_slot == slot and sx then
                    self:applyCanvasPoint(sx, sy, nil)
                end
            else
                kept[#kept + 1] = ev
            end
        else
            local dest = router:destinationOf(slot)
            router:touchUp(slot)
            if self.draw_slot == slot then
                self:endCanvasStroke()
                self.draw_slot = nil
            elseif self.draw_slot == SUSPENDED and router:touchCount() == 0 then
                self.draw_slot = nil
            end
            if dest ~= "canvas" then kept[#kept + 1] = ev end
        end
    end
    return kept
end

-- ------------------------------------------------------------------ stroke

function JustDraw:startStroke(x, y)
    self.stroke = { n = 1, w = self.pen_width, x, y }
end

function JustDraw:addPoint(x, y)
    local s = self.stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == x and py == y then return true end
    if s.n >= (self.max_open_points or Limits.MAX_OPEN_POINTS) then
        self.trace_route_reason = "point_budget"
        self:abortStroke()
        if self.stylus_active then
            self.stylus_suspended = true
        else
            self.draw_slot = SUSPENDED
        end
        self:notifyStrokeBudget()
        return false
    end

    s[i + 1] = x
    s[i + 2] = y
    s.n = s.n + 1

    local painted, left, top, right, bottom =
        Render.segment(Screen.bb, px, py, x, y, s.w, INK)
    if painted then self:refreshBox(left, top, right, bottom) end
    return true
end

--- Ends whichever stroke is in progress. Every caller -- the pen lift, a
--- dialog opening mid-stroke, Stop -- means "finish what is being drawn", and
--- what that is depends on whether a sheet is open.
function JustDraw:endStroke()
    if self.canvas_open then return self:endCanvasStroke() end

    local s = self.stroke
    self.stroke = nil
    self.draw_slot = nil
    if not s then return end

    if s.n == 1 then -- a dot: never painted live, paint it now
        local painted, left, top, right, bottom =
            Render.stroke(Screen.bb, s, 0, 0, INK)
        if painted then self:refreshBox(left, top, right, bottom) end
    end
    self.store:add(self:currentPage(), s)
end

--- Gives up whichever stroke is in progress. See endStroke.
function JustDraw:abortStroke()
    if self.canvas_open then
        self.draw_slot = nil
        return self:abortCanvasStroke()
    end
    if not self.stroke then
        self.draw_slot = nil
        return
    end
    self.stroke = nil
    self.draw_slot = nil
    self:repaint()
end

function JustDraw:eraseAt(x, y)
    local page = self:currentPage()
    local list = self.store:get(page)
    local idx = Store.hit(list, x, y, ERASER_RADIUS)
    if not idx then return end
    self.store:removeAt(page, idx)
    self:repaint()
end

-- ------------------------------------------------------------- canvas ink

--[[--
Open a sheet, taking the toolbar with it.

There is never more than one JustDraw window: the standalone toolbar steps
down and the overlay's embedded one takes its place, so `self.bar` keeps
meaning "the toolbar the reader can see" everywhere else in this file.
]]
function JustDraw:openCanvas(canvas)
    if not (self.session and canvas) then return end
    if self.canvas_open and self.session:activeCanvas() == canvas then return end

    local switching = self.canvas_open
    if switching then
        -- Session may refuse to close the old sheet. Stop capture first, but
        -- leave its embedded toolbar/window owned by the old overlay until the
        -- durable switch succeeds.
        self:abortCanvasStroke()
        self:setDrawing(false)
    else
        self.bar_restore = self.bar ~= nil
    end
    if not switching and self.bar then
        local dimen = self.bar.dimen
        UIManager:close(self.bar)
        self.bar = nil
        UIManager:setDirty(self.ui, "ui", dimen)
    end

    local overlay, err = self.session:openCanvas(canvas)
    if not overlay then
        if switching then
            local old = self.session:overlay()
            if old then
                self.bar = old.bar
            else
                self.canvas_open = false
                self.bar = nil
                if self.bar_restore then self:setBarShown(true) end
            end
        elseif self.bar_restore then
            self:setBarShown(true)
        end
        return nil, err
    end
    self.canvas_pending_repaint = nil
    self.bar = overlay.bar
    self.canvas_open = true
    if self.router then self.router:reset() end
    if self.session:isWritable() and self.session:cache():isReady() then
        self:setDrawing(true)
    end
    return overlay
end

--- Overlay replaces its embedded toolbar whenever geometry or side changes.
--- Keep `self.bar` bound to the visible object; all state and input routing in
--- this module intentionally go through that single owner reference.
function JustDraw:onCanvasOverlayBarChanged(overlay)
    local current = self.session and self.session:overlay()
    if self.canvas_open and (current == nil or current == overlay) then
        self.bar = overlay.bar
    end
end

--- A rotation changes raster scale. This hook runs before Cache releases the
--- ready buffer, which is the last safe moment to abandon and repair a live
--- stroke. Rotation events are outside the stylus callback stack, so immediate
--- unregistration is safe here.
function JustDraw:onCanvasCacheWillRebuild(canvas)
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    self.canvas_pending_repaint = nil
    self:abortCanvasStroke()
    self:setDrawing(false)
end

--- Latch a domain-fatal input stop until the residual handler for this same
--- SYN_REPORT has filtered palms and advanced diagnostics. The stylus callback
--- runs before feedEvent, so releasing the lease there would bypass both.
function JustDraw:_requestCanvasCaptureStop(canvas, repair_live_stroke)
    if not canvas then return nil, "no_canvas" end
    local pending = self.canvas_pending_capture_stop
    if pending and pending.canvas_id == canvas.id then
        pending.repair_live_stroke = pending.repair_live_stroke
            or repair_live_stroke == true
        return true
    end
    self.canvas_pending_capture_stop = {
        canvas = canvas,
        canvas_id = canvas.id,
        repair_live_stroke = repair_live_stroke == true,
    }
    return true
end

function JustDraw:_flushPendingCanvasCaptureStop()
    local pending = self.canvas_pending_capture_stop
    if not pending then return true end
    self.canvas_pending_capture_stop = nil
    return self:_deferCanvasCaptureStop(
        pending.canvas, pending.repair_live_stroke)
end

--- A cache or save failure may be reported from inside the stylus callback.
--- Make capture inert now, but leave the callback registered and `drawing`
--- true through the rest of this frame so palm gestures remain suppressed.
--- The visible state changes on the next safe UI tick.
function JustDraw:_deferCanvasCaptureStop(canvas, repair_live_stroke)
    self.canvas_pending_capture_stop = nil
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    if not self.drawing and not self.input_lease then
        local overlay = self.session and self.session:overlay()
        if self.bar then self.bar:update(false) end
        if overlay then UIManager:setDirty(overlay, "ui") end
        return
    end
    local generation = self.drawing_generation or 0
    local lease = self.input_lease
    if not lease then return end
    lease:releaseDeferred(function()
        if self.input_lease == lease then self.input_lease = nil end
        if (self.drawing_generation or 0) ~= generation then return end
        local still_active = self.session and self.session:activeCanvas()
        if not (self.canvas_open and still_active and still_active.id == canvas.id) then
            return
        end
        if repair_live_stroke then
            self:abortCanvasStroke()
        else
            self:endCanvasErase()
            self.canvas_stroke = nil
            self.draw_slot = nil
        end
        self:setDrawing(false)
        local overlay = self.session and self.session:overlay()
        if self.bar then self.bar:update(false) end
        if overlay then UIManager:setDirty(overlay, "ui") end
    end)
end

--- Cache completion is asynchronous for a non-empty sheet. Do not capture pen
--- or touch input until every chunk has validated and reached the raster.
function JustDraw:onCanvasReady(canvas)
    local active = self.session and self.session:activeCanvas()
    local overlay = self.session and self.session:overlay()
    if not (self.canvas_open and active and canvas and overlay
        and active.id == canvas.id) then
        return
    end
    if self.session:isWritable() then
        self:setDrawing(true)
    elseif self.bar then
        self.bar:update(false)
    end
    UIManager:setDirty(overlay, "ui")
end

function JustDraw:onCanvasLoadFailed(canvas)
    local active = self.session and self.session:activeCanvas()
    local overlay = self.session and self.session:overlay()
    if not (self.canvas_open and active and canvas and overlay
        and active.id == canvas.id) then
        return
    end
    self:_deferCanvasCaptureStop(canvas, false)
end

function JustDraw:onCanvasSaveFailed(canvas)
    self:_deferCanvasCaptureStop(canvas, true)
end

function JustDraw:onCanvasSaveRecovered(canvas)
    local active = self.session and self.session:activeCanvas()
    if self.canvas_open and active and canvas and active.id == canvas.id
        and self.session:cache() and self.session:cache():isReady() then
        self:setDrawing(true)
    end
    if self.bar then self.bar:update(true) end
end

function JustDraw:retryCanvasLoad()
    if not (self.session and self.canvas_open) then return nil, "no_canvas" end
    local ok, err = self.session:retryLoad()
    if self.bar then self.bar:update(true) end
    return ok, err
end

--- Open the sheet at the reader's position, or make one there.
function JustDraw:openCanvasHere()
    if not (self.session and self.session:isAvailable()) then return end
    local here = self.session:canvasesHere(self:currentPage())
    if #here == 1 then return self:openCanvas(here[1]) end
    if #here > 1 then return self:showCanvasPicker(here) end
    local canvas, err = self.session:createHere(self:currentPage())
    if not canvas then
        if err ~= "indexing" then
            self:notify(_("Cannot anchor a sheet at this position"))
        end
        return
    end
    return self:openCanvas(canvas)
end

function JustDraw:closeCanvas()
    if not self.canvas_open then return end
    -- Keep the visible sheet, its retry queue and ReaderUI capture intact if
    -- durability refuses the transition. Only dismantle the surface after the
    -- same explicit save gate used by document lifecycle events succeeds.
    local durable, durable_err = self.session:flush()
    if not durable then return nil, durable_err end
    self:abortCanvasStroke()
    self:setDrawing(false)
    local ok, err = self.session:closeCanvas()
    if not ok then return nil, err end
    self.canvas_pending_repaint = nil
    self.canvas_open = false
    self.bar = nil
    if self.bar_restore then self:setBarShown(true) end
    -- The sheet uncovered a page of text; a partial refresh would leave it
    -- ghosted.
    UIManager:setDirty(self.ui, "full")
    return true
end

--[[--
One drawing point, in screen coordinates, while a sheet is open.

Returns whether it inked, which is what the pen route's lift-recovery uses to
tell a stroke that produced nothing from one that was simply off the page.
]]
function JustDraw:applyCanvasPoint(x, y, tool)
    local cache = self.session and self.session:cache()
    if not cache or not cache:isReady() then return false end
    local tr = self.session and self.session:transform()
    if not tr or not tr:contains(x, y) then
        -- Off the page. End the stroke at the edge rather than clamping it
        -- into a line along the margin.
        self:endCanvasStroke()
        return false
    end
    local cx, cy = tr:toCanvas(x, y)
    if tool == Capture.TOOL_ERASER or self.eraser then
        self:eraseCanvasAt(cx, cy, tr)
    else
        self:endCanvasErase()
        if self.canvas_stroke then
            if not self:addCanvasPoint(cx, cy, tr) then return false end
        else
            self:startCanvasStroke(cx, cy, tr)
        end
    end
    return true
end

--- Widths are stored in canvas units, so a stroke keeps its weight relative to
--- the page when the sheet is shown at another size or on another screen.
function JustDraw:startCanvasStroke(cx, cy, tr)
    self.canvas_stroke = {
        n = 1, w = self.pen_width / tr.scale,
        min_x = cx, min_y = cy, max_x = cx, max_y = cy,
        cx, cy,
    }
end

function JustDraw:addCanvasPoint(cx, cy, tr)
    local s = self.canvas_stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == cx and py == cy then return true end
    if s.n >= (self.max_open_points or Limits.MAX_OPEN_POINTS) then
        self.trace_route_reason = "point_budget"
        self:abortCanvasStroke()
        if self.stylus_active then
            self.stylus_suspended = true
        else
            self.draw_slot = SUSPENDED
        end
        self:notifyStrokeBudget()
        return false
    end

    s[i + 1] = cx
    s[i + 2] = cy
    s.n = s.n + 1
    if cx < s.min_x then s.min_x = cx elseif cx > s.max_x then s.max_x = cx end
    if cy < s.min_y then s.min_y = cy elseif cy > s.max_y then s.max_y = cy end

    local cache = self.session:cache()
    if not cache then
        s.live_raster_complete = false
        return true
    end
    local box, raster_cache, raster_generation =
        cache:drawSegment(px, py, cx, cy, s.w)
    updateLiveRasterToken(s, box, raster_cache, raster_generation)
    self:blitCanvasBox(box, tr)
    return true
end

--[[--
Copy one dirty region of the raster onto the screen, and refresh it.

The raster is the source of truth for what the sheet looks like, so live ink
goes into it first and is copied out. That is what lets a repaint mid-stroke --
a notification, a menu closing -- show the stroke so far instead of losing it.
]]
function JustDraw:_queueCanvasRepaint(box, tr, overlay, cache)
    local sx, sy = tr:fromCache(box.x, box.y)
    local pending = self.canvas_pending_repaint
    local active = self.session and self.session:activeCanvas()
    local generation = cache and cache.generation
    if not pending or pending.overlay ~= overlay or pending.cache ~= cache
        or pending.generation ~= generation or pending.transform ~= tr
        or not active or pending.canvas_id ~= active.id then
        pending = {
            overlay = overlay,
            cache = cache,
            generation = generation,
            transform = tr,
            canvas_id = active and active.id,
            cache_left = box.x,
            cache_top = box.y,
            cache_right = box.x + box.w,
            cache_bottom = box.y + box.h,
            screen_left = sx,
            screen_top = sy,
            screen_right = sx + box.w,
            screen_bottom = sy + box.h,
        }
        self.canvas_pending_repaint = pending
        return
    end
    pending.cache_left = math.min(pending.cache_left, box.x)
    pending.cache_top = math.min(pending.cache_top, box.y)
    pending.cache_right = math.max(pending.cache_right, box.x + box.w)
    pending.cache_bottom = math.max(pending.cache_bottom, box.y + box.h)
    pending.screen_left = math.min(pending.screen_left, sx)
    pending.screen_top = math.min(pending.screen_top, sy)
    pending.screen_right = math.max(pending.screen_right, sx + box.w)
    pending.screen_bottom = math.max(pending.screen_bottom, sy + box.h)
end

function JustDraw:_canvasPendingRepaintValid(pending)
    local overlay = self.session and self.session:overlay()
    local active = self.session and self.session:activeCanvas()
    local cache = self.session and self.session:cache()
    return pending and self.canvas_open and overlay == pending.overlay
        and active and active.id == pending.canvas_id
        and cache == pending.cache and cache.generation == pending.generation
        and self.session:transform() == pending.transform
end

--- Flush fallback ink only when the canvas is once again the topmost window.
--- Direct framebuffer writes while a modal is above the overlay would punch
--- through that modal. The pending union is O(1) and bound to the exact
--- canvas/cache/transform generation that produced it.
function JustDraw:_flushCanvasPendingRepaint(already_painted)
    local pending = self.canvas_pending_repaint
    if not pending then return true end
    if not self:_canvasPendingRepaintValid(pending) then
        self.canvas_pending_repaint = nil
        return nil, "stale_repaint"
    end
    if Stack.visualAbove(pending.overlay) then return nil, "covered" end
    self.canvas_pending_repaint = nil
    local x, y = pending.screen_left, pending.screen_top
    local w = pending.screen_right - x
    local h = pending.screen_bottom - y
    if not already_painted then
        local bb = pending.cache:buffer()
        if not bb then return nil, "no_buffer" end
        Screen.bb:blitFrom(bb, x, y, pending.cache_left, pending.cache_top, w, h)
        pending.overlay:restoreChromeIfIntersecting(Screen.bb,
            { x = x, y = y, w = w, h = h }, 0, 0)
    end
    if w > 0 and h > 0 then
        if already_painted then
            UIManager:setDirty(nil, "partial",
                Geom:new{ x = x, y = y, w = w, h = h })
        else
            self:refreshBox(x, y, x + w, y + h)
        end
    end
    return true
end

--- Called after the overlay has copied the current cache into Screen.bb.
--- Closing any KOReader modal repaints the exposed overlay; use that natural
--- lifecycle boundary to request the deferred regional refresh once.
function JustDraw:onCanvasOverlayPainted(overlay)
    local pending = self.canvas_pending_repaint
    if pending and pending.overlay == overlay then
        self:_flushCanvasPendingRepaint(true)
    end
end

function JustDraw:blitCanvasBox(box, tr)
    if not box or box.w <= 0 or box.h <= 0 then return end
    local cache = self.session and self.session:cache()
    local bb = cache and cache:buffer()
    if not bb then return end
    local overlay = self.session and self.session:overlay()
    if overlay and Stack.visualAbove(overlay) then
        self:_queueCanvasRepaint(box, tr, overlay, cache)
        return nil, "covered"
    end
    self:_flushCanvasPendingRepaint(false)
    local sx, sy = tr:fromCache(box.x, box.y)
    Screen.bb:blitFrom(bb, sx, sy, box.x, box.y, box.w, box.h)
    if overlay then
        overlay:restoreChromeIfIntersecting(Screen.bb,
            { x = sx, y = sy, w = box.w, h = box.h }, 0, 0)
    end
    self:refreshBox(sx, sy, sx + box.w, sy + box.h)
end

function JustDraw:endCanvasStroke()
    self:endCanvasErase()
    local s = self.canvas_stroke
    self.canvas_stroke = nil
    if not s or not self.session then return end

    local tr = self.session:transform()
    if s.n == 1 and tr then
        -- A dot is never painted live, because there is no segment to paint.
        local cache = self.session:cache()
        if cache then
            local box, raster_cache, raster_generation =
                cache:drawSegment(s[1], s[2], s[1], s[2], s.w)
            updateLiveRasterToken(s, box, raster_cache, raster_generation)
            self:blitCanvasBox(box, tr)
        end
    end

    local ok, err, painted, left, top, right, bottom =
        self.session:addStroke(s, s.n, s.w, Capture.TOOL_PEN, {
            raster_cache = s.raster_cache,
            raster_generation = s.raster_generation,
            live_raster_complete = s.live_raster_complete == true,
        })
    if not ok then
        logger.warn("JustDraw: canvas stroke not recorded:", err)
        -- Live segments were painted before the queue accepted the stroke.
        -- If acceptance failed, remove them now rather than showing ink that
        -- will disappear on reopen.
        local box = self.session:repair(
            s.min_x, s.min_y, s.max_x, s.max_y, s.w)
        if box and tr then self:blitCanvasBox(box, tr) end
        if err == "queue_backpressure" and not self.canvas_backpressure_notified then
            self.canvas_backpressure_notified = true
            self:notifyCanvasBackpressure()
        elseif err == "operation_too_large" then
            self:notifyStrokeBudget()
            self:_requestCanvasCaptureStop(
                self.session and self.session:activeCanvas(), false)
        end
        return nil, err
    end
    self.canvas_backpressure_notified = false
    if painted and tr then
        self:blitCanvasBox({
            x = left, y = top, w = right - left, h = bottom - top,
        }, tr)
    end
    return true
end

--[[--
Give up the stroke in progress.

Its segments are already in the raster, so the region has to be rebuilt from
what was underneath. Repainting the overlay alone would leave ink on screen
that is in no canvas.
]]
function JustDraw:abortCanvasStroke()
    self:endCanvasErase()
    local s = self.canvas_stroke
    self.canvas_stroke = nil
    if not s or not self.session then return end
    local box = self.session:repair(s.min_x, s.min_y, s.max_x, s.max_y, s.w)
    local tr = self.session:transform()
    if box and tr then self:blitCanvasBox(box, tr) end
end

function JustDraw:eraseCanvasAt(cx, cy, tr)
    -- The eraser is a fixed size under the reader's hand, so its reach in
    -- canvas units grows as the sheet shrinks.
    local radius = ERASER_RADIUS / tr.scale
    if not self.canvas_erase_ctx then
        self.canvas_erase_ctx = self.session:beginErase()
    end
    local lx, ly = self.canvas_erase_x, self.canvas_erase_y
    local threshold = radius / 3
    if threshold < 1 then threshold = 1 end
    if lx then
        local dx, dy = cx - lx, cy - ly
        if dx * dx + dy * dy < threshold * threshold then return end
    end
    self.canvas_erase_x, self.canvas_erase_y = cx, cy
    local box = self.session:eraseAt(cx, cy, radius, self.canvas_erase_ctx)
    self:blitCanvasBox(box, tr)
end

function JustDraw:endCanvasErase()
    if self.canvas_erase_ctx and self.session then
        self.session:endErase(self.canvas_erase_ctx)
    end
    self.canvas_erase_ctx = nil
    self.canvas_erase_x, self.canvas_erase_y = nil, nil
end

-- ------------------------------------------------------------------ output

function JustDraw:paintTo(bb, x, y)
    self:paintMarks(bb)

    local list = self.store:get(self:currentPage())
    if not list then return end
    for i = 1, #list do
        Render.stroke(bb, list[i], 0, 0, INK)
    end
end

--[[--
A flag in the margin for every sheet anchored on this view.

Reads a table the session filled when the page turned. No query, no CREngine
call and no xpointer resolution happens here, which is what keeps turning a
page in a heavily annotated book the same cost as turning one in a plain book.

Drawn on the edge opposite the toolbar so the two never overlap.
]]
function JustDraw:paintMarks(bb)
    if not self.session then return end
    local marks = self.session:marks()
    if #marks == 0 then return end

    local x = (self.bar_side == "left") and (Screen:getWidth() - MARK_W) or 0
    local limit = Screen:getHeight() - MARK_H
    for i = 1, #marks do
        local y = marks[i].y - math.floor(MARK_H / 2)
        if y < 0 then y = 0 elseif y > limit then y = limit end
        bb:paintRect(x, y, MARK_W, MARK_H, INK)
    end
end

function JustDraw:repaint()
    UIManager:setDirty(self.ui, "ui")
end

--- Refresh the half-open coverage returned by InkRender, clamped to screen.
function JustDraw:refreshBox(left, top, right, bottom)
    left, top, right, bottom = tonumber(left), tonumber(top),
        tonumber(right), tonumber(bottom)
    if not left or not top or not right or not bottom
        or left ~= left or top ~= top or right ~= right or bottom ~= bottom
        or left == math.huge or top == math.huge
        or right == math.huge or bottom == math.huge
        or left == -math.huge or top == -math.huge
        or right == -math.huge or bottom == -math.huge then
        return
    end
    local x, y = math.floor(left), math.floor(top)
    local edge_x, edge_y = math.ceil(right), math.ceil(bottom)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if edge_x > sw then edge_x = sw end
    if edge_y > sh then edge_y = sh end
    local w, h = edge_x - x, edge_y - y
    if w <= 0 or h <= 0 then return end

    if self.live_fast then
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshPartial(x, y, w, h)
    end
end

-- -------------------------------------------------------------------- menu

function JustDraw:onJustDrawUndo()
    if self.canvas_open then
        local box, err = self.session:undo()
        if not box then
            if err == "read_only" then self:notify(_("This sheet is read-only"))
            elseif err == "loading" or err == "load_failed" then
                self:notify(_("This sheet's ink is still loading"))
            else self:notify(_("Nothing to undo on this sheet")) end
            return true
        end
        local tr = self.session:transform()
        if type(box) == "table" and tr then
            self:blitCanvasBox(box, tr)
        else
            UIManager:setDirty(self.session:overlay(), "ui")
        end
        return true
    end

    local page = self:currentPage()
    if not self.store:pop(page) then
        self:notify(_("Nothing to undo on this page"))
        return true
    end
    self:repaint()
    return true
end

function JustDraw:setPenWidth(w)
    self.pen_width = w
    Compat.saveSetting(G_reader_settings, "pen_width", w)
end

function JustDraw:penItem(text, w)
    return {
        text = text,
        checked_func = function() return self.pen_width == w end,
        radio = true,
        callback = function() self:setPenWidth(w) end,
    }
end

function JustDraw:sideItem(text, side)
    return {
        text = text,
        checked_func = function() return self.bar_side == side end,
        radio = true,
        callback = function()
            if self.bar_side == side then return end
            self.bar_side = side
            Compat.saveSetting(G_reader_settings, "bar_side", side)
            local overlay = self.session and self.session:overlay()
            if overlay then
                overlay:setBarSide(side)
                self.bar = overlay.bar
            else
                self:rebuildBar()
            end
        end,
    }
end

--- Radio item for the input mode. Locked while drawing, because swapping
--- backends mid-sequence would tear down capture inside a live contact.
function JustDraw:inputModeItem(text, value)
    return {
        text = text,
        checked_func = function() return self.input_mode == value end,
        radio = true,
        enabled_func = function() return not self.drawing end,
        callback = function() self:setInputMode(value) end,
    }
end

--[[--
Ask which sheet, when the reader's position has more than one.

Opening the first one silently is the failure worth avoiding: the reader would
write into a sheet they cannot see the identity of, and find their earlier
notes in the other one later.
]]
function JustDraw:showCanvasPicker(list)
    local buttons = {}
    for i = 1, #list do
        local canvas = list[i]
        buttons[i] = { {
            text = string.format(_("Sheet %d"), i),
            callback = function()
                if self.canvas_picker then
                    UIManager:close(self.canvas_picker)
                    self.canvas_picker = nil
                end
                self:openCanvas(canvas)
            end,
        } }
    end
    self.canvas_picker = ButtonDialog:new{
        title = _("Sheets at this position"),
        buttons = buttons,
    }
    UIManager:show(self.canvas_picker)
end

function JustDraw:confirmDeleteCanvas(canvas)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this sheet and everything drawn on it?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteCanvas(canvas)
        end,
    })
end

--- Delete through the plugin so its visible state changes together with the
--- session. Session deliberately knows nothing about JustDraw's toolbar and
--- capture flags.
function JustDraw:deleteCanvas(canvas)
    if not (self.session and canvas) then return nil, "no_canvas" end
    local active = self.canvas_open and self.session:activeCanvas()
        and self.session:activeCanvas().id == canvas.id
    if active then
        self:abortCanvasStroke()
        self:setDrawing(false)
    end

    local ok, err = self.session:deleteCanvas(canvas)
    if not ok then
        self:notify(_("Could not delete this sheet"))
        return nil, err
    end

    if active then
        self.canvas_pending_repaint = nil
        self.canvas_open = false
        self.bar = nil
        if self.router then self.router:reset() end
        if self.bar_restore then self:setBarShown(true) end
    end
    UIManager:setDirty(self.ui, "full")
    return true
end

--[[--
The sheet menu, rebuilt every time it is opened.

Deliberately built on demand rather than kept as a static table: what it can
offer depends on where the reader is, whether a sheet is open, and whether the
page index has finished -- and a stale menu that offers to create a second
sheet on a paragraph that already has one is the failure this feature can least
afford.
]]
function JustDraw:canvasMenu()
    local items = {}
    if not (self.session and self.session:isAvailable()) then return items end

    if self.canvas_open then
        local active = self.session:activeCanvas()
        items[#items + 1] = {
            text = _("Close sheet"),
            callback = function() self:closeCanvas() end,
        }
        items[#items + 1] = {
            text = _("Delete this sheet"),
            enabled_func = function() return self.session:isWritable() end,
            keep_menu_open = true,
            separator = true,
            callback = function() self:confirmDeleteCanvas(active) end,
        }
    else
        items[#items + 1] = {
            -- Closes the menu on purpose: opening a sheet turns drawing on,
            -- and an open menu is unusable once the pen is inking.
            text = _("Open sheet here"),
            enabled_func = function()
                if self.session:isIndexing() then return false end
                return self.session:isWritable()
                    or #self.session:canvasesHere(self:currentPage()) > 0
            end,
            callback = function() self:openCanvasHere() end,
            help_text = _([[Creates a blank sheet anchored to this position in the book, or opens the one that is already here. The sheet keeps its own coordinates, so changing font or margins moves the sheet, not what you drew on it.]]),
        }
    end

    if self.session:saveFailed() then
        -- Editing is refused until this succeeds, so it has to be the first
        -- thing here and it has to say what state the ink is in.
        items[#items + 1] = {
            text = _("Retry saving ink"),
            keep_menu_open = true,
            separator = true,
            help_text = _([[A write to the sheet database failed. Nothing has been lost -- the strokes are still in memory -- but they are not durable until this succeeds, and no more can be drawn until it does.]]),
            callback = function() self.session:retrySave() end,
        }
    end

    if self.session:loadFailed() then
        items[#items + 1] = {
            text = _("Retry loading sheet"),
            keep_menu_open = true,
            separator = true,
            callback = function() self:retryCanvasLoad() end,
        }
    end

    local here = self.session:canvasesHere(self:currentPage())
    if #here > 1 then
        local sub = {}
        for i = 1, #here do
            local canvas = here[i]
            sub[i] = {
                text = string.format(_("Sheet %d"), i),
                callback = function() self:openCanvas(canvas) end,
            }
        end
        items[#items + 1] = {
            text = _("Sheets on this page"),
            separator = true,
            sub_item_table = sub,
        }
    end

    local orphans = self.session:orphans()
    if #orphans > 0 then
        local sub = {}
        for i = 1, #orphans do
            local canvas = orphans[i]
            sub[i] = {
                text = string.format(_("Lost sheet %d"), i),
                sub_item_table = {
                    {
                        text = _("Open it anyway"),
                        callback = function() self:openCanvas(canvas) end,
                    },
                    {
                        text = _("Delete it"),
                        enabled_func = function() return self.session:isWritable() end,
                        keep_menu_open = true,
                        callback = function() self:confirmDeleteCanvas(canvas) end,
                    },
                },
            }
        end
        items[#items + 1] = {
            -- Anchors that no longer resolve are kept, never deleted for the
            -- reader: the text may come back. But a sheet nothing can reach is
            -- no use either, so there is a way in.
            text = string.format(_("Lost sheets (%d)"), #orphans),
            help_text = _([[Sheets whose place in the book can no longer be found -- usually because the file was replaced with a different edition. Nothing drawn on them has been lost.]]),
            sub_item_table = sub,
        }
    end

    return items
end

function JustDraw:addToMainMenu(menu_items)
    if self.is_docless then
        menu_items.justdraw_notebooks = {
            text = _("Notebooks"),
            sorting_hint = "more_tools",
            callback = function() self:openNotebookLibrary() end,
        }
        return
    end
    menu_items.justdraw = {
        text = _("JustDraw"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Notebooks"),
                callback = function() self:openNotebookLibrary() end,
            },
            {
                -- Deliberately closes the menu: turning drawing on swallows
                -- single-finger taps, so an open menu would be unusable.
                text = _("Start drawing"),
                enabled_func = function() return not self.drawing end,
                callback = function() self:setDrawing(true) end,
                help_text = _([[Use the Draw/Stop button on the side toolbar to switch drawing off again. Two fingers also work as usual while drawing is on.]]),
            },
            {
                text = _("Show toolbar"),
                checked_func = function() return self.bar ~= nil end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:setBarShown(self.bar == nil)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Toolbar side"),
                separator = true,
                sub_item_table = {
                    self:sideItem(_("Left"), "left"),
                    self:sideItem(_("Right"), "right"),
                },
            },
            {
                text = _("Input mode"),
                separator = true,
                help_text = _([[Automatic uses the stylus route on devices that report a pen digitizer, and the finger route everywhere else. On a drawing sheet, finger and palm never draw; touches above the bounded sheet can still turn pages. With direct ink, press Stop to return all touch input to reading.]]),
                sub_item_table = {
                    self:inputModeItem(_("Automatic"), "auto"),
                    self:inputModeItem(_("Stylus"), "stylus"),
                    self:inputModeItem(_("Finger"), "finger"),
                },
            },
            {
                text = _("Pen width"),
                sub_item_table = {
                    self:penItem(_("Thin"), PEN_THIN),
                    self:penItem(_("Medium"), PEN_MEDIUM),
                    self:penItem(_("Thick"), PEN_THICK),
                },
            },
            {
                text = _("Fast refresh while drawing"),
                checked_func = function() return self.live_fast end,
                callback = function()
                    self.live_fast = not self.live_fast
                    Compat.saveSetting(G_reader_settings, "live_fast", self.live_fast)
                end,
                help_text = _([[On: strokes appear with the DU waveform — quick, but grainy and it leaves ghosting until the next page turn. Off: slower, cleaner.]]),
                separator = true,
            },
            {
                -- Deliberately not gated on the stylus backend being live: the
                -- only person who opens this is someone whose pen does nothing,
                -- and for them it never is.
                text = _("Stylus diagnostics"),
                callback = function() self:showDiagnostics() end,
                help_text = _([[Shows why the pen route is or is not running. With confirmation, it writes pen coordinates and decisions to the local log for up to one minute or 8,192 events. No book or notebook identity is logged.]]),
                separator = true,
            },
            {
                text = _("Drawing sheet"),
                separator = true,
                enabled_func = function()
                    return self.session ~= nil and self.session:isAvailable()
                end,
                help_text = _([[Blank sheets anchored to a position in a reflowable book. Not available in PDFs and other fixed layouts, where drawing goes straight onto the page instead.]]),
                sub_item_table_func = function() return self:canvasMenu() end,
            },
            {
                text = _("Clear this page"),
                keep_menu_open = true,
                callback = function()
                    if self.store:clearPage(self:currentPage()) then
                        self:repaint()
                    else
                        self:notify(_("No ink on this page"))
                    end
                end,
            },
            {
                text = _("Clear whole document"),
                keep_menu_open = true,
                callback = function()
                    if self.store:countPages() == 0 then
                        self:notify(_("No ink in this document"))
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all ink in this document?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:clearWholeDocumentInk()
                        end,
                    })
                end,
            },
        },
    }
end

-- Compatibility event handlers for Gesture Manager assignments created by
-- FingerInk. The registered action IDs above intentionally keep emitting the
-- old event names, while all current code calls the JustDraw handlers.
JustDraw.onFingerInkBar = JustDraw.onJustDrawBar
JustDraw.onFingerInkToggle = JustDraw.onJustDrawToggle
JustDraw.onFingerInkEraser = JustDraw.onJustDrawEraser
JustDraw.onFingerInkUndo = JustDraw.onJustDrawUndo

return JustDraw
