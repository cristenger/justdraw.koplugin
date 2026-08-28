--[[--
QA probe that pins the axis policy's trade-off as measured figures.

Run directly under Lua and KOReader's LuaJIT, from anywhere; no KOReader
session is needed. Drives shapes a pen would actually draw -- lines, a
rectangle, a circle, taps, a resting palm -- through the shipping pipeline
(InkWacomPalm classifying first, then InkStylusSequence over InkStylusGeometry)
with input shaped the way a Kindle Scribe reports it: one persistent table per
slot mutated in place, the pen id pinned to its slot, a lift written as -1.

What it asserts is the whole ADR-22 bargain, as numbers:

  - after the boundary, the sample-to-point ratio is 1:1;
  - a tap is exactly one point, delivered on the lift;
  - a resting palm contributes nothing at all;
  - a contact that never moves one axis away from the boundary collapses to a
    single dot -- and one pixel of hand wobble is enough to escape that, which
    is why the collapse takes machine-perfect input to trigger.

If a change to the geometry policy alters any of these, this file is what
should break. It deliberately does not test budgets (stylus_budget_benchmark)
or palm cost (wacom_palm_burst_benchmark).

Optional render: with JUSTDRAW_PNG set *and* a KOReader build resolvable
(run from inside a build directory, per the koreader-simulator-qa headless
recipe), the collected strokes are rasterised through the real BlitBuffer and
written as a PNG -- a table of numbers does not show a missing rectangle edge;
a picture does. Absent either, the render is skipped with a note.
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local Geometry = require("ink_stylus_geometry")
local PalmGate = require("ink_wacom_palm")
local Sequence = require("ink_stylus_sequence")

local PEN, TOUCH_A = 4, 0
local TOOL_FINGER, TOOL_PEN, TOOL_ERASER = 0, 1, 2

-- ------------------------------------------------------------------ harness

local function newPipeline()
    local out = { strokes = {}, open = nil, contacts = 0, dots = 0, discards = 0 }
    local geometry = Geometry.new()

    local function closeOpen()
        if out.open and out.open.n > 0 then
            out.strokes[#out.strokes + 1] = out.open
        end
        out.open = nil
    end

    local sequence = Sequence.new{
        wacom_protocol = true,
        pen_slot = PEN,
        tool_finger = TOOL_FINGER,
        geometry = geometry,
        classify = function(_, _, tool)
            return "draw", tool == TOOL_ERASER and "erase" or "ink"
        end,
        on_contact_start = function()
            out.contacts = out.contacts + 1
            return true
        end,
        on_point = function(x, y, tool, is_first)
            if is_first then
                closeOpen()
                out.open = { n = 0, w = tool == TOOL_ERASER and 14 or 4,
                    erase = tool == TOOL_ERASER }
            end
            local s = out.open
            s[#s + 1] = x
            s[#s + 1] = y
            s.n = s.n + 1
            return "continue"
        end,
        on_finish = function() closeOpen(); return true end,
        on_abort = function() out.open = nil; return true end,
        on_contact_end = function() return true end,
        on_pending_finish = function(kind)
            if kind == "dot" then out.dots = out.dots + 1
            else out.discards = out.discards + 1 end
        end,
        drop_contact = function() return true end,
    }

    local gate = PalmGate.new{
        classify = function(slot)
            if slot.slot == PEN then return "trusted_stylus" end
            local tool = slot.tool
            if tool == TOOL_PEN or tool == TOOL_ERASER then return "routed_palm" end
            return "touch"
        end,
        retire_touch = function() end,
    }

    -- The host's own order: the palm ledger classifies first, and only what
    -- survives is offered to the contact machine.
    out.feed = function(slot)
        if gate:routeStylus(slot) then return true end
        local handled = sequence:feed(slot)
        sequence:afterFrame()
        return handled
    end
    out.sequence, out.gate, out.geometry = sequence, gate, geometry
    return out
end

--- One persistent table per slot, exactly as KOReader hands them out.
local function newSlots()
    return {
        [PEN] = { slot = PEN },
        [TOUCH_A] = { slot = TOUCH_A },
    }
end

--- A contact-down frame carries no ABS update of its own: the slot still
--- shows wherever the previous contact left it. Then the samples arrive.
local function contact(pipe, slots, samples, tool)
    local s = slots[PEN]
    s.id, s.tool = PEN, tool or TOOL_PEN
    pipe.feed(s)
    for i = 1, #samples, 2 do
        s.x, s.y = samples[i], samples[i + 1]
        pipe.feed(s)
    end
    s.id = -1
    pipe.feed(s)
end

local function line(x0, y0, x1, y1, steps)
    local pts = {}
    for i = 0, steps do
        local t = i / steps
        pts[#pts + 1] = math.floor(x0 + (x1 - x0) * t + 0.5)
        pts[#pts + 1] = math.floor(y0 + (y1 - y0) * t + 0.5)
    end
    return pts
end

local function polyline(vertices, per_edge)
    local pts = {}
    for i = 1, #vertices - 2, 2 do
        local seg = line(vertices[i], vertices[i + 1],
            vertices[i + 2], vertices[i + 3], per_edge)
        local from = (i == 1) and 1 or 3
        for k = from, #seg do pts[#pts + 1] = seg[k] end
    end
    return pts
end

local function circle(cx, cy, r, steps)
    local pts = {}
    for i = 0, steps do
        local a = i / steps * 2 * math.pi
        pts[#pts + 1] = math.floor(cx + r * math.cos(a) + 0.5)
        pts[#pts + 1] = math.floor(cy + r * math.sin(a) + 0.5)
    end
    return pts
end

local function totalPoints(pipe)
    local n = 0
    for i = 1, #pipe.strokes do n = n + pipe.strokes[i].n end
    return n
end

-- ------------------------------------------------------------------ figures

local rows = {}
local all_strokes = {}
local function record(name, pipe, expectation)
    rows[#rows + 1] = string.format("%-34s contacts=%d strokes=%d points=%d"
        .. " dots=%d  %s", name, pipe.contacts, #pipe.strokes,
        totalPoints(pipe), pipe.dots, expectation)
    for i = 1, #pipe.strokes do all_strokes[#all_strokes + 1] = pipe.strokes[i] end
end

-- A diagonal proves both axes on its first sample after the baseline: from
-- there every sample is a point.
do
    local pipe, slots = newPipeline(), newSlots()
    contact(pipe, slots, line(80, 80, 380, 300, 24))
    assert(#pipe.strokes == 1 and pipe.strokes[1].n == 24,
        "a diagonal keeps a 1:1 sample-to-point ratio after the baseline")
    record("diagonal, cold lease", pipe, "24 samples -> 24 points")
end

-- The collapse, and its real-world escape hatch, side by side. This pair IS
-- the ADR-22 trade-off: machine-perfect axis-constant input collapses to a
-- dot; one pixel of wobble -- less than any hand produces -- escapes it.
do
    local pipe, slots = newPipeline(), newSlots()
    contact(pipe, slots, line(80, 380, 380, 380, 24))
    assert(#pipe.strokes == 1 and pipe.strokes[1].n == 1,
        "a pixel-perfect horizontal on a cold lease collapses to one dot")
    assert(pipe.dots == 1, "and the collapse is reported to the host")
    record("horizontal, pixel-perfect, cold", pipe, "collapses to 1 dot")

    local wobble, wslots = newPipeline(), newSlots()
    local pts = line(80, 380, 380, 380, 24)
    for i = 2, #pts, 2 do pts[i] = pts[i] + (i % 4 == 0 and 1 or 0) end
    contact(wobble, wslots, pts)
    assert(#wobble.strokes == 1 and wobble.strokes[1].n == 24,
        "one pixel of hand wobble draws every sample")
    assert(wobble.dots == 0, "and nothing collapsed")
    record("horizontal, 1px wobble, cold", wobble, "24 samples -> 24 points")
end

-- With a boundary left by a previous contact, axis-aligned figures draw whole:
-- the rectangle keeps all four edges and the circle closes.
do
    local pipe, slots = newPipeline(), newSlots()
    contact(pipe, slots, line(80, 80, 380, 300, 24))          -- leaves a boundary
    contact(pipe, slots, line(80, 380, 380, 380, 24))         -- horizontal
    contact(pipe, slots, line(80, 430, 80, 700, 24))          -- vertical
    contact(pipe, slots,
        polyline({ 480, 80, 780, 80, 780, 300, 480, 300, 480, 80 }, 12))
    contact(pipe, slots, circle(640, 520, 130, 64))
    assert(pipe.strokes[2].n == 25, "a horizontal after a lift draws whole")
    assert(pipe.strokes[3].n == 25, "so does a vertical")
    assert(pipe.strokes[4].n == 49,
        "a rectangle keeps all four axis-aligned edges")
    assert(pipe.strokes[5].n == 65, "a circle closes without a seam")
    assert(pipe.dots == 0, "nothing collapsed with a boundary to prove against")
    record("shared lease: h, v, rect, circle", pipe, "all draw whole")
end

-- A tap is one contact and exactly one point, delivered on the lift; two taps
-- on the same spot stay two.
do
    local pipe, slots = newPipeline(), newSlots()
    contact(pipe, slots, { 900, 120 })
    contact(pipe, slots, { 900, 120 })
    assert(pipe.contacts == 2 and #pipe.strokes == 2,
        "two taps on the same spot are two contacts and two strokes")
    assert(pipe.strokes[1].n == 1 and pipe.strokes[2].n == 1,
        "each delivering exactly one point")
    record("two taps, same spot", pipe, "2 contacts, 1 point each")
end

-- A hand resting through a whole stroke contributes nothing: no contact, no
-- point, and the pen's stroke is intact.
do
    local pipe, slots = newPipeline(), newSlots()
    local palm = slots[TOUCH_A]
    palm.id, palm.x, palm.y, palm.tool = 71, 300, 900, TOOL_FINGER
    pipe.feed(palm)                    -- lands as a finger
    palm.tool = TOOL_ERASER            -- promoted to MT_TOOL_PALM (value 2)
    pipe.feed(palm)
    contact(pipe, slots, line(900, 200, 1200, 420, 24))
    for i = 1, 20 do                   -- the hand keeps reporting
        palm.x, palm.y = 300 + i, 900 + i
        pipe.feed(palm)
    end
    palm.id = -1
    pipe.feed(palm)
    assert(pipe.contacts == 1, "the palm never became a contact")
    assert(#pipe.strokes == 1 and pipe.strokes[1].n == 24,
        "and the pen's stroke has only the pen's points")
    assert(pipe.gate:activeCount() == 0, "the ledger emptied at the palm's lift")
    record("stroke with a palm down", pipe, "palm contributes nothing")
end

-- Tool 2 on the pen slot is the rear eraser, and erases.
do
    local pipe, slots = newPipeline(), newSlots()
    contact(pipe, slots, line(900, 470, 1200, 690, 24), TOOL_ERASER)
    assert(#pipe.strokes == 1 and pipe.strokes[1].erase == true,
        "tool 2 on the pen slot is an erase stroke")
    record("rear eraser stroke", pipe, "erases, 24 points")
end

-- ------------------------------------------------------------------- output

print(string.format("stylus figures: %d assertions of the axis-policy bargain",
    #rows))
for i = 1, #rows do print("  " .. rows[i]) end

-- Optional render, only where the koreader-simulator-qa headless recipe holds:
-- inside a build directory with JUSTDRAW_PNG naming the output.
local png = os.getenv("JUSTDRAW_PNG")
if png then
    local ok, err = pcall(function()
        require("setupkoenv")
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        _G.G_defaults = _G.G_defaults or require("luadefaults"):open()
        _G.G_reader_settings = _G.G_reader_settings
            or LuaSettings:open(DataStorage:getDataDir() .. "/settings.reader.lua")
        local Device = require("device")
        require("document/canvascontext"):init(Device)
        local Blitbuffer = require("ffi/blitbuffer")
        local Render = require("ink_render")
        local bb = Blitbuffer.new(1400, 1000, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        for i = 1, #all_strokes do
            local s = all_strokes[i]
            Render.stroke(bb, s, 0, 0,
                s.erase and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK)
        end
        bb:writePNG(png)
    end)
    if ok then
        print("render: " .. png)
    else
        print("render skipped (not inside a KOReader build): "
            .. (tostring(err):match("[^\n]*") or "unknown"))
    end
else
    print("render skipped (set JUSTDRAW_PNG and run from a build directory)")
end
