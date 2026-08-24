--[[--
FingerInk input regression suite.

Runs under a bare LuaJIT, no KOReader session. Two entry points reach this
file, so the search path is derived from the file's own location rather than
from the working directory:

  koreader_qa.sh test        ->  cd <plugin> && luajit tests/run.lua
  luajit test.lua            ->  from the repository root, via the shim
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local support = require("support")
local env = support.install()

local Capture = require("ink_capture")
local Store = require("ink_store")
local Render = require("ink_render")
local FingerInk = require("main")

local t = support.newRunner()
local Device = env.Device

--- Point every test at a freshly built Input, with capture torn down.
local function reset(input_opts)
    -- Error disarming is deferred to the next UI tick; drain it so one case's
    -- pending teardown cannot bleed into the next.
    env.UIManager:flush()
    Capture:remove()
    Device.input = support.newInput(input_opts)
    Device._is_sdl = false
    Device.screen.rotation = 0
    Device.screen.touch_rotation = nil
    Device.screen.refreshes = {}
    Device.screen.bb:clear()
    env.notifications = {}
    env.shown_messages = {}
    env.reader_events = {}
    env.UIManager._window_stack = {}
    _G.G_reader_settings.data = {}
    return Device.input
end

local function newPlugin(opts)
    local p = support.newPlugin(FingerInk, env, opts)
    env.UIManager:flush()   -- let the deferred setBarShown run
    return p
end

--- Put a window above the toolbar, the way UIManager:show would. `dialogOnTop`
--- and the suppression decision both read the real stack now, so a dialog has
--- to actually be on it.
local function showDialog(name)
    local w = { name = name }
    env.UIManager:show(w)
    return w
end

local RealInkBar = dofile(plugin_dir .. "/ink_bar.lua")

local function newRealBar(plugin, side)
    return RealInkBar:new{ plugin = plugin, side = side or "right" }
end

--- Swap in the real toolbar widget, on the real window stack. The fake bar
--- newPlugin puts up is closed first: production only ever has one, and a
--- second one in the middle of the stack would be what `windowBelow` finds
--- instead of the reader.
---
--- Every plugin the input tests drive uses this, because the suppression
--- decision now lives in the widget and a fake bar could not answer it.
local function realBar(plugin)
    plugin:setBarShown(false)
    local bar = newRealBar(plugin)
    plugin.bar = bar
    env.UIManager:show(bar)
    return bar
end

local function realBarPlugin(opts)
    reset(opts)
    local p = newPlugin()
    return p, realBar(p)
end

-- =====================================================================
-- ink_capture.lua
-- =====================================================================

t:describe("ink_capture / stylus API detection")

t:case("missing stylus API", function()
    local input = reset{ stylus_api = false }
    local feed_before = input.gesture_detector.feedEvent
    t:eq(Capture:supportsStylus(), false, "supportsStylus is false without the API")
    local ok, reason = Capture:installStylus(function() end, function() end)
    t:eq(ok, false, "installStylus refuses")
    t:eq(reason, "no_stylus_api", "reason is no_stylus_api")
    t:eq(input.stylus_callback, nil, "nothing was registered")
    t:eq(input.gesture_detector.feedEvent, feed_before, "feedEvent is the same function")
    t:eq(Capture.active, false, "capture stayed inactive")
end)

t:case("missing gesture detector", function()
    reset{ gesture = false }
    local ok, reason = Capture:installStylus(function() end, function() end)
    t:eq(ok, false, "installStylus refuses")
    t:eq(reason, "no_gesture_detector", "reason is no_gesture_detector")
end)

t:case("callback already owned by someone else", function()
    local input = reset()
    local foreign = function() return true end
    input.stylus_callback = foreign
    local original_feed = input.gesture_detector.feedEvent

    local ok, reason = Capture:installStylus(function() end, function() end)
    t:eq(ok, false, "installStylus refuses")
    t:eq(reason, "stylus_callback_busy", "reason is stylus_callback_busy")
    t:eq(input.stylus_callback, foreign, "foreign callback left intact")
    t:eq(input.gesture_detector.feedEvent, original_feed, "feedEvent not wrapped either")
end)

t:describe("ink_capture / install and dominate")

t:case("valid install registers exactly one callback and one wrapper", function()
    local input = reset()
    local original_feed = input.gesture_detector.feedEvent
    local ok, backend = Capture:installStylus(function() return true end, function() return false end)
    t:eq(ok, true, "install succeeded")
    t:eq(backend, "stylus", "backend reported")
    t:check(type(input.stylus_callback) == "function", "callback registered")
    t:check(input.gesture_detector.feedEvent ~= original_feed, "feedEvent wrapped")
    t:eq(Capture.original_feed, original_feed, "original remembered")
end)

t:case("callback returning true reaches KOReader as true", function()
    local input = reset()
    Capture:installStylus(function() return true end, function() return false end)
    t:eq(input.stylus_callback(input, { slot = 4, id = 4 }), true, "true propagates")
end)

t:case("callback returning false reaches KOReader as false", function()
    local input = reset()
    Capture:installStylus(function() return false end, function() return false end)
    t:eq(input.stylus_callback(input, { slot = 4, id = 4 }), false, "false propagates")
end)

t:case("the wrapper observes the frame and passes the detector's output through", function()
    -- ADR-13: emptying this array never could suppress hold or the deferred
    -- tap, so the wrapper stopped trying. It observes; InkBar:suppresses
    -- decides. Whatever the handler answers, the detector's output survives.
    local input = reset()
    local gd = input.gesture_detector
    local seen
    Capture:installStylus(function() return true end,
        function(slots) seen = slots; return false end)
    local frame = { { slot = 0, id = 1, x = 10, y = 20 } }
    local evs = gd.feedEvent(gd, frame)
    t:eq(gd.calls, 1, "original feedEvent was still called")
    t:eq(seen, frame, "the residual handler saw the frame")
    t:eq(#evs, 1, "and the detector's gestures were not touched")
end)

t:case("the wrapper drops no contacts", function()
    -- dropContact was the old way to reach hold timers. It is destructive and
    -- the finger route could never use it; nothing needs it now.
    local input = reset()
    local gd = input.gesture_detector
    Capture:installStylus(function() return true end, function() return false end)
    gd.feedEvent(gd, { { slot = 0, id = 1, x = 10, y = 20 } })
    t:check(gd:getContact(0) ~= nil, "the contact is left alone")
    t:eq(#gd.dropped, 0, "nothing was dropped")
end)

t:case("finger backend keeps its existing semantics", function()
    local input = reset()
    local gd = input.gesture_detector
    local seen
    local ok, backend = Capture:installFinger(function(slots) seen = slots; return false end)
    t:eq(ok, true, "install succeeded")
    t:eq(backend, "finger", "backend reported")
    t:eq(input.stylus_callback, nil, "finger backend registers no stylus callback")
    local frame = { { slot = 0, id = 1, x = 10, y = 20 } }
    local evs = gd.feedEvent(gd, frame)
    t:eq(seen, frame, "handler saw the frame")
    t:eq(#evs, 1, "and the detector's output passes through untouched")
end)

t:describe("ink_capture / ownership-safe removal")

t:case("remove twice is a no-op", function()
    local input = reset()
    Capture:installStylus(function() return true end, function() return false end)
    Capture:remove()
    local after = input.gesture_detector.feedEvent
    Capture:remove()
    t:eq(input.stylus_callback, nil, "callback gone")
    t:eq(input.gesture_detector.feedEvent, after, "second remove changed nothing")
    t:eq(Capture.active, false, "inactive")
end)

t:case("remove does not clobber a callback registered after us", function()
    local input = reset()
    Capture:installStylus(function() return true end, function() return false end)
    local newer = function() return true end
    input.stylus_callback = newer
    Capture:remove()
    t:eq(input.stylus_callback, newer, "newer callback survived")
end)

t:case("remove does not restore over a wrapper chained after us", function()
    local input = reset()
    local gd = input.gesture_detector
    local original_feed = gd.feedEvent
    local handler_calls = 0
    Capture:installStylus(function() return true end,
                          function() handler_calls = handler_calls + 1; return false end)
    local ours = Capture.feed_wrapper
    local newer = function(gd_self, slots) return ours(gd_self, slots) end
    gd.feedEvent = newer

    Capture:remove()
    t:eq(gd.feedEvent, newer, "chained wrapper survived")

    -- Our own wrapper is still reachable through the chain: it must now be
    -- transparent instead of filtering with a dead handler.
    local evs = gd.feedEvent(gd, { { slot = 0, id = 1, x = 10, y = 20 } })
    t:eq(handler_calls, 0, "our handler no longer runs")
    t:eq(#evs, 1, "our wrapper passes gestures through unchanged")
    t:eq(gd.calls, 1, "original feedEvent reached exactly once")
    t:eq(Capture.original_feed, nil, "we dropped our reference to the original")
    t:check(original_feed ~= gd.feedEvent, "the chained wrapper is not the original")
end)

t:describe("ink_capture / coordinates")

t:case("four rotations match GestureDetector:translateCoordinates", function()
    reset()
    local s = Device.screen
    s.w, s.h = 600, 800

    s.rotation = s.DEVICE_ROTATED_UPRIGHT
    local x, y = Capture.toScreen(10, 20)
    t:eq(x, 10, "UR x"); t:eq(y, 20, "UR y")

    s.rotation = s.DEVICE_ROTATED_CLOCKWISE
    x, y = Capture.toScreen(10, 20)
    t:eq(x, 600 - 20, "CW x = width - y"); t:eq(y, 10, "CW y = x")

    s.rotation = s.DEVICE_ROTATED_UPSIDE_DOWN
    x, y = Capture.toScreen(10, 20)
    t:eq(x, 600 - 10, "UD x = width - x"); t:eq(y, 800 - 20, "UD y = height - y")

    s.rotation = s.DEVICE_ROTATED_COUNTER_CLOCKWISE
    x, y = Capture.toScreen(10, 20)
    t:eq(x, 20, "CCW x = y"); t:eq(y, 800 - 10, "CCW y = height - x")

    s.rotation = 0
end)

t:case("getTouchRotation wins over getRotationMode", function()
    reset()
    local s = Device.screen
    s.rotation = s.DEVICE_ROTATED_UPRIGHT
    s.touch_rotation = s.DEVICE_ROTATED_CLOCKWISE
    local x, y = Capture.toScreen(10, 20)
    t:eq(x, 600 - 20, "used the touch rotation, not the display rotation")
    t:eq(y, 10, "used the touch rotation for y too")
    s.touch_rotation = nil
end)

t:case("falls back to getRotationMode when getTouchRotation is absent", function()
    reset()
    local saved = Device.screen
    Device.screen = support.newScreen{ no_touch_rotation = true }
    Device.screen.rotation = Device.screen.DEVICE_ROTATED_UPSIDE_DOWN
    local ok, x, y = pcall(Capture.toScreen, 10, 20)
    t:eq(ok, true, "no error without getTouchRotation")
    t:eq(x, 600 - 10, "fell back to getRotationMode")
    t:eq(y, 800 - 20, "fell back for y too")
    Device.screen = saved
end)

t:describe("ink_capture / tool constants")

t:case("tool constants come from Device.input when exported", function()
    local input = reset()
    input.TOOL_TYPE_ERASER = 42
    Capture:installStylus(function() return true end, function() return false end)
    t:eq(Capture.TOOL_ERASER, 42, "picked up the exported value")
end)

t:case("tool constants fall back to the documented literals", function()
    reset{ exports = false }
    Capture:installStylus(function() return true end, function() return false end)
    t:eq(Capture.TOOL_FINGER, 0, "finger = 0")
    t:eq(Capture.TOOL_PEN, 1, "pen = 1")
    t:eq(Capture.TOOL_ERASER, 2, "eraser = 2")
    t:eq(Capture.TOOL_HIGHLIGHTER, 3, "highlighter = 3")
end)

t:describe("ink_capture / error containment")

t:case("a throwing stylus handler does not escape and disarms capture", function()
    local input = reset()
    local errors = 0
    Capture:installStylus(function() error("boom") end,
                          function() return false end,
                          function() errors = errors + 1 end)
    local cb = input.stylus_callback
    local ok, res = pcall(cb, input, { slot = 4, id = 4 })
    t:eq(ok, true, "error did not propagate to KOReader")
    t:eq(res, false, "safe return value is false: do not dominate")
    t:eq(Capture.active, false, "capture went inert immediately")
    -- Still registered: unhooking from inside the callback would break the
    -- rest of routeStylusEvents' loop. See the next case.
    t:eq(input.stylus_callback, cb, "still registered until the next tick")
    t:eq(errors, 0, "on_error is deferred too")

    env.UIManager:flush()
    t:eq(errors, 1, "on_error fired exactly once")
    t:eq(input.stylus_callback, nil, "callback unregistered on the next tick")
    t:eq(Capture.active, false, "capture disarmed")
end)

t:case("a second stylus slot in the same frame does not call a nil callback", function()
    -- Input:routeStylusEvents re-reads input.stylus_callback on every slot of
    -- the frame, so a mid-loop unregister would make the next slot call nil.
    local input = reset()
    Capture:installStylus(function() error("boom") end,
                          function() return false end,
                          function() end)
    local frame = {
        { slot = 2, id = 2, x = 1, y = 1, tool = 1 },   -- matches by tool
        { slot = 4, id = 4, x = 2, y = 2 },             -- matches by pen_slot
    }
    local ok, err = pcall(function()
        for _, slot in ipairs(frame) do
            input.stylus_callback(input, slot)          -- re-read, as core does
        end
    end)
    t:eq(ok, true, "the whole frame survived: " .. tostring(err))
    env.UIManager:flush()
    t:eq(input.stylus_callback, nil, "unhooked afterwards, from a safe stack")
end)

t:case("a throwing residual handler does not escape and disarms capture", function()
    local input = reset()
    local gd = input.gesture_detector
    local errors = 0
    Capture:installStylus(function() return true end,
                          function() error("boom") end,
                          function() errors = errors + 1 end)
    local wrapper = gd.feedEvent
    local ok, evs = pcall(wrapper, gd, { { slot = 0, id = 1, x = 10, y = 20 } })
    t:eq(ok, true, "error did not propagate to KOReader")
    t:eq(#evs, 1, "safe return value emits: gestures reach the reader")
    t:eq(Capture.active, false, "capture went inert immediately")
    env.UIManager:flush()
    t:eq(errors, 1, "on_error fired exactly once")
    t:eq(Capture.active, false, "capture disarmed")
end)

t:case("a re-entrant remove from on_error is idempotent", function()
    local input = reset()
    local errors = 0
    Capture:installStylus(function() error("boom") end,
                          function() return false end,
                          function() errors = errors + 1; Capture:remove() end)
    local ok = pcall(input.stylus_callback, input, { slot = 4, id = 4 })
    t:eq(ok, true, "no error escaped")
    env.UIManager:flush()
    t:eq(errors, 1, "on_error still fired exactly once")
    t:eq(Capture.active, false, "capture disarmed")
end)

t:case("a throwing on_error does not resurrect the error", function()
    local input = reset()
    Capture:installStylus(function() error("boom") end,
                          function() return false end,
                          function() error("secondary") end)
    local ok = pcall(input.stylus_callback, input, { slot = 4, id = 4 })
    t:eq(ok, true, "secondary failure contained too")
    env.UIManager:flush()
    t:eq(Capture.active, false, "capture still disarmed")
end)

-- =====================================================================
-- main.lua : backend resolution
-- =====================================================================

t:describe("main / backend resolution")

t:case("auto with wacom and API picks stylus", function()
    reset{ wacom_protocol = true }
    local p = newPlugin()
    t:eq(p:resolveInputBackend(), "stylus", "stylus chosen")
end)

t:case("auto without wacom and not SDL picks finger", function()
    reset()
    local p = newPlugin()
    t:eq(p:resolveInputBackend(), "finger", "finger chosen")
end)

t:case("auto on SDL still picks finger so the emulator mouse can draw", function()
    -- koreader-base routes SDL3 *pen* events to the pen slot with a real tool,
    -- but a plain mouse lands on slot 0/1 with no ABS_MT_TOOL_TYPE. Choosing
    -- stylus here would let the residual filter swallow every mouse contact.
    reset()
    Device._is_sdl = true
    local p = newPlugin()
    t:eq(p:resolveInputBackend(), "finger", "finger chosen on SDL")
    Device._is_sdl = false
end)

t:case("explicit stylus on SDL is available for tablet testing", function()
    reset()
    Device._is_sdl = true
    local p = newPlugin()
    p:setInputMode("stylus")
    t:eq(p:resolveInputBackend(), "stylus", "opt-in still works")
    Device._is_sdl = false
end)

t:case("auto without the API falls back to finger", function()
    reset{ stylus_api = false, wacom_protocol = true }
    local p = newPlugin()
    t:eq(p:resolveInputBackend(), "finger", "no API means the legacy route")
end)

t:case("explicit stylus without the API refuses to start drawing", function()
    reset{ stylus_api = false }
    local p = newPlugin()
    p:setInputMode("stylus")
    p:setDrawing(true)
    t:eq(p.drawing, false, "drawing stayed off")
    t:eq(#env.notifications, 1, "one notification shown")
    t:check(tostring(env.notifications[1]):find("v2026.07", 1, true) ~= nil,
            "message names the required version")
end)

t:case("explicit stylus does not require wacom_protocol", function()
    reset()   -- API present, wacom_protocol false
    local p = newPlugin()
    p:setInputMode("stylus")
    t:eq(p:resolveInputBackend(), "stylus", "stylus available on any device with the API")
end)

t:case("explicit stylus reports a busy callback instead of silently falling back", function()
    local input = reset{ wacom_protocol = true }
    input.stylus_callback = function() return true end
    local p = newPlugin()
    p:setInputMode("stylus")
    p:setDrawing(true)
    t:eq(p.drawing, false, "drawing stayed off")
    t:eq(p.input_backend, nil, "no backend adopted")
    t:check(tostring(env.notifications[1]):find("Another plugin", 1, true) ~= nil,
            "message names the conflict")
end)

t:case("input mode cannot be changed while drawing", function()
    reset{ wacom_protocol = true }
    local p = newPlugin()
    local item = p:inputModeItem("Finger", "finger")
    t:eq(item.enabled_func(), true, "enabled while idle")
    p:setDrawing(true)
    t:eq(p.drawing, true, "drawing on")
    t:eq(item.enabled_func(), false, "disabled while drawing")

    -- The greyed-out menu item is not the guarantee; the setter is.
    p:setInputMode("finger")
    t:eq(p.input_mode, "auto", "mode unchanged while drawing")
    t:eq(_G.G_reader_settings.data.fingerink_input_mode, nil, "nothing persisted")
    t:eq(p.input_backend, "stylus", "the live backend is untouched")

    p:setDrawing(false)
    p:setInputMode("finger")
    t:eq(p.input_mode, "finger", "and it works once drawing is off")
end)

-- =====================================================================
-- main.lua : stylus state machine
-- =====================================================================

local function drawingPlugin()
    local p = realBarPlugin{ wacom_protocol = true }
    p:setDrawing(true)
    return p
end

t:describe("main / stylus state machine")

t:case("pen down, move and lift produce exactly one stroke", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    t:eq(p.input_backend, "stylus", "stylus backend active")

    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), true, "down dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 150, y = 100 })), true, "move dominated")
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), true, "lift dominated")

    local list = p.store:get(1)
    t:eq(list and #list, 1, "one stroke stored")
    t:eq(list and list[1].n, 2, "two points recorded")
end)

t:case("a frame with id=nil neither starts nor ends a stroke", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    t:eq(p:onStylusEvent(bus:set(4, { x = 10, y = 10, tool = 1 })), true, "hover consumed")
    t:eq(p.stroke, nil, "no stroke started")
    t:eq(p.stylus_active, false, "not marked active")
end)

t:case("repeated id<0 frames after a lift stay idempotent", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    -- The slot table is persistent: id stays -1 and x/y keep the last point.
    p:onStylusEvent(bus:slot(4))
    p:onStylusEvent(bus:slot(4))
    local list = p.store:get(1)
    t:eq(list and #list, 1, "still exactly one stroke")
    t:eq(p.stroke, nil, "no stroke reopened")
end)

t:case("sticky x/y on a lifted slot never paint", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    -- Two points, so the stroke is committed and a stray hover point would be
    -- visible as a third point or a second stroke.
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    local before = #Device.screen.bb.rects

    -- Hover frames keep the last coordinates around; they must not ink.
    p:onStylusEvent(bus:slot(4))
    p:onStylusEvent(bus:slot(4))
    t:eq(#Device.screen.bb.rects, before, "nothing was painted")
    t:eq(#p.store:get(1), 1, "no extra stroke")
    t:eq(p.store:get(1)[1].n, 2, "the committed stroke did not grow")
    t:eq(p.stroke, nil, "no stroke was reopened")
end)

t:case("pen slot reporting tool=FINGER with id<0 is a lift, not a point", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 140, y = 100 }))
    -- Leaving proximity: KOReader writes TOOL_TYPE_FINGER into the pen slot.
    t:eq(p:onStylusEvent(bus:set(4, { id = -1, tool = 0 })), true, "treated as a lift")
    t:eq(p.stroke, nil, "stroke closed")
    t:eq(#p.store:get(1), 1, "exactly one stroke stored")
end)

t:case("highlighter behaves as a pen in this release", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 3 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 1, "highlighter drew a normal stroke")
end)

t:case("highlighter defers to the manual tool, it is not a forced pen", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p.store:add(1, { n = 1, w = 4, 100, 100 })
    p:setEraser(true)
    -- Manual eraser on: the highlighter must erase, exactly like the pen would.
    p:onStylusEvent(bus:set(4, { id = 4, x = 105, y = 100, tool = 3 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p.store:get(1), nil, "highlighter used the manual tool")
end)

t:case("the physical eraser erases even with the manual tool set to pen", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p.store:add(1, { n = 1, w = 4, 100, 100 })
    t:eq(p.eraser, false, "manual tool is pen")

    p:onStylusEvent(bus:set(4, { id = 4, x = 105, y = 100, tool = 2 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p.store:get(1), nil, "the stroke under the eraser was removed")
end)

t:describe("main / stylus latching")

t:case("a sequence starting on the toolbar stays passthrough to the lift", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    local bx, by = bar.x + 5, bar.y + 5

    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = bx, y = by, tool = 1 })), false, "down passes through")
    t:eq(p:onStylusEvent(bus:set(4, { x = 100, y = 100 })), false, "still passthrough outside the bar")
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), false, "lift passes through too")
    t:eq(p.store:get(1), nil, "no ink at all")
end)

t:case("a sequence dragged onto the toolbar stays dominated and truncates", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), true, "down dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 150, y = 100 })), true, "move dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = bar.x + 5, y = bar.y + 5 })), true, "over the bar, still dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = bar.x + 20, y = bar.y + 20 })), true, "and stays dominated")
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), true, "lift dominated")

    local list = p.store:get(1)
    t:eq(list and #list, 1, "one stroke stored")
    t:eq(list and list[1].n, 2, "truncated at the edge: only the points outside the bar")
end)

