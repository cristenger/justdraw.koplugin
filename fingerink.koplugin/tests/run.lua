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
    Device.screen.bb.rects = {}
    env.notifications = {}
    env.window_below = nil
    env.UIManager._window_stack = {}
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
    local ok, evs = pcall(wrapper, gd, {})
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
    local bus = support.newSlotBus()
    -- Start a real stroke first: asserting on a stroke that was never started
    -- proves nothing about "never closes a stroke".
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 100 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    t:eq(p:onStylusTouchFrame({}), false, "nothing to emit")
    t:eq(p.n_contacts, 0, "no contacts invented")
    t:check(p.stroke ~= nil, "the in-flight stroke was neither closed nor dropped")
    t:eq(p.store:get(1), nil, "nothing was committed to the store")
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

--- Returns: gestures emitted for this frame, and whether the pen was dominated.
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
    return #evs, #dominated > 0
end

local function pipelinePlugin()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)
    return p, input
end

t:case("the pen can press a toolbar button", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    local down_evs = pumpFrame(input, bus,
        { { slot = 4, fields = { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 } } })
    local lift_evs = pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })

    t:check(down_evs > 0, "the contact-down frame reaches the detector")
    -- Taps are emitted on the lift frame. Losing this one made Draw/Stop,
    -- Pen/Eraser, Undo and Hide all unreachable with the pen.
    t:check(lift_evs > 0, "the lift frame carries the tap to the button")
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

t:case("suppressing a frame drops the contacts, killing their hold timers", function()
    -- Emptying feedEvent's return array is not enough: `hold` and the deferred
    -- `tap` come from Input timer callbacks that never pass through feedEvent.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local gd = input.gesture_detector

    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })
    t:eq(gd:getContact(0), nil, "the palm's contact was dropped")
    t:check(#gd.dropped >= 1, "dropContact was called")
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

t:case("an error disarm does not leave the pen's frame flag set", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)

    -- A raise inside the stylus handler returns the guard's fail value without
    -- ever reaching stylusFrameResult, so the flag keeps whatever it held.
    p.stylus_frame_ui = true
    Capture:fail("boom")
    env.UIManager:flush()

    t:eq(p.stylus_frame_ui, false, "the per-frame flag was cleared with the rest")

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

    t:check(n > 0, "the toolbar tap survives a resting palm")
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

    env.window_below = { name = "a dialog that just opened" }
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

local RealInkBar = dofile(plugin_dir .. "/ink_bar.lua")

local function newRealBar(plugin, side)
    return RealInkBar:new{ plugin = plugin, side = side or "right" }
end

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
    t:eq(bar:onGesture{ pos = { x = d.x - 20, y = d.y } }, nil, "not consumed outside")
    t:eq(bar:onGesture{}, nil, "a gesture with no position is left alone")

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

os.exit(t:report() and 0 or 1)
