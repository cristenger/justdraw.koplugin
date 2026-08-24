--[[--
Finger Ink — draw on book pages with a finger.

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
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Version = require("version")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local CanvasSession = require("ink_canvas_session")
local Capture = require("ink_capture")
local InkBar = require("ink_bar")
local Render = require("ink_render")
local Router = require("ink_contact_router")
local Stack = require("ink_stack")
local Store = require("ink_store")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SETTING_KEY = "fingerink_strokes"
local MODE_KEY = "fingerink_input_mode"
local SUSPENDED = -1   -- draw_slot sentinel: ignore this contact until it lifts

local INPUT_MODES = { auto = true, stylus = true, finger = true }

-- The margin flag that says "there is a sheet anchored here". Drawn on the
-- edge opposite the toolbar, so the two never overlap.
local MARK_W, MARK_H = 6, 28

-- Bounded twice on purpose. The only thing worse than no data from a hardware
-- session is a log that filled the device and got truncated at the interesting
-- part.
local DIAG_SECONDS = 60
local DIAG_MAX_LINES = 500

-- Reasons Capture can refuse, mapped to something a user can act on.
local INPUT_ERRORS = {
    no_stylus_api = _("Stylus input requires KOReader v2026.07 or newer"),
    stylus_callback_busy = _("Another plugin is already using stylus input"),
    no_gesture_detector = _("Finger Ink: cannot hook touch input"),
    -- Not a refusal: drawing still starts, on the finger route. It is the
    -- answer to "my pen does nothing", given before the user has to ask.
    pen_unavailable = _("Pen input needs KOReader v2026.07 or newer. Drawing with finger."),
    no_input = _("Finger Ink: cannot hook touch input"),
    already_installed = _("Finger Ink: input is already captured"),
    handler_error = _("Finger Ink: drawing stopped after an input error"),
}

local FingerInk = WidgetContainer:extend{
    name = "fingerink",
    is_doc_only = true,
}

-- ---------------------------------------------------------------- lifecycle

function FingerInk:init()
    self.drawing = false
    self.eraser = false
    self.bar = nil
    self.pen_width = G_reader_settings:readSetting("fingerink_pen_width") or PEN_MEDIUM
    self.live_fast = G_reader_settings:readSetting("fingerink_live_fast") ~= false
    self.bar_side = G_reader_settings:readSetting("fingerink_bar_side") or "right"

    local mode = G_reader_settings:readSetting(MODE_KEY)
    self.input_mode = INPUT_MODES[mode] and mode or "auto"
    self.input_backend = nil

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

    self.diag_until = nil
    self.diag_lines = 0
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
    --- Left nil in production, where the session opens its own connection.
    --- The suite runs under a bare interpreter that cannot load the SQLite
    --- driver at all, so it hands one in.
    self.canvas_repository = nil

    self.store = Store.new(self.ui.doc_settings:readSetting(SETTING_KEY))

    self:registerDispatcher()
    self.ui.menu:registerToMainMenu(self)
    self.view:registerViewModule("fingerink", self)

    if G_reader_settings:readSetting("fingerink_bar_shown") ~= false then
        UIManager:nextTick(function() self:setBarShown(true) end)
    end
end

function FingerInk:registerDispatcher()
    Dispatcher:registerAction("fingerink_toggle", {
        category = "none", event = "FingerInkToggle", reader = true,
        title = _("Finger Ink: toggle drawing"),
    })
    Dispatcher:registerAction("fingerink_eraser", {
        category = "none", event = "FingerInkEraser", reader = true,
        title = _("Finger Ink: toggle eraser"),
    })
    Dispatcher:registerAction("fingerink_undo", {
        category = "none", event = "FingerInkUndo", reader = true,
        title = _("Finger Ink: undo stroke"),
    })
    Dispatcher:registerAction("fingerink_bar", {
        category = "none", event = "FingerInkBar", reader = true,
        title = _("Finger Ink: toggle toolbar"),
    })
end

--[[--
Start the canvas session, once the document is ready.

Not in `init`: half the book's identity is `partial_md5_checksum`, which
ReaderUI computes on its way to emitting this event. Only reflowable documents
get one -- a canvas anchored by xpointer means nothing in a fixed layout, and
`anchor_kind = 'page'` is reserved for when it does.
]]
function FingerInk:onReaderReady(config)
    if self.session or not self.ui.rolling or not self.ui.document then return end

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
function FingerInk:documentSize()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not self.ui.document or not self.ui.document.file then return nil end
    return lfs.attributes(self.ui.document.file, "size")
end

function FingerInk:onCloseDocument()
    self:teardown()
end

function FingerInk:onCloseWidget()
    self:teardown()
end

function FingerInk:onSuspend()
    self:setDrawing(false)
end

--[[--
Every exit path lands here. It has to do exactly what stopping does, including
dropping the stroke in flight: an unfinished stroke is not in the store yet, so
leaving it dangling loses it silently and leaks contact state into whatever
document is opened next in the same session.
]]
function FingerInk:teardown()
    -- Before the session goes: abortStroke reaches the sheet's stroke through
    -- it, and an unfinished stroke is not in any store yet.
    self:abortStroke()
    if self.session then
        self.session:close{ force = true }
        self.session = nil
        self.router = nil
        self.canvas_open = false
    end
    Capture:remove()
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
function FingerInk:onSaveSettings()
    if self.session then
        local saved, save_err = self.session:flush()
        if not saved then
            -- Queue already retained the operations and emitted the reader's
            -- deduplicated notification; this log makes the lifecycle gate's
            -- failed return explicit without claiming settings were durable.
            logger.warn("FingerInk: SaveSettings canvas flush failed:", save_err)
        end
    end
    if self.store:isEmpty() then
        self.ui.doc_settings:delSetting(SETTING_KEY)
    else
        self.ui.doc_settings:saveSetting(SETTING_KEY, self.store.pages)
    end
end

--- Rotation and resize invalidate the bar's fixed position; rebuild it.
function FingerInk:rebuildBar()
    if not self.bar then return end
    UIManager:close(self.bar)
    self.bar = nil
    UIManager:nextTick(function() self:setBarShown(true) end)
end

function FingerInk:onScreenResize()
    local overlay = self.session and self.session:overlay()
    if overlay then
        overlay:onScreenResize()
        self.bar = overlay.bar
    else
        self:rebuildBar()
    end
end

function FingerInk:onSetRotationMode()
    self:onScreenResize()
end

-- ----------------------------------------------------------- canvas events

--- A page turn. Only the marks are recomputed; the index answers from memory.
function FingerInk:onPageUpdate(page)
    if self.session then self.session:setPage(page or self:currentPage()) end
end

--[[--
`PosUpdate` carries `(pos, pageno)` -- the scroll position first
(readerrolling.lua:1089 @ v2026.07). Aliasing it to `onPageUpdate` would hand a
byte offset to something that looks up canvases by page number, and every mark
in scroll mode would land on the wrong page or on none.
]]
function FingerInk:onPosUpdate(_, page)
    self:onPageUpdate(page)
end

--- Font, margin or line-height change. The page index is rebuilt; not one
--- stroke is read, written or moved.
function FingerInk:onDocumentRerendered()
    if self.session then self.session:invalidate() end
end

--- The asynchronous page index has caught up with the current layout. Session
--- already recomputed `marks_here`; repaint so the first visible page does not
--- wait for an unrelated PageUpdate before showing its sheet markers.
function FingerInk:onCanvasIndexReady()
    if self.session then UIManager:setDirty(self.ui, "ui") end
end

-- ----------------------------------------------------------------- toolbar

function FingerInk:setBarShown(on)
    on = on and true or false
    -- With a sheet open the toolbar is the overlay's child, not a window of
    -- ours. "Hide" then means put the sheet away -- the invariant is still
    -- that drawing is never on without a way to turn it off.
    if self.canvas_open then
        if not on then self:closeCanvas() end
        return
    end
    G_reader_settings:saveSetting("fingerink_bar_shown", on)

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

function FingerInk:onFingerInkBar()
    self:setBarShown(self.bar == nil)
    return true
end

function FingerInk:inBar(x, y)
    return self.bar ~= nil and self.bar:contains(x, y)
end

--[[--
True while a menu or dialog is open over the reader.

Drawing mode eats single-finger touches before UIManager ever sees them, which
would otherwise make an open menu impossible to dismiss — tapping outside it is
the only way to close one. So drawing yields for as long as one is up.
]]
--- Whichever FingerInk window is currently the topmost: the canvas overlay
--- when a sheet is open, the standalone toolbar otherwise.
function FingerInk:topWindow()
    local overlay = self.session and self.session:overlay()
    if overlay then return overlay end
    return self.bar
end

function FingerInk:dialogOnTop()
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
function FingerInk:regionAt(x, y)
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

function FingerInk:notify(text)
    UIManager:show(Notification:new{ text = text })
end

function FingerInk:currentPage()
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
function FingerInk:resolveInputBackend()
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

function FingerInk:reportInputFailure(reason)
    logger.warn("FingerInk: cannot start drawing:", reason)
    self:notify(INPUT_ERRORS[reason] or INPUT_ERRORS.no_gesture_detector)
end

--[[--
Emergency stop after an input handler raised. Capture has already unhooked
itself by the time this runs; this is the plugin-side half. Guarded so a second
call — Capture disarming and the handler disarming again — stays silent.
]]
function FingerInk:disarmInput(err)
    if not self.drawing and self.input_backend == nil then return end
    logger.err("FingerInk: disarming input capture after a handler error:", err)
    self.drawing = false
    self.input_backend = nil
    Capture:remove()
    self:abortStroke()
    self:resetContacts()
    self:resetStylusState()
    self:notify(INPUT_ERRORS.handler_error)
    if self.bar then self.bar:update(true) end
end

function FingerInk:setDrawing(on)
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

    self.drawing_generation = (self.drawing_generation or 0) + 1

    if on then
        -- Resolve before touching the toolbar: a refusal must not leave the
        -- bar forced on and the preference rewritten.
        local backend, reason = self:resolveInputBackend()
        if not backend then
            return self:reportInputFailure(reason)
        end
        if not self.bar then self:setBarShown(true) end

        local ok
        if backend == "stylus" then
            ok, reason = Capture:installStylus(
                function(slot) return self:onStylusEvent(slot) end,
                function(slots) return self:onStylusTouchFrame(slots) end,
                function(err) self:disarmInput(err) end)
        else
            ok, reason = Capture:installFinger(
                function(slots) return self:onTouchFrame(slots) end,
                function(err) self:disarmInput(err) end)
        end
        -- Drawing only goes on after a complete install, never before.
        if not ok then
            return self:reportInputFailure(reason)
        end

        self.input_backend = backend
        self.drawing = true
        if self.router then self.router:setBackend(backend) end
        logger.info("FingerInk: drawing on, mode", self.input_mode, "backend", backend)
        self:notePenUnavailable(backend)
    else
        self:abortStroke()
        Capture:remove()
        self:resetContacts()
        self:resetStylusState()
        self.input_backend = nil
        self.drawing = false
        logger.info("FingerInk: drawing off")
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
function FingerInk:notePenUnavailable(backend)
    if backend ~= "finger" or self.pen_notice_shown then return end
    if self.input_mode ~= "auto" then return end
    if Device.input == nil or Device.input.wacom_protocol ~= true then return end
    self.pen_notice_shown = true
    logger.warn("FingerInk: device reports a pen digitizer but this runtime has no stylus API")
    self:notify(INPUT_ERRORS.pen_unavailable)
end

function FingerInk:setInputMode(mode)
    if not INPUT_MODES[mode] or mode == self.input_mode then return end
    -- The menu item is disabled while drawing, but the guard belongs here:
    -- swapping backends inside a live contact sequence tears down capture
    -- mid-stroke, and the menu is not the only possible caller.
    if self.drawing then
        logger.warn("FingerInk: refusing to change input mode while drawing")
        return
    end
    self.input_mode = mode
    G_reader_settings:saveSetting(MODE_KEY, mode)
    logger.info("FingerInk: input mode set to", mode)
end

function FingerInk:setEraser(on)
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

function FingerInk:resetContacts()
    for slot in pairs(self.contacts) do
        self.contacts[slot] = nil
    end
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
end

--- Per-sequence pen state. `stylus_lift_x/y` deliberately survives, because it
--- is how the next contact-down detects stale coordinates.
function FingerInk:resetStylusState()
    self.stylus_active = false
    self.stylus_passthrough = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_stale_xy = false
    self.stylus_inked = false
    self.stylus_tool = nil
end

function FingerInk:onFingerInkToggle()
    self:setDrawing(not self.drawing)
    return true
end

function FingerInk:onFingerInkEraser()
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
function FingerInk:onTouchFrame(slots)
    if self.canvas_open then return self:routeCanvasFinger(slots) end

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
function FingerInk:onContactPoint(slot, raw_x, raw_y, tool)
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
function FingerInk:applyPoint(x, y, tool)
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
function FingerInk:onStylusEvent(slot)
    local id, x, y, tool = slot.id, slot.x, slot.y, slot.tool
    if self.diag_until then self:diag(slot, x, y) end

    -- Hover before this slot ever carried a tracking id. Consume, change nothing.
    if id == nil then return true end

    if id >= 0 then
        if not self.stylus_active then
            self.stylus_active = true
            -- The pen is on the page from this frame, even though where is
            -- not known yet. A finger arriving in that window is no less of a
            -- palm for being one frame early.
            if self.router and self.canvas_open then self.router:penContact(nil, nil) end
            self.stylus_passthrough = self:dialogOnTop()
            self.stylus_geom_latched = self.stylus_passthrough
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

--[[--
Whether a pen contact starting here belongs to somebody else.

With no sheet open that is the toolbar and nothing else, exactly as before.
With one open the resize handle joins it: dragging the sheet with the pen has
to work, and a stroke is not what the reader meant there.
]]
function FingerInk:penPassesThrough(x, y)
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
function FingerInk:diagnosticReport()
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
function FingerInk:diagnosticLines()
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

--- Put the report on screen. On a device the log is not always reachable, and
--- this is the answer to a question the user is asking right now.
function FingerInk:showDiagnostics()
    local lines = self:startDiagnostics()
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--[[--
One bounded diagnostic session, for reporting hardware problems.

Digitizer numbers only: slot, tracking id, tool, the screen position, and
whether this frame's raw coordinates repeated the previous lift. No paths, no
titles, nothing from the book. See the plan's stopping conditions.
]]
function FingerInk:startDiagnostics()
    local lines = self:diagnosticLines()
    for i = 1, #lines do
        if lines[i] ~= "" then logger.info("FI-DIAG", lines[i]) end
    end

    self.diag_until = os.time() + DIAG_SECONDS
    self.diag_lines = 0
    logger.info("FI-DIAG start, per-event log armed")
    return lines
end

function FingerInk:diag(slot, sx, sy)
    if not self.diag_until then return end
    if self.diag_lines >= DIAG_MAX_LINES or os.time() > self.diag_until then
        logger.info("FI-DIAG end", self.diag_lines, "lines")
        self.diag_until = nil
        return
    end
    self.diag_lines = self.diag_lines + 1
    logger.info("FI-DIAG", slot.slot, slot.id, tostring(slot.tool),
        sx, sy, tostring(self.stylus_stale_xy))
end

--[[--
One drawing point from the pen. Starting on the toolbar is already settled by
the latch, so the only case left is a stroke dragged *onto* the bar, which ends
at the edge rather than scribbling over the buttons.
]]
function FingerInk:onStylusPoint(x, y, tool)
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
function FingerInk:onStylusTouchFrame(slots)
    if self.canvas_open then return self:routeCanvasTouch(slots) end

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
function FingerInk:routeCanvasTouch(slots)
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
function FingerInk:routeCanvasFinger(slots)
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

function FingerInk:startStroke(x, y)
    self.stroke = { n = 1, w = self.pen_width, x, y }
end

function FingerInk:addPoint(x, y)
    local s = self.stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == x and py == y then return end

    s[i + 1] = x
    s[i + 2] = y
    s.n = s.n + 1

    Render.segment(Screen.bb, px, py, x, y, s.w, INK)
    self:refreshBox(px, py, x, y, s.w)
end

--- Ends whichever stroke is in progress. Every caller -- the pen lift, a
--- dialog opening mid-stroke, Stop -- means "finish what is being drawn", and
--- what that is depends on whether a sheet is open.
function FingerInk:endStroke()
    if self.canvas_open then return self:endCanvasStroke() end

    local s = self.stroke
    self.stroke = nil
    self.draw_slot = nil
    if not s then return end

    if s.n == 1 then -- a dot: never painted live, paint it now
        Render.stroke(Screen.bb, s, 0, 0, INK)
        self:refreshBox(s[1], s[2], s[1], s[2], s.w)
    end
    self.store:add(self:currentPage(), s)
end

--- Gives up whichever stroke is in progress. See endStroke.
function FingerInk:abortStroke()
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

function FingerInk:eraseAt(x, y)
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

There is never more than one FingerInk window: the standalone toolbar steps
down and the overlay's embedded one takes its place, so `self.bar` keeps
meaning "the toolbar the reader can see" everywhere else in this file.
]]
function FingerInk:openCanvas(canvas)
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
function FingerInk:onCanvasOverlayBarChanged(overlay)
    local current = self.session and self.session:overlay()
    if self.canvas_open and (current == nil or current == overlay) then
        self.bar = overlay.bar
    end