t:case("a dialog on top hands the pen to the UI", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    showDialog("some dialog")
    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), false, "pen passes through")
    t:eq(p.store:get(1), nil, "no ink")
end)

-- =====================================================================
-- main.lua : residual touch filter
-- =====================================================================

t:describe("main / residual touch filter")

t:case("an empty residual frame changes nothing", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    -- Start a real stroke first: asserting on a stroke that was never started
    -- proves nothing about "never closes a stroke".
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    p:onStylusTouchFrame({})
    t:eq(p.n_contacts, 0, "no contacts invented")
    t:check(p.stroke ~= nil, "the in-flight stroke was neither closed nor dropped")
    t:eq(p.store:get(1), nil, "nothing was committed to the store")
end)

t:case("one finger outside the bar produces neither ink nor gesture", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 400 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 100, y = 400 } }, true,
        "its gesture is suppressed")
    t:eq(p.stroke, nil, "no ink")
end)

t:case("two fingers outside the bar produce neither ink nor gesture", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 400 })
    bus:set(1, { id = 2, x = 200, y = 400 })
    p:onStylusTouchFrame(bus:frame(0, 1))
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 100, y = 400 } }, true,
        "the first is suppressed")
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 200, y = 400 } }, true,
        "and so is the second")
    t:eq(p.n_contacts, 2, "both contacts tracked")
