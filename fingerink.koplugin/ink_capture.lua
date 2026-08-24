--[[--
Input capture for FingerInk. Two backends, one at a time.

`finger` wraps `GestureDetector:feedEvent`, the only device-agnostic place
where fully parsed finger contacts are observable without patching core. That
is the legacy route and its semantics are unchanged. See ADR-2.

`stylus` registers `Input:registerStylusCallback` for pen/eraser slots *and*
wraps `feedEvent` as well. The callback alone is not palm rejection: it only
removes the pen from gesture detection, so every palm contact would still reach
the reader. The wrapper is how the plugin keeps track of those contacts; what
actually stops them reaching the reader is the widget-layer filter in
`ink_bar.lua`. See ADR-11 and ADR-13.

Both handlers run under pcall and disarm the whole capture on the first error.
Nothing between here and KOReader's main event loop is protected: the callback
is invoked bare from `Input:routeStylusEvents`, `handleTouchEv` is invoked bare
from `Input:waitEvent`, and neither UIManager nor reader.lua wraps that path.
An unguarded error would take KOReader down *and* leave this monkey patch
installed. See ADR-12.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Fallbacks for runtimes older than the Input.TOOL_TYPE_* exports, which
-- landed in v2026.07 (frontend/device/input.lua:1831-1834). The live values
-- are read from Device.input at install time; these only ever apply to a
-- runtime that predates the export, where the stylus backend is unavailable
-- anyway, and to tests.
local TOOL_TYPE_FINGER      = 0
local TOOL_TYPE_PEN         = 1
local TOOL_TYPE_ERASER      = 2
local TOOL_TYPE_HIGHLIGHTER = 3

local Capture = {
    active = false,
    backend = nil,            -- nil | "finger" | "stylus"
    input = nil,
    gesture_detector = nil,
    original_feed = nil,
    feed_was_own = false,     -- was feedEvent an instance field before us?
    feed_wrapper = nil,
    stylus_callback = nil,
    on_error = nil,
    failing = false,
    generation = 0,

    TOOL_FINGER = TOOL_TYPE_FINGER,
    TOOL_PEN = TOOL_TYPE_PEN,
    TOOL_ERASER = TOOL_TYPE_ERASER,
    TOOL_HIGHLIGHTER = TOOL_TYPE_HIGHLIGHTER,
}

-- ------------------------------------------------------------ capability

--[[--
True when this runtime exposes the stylus callback pair. Deliberately does not
look at the gesture detector: a missing detector is a different failure with a
different message, and callers need to tell them apart.
]]
function Capture:supportsStylus()
    local input = Device.input
    return not not (input
        and type(input.registerStylusCallback) == "function"
        and type(input.unregisterStylusCallback) == "function")
end

--[[--
Resolve the tool constants from Input. Done at install time, not at module
load: Device.input is not necessarily built yet when a plugin is required.

Every field is reassigned on every call, so the constants always describe the
Input we are about to hook rather than whatever was hooked before.
]]
function Capture:resolveTools(input)
    input = input or {}
    local function pick(exported, fallback)
        if exported == nil then return fallback end
        return exported
    end
    self.TOOL_FINGER      = pick(input.TOOL_TYPE_FINGER, TOOL_TYPE_FINGER)
    self.TOOL_PEN         = pick(input.TOOL_TYPE_PEN, TOOL_TYPE_PEN)
    self.TOOL_ERASER      = pick(input.TOOL_TYPE_ERASER, TOOL_TYPE_ERASER)
    self.TOOL_HIGHLIGHTER = pick(input.TOOL_TYPE_HIGHLIGHTER, TOOL_TYPE_HIGHLIGHTER)
end

--[[--
Mirrors the `is_stylus` test in Input:routeStylusEvents: a tool match, *or* the
dedicated pen slot regardless of tool. The slot-number clause is the one that
matters on Wacom, and it is why a frame can arrive here reporting
TOOL_TYPE_FINGER.

Used by the residual filter to skip pen slots that were handed back to the UI:
they are not touch, and counting them as contacts corrupts the bookkeeping.
]]
function Capture:isStylusSlot(slot, input)
    if not slot then return false end
    local tool = slot.tool
    if tool == self.TOOL_PEN or tool == self.TOOL_ERASER or tool == self.TOOL_HIGHLIGHTER then
        return true
    end
    input = input or self.input or Device.input
    local pen_slot = input and input.pen_slot
    return pen_slot ~= nil and slot.slot == pen_slot
end

-- -------------------------------------------------------- error handling

--[[--
Disarm after a handler error.

The unhooking is deferred to the next UI tick on purpose. `routeStylusEvents`
re-reads `input.stylus_callback` on *every* slot of the frame
(frontend/device/input.lua:506), so clearing it from inside the callback would
make the next stylus slot in that same frame call a nil value — exactly the
crash this guard exists to prevent. Clearing `active` is enough to make both
wrappers inert immediately; the actual unhook happens from a safe stack.
]]
function Capture:fail(err)
    if self.failing then return end
    self.failing = true
    logger.err("FingerInk: input handler failed:", err)
    self.active = false
    local on_error = self.on_error
    local generation = self.generation
    UIManager:nextTick(function()
        self.failing = false
        if self.generation ~= generation then return end
        self:remove()
        if on_error then
            -- A failure in the notifier must not resurrect the original error.
            local ok, nested = pcall(on_error, err)
            if not ok then
                logger.err("FingerInk: error handler itself failed:", nested)
            end
        end
    end)
end

--[[--
Make both input wrappers inert now and remove them from a safe UI stack.

This is the non-error counterpart of `fail`: a storage or raster failure can
be discovered while a stylus callback is running, and unregistering from that
stack would make KOReader's next stylus slot call a nil callback. Callers may
queue cleanup that must happen after the hook has actually been removed.
]]
function Capture:removeDeferred(after)
    self.active = false
    local generation = self.generation
    UIManager:nextTick(function()
        -- A programmatic close/switch may have removed the old hook and
        -- installed another before this tick. Never tear down that newer
        -- capture or apply stale cleanup to its state.
        if self.generation ~= generation then return end
        self:remove()
        if after then
            local ok, err = pcall(after)
            if not ok then
                logger.err("FingerInk: deferred capture cleanup failed:", err)
            end
        end
    end)
end

--[[--
Wrap a plugin handler so a raised error degrades instead of propagating.
`fail_value` is the answer that makes KOReader behave as if we were not here:
false for the stylus callback (do not dominate the slot) and true for the
residual wrapper (let the gestures out).

`fail` itself is called under pcall too — it is not part of the caller's
contract, and a raise from it would escape to exactly the place we are
protecting.
]]
local function guard(self, fn, fail_value)
    return function(...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        pcall(self.fail, self, res)
        return fail_value
    end
end

-- ------------------------------------------------------------- install

--[[--
Build the feedEvent wrapper.

The handler sees the frame's contacts and may return a *replacement* array;
returning nothing passes the frame through untouched, which is what the legacy
finger route does.

Filtering here is not a way to suppress gestures in general. `hold` and the
deferred single `tap` come from timer callbacks registered through
`Input:setTimeout` (gesturedetector.lua:641 and :675) and are dispatched
straight from `Input:waitEvent` (input.lua:1584) without passing through
feedEvent at all, so emptying the array cannot stop a gesture from a contact
that already exists. That is why the widget layer decides what reaches the
application. See ADR-13.

What removing a slot from its *very first* frame does achieve is different and
worth having: GestureDetector never opens a Contact for it, so no hold timer is
ever armed and no gesture is ever produced. Emitted gestures carry `ges`, `pos`
and `time` and no slot number (gesturedetector.lua:540, :606, :1262), so a
palm's `hold` over the book text is indistinguishable at the widget layer from
the reader's own -- and the overlay hands gestures above the sheet to the book
on purpose. Keeping that contact from existing is the only place the two can
still be told apart.

The wrapper stays transparent once we are no longer the installed wrapper, which
is what makes removal safe when another plugin has chained on top of us and we
can no longer unhook cleanly.
]]
function Capture:_installFeedWrapper(frame_handler)
    local original = self.original_feed
    -- nil on failure, so a raising handler degrades to "pass the whole frame
    -- through" rather than handing the detector something that is not a frame.
    local handler = guard(self, frame_handler, nil)
    local wrapper
    wrapper = function(gd_self, slots)
        if not (self.active and self.feed_wrapper == wrapper) then
            return original(gd_self, slots)
        end
        local kept = handler(slots)
        return original(gd_self, type(kept) == "table" and kept or slots)
    end
    self.feed_wrapper = wrapper
    self.feed_was_own = rawget(self.gesture_detector, "feedEvent") ~= nil
    self.gesture_detector.feedEvent = wrapper
end

--[[--
Drop one slot's contact, and with it the hold and double-tap timers it armed.

For the case a filter cannot catch: a contact-down frame that arrived without
coordinates has already reached the detector by the time the next frame says
where it was, and by then a Contact exists. `dropContact` is GestureDetector's
own way to retire one, and doing it per slot rather than through
`dropContacts()` is what leaves a finger on the toolbar alone.

Returns whether anything was dropped. A runtime without the pair -- or a slot
with no contact -- is a no-op, not an error.
]]
function Capture:dropContact(slot)
    local gd = self.gesture_detector
    if not gd or type(gd.getContact) ~= "function"
        or type(gd.dropContact) ~= "function" then
        return false
    end
    local ok, contact = pcall(gd.getContact, gd, slot)
    if not ok or not contact then return false end
    local dropped, err = pcall(gd.dropContact, gd, contact)
    if not dropped then
        logger.warn("FingerInk: could not drop contact for slot", slot, err)
        return false
    end
    return true
end

--- Legacy touch capture. handler(slots) returns true to let gestures through.
function Capture:installFinger(frame_handler, on_error)
    if self.active then return false, "already_installed" end

    local input = Device.input
    local gd = input and input.gesture_detector
    if not gd or type(gd.feedEvent) ~= "function" then
        return false, "no_gesture_detector"
    end

    self:resolveTools(input)
    self.input = input
    self.gesture_detector = gd
    self.original_feed = gd.feedEvent
    self.on_error = on_error
    self.backend = "finger"
    self.active = true
    self.generation = self.generation + 1
    self:_installFeedWrapper(frame_handler)

    logger.info("FingerInk: capture installed, backend finger")
    return true, "finger"
end

--[[--
Stylus capture. `stylus_handler(slot)` returns true to dominate the slot;
`residual_frame_handler(slots)` returns true to let the frame's gestures out.

Everything is validated before the first mutation, so a refusal leaves the
runtime exactly as it was found.
]]
function Capture:installStylus(stylus_handler, residual_frame_handler, on_error)
    if self.active then return false, "already_installed" end

    local input = Device.input
    if not input then return false, "no_input" end
    if type(input.registerStylusCallback) ~= "function"
        or type(input.unregisterStylusCallback) ~= "function" then
        return false, "no_stylus_api"
    end
    local gd = input.gesture_detector
    if not gd or type(gd.feedEvent) ~= "function" then
        return false, "no_gesture_detector"
    end
    -- The callback is a singleton with no chaining and no owner query, so the
    -- only safe move against another plugin is to refuse. Our own callback is
    -- always nil here: we return early when active, and every removal path
    -- clears it.
    if input.stylus_callback ~= nil then
        return false, "stylus_callback_busy"
    end

    self:resolveTools(input)
    self.input = input
    self.gesture_detector = gd
    self.original_feed = gd.feedEvent
    self.on_error = on_error
    self.backend = "stylus"
    self.active = true
    self.generation = self.generation + 1

    local handler = guard(self, stylus_handler, false)
    local callback
    callback = function(_, slot)
        if not (self.active and self.stylus_callback == callback) then return false end
        return handler(slot) and true or false
    end
    self.stylus_callback = callback

    -- Registration is the first mutation of the runtime; if a device override
    -- raises here, the refusal must still leave nothing behind.
    local registered, reg_err = pcall(input.registerStylusCallback, input, callback)
    if not registered then
        logger.err("FingerInk: registerStylusCallback failed:", reg_err)
        self.active = false
        self:_forget()
        return false, "no_stylus_api"
    end

    self:_installFeedWrapper(residual_frame_handler)

    logger.info("FingerInk: capture installed, backend stylus, pen_slot", input.pen_slot)
    return true, "stylus"
end

-- -------------------------------------------------------------- removal

function Capture:_forget()
    self.input = nil
    self.gesture_detector = nil
    self.original_feed = nil
    self.feed_was_own = false
    self.feed_wrapper = nil
    self.stylus_callback = nil
    self.backend = nil
    self.on_error = nil
    self:resolveTools(nil)
end

--[[--
Give back everything we still own, and only what we still own. Idempotent.

Deliberately not gated on `active`: an error disarms by clearing `active` and
schedules this for the next tick, so by the time it runs the flag is already
false but the hooks are still in place.
]]
function Capture:remove()
    local input = self.input
    local gd = self.gesture_detector
    if not (input or gd) then
        self:_forget()
        return
    end
    self.active = false

    if self.stylus_callback and input then
        if input.stylus_callback == self.stylus_callback then
            input:unregisterStylusCallback()
        else
            logger.warn("FingerInk: stylus callback was replaced by someone else; leaving it in place")
        end
    end

    if self.feed_wrapper and gd then
        if gd.feedEvent == self.feed_wrapper then
            -- feedEvent is normally inherited from the GestureDetector class.
            -- Writing the original back as an instance field would pin a
            -- snapshot of it forever, so restore the exact shape we found.
            if self.feed_was_own then
                gd.feedEvent = self.original_feed
            else
                gd.feedEvent = nil
            end
        else
            logger.warn("FingerInk: feedEvent was replaced by someone else; leaving it in place")
        end
    end

    self:_forget()
end

-- ---------------------------------------------------------- coordinates

--[[--
Slot coordinates are pre-rotation: GestureDetector applies the transform after
detection, in Input:handleTouchEv, so both capture routes have to do it
themselves. Formulas mirror GestureDetector:translateCoordinates exactly,
including its identity default for a mode outside 0..3.

getTouchRotation is the contract GestureDetector itself uses; it can diverge
from getRotationMode on backends that override it (PocketBook does). The
fallback is defensive only — koreader-base has shipped getTouchRotation since
well before the minimum supported version.

Returns two numbers, no table.
]]
function Capture.toScreen(x, y)
    local screen = Device.screen
    local mode = screen.getTouchRotation
        and screen:getTouchRotation()
        or screen:getRotationMode()
    if mode == screen.DEVICE_ROTATED_CLOCKWISE then
        return screen:getWidth() - y, x
    elseif mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return screen:getWidth() - x, screen:getHeight() - y
    elseif mode == screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        return y, screen:getHeight() - x
    else -- DEVICE_ROTATED_UPRIGHT, and anything unexpected: identity
        return x, y
    end
end

return Capture
