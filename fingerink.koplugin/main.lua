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
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Capture = require("ink_capture")
local InkBar = require("ink_bar")
local Render = require("ink_render")
local Store = require("ink_store")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SETTING_KEY = "fingerink_strokes"
local MODE_KEY = "fingerink_input_mode"
local SUSPENDED = -1   -- draw_slot sentinel: ignore this contact until it lifts

local INPUT_MODES = { auto = true, stylus = true, finger = true }

-- Reasons Capture can refuse, mapped to something a user can act on.
local INPUT_ERRORS = {
    no_stylus_api = _("Stylus input requires KOReader v2026.07 or newer"),
    stylus_callback_busy = _("Another plugin is already using stylus input"),
    no_gesture_detector = _("Finger Ink: cannot hook touch input"),
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
    self.stylus_frame_ui = false
    self.stylus_lift_x, self.stylus_lift_y = nil, nil

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
    self:abortStroke()
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

function FingerInk:onSaveSettings()
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
    self:rebuildBar()
end

function FingerInk:onSetRotationMode()
    self:rebuildBar()
end

-- ----------------------------------------------------------------- toolbar

function FingerInk:setBarShown(on)
    on = on and true or false
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
function FingerInk:dialogOnTop()
    local below = self.bar and self.bar:windowBelow()
    return below ~= nil and below ~= self.ui
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
        logger.info("FingerInk: drawing on, mode", self.input_mode, "backend", backend)
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
    self.eraser = on and true or false
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
--- is how the next contact-down detects stale coordinates. `stylus_frame_ui`
--- does not: a raise mid-frame skips stylusFrameResult entirely and would
--- otherwise leave the flag set for the next session's first residual frame.
function FingerInk:resetStylusState()
    self.stylus_active = false
    self.stylus_passthrough = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_stale_xy = false
    self.stylus_frame_ui = false
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
sees it. Returns true if the frame's gesture events should reach the app.
]]
function FingerInk:onTouchFrame(slots)
    if not self.passthrough and self:dialogOnTop() then
        -- Latches for the whole contact sequence, and re-latches on the next
        -- one, so drawing resumes by itself once the dialog is gone.
        self.passthrough = true
        self:abortStroke()
    end

    local was_passthrough = self.passthrough

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

    return self.passthrough or was_passthrough
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

    -- Hover before this slot ever carried a tracking id. Consume, change nothing.
    if id == nil then return self:stylusFrameResult(true) end

    if id >= 0 then
        if not self.stylus_active then
            self.stylus_active = true
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
        if self.stylus_passthrough then return self:stylusFrameResult(false) end

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
                if not self.stylus_dominated and self:inBar(sx, sy) then
                    self.stylus_passthrough = true
                    return self:stylusFrameResult(false)
                end
            end
            self:onStylusPoint(sx, sy, tool)
        end
        -- Only the contact-down frame can be carrying stale coordinates.
        self.stylus_stale_xy = false
        self.stylus_dominated = true
        return self:stylusFrameResult(true)
    end

    -- Contact lift. Remember where it happened, for the staleness check above.
    if x and y then
        self.stylus_lift_x, self.stylus_lift_y = x, y
    end
    if not self.stylus_active then
        return self:stylusFrameResult(not self.stylus_passthrough)
    end
    local was_passthrough = self.stylus_passthrough
    if not was_passthrough then
        self:endStroke()
    end
    self:resetStylusState()
    return self:stylusFrameResult(not was_passthrough)
end

--[[--
Record this frame's pen decision and return it.

The residual filter runs later in the same input frame and needs to know
whether the pen handed its slot to the UI. It cannot read `stylus_passthrough`,
because the lift frame — the one that carries the toolbar's tap — resets that
state before the filter runs. Reading it there is what made every toolbar
button unreachable with the pen.
]]
function FingerInk:stylusFrameResult(dominate)
    if not dominate then self.stylus_frame_ui = true end
    return dominate
end

--[[--
One drawing point from the pen. Starting on the toolbar is already settled by
the latch, so the only case left is a stroke dragged *onto* the bar, which ends
at the edge rather than scribbling over the buttons.
]]
function FingerInk:onStylusPoint(x, y, tool)
    if self.stylus_suspended then return end
    if self:inBar(x, y) then
        self:endStroke()
        self.stylus_suspended = true
        return
    end
    self:applyPoint(x, y, tool)
end

--[[--
The residual touch filter: everything the pen callback did not take.

Runs after onStylusEvent within the same input frame, because
Input:routeStylusEvents is called immediately before feedEvent in every
handleTouchEv variant. So the pen's decision for this frame is already made and
a dominated pen slot is already gone from `slots`. That ordering is what lets
this function promise never to touch `self.stroke` — a palm landing mid-stroke
is precisely what the stylus backend exists to ignore.

While drawing is on, touch does not navigate. Finger and palm are not told
apart; refusing to guess is what makes rejection predictable. The only touches
that survive are the ones aimed at the toolbar or at a dialog above the reader.
]]
function FingerInk:onStylusTouchFrame(slots)
    -- The pen already ran in this frame. If it handed its slot to the UI, this
    -- frame has to be emitted so the toolbar button or the dialog gets it.
    -- Gestures carry `pos` but not `slot`, so the decision is necessarily per
    -- frame: releasing the pen's gesture also releases a simultaneous palm's.
    -- Known limitation, documented in the README.
    local pen_wants_ui = self.stylus_frame_ui
    self.stylus_frame_ui = false

    if not self.passthrough and self:dialogOnTop() then
        self.passthrough = true
    end

    local was_passthrough = self.passthrough

    -- Contact accounting runs unconditionally, even when the pen has already
    -- decided this frame. Skipping it used to strand `n_contacts` and leave
    -- `passthrough` latched, at which point a palm could turn pages.
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

    return pen_wants_ui or self.passthrough or was_passthrough
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

function FingerInk:endStroke()
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

function FingerInk:abortStroke()
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

-- ------------------------------------------------------------------ output

function FingerInk:paintTo(bb, x, y)
    local list = self.store:get(self:currentPage())
    if not list then return end
    for i = 1, #list do
        Render.stroke(bb, list[i], 0, 0, INK)
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
            self:rebuildBar()
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
                help_text = _([[Automatic uses the stylus route on devices that report a pen digitizer, and the finger route everywhere else. While the stylus route is active, finger and palm never draw and never turn pages — press Stop to read again.]]),
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