end)

t:case("a touch starting on the toolbar completes its tap", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    local on_bar = { ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }
    bus:set(0, { id = 1, x = bar.x + 5, y = bar.y + 5 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.passthrough, true, "the contact latched passthrough")
    t:eq(p.bar:suppresses(on_bar), false, "down reaches the toolbar")
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses(on_bar), false, "move too")
    bus:set(0, { id = -1 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses(on_bar), false, "and the lift, so the button fires")
    t:eq(p.passthrough, false, "latch released after the sequence")
end)

t:case("a palm never aborts the pen stroke in flight", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    bus:set(0, { id = 1, x = 300, y = 600 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 300, y = 600 } }, true, "palm suppressed")
    t:check(p.stroke ~= nil, "stroke survived the palm")

    p:onStylusEvent(bus:set(4, { x = 200, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p.store:get(1)[1].n, 3, "all three pen points kept")
end)

t:case("a dialog on top releases residual touch to the UI", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    showDialog("some dialog")
    bus:set(0, { id = 1, x = 100, y = 400 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.passthrough, true, "the dialog latched passthrough")
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 100, y = 400 } }, false,
        "so touch is free to reach the dialog")
end)

t:case("a pen tap on the toolbar does not release a simultaneous palm", function()
    -- This used to be a documented limitation: the emit decision was per frame
    -- and gestures carry `pos` but not `slot`, so releasing the pen's tap
    -- released the palm's gesture with it. Per gesture, position settles it.
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    p:onStylusEvent(bus:set(4, { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 }))
    t:eq(p.stylus_passthrough, true, "pen latched to passthrough")

    bus:set(0, { id = 1, x = 100, y = 400 })
    p:onStylusTouchFrame(bus:frame(0))

    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }, false,
        "the pen's tap on the toolbar travels")
    t:eq(p.bar:suppresses{ ges = "pan", pos = { x = 100, y = 400 } }, true,
        "the palm's gesture in the same frame does not")
