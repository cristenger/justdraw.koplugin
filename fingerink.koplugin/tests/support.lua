--[[--
Test harness for FingerInk: stubs, fakes and a tiny runner.

Everything KOReader-shaped is faked here so the suite runs under a bare LuaJIT
with no KOReader session. Two fidelity rules matter more than the rest, because
the bugs they exist to catch are invisible to a naive stub:

1. `Device.input.ev_slots` entries are *persistent tables*, reused across input
   frames, and `MTSlots` holds references to them. `id`, `x` and `y` survive a
   contact lift. A stub that hands out a fresh table per frame would make the
   sticky-id tests pass for the wrong reason.
   c.f. frontend/device/input.lua:1381-1450 @ v2026.07.2

2. `GestureDetector:feedEvent` is reached through the *instance*
   (`input.gesture_detector.feedEvent`), which is what makes the monkey patch
   possible and what identity-based removal has to defend.
]]

local support = {}

-- ------------------------------------------------------------------ runner

local Runner = {}
Runner.__index = Runner

function support.newRunner()
    return setmetatable({ passed = 0, failed = 0, group = "?" }, Runner)
end

function Runner:describe(name)
    self.group = name
    io.write("\n-- ", name, "\n")
end

function Runner:check(ok, label)
    if ok then
        self.passed = self.passed + 1
    else
        self.failed = self.failed + 1
        io.write("FAIL  ", self.group, " :: ", label, "\n")
    end
    return ok
end

function Runner:eq(got, want, label)
    local ok = got == want
    if not ok then
        label = string.format("%s (got %s, want %s)", label, tostring(got), tostring(want))
    end
    return self:check(ok, label)
end

--- Run fn under pcall; a raised error is a failure, not a crashed suite.
function Runner:case(label, fn)
    local ok, err = pcall(fn, self)
    if not ok then
        self.failed = self.failed + 1
        io.write("ERROR ", self.group, " :: ", label, "\n        ", tostring(err), "\n")
    end
end

function Runner:report()
    io.write(string.format("\n%d passed, %d failed\n", self.passed, self.failed))
    return self.failed == 0
end

-- ------------------------------------------------------- persistent slots

--[[--
Mimics Input.ev_slots: one durable table per slot number, handed out by
reference. Frames are arrays of those references, exactly like Input.MTSlots.
]]
local SlotBus = {}
SlotBus.__index = SlotBus

function support.newSlotBus()
    return setmetatable({ ev_slots = {} }, SlotBus)
end

function SlotBus:slot(n)
    local s = self.ev_slots[n]
    if not s then
        s = { slot = n }
        self.ev_slots[n] = s
    end
    return s
end

--- Mutate a slot in place and return the same reference. Fields not named here
--- keep their previous value, which is the whole point.
function SlotBus:set(n, fields)
    local s = self:slot(n)
    for k, v in pairs(fields) do s[k] = v end
    return s
end

--- Build a frame (an MTSlots-alike) out of references to persistent slots.
function SlotBus:frame(...)
    local frame = {}
    for i = 1, select("#", ...) do
        frame[i] = self:slot((select(i, ...)))
    end
    return frame
end

-- --------------------------------------------------------------- fake gd

local function newGestureDetector(opts)
    opts = opts or {}
    local gd = { calls = 0, last_slots = nil }
    -- The real feedEvent returns a fresh array of gesture events per frame.
    gd.feedEvent = function(gd_self, slots)
        gd.calls = gd.calls + 1
        gd.last_slots = slots
        local out = {}
        for i = 1, (opts.gestures_per_frame or 1) do
            out[i] = { ges = "tap", pos = { x = 1, y = 2 } }
        end
        return out
    end
    return gd
end
support.newGestureDetector = newGestureDetector

-- ------------------------------------------------------------- fake input

--[[--
opts.stylus_api  - install register/unregisterStylusCallback (default true)
opts.exports     - export Input.TOOL_TYPE_* (default true)
opts.gesture     - install a gesture_detector (default true)
]]
function support.newInput(opts)
    opts = opts or {}
    local input = {
        main_finger_slot = 0,
        pen_slot = 4,
        wacom_protocol = opts.wacom_protocol or false,
    }
    if opts.exports ~= false then
        input.TOOL_TYPE_FINGER = 0
        input.TOOL_TYPE_PEN = 1
        input.TOOL_TYPE_ERASER = 2
        input.TOOL_TYPE_HIGHLIGHTER = 3
    end
    if opts.gesture ~= false then
        input.gesture_detector = newGestureDetector(opts)
    end
    if opts.stylus_api ~= false then
        input.registerStylusCallback = function(self, cb)
            self.stylus_callback = cb
        end
        input.unregisterStylusCallback = function(self)
            self.stylus_callback = nil
        end
    end
    return input
end

-- ------------------------------------------------------------ fake screen

