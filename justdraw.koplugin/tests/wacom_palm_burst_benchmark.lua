--[[--
QA-only probe for the cost of a Kindle Scribe palm.

Run directly under Lua and KOReader's LuaJIT. It records measurements rather
than enforcing allocator-specific limits, because the numbers that matter are
device numbers. What it *does* assert is deterministic and is the whole claim
of the palm gate: a resting hand performs no domain work at all, and its
bookkeeping is one scalar per physical slot no matter how long it rests.

The physical trace showed the opposite -- a promoted palm running erase
candidate lookups, chunk decoding and raster repair for as long as the hand was
down -- so "no work" here means literally none of it, counted.
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local Geometry = require("ink_stylus_geometry")
local PalmGate = require("ink_wacom_palm")
local Sequence = require("ink_stylus_sequence")

local SAMPLES = 10000
local PEN_SLOT = 4

local domain = {
    classify = 0, points = 0, finishes = 0, aborts = 0,
    starts = 0, ends = 0, retires = 0, drops = 0,
}

-- Wacom, as the Scribe reports it: one dedicated pen slot, everything else a
-- hand however its tool value reads.
local function role(slot)
    if slot.slot == PEN_SLOT then return "trusted_stylus", "wacom_pen_slot" end
    local tool = slot.tool
    if tool == 1 or tool == 2 or tool == 3 then
        return "routed_palm", "wacom_non_pen_tool"
    end
    return "touch", "touch_slot"
end

local gate = PalmGate.new{
    classify = role,
    retire_touch = function() domain.retires = domain.retires + 1 end,
}

local geometry = Geometry.new()
local sequence = Sequence.new{
    wacom_protocol = true,
    pen_slot = PEN_SLOT,
    geometry = geometry,
    classify = function()
        domain.classify = domain.classify + 1
        return "draw", "ink"
    end,
    on_contact_start = function() domain.starts = domain.starts + 1; return true end,
    on_point = function() domain.points = domain.points + 1; return "continue" end,
    on_finish = function() domain.finishes = domain.finishes + 1; return true end,
    on_abort = function() domain.aborts = domain.aborts + 1; return true end,
    on_contact_end = function() domain.ends = domain.ends + 1; return true end,
    drop_contact = function() domain.drops = domain.drops + 1; return true end,
}

--- The host's own order: classify first, and only what survives is a contact.
local function route(slot)
    if gate:routeStylus(slot) then return true end
    return sequence:feed(slot)
end

-- The reusable slot table KOReader hands the callback, mutated in place.
local palm = { slot = 0, id = 70, tool = 2, x = 300, y = 900, timev = 0 }

collectgarbage("collect")
local before_kb = collectgarbage("count")
local start = os.clock()

for i = 1, SAMPLES do
    palm.x = 300 + i % 17
    palm.y = 900 + i % 13
    palm.timev = i
    assert(route(palm) == true, "a promoted palm must always be dominated")
end

local elapsed = os.clock() - start
local after_kb = collectgarbage("count")

-- A second, identical burst measures the steady state. The first one also pays
-- for whatever the runtime compiles on the way in, which is not what "does a
-- palm allocate?" is asking.
collectgarbage("collect")
local steady_before_kb = collectgarbage("count")
for i = 1, SAMPLES do
    palm.x = 300 + i % 17
    palm.y = 900 + i % 13
    palm.timev = SAMPLES + i
    route(palm)
end
local steady_after_kb = collectgarbage("count")

local tracked = 0
for _ in pairs(gate.palms) do tracked = tracked + 1 end
assert(tracked == 1, "one physical palm must be one ledger entry")
assert(gate:activeCount() == 1, "and must be counted once")
assert(domain.classify == 0, "a palm must never be classified as a contact")
assert(domain.starts == 0, "a palm must never start a contact")
assert(domain.points == 0, "a palm must never produce a point")
assert(domain.finishes == 0 and domain.aborts == 0,
    "a palm must never open or close an effect")
assert(domain.ends == 0, "a palm must never publish a contact boundary")
assert(domain.drops == 0, "a palm never seen as touch has nothing to reclaim")
assert(sequence.owner_slot == nil, "and must never own the sequence")
assert(geometry:baseline() == nil,
    "a palm must never move the trusted pen baseline")

palm.id = -1
assert(route(palm) == true, "the lift is dominated too")
assert(gate:hasActiveContact() == false, "and empties the ledger")

collectgarbage("collect")
local after_gc_kb = collectgarbage("count")

-- A trusted pen contact still works after the burst, and its baseline starts
-- from the pen's own coordinates rather than the hand's.
local pen = { slot = PEN_SLOT, id = 71, tool = 1, x = 100, y = 100, timev = 0 }
route(pen)
pen.x, pen.y = 400, 500
route(pen)
pen.id = -1
route(pen)
sequence:afterFrame()
assert(domain.points == 1, "the pen after the burst drew its coherent point")
assert(domain.ends == 1, "and published exactly one boundary")

io.write(string.format(
    "wacom palm burst: samples=%d elapsed_s=%.4f samples_per_s=%.0f"
        .. " ledger_entries=%d before_kb=%.1f after_kb=%.1f after_gc_kb=%.1f"
        .. " first_burst_delta_kb=%.1f steady_burst_delta_kb=%.1f\n",
    SAMPLES, elapsed, SAMPLES / (elapsed > 0 and elapsed or 1),
    tracked, before_kb, after_kb, after_gc_kb,
    after_kb - before_kb, steady_after_kb - steady_before_kb))