end)

-- =====================================================================
-- main.lua : lifecycle
-- =====================================================================

t:describe("main / lifecycle")

t:case("stop releases capture and resets both state machines", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))

    p:setDrawing(false)
    t:eq(p.drawing, false, "drawing off")
    t:eq(p.input_backend, nil, "backend cleared")
    t:eq(p.stroke, nil, "stroke aborted")
    t:eq(p.stylus_active, false, "stylus state reset")
    t:eq(input.stylus_callback, nil, "callback unregistered")
    t:eq(Capture.active, false, "capture removed")
end)

t:case("suspend stops drawing", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    p:onSuspend()
    t:eq(p.drawing, false, "drawing off")
    t:eq(input.stylus_callback, nil, "callback unregistered")
end)

t:case("teardown aborts the in-flight stroke and resets contacts", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusTouchFrame(bus:frame(0))
    p.contacts[7] = true
    p.n_contacts = 1

    p:teardown()
    t:eq(p.stroke, nil, "stroke aborted, not leaked")
    t:eq(p.n_contacts, 0, "contacts reset")
    t:eq(p.stylus_active, false, "stylus state reset")
    t:eq(p.drawing, false, "drawing off")
    t:eq(input.stylus_callback, nil, "callback unregistered")
end)

t:case("a handler error disarms the plugin without taking KOReader down", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    t:eq(p.drawing, true, "drawing on")

    -- Force a failure from inside the real installed callback.
    p.onStylusEvent = function() error("synthetic handler failure") end
    local ok, res = pcall(input.stylus_callback, input, { slot = 4, id = 4 })
    env.UIManager:flush()

    t:eq(ok, true, "no error reached KOReader's input loop")
    t:eq(res, false, "degraded to not dominating")
    t:eq(p.drawing, false, "plugin disarmed")
    t:eq(p.input_backend, nil, "backend cleared")
    t:eq(input.stylus_callback, nil, "callback unregistered")
    t:eq(Capture.active, false, "capture removed")
    t:eq(#env.notifications, 1, "the user was told exactly once")
end)

t:case("drawing is never on without a toolbar", function()
    reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setBarShown(false)
    t:eq(p.bar, nil, "bar hidden")
    p:setDrawing(true)
    t:check(p.bar ~= nil, "turning drawing on brought the bar back")
    t:eq(p.drawing, true, "drawing on")
    p:setDrawing(false)
end)

-- =====================================================================
-- main.lua : finger backend regressions
-- =====================================================================

t:describe("main / finger backend regressions")

local function fingerPlugin()
    local p = realBarPlugin()   -- no wacom, not SDL => finger
    p:setDrawing(true)
    return p
end

t:case("finger backend is selected and installed", function()
    local input = reset()
    local p = newPlugin()
    p:setDrawing(true)
    t:eq(p.input_backend, "finger", "finger backend")
    t:eq(input.stylus_callback, nil, "no stylus callback registered")
end)

t:case("one contact draws", function()
    local p = fingerPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 100 })
    p:onTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 100, y = 400 } }, true,
        "gestures suppressed")
    bus:set(0, { x = 150, y = 100 })
    p:onTouchFrame(bus:frame(0))
    bus:set(0, { id = -1 })
    p:onTouchFrame(bus:frame(0))
    local list = p.store:get(1)
    t:eq(list and #list, 1, "one stroke stored")
    t:eq(list and list[1].n, 2, "two points")
end)

t:case("two contacts abort and pass through", function()
    local p = fingerPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 100 })
    p:onTouchFrame(bus:frame(0))
    t:check(p.stroke ~= nil, "stroke started")
    bus:set(1, { id = 2, x = 200, y = 200 })
    t:eq(p:onTouchFrame(bus:frame(1)), true, "second contact passes gestures through")
    t:eq(p.stroke, nil, "stroke aborted, as before")
end)

t:case("a contact starting on the toolbar passes through", function()
    local p = fingerPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    bus:set(0, { id = 1, x = bar.x + 5, y = bar.y + 5 })
    t:eq(p:onTouchFrame(bus:frame(0)), true, "emitted so the button fires")
    t:eq(p.store:get(1), nil, "no ink")
end)

