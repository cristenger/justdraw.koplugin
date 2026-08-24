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

-- LuaJIT and Lua 5.1 expose unpack as a global; 5.2+ moved it to table. Keeping
-- both alive is what lets this suite run in CI without a KOReader build.
local unpack = unpack or table.unpack

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
    local gd = { calls = 0, last_slots = nil, active_contacts = {}, dropped = {} }
    -- The real feedEvent returns a fresh array of gesture events per frame,
    -- and opens a Contact the first time it sees a slot.
    gd.feedEvent = function(gd_self, slots)
        gd.calls = gd.calls + 1
        gd.last_slots = slots
        for i = 1, #slots do
            local n = slots[i].slot
            if n ~= nil and not gd.active_contacts[n] then
                -- Mimics the pending hold timer the real Contact registers on
                -- first contact down; dropContact is what clears it.
                gd.active_contacts[n] = { slot = n, pending_hold_timer = true }
            end
        end
        local out = {}
        if opts.gestures_per_frame then
            for i = 1, opts.gestures_per_frame do
                out[i] = { ges = "tap", pos = { x = 1, y = 2 } }
            end
            return out
        end
        -- One gesture per contact, at that contact's position. The real
        -- detector does not emit one per slot per frame, but position is the
        -- only property the suppression layer reads and it has to be the
        -- contact's own -- a fixed position would make every position test
        -- pass or fail for the wrong reason.
        --
        -- Rotation is identity in these tests, so raw slot coordinates and the
        -- screen coordinates adjustGesCoordinate would produce are the same.
        for i = 1, #slots do
            local ev = slots[i]
            out[#out + 1] = {
                ges = "tap",
                pos = { x = ev.x or 0, y = ev.y or 0 },
                slot = ev.slot,
            }
        end
        return out
    end
    function gd:getContact(slot) return self.active_contacts[slot] end
    function gd:dropContact(contact)
        self.active_contacts[contact.slot] = nil
        contact.pending_hold_timer = nil
        self.dropped[#self.dropped + 1] = contact.slot
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

-- ---------------------------------------------------------- fake sql driver

--[[--
A recording stand-in for `lua-ljsqlite3`.

It is deliberately *not* an SQL engine. It executes nothing, parses nothing and
knows nothing about tables; it records every statement and every binding in
order, and hands back rows a test scripted in advance. What it can prove is
control flow -- the order of BEGIN/COMMIT/ROLLBACK, that a backup happens
before a migration, that a query does not select a column, that a connection is
closed on the failure path.

What it cannot prove is that the SQL is valid or that a constraint fires. That
lives in tests/conformance.lua, which runs the real schema against real SQLite.
Treating this fake as evidence about SQL semantics is how a suite ends up
proving only what it already believed.

Two behaviours are modelled from the real driver because the repository has to
defend against them, and a naive stub would hide both:

1. INTEGER columns come back as int64 cdata under LuaJIT, not as Lua numbers.
   `1LL == 1` is true, but `t[1LL]` and `t[1]` are *different table keys*, and
   `1LL .. ""` raises. Anything the repository hands out has to be a real
   number. Set `opts.int64` to wrap integer answers in a stand-in with those
   same edges.
2. `stmt:step()` returns nil once the rows run out, and `reset()` is what
   re-arms it.
]]

--[[--
Stands in for the int64 cdata the real driver hands back for INTEGER columns.

A string, deliberately. What has to be modelled is the property the repository
defends against: a raw driver value is *not* the same table key as the number
it represents, and `tonumber` is what fixes that. A string has exactly that
shape and works under a stock Lua, where there is no ffi to make a real int64.

It diverges from the real cdata in one way -- `1LL == 1` is true and `"1" == 1`
is not -- which is why the assertions built on this check table keys and types
rather than equality.
]]
function support.int64(v) return tostring(v) end

local function scriptedRows(conn, sql)
    for i = 1, #conn.answers do
        local a = conn.answers[i]
        if sql:find(a.pattern) then
            local rows = a.rows
            if type(rows) == "function" then rows = rows(sql) end
            return rows
        end
    end
    return nil
end

--- Wrap integers the way the real driver would, when asked to.
local function maybeInt64(conn, rows)
    if not conn.int64 or type(rows) ~= "table" then return rows end
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            -- pairs, not 1..#row: a scripted row with a NULL column in the
            -- middle has a hole, and `#` on a table with a hole may stop at
            -- it, silently truncating every column after the NULL.
            local copy = {}
            for j, v in pairs(row) do
                if type(v) == "number" and v == math.floor(v) then
                    copy[j] = support.int64(v)
                else
                    copy[j] = v
                end
            end
            out[i] = copy
        else
            out[i] = row
        end
    end
    return out
end

local FakeStmt = {}
FakeStmt.__index = FakeStmt

function FakeStmt:bind(...)
    self.binds = { ... }
    self.conn.log[#self.conn.log + 1] = {
        op = "bind", sql = self.sql, values = self.binds,
    }
    return self
end

function FakeStmt:clearbind() self.binds = {} ; return self end

function FakeStmt:reset()
    self.cursor = 0
    return self
end

function FakeStmt:step(row)
    self.conn.log[#self.conn.log + 1] = { op = "step", sql = self.sql, values = self.binds }
    self.conn.steps = self.conn.steps + 1
    if self.conn.fail_on and self.sql:find(self.conn.fail_on) then
        error("fake sql failure: " .. self.sql, 0)
    end
    self.cursor = self.cursor + 1
    local rows = self.rows
    local out = rows and rows[self.cursor]
    if out and row then
        for i, v in pairs(out) do row[i] = v end
        return row
    end
    return out
end

function FakeStmt:close() self.closed = true end

local FakeConn = {}
FakeConn.__index = FakeConn

--- Script an answer. `pattern` is a Lua pattern matched against the statement
--- text; `rows` is an array of rows, or a function returning one.
function FakeConn:answer(pattern, rows)
    self.answers[#self.answers + 1] = { pattern = pattern, rows = rows }
    return self
end

function FakeConn:exec(sql)
    self.log[#self.log + 1] = { op = "exec", sql = sql }
    if self.fail_on and sql:find(self.fail_on) then
        error("fake sql failure: " .. sql, 0)
    end
    return nil
end

function FakeConn:rowexec(sql)
    self.log[#self.log + 1] = { op = "rowexec", sql = sql }
    if self.fail_on and sql:find(self.fail_on) then
        error("fake sql failure: " .. sql, 0)
    end
    local rows = maybeInt64(self, scriptedRows(self, sql))
    local first = rows and rows[1]
    if not first then return nil end
    return unpack(first)
end

function FakeConn:prepare(sql)
    self.log[#self.log + 1] = { op = "prepare", sql = sql }
    if self.fail_on and sql:find(self.fail_on) then
        error("fake sql failure: " .. sql, 0)
    end
    local stmt = setmetatable({
        conn = self, sql = sql, cursor = 0, binds = {},
        rows = maybeInt64(self, scriptedRows(self, sql)),
    }, FakeStmt)
    self.prepared[#self.prepared + 1] = stmt
    return stmt
end

function FakeConn:close() self.closed = true end

--- Every statement text seen, in order, for order assertions.
function FakeConn:sqlLog()
    local out = {}
    for i = 1, #self.log do out[i] = self.log[i].sql end
    return out
end

--- True when any recorded statement matches the pattern.
function FakeConn:saw(pattern)
    for i = 1, #self.log do
        if self.log[i].sql:find(pattern) then return true end
    end
    return false
end

--- The text of the first statement matching the pattern, or nil. Use this
--- rather than `saw` when the claim is about one query's own text: the schema
--- DDL is in the log too, and it names every table and column there is.
function FakeConn:statement(pattern)
    for i = 1, #self.log do
        if self.log[i].sql:find(pattern) then return self.log[i].sql end
    end
end

--- Position of the first statement matching the pattern, or nil.
function FakeConn:indexOf(pattern)
    for i = 1, #self.log do
        if self.log[i].sql:find(pattern) then return i end
    end
end

--- The binding list of the first step matching the pattern.
function FakeConn:bindsFor(pattern)
    for i = 1, #self.log do
        local e = self.log[i]
        if e.op == "step" and e.sql:find(pattern) then return e.values end
    end
end

--[[--
opts.int64    - hand integers back as int64 stand-ins (default false)
opts.fail_on  - Lua pattern; any statement matching it raises
]]
function support.newSqlDriver(opts)
    opts = opts or {}
    local driver = { opened = {}, conns = {} }
    function driver.open(path)
        local conn = setmetatable({
            path = path,
            log = {},
            answers = {},
            prepared = {},
            steps = 0,
            closed = false,
            int64 = opts.int64 or false,
            fail_on = opts.fail_on,
        }, FakeConn)
        driver.opened[#driver.opened + 1] = path
        driver.conns[#driver.conns + 1] = conn
        if opts.on_open then opts.on_open(conn) end
        return conn
    end
    --- The connection most recently handed out.
    function driver.last() return driver.conns[#driver.conns] end
    return driver
end

-- --------------------------------------------------------- fake document

--[[--
A CreDocument stand-in for the anchor and index tests.

Only the xpointer surface is modelled, and every call that costs something on a
real document is counted: `resolutions` for getPageFromXPointer and
`in_page_checks` for isXPointerInCurrentPage. Several of the guarantees the
index has to make are about *not* calling those -- a page turn resolving
nothing, a repaint resolving nothing -- and a counter is the only way to state
that as a test rather than as a hope.

`getNormalizedXPointer` returns false for an xpointer the DOM does not know,
which is what the real one does and is easy to mistake for nil.

opts.pages        xpointer -> page number. Absent means "not in this document".
opts.normalized   raw xpointer -> normalised form. Absent means unchanged.
opts.hash         rendering hash (default "layout-a")
opts.dom_version  the book's cre_dom_version (default 20240114)
opts.visible      pages visible at once (default 1)
opts.here         the xpointer getXPointer() reports (default "/body/p[1]")
]]
function support.newDocument(opts)
    opts = opts or {}
    local doc = {
        pages = opts.pages or {},
        normalized = opts.normalized or {},
        hash = opts.hash or "layout-a",
        dom_version = opts.dom_version or 20240114,
        normalized_dom_version = opts.normalized_dom_version or 20200824,
        visible = opts.visible or 1,
        here = opts.here or "/body/p[1]",
        current_page = opts.current_page or 1,
        resolutions = 0,
        in_page_checks = 0,
    }
    function doc:getXPointer() return self.here end
    function doc:getNormalizedXPointer(xp)
        if self.pages[xp] == nil and self.normalized[xp] == nil then return false end
        return self.normalized[xp] or xp
    end
    function doc:isXPointerInDocument(xp) return self.pages[xp] ~= nil end
    function doc:getPageFromXPointer(xp)
        self.resolutions = self.resolutions + 1
        return self.pages[xp]
    end
    function doc:isXPointerInCurrentPage(xp)
        self.in_page_checks = self.in_page_checks + 1
        local page = self.pages[xp]
        return page ~= nil and page >= self.current_page
            and page < self.current_page + self.visible
    end
    function doc:getVisiblePageNumberCount() return self.visible end
    function doc:getDocumentRenderingHash() return self.hash end
    function doc:getDomVersionWithNormalizedXPointers()
        return self.normalized_dom_version
    end
    return doc
end

-- ------------------------------------------------------- fake canvas store

--[[--
An in-memory stand-in for the canvas repository.

This one fakes an *interface*, not a database: the four methods the anchor
index actually calls, backed by Lua tables. The repository's own behaviour is
covered against a recorder and against real SQLite elsewhere, so nothing here
is claiming anything about SQL. What it gives the index tests is a call count,
which is how "a page turn issues no query" becomes a check rather than a claim.
]]
function support.newCanvasStore(canvases)
    local store = {
        canvases = canvases or {},
        layouts = {},        -- [hash] = { [canvas_id] = page }
        calls = { list = 0, read = 0, save = 0 },
        saves = {},          -- every saveLayoutPages call, in order
    }
    function store:listCanvases()
        self.calls.list = self.calls.list + 1
        return self.canvases
    end
    function store:layoutPages(_, hash)
        self.calls.read = self.calls.read + 1
        return self.layouts[hash] or {}
    end
    function store:saveLayoutPages(_, hash, pages)
        self.calls.save = self.calls.save + 1
        local copy = {}
        for id, page in pairs(pages) do copy[id] = page end
        self.layouts[hash] = copy
        self.saves[#self.saves + 1] = { hash = hash, pages = copy }
        return true
    end
    return store
end

--[[--
A manual scheduler standing in for UIManager:nextTick.

Nothing runs until a test pumps it, which is what makes "the index is still
incomplete here" an observable state rather than a race.
]]
function support.newScheduler()
    local s = { queue = {} }
    function s:schedule(fn) self.queue[#self.queue + 1] = fn end
    --- Run one pending callback. Returns false when there was nothing to run.
    function s:tick()
        local fn = table.remove(self.queue, 1)
        if not fn then return false end
        fn()
        return true
    end
    --- Run to quiescence, with a bound so a scheduling loop fails loudly.
    function s:drain(limit)
        local n = 0
        while self:tick() do
            n = n + 1
            if n > (limit or 10000) then error("scheduler did not settle", 0) end
        end
        return n
    end
    return s
end

-- --------------------------------------------------------- module preload

--[[--
Install the KOReader module stubs. Returns the mutable `env` the tests poke at:
env.Device, env.UIManager, env.notifications, env.logs.
]]
function support.install()
    local env = {
        notifications = {},
        shown_messages = {},
        reader_events = {},
        logs = { warn = {}, err = {}, info = {} },
        dispatcher_actions = {},
    }

    local Device = { model = "Emulator", screen = support.newScreen(), input = support.newInput() }
    function Device:isSDL() return self._is_sdl == true end
    env.Device = Device

    local UIManager = { _window_stack = {}, shown = {}, dirty = {}, _queue = {} }
    function UIManager:nextTick(fn) self._queue[#self._queue + 1] = fn end
    function UIManager:scheduleIn(_, fn) self._queue[#self._queue + 1] = fn end
    function UIManager:unschedule() end
    function UIManager:show(w)
        self.shown[#self.shown + 1] = w
        self._window_stack[#self._window_stack + 1] = { widget = w }
    end
    --- Mirrors UIManager:sendEvent @ v2026.07: toasts are offered the event but
    --- never consume it, the topmost non-toast widget gets first refusal, and a
    --- true return stops propagation.
    function UIManager:sendEvent(event)
        local top
        for i = #self._window_stack, 1, -1 do
            local w = self._window_stack[i].widget
            if w.toast then
                w:handleEvent(event)
            else
                top = w
                break
            end
        end
        if not top then return false end
        return top:handleEvent(event) and true or false
    end
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
    --- KOReader's dispatch order: numeric children first, in array order, and
    --- only then our own handler. c.f. WidgetContainer:handleEvent ->
    --- propagateEvent -> Widget.handleEvent
    --- (frontend/ui/widget/container/widgetcontainer.lua @ v2026.07).
    ---
    --- Getting this backwards makes a toolbar button unreachable in the fake
    --- while it works on the device, or the reverse -- exactly the class of bug
    --- this suite exists to catch.
    function WidgetContainer:handleEvent(event)
        for i = 1, #self do
            local child = self[i]
            if type(child) == "table" and child.handleEvent then
                if child:handleEvent(event) then return true end
            end
        end
        local handler = self[event.handler]
        if type(handler) == "function" then
            return handler(self, unpack(event.args or {}))
        end
    end

    local Notification = {}
    function Notification:new(o)
        env.notifications[#env.notifications + 1] = o.text
        o.toast = true
        -- Toasts are real widgets: sendEvent offers them every event on its way
        -- down, they just never consume one.
        o.handleEvent = function() end
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
    env.WidgetContainer = WidgetContainer
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
    --- Same walk as the production widget: skip ourselves and any toast, and
    --- return the first real window underneath. Reading the actual stack is
    --- what makes `dialogOnTop` mean something in these tests.
    function InkBar:windowBelow()
        local stack = UIManager._window_stack
        for i = #stack, 1, -1 do
            local widget = stack[i].widget
            if widget ~= self and not widget.toast then return widget end
        end
    end
    package.preload["ink_bar"] = function() return InkBar end
    env.InkBar = InkBar

    -- Enough of the widget toolkit to load the real ink_bar.lua.
    local Geom = {}
    Geom.__index = Geom
    function Geom:new(o) return setmetatable(o or {}, Geom) end
    package.preload["ui/geometry"] = function() return Geom end

    package.preload["ui/size"] = function()
        return {
            radius = { button = 4, window = 6 },
            border = { window = 2 },
            padding = { small = 2, large = 8 },
        }
    end

    local Button = {}
    Button.__index = Button
    function Button:new(o)
        o = setmetatable(o or {}, Button)
        o.texts = { o.text }
        o.seen = {}
        return o
    end
    --- Records the offer and declines it. The stub has no hit rectangle of its
    --- own, so it cannot decide a tap; what it can prove is that KOReader would
    --- have offered it the event before the container's own handler ran.
    function Button:handleEvent(event)
        self.seen[#self.seen + 1] = event.handler
        return false
    end
    function Button:setText(text) self.text = text; self.texts[#self.texts + 1] = text end
    function Button:getSize() return { w = self.width or 60, h = 30 } end
    function Button:paintTo() end
    package.preload["ui/widget/button"] = function() return Button end

    local function sizedContainer(name)
        local C = {}
        C.__index = C
        function C:new(o) return setmetatable(o or {}, C) end
        function C:getSize()
            local w, h = 0, 0
            for i = 1, #self do
                local size = self[i].getSize and self[i]:getSize() or { w = 0, h = 0 }
                if size.w > w then w = size.w end
                h = h + size.h
            end
            if name == "frame" then w = w + 8; h = h + 8 end
            return { w = w, h = h }
        end
        function C:paintTo() end
        --- FrameContainer and VerticalGroup are WidgetContainers on the device,
        --- so they propagate to their children. Without this the buttons are
        --- unreachable in the fake and the bar looks like it swallows
        --- everything.
        function C:handleEvent(event)
            for i = 1, #self do
                local child = self[i]
                if type(child) == "table" and child.handleEvent then
                    if child:handleEvent(event) then return true end
                end
            end
            return false
        end
        return C
    end
    package.preload["ui/widget/container/framecontainer"] = function() return sizedContainer("frame") end
    package.preload["ui/widget/verticalgroup"] = function() return sizedContainer("vgroup") end

    local Event = {}
    function Event:new(name, ...)
        return { handler = "on" .. name, args = { ... } }
    end
    package.preload["ui/event"] = function() return Event end

    local InfoMessage = {}
    function InfoMessage:new(o)
        env.shown_messages[#env.shown_messages + 1] = o.text
        o.handleEvent = function() end
        return o
    end
    package.preload["ui/widget/infomessage"] = function() return InfoMessage end

    package.preload["version"] = function()
        return { getCurrentRevision = function() return "v2025.08-test" end }
    end
    env.Event = Event

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
    -- Stands in for ReaderUI: the window under the bar, and the thing that
    -- turns pages when a gesture it should never have seen reaches it.
    local ui = {
        doc_settings = doc_settings,
        menu = { registerToMainMenu = function() end },
        handleEvent = function(_, event)
            env.reader_events[#env.reader_events + 1] = event.handler
            return true
        end,
    }
    local view = {
        state = { page = opts.page or 1 },
        registerViewModule = function() end,
    }
    -- ReaderUI has to be a real entry in the stack: the bar's forwarding, the
    -- dialogOnTop test and the whole suppression decision are defined relative
    -- to what sits below it.
    env.UIManager._window_stack = { { widget = ui } }
    local plugin = FingerInk:new{ ui = ui, view = view }
    return plugin
end

return support