function support.newScreen(opts)
    opts = opts or {}
    local screen = {
        DEVICE_ROTATED_UPRIGHT = 0,
        DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
        rotation = 0,
        touch_rotation = nil,   -- nil => follow `rotation`
        refreshes = {},
        w = opts.w or 600,
        h = opts.h or 800,
    }
    screen.bb = { rects = {} }
    function screen.bb:paintRect(x, y, w, h, c)
        self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, c = c }
    end
    function screen:getWidth() return self.w end
    function screen:getHeight() return self.h end
    function screen:getRotationMode() return self.rotation end
    function screen:refreshFast(x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { "fast", x, y, w, h }
    end
    function screen:refreshPartial(x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { "partial", x, y, w, h }
    end
    if opts.no_touch_rotation ~= true then
        function screen:getTouchRotation()
            return self.touch_rotation or self.rotation
        end
    end
    return screen
end

-- --------------------------------------------------------- module preload

--[[--
Install the KOReader module stubs. Returns the mutable `env` the tests poke at:
env.Device, env.UIManager, env.notifications, env.logs.
]]
function support.install()
    local env = {
        notifications = {},
        logs = { warn = {}, err = {}, info = {} },
        dispatcher_actions = {},
    }

    local Device = { screen = support.newScreen(), input = support.newInput() }
    function Device:isSDL() return self._is_sdl == true end
    env.Device = Device

    local UIManager = { _window_stack = {}, shown = {}, dirty = {}, _queue = {} }
    function UIManager:nextTick(fn) self._queue[#self._queue + 1] = fn end
    function UIManager:scheduleIn(_, fn) self._queue[#self._queue + 1] = fn end
    function UIManager:unschedule() end
    function UIManager:show(w) self.shown[#self.shown + 1] = w end
    function UIManager:close(w)
        for i = #self._window_stack, 1, -1 do
            if self._window_stack[i].widget == w then table.remove(self._window_stack, i) end
        end
    end
    function UIManager:setDirty(w, mode) self.dirty[#self.dirty + 1] = { w, mode } end
    function UIManager:flush()
        local q = self._queue
        self._queue = {}
        for i = 1, #q do q[i]() end
    end
    env.UIManager = UIManager

    local logger = {}
    function logger.warn(...) env.logs.warn[#env.logs.warn + 1] = { ... } end
    function logger.err(...) env.logs.err[#env.logs.err + 1] = { ... } end
    function logger.info(...) env.logs.info[#env.logs.info + 1] = { ... } end
    logger.dbg = function() end

    local function WidgetContainer_extend(self, o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    local WidgetContainer = { extend = WidgetContainer_extend }
    function WidgetContainer:new(o)
        o = self:extend(o)
        if o.init then o:init() end
        return o
    end

    local Notification = {}
    function Notification:new(o)
        env.notifications[#env.notifications + 1] = o.text
        o.toast = true
        return o
    end

    local Dispatcher = {}
    function Dispatcher:registerAction(name, def)
        env.dispatcher_actions[name] = def
    end

    local ConfirmBox = {}
    function ConfirmBox:new(o) return o end

    package.preload["device"] = function() return Device end
    package.preload["ui/uimanager"] = function() return UIManager end
    package.preload["logger"] = function() return logger end
    package.preload["gettext"] = function() return function(s) return s end end
    package.preload["ffi/blitbuffer"] = function()
        return { COLOR_BLACK = "black", COLOR_WHITE = "white" }
    end
    package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
    package.preload["ui/widget/notification"] = function() return Notification end
    package.preload["ui/widget/confirmbox"] = function() return ConfirmBox end
    package.preload["dispatcher"] = function() return Dispatcher end

    -- ink_bar pulls in half the widget toolkit; the plugin only ever asks it
    -- for geometry and the window below, so fake exactly that surface.
    local InkBar = {}
    InkBar.__index = InkBar
    function InkBar:new(o)
        o = o or {}
        setmetatable(o, self)
        o.dimen = o.dimen or { x = 500, y = 300, w = 90, h = 200 }
        o.updates = 0
        return o
    end
    function InkBar:contains(x, y)
        local d = self.dimen
        return x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
    end
    function InkBar:update() self.updates = self.updates + 1 end
    function InkBar:windowBelow() return env.window_below end
    package.preload["ink_bar"] = function() return InkBar end
    env.InkBar = InkBar

    _G.G_reader_settings = {
        data = {},
        readSetting = function(self, k) return self.data[k] end,
        saveSetting = function(self, k, v) self.data[k] = v end,
        delSetting = function(self, k) self.data[k] = nil end,
    }

    return env
end

--- Build a FingerInk instance wired to fake ui/view objects.
function support.newPlugin(FingerInk, env, opts)
    opts = opts or {}
    local doc_settings = {
        data = opts.doc_settings or {},
        readSetting = function(self, k) return self.data[k] end,
        saveSetting = function(self, k, v) self.data[k] = v end,
        delSetting = function(self, k) self.data[k] = nil end,
    }
    local ui = {
        doc_settings = doc_settings,
        menu = { registerToMainMenu = function() end },
    }
    local view = {
        state = { page = opts.page or 1 },
        registerViewModule = function() end,
    }
    local plugin = FingerInk:new{ ui = ui, view = view }
    env.window_below = ui
    return plugin
end

return support