t:case("onContactPoint without a tool behaves exactly as before", function()
    local p = fingerPlugin()
    p.store:add(1, { n = 1, w = 4, 100, 100 })
    -- No tool argument: the physical-eraser branch must not fire.
    p:onContactPoint(0, 105, 100)
    t:check(p.store:get(1) ~= nil, "nothing was erased")
    t:check(p.stroke ~= nil, "it drew instead")
end)

-- =====================================================================
-- auxiliary regressions
-- =====================================================================

t:describe("auxiliary regressions")

t:case("rasteriser covers horizontal, vertical and diagonal", function()
    local bb = { n = 0 }
    function bb:paintRect() self.n = self.n + 1 end
    bb.n = 0; Render.segment(bb, 0, 0, 10, 0, 2, "black")
    t:check(bb.n >= 10, "horizontal painted")
    bb.n = 0; Render.segment(bb, 0, 0, 0, 10, 2, "black")
    t:check(bb.n >= 10, "vertical painted")
    bb.n = 0; Render.segment(bb, 0, 0, 10, 10, 2, "black")
    t:check(bb.n >= 10, "diagonal painted")
    bb.n = 0; Render.segment(bb, 5, 5, 5, 5, 2, "black")
    t:eq(bb.n, 1, "degenerate segment paints one dot")
end)

t:case("store add, pop, removeAt and hit", function()
    local s = Store.new()
    s:add(3, { n = 1, w = 2, 10, 10 })
    s:add(3, { n = 1, w = 2, 50, 50 })
    t:eq(#s:get(3), 2, "two strokes")
    t:eq(Store.hit(s:get(3), 52, 50, 18), 2, "hit finds the topmost match")
    t:eq(Store.hit(s:get(3), 300, 300, 18), nil, "miss returns nil")
    t:eq(s:removeAt(3, 2), true, "removeAt works")
    t:check(s:pop(3) ~= nil, "pop returns the last stroke")
    t:eq(s:get(3), nil, "page dropped when empty")
    t:eq(s:isEmpty(), true, "store empty")
end)

t:case("persisted stroke format is unchanged and loads without migration", function()
    local legacy = { [2] = { { n = 2, w = 4, 10, 20, 30, 40 } } }
    reset()
    local p = support.newPlugin(FingerInk, env, { doc_settings = { fingerink_strokes = legacy }, page = 2 })
    env.UIManager:flush()
    local list = p.store:get(2)
    t:eq(list and #list, 1, "legacy stroke loaded")
    t:eq(list and list[1].n, 2, "point count intact")
    t:eq(list and list[1][3], 30, "coordinates intact")
end)

-- =====================================================================
-- full input-frame pipeline
--
-- The unit sections above drive onStylusEvent and onStylusTouchFrame
-- separately. Every bug in this section lived in the seam between them, so
-- these cases reproduce what Input:handleTouchEv actually does: run
-- routeStylusEvents over the frame, drop the slots the callback dominated,
-- then hand what is left to feedEvent.
-- =====================================================================

t:describe("test harness fidelity")

t:case("widget containers offer events to children before themselves", function()
    -- KOReader's WidgetContainer:handleEvent calls propagateEvent (children)
    -- first and only then its own handler. A fake with that backwards makes a
    -- toolbar button unreachable in the suite while it works on the device,
    -- or the reverse.
    reset()
    local seen = {}
    local Container = env.WidgetContainer:extend{}
    function Container:onGesture() seen[#seen + 1] = "parent" end
    local child = { handleEvent = function() seen[#seen + 1] = "child" end }
    local c = Container:new{ child }

    c:handleEvent({ handler = "onGesture", args = { {} } })

    t:eq(seen[1], "child", "the child saw the event first")
    t:eq(seen[2], "parent", "the container's own handler ran second")
end)

t:describe("full input frame pipeline")

--- Drive one whole input frame and report how many gestures reached the reader.
---
--- Since ADR-13 counting feedEvent's return value proves nothing: the detector
--- always produces its gestures and the toolbar decides which ones travel. So
--- this dispatches them the way UIManager:handleInput does and counts what got
--- through, which is the question every one of these tests is actually asking.
local function pumpFrame(input, bus, slot_specs)
    local mtslots = {}
    for _, spec in ipairs(slot_specs) do
        mtslots[#mtslots + 1] = bus:set(spec.slot, spec.fields)
    end

    -- Input:routeStylusEvents: offer every stylus slot, remove the dominated.
    local dominated = {}
    for i, slot in ipairs(mtslots) do
        if Capture:isStylusSlot(slot, input) then
            -- Core re-reads the callback on each slot; mirror that.
            if input.stylus_callback and input.stylus_callback(input, slot) then
                dominated[#dominated + 1] = i
            end
        end
    end
    for i = #dominated, 1, -1 do
        table.remove(mtslots, dominated[i])
    end

    local gd = input.gesture_detector
    local evs = gd.feedEvent(gd, mtslots)

    local before = #env.reader_events
    for i = 1, #evs do
        env.UIManager:sendEvent(env.Event:new("Gesture", evs[i]))
    end
    return #env.reader_events - before, #dominated > 0
end

local function pipelinePlugin()
    local p, _ = realBarPlugin{ wacom_protocol = true }
    p:setDrawing(true)
    return p, Device.input
end

t:case("the pen can press a toolbar button", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    local on_bar = { ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }
    local seen_before = #p.bar.draw_btn.seen

    local down_reader = pumpFrame(input, bus,
        { { slot = 4, fields = { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 } } })
    t:eq(p.bar:suppresses(on_bar), false, "the contact-down frame is the toolbar's")

    local lift_reader = pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })
    -- Taps are emitted on the lift frame. Losing this one made Draw/Stop,
    -- Pen/Eraser, Undo and Hide all unreachable with the pen.
    t:eq(p.bar:suppresses(on_bar), false, "and so is the lift frame that carries the tap")

    t:check(#p.bar.draw_btn.seen > seen_before, "the buttons were offered the gesture")
    -- What the harness cannot prove is the button's hit rectangle; the stub has
    -- no layout. Physical matrix item 8 is what covers that.
    t:eq(down_reader, 0, "the reader never saw it")
    t:eq(lift_reader, 0, "so nothing turned a page under the toolbar")
    t:eq(p.store:get(1), nil, "and no ink was left on the page")
end)

t:case("a pen stroke away from the toolbar emits nothing", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    local n1 = pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 100, y = 100, tool = 1 } } })
    local n2 = pumpFrame(input, bus, { { slot = 4, fields = { x = 150, y = 100 } } })
    local n3 = pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })

    t:eq(n1 + n2 + n3, 0, "the reader saw no gestures at all")
    t:eq(#p.store:get(1), 1, "one stroke stored")
end)

t:case("a palm during a pen stroke emits nothing and keeps the stroke", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 100, y = 100, tool = 1 } } })
    local palm = pumpFrame(input, bus, {
        { slot = 4, fields = { x = 150, y = 100 } },
        { slot = 0, fields = { id = 1, x = 300, y = 600 } },
    })
    t:eq(palm, 0, "the palm produced no gesture")
    t:check(p.stroke ~= nil, "the pen stroke survived")
end)