end

--- A rotation changes raster scale. This hook runs before Cache releases the
--- ready buffer, which is the last safe moment to abandon and repair a live
--- stroke. Rotation events are outside the stylus callback stack, so immediate
--- unregistration is safe here.
function FingerInk:onCanvasCacheWillRebuild(canvas)
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    self:abortCanvasStroke()
    self:setDrawing(false)
end

--- A cache or save failure may be reported from inside the stylus callback.
--- Make capture inert now, but leave the callback registered and `drawing`
--- true through the rest of this frame so palm gestures remain suppressed.
--- The visible state changes on the next safe UI tick.
function FingerInk:_deferCanvasCaptureStop(canvas, repair_live_stroke)
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    if not self.drawing and not Capture.active then
        local overlay = self.session and self.session:overlay()
        if self.bar then self.bar:update(false) end
        if overlay then UIManager:setDirty(overlay, "ui") end
        return
    end
    local generation = self.drawing_generation or 0
    Capture:removeDeferred(function()
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
function FingerInk:onCanvasReady(canvas)
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

function FingerInk:onCanvasLoadFailed(canvas)
    local active = self.session and self.session:activeCanvas()
    local overlay = self.session and self.session:overlay()
    if not (self.canvas_open and active and canvas and overlay
        and active.id == canvas.id) then
        return
    end
    self:_deferCanvasCaptureStop(canvas, false)
end

function FingerInk:onCanvasSaveFailed(canvas)
    self:_deferCanvasCaptureStop(canvas, true)
end

function FingerInk:onCanvasSaveRecovered(canvas)
    local active = self.session and self.session:activeCanvas()
    if self.canvas_open and active and canvas and active.id == canvas.id
        and self.session:cache() and self.session:cache():isReady() then
        self:setDrawing(true)
    end
    if self.bar then self.bar:update(true) end
end

function FingerInk:retryCanvasLoad()
    if not (self.session and self.canvas_open) then return nil, "no_canvas" end
    local ok, err = self.session:retryLoad()
    if self.bar then self.bar:update(true) end
    return ok, err
end

--- Open the sheet at the reader's position, or make one there.
function FingerInk:openCanvasHere()
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

function FingerInk:closeCanvas()
    if not self.canvas_open then return end
    self:abortCanvasStroke()
    self:setDrawing(false)
    local ok, err = self.session:closeCanvas()
    if not ok then return nil, err end
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
function FingerInk:applyCanvasPoint(x, y, tool)
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
        self:addCanvasPoint(cx, cy, tr)
        else
            self:startCanvasStroke(cx, cy, tr)
        end
    end
    return true
end

--- Widths are stored in canvas units, so a stroke keeps its weight relative to
--- the page when the sheet is shown at another size or on another screen.
function FingerInk:startCanvasStroke(cx, cy, tr)
    self.canvas_stroke = {
        n = 1, w = self.pen_width / tr.scale,
        min_x = cx, min_y = cy, max_x = cx, max_y = cy,
        cx, cy,
    }
end

function FingerInk:addCanvasPoint(cx, cy, tr)
    local s = self.canvas_stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == cx and py == cy then return end

    s[i + 1] = cx
    s[i + 2] = cy
    s.n = s.n + 1
    if cx < s.min_x then s.min_x = cx elseif cx > s.max_x then s.max_x = cx end
    if cy < s.min_y then s.min_y = cy elseif cy > s.max_y then s.max_y = cy end

    local cache = self.session:cache()
    if not cache then return end
    self:blitCanvasBox(cache:drawSegment(px, py, cx, cy, s.w), tr)
end

--[[--
Copy one dirty region of the raster onto the screen, and refresh it.

The raster is the source of truth for what the sheet looks like, so live ink
goes into it first and is copied out. That is what lets a repaint mid-stroke --
a notification, a menu closing -- show the stroke so far instead of losing it.
]]
function FingerInk:blitCanvasBox(box, tr)
    if not box or box.w <= 0 or box.h <= 0 then return end
    local cache = self.session and self.session:cache()
    local bb = cache and cache:buffer()
    if not bb then return end
    local sx, sy = tr:fromCache(box.x, box.y)
    Screen.bb:blitFrom(bb, sx, sy, box.x, box.y, box.w, box.h)
    self:refreshBox(sx, sy, sx + box.w, sy + box.h, 0)
end

function FingerInk:endCanvasStroke()
    self:endCanvasErase()
    local s = self.canvas_stroke
    self.canvas_stroke = nil
    if not s or not self.session then return end

    local tr = self.session:transform()
    if s.n == 1 and tr then
        -- A dot is never painted live, because there is no segment to paint.
        local cache = self.session:cache()
        if cache then
            self:blitCanvasBox(cache:drawSegment(s[1], s[2], s[1], s[2], s.w), tr)
        end
    end

    local ok, err = self.session:addStroke(s, s.n, s.w, Capture.TOOL_PEN)
    if not ok then
        logger.warn("FingerInk: canvas stroke not recorded:", err)
        -- Live segments were painted before the queue accepted the stroke.
        -- If acceptance failed, remove them now rather than showing ink that
        -- will disappear on reopen.
        local box = self.session:repair(
            s.min_x, s.min_y, s.max_x, s.max_y, s.w)
        if box and tr then self:blitCanvasBox(box, tr) end
    end
end

--[[--
Give up the stroke in progress.

Its segments are already in the raster, so the region has to be rebuilt from
what was underneath. Repainting the overlay alone would leave ink on screen
that is in no canvas.
]]
function FingerInk:abortCanvasStroke()
    self:endCanvasErase()
    local s = self.canvas_stroke
    self.canvas_stroke = nil
    if not s or not self.session then return end
    local box = self.session:repair(s.min_x, s.min_y, s.max_x, s.max_y, s.w)
    local tr = self.session:transform()
    if box and tr then self:blitCanvasBox(box, tr) end
end

function FingerInk:eraseCanvasAt(cx, cy, tr)
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

function FingerInk:endCanvasErase()
    if self.canvas_erase_ctx and self.session then
        self.session:endErase(self.canvas_erase_ctx)
    end
    self.canvas_erase_ctx = nil
    self.canvas_erase_x, self.canvas_erase_y = nil, nil
end

-- ------------------------------------------------------------------ output

function FingerInk:paintTo(bb, x, y)
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
function FingerInk:paintMarks(bb)
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

function FingerInk:repaint()
    UIManager:setDirty(self.ui, "ui")
end

--- DU refresh over the padded bounding box of one segment, clamped to screen.
function FingerInk:refreshBox(x0, y0, x1, y1, w)
    local pad = w + 2
    local x = (x0 < x1 and x0 or x1) - pad
    local y = (y0 < y1 and y0 or y1) - pad
    local bw = (x0 < x1 and x1 - x0 or x0 - x1) + 2 * pad
    local bh = (y0 < y1 and y1 - y0 or y0 - y1) + 2 * pad

    if x < 0 then bw = bw + x; x = 0 end
    if y < 0 then bh = bh + y; y = 0 end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if x + bw > sw then bw = sw - x end
    if y + bh > sh then bh = sh - y end
    if bw <= 0 or bh <= 0 then return end

    if self.live_fast then
        Screen:refreshFast(x, y, bw, bh)
    else
        Screen:refreshPartial(x, y, bw, bh)
    end
end

-- -------------------------------------------------------------------- menu

function FingerInk:onFingerInkUndo()
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

function FingerInk:setPenWidth(w)
    self.pen_width = w
    G_reader_settings:saveSetting("fingerink_pen_width", w)
end

function FingerInk:penItem(text, w)
    return {
        text = text,
        checked_func = function() return self.pen_width == w end,
        radio = true,
        callback = function() self:setPenWidth(w) end,
    }
end

function FingerInk:sideItem(text, side)
    return {
        text = text,
        checked_func = function() return self.bar_side == side end,
        radio = true,
        callback = function()
            if self.bar_side == side then return end
            self.bar_side = side
            G_reader_settings:saveSetting("fingerink_bar_side", side)
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
function FingerInk:inputModeItem(text, value)
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
function FingerInk:showCanvasPicker(list)
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

function FingerInk:confirmDeleteCanvas(canvas)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this sheet and everything drawn on it?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteCanvas(canvas)
        end,
    })
end

--- Delete through the plugin so its visible state changes together with the
--- session. Session deliberately knows nothing about FingerInk's toolbar and
--- capture flags.
function FingerInk:deleteCanvas(canvas)
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
function FingerInk:canvasMenu()
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

function FingerInk:addToMainMenu(menu_items)
    menu_items.fingerink = {
        text = _("Finger Ink"),
        sorting_hint = "more_tools",
        sub_item_table = {
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
                    G_reader_settings:saveSetting("fingerink_live_fast", self.live_fast)
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
                help_text = _([[Shows why the pen route is or is not running, and writes the same report to the log along with one line per pen event for a minute, capped at 500 lines. Digitizer numbers only - nothing from the book.]]),
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
                            self.store:clearAll()
                            self:repaint()
                        end,
                    })
                end,
            },
        },
    }
end

return FingerInk
