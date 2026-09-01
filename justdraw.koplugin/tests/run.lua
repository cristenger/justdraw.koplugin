--[[--
JustDraw input regression suite.

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
local JustDraw = require("main")

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
    local p = support.newPlugin(JustDraw, env, opts)
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

t:case("diagnostics report the frames the steer moved and the evdev drops", function()
    reset{ wacom_protocol = true }
    local p = newPlugin()
    local lines = table.concat(p:diagnosticLines(), "\n")
    t:eq(lines:match("Pen frames steered back to the pen slot: (%d+)"), "0", "pen line, idle")
    t:eq(lines:match("Hand frames kept off the pen slot: (%d+)"), "0", "panel line, idle")
    t:eq(lines:match("Input events the kernel dropped: (%d+)"), "0", "drops line, idle")
end)

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

t:case("a stale deferred removal never tears down a newer capture", function()
    local input = reset()
    local stale_cleanup = 0
    Capture:installStylus(function() return true end,
                          function() return false end)

    Capture:removeDeferred(function() stale_cleanup = stale_cleanup + 1 end)
    Capture:remove()
    local installed = Capture:installStylus(function() return true end,
                                             function() return false end)
    local newer_callback = input.stylus_callback

    env.UIManager:flush()
    t:eq(installed, true, "the replacement capture installed")
    t:eq(Capture.active, true, "the replacement stayed active")
    t:eq(input.stylus_callback, newer_callback,
        "the stale tick did not unregister the replacement callback")
    t:eq(stale_cleanup, 0, "cleanup tied to the old generation was discarded")
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
    t:eq(_G.G_reader_settings.data.justdraw_input_mode, nil, "nothing persisted")
    t:eq(p.input_backend, "stylus", "the live backend is untouched")

    p:setDrawing(false)
    p:setInputMode("finger")
    t:eq(p.input_mode, "finger", "and it works once drawing is off")
end)

-- =====================================================================
-- main.lua : stylus state machine
-- =====================================================================

--- `limits` has to be applied before drawing starts: InkStylusSequence
--- snapshots the budgets of the lease it is built for rather than re-reading
--- two plugin fields on every sample.
local function drawingPlugin(limits)
    local p = realBarPlugin{ wacom_protocol = true }
    if limits then
        if limits.max_open_points then p.max_open_points = limits.max_open_points end
        if limits.max_contact_samples then
            p.max_contact_samples = limits.max_contact_samples
        end
    end
    p:setDrawing(true)
    return p
end

--[[--
A note that applies to every pen sequence below.

KOReader hands the callback its own persistent slot table and writes X and Y
into it independently, so a contact-down frame presents whatever the previous
contact left there. InkStylusGeometry therefore treats the first pair of a
contact as a baseline and draws from the first pair that has moved on *both*
axes -- which is also why these fixtures move both, the way a digitizer does.
The classification latch (draw / pass / block) moves with it: it is decided on
the first coherent point, not on the contact-down frame.
]]

t:describe("main / stylus state machine")

t:case("pen down, move and lift produce exactly one stroke", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    t:eq(p.input_backend, "stylus", "stylus backend active")

    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), true, "down dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 150, y = 120 })), true, "first coherent point dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 200, y = 140 })), true, "move dominated")
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), true, "lift dominated")

    local list = p.store:get(1)
    t:eq(list and #list, 1, "one stroke stored")
    t:eq(list and list[1].n, 2, "two points recorded")
end)

