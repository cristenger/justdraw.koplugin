--[[--
QA-only memory probe for the bounded stylus sequence.

Run directly under Lua and KOReader's LuaJIT. This deliberately records
measurements instead of enforcing allocator-specific timing or memory limits.
The correctness assertions remain deterministic: an ink contact cannot retain
more than MAX_OPEN_POINTS and no partial stroke is committed after the cap.
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local Limits = require("ink_limits")
local Sequence = require("ink_stylus_sequence")

local points = {}
local max_points = 0
local committed = 0
local aborted = 0

local geometry = {
    observe = function(_, x, y)
        return "accept", x, y
    end,
    onLift = function()
        return "discard", "lift"
    end,
    reset = function()
    end,
}

local sequence = Sequence.new{
    geometry = geometry,
    classify = function()
        points = {}
        return "draw", "ink"
    end,
    on_point = function(x, y)
        points[#points + 1] = x
        points[#points + 1] = y
        local n = #points / 2
        if n > max_points then max_points = n end
        return "continue"
    end,
    on_finish = function()
        committed = committed + 1
        points = {}
        return true
    end,
    on_abort = function()
        aborted = aborted + 1
        points = {}
        return true
    end,
}

local function feed(id, sample)
    return sequence:feed{
        slot = 4,
        id = id,
        tool = 1,
        x = sample,
        y = sample,
        timev = sample,
    }
end

collectgarbage("collect")
local before_kb = collectgarbage("count")
for i = 1, Limits.MAX_OPEN_POINTS do
    feed(4, i)
end
local at_limit_kb = collectgarbage("count")
assert(#points / 2 == Limits.MAX_OPEN_POINTS,
    "the vector did not reach MAX_OPEN_POINTS")

for i = Limits.MAX_OPEN_POINTS + 1, 10000 do
    feed(4, i)
    assert(#points / 2 <= Limits.MAX_OPEN_POINTS,
        "open point vector exceeded MAX_OPEN_POINTS")
end
local after_cap_kb = collectgarbage("count")

assert(max_points == Limits.MAX_OPEN_POINTS,
    "the retained point maximum did not match the configured cap")
assert(aborted == 1, "the oversized ink contact must abort exactly once")
assert(committed == 0, "an oversized contact must not persist a prefix")
assert(#points == 0, "the aborted host vector must be repaired")
assert(sequence:isLifecycleBlocked(),
    "the capped physical contact must stay owned until lift")

feed(-1, 10001)
sequence:afterFrame()
feed(4, 10002)
feed(-1, 10003)
sequence:afterFrame()
assert(committed == 1, "the contact after a capped stroke must still work")

sequence:reset(true)
points = nil
collectgarbage("collect")
local after_reset_kb = collectgarbage("count")

io.write(string.format(
    "stylus budget: max_points=%d fed=%d before_kb=%.1f at_limit_kb=%.1f after_cap_kb=%.1f after_reset_gc_kb=%.1f limit_delta_kb=%.1f released_kb=%.1f\n",
    max_points, 10000, before_kb, at_limit_kb, after_cap_kb,
    after_reset_kb, at_limit_kb - before_kb, at_limit_kb - after_reset_kb))
