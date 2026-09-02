--[[--
Test harness for JustDraw: stubs, fakes and a tiny runner.

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

-- This file's own directory's parent: the plugin root. Derived from the source
-- path because the suite is reached from the repository root and from inside
-- the plugin, and neither is the working directory the other one has.
local here = debug.getinfo(1, "S").source:sub(2)
local tests_dir = here:match("^(.*)[/\\][^/\\]*$") or "."
support.plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."

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
        -- Input's own persistent slot table. It outlives every capture, which
        -- is why a contact-down frame can present the previous contact's
        -- position and why the geometry policy seeds its boundary from here.
        ev_slots = opts.ev_slots or {},
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
    if opts.adjust_hook ~= false then
        -- input.lua @ 60ce80ed, 423-440 and 453: a class-level NOP that the
        -- first registration replaces and later ones chain onto. There is no
        -- unregister; `adjust_hooks_registered` lets a test see the chaining.
        local NOP = function() end
        input.eventAdjustHook = NOP
        input.adjust_hooks_registered = 0
        input.registerEventAdjustHook = function(self, hook, params)
            self.adjust_hooks_registered = self.adjust_hooks_registered + 1
            if self.eventAdjustHook == NOP then
                self.eventAdjustHook = function(this, ev) hook(this, ev, params) end
            else
                local old = self.eventAdjustHook
                self.eventAdjustHook = function(this, ev) old(this, ev); hook(this, ev, params) end
            end
        end
    end
    return input
end

--[[--
The slot bookkeeping of Input, copied from frontend/device/input.lua @
60ce80ed (1382-1450). tests/conformance.lua runs the same scenarios against
the real methods; if these ever drift, that probe is what says so.

`mixed_handler` puts an instance-level handleTouchEv on the table, the shape
the reMarkable has (remarkable/device.lua:324) and the slot steer refuses.
]]
function support.newSlotInput(opts)
    opts = opts or {}
    local input = {
        main_finger_slot = 0,
        pen_slot = 4,
        wacom_protocol = opts.wacom_protocol ~= false,
        cur_slot = 0,
        ev_slots = { [0] = { slot = 0 } },
        MTSlots = {},
        active_slots = {},
    }
    function input:initMtSlot(slot)
        if not self.ev_slots[slot] then self.ev_slots[slot] = { slot = slot } end
    end
    function input:getMtSlot(slot) return self.ev_slots[slot] end
    function input:setCurrentMtSlot(key, val) self.ev_slots[self.cur_slot][key] = val end
    function input:setCurrentMtSlotChecked(key, val)
        if not self.active_slots[self.cur_slot] then self:addSlot(self.cur_slot) end
        self.ev_slots[self.cur_slot][key] = val
    end
    function input:getCurrentMtSlotData(key)
        local slot = self.ev_slots[self.cur_slot]
        return slot and slot[key] or nil
    end
    function input:newFrame() self.MTSlots = {}; self.active_slots = {} end
    function input:addSlot(value)
        self:initMtSlot(value)
        table.insert(self.MTSlots, self:getMtSlot(value))
        self.active_slots[value] = true
        self.cur_slot = value
    end
    function input:setupSlotData(value)
        if not self.active_slots[value] then self:addSlot(value) else self.cur_slot = value end
    end
    if opts.mixed_handler then input.handleTouchEv = function() end end
    return input
end

-- -------------------------------------------------------- fake blitbuffer

--[[--
A recording BlitBuffer.

Two behaviours are modelled because the canvas depends on them, and a stub
without them would make the clipping tests pass for the wrong reason:

1. `paintRect` bounds its rectangle to the buffer and returns early when
   nothing is left (`getBoundedRect`, blitbuffer.lua:1673 @ koreader-base).
   That is what makes a viewport *clip* rather than merely describe a region.
2. `viewport` is a buffer over the same memory at an offset, so a write inside
   one lands in the parent at parent coordinates -- and a write outside one
   lands nowhere at all.

Every write is recorded twice: in `rects`, in the buffer's own coordinates, and
in the root buffer's `writes`, in root coordinates. The second is how a test
asks "did anything at all get painted outside the sheet".
]]
local FakeBB = {}
FakeBB.__index = FakeBB

local function newFakeBB(w, h, bbtype, root, ox, oy)
    local bb = setmetatable({
        w = w, h = h, bbtype = bbtype or 1,
        ox = ox or 0, oy = oy or 0,
        rects = {}, fills = {}, blits = {}, viewports = {},
        freed = false,
    }, FakeBB)
    bb.root = root or bb
    if bb.root == bb then bb.writes = {}; bb.clears = {} end
    return bb
end

function FakeBB:getWidth() return self.w end
function FakeBB:getHeight() return self.h end

--- Exactly getBoundedRect: clip to this buffer, and report nothing left over.
function FakeBB:_bound(x, y, w, h)
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    if x + w > self.w then w = self.w - x end
    if y + h > self.h then h = self.h - y end
    return x, y, w, h
end

function FakeBB:paintRect(x, y, w, h, c)
    x, y, w, h = self:_bound(x, y, w, h)
    if w <= 0 or h <= 0 then return end
    self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, c = c }
    local root = self.root
    root.writes[#root.writes + 1] =
        { x = x + self.ox, y = y + self.oy, w = w, h = h, c = c }
end

function FakeBB:fill(c)
    self.fills[#self.fills + 1] = c
    self:paintRect(0, 0, self.w, self.h, c)
end

function FakeBB:viewport(x, y, w, h)
    local v = newFakeBB(w, h, self.bbtype, self.root, self.ox + x, self.oy + y)
    self.viewports[#self.viewports + 1] = v
    return v
end

--- The bounded blit both entry points share. `alpha` is what separates them in
--- the record: the two calls carry the same rectangle, and only the recorded
--- flag says whether the source was copied over the destination or composed
--- onto it.
local function recordBlit(self, alpha, src, dest_x, dest_y, offs_x, offs_y, w, h)
    dest_x, dest_y = dest_x or 0, dest_y or 0
    offs_x, offs_y = offs_x or 0, offs_y or 0
    w = w or src.w
    h = h or src.h
    if dest_x < 0 then w = w + dest_x; offs_x = offs_x - dest_x; dest_x = 0 end
    if dest_y < 0 then h = h + dest_y; offs_y = offs_y - dest_y; dest_y = 0 end
    if dest_x + w > self.w then w = self.w - dest_x end
    if dest_y + h > self.h then h = self.h - dest_y end
    if offs_x + w > src.w then w = src.w - offs_x end
    if offs_y + h > src.h then h = src.h - offs_y end
    if w <= 0 or h <= 0 then return end
    self.blits[#self.blits + 1] = {
        src = src, dest_x = dest_x, dest_y = dest_y,
        offs_x = offs_x, offs_y = offs_y, w = w, h = h,
        alpha = alpha,
    }
end

function FakeBB:blitFrom(src, dest_x, dest_y, offs_x, offs_y, w, h)
    return recordBlit(self, false, src, dest_x, dest_y, offs_x, offs_y, w, h)
end

--[[--
The alpha composition, which a transparent overlay is painted with.

Real `alphablitFrom` leaves the destination untouched where the source's alpha
is 0, copies where it is 0xFF and blends in between; the fake has no pixels, so
what it can honestly record is that this call was made, over which rectangle,
and that it was not the opaque `blitFrom`. tests/conformance.lua states the
per-pixel behaviour against the real blitter.
]]
function FakeBB:alphablitFrom(src, dest_x, dest_y, offs_x, offs_y, w, h)
    return recordBlit(self, true, src, dest_x, dest_y, offs_x, offs_y, w, h)
end

function FakeBB:getType() return self.bbtype end

--[[--
The image encoder, as the export calls it.

`BlitBuffer:writeToFile` returns the results of a `pcall`, so a failure is
`false, message` and never a raise. Recording the call is what lets a spec
assert the two things that matter about it: that the format reaching KOReader
came from the closed set the job validated, and that the file written is the
job's own temporary rather than its destination.
]]
function FakeBB:writeToFile(filename, format, quality, grayscale)
    local root = self.root
    root.written = root.written or {}
    root.written[#root.written + 1] = {
        filename = filename, format = format, quality = quality,
        grayscale = grayscale, w = self.w, h = self.h,
    }
    if root.write_failure then return false, root.write_failure end
    return true
end

function FakeBB:free() self.freed = true end

function FakeBB:clear()
    self.rects, self.fills, self.blits, self.viewports = {}, {}, {}, {}
    if self.root == self then self.writes = {}; self.clears = {} end
end

--- How many recorded writes fall wholly or partly outside a rectangle. The
--- direct form of "nothing was painted outside the sheet".
function FakeBB:writesOutside(x, y, w, h)
    local n = 0
    for _, r in ipairs(self.root.writes) do
        if r.x < x or r.y < y or r.x + r.w > x + w or r.y + r.h > y + h then
            n = n + 1
        end
    end
    return n
end

function support.newBlitbuffer(w, h, bbtype)
    return newFakeBB(w, h, bbtype)
end

--[[--
The transparent clear, as the raster cache takes it: a plain function, not a
method on the buffer.

An overlay raster is cleared by writing zero bytes over its pixel rows -- the
only way to get alpha back to 0, because `fill` and `paintRect` force it to
0xFF -- and this fake has no pixels at all. Injecting the clear is what keeps
the fake honest: a `bb:clearTransparent` here would be a method the real
BlitBuffer does not have, so a spec built on it would prove something about
KOReader that is not true. What is recorded is the region, in root
coordinates, exactly as `writes` records a paint.
]]
function support.recordingClear()
    return function(bb, x, y, w, h)
        local root = bb.root
        root.clears[#root.clears + 1] =
            { x = x + bb.ox, y = y + bb.oy, w = w, h = h }
        return true
    end
end

--[[--
The blitbuffer module, with strings where the real one has colours.

Worth knowing before trusting a colour assertion built on this: a real colour
is cdata carrying an `__eq` that indexes its argument, so `color == nil` raises
under LuaJIT where here it merely answers false. A guard written against this
fake can therefore be wrong in production and green here -- which is what
happened to `ink_paper`, and why tests/conformance.lua now states that
difference against a real BlitBuffer.
]]
function support.newBlitbufferModule()
    return {
        COLOR_BLACK = "black",
        COLOR_WHITE = "white",
        -- The real values (koreader-base ffi/blitbuffer.lua @ 6e4bc81a), so a
        -- test that asserts an export asked for BB8 is asserting the number
        -- KOReader would have been handed.
        TYPE_BB4 = 0,
        TYPE_BB8 = 1,
        TYPE_BB8A = 2,
        TYPE_BBRGB16 = 3,
        TYPE_BBRGB24 = 4,
        TYPE_BBRGB32 = 5,
        new = function(w, h, bbtype) return newFakeBB(w, h, bbtype or 1) end,
        --- The real one is `ffi.string(bb.data, bb.stride * bb.h)`. A white
        --- page is the honest stand-in: the fake has no pixel storage, so a
        --- spec can assert the *length* contract -- which is the one the PDF
        --- writer depends on -- and nothing about content.
        tostring = function(bb) return string.rep("\255", bb.w * bb.h) end,
    }
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
    screen.bb = support.newBlitbuffer(screen.w, screen.h)
    function screen:getWidth() return self.w end
    function screen:getHeight() return self.h end
    function screen:scaleByDPI(value)
        return math.floor(value * (opts.dpi or 160) / 160 + 0.5)
    end
    function screen:scaleBySize(value) return math.floor(value + 0.5) end
    function screen:getRotationMode() return self.rotation end
    function screen:refreshFast(x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { "fast", x, y, w, h }
    end
    function screen:refreshPartial(x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { "partial", x, y, w, h }
    end
    -- The non-fenced grayscale mode live gray ink rides (ADR-36); the real
    -- method's existence is stated in conformance.lua.
    function screen:refreshUI(x, y, w, h)
        self.refreshes[#self.refreshes + 1] = { "ui", x, y, w, h }
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
    if not first and sql:find("wal_checkpoint") then return 0, 0, 0 end
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
    local driver = { opened = {}, modes = {}, conns = {} }
    function driver.open(path, mode)
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
        driver.modes[#driver.modes + 1] = mode
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
    --- y first, x second -- the same order the real one returns, which is easy
    --- to get backwards and would put every mark at the left edge.
    function doc:getScreenPositionFromXPointer(xp)
        self.screen_positions = (self.screen_positions or 0) + 1
        local page = self.pages[xp]
        if page == nil then return nil end
        return (page - self.current_page) * 40 + 20, 5
    end
    function doc:getDocumentRenderingHash() return self.hash end
    function doc:getDomVersionWithNormalizedXPointers()
        return self.normalized_dom_version
    end
    return doc
end

-- ------------------------------------------------------- fake reader view

--[[--
The live fixed-layout reader, as `ink_document_transform` reads it.

Only the fields the page-ink transform touches are modelled, and they are the
fields KOReader's own `getSinglePagePosition` reads: `state.offset`,
`state.zoom`, `visible_area` and the view's own `dimen`. A ReaderView carries
another forty; putting them here would make this look like something it can be
trusted to be.

Two defaults model KOReader rather than convenience, and `tests/conformance.lua`
states both against the real thing: the native page size is a non-integer pair
of points, because MuPDF measures in 1/72 in and does not round, so a surface
geometry has to be rounded up somewhere; and `state.offset` is a table only
after a `recalculate` has run -- `ReaderView:init` leaves it nil, which is the
state a view event can find the reader in.

Anywhere inside `state`, `visible_area` or `dimen`, a `false` means "this field
is not there": `state = { offset = false }` is the view before its first
recalculate. The same goes for `configurable`, `koptinterface`, `native` and
`document` themselves.

opts.paging         ui.paging (default true)
opts.rolling        ui.rolling (default false)
opts.page_scroll    view.page_scroll (default false)
opts.state          over { page = 1, zoom = 2, rotation = 0,
                    offset = { x = 0, y = 0 } }
opts.visible_area   over { x = 0, y = 0, w = 1000, h = 1400 }
opts.dimen          over { x = 0, y = 0, w = 1000, h = 1400 }
opts.provider       document.provider (default "mupdf")
opts.configurable   document.configurable (default {})
opts.koptinterface  document.koptinterface (default absent)
opts.native         what getNativePageDimensions answers
                    (default { w = 595.276, h = 841.89 }; false answers nil)
opts.document       the whole document, or false for a view without one
]]
local function viewField(defaults, over)
    if over == false then return nil end
    local out = {}
    for k, v in pairs(defaults) do out[k] = v end
    if type(over) == "table" then
        for k, v in pairs(over) do
            if v == false then out[k] = nil else out[k] = v end
        end
    end
    return out
end

function support.newReaderView(opts)
    opts = opts or {}
    local document = opts.document
    if document == nil then
        local native = opts.native
        if native == nil then native = { w = 595.276, h = 841.89 } end
        document = {
            provider = opts.provider or "mupdf",
            configurable = opts.configurable == nil and {}
                or (opts.configurable or nil),
            koptinterface = opts.koptinterface or nil,
            getNativePageDimensions = function(_, page)
                if not native or not page then return nil end
                return { w = native.w, h = native.h }
            end,
        }
    elseif document == false then
        document = nil
    end

    local view = {
        document = document,
        page_scroll = opts.page_scroll == true,
        state = viewField(
            { page = 1, zoom = 2, rotation = 0, offset = { x = 0, y = 0 } },
            opts.state),
        visible_area = viewField({ x = 0, y = 0, w = 1000, h = 1400 },
            opts.visible_area),
        dimen = viewField({ x = 0, y = 0, w = 1000, h = 1400 }, opts.dimen),
    }
    local ui = {
        paging = opts.paging ~= false,
        rolling = opts.rolling == true,
        document = document,
    }
    return { ui = ui, view = view }
end

-- ------------------------------------------------------- fake canvas store

--[[--
An in-memory stand-in for the canvas repository.

This one fakes an *interface*, not a database: the methods the anchor index,
the sessions and the export actually call, backed by Lua tables. The
repository's own behaviour is covered against a recorder and against real
SQLite elsewhere, so nothing here is claiming anything about SQL. What it gives
the index tests is a call count, which is how "a page turn issues no query"
becomes a check rather than a claim.

Two things it does model, because a fake that got them wrong would let a whole
suite pass over a broken device: rowid reuse, and the surface roles -- sheets
and page ink are separate listings with separate cursors, and a spec the
schema's CHECKs would reject is refused here too (ADR-37).
]]
function support.newCanvasStore(canvases)
    local store = {
        canvases = canvases or {},
        layouts = {},        -- [hash] = { [canvas_id] = page }
        calls = { list = 0, read = 0, save = 0 },
        saves = {},          -- every saveLayoutPages call, in order
    }
    --- The role a row plays. A row that never stated one is a sheet, exactly
    --- the way the column's DEFAULT reads back for every row written before
    --- schema v2 -- so a fixture built as a bare table is still a sheet here.
    local function roleOf(canvas) return canvas.surface_role or "sheet" end

    function store:listCanvases()
        self.calls.list = self.calls.list + 1
        if self.fail_list_canvases then return nil, self.fail_list_canvases end
        -- A fresh array, the way the real repository builds one per query.
        -- Handing out the live table lets a caller that appends to the result
        -- quietly grow the store, which is a bug the fake would then hide.
        -- Sheets only, like `listCanvases`: page ink has no anchor to resolve.
        local out = {}
        for i = 1, #self.canvases do
            if roleOf(self.canvases[i]) == "sheet" then
                out[#out + 1] = self.canvases[i]
            end
        end
        return out
    end
    function store:layoutPages(_, hash)
        self.calls.read = self.calls.read + 1
        return self.layouts[hash] or {}
    end
    function store:saveLayoutPages(_, hash, pages, finalize)
        self.calls.save = self.calls.save + 1
        local copy = {}
        for id, page in pairs(pages) do copy[id] = page end
        local layout = self.layouts[hash]
        if not layout then layout = {}; self.layouts[hash] = layout end
        for id, page in pairs(copy) do layout[id] = page end
        self.saves[#self.saves + 1] = {
            hash = hash, pages = copy, finalize = finalize == true,
        }
        return true
    end

    --- Strokes are held with their points attached, but `listStrokes` hands
    --- back metadata only and `readStroke` is counted. The cache's central
    --- promise -- that a repaint decodes nothing -- is that counter staying
    --- still.
    store.strokes = {}          -- [canvas_id] = { { meta..., points = {}, n = } }
    store.next_stroke_id = 1
    store.calls.stroke_list = 0
    store.calls.stroke_read = 0
    store.calls.stroke_chunk = 0

    function store:putStroke(canvas_id, stroke)
        local list = self.strokes[canvas_id]
        if not list then
            list = {}
            self.strokes[canvas_id] = list
        end
        -- SQLite semantics, not a monotonic counter: `id INTEGER PRIMARY KEY`
        -- without AUTOINCREMENT assigns max(rowid)+1 over the rows that exist
        -- NOW, so deleting the newest stroke frees its id for the next
        -- insert. A fake that never reused ids hid a real id-reuse bug from
        -- the whole suite (device log 2026-09-01, chunk_count_meta).
        if not stroke.id then
            local max_id = 0
            for _, rows in pairs(self.strokes) do
                for _, s in ipairs(rows) do
                    if s.id > max_id then max_id = s.id end
                end
            end
            stroke.id = max_id + 1
        end
        stroke.seq = stroke.seq or (#list + 1)
        local min_x, min_y = stroke.points[1], stroke.points[2]
        local max_x, max_y = min_x, min_y
        for i = 2, stroke.n do
            local x, y = stroke.points[i * 2 - 1], stroke.points[i * 2]
            if x < min_x then min_x = x elseif x > max_x then max_x = x end
            if y < min_y then min_y = y elseif y > max_y then max_y = y end
        end
        stroke.min_x, stroke.min_y = min_x, min_y
        stroke.max_x, stroke.max_y = max_x, max_y
        stroke.point_count = stroke.n
        list[#list + 1] = stroke
        return stroke.id
    end

    function store:listStrokes(canvas_id)
        self.calls.stroke_list = self.calls.stroke_list + 1
        if self.fail_stroke_list then return nil, self.fail_stroke_list end
        local out = {}
        for _, s in ipairs(self.strokes[canvas_id] or {}) do
            out[#out + 1] = {
                id = s.id, seq = s.seq, width = s.width, tool = s.tool,
                codec = 1, point_count = s.point_count,
                min_x = s.min_x, min_y = s.min_y, max_x = s.max_x, max_y = s.max_y,
            }
        end
        table.sort(out, function(a, b) return a.seq < b.seq end)
        return out
    end

    function store:readStroke(canvas, meta)
        self.calls.stroke_read = self.calls.stroke_read + 1
        for _, s in ipairs(self.strokes[canvas.id] or {}) do
            if s.id == meta.id then return s.points, s.n end
        end
        return nil, "empty"
    end

    local Codec = require("ink_canvas_codec")
    function store:openStrokeCursor(stroke_id)
        self.calls.stroke_read = self.calls.stroke_read + 1
        if self.fail_stroke_cursor then return nil, self.fail_stroke_cursor end
        local found, found_canvas_id
        for canvas_id, list in pairs(self.strokes) do
            for _, s in ipairs(list) do
                if s.id == stroke_id then found = s; found_canvas_id = canvas_id; break end
            end
            if found then break end
        end
        if not found then return nil, "empty" end
        local logical_w, logical_h = 1860, 2480
        for _, canvas in ipairs(self.canvases) do
            if canvas.id == found_canvas_id then
                logical_w, logical_h = canvas.logical_w, canvas.logical_h
                break
            end
        end
        local valid, err = Codec.validate(found.points, found.n,
            logical_w, logical_h)
        if not valid then return nil, err end
        local at, closed = 0, false
        local owner = self
        local function chunkAt(chunk_no)
            local first
            if chunk_no == 0 then first = 1
            else first = chunk_no * (Codec.MAX_POINTS - 1) + 1 end
            if first > found.n then return nil end
            local last = math.min(first + Codec.MAX_POINTS - 1, found.n)
            local part = {}
            for i = first, last do
                part[#part + 1] = found.points[i * 2 - 1]
                part[#part + 1] = found.points[i * 2]
            end
            local chunks, encode_err = Codec.encode(part, last - first + 1,
                logical_w, logical_h)
            if not chunks then return nil, encode_err end
            return chunks[1]
        end
        return {
            next = function(cursor)
                if closed then return nil, "closed" end
                local chunk, chunk_err = chunkAt(at)
                if chunk_err then closed = true; return nil, chunk_err end
                if not chunk then
                    closed = true
                    if owner.fail_stroke_cursor_close then
                        return nil, owner.fail_stroke_cursor_close
                    end
                    return nil, nil, true
                end
                owner.calls.stroke_chunk = owner.calls.stroke_chunk + 1
                if owner.fail_stroke_chunk == at then
                    closed = true
                    return nil, "chunk failed"
                end
                local row = { chunk_no = at, point_count = chunk.point_count,
                    points = chunk.points }
                at = at + 1
                return row
            end,
            close = function(cursor)
                closed = true
                if owner.fail_stroke_cursor_close then
                    return nil, owner.fail_stroke_cursor_close
                end
                return true
            end,
        }
    end

    function store:readStrokeChunk(stroke_id, chunk_no)
        self.calls.stroke_read = self.calls.stroke_read + 1
        if self.fail_stroke_cursor then return nil, self.fail_stroke_cursor end
        local found, found_canvas_id
        for canvas_id, list in pairs(self.strokes) do
            for _, stroke in ipairs(list) do
                if stroke.id == stroke_id then
                    found, found_canvas_id = stroke, canvas_id
                    break
                end
            end
            if found then break end
        end
        if not found then return nil, "empty" end
        if self.fail_stroke_chunk == chunk_no then return nil, "chunk failed" end
        local logical_w, logical_h = 1860, 2480
        for _, canvas in ipairs(self.canvases) do
            if canvas.id == found_canvas_id then
                logical_w, logical_h = canvas.logical_w, canvas.logical_h
                break
            end
        end
        local first = chunk_no == 0 and 1
            or chunk_no * (Codec.MAX_POINTS - 1) + 1
        if first > found.n then return nil, "missing_chunk" end
        local last = math.min(first + Codec.MAX_POINTS - 1, found.n)
        local part = {}
        for i = first, last do
            part[#part + 1] = found.points[i * 2 - 1]
            part[#part + 1] = found.points[i * 2]
        end
        local chunks, encode_err = Codec.encode(part, last - first + 1,
            logical_w, logical_h)
        if not chunks then return nil, encode_err end
        self.calls.stroke_chunk = self.calls.stroke_chunk + 1
        return {
            chunk_no = chunk_no,
            point_count = chunks[1].point_count,
            points = chunks[1].points,
        }
    end

    function store:addStroke(canvas, stroke)
        return self:putStroke(canvas.id, stroke)
    end

    function store:deleteStroke(stroke_id)
        self.deleted[#self.deleted + 1] = stroke_id
        for _, list in pairs(self.strokes) do
            for i = #list, 1, -1 do
                if list[i].id == stroke_id then table.remove(list, i) end
            end
        end
        return true
    end
    store.deleted = {}

    --[[--
    A transaction that restores inserts and deletes.

    Queue may mix a persisted DELETE with a new INSERT in one flush, so a fake
    that only truncates appended rows would let retry and atomicity tests pass
    while leaving the deletion applied.
    ]]
    --- The rest of the repository interface the session drives.
    store.calls.book = 0
    store.next_canvas_id = 100
    store.closed = false
    store.identity = nil

    function store:bookId(partial_md5, file_size, last_path)
        self.calls.book = self.calls.book + 1
        if not partial_md5 or not file_size then return nil, "no_identity" end
        self.identity = { partial_md5, file_size, last_path }
        return 12
    end

    --[[--
    The surface a spec describes, or nil for one the schema would refuse.

    Deliberately a copy of `ink_canvas_repository`'s rule rather than a call
    into it: a fake that shares the implementation can never disagree with it,
    and so can never catch the day the rule itself is what changed. A copy can
    drift, which is why tests/conformance.lua states every one of these against
    SQLite's own CHECK and UNIQUE constraints, and canvas_repository_spec runs
    both over one table of refusals.
    ]]
    local function surfaceOf(spec)
        local kind = spec.anchor_kind or "xpointer"
        local role = spec.surface_role or "sheet"
        local space = spec.coordinate_space
        if role == "sheet" then
            if space == nil then space = "surface" end
            if space ~= "surface" then return nil end
        elseif role == "page_ink" then
            if space == nil then space = "native_page" end
            if space ~= "native_page" then return nil end
            if kind ~= "page" then return nil end
            local page = spec.fixed_page
            if type(page) ~= "number" or page ~= page
                or page == math.huge or page == -math.huge
                or page < 1 or page ~= math.floor(page) then
                return nil
            end
            if spec.anchor_raw ~= nil or spec.anchor_normalized ~= nil
                or spec.anchor_dom_version ~= nil then
                return nil
            end
        else
            return nil
        end
        return role, space
    end

    --- Absent or unusable falls back to the default, anything else is clamped
    --- to 1..500 -- `ink_canvas_repository.batchLimit`, so a suite that pages
    --- through the fake sees the batch sizes the device will see.
    local function batchLimit(v, default)
        local n = tonumber(v)
        if n == nil or n ~= n then return default end
        n = math.floor(n)
        if n < 1 then return 1 end
        if n > 500 then return 500 end
        return n
    end

    function store:createCanvas(book_id, spec)
        if self.fail_create then return nil, self.fail_create end
        local role, space = surfaceOf(spec)
        if not role then return nil, "bad_surface" end
        for _, c in ipairs(self.canvases) do
            if c.anchor_key == spec.anchor_key then return nil, "duplicate" end
        end
        self.next_canvas_id = self.next_canvas_id + 1
        local canvas = {
            id = self.next_canvas_id,
            book_id = book_id,
            anchor_kind = spec.anchor_kind,
            anchor_key = spec.anchor_key,
            anchor_raw = spec.anchor_raw,
            anchor_normalized = spec.anchor_normalized,
            anchor_dom_version = spec.anchor_dom_version,
            fixed_page = spec.fixed_page,
            surface_role = role,
            coordinate_space = space,
            logical_w = spec.logical_w,
            logical_h = spec.logical_h,
        }
        self.canvases[#self.canvases + 1] = canvas
        return canvas
    end

    function store:countCanvases()
        if self.fail_count_canvases then return nil, self.fail_count_canvases end
        local n = 0
        for i = 1, #self.canvases do
            if roleOf(self.canvases[i]) == "sheet" then n = n + 1 end
        end
        return n
    end

    --- Sheet metadata by id, the way the index pages through it. Counted as a
    --- listing, and pointedly not as a stroke read: the promise this fake is
    --- here to check is that building an index opens no stroke at all.
    function store:listCanvasesBatch(_, opts)
        self.calls.list = self.calls.list + 1
        if self.fail_list_canvases then return nil, self.fail_list_canvases end
        opts = opts or {}
        local limit = batchLimit(opts.limit, 200)
        local after_id = tonumber(opts.after_id)
        local rows = {}
        for i = 1, #self.canvases do
            local c = self.canvases[i]
            if roleOf(c) == "sheet" and (not after_id or c.id > after_id) then
                rows[#rows + 1] = c
            end
        end
        table.sort(rows, function(a, b) return a.id < b.id end)
        local out = {}
        for i = 1, math.min(#rows, limit) do out[i] = rows[i] end
        return out
    end

    function store:findPageInkSurface(_, fixed_page)
        if self.fail_find_page_ink then return nil, self.fail_find_page_ink end
        for i = 1, #self.canvases do
            local c = self.canvases[i]
            if roleOf(c) == "page_ink" and c.fixed_page == fixed_page then
                return c
            end
        end
        return nil, "not_found"
    end

    function store:createPageInkSurface(book_id, fixed_page, logical_w, logical_h)
        return self:createCanvas(book_id, {
            anchor_kind = "page",
            anchor_key = "page-ink:" .. tostring(fixed_page),
            fixed_page = fixed_page,
            surface_role = "page_ink",
            coordinate_space = "native_page",
            logical_w = logical_w,
            logical_h = logical_h,
        })
    end

    --- Page ink by `(fixed_page, id)`, keyset-paginated. The pair, not the
    --- page: see `Repository.listPageInkSurfaces`.
    function store:listPageInkSurfaces(_, opts)
        if self.fail_list_page_ink then return nil, self.fail_list_page_ink end
        opts = opts or {}
        local limit = batchLimit(opts.limit, 100)
        local after_page = tonumber(opts.after_page)
        local after_id = after_page and (tonumber(opts.after_id) or 0) or nil
        local rows = {}
        for i = 1, #self.canvases do
            local c = self.canvases[i]
            if roleOf(c) == "page_ink"
                and (not after_page
                     or c.fixed_page > after_page
                     or (c.fixed_page == after_page and c.id > after_id)) then
                rows[#rows + 1] = c
            end
        end
        table.sort(rows, function(a, b)
            if a.fixed_page ~= b.fixed_page then return a.fixed_page < b.fixed_page end
            return a.id < b.id
        end)
        local out = {}
        for i = 1, math.min(#rows, limit) do out[i] = rows[i] end
        return out
    end

    function store:countPageInkSurfaces()
        local n = 0
        for i = 1, #self.canvases do
            if roleOf(self.canvases[i]) == "page_ink" then n = n + 1 end
        end
        return n
    end

    function store:deletePageInkSurface(_, fixed_page)
        if self.fail_delete_canvas then return nil, self.fail_delete_canvas end
        for i = #self.canvases, 1, -1 do
            local c = self.canvases[i]
            if roleOf(c) == "page_ink" and c.fixed_page == fixed_page then
                self.strokes[c.id] = nil
                table.remove(self.canvases, i)
            end
        end
        return true
    end

    function store:deleteAllPageInkSurfaces()
        if self.fail_delete_canvas then return nil, self.fail_delete_canvas end
        for i = #self.canvases, 1, -1 do
            local c = self.canvases[i]
            if roleOf(c) == "page_ink" then
                self.strokes[c.id] = nil
                table.remove(self.canvases, i)
            end
        end
        return true
    end

    function store:deleteCanvas(canvas_id)
        if self.fail_delete_canvas then return nil, self.fail_delete_canvas end
        for i = #self.canvases, 1, -1 do
            if self.canvases[i].id == canvas_id then table.remove(self.canvases, i) end
        end
        self.strokes[canvas_id] = nil
        return true
    end

    function store:touchCanvas()
        if self.fail_touch then return nil, self.fail_touch end
        return true
    end

    function store:close() self.closed = true end

    store.calls.transaction = 0
    store.fail_transaction = nil
    function store:transaction(fn)
        self.calls.transaction = self.calls.transaction + 1
        if self.fail_transaction == "begin" then return nil, "cannot begin" end
        local before = {}
        for cid, list in pairs(self.strokes) do
            before[cid] = {}
            for i = 1, #list do before[cid][i] = list[i] end
        end
        local next_id = self.next_stroke_id
        local deleted_count = #self.deleted
        local ok, res, err = pcall(fn, self)
        if self.fail_transaction == "commit" then
            ok, res, err = true, nil, "cannot commit"
        end
        if not ok or res == nil then
            self.strokes = before
            self.next_stroke_id = next_id
            for i = #self.deleted, deleted_count + 1, -1 do
                table.remove(self.deleted, i)
            end
            return nil, ok and err or res
        end
        return res
    end

    return store
end

-- ------------------------------------------------------ fake notebook store

--- In-memory implementation of the notebook domain plus the generic stroke
--- repository. It intentionally counts metadata and point operations
--- separately so scale tests can prove that library/page navigation never
--- opens stroke payloads.
function support.newNotebookStore(opts)
    opts = opts or {}
    local pages = opts.pages or {
        { id = 11, notebook_id = 1, sort_key = 1024,
          logical_w = 1000, logical_h = 1400, template_kind = "blank" },
    }
    local store = support.newCanvasStore(pages)
    store.notebooks = opts.notebooks or {
        { id = 1, title = "Notebook", page_count = #pages,
          next_sort_key = (#pages + 1) * 1024,
          -- A notebook with no live pages is a real state (every page
          -- tombstoned), and the fake has to be able to hold it.
          current_page_id = pages[1] and pages[1].id or nil,
          created_at = 1, updated_at = 1 },
    }
    store.pages = pages
    store.calls.list_notebooks = 0
    store.calls.list_pages = 0
    store.calls.select_page = 0
    store.calls.purge = 0

    local function activeNotebook(id)
        for _, n in ipairs(store.notebooks) do
            if n.id == id and not n.deleted_at then return n end
        end
    end
    local function activePage(id)
        for _, p in ipairs(store.pages) do
            if p.id == id and not p.deleted_at then return p end
        end
    end
    local function copyRow(row)
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        return copy
    end

    function store:listNotebooks(spec)
        self.calls.list_notebooks = self.calls.list_notebooks + 1
        spec = spec or {}
        local limit = math.min(tonumber(spec.limit) or 50, 200)
        local out = {}
        for _, n in ipairs(self.notebooks) do
            if not n.deleted_at then
                out[#out + 1] = copyRow(n)
                if #out >= limit then break end
            end
        end
        return out
    end

    function store:getNotebook(id)
        if self.fail_get_notebook then return nil, self.fail_get_notebook end
        local n = activeNotebook(id)
        return n and copyRow(n) or nil, n and nil or "not_found"
    end

    function store:listPages(notebook_id, spec)
        self.calls.list_pages = self.calls.list_pages + 1
        spec = spec or {}
        local limit = math.min(tonumber(spec.limit) or 50, 200)
        local out = {}
        for _, p in ipairs(self.pages) do
            if p.notebook_id == notebook_id and not p.deleted_at
                and (not spec.after_sort_key
                    or p.sort_key > spec.after_sort_key
                    or p.sort_key == spec.after_sort_key and p.id > spec.after_id) then
                out[#out + 1] = p
                if #out >= limit then break end
            end
        end
        table.sort(out, function(a, b)
            return a.sort_key == b.sort_key and a.id < b.id
                or a.sort_key < b.sort_key
        end)
        return out
    end

    function store:getPage(id)
        if self.fail_get_page then return nil, self.fail_get_page end
        local p = activePage(id)
        return p or nil, p and nil or "not_found"
    end

    function store:selectCurrentPage(notebook_id, page_id)
        self.calls.select_page = self.calls.select_page + 1
        if self.fail_select_page then return nil, self.fail_select_page end
        local n, p = activeNotebook(notebook_id), activePage(page_id)
        if not n or not p or p.notebook_id ~= notebook_id then return nil, "not_found" end
        n.current_page_id = page_id
        return true
    end

    function store:previousPage(page)
        local best
        for _, p in ipairs(self.pages) do
            if p.notebook_id == page.notebook_id and not p.deleted_at
                and (p.sort_key < page.sort_key
                    or p.sort_key == page.sort_key and p.id < page.id)
                and (not best or p.sort_key > best.sort_key
                    or p.sort_key == best.sort_key and p.id > best.id) then
                best = p
            end
        end
        return best
    end

    function store:nextPage(page)
        local best
        for _, p in ipairs(self.pages) do
            if p.notebook_id == page.notebook_id and not p.deleted_at
                and (p.sort_key > page.sort_key
                    or p.sort_key == page.sort_key and p.id > page.id)
                and (not best or p.sort_key < best.sort_key
                    or p.sort_key == best.sort_key and p.id < best.id) then
                best = p
            end
        end
        return best
    end

    function store:appendPage(notebook_id, spec)
        if self.fail_append then return nil, self.fail_append end
        local n = activeNotebook(notebook_id)
        if not n then return nil, "not_found" end
        local page = {
            id = 10 + #self.pages + 1, notebook_id = notebook_id,
            sort_key = n.next_sort_key, logical_w = spec.logical_w,
            logical_h = spec.logical_h, template_kind = spec.template_kind or "blank",
        }
        self.pages[#self.pages + 1] = page
        n.next_sort_key = n.next_sort_key + 1024
        n.page_count = n.page_count + 1
        return page
    end

    function store:softDeletePage(notebook_id, page_id)
        local n, p = activeNotebook(notebook_id), activePage(page_id)
        if not n or not p then return nil, "not_found" end
        if n.page_count <= 1 then return nil, "last_page" end
        local selected = self:previousPage(p) or self:nextPage(p)
        p.deleted_at = 1
        n.page_count = n.page_count - 1
        if n.current_page_id == p.id then n.current_page_id = selected.id end
        return selected
    end

    function store:createNotebook(spec)
        if self.fail_create_notebook then return nil, self.fail_create_notebook end
        local id = #self.notebooks + 1
        local page = {
            id = 10 + #self.pages + 1, notebook_id = id, sort_key = 1024,
            logical_w = spec.logical_w, logical_h = spec.logical_h,
            template_kind = spec.template_kind or "blank",
        }
        local notebook = {
            id = id, title = spec.title, page_count = 1,
            next_sort_key = 2048, current_page_id = page.id,
        }
        self.notebooks[#self.notebooks + 1] = notebook
        self.pages[#self.pages + 1] = page
        return notebook, page
    end

    function store:renameNotebook(id, title)
        local n = activeNotebook(id)
        if not n then return nil, "not_found" end
        n.title = title
        return true
    end

    --- Mirrors the repository's strict acceptance: creation is permissive so a
    --- future template name survives, but a kind that is about to rule paper
    --- has to be one this build can draw.
    function store:setPageTemplate(notebook_id, page_id, kind)
        if self.fail_set_template then return nil, self.fail_set_template end
        local n, p = activeNotebook(notebook_id), activePage(page_id)
        if not n or not p or p.notebook_id ~= notebook_id then
            return nil, "not_found"
        end
        if kind ~= "blank" and kind ~= "ruled"
            and kind ~= "grid" and kind ~= "dots" then
            return nil, "bad_template"
        end
        p.template_kind = kind
        return true
    end

    function store:softDeleteNotebook(id)
        local n = activeNotebook(id)
        if not n then return nil, "not_found" end
        n.deleted_at = 1
        return true
    end

    function store:purgeDeletedBatch()
        self.calls.purge = self.calls.purge + 1
        return { chunks = 0, strokes = 0, pages = 0, notebooks = 0, changed = 0 }
    end

    return store
end

--[[--
A deterministic scheduler with KOReader's identity-based cancellation rules.

Callbacks are ordered by due time and then insertion order. Nothing runs until
a test pumps or advances the clock, which makes delayed-to-urgent replacement,
idle cleanup and stale-generation callbacks observable without wall time.
`schedule` remains the next-tick shorthand used by the older suites.
]]
--[[--
A filesystem, in a table, with the four calls an export makes of one.

Modelled from the real ones rather than invented, because the job's failure
handling is written against their exact shapes and a friendlier stub would
make all of it pass for the wrong reason:

1. `io.open` answers `nil, message` when it cannot open, and the handle's
   `write` answers the handle itself on success -- truthy, not `true`.
2. `file:close()` is where a buffered write finally fails, which is why the
   job checks it before renaming rather than assuming success.
3. `os.rename` and `os.remove` answer `nil, message`, not `false`.
4. `seek()` reports the handle's own idea of the offset, which is what the
   PDF writer cross-checks its counted offsets against.

`fail_open`, `fail_write`, `fail_close` and `fail_rename` are keyed by path so
a spec can break exactly one step of one page.
]]
function support.newExportFs(opts)
    opts = opts or {}
    local fs = {
        files = opts.files or {},
        dirs = opts.dirs or {},
        opened = {}, renames = {}, removes = {},
        fail_open = opts.fail_open or {},
        fail_write = opts.fail_write or {},
        fail_close = opts.fail_close or {},
        fail_rename = opts.fail_rename or {},
        fail_remove = opts.fail_remove or {},
        -- Modification times, for the sweep's minimum age. A file with none
        -- recorded answers nil, which is what the real `lfs` does for a file
        -- that vanished between the listing and the stat -- and a temporary
        -- of unknown age must never be offered for deletion.
        mtimes = opts.mtimes or {},
    }

    function fs.attributes(path, what)
        if what == "mode" then
            if fs.dirs[path] then return "directory" end
            if fs.files[path] ~= nil then return "file" end
            return nil
        end
        if what == "size" then
            local content = fs.files[path]
            return content and #content or nil
        end
        if what == "modification" then
            if fs.files[path] == nil and not fs.dirs[path] then return nil end
            return fs.mtimes[path]
        end
        return nil
    end

    --[[--
    `lfs.dir`, including the parts that are easy to forget.

    It yields "." and ".." before anything else, and it *raises* for a
    directory that is not there rather than answering nil. Both are why
    `Export.orphans` looks the way it does, so the fake has to do both or the
    pcall in production would be untested ceremony.
    ]]
    function fs.dir(path)
        if not fs.dirs[path] then
            error("cannot open " .. tostring(path) .. ": No such file or directory")
        end
        local names = { ".", ".." }
        local prefix = path == "/" and "/" or (path .. "/")
        for entry in pairs(fs.files) do
            local rest = entry:sub(1, #prefix) == prefix and entry:sub(#prefix + 1) or nil
            if rest and rest ~= "" and not rest:find("/", 1, true) then
                names[#names + 1] = rest
            end
        end
        for entry in pairs(fs.dirs) do
            local rest = entry:sub(1, #prefix) == prefix and entry:sub(#prefix + 1) or nil
            if rest and rest ~= "" and not rest:find("/", 1, true) then
                names[#names + 1] = rest
            end
        end
        table.sort(names, function(a, b)
            -- "." and ".." first, as the real one does; the rest in a stable
            -- order so a spec can rely on what the cap truncates.
            local rank_a = (a == "." and 0) or (a == ".." and 1) or 2
            local rank_b = (b == "." and 0) or (b == ".." and 1) or 2
            if rank_a ~= rank_b then return rank_a < rank_b end
            return a < b
        end)
        local i = 0
        return function()
            i = i + 1
            return names[i]
        end
    end

    function fs.open(path, mode)
        fs.opened[#fs.opened + 1] = { path = path, mode = mode }
        if fs.fail_open[path] then return nil, fs.fail_open[path] end
        local parts, offset, closed = {}, 0, false
        local handle = {}
        function handle:write(chunk)
            if closed then return nil, "closed" end
            if fs.fail_write[path] then return nil, fs.fail_write[path] end
            parts[#parts + 1] = chunk
            offset = offset + #chunk
            return handle
        end
        function handle:seek() return offset end
        function handle:close()
            if closed then return true end
            closed = true
            -- The real one answers `true` or `nil, message, errno` -- never
            -- `false`. Saying `false` here is what let a `== false` test in
            -- the job pass while the production check was dead.
            if fs.fail_close[path] then return nil, fs.fail_close[path], 28 end
            fs.files[path] = table.concat(parts)
            return true
        end
        return handle
    end

    function fs.rename(from, to)
        fs.renames[#fs.renames + 1] = { from = from, to = to }
        if fs.fail_rename[from] then return nil, fs.fail_rename[from] end
        if fs.files[from] == nil then return nil, "no such file or directory" end
        fs.files[to] = fs.files[from]
        fs.files[from] = nil
        return true
    end

    function fs.remove(path)
        fs.removes[#fs.removes + 1] = path
        if fs.fail_remove[path] then return nil, fs.fail_remove[path] end
        if fs.files[path] == nil then return nil, "no such file or directory" end
        fs.files[path] = nil
        return true
    end

    --- Every path that still exists and carries the export's private prefix.
    --- "Left nothing of its own behind" is otherwise untestable.
    function fs.temporaries(prefix)
        local out = {}
        for path in pairs(fs.files) do
            if path:find(prefix, 1, true) then out[#out + 1] = path end
        end
        table.sort(out)
        return out
    end

    return fs
end

function support.newScheduler(start_time)
    local s = { queue = {}, clock = tonumber(start_time) or 0, serial = 0 }

    local function before(a, b)
        return a.due < b.due or (a.due == b.due and a.serial < b.serial)
    end

    function s:now() return self.clock end

    function s:scheduleIn(delay, fn)
        assert(type(fn) == "function", "scheduled action must be a function")
        delay = tonumber(delay) or 0
        if delay < 0 then delay = 0 end
        self.serial = self.serial + 1
        local item = { due = self.clock + delay, serial = self.serial, fn = fn }
        local at = #self.queue + 1
        while at > 1 and before(item, self.queue[at - 1]) do
            self.queue[at] = self.queue[at - 1]
            at = at - 1
        end
        self.queue[at] = item
        return fn
    end

    function s:schedule(fn) return self:scheduleIn(0, fn) end

    function s:unschedule(fn)
        local removed = false
        for i = #self.queue, 1, -1 do
            if self.queue[i].fn == fn then
                table.remove(self.queue, i)
                removed = true
            end
        end
        return removed
    end

    --- Run one callback due at the current virtual time.
    function s:tick()
        local item = self.queue[1]
        if not item or item.due > self.clock then return false end
        table.remove(self.queue, 1)
        item.fn()
        return true
    end

    --- Run all callbacks due now, with a bound for scheduling loops.
    function s:drain(limit)
        local n = 0
        while self:tick() do
            n = n + 1
            if n > (limit or 10000) then error("scheduler did not settle", 0) end
        end
        return n
    end

    function s:advance(seconds, limit)
        seconds = tonumber(seconds) or 0
        assert(seconds >= 0, "virtual time cannot move backwards")
        self.clock = self.clock + seconds
        return self:drain(limit)
    end

    function s:pending(fn)
        if fn == nil then return #self.queue end
        local n = 0
        for i = 1, #self.queue do
            if self.queue[i].fn == fn then n = n + 1 end
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
        dialogs = {},
        reader_events = {},
        logs = { warn = {}, err = {}, info = {} },
        dispatcher_actions = {},
    }

    local Device = { model = "Emulator", screen = support.newScreen(), input = support.newInput() }
    function Device:isSDL() return self._is_sdl == true end
    function Device:hasKeys() return false end
    function Device:hasDPad() return false end
    function Device:hasKeyboard() return false end
    function Device:isTouchDevice() return true end
    env.Device = Device

    local UIManager = { _window_stack = {}, shown = {}, dirty = {}, _queue = {} }
    function UIManager:nextTick(fn) self._queue[#self._queue + 1] = fn end
    function UIManager:scheduleIn(_, fn) self._queue[#self._queue + 1] = fn end
    function UIManager:unschedule() end
    --- uimanager.lua:156-186: a refresh type handed to `show` goes straight
    --- to setDirty, and without one the widget is only *repainted* -- which
    --- is how a sheet reached the framebuffer and never the panel
    --- (crash.log 2026-09-02, 11909-11930).
    function UIManager:show(w, refreshtype, refreshregion, _x, _y, refreshdither)
        self.shown[#self.shown + 1] = w
        self._window_stack[#self._window_stack + 1] = { widget = w }
        if refreshtype then
            self:setDirty(w, refreshtype, refreshregion, refreshdither)
        end
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
    --[[--
    Mirrors UIManager:close @ 1d66e440b in the one respect the plugin depends
    on: the widget is notified *before* any stack surgery, and it is notified
    whether or not it is still on the stack. That second half is what makes a
    double close observable -- in the real one the CloseWidget event fires
    either way, while the "schedule the widgets underneath to repaint" block is
    guarded on having actually found the widget (uimanager.lua:259).

    Dispatch is EventListener's lookup rather than handleEvent, because several
    dialog stubs here -- and several test modals -- answer handleEvent with a
    bare `true` and would swallow it. tests/conformance.lua states that the real
    dispatch does reach an instance-level handler through the container.
    ]]
    function UIManager:close(w)
        if not w then return end
        if w.onFlushSettings then w:onFlushSettings() end
        if w.onCloseWidget then w:onCloseWidget() end
        for i = #self._window_stack, 1, -1 do
            if self._window_stack[i].widget == w then table.remove(self._window_stack, i) end
        end
    end
    function UIManager:setDirty(w, mode, region, dither)
        if region ~= nil then
            assert(type(region.openIntersectWith) == "function"
                and type(region.combine) == "function",
                "refresh region must be a Geom")
        end
        self.dirty[#self.dirty + 1] = { w, mode, region, dither }
    end
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
    function WidgetContainer:getSize()
        if self.dimen then return self.dimen end
        return self[1] and self[1]:getSize() or { x = 0, y = 0, w = 0, h = 0 }
    end
    function WidgetContainer:paintTo(bb, x, y)
        if self[1] and self[1].paintTo then self[1]:paintTo(bb, x or 0, y or 0) end
    end
    function WidgetContainer:free()
        for i = 1, #self do
            if self[i] and self[i].free then self[i]:free() end
        end
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

    local ButtonDialog = {}
    function ButtonDialog:new(o)
        o = o or {}
        env.dialogs[#env.dialogs + 1] = o
        o.handleEvent = function() return true end
        return o
    end

    package.preload["device"] = function() return Device end
    package.preload["ui/uimanager"] = function() return UIManager end
    package.preload["logger"] = function() return logger end
    local gettext = setmetatable({
        ngettext = function(single, plural, count)
            return count == 1 and single or plural
        end,
    }, { __call = function(_, text) return text end })
    package.preload["gettext"] = function() return gettext end
    env.Blitbuffer = support.newBlitbufferModule()
    env.Blitbuffer.COLOR_LIGHT_GRAY = "light_gray"
    env.Blitbuffer.COLOR_DARK_GRAY = "dark_gray"
    -- ink_style's graphite gray. A string, like every fake color; the
    -- constant's existence on the real module is stated in conformance.lua.
    env.Blitbuffer.COLOR_GRAY_6 = "gray_6"
    -- The raster cache's default ruling colour. Without it every paper
    -- assertion would pass against a nil colour, which paints nothing.
    env.Blitbuffer.COLOR_GRAY = "gray"
    -- The transparent pixel a BB8A overlay is cleared with. Nothing in the
    -- plugin calls it -- the raster's clear arrives injected -- but the
    -- capability probe does, and a module without it would describe a
    -- KOReader that cannot compose page ink at all (ADR-41).
    env.Blitbuffer.Color8A = function(value, alpha) return { v = value, a = alpha } end
    package.preload["ffi/blitbuffer"] = function() return env.Blitbuffer end

    --[[--
    The two core modules the capability probe asks about, and nothing more.

    `Compat.capabilities` reads exactly four things off the runtime; these are
    two of them. Stubbing the whole of ReaderView or Document here would be a
    fake nobody checks, so what is preloaded is the shape the probe looks at:
    the transform pair and the native page size. That every one of the four is
    genuinely present on a real v2026.07 is stated in tests/conformance.lua,
    which is what keeps these two from becoming wishful thinking.
    ]]
    package.preload["apps/reader/modules/readerview"] = function()
        return {
            screenToPageTransform = function() end,
            pageToScreenTransform = function() end,
        }
    end
    package.preload["document/document"] = function()
        return { getNativePageDimensions = function() end }
    end
    env.WidgetContainer = WidgetContainer
    package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
    package.preload["ui/widget/notification"] = function() return Notification end
    package.preload["ui/widget/confirmbox"] = function() return ConfirmBox end
    package.preload["ui/widget/buttondialog"] = function() return ButtonDialog end
    package.preload["dispatcher"] = function() return Dispatcher end

    -- The real toolbar, not a stub.
    --
    -- It used to be stubbed here to avoid pulling in the widget toolkit, and
    -- the stubs below now cover that toolkit anyway. Keeping a second bar
    -- class alive is worse than the dependency: main.lua, the canvas overlay
    -- and the tests would each capture whichever one they saw first, and a
    -- test could then pass against a bar the plugin never uses.
    --
    -- Preloaded rather than required outright because the widget stubs below
    -- have to be registered first.
    package.preload["ink_bar"] = function()
        return dofile(support.plugin_dir .. "/ink_bar.lua")
    end

    -- Enough of the widget toolkit to load the real ink_bar.lua.
    local Geom = {}
    Geom.__index = Geom
    function Geom:new(o) return setmetatable(o or {}, Geom) end
    function Geom:copy()
        return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
    end
    function Geom:intersectWith(other)
        return self.x < other.x + other.w and other.x < self.x + self.w
            and self.y < other.y + other.h and other.y < self.y + self.h
    end
    function Geom:openIntersectWith(other)
        return self.x <= other.x + other.w and other.x <= self.x + self.w
            and self.y <= other.y + other.h and other.y <= self.y + self.h
    end
    function Geom:combine(other)
        local left, top = math.min(self.x, other.x), math.min(self.y, other.y)
        local right = math.max(self.x + self.w, other.x + other.w)
        local bottom = math.max(self.y + self.h, other.y + other.h)
        return Geom:new{ x = left, y = top, w = right - left, h = bottom - top }
    end
    package.preload["ui/geometry"] = function() return Geom end

    package.preload["ui/size"] = function()
        return {
            radius = { button = 4, window = 6 },
            border = { window = 2, button = 2 },
            margin = { button = 0 },
            padding = { default = 5, small = 2, large = 8, button = 2 },
            item = { height_default = 30, height_big = 40, height_large = 50 },
            span = { horizontal_default = 10, vertical_default = 2 },
        }
    end

    local fake_now = 0
    package.preload["ui/time"] = function()
        return {
            now = function() return fake_now end,
            ms = function(value) return value * 1000 end,
            s = function(value) return value * 1000000 end,
            _set = function(value) fake_now = value end,
        }
    end

    local Button = {}
    Button.__index = Button
    -- The class constant the real Button appends for `checked_func` labels
    -- (button.lua `checkmark`). ink_bar borrows the glyph for its own
    -- label-carried tool check; conformance.lua states the constant exists.
    Button.checkmark = "  \u{2713}"
    function Button:new(o)
        o = setmetatable(o or {}, Button)
        o.texts = { o.text }
        o.seen = {}
        if o.enabled == nil then o.enabled = true end
        o.frame = { invert = false }
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
    --- KOReader's Button is asymmetric about the box it is given: it subtracts
    --- its chrome from `width` so the widget is exactly that wide, but treats
    --- `height` as the *label* box and adds the chrome on top. A stub that
    --- hands back the requested height is the reason a column of buttons could
    --- overflow the screen with every assertion still green.
    function Button:chromeHeight()
        local padding = self.padding_v or self.padding or 0
        local border = self.bordersize or 2
        return 2 * (padding + border + (self.margin or 0))
    end
    function Button:getSize()
        return { w = self.width or 60, h = (self.height or 30) + self:chromeHeight() }
    end
    function Button:paintTo(_, x, y)
        if self.enabled_func then self.enabled = self.enabled_func() and true or false end
        local size = self:getSize()
        self.dimen = { x = x or 0, y = y or 0, w = size.w, h = size.h }
    end
    function Button:enable() self.enabled = true end
    function Button:disable() self.enabled = false end
    function Button:free() end
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

    local HorizontalGroup = sizedContainer("hgroup")
    function HorizontalGroup:getSize()
        local w, h = 0, 0
        for i = 1, #self do
            local size = self[i]:getSize()
            w = w + size.w
            if size.h > h then h = size.h end
        end
        return { w = w, h = h }
    end
    function HorizontalGroup:paintTo(bb, x, y)
        local offset = 0
        for i = 1, #self do
            self[i]:paintTo(bb, (x or 0) + offset, y or 0)
            offset = offset + self[i]:getSize().w
        end
    end
    package.preload["ui/widget/horizontalgroup"] = function() return HorizontalGroup end

    local FocusManager = WidgetContainer:extend{}
    package.preload["ui/widget/focusmanager"] = function() return FocusManager end

    local GestureRange = {}
    function GestureRange:new(o) return o or {} end
    package.preload["ui/gesturerange"] = function() return GestureRange end

    local BD = {
        auto = function(text) return text end,
        mirroredUILayout = function() return false end,
    }
    package.preload["ui/bidi"] = function() return BD end

    local ffiUtil = {}
    function ffiUtil.template(text, ...)
        local args = { ... }
        return (text:gsub("%%(%d+)", function(index)
            return tostring(args[tonumber(index)] or "")
        end))
    end
    package.preload["ffi/util"] = function() return ffiUtil end

    local Font = {}
    function Font:getFace(name, size) return { name = name, size = size or 20 } end
    package.preload["ui/font"] = function() return Font end

    local TextWidget = {}
    TextWidget.__index = TextWidget
    function TextWidget:new(o) return setmetatable(o or {}, TextWidget) end
    function TextWidget:getSize()
        return { w = math.min(self.max_width or 1000, #(self.text or "") * 9),
            h = self.face and self.face.size or 20 }
    end
    function TextWidget:paintTo() end
    function TextWidget:free() end
    package.preload["ui/widget/textwidget"] = function() return TextWidget end

    local VerticalSpan = {}
    function VerticalSpan:new(o)
        o = o or {}
        function o:getSize() return { w = 0, h = self.width or 0 } end
        function o:paintTo() end
        function o:free() end
        return o
    end
    package.preload["ui/widget/verticalspan"] = function() return VerticalSpan end

    local TitleBar = {}
    TitleBar.__index = TitleBar
    function TitleBar:new(o) return setmetatable(o or {}, TitleBar) end
    function TitleBar:getHeight() return 50 end
    function TitleBar:getSize() return { w = Device.screen:getWidth(), h = 50 } end
    function TitleBar:paintTo() end
    function TitleBar:handleEvent() return false end
    function TitleBar:free() end
    package.preload["ui/widget/titlebar"] = function() return TitleBar end

    local InputDialog = {}
    function InputDialog:new(o)
        o = o or {}
        o._text = o.input or ""
        function o:getInputText() return self._text end
        function o:setInputText(text) self._text = text end
        function o:handleEvent() return true end
        return o
    end
    package.preload["ui/widget/inputdialog"] = function() return InputDialog end

    local MultiInputDialog = {}
    function MultiInputDialog:new(o)
        o = o or {}
        o._values, o.input_fields = {}, {}
        for i = 1, #(o.fields or {}) do
            o._values[i] = o.fields[i].text or ""
            -- The real field is an InputText, and it carries its own "edited"
            -- flag. That flag is the only thing separating helping the reader
            -- from overwriting a name they typed, so the fake has to have it.
            local field = { _edited = false, _index = i, _dialog = o }
            function field:getText() return self._dialog._values[self._index] end
            function field:setText(text, keep)
                self._dialog._values[self._index] = text
                if not keep then self._edited = false end
            end
            function field:isTextEdited() return self._edited end
            --- What the keyboard does, so a spec can say "the reader typed
            --- here" without inventing an event.
            function field:typeText(text)
                self._dialog._values[self._index] = text
                self._edited = true
            end
            o.input_fields[i] = field
        end
        function o:getFields() return self._values end
        o.added_widgets = {}
        function o:addWidget(widget)
            self.added_widgets[#self.added_widgets + 1] = widget
            self.added_widget = widget
        end
        function o:handleEvent() return true end
        return o
    end
    package.preload["ui/widget/multiinputdialog"] = function() return MultiInputDialog end

    local RadioButtonTable = {}
    function RadioButtonTable:new(o)
        o = o or {}
        function o:getSize() return { w = self.width or 400, h = 50 } end
        --- The real widget calls `button_select_callback(entry)` from the
        --- button's own callback, after checking it. This is that, and only
        --- that: a spec drives the radio the way a finger would.
        function o:select(value)
            for _, row in ipairs(self.radio_buttons or {}) do
                for _, entry in ipairs(row) do
                    if entry.value == value then
                        self.checked_value = value
                        if self.button_select_callback then
                            self.button_select_callback(entry)
                        end
                        return true
                    end
                end
            end
            return false
        end
        return o
    end
    package.preload["ui/widget/radiobuttontable"] = function() return RadioButtonTable end

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

    -- The real one is a C module in koreader-base. File size is half a book's
    -- identity, while file mode lets rename migration distinguish an existing
    -- but unreadable database from a missing one.
    env.file_sizes = {}
    env.file_modes = {}
    package.preload["libs/libkoreader-lfs"] = function()
        return {
            attributes = function(path, what)
                if what == "size" then return env.file_sizes[path] end
                if what == "mode" then return env.file_modes[path] end
                return nil
            end,
        }
    end

    --- Only the calls the export makes. `getSafeFilename` stands in for the
    --- real one's job -- replace what a filesystem cannot hold -- without its
    --- VFAT detection, which is what tests/conformance.lua is for. There is
    --- deliberately no `diskUsage` here: it shells out to `df`, and a fake of
    --- it would say nothing true. The space probe is injected instead.
    package.preload["util"] = function()
        local util = {}
        function util.getSafeFilename(str, path, limit, limit_ext)
            local name = (tostring(str or ""):gsub('[\\/:%*%?"<>|]', "_"))
            if limit and #name > limit then name = name:sub(1, limit) end
            return name
        end
        function util.fileExists(path) return env.file_modes[path] ~= nil end
        function util.makePath(path)
            env.file_modes[path] = "directory"
            return true
        end
        --- Powers of 1000, like the real one, and nil for what is not a
        --- number -- which is the only part of it any caller here relies on.
        function util.getFriendlySize(size)
            size = tonumber(size)
            if not size then return end
            if size > 1000 * 1000 * 1000 then
                return string.format("%.1f GB", size / 1e9)
            elseif size > 1000 * 1000 then
                return string.format("%.1f MB", size / 1e6)
            elseif size > 1000 then
                return string.format("%.1f kB", size / 1e3)
            end
            return string.format("%d B", size)
        end
        return util
    end

    --- Where KOReader keeps its own data. The export's default destination is
    --- derived from this, so the path a spec sees is the shape of a real one.
    package.preload["datastorage"] = function()
        local DataStorage = {}
        function DataStorage:getDataDir() return "/mnt/us/koreader" end
        function DataStorage:getFullDataDir() return "/mnt/us/koreader" end
        function DataStorage:getSettingsDir() return "/mnt/us/koreader/settings" end
        return DataStorage
    end

    --[[--
    The folder chooser, reduced to its contract: it hands a path to a callback,
    and it may hand back nothing at all if the reader backs out. `answer` is
    what a spec sets to decide which of those happens.
    ]]
    env.choose_folder = { calls = {}, answer = nil }
    package.preload["apps/filemanager/filemanagerutil"] = function()
        local filemanagerutil = {}
        function filemanagerutil.getDefaultDir() return "/mnt/us" end
        function filemanagerutil.showChooseDialog(title, callback, current, default)
            env.choose_folder.calls[#env.choose_folder.calls + 1] = {
                title = title, current = current, default = default,
            }
            if env.choose_folder.answer then callback(env.choose_folder.answer) end
        end
        return filemanagerutil
    end

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

--[[--
`newReaderView`'s options with a host's defaults underneath them.

A fixed page has to fit twice over in the suite's 600x800 screen or the raster
budget refuses it (`zoom_too_large`), and `newReaderView`'s own default zoom of
2 does not: A4 at 2 is 1191x1684 pixels, twice the budget. Zoom 0.5 puts the
whole 596x842-point page on screen as 298x421 pixels -- the fit-page case --
with a surround to its right and below that is nowhere near the toolbar, which
is where "ink never starts in the margin" has to be checked from.

A caller's own `view` wins field by field, `false` included -- `state = {
offset = false }` is still the view before its first recalculate.
]]
local function pagingViewOpts(over, page)
    local out = {}
    for k, v in pairs(over or {}) do out[k] = v end
    local function under(key, defaults)
        if out[key] == false then return end
        local merged = {}
        for k, v in pairs(defaults) do merged[k] = v end
        if type(out[key]) == "table" then
            for k, v in pairs(out[key]) do merged[k] = v end
        end
        out[key] = merged
    end
    under("state", { zoom = 0.5, page = page or 1 })
    under("visible_area", { w = 600, h = 800 })
    under("dimen", { w = 600, h = 800 })
    return out
end

--- Build a JustDraw instance wired to fake ui/view objects.
function support.newPlugin(JustDraw, env, opts)
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
        -- ReaderUI always exposes a document, including fixed-layout books.
        -- Most input tests do not need a reflowable document, so use a small
        -- inert one unless the caller supplies the EPUB fake below.
        document = opts.document or { file = opts.file or "/books/test.pdf" },
        menu = { registerToMainMenu = function() end },
        handleEvent = function(_, event)
            env.reader_events[#env.reader_events + 1] = event.handler
            return true
        end,
    }
    -- The reflowable-document surface. Absent by default, so every existing
    -- test still describes a plugin with no canvas session at all.
    if opts.document then
        ui.rolling = opts.rolling ~= false and {} or nil
        -- In the document's settings, where ReaderUI puts it, not on ReaderUI.
        doc_settings.data.partial_md5_checksum = opts.partial_md5 or "test-md5"
        ui.document.file = opts.file or "/books/test.epub"
        env.file_sizes[ui.document.file] = opts.file_size or 90210
        doc_settings.data.cre_dom_version = opts.dom_version or 20240114
    end
    local view = {
        state = { page = opts.page or 1 },
        registerViewModule = function() end,
    }
    -- The fixed-layout surface: the page-ink route's host. Absent by default
    -- for the same reason the EPUB one is -- every existing test describes a
    -- plugin with neither -- and mutually exclusive with it, because ReaderUI
    -- is one or the other and never both.
    if opts.paging then
        local rv = support.newReaderView(pagingViewOpts(opts.view, opts.page))
        view = rv.view
        -- ReaderView's plugin-host half, which `newReaderView` has no reason
        -- to model: JustDraw registers itself as a view module in `init`.
        view.registerViewModule = function() end
        ui.paging = true
        ui.rolling = nil
        ui.document = rv.ui.document
        if ui.document then
            ui.document.file = opts.file or "/books/test.pdf"
            env.file_sizes[ui.document.file] = opts.file_size or 90210
        end
        doc_settings.data.partial_md5_checksum = opts.partial_md5 or "test-md5"
    end
    -- ReaderUI has to be a real entry in the stack: the bar's forwarding, the
    -- dialogOnTop test and the whole suppression decision are defined relative
    -- to what sits below it.
    env.UIManager._window_stack = { { widget = ui } }
    local plugin = JustDraw:new{ ui = ui, view = view }
    return plugin
end

--- Build the exact shape FileManager gives a non-document-only plugin: only
--- `ui` and its menu, with no document, view or doc_settings conveniences.
--- JustDraw is non-document-only in production so standalone notebooks remain
--- available without opening a book; tests instantiate that exact host shape.
function support.newFileManagerPlugin(JustDraw, env)
    local ui = {
        menu = { registerToMainMenu = function() end },
        handleEvent = function() return true end,
    }
    env.UIManager._window_stack = { { widget = ui } }
    return JustDraw:new{ ui = ui }
end

return support
