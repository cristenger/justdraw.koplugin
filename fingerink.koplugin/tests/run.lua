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
    Capture:remove()
    Device.input = support.newInput(input_opts)
    Device._is_sdl = false
    Device.screen.rotation = 0
    Device.screen.touch_rotation = nil
    Device.screen.refreshes = {}
    Device.screen.bb.rects = {}
    env.notifications = {}
    env.window_below = nil
    _G.G_reader_settings.data = {}
    return Device.input
end

local function newPlugin(opts)
    local p = support.newPlugin(FingerInk, env, opts)
    env.UIManager:flush()   -- let the deferred setBarShown run
    return p
end

-- =====================================================================
-- ink_capture.lua
-- =====================================================================

t:describe("ink_capture / stylus API detection")

t:case("missing stylus API", function()
    local input = reset{ stylus_api = false }
    t:eq(Capture:supportsStylus(), false, "supportsStylus is false without the API")
    local ok, reason = Capture:installStylus(function() end, function() end)
    t:eq(ok, false, "installStylus refuses")
    t:eq(reason, "no_stylus_api", "reason is no_stylus_api")
    t:eq(input.stylus_callback, nil, "nothing was registered")
    t:check(input.gesture_detector.feedEvent ~= nil, "feedEvent untouched")
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

t:case("residual handler returning false empties the gesture array", function()
    local input = reset()
    local gd = input.gesture_detector
    Capture:installStylus(function() return true end, function() return false end)
    local evs = gd.feedEvent(gd, {})
    t:eq(gd.calls, 1, "original feedEvent was still called")
    t:eq(#evs, 0, "gestures suppressed")
end)

t:case("residual handler returning true keeps the gesture array", function()
    local input = reset()
    local gd = input.gesture_detector
    Capture:installStylus(function() return true end, function() return true end)
    local evs = gd.feedEvent(gd, {})
    t:eq(gd.calls, 1, "original feedEvent was called")
    t:eq(#evs, 1, "gestures preserved")
end)

t:case("finger backend keeps its existing semantics", function()
    local input = reset()
    local gd = input.gesture_detector
    local seen
    local ok, backend = Capture:installFinger(function(slots) seen = slots; return false end)
    t:eq(ok, true, "install succeeded")
    t:eq(backend, "finger", "backend reported")
    t:eq(input.stylus_callback, nil, "finger backend registers no stylus callback")
    local frame = { { slot = 0 } }
    local evs = gd.feedEvent(gd, frame)
    t:eq(seen, frame, "handler saw the frame")
    t:eq(#evs, 0, "gestures suppressed")
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
    local evs = gd.feedEvent(gd, {})
    t:eq(handler_calls, 0, "our handler no longer runs")
    t:eq(#evs, 1, "our wrapper passes gestures through unchanged")
    t:check(gd.calls >= 1, "original feedEvent still reached")
    t:check(original_feed ~= nil, "original captured")
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
    t:eq(errors, 1, "on_error fired exactly once")
    t:eq(input.stylus_callback, nil, "callback unregistered")
    t:eq(Capture.active, false, "capture disarmed")
end)

t:case("a throwing residual handler does not escape and disarms capture", function()
    local input = reset()
    local gd = input.gesture_detector
    local errors = 0
    Capture:installStylus(function() return true end,
                          function() error("boom") end,
                          function() errors = errors + 1 end)
    local wrapper = gd.feedEvent
    local ok, evs = pcall(wrapper, gd, {})
    t:eq(ok, true, "error did not propagate to KOReader")
    t:eq(#evs, 1, "safe return value emits: gestures reach the reader")
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
    p:setDrawing(false)
end)

-- =====================================================================
-- main.lua : stylus state machine
-- =====================================================================

local function drawingPlugin()
    reset{ wacom_protocol = true }
    local p = newPlugin()
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
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    local before = #Device.screen.bb.rects
    -- Hover frames keep the last coordinates around; they must not ink.
    p:onStylusEvent(bus:slot(4))
    p:onStylusEvent(bus:slot(4))
    t:eq(#Device.screen.bb.rects, before, "nothing was painted")
    t:eq(#p.store:get(1), 1, "no extra stroke")
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
    env.window_below = { name = "some dialog" }
    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), false, "pen passes through")
    t:eq(p.store:get(1), nil, "no ink")
end)

-- =====================================================================
-- main.lua : residual touch filter
-- =====================================================================

t:describe("main / residual touch filter")

t:case("an empty residual frame changes nothing", function()
    local p = drawingPlugin()
    t:eq(p:onStylusTouchFrame({}), false, "nothing to emit")
    t:eq(p.n_contacts, 0, "no contacts invented")
    t:eq(p.stroke, nil, "no stroke touched")
end)

t:case("one finger outside the bar produces neither ink nor gesture", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 400 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), false, "gestures suppressed")
    t:eq(p.stroke, nil, "no ink")
end)

t:case("two fingers outside the bar produce neither ink nor gesture", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    bus:set(0, { id = 1, x = 100, y = 400 })
    bus:set(1, { id = 2, x = 200, y = 400 })
    t:eq(p:onStylusTouchFrame(bus:frame(0, 1)), false, "still suppressed")
    t:eq(p.n_contacts, 2, "both contacts tracked")
end)

t:case("a touch starting on the toolbar completes its tap", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    bus:set(0, { id = 1, x = bar.x + 5, y = bar.y + 5 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), true, "down emitted")
    t:eq(p:onStylusTouchFrame(bus:frame(0)), true, "move emitted")
    bus:set(0, { id = -1 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), true, "lift emitted so the button fires")
    t:eq(p.passthrough, false, "latch released after the sequence")
end)

t:case("a palm never aborts the pen stroke in flight", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    bus:set(0, { id = 1, x = 300, y = 600 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), false, "palm suppressed")
    t:check(p.stroke ~= nil, "stroke survived the palm")

    p:onStylusEvent(bus:set(4, { x = 200, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p.store:get(1)[1].n, 3, "all three pen points kept")
end)

t:case("a dialog on top releases residual touch to the UI", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    env.window_below = { name = "some dialog" }
    bus:set(0, { id = 1, x = 100, y = 400 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), true, "touch reaches the UI")
end)

t:case("known limitation: a passthrough pen frame also releases a simultaneous palm", function()
    -- Gestures carry `pos` but not `slot`, so the emit decision is per frame.
    -- This test pins the current behaviour so any future change is deliberate.
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    p:onStylusEvent(bus:set(4, { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 }))
    t:eq(p.stylus_passthrough, true, "pen latched to passthrough")
    bus:set(0, { id = 1, x = 100, y = 400 })
    t:eq(p:onStylusTouchFrame(bus:frame(0)), true, "whole frame emitted, palm included")
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

    t:eq(ok, true, "no error reached KOReader's input loop")
    t:eq(res, false, "degraded to not dominating")
    t:eq(p.drawing, false, "plugin disarmed")
    t:eq(p.input_backend, nil, "backend cleared")
    t:eq(input.stylus_callback, nil, "callback unregistered")
    t:eq(Capture.active, false, "capture removed")
    t:check(#env.notifications >= 1, "the user was told once")
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
    reset()   -- no wacom, not SDL => finger
    local p = newPlugin()
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
    t:eq(p:onTouchFrame(bus:frame(0)), false, "gestures suppressed")
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

os.exit(t:report() and 0 or 1)
