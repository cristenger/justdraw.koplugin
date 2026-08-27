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
    if bb.root == bb then bb.writes = {} end
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

function FakeBB:blitFrom(src, dest_x, dest_y, offs_x, offs_y, w, h)
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
    }
end

function FakeBB:free() self.freed = true end

function FakeBB:clear()
    self.rects, self.fills, self.blits, self.viewports = {}, {}, {}, {}
    if self.root == self then self.writes = {} end
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

function support.newBlitbufferModule()
    return {
        COLOR_BLACK = "black",
        COLOR_WHITE = "white",
        TYPE_BB8 = 1,
        new = function(w, h, bbtype) return newFakeBB(w, h, bbtype or 1) end,
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
        if self.fail_list_canvases then return nil, self.fail_list_canvases end
        -- A fresh array, the way the real repository builds one per query.
        -- Handing out the live table lets a caller that appends to the result
        -- quietly grow the store, which is a bug the fake would then hide.
        local out = {}
        for i = 1, #self.canvases do out[i] = self.canvases[i] end
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
        stroke.id = stroke.id or self.next_stroke_id
        self.next_stroke_id = math.max(self.next_stroke_id, stroke.id) + 1
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

    function store:createCanvas(book_id, spec)
        if self.fail_create then return nil, self.fail_create end
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
            logical_w = spec.logical_w,
            logical_h = spec.logical_h,
        }
        self.canvases[#self.canvases + 1] = canvas
        return canvas
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
          next_sort_key = (#pages + 1) * 1024, current_page_id = pages[1].id,
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
    package.preload["ffi/blitbuffer"] = function() return env.Blitbuffer end
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
            border = { window = 2 },
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
    function Button:getSize() return { w = self.width or 60, h = self.height or 30 } end
    function Button:paintTo(_, x, y)
        if self.enabled_func then self.enabled = self.enabled_func() and true or false end
        self.dimen = { x = x or 0, y = y or 0, w = self.width or 60, h = self.height or 30 }
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
        o._values = {}
        for i = 1, #(o.fields or {}) do o._values[i] = o.fields[i].text or "" end
        function o:getFields() return self._values end
        function o:addWidget(widget) self.added_widget = widget end
        function o:handleEvent() return true end
        return o
    end
    package.preload["ui/widget/multiinputdialog"] = function() return MultiInputDialog end

    local RadioButtonTable = {}
    function RadioButtonTable:new(o)
        o = o or {}
        function o:getSize() return { w = self.width or 400, h = 50 } end
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

    -- The real one is a C module in koreader-base. Only `attributes(path,
    -- "size")` is used, and it is half a book's identity, so a stub that
    -- silently answered nil would turn the canvas off in every test.
    env.file_sizes = {}
    package.preload["libs/libkoreader-lfs"] = function()
        return {
            attributes = function(path, what)
                if what == "size" then return env.file_sizes[path] end
                return nil
            end,
        }
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
    -- ReaderUI has to be a real entry in the stack: the bar's forwarding, the
    -- dialogOnTop test and the whole suppression decision are defined relative
    -- to what sits below it.
    env.UIManager._window_stack = { { widget = ui } }
    local plugin = FingerInk:new{ ui = ui, view = view }
    return plugin
end

--- Build the exact shape FileManager gives a non-document-only plugin: only
--- `ui` and its menu, with no document, view or doc_settings conveniences.
--- FingerInk remains document-only in production for now, so tests instantiate
--- this host explicitly through the future activation seam.
function support.newFileManagerPlugin(FingerInk, env)
    local ui = {
        menu = { registerToMainMenu = function() end },
        handleEvent = function() return true end,
    }
    env.UIManager._window_stack = { { widget = ui } }
    return FingerInk:new{ ui = ui }
end

return support