t:case("a timer-born hold from a suppressed contact never reaches the reader", function()
    -- `hold` and the deferred `tap` come from Input timer callbacks that never
    -- pass through feedEvent, so no filter down there can see them. The old
    -- answer was dropContact, which destroys the contact and could not be used
    -- on the finger route at all. ADR-13 catches them where they are dispatched.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local gd = input.gesture_detector

    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })

    t:check(gd:getContact(0) ~= nil, "the contact is left intact")
    t:eq(#gd.dropped, 0, "nothing was dropped")

    -- The hold arrives later, out of band, exactly as Input:waitEvent emits it.
    local before = #env.reader_events
    env.UIManager:sendEvent(env.Event:new("Gesture",
        { ges = "hold", pos = { x = 300, y = 600 } }))
    t:eq(#env.reader_events, before, "and its hold never reached the reader")
end)

t:case("a released frame keeps its contact, so the tap can still form", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local gd = input.gesture_detector
    local bar = p.bar.dimen

    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = bar.x + 5, y = bar.y + 5 } } })
    t:check(gd:getContact(0) ~= nil, "a toolbar touch keeps its contact")
end)

t:case("the finger backend never drops contacts, so two-finger gestures survive", function()
    -- ADR-2: the detector's state has to stay consistent on the legacy route.
    local input = reset()
    local p = newPlugin()
    p:setDrawing(true)
    t:eq(p.input_backend, "finger", "finger backend")
    local gd = input.gesture_detector
    local bus = support.newSlotBus()

    bus:set(0, { id = 1, x = 100, y = 100 })
    gd.feedEvent(gd, bus:frame(0))
    t:check(gd:getContact(0) ~= nil, "the drawing contact is left alone")
    t:eq(#gd.dropped, 0, "nothing was dropped")
end)

t:case("contact accounting survives a pen passthrough sequence", function()
    -- A palm that lifts while the pen owns the frame used to never be
    -- decremented, stranding n_contacts and latching passthrough on.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })
    t:eq(p.n_contacts, 1, "palm counted")

    -- Pen taps the toolbar while the palm is still down, then the palm lifts
    -- inside that window.
    pumpFrame(input, bus, {
        { slot = 4, fields = { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 } },
        { slot = 0, fields = { id = -1 } },
    })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })

    t:eq(p.n_contacts, 0, "the palm was accounted for even during passthrough")
    t:eq(p.passthrough, false, "passthrough released")
    t:eq(next(p.contacts), nil, "contact bookkeeping released")

    -- The proof that it matters: a later palm swipe must still be swallowed.
    local swipe = pumpFrame(input, bus, { { slot = 0, fields = { id = 2, x = 200, y = 500 } } })
    t:eq(swipe, 0, "a later palm still cannot turn the page")
end)

t:case("a pen on the toolbar does not latch passthrough for a palm", function()
    -- The pen slot must not be counted as residual touch. If it were, the
    -- toolbar coordinates would latch `passthrough` for the *touch* state
    -- machine, and a palm that arrives during the pen's passthrough window
    -- would keep that latch alive after the pen lifts -- turning pages.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 } } })
    t:eq(p.n_contacts, 0, "the pen is not a touch contact")

    -- Palm lands while the pen still owns the frame.
    pumpFrame(input, bus, {
        { slot = 4, fields = {} },
        { slot = 0, fields = { id = 1, x = 300, y = 600 } },
    })
    t:eq(p.n_contacts, 1, "only the palm is counted")

    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })
    t:eq(p.passthrough, false, "the pen's toolbar position never latched touch passthrough")

    -- The palm is still down. It must stay suppressed.
    local moved = pumpFrame(input, bus, { { slot = 0, fields = { x = 320, y = 620 } } })
    t:eq(moved, 0, "the palm still cannot reach the reader")
end)

t:case("a pen device on an old KOReader says so instead of falling back silently", function()
    -- The Scribe on v2026.03: the device claims a digitizer, but the runtime
    -- has no stylus API, so auto quietly drops to finger. The finger draws, the
    -- pen does nothing, and nothing on screen explains it.
    reset{ stylus_api = false, wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)

    t:eq(p.input_backend, "finger", "it still starts, on the finger route")
    t:eq(#env.notifications, 1, "and it says why, once")
    t:check(env.notifications[1]:find("v2026.07"), "naming the version needed")
end)

t:case("the fallback notice is not repeated every time drawing starts", function()
    reset{ stylus_api = false, wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    p:setDrawing(false)
    p:setDrawing(true)
    t:eq(#env.notifications, 1, "said once per session, not on every Draw")
end)

t:case("a device with no pen digitizer gets no such notice", function()
    reset{ stylus_api = false, wacom_protocol = false }
    local p = newPlugin()
    p:setDrawing(true)
    t:eq(#env.notifications, 0, "a Paperwhite has nothing to be told")
end)

t:case("the capability report explains why auto chose a backend", function()
    -- The question this answers is "the pen does nothing, why". It has to work
    -- when the stylus route is *not* running, which is the only situation in
    -- which anybody asks it.
    local input = reset{ stylus_api = false, wacom_protocol = true }
    local p = newPlugin()
    local r = p:diagnosticReport()

    t:eq(r.mode, "auto", "the configured mode")
    t:eq(r.backend, "finger", "what auto resolved to")
    t:eq(r.stylus_api, false, "the reason: no callback API in this runtime")
    t:eq(r.wacom, true, "even though the device reports a pen digitizer")
    t:check(r.blocker ~= nil, "and a blocker is named")
end)

t:case("the report names a missing digitizer as the blocker", function()
    local input = reset{ wacom_protocol = false }
    local p = newPlugin()
    local r = p:diagnosticReport()

    t:eq(r.stylus_api, true, "the runtime has the API")
    t:eq(r.wacom, false, "but the device does not claim a pen")
    t:eq(r.backend, "finger", "so auto stayed on finger")
    t:check(r.blocker ~= nil, "blocker named")
end)

t:case("the report is clean when the stylus route is available", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    local r = p:diagnosticReport()

    t:eq(r.backend, "stylus", "auto picks the pen route")
    t:eq(r.blocker, nil, "nothing to report")
end)

--- Find a menu entry by label anywhere under the plugin's menu tree.
local function menuItem(plugin, label)
    local items = {}
    plugin:addToMainMenu(items)
    local function walk(list)
        for i = 1, #list do
            local it = list[i]
            if it.text == label then return it end
            if it.sub_item_table then
                local found = walk(it.sub_item_table)
                if found then return found end
            end
        end
    end
    return walk(items.fingerink.sub_item_table)
end

t:case("the diagnostics menu entry is reachable with the pen route dead", function()
    -- It used to be gated on input_backend == "stylus", which disabled it in
    -- precisely the situation it exists for.
    local input = reset{ stylus_api = false }
    local p = newPlugin()
    t:eq(p.drawing, false, "not drawing, no backend installed")

    local item = menuItem(p, "Stylus diagnostics")
    t:check(item ~= nil, "the entry exists")
    t:check(item.enabled_func == nil or item.enabled_func(), "and it is selectable")

    item.callback()
    t:check(p.diag_until ~= nil, "armed")
    t:check(#env.logs.info > 0, "and the capability report was written")
    t:check(#env.notifications > 0 or #env.shown_messages > 0, "and shown to the user")
end)

t:case("diagnostics stop on their own", function()
    local p = pipelinePlugin()
    p:startDiagnostics()
    t:check(p.diag_until ~= nil, "diagnostics armed")

    local before = #env.logs.info
    for i = 1, 600 do p:diag({ slot = 4, id = 4, tool = 1 }, 10, i) end

    t:eq(p.diag_until, nil, "the line budget disarmed them")
    t:check(#env.logs.info - before <= 502, "and the log did not run away")
end)

t:case("diagnostics log nothing until they are armed", function()
    local p = pipelinePlugin()
    local before = #env.logs.info
    p:diag({ slot = 4, id = 4, tool = 1 }, 10, 10)
    t:eq(#env.logs.info, before, "disarmed is silent")
end)

t:case("the lift frame only contributes a point when nothing was drawn", function()
    -- The recovery exists for a contact-down frame wrongly judged stale. If it
    -- ran unconditionally it would append the lift position to every stroke,
    -- moving its end whenever the lift frame carries a fresh sample.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 100, y = 100, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { x = 200, y = 100 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1, x = 900, y = 900 } } })

    t:eq(p.store:get(p:currentPage())[1].n, 2, "the lift position was not appended")
end)

t:case("a dot placed where the last one lifted is not lost", function()
    -- The stale-coordinate guard compares the contact-down frame against the
    -- previous lift, so a pen that comes back down on the same spot is judged
    -- stale and the whole sequence produces nothing.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 400, y = 400, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = 5, x = 400, y = 400, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })

    t:eq(#p.store:get(p:currentPage()), 2, "both dots were stored")
end)

t:case("an error disarm resets the pen state machine, not just the hooks", function()
    -- disarmInput has to undo the pen's per-sequence state too. Leaving
    -- stylus_active set makes the next session's contact-down skip its own
    -- initialisation, so a stale passthrough latch silently eats the first
    -- stroke after the error.
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local d = p.bar.dimen
    p:onStylusEvent(bus:set(4, { id = 4, x = d.x + 5, y = d.y + 5, tool = 1 }))
    t:eq(p.stylus_passthrough, true, "latched over the toolbar mid-sequence")

    Capture:fail("boom")
    env.UIManager:flush()
    t:eq(p.stylus_active, false, "the pen sequence was closed out")
    t:eq(p.stylus_passthrough, false, "and its latch released")

    p:setDrawing(true)
    local next_bus = support.newSlotBus()
    p:onStylusEvent(next_bus:set(4, { id = 9, x = 400, y = 400, tool = 1 }))
    p:onStylusEvent(next_bus:set(4, { x = 450, y = 400 }))
    p:onStylusEvent(next_bus:set(4, { id = -1 }))
    t:eq(#p.store:get(p:currentPage()), 1, "the next session's first stroke survives")
end)

t:case("an error disarm leaves nothing released behind it", function()
    -- Before ADR-13 a raise mid-frame skipped the bookkeeping that cleared the
    -- pen's per-frame flag, and the first residual frame of the next session
    -- was let through. There is no such flag any more; this pins the invariant
    -- it existed to protect.
    local p, input = pipelinePlugin()

    Capture:fail("boom")
    env.UIManager:flush()
    t:eq(p.drawing, false, "the error stopped drawing")

    p:setDrawing(true)
    local bus = support.newSlotBus()
    local n = pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })
    t:eq(n, 0, "the first palm frame after restarting is still suppressed")
end)

t:case("a resting palm does not make the toolbar unreachable", function()
    -- The palm lands first, off the toolbar, and used to latch the geometry
    -- decision for every later contact in the sequence. Stop is the only way
    -- out of stylus drawing mode, so losing that tap is a lock-out.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })

    local n = pumpFrame(input, bus,
        { { slot = 1, fields = { id = 2, x = bar.x + 5, y = bar.y + 5 } } })

    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }, false,
        "the toolbar tap survives a resting palm")
    t:eq(n, 0, "and it went to the toolbar, not the reader")
    t:eq(p.passthrough, true, "the bar contact latched passthrough on its own slot")
    t:eq(p.contacts[0], "page", "the palm is remembered as off-bar")
    t:eq(p.contacts[1], "bar", "the finger is remembered as on-bar")
