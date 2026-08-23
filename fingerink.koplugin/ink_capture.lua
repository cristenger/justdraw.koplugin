--[[--
Input capture for FingerInk. Two backends, one at a time.

`finger` wraps `GestureDetector:feedEvent`, the only device-agnostic place
where fully parsed finger contacts are observable without patching core. That
is the legacy route and its semantics are unchanged. See ADR-2.

`stylus` registers `Input:registerStylusCallback` for pen/eraser slots *and*
wraps `feedEvent` as well. The callback alone is not palm rejection: it only
removes the pen from gesture detection, so every palm contact would still
reach the reader and turn pages. The residual wrapper is what suppresses them.
See ADR-11.

Both handlers run under pcall and disarm the whole capture on the first error.
Nothing between here and KOReader's main event loop is protected: the callback
is invoked bare from `Input:routeStylusEvents`, `handleTouchEv` is invoked bare
from `Input:waitEvent`, and neither UIManager nor reader.lua wraps that path.
An unguarded error would take KOReader down *and* leave this monkey patch
installed. See ADR-12.
]]

local Device = require("device")
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
    feed_wrapper = nil,
    stylus_callback = nil,
    on_error = nil,

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
Disarm after a handler error. Runs remove() *before* notifying, so a caller
that disarms again from its own error handler finds nothing left to do.
]]
function Capture:fail(err)
    logger.err("FingerInk: input handler failed:", err)
    local on_error = self.on_error
    self:remove()
    if on_error then
        -- A failure in the notifier must not resurrect the original error.
        local ok, nested = pcall(on_error, err)
        if not ok then
            logger.err("FingerInk: error handler itself failed:", nested)
        end
    end
end

--[[--
Wrap a plugin handler so a raised error degrades instead of propagating.
`fail_value` is the answer that makes KOReader behave as if we were not here:
false for the stylus callback (do not dominate the slot) and true for the
residual wrapper (let the gestures out).
]]
local function guard(self, fn, fail_value)
    return function(...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        self:fail(res)
        return fail_value
    end
end

-- ------------------------------------------------------------- install

--[[--
Build the feedEvent wrapper. It stays transparent once we are no longer the
installed wrapper, which is what makes removal safe when another plugin has
chained on top of us and we can no longer unhook cleanly.
]]
function Capture:_installFeedWrapper(frame_handler, fail_value)
    local original = self.original_feed
    local handler = guard(self, frame_handler, fail_value)
    local wrapper
    wrapper = function(gd_self, slots)
        if not (self.active and self.feed_wrapper == wrapper) then
            return original(gd_self, slots)
        end
        local emit = handler(slots)
        local evs = original(gd_self, slots)
        if emit then return evs end
        for i = #evs, 1, -1 do
            evs[i] = nil
        end
        return evs
    end
    self.feed_wrapper = wrapper
    self.gesture_detector.feedEvent = wrapper
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
    self:_installFeedWrapper(frame_handler, true)

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
    -- only safe move against another plugin is to refuse.
    if input.stylus_callback ~= nil and input.stylus_callback ~= self.stylus_callback then
        return false, "stylus_callback_busy"
    end

    self:resolveTools(input)
    self.input = input
    self.gesture_detector = gd
    self.original_feed = gd.feedEvent
    self.on_error = on_error
    self.backend = "stylus"
    self.active = true

    local handler = guard(self, stylus_handler, false)
    local callback
    callback = function(_, slot)
        if not (self.active and self.stylus_callback == callback) then return false end
        return handler(slot) and true or false
    end
    self.stylus_callback = callback
    input:registerStylusCallback(callback)

    self:_installFeedWrapper(residual_frame_handler, true)

    logger.info("FingerInk: capture installed, backend stylus, pen_slot", input.pen_slot)
    return true, "stylus"
end

-- -------------------------------------------------------------- removal

function Capture:_forget()
    self.input = nil
    self.gesture_detector = nil
    self.original_feed = nil
    self.feed_wrapper = nil
    self.stylus_callback = nil
    self.backend = nil
    self.on_error = nil
end

--[[--
Give back everything we still own, and only what we still own. Idempotent.

Order matters: clearing `active` first turns our own handlers into passthrough,
so a wrapper someone else chained on top of ours keeps working even in the case
where we cannot unhook.
]]
function Capture:remove()
    if not self.active then
        self:_forget()
        return
    end
    self.active = false

    local input = self.input
    local gd = self.gesture_detector

    if self.stylus_callback and input then
        if input.stylus_callback == self.stylus_callback then
            input:unregisterStylusCallback()
        else
            logger.warn("FingerInk: stylus callback was replaced by someone else; leaving it in place")
        end
    end

    if self.feed_wrapper and gd then
        if gd.feedEvent == self.feed_wrapper then
            gd.feedEvent = self.original_feed
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
themselves. Formulas mirror GestureDetector:translateCoordinates exactly.

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
    if mode == screen.DEVICE_ROTATED_UPRIGHT then
        return x, y
    elseif mode == screen.DEVICE_ROTATED_CLOCKWISE then
        return screen:getWidth() - y, x
    elseif mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return screen:getWidth() - x, screen:getHeight() - y
    else -- DEVICE_ROTATED_COUNTER_CLOCKWISE
        return y, screen:getHeight() - x
    end
end

return Capture
