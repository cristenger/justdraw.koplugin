--[[--
ink_live_refresh: the pen's boxes reach the panel at a bounded cadence.

A pen sample is a raster write, a framebuffer copy and a physical refresh,
and the Scribe's Wacom delivers one every 2.8 ms. The refresh is the part
that does not scale. On lab126 MTK every `ui` update -- AUTO, the only
mode that renders gray -- first waits for the *submission* of the previous
marker (koreader-base framebuffer_mxcfb.lua, `wait_for_submission_before`),
so one update per sample becomes a queue the panel drains slower than the
pen fills it, and the process stops reading evdev. A device session
measured 7 611 `ui` updates in three minutes, one per pen frame at
150-280 Hz, and 79 `SYN_DROPPED`: frames the kernel discarded because
nobody read them (crash.log 2026-09-02, ADR-43).

The raster and the framebuffer still take every sample; only the panel is
asked less often. Boxes are unioned into one pending rectangle and flushed
when an interval has passed since the last physical refresh -- from the
sample that crosses it, so a moving pen refreshes on its own clock -- and
by one trailing timer for the tail of a stroke. A stroke end flushes what
is left. Modes rank: a union holding one box that needs `ui` (gray content)
rides `ui`, because a DU over a gray stroke mangles it (ADR-36).

Nothing here allocates per sample: the pending box is four numbers, the
timer action is built once, and `schedule_in` runs at most once per
interval. The clock, the scheduler and the refresh are injected, so the
policy is stated in `tests/live_refresh_spec.lua` against a virtual clock.
]]

local Live = {}
Live.__index = Live

--- DU carries no wait on any mxcfb device; a 20 ms union is invisible
--- behind the panel's own latency.
Live.FAST_INTERVAL = 0.02
--- AUTO (`ui`) waits for the previous submission on Kindles and REAGL
--- (`partial`) fences on completion: ten a second is the budget a
--- three-minute session with the pen down has to stay inside (ADR-43).
Live.SLOW_INTERVAL = 0.10

local RANK = { fast = 1, partial = 2, ui = 3 }
local MODE = { "fast", "partial", "ui" }

--- A millisecond of slack on "has the interval elapsed". Clocks are coarse
--- (CLOCK_MONOTONIC_COARSE on the device, accumulated floats in the
--- harness), and a timer re-armed for the last few nanoseconds of an
--- interval would fire again at the same instant and spin.
local EPSILON = 0.001

--[[--
  opts.clock         function() -> seconds, monotonic
  opts.schedule_in   function(delay_seconds, action)  -- UIManager:scheduleIn
  opts.unschedule    function(action)                 -- UIManager:unschedule
  opts.refresh       function(mode, left, top, right, bottom) -- the one physical refresh
  opts.fast_interval, opts.slow_interval   seconds; tests only
]]
function Live.new(opts)
    opts = opts or {}
    assert(type(opts.clock) == "function", "live refresh needs a clock")
    assert(type(opts.schedule_in) == "function", "live refresh needs schedule_in")
    assert(type(opts.refresh) == "function", "live refresh needs a refresh sink")
    local self = setmetatable({
        clock = opts.clock,
        schedule_in = opts.schedule_in,
        unschedule = opts.unschedule,
        refresh = opts.refresh,
        fast_interval = opts.fast_interval or Live.FAST_INTERVAL,
        slow_interval = opts.slow_interval or Live.SLOW_INTERVAL,
        pending = false,
        rank = 0,
        left = 0, top = 0, right = 0, bottom = 0,
        last_at = -math.huge,
        armed = false,
        closed = false,
        boxes = 0,
        flushes = 0,
    }, Live)
    -- One closure for the life of the accumulator: UIManager:unschedule
    -- matches on identity, and a closure per arm would be an allocation
    -- per interval and a timer nothing could cancel. The timer asks whether
    -- the interval of the union it finds has really elapsed: a box that
    -- needs `ui` may have arrived after a `fast` timer was armed, and the
    -- slow cadence is the one that has to hold.
    self.action = function()
        self.armed = false
        if self.closed or not self.pending then return end
        local interval = self.rank == RANK.fast and self.fast_interval
            or self.slow_interval
        local elapsed = self.clock() - self.last_at
        if elapsed + EPSILON >= interval then
            self:flush()
        else
            self.armed = true
            self.schedule_in(interval - elapsed, self.action)
        end
    end
    return self
end

--- Union one screen box (half-open, already clamped) into the pending
--- refresh. Returns true when the box was taken.
function Live:add(mode, left, top, right, bottom)
    if self.closed then return false end
    local rank = RANK[mode]
    if not rank then error("invalid live refresh mode: " .. tostring(mode), 2) end
    if not (right > left and bottom > top) then return false end
    if self.pending then
        if left < self.left then self.left = left end
        if top < self.top then self.top = top end
        if right > self.right then self.right = right end
        if bottom > self.bottom then self.bottom = bottom end
        if rank > self.rank then self.rank = rank end
    else
        self.pending = true
        self.left, self.top, self.right, self.bottom = left, top, right, bottom
        self.rank = rank
    end
    self.boxes = self.boxes + 1

    local interval = self.rank == RANK.fast and self.fast_interval
        or self.slow_interval
    local elapsed = self.clock() - self.last_at
    if elapsed + EPSILON >= interval then
        self:flush()
    elseif not self.armed then
        self.armed = true
        self.schedule_in(interval - elapsed, self.action)
    end
    return true
end

--- Send the pending union now, whatever the clock says: a stroke end and
--- Draw off call this so a tail never waits on the timer. Returns true when
--- a refresh went out.
function Live:flush()
    if not self.pending then return false end
    local mode = MODE[self.rank]
    local left, top, right, bottom = self.left, self.top, self.right, self.bottom
    self.pending = false
    self.rank = 0
    -- Stamped before the sink runs: a sink that adds a box must not recurse.
    self.last_at = self.clock()
    self.flushes = self.flushes + 1
    self.refresh(mode, left, top, right, bottom)
    return true
end

function Live:hasPending()
    return self.pending
end

--- Whether the trailing timer is armed. Tests only.
function Live:isArmed()
    return self.armed
end

--- Forget what is pending and disarm the timer. After close nothing is
--- taken: the screen this was refreshing is going away.
function Live:close()
    self.closed = true
    self.pending = false
    self.rank = 0
    if self.armed and self.unschedule then self.unschedule(self.action) end
    self.armed = false
end

return Live