--[[--
The blind window a re-render opens, and why a lost lift is worse on Wacom.

`Input:inhibitInput(true)` swaps `handleTouchEv` for a sink, and
`routeStylusEvents` is called from inside it, so no frame reaches this route at
all while it holds -- the lift included. readerrolling opens exactly such a
window around a re-render and broadcasts `DocumentRerendered` from inside it.

The pen's tracking id is pinned: KOReader writes `pen_slot` on BTN_TOUCH down
and -1 on lift, and nothing else, so two consecutive contacts are the same slot
carrying the same id. With the lift gone there is nothing left to tell them
apart, and the next contact-down would be appended to the stroke that was
already open -- one line straight across the page.
]]
t:case("a re-render ends the contact the capture can no longer see lift", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
    t:eq(p:hasActivePhysicalContact(), true, "a contact is open")

    p:onDocumentRerendered()
    t:eq(p:hasActivePhysicalContact(), false,
        "the contact ends with the frames that would have closed it")
    t:eq(p.stroke, nil, "and the stroke in flight is dropped, not left dangling")
    t:eq(p.store:get(1), nil, "nothing partial reached the store")

    -- The same slot and the same pinned id, which is all a Scribe ever sends.
    -- The boundary went with the contact, deliberately: a coordinate from
    -- before the window names a place the pen may have left long ago. So this
    -- contact proves where it is the way a lease's first one does, and its ink
    -- starts at the first pair it can trust -- one dot's worth of caution in
    -- exchange for never drawing a line the pen did not.
    p:onStylusEvent(bus:set(4, { id = 4, x = 900, y = 900, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 950, y = 960 }))
    p:onStylusEvent(bus:set(4, { x = 980, y = 990 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))

    local list = p.store:get(1)
    t:eq(list and #list, 1, "the contact after the window is its own stroke")
    t:eq(list and list[1].n, 2, "carrying only points from after the window")
    t:eq(list and list[1][1], 950, "starting at the first pair it could trust")
    t:eq(list and list[1][2], 960, "on both axes")
    t:check(list and list[1][1] ~= 200 and list[1][2] ~= 140,
        "and nowhere near where the abandoned contact was")
end)

--[[--
A forwarded contact has to end too, and the drop that would end it cannot work.

`inhibitInput` runs `Input:resetState` before the re-render event is dispatched,
which drops GestureDetector's contacts. So the hand-back this sequence would
normally perform fails -- and a failed hand-back normally means the opposite of
what it means here: a contact somebody else still owns, which must not be
forgotten. Without telling the sequence which case it is in, it latches
`forwarded_wait_lift` and `hasActivePhysicalContact` never goes false again:
notebooks stay unreachable and the next pen contact is forwarded instead of
drawing.
]]
t:case("a re-render ends a contact the detector no longer owns", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    t:eq(p:onStylusEvent(bus:set(4, {
        id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1,
    })), false, "a contact on the toolbar is handed to the UI")
    t:eq(p:hasActivePhysicalContact(), true, "and is still physically down")

    -- What inhibitInput did before the event reached us.
    env.Device.input.gesture_detector.contacts = {}

    p:onDocumentRerendered()
    t:eq(p:hasActivePhysicalContact(), false,
        "the forwarded contact ends even though it could not be handed back")
    t:eq(p.stylus_sequence.state, "idle", "the sequence is not left latched")

    p:onStylusEvent(bus:set(4, { id = 4, x = 300, y = 300, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 400, y = 380 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 1, "and the next contact draws instead of forwarding")
end)

--- The notebook editor runs its own contact machine over the same digitizer and
--- can be open above a document, so the blind window reaches it too.
t:case("a re-render reaches the notebook contact machine as well", function()
    local p = drawingPlugin()
    local aborted = 0
    p.notebook_input = {
        hasActiveContact = function() return true end,
        abort = function() aborted = aborted + 1; return true end,
    }
    p:onDocumentRerendered()
    t:eq(aborted, 1, "the notebook adapter was told exactly once")

    p.notebook_input = {
        hasActiveContact = function() return false end,
        abort = function() aborted = aborted + 1; return true end,
    }
    p:onDocumentRerendered()
    t:eq(aborted, 1, "with nothing on the glass it is left alone")
end)

--[[--
The eraser counters are wired to the route, not only to themselves.

A unit test of Capture's counters passes whether or not anything calls them --
which is how a bump that fired several times per contact went unnoticed. This
drives a real erase contact through the host and reads the numbers back.
]]
t:case("an erase contact is counted once, by where the tool came from", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    Capture:resetEraserCounts()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 2 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
    p:onStylusEvent(bus:set(4, { x = 260, y = 190 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    local by_button, by_tool = Capture:eraserCounts()
    t:eq(by_button, 0, "no barrel button was held")
    t:eq(by_tool, 1, "one erase contact, counted once")

    p:onStylusEvent(bus:set(4, { id = 4, x = 500, y = 500, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 600, y = 560 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    by_button, by_tool = Capture:eraserCounts()
    t:eq(by_tool, 1, "an ink contact adds nothing")
end)

--[[--
The collapse ADR-22 accepts is now counted, so a log can confirm it.

A contact that never moves one axis away from the previous boundary finishes as
a single dot. That is the documented trade-off of the axis policy -- and "my
underline came out a point" is not diagnosable from a log unless something
counts it happening.
]]
t:case("a contact that collapses to a dot is counted, a stroke is not", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    Capture:resetCollapsedCounts()

    -- A contact that only ever moves X: its Y never differs from the boundary
    -- the contact-down frame presented, so it finishes as one dot.
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 100 }))
    p:onStylusEvent(bus:set(4, { x = 300, y = 100 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    local dots, discards = Capture:collapsedCounts()
    t:eq(dots, 1, "the axis-collapsed contact counted as a dot")
    t:eq(discards, 0, "it had a position, so it is not a discard")
    t:eq(#p.store:get(1), 1, "and its single dot was still delivered")

    -- An ordinary two-axis stroke proves its geometry and counts nothing.
    p:onStylusEvent(bus:set(4, { id = 4, x = 400, y = 400, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 500, y = 460 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    dots, discards = Capture:collapsedCounts()
    t:eq(dots, 1, "a proven stroke adds nothing")

    -- A contact on the toolbar is the UI's tap, not a collapse.
    local bar = p.bar.dimen
    p:onStylusEvent(bus:set(4, { id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    dots, discards = Capture:collapsedCounts()
    t:eq(dots, 1, "a passed contact is not a collapse")
    t:eq(discards, 0, "on either count")
end)

t:case("a re-render with nothing on the glass changes nothing", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 1, "one stroke stored")

    p:onDocumentRerendered()
    t:eq(#p.store:get(1), 1, "the stored stroke is untouched")
    t:eq(p:hasActivePhysicalContact(), false, "and nothing is owed a lift")

    p:onStylusEvent(bus:set(4, { id = 4, x = 300, y = 300, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 400, y = 380 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 2, "and the route still works afterwards")
end)

t:case("an over-budget direct stroke is repaired and owns through lift", function()
    local p = drawingPlugin{ max_open_points = 2 }
    local bus = support.newSlotBus()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 120 }))
    p:onStylusEvent(bus:set(4, { x = 300, y = 140 }))
    t:eq(p:onStylusEvent(bus:set(4, { x = 400, y = 160 })), true,
        "over-budget frame remains dominated")
    t:eq(p.stroke, nil, "the complete live stroke was abandoned")
    t:eq(p.store:get(1), nil, "no prefix was persisted")
    t:eq(p:hasActivePhysicalContact(), true, "physical contact remains owned")
    t:eq(p.stylus_sequence.state, "suspended", "host work is suspended until lift")
    t:eq(#env.notifications, 0, "notification is not opened inside the callback")
    env.UIManager:flush()
    t:eq(#env.notifications, 1, "one deferred notice is visible")
    t:check(env.notifications[1]:find("Stroke stopped", 1, true) ~= nil,
        "the notice explains the orphaned contact")

    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p:hasActivePhysicalContact(), false, "lift releases ownership")
    -- Left of the toolbar: the six-button bar spans the screen's vertical
    -- middle, and a contact starting on it is passthrough, not ink.
    p:onStylusEvent(bus:set(4, { id = 5, x = 300, y = 300, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 400, y = 400 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 1, "the next physical contact works")
end)

t:case("the sample cap preserves direct erases and stops further work", function()
    local p = drawingPlugin{ max_contact_samples = 2 }
    local bus = support.newSlotBus()
    p.store:add(1, { n = 1, w = 4, 100, 100 })

    p:onStylusEvent(bus:set(4, { id = 4, x = 105, y = 100, tool = 2 }))
    p:onStylusEvent(bus:set(4, { x = 106, y = 101 }))
    p:onStylusEvent(bus:set(4, { x = 107, y = 102 }))
    t:eq(p.store:get(1), nil, "accepted eraser work is not rolled back")
    t:eq(p.stylus_sequence.sample_count, 2, "sample counter saturates at its bound")
    t:eq(p.stylus_sequence.state, "suspended", "further samples do no host work")
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(p:hasActivePhysicalContact(), false, "lift rearms the route")
end)

t:case("a passed stylus contact is never reclaimed by the sample cap", function()
    local p = drawingPlugin{ max_contact_samples = 2 }
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    t:eq(p:onStylusEvent(bus:set(4, {
        id = 4, x = bar.x + 5, y = bar.y + 5, tool = 1,
    })), false, "control down passes")
    for _ = 1, 4 do
        t:eq(p:onStylusEvent(bus:slot(4)), false,
            "forwarded sequence stays forwarded")
    end
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), false,
        "matching lift also passes")
    t:eq(p.store:get(1), nil, "nothing was drawn")
end)

t:case("a frame with id=nil neither starts nor ends a stroke", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    t:eq(p:onStylusEvent(bus:set(4, { x = 10, y = 10, tool = 1 })), true, "hover consumed")
    t:eq(p.stroke, nil, "no stroke started")
    t:eq(p:hasActivePhysicalContact(), false, "not marked active")
end)

t:case("repeated id<0 frames after a lift stay idempotent", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
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
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
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
    p:onStylusEvent(bus:set(4, { x = 140, y = 120 }))
    -- Leaving proximity: KOReader writes TOOL_TYPE_FINGER into the pen slot.
    t:eq(p:onStylusEvent(bus:set(4, { id = -1, tool = 0 })), true, "treated as a lift")
    t:eq(p.stroke, nil, "stroke closed")
    t:eq(#p.store:get(1), 1, "exactly one stroke stored")
end)

t:case("highlighter behaves as a pen in this release", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 3 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
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

t:case("a stroke record carries its style into the sidecar and back", function()
    local p = drawingPlugin()
    p:startStroke(100, 100, 65)          -- graphite, injected directly
    p:endStroke()
    local s = p.store:get(1)[1]
    t:eq(s.t, 65, "the sidecar stroke keeps the style field")
    t:eq(s.w, p.pen_width, "graphite does not widen the nib")
end)

t:case("a marker stroke stores a three-nib width", function()
    local p = drawingPlugin()
    p:startStroke(100, 100, 3)
    p:endStroke()
    local s = p.store:get(1)[1]
    t:eq(s.w, p.pen_width * 3, "marker width is baked into the stored stroke")
end)

t:case("direct replay paints each stroke with its style's color", function()
    local p = drawingPlugin()
    p.store:add(1, { n = 2, w = 4, t = 65, 100, 100, 140, 100 })
    p.store:add(1, { n = 2, w = 4, 100, 200, 140, 200 })   -- legacy, no t
    local bb = Device.screen.bb
    local before = #bb.rects
    p:paintTo(bb, 0, 0)
    -- The fake records every stamp as { x, y, w, h, c } in bb.rects
    -- (support.lua:317-324). Row y=100 is the graphite stroke, y=200 legacy.
    local seen_gray, seen_black = false, false
    for i = before + 1, #bb.rects do
        local r = bb.rects[i]
        if r.c == "gray_6" and r.y < 150 then seen_gray = true end
        if r.c == "black" and r.y > 150 then seen_black = true end
    end
    t:eq(seen_gray, true, "graphite painted gray")
    t:eq(seen_black, true, "a legacy stroke still paints plain ink")
end)

t:describe("main / stylus latching")

t:case("a sequence starting on the toolbar stays passthrough to the lift", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen
    local bx, by = bar.x + 5, bar.y + 5

    -- The contact-down pair is not good enough to draw from, but it is good
    -- enough to answer "is this somebody else's?", which is what keeps the
    -- toolbar tappable with a pen.
    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = bx, y = by, tool = 1 })), false,
        "down passes through")
    t:eq(p:onStylusEvent(bus:set(4, { x = 100, y = 100 })), false, "still passthrough outside the bar")
    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), false, "lift passes through too")
    t:eq(p.store:get(1), nil, "no ink at all")
end)

t:case("a sequence dragged onto the toolbar stays dominated and truncates", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), true, "down dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 150, y = 120 })), true, "first coherent point dominated")
    t:eq(p:onStylusEvent(bus:set(4, { x = 200, y = 140 })), true, "move dominated")
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
    t:eq(p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 })), false,
        "pen passes through")
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
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
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
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    bus:set(0, { id = 1, x = 300, y = 600 })
    p:onStylusTouchFrame(bus:frame(0))
    t:eq(p.bar:suppresses{ ges = "tap", pos = { x = 300, y = 600 } }, true, "palm suppressed")
    t:check(p.stroke ~= nil, "stroke survived the palm")

    p:onStylusEvent(bus:set(4, { x = 200, y = 140 }))
    p:onStylusEvent(bus:set(4, { x = 250, y = 160 }))
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
    t:eq(p.stylus_sequence.state, "active_pass", "pen latched to passthrough")

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
    t:eq(p:hasActivePhysicalContact(), false, "stylus state reset")
    t:eq(p.stylus_sequence, nil, "the lease's contact machine went with it")
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
    t:eq(p:hasActivePhysicalContact(), false, "stylus state reset")
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
    function bb:getWidth() return 32 end
    function bb:getHeight() return 32 end
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

t:case("store hit measures segments, not just sampled points", function()
    local s = Store.new()
    s:add(3, { n = 2, w = 2, 0, 0, 100, 0 })
    t:eq(Store.hit(s:get(3), 50, 3, 2), 1,
        "the gap between two sparse samples responds (ADR-7's noted fix)")
    t:eq(Store.hit(s:get(3), 50, 30, 2), nil, "far away still misses")
end)

t:case("store sweep cuts strokes in place, keeping their position", function()
    local s = Store.new()
    s:add(3, { n = 5, w = 2, 0, 0, 25, 0, 50, 0, 75, 0, 100, 0 })
    s:add(3, { n = 1, w = 2, 200, 200 })
    t:eq(s:sweep(3, 50, -10, 50, 10, 5), true, "the capsule cut something")
    local list = s:get(3)
    t:eq(#list, 3, "two fragments in the old slot, plus the untouched dot")
    t:eq(list[1][1], 0, "the head fragment keeps the start")
    t:eq(list[1].n, 2, "and only its own points")
    t:eq(list[2][1], 75, "the tail fragment resumes after the cut")
    t:eq(list[3][1], 200, "the dot stayed last -- pop still means newest")
    t:eq(s:sweep(3, 500, 500, 510, 510, 5), false, "a miss reports no change")
end)

t:case("store sweep drops the whole page when everything is cut", function()
    local s = Store.new()
    s:add(7, { n = 2, w = 2, 10, 10, 20, 20 })
    t:eq(s:sweep(7, 15, 15, 15, 15, 30), true, "the only stroke went whole")
    t:eq(s:get(7), nil, "empty pages are dropped, as removeAt does")
end)

t:case("the direct eraser sweeps between samples and forgets its anchor at lift", function()
    reset()
    local p = support.newPlugin(JustDraw, env, { page = 1 })
    p.store:add(1, { n = 5, w = 4, 100, 100, 200, 100, 300, 100, 400, 100, 500, 100 })
    p:eraseAt(300, 300)
    t:eq(#p.store:get(1), 1, "a far sample cuts nothing but arms the anchor")
    p:eraseAt(300, 50)
    t:eq(#p.store:get(1), 2, "the capsule crossed the stroke on its way up")
    p:endStroke()
    t:eq(p.direct_erase_x, nil, "lift forgets the sweep anchor")
    p:eraseAt(300, 300)
    t:eq(#p.store:get(1), 2, "a fresh contact does not inherit the old path")
end)

t:case("persisted stroke format is unchanged and loads without migration", function()
    local legacy = { [2] = { { n = 2, w = 4, 10, 20, 30, 40 } } }
    reset()
    local p = support.newPlugin(JustDraw, env, { doc_settings = { justdraw_strokes = legacy }, page = 2 })
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
        if Capture:isKORoutedStylusSlot(slot, input) then
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
        { slot = 4, fields = { x = 150, y = 120 } },
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
    return walk(items.justdraw.sub_item_table)
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
    t:eq(p.stylus_trace, nil, "coordinates are not logged before confirmation")
    local warning = env.UIManager.shown[#env.UIManager.shown]
    t:check(warning and warning.text:find("Pen coordinates", 1, true),
        "the privacy warning is shown")
    warning.ok_callback()
    t:check(p.stylus_trace and p.stylus_trace:isActive(), "armed after confirmation")
    t:check(#env.logs.info > 0, "and the capability report was written")
    t:check(#env.notifications > 0 or #env.shown_messages > 0, "and shown to the user")
end)

t:case("diagnostics stop on their own", function()
    local p = pipelinePlugin()
    local lines = {}
    p:startDiagnostics("direct", {
        emit = function(line) lines[#lines + 1] = line end,
        now = function() return 0 end,
        duration_seconds = 60,
        max_events = 3,
    })
    t:check(p.stylus_trace:isActive(), "diagnostics armed")
    for i = 1, 3 do
        p:onStylusEvent({ slot = 4, id = 4, tool = 1, x = 10, y = i })
    end
    t:check(not p.stylus_trace:isActive(), "the event budget disarmed them")
    t:check(lines[#lines]:find("trace_truncated=event_limit", 1, true),
        "the bounded cause is recorded")
end)

t:case("diagnostics log nothing until they are armed", function()
    local p = pipelinePlugin()
    local before = #env.logs.info
    p:onStylusEvent({ slot = 4, id = 4, tool = 1, x = 10, y = 10 })
    t:eq(#env.logs.info, before, "disarmed is silent")
end)

t:case("the lift frame only contributes a point when nothing was drawn", function()
    -- The recovery exists for a contact-down frame wrongly judged stale. If it
    -- ran unconditionally it would append the lift position to every stroke,
    -- moving its end whenever the lift frame carries a fresh sample.
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 100, y = 100, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { x = 200, y = 120 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { x = 300, y = 140 } } })
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
    -- disarmInput has to undo the pen's per-sequence state too. A surviving
    -- passthrough latch would silently eat the first stroke of the next
    -- session, and a surviving geometry baseline would measure it against a
    -- position from a lease that no longer exists.
    local p = drawingPlugin()
    local bus = support.newSlotBus()
    local d = p.bar.dimen
    p:onStylusEvent(bus:set(4, { id = 4, x = d.x + 5, y = d.y + 5, tool = 1 }))
    t:eq(p.stylus_sequence.state, "active_pass", "latched over the toolbar mid-sequence")

    Capture:fail("boom")
    env.UIManager:flush()
    t:eq(p.stylus_sequence, nil, "the pen sequence was closed out")
    t:eq(p:hasActivePhysicalContact(), false, "and its latch released")

    p:setDrawing(true)
    local next_bus = support.newSlotBus()
    p:onStylusEvent(next_bus:set(4, { id = 9, x = 400, y = 400, tool = 1 }))
    p:onStylusEvent(next_bus:set(4, { x = 450, y = 430 }))
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
    -- The lift position is the next contact's baseline, which is what makes
    -- the sticky pair below detectable at all.

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
    p:onStylusEvent(bus:set(4, { x = 140, y = 130 }))
    p:onStylusEvent(bus:set(4, { x = bar.x + 5, y = bar.y + 5 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))

    -- Next contact-down repeats those coordinates without meaning to. Matching
    -- the baseline on both axes is the one case that proves nothing at all, so
    -- it neither inks nor hands the contact to the toolbar.
    p:onStylusEvent(bus:set(4, { id = 4 }))
    t:eq(p.stylus_sequence.state, "geometry_pending",
        "the stale bar position did not latch passthrough")
    p:onStylusEvent(bus:set(4, { x = 200, y = 200 }))
    p:onStylusEvent(bus:set(4, { x = 250, y = 220 }))
    p:onStylusEvent(bus:set(4, { id = -1 }))
    t:eq(#p.store:get(1), 2, "the second stroke was drawn, not lost")
end)

t:case("a dialog opening mid-stroke stops the ink but keeps the slot", function()
    local p = drawingPlugin()
    local bus = support.newSlotBus()

    p:onStylusEvent(bus:set(4, { id = 4, x = 100, y = 100, tool = 1 }))
    p:onStylusEvent(bus:set(4, { x = 150, y = 120 }))
    t:check(p.stroke ~= nil, "stroke in flight")

    showDialog("a dialog that just opened")
    t:eq(p:onStylusEvent(bus:set(4, { x = 200, y = 140 })), true,
         "still dominating: handing the slot back mid-sequence corrupts the detector")
    t:eq(p.stroke, nil, "the stroke was aborted rather than drawn over the dialog")

    t:eq(p:onStylusEvent(bus:set(4, { id = -1 })), true, "lift stays dominated")
    t:eq(p.store:get(1), nil, "nothing was committed")
end)

t:case("a failed start does not force the toolbar on", function()
    reset{ stylus_api = false }
    local p = newPlugin()
    p:setBarShown(false)
    _G.G_reader_settings.data.justdraw_bar_shown = false
    p:setInputMode("stylus")

    p:setDrawing(true)
    t:eq(p.drawing, false, "drawing stayed off")
    t:eq(p.bar, nil, "the toolbar was not forced on")
    t:eq(_G.G_reader_settings.data.justdraw_bar_shown, false, "the preference was not rewritten")
end)

-- =====================================================================
-- ink_bar.lua, the real widget
-- =====================================================================

t:describe("ink_bar (real widget)")

t:case("builds six buttons and a screen-relative geometry", function()
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    t:check(bar.draw_btn ~= nil, "the capture toggle exists")
    t:check(bar.pen_btn ~= nil and bar.eraser_btn ~= nil,
        "each tool has a button of its own, like the notebook rail")
    t:check(bar.undo_btn ~= nil and bar.hide_btn ~= nil, "action buttons exist")
    t:check(bar.more_btn ~= nil, "the settings dialog is reachable from the bar")
    t:eq(bar.tool_btn, nil, "the combined tool toggle is gone")
    t:check(bar.dimen.w > 0 and bar.dimen.h > 0, "the bar has a size")
    t:check(bar.dimen.x + bar.dimen.w <= Device.screen:getWidth(), "it fits on screen")
    t:check(bar.dimen.y >= 0
        and bar.dimen.y + bar.dimen.h <= Device.screen:getHeight(),
        "six buttons still fit the screen's height")

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

t:case("relabels Draw/Stop and marks the active tool", function()
    -- The check lives in the label, through the same setText relabel the
    -- Draw button already uses, because a Button refreshes a `checked_func`
    -- checkmark only after its own tap -- a bound eraser gesture or the menu
    -- flipping the tool from outside would leave a stale check.
    local checked = function(btn) return btn.text:find("\u{2713}", 1, true) ~= nil end
    reset()
    local p = newPlugin()
    local bar = newRealBar(p)
    p.drawing, p.eraser = false, false
    bar:update(false)
    t:eq(bar.draw_btn.text, "Draw", "idle label")
    t:eq(checked(bar.pen_btn), true, "the pen is marked as the active tool")
    t:eq(checked(bar.eraser_btn), false, "the eraser is not")
    p.drawing, p.eraser = true, true
    bar:update(false)
    t:eq(bar.draw_btn.text, "Stop", "drawing label")
    t:eq(checked(bar.pen_btn), false, "the pen mark moved")
    t:eq(checked(bar.eraser_btn), true, "to the eraser")
end)

t:case("each tool button sets its own tool, never toggles", function()
    local p, bar = realBarPlugin()
    bar.eraser_btn.callback()
    t:eq(p.eraser, true, "the eraser button picks the eraser")
    t:eq(p.drawing, true, "and arms capture, as the old toggle did")
    bar.eraser_btn.callback()
    t:eq(p.eraser, true, "a second tap holds the tool rather than toggling")
    bar.pen_btn.callback()
    t:eq(p.eraser, false, "the pen button returns to inking")
end)

--- The one button spec with this text anywhere in a ButtonDialog's rows.
local function dialogButton(dialog, text)
    for _, row in ipairs(dialog and dialog.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn.text == text then return btn end
        end
    end
    return nil
end

t:case("More opens the settings dialog for the reader", function()
    local p, bar = realBarPlugin()
    local before = #env.dialogs
    bar.more_btn.callback()
    t:eq(#env.dialogs, before + 1, "one dialog opened")
    local dialog = env.dialogs[#env.dialogs]
    t:check(dialogButton(dialog, "Pen width") ~= nil, "pen width is reachable")
    t:check(dialogButton(dialog, "Input mode") ~= nil, "input mode is reachable")
    t:check(dialogButton(dialog, "Export…") ~= nil, "export is reachable")
    t:eq(dialogButton(dialog, "Export…").enabled, false,
        "and disabled while there is nothing to export")
    t:check(dialogButton(dialog, "Toolbar side") ~= nil, "the side can move")
    t:eq(dialogButton(dialog, "Close sheet"), nil, "no sheet rows without a sheet")
    t:check(dialogButton(dialog, "Close") ~= nil, "and it can be dismissed")
end)

t:case("the settings dialog refuses while a contact is live", function()
    local p = realBarPlugin()
    p.input_lease = { hasActiveContact = function() return true end }
    local before = #env.dialogs
    local got, err = p:showBarMenu()
    t:eq(got, nil, "refused")
    t:eq(err, "contact_active", "and says why")
    t:eq(#env.dialogs, before, "no window went up under the pen")
end)

t:case("pen width is set from the dialog and remembered", function()
    local p, bar = realBarPlugin()
    bar.more_btn.callback()
    dialogButton(env.dialogs[#env.dialogs], "Pen width").callback()
    local widths = env.dialogs[#env.dialogs]
    t:eq(dialogButton(widths, "Medium").checked_func(), true,
        "the current width is the marked one")
    dialogButton(widths, "Thick").callback()
    t:eq(p.pen_width, 7, "the plugin took the width")
    t:eq(_G.G_reader_settings.data.justdraw_pen_width, 7, "and it is saved")
end)

t:case("input mode stays locked while drawing, from the dialog too", function()
    local p, bar = realBarPlugin()
    p:setDrawing(true)
    bar.more_btn.callback()
    dialogButton(env.dialogs[#env.dialogs], "Input mode").callback()
    t:eq(dialogButton(env.dialogs[#env.dialogs], "Finger").enabled, false,
        "swapping backends mid-capture is refused, as in the menu")
    p:setDrawing(false)
    bar.more_btn.callback()
    dialogButton(env.dialogs[#env.dialogs], "Input mode").callback()
    local modes = env.dialogs[#env.dialogs]
    t:eq(dialogButton(modes, "Finger").enabled, true,
        "and allowed once capture is off")
    dialogButton(modes, "Finger").callback()
    t:eq(p.input_mode, "finger", "the mode reached the plugin")
end)

t:case("the dialog swaps the toolbar side", function()
    local p, bar = realBarPlugin()
    local before_x = p.bar.dimen.x
    bar.more_btn.callback()
    dialogButton(env.dialogs[#env.dialogs], "Toolbar side").callback()
    t:eq(p.bar_side, "left", "the side flipped")
    t:eq(_G.G_reader_settings.data.justdraw_bar_side, "left", "and was saved")
    env.UIManager:flush()   -- rebuildBar re-shows the bar on the next tick
    t:check(p.bar.dimen.x < before_x, "the bar really moved")
end)

t:case("closing the settings dialog twice is a no-op (ADR-28)", function()
    local p = realBarPlugin()
    local dialog = p:showBarMenu()
    t:check(dialog ~= nil, "the dialog opened")
    t:eq(p:closeReaderModal(dialog), true, "the first close finds it")
    t:eq(p:closeReaderModal(dialog), false,
        "the second is refused rather than repainted")
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
    JustDraw = JustDraw,
    menuItem = menuItem,
    newRealBar = newRealBar,
    realBar = realBar,
    realBarPlugin = realBarPlugin,
    showDialog = showDialog,
}

for _, spec in ipairs({
    "style_spec",
    "compat_spec",
    "conformance_policy_spec",
    "stylus_sequence_spec",
    "wacom_palm_spec",
    "render_spec",
    "stroke_split_spec",
    "paper_spec",
    "canvas_codec_spec",
    "canvas_repository_spec",
    "canvas_anchor_spec",
    "canvas_geometry_spec",
    "canvas_cache_spec",
    "canvas_overlay_spec",
    "canvas_router_spec",
    "capture_filter_spec",
    "slot_steer_spec",
    "input_controller_spec",
    "canvas_queue_spec",
    "surface_session_spec",
    "canvas_session_spec",
    "main_canvas_spec",
    "canvas_scale_spec",
    "notebook_geometry_spec",
    "notebook_input_spec",
    "notebook_repository_spec",
    "notebook_session_spec",
    "notebook_controller_spec",
    "notebook_host_spec",
    "notebook_scale_spec",
    "notebook_ui_spec",
    "notebook_library_spec",
    "notebook_editor_spec",
    "export_pdf_spec",
    "export_raster_spec",
    "export_job_spec",
    "export_reader_spec",
    "export_enumeration_spec",
    "export_dialog_spec",
}) do
    dofile(tests_dir .. "/" .. spec .. ".lua")(ctx)
end

os.exit(t:report() and 0 or 1)