end)

t:describe("main / stale coordinates and mid-stroke dialogs")

t:case("a contact-down frame carrying the previous stroke's coordinates never inks", function()
    -- ev_slots entries are persistent; a BTN_TOUCH-only frame still presents
    -- the position where the last sequence ended.
    local p = drawingPlugin()
    local bus = support.newSlotBus()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 140, y = 140 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 1, "first stroke committed")

    -- New contact, no fresh coordinates: x/y are still 140,140.
    p:onStylusEvent(bus:set(4, { id = 4 }))
    t:eq(p.stroke, nil, "no phantom point was painted from the stale position")

    -- Real coordinates arrive on the next frame and the stroke starts there.
    p:onStylusEvent(bus:set(4, { x = 400, y = 400 }))
    t:check(p.stroke ~= nil, "the stroke starts from the real position")
    t:eq(p.stroke[1], 400, "and at the right x")
end)

t:case("a stale contact-down over the toolbar does not swallow the next stroke", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    -- End a stroke by dragging onto the bar, so the lift position is inside it.
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = bar.x + 5, y = bar.y + 5 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))

    -- Next contact-down repeats those coordinates without meaning to.
    p:onStylusEvent(bus:set(4, { id = 4 }))
    t:eq(p.stylus_passthrough, false, "the stale bar position did not latch passthrough")
    p:onStylusEvent(bus:set(4, { x = 200, y = 200 }))
    p:onStylusEvent(bus:set(4, { x = 250, y = 200 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 2, "the second stroke was drawn, not lost")
end)

t:case("a dialog opening mid-stroke stops the ink but keeps the slot", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    showDialog("a dialog that just opened")
    t:eq(p:onStylusEvent(bus:set(4, { x = 200, y = 100 })), true,
         "still dominating: handing the slot back mid-sequence corrupts the detector")
    t:eq(p.stroke, nil, "the stroke was aborted rather than drawn over the dialog")

    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), true, "lift stays dominated")
    t:eq(p.store:get(1), nil, "nothing was committed")
end)

t:case("a failed start does not force the toolbar on", function()
    reset{ stylus_api = false }
    local p = newPlugin()
    p:setBarShown(false)
    _G.G_reader_settings.data.fingerink_bar_shown = false
    p:setInputMode("stylus")

    p:setDrawing(true)
    t:eq(p.drawing, false, "drawing stayed off")
    t:eq(p.bar, nil, "the toolbar was not forced on")
    t:eq(_G.G_reader_settings.data.fingerink_bar_shown, false, "the preference was not rewritten")
end)

-- =====================================================================
-- ink_bar.lua, the real widget
-- =====================================================================

t:describe("ink_bar (real widget)")

t:case("builds four buttons and a screen-relative geometry", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    t:check(bar.draw_btn ~= nil and bar.tool_btn ~= nil, "stateful buttons exist")
    t:check(bar.undo_btn ~= nil and bar.hide_btn ~= nil, "action buttons exist")
    t:check(bar.dimen.w > 0 and bar.dimen.h > 0, "the bar has a size")
    t:check(bar.dimen.x + bar.dimen.w <= Device.screen:getWidth(), "it fits on screen")

    local left = newRealBar(p, "left")
    t:check(left.dimen.x < bar.dimen.x, "the left side really is further left")
end)

t:case("contains() matches its own dimen", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    local d = bar.dimen
    t:eq(bar:contains(d.x, d.y), true, "top-left corner is inside")
    t:eq(bar:contains(d.x + d.w - 1, d.y + d.h - 1), true, "bottom-right corner is inside")
    t:eq(bar:contains(d.x - 1, d.y), false, "one pixel left is outside")
    t:eq(bar:contains(d.x + d.w, d.y), false, "the far edge is exclusive")
end)

t:case("swallows gestures that hit the bar but miss every button", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    local d = bar.dimen
    -- Without this the border and inter-button gaps would forward a tap to the
    -- reader underneath and turn a page.
    t:eq(bar:onGesture{ pos = { x = d.x + 1, y = d.y + 1 } }, true, "consumed inside the bar")
    -- Falsy, not nil: outside the bar the answer now comes from `suppresses`,
    -- and with drawing off that is an explicit false. handleEvent treats both
    -- the same, but the test should say which one it expects.
    t:eq(bar:onGesture{ pos = { x = d.x - 20, y = d.y } }, false, "not consumed outside")
    t:eq(bar:onGesture{}, false, "a gesture with no position is left alone while idle")

    -- And through the real dispatch path, the buttons get first refusal:
    -- KOReader offers an event to a container's children before the container
    -- itself, so onGesture only ever sees what no button wanted.
    env.UIManager._window_stack = { { widget = { handleEvent = function() return true end } },
                                    { widget = bar } }
    bar:handleEvent(env.Event:new("Gesture", { pos = { x = d.x + 1, y = d.y + 1 } }))
    t:eq(bar.draw_btn.seen[1], "onGesture", "the buttons were offered it first")
    env.UIManager._window_stack = {}
end)

t:case("windowBelow skips toasts and finds the reader", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    local reader = { name = "reader" }
    local toast = { name = "toast", toast = true }
    env.UIManager._window_stack = { { widget = reader }, { widget = toast }, { widget = bar } }
    t:eq(bar:windowBelow(), reader, "the toast above the reader is skipped")

    local dialog = { name = "dialog" }
    env.UIManager._window_stack = { { widget = reader }, { widget = dialog }, { widget = bar } }
    t:eq(bar:windowBelow(), dialog, "an actual dialog is returned")
    env.UIManager._window_stack = {}
end)

t:case("forwards input it does not want to the window below", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    local seen = {}
    local below = {
        handleEvent = function(_, event) seen[#seen + 1] = event.handler; return true end,
    }
    env.UIManager._window_stack = { { widget = below }, { widget = bar } }

    -- A gesture outside the bar is forwarded...
    t:eq(bar:handleEvent(env.Event:new("Gesture", { pos = { x = 5, y = 5 } })), true, "forwarded")
    t:eq(seen[1], "onGesture", "the reader saw the gesture")
    -- ...and so are key events, which never reach a non-topmost window.
    bar:handleEvent(env.Event:new("KeyPress", {}))
    t:eq(seen[2], "onKeyPress", "key presses reach the reader too")

    -- Events that are not input handlers are not forwarded.
    local before = #seen
    bar:handleEvent(env.Event:new("SomethingElse"))
    t:eq(#seen, before, "non-input events are left alone")
    env.UIManager._window_stack = {}
end)

t:describe("spike / widget-layer gesture visibility")

--- A Gesture event as UIManager builds it: rotation already applied by
--- adjustGesCoordinate, so `pos` is in screen coordinates.
local function gestureEvent(x, y, name)
    return env.Event:new("Gesture", { ges = name or "tap", pos = { x = x, y = y } })
end

t:case("a gesture reaches the bar while it is topmost", function()
    local p, bar = realBarPlugin()

    local seen = {}
    local original = bar.onGesture
    bar.onGesture = function(self, ges) seen[#seen + 1] = ges; return original(self, ges) end

    env.UIManager:sendEvent(gestureEvent(300, 600))

    t:eq(#seen, 1, "the bar saw the gesture")
    t:eq(seen[1].pos.x, 300, "position arrives in screen coordinates")
end)

t:case("a dialog above the bar takes the gesture instead", function()
    local p, bar = realBarPlugin()

    local seen = 0
    local original = bar.onGesture
    bar.onGesture = function(self, ges) seen = seen + 1; return original(self, ges) end

    local dialog_got = false
    env.UIManager:show({ handleEvent = function() dialog_got = true; return true end })

    env.UIManager:sendEvent(gestureEvent(300, 600))

    t:eq(seen, 0, "the bar never saw it")
    t:eq(dialog_got, true, "the dialog did")
end)

t:case("bar membership is decidable from ges.pos alone", function()
    local _, bar = realBarPlugin()
    local d = bar.dimen
    t:eq(bar:contains(d.x + 5, d.y + 5), true, "inside needs no transform")
    t:eq(bar:contains(d.x - 50, d.y + 5), false, "outside needs no transform")
end)

t:describe("widget-layer suppression")

t:case("a timer-born hold is swallowed while drawing", function()
    -- hold never passes through feedEvent: Input:waitEvent dispatches it
    -- straight from a setTimeout callback. This layer is the only one that
    -- sees it. c.f. gesturedetector.lua:675 and input.lua:1584 @ v2026.07.
    local p = realBarPlugin()
    p:setDrawing(true)

    local consumed = env.UIManager:sendEvent(gestureEvent(300, 600, "hold"))

    t:eq(consumed, true, "the hold was consumed by the bar")
    t:eq(#env.reader_events, 0, "the reader never saw it")
end)

t:case("a gesture aimed at the toolbar is not swallowed", function()
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    local d = bar.dimen
    t:eq(bar:suppresses{ ges = "tap", pos = { x = d.x + 5, y = d.y + 5 } }, false,
        "the toolbar keeps its taps")
end)

t:case("a palm gesture is suppressed even when the pen taps the bar", function()
    -- The old per-frame decision released both, because gestures carry a
    -- position but not a slot. Position is per gesture; the frame is not.
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    local d = bar.dimen
    t:eq(bar:suppresses{ ges = "tap", pos = { x = d.x + 5, y = d.y + 5 } }, false,
        "the pen's tap on the bar survives")
    t:eq(bar:suppresses{ ges = "pan", pos = { x = 300, y = 600 } }, true,
        "the palm's pan in the same frame does not")
end)

t:case("a gesture with no position is suppressed while drawing", function()
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    t:eq(bar:suppresses{ ges = "multiswipe" }, true, "unattributable, so suppressed")
end)

t:case("nothing is suppressed once drawing is off", function()
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    p:setDrawing(false)
    t:eq(bar:suppresses{ ges = "tap", pos = { x = 300, y = 600 } }, false,
        "reading works again")
    t:eq(env.UIManager:sendEvent(gestureEvent(300, 600)), true, "and the reader gets it")
    t:eq(env.reader_events[1], "onGesture", "by name")
end)

t:case("passthrough releases gestures without turning drawing off", function()
    -- The finger route's two-finger escape, and the residual filter's dialog
    -- latch, both work by setting passthrough. Suppression has to honour it.
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    p.passthrough = true
    t:eq(bar:suppresses{ ges = "tap", pos = { x = 300, y = 600 } }, false,
        "a passthrough sequence reaches the reader")
end)

t:case("relabels Draw/Stop and Pen/Eraser from plugin state", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    p.drawing, p.eraser = false, false
    bar:update(false)
    t:eq(bar.draw_btn.text, "Draw", "idle label")
    t:eq(bar.tool_btn.text, "Pen", "pen label")
    p.drawing, p.eraser = true, true
    bar:update(false)
    t:eq(bar.draw_btn.text, "Stop", "drawing label")
    t:eq(bar.tool_btn.text, "Eraser", "eraser label")
end)

-- =====================================================================
-- Canvas suites
--
-- The canvas is a separate story from input capture and the toolbar, and
-- those two already make this the longest file in the plugin. Each canvas
-- module gets its own spec file; they are handed the same runner and the
-- same fakes, so a failure reads identically wherever it comes from.
-- =====================================================================

local ctx = {
    t = t,
    env = env,
    support = support,
    Device = Device,
    plugin_dir = plugin_dir,
    tests_dir = tests_dir,
    reset = reset,
    newPlugin = newPlugin,
    newRealBar = newRealBar,
    realBar = realBar,
    realBarPlugin = realBarPlugin,
    showDialog = showDialog,
}

for _, spec in ipairs({
    "canvas_codec_spec",
    "canvas_repository_spec",
    "canvas_anchor_spec",
    "canvas_geometry_spec",
    "canvas_cache_spec",
    "canvas_overlay_spec",
    "canvas_router_spec",
    "capture_filter_spec",
}) do
    dofile(tests_dir .. "/" .. spec .. ".lua")(ctx)
end

os.exit(t:report() and 0 or 1)
