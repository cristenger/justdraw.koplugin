--[[--
The live refresh accumulator's policy, against a virtual clock.

A pen sample is cheap everywhere except at the panel, and the panel is the
one place the plugin used to ask per sample. These cases state the
cadence: the first box of a run goes out at once, the rest ride one
trailing timer or the sample that crosses the interval, a union carries
the heaviest mode it contains, and none of it allocates.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Live = require("ink_live_refresh")

    local function fixture(opts)
        opts = opts or {}
        local sched = support.newScheduler()
        local sent = {}
        local live = Live.new{
            clock = function() return sched:now() end,
            schedule_in = function(delay, action) sched:scheduleIn(delay, action) end,
            unschedule = function(action) sched:unschedule(action) end,
            refresh = function(mode, l, top, r, b)
                sent[#sent + 1] = { mode = mode, l = l, t = top, r = r, b = b }
            end,
            fast_interval = opts.fast_interval,
            slow_interval = opts.slow_interval,
        }
        return live, sched, sent
    end

    t:describe("ink_live_refresh / cadence")

    t:case("the first box of a run refreshes at once, the rest wait for the interval", function()
        local live, sched, sent = fixture()
        t:eq(live:add("fast", 10, 10, 20, 20), true, "taken")
        t:eq(#sent, 1, "first box goes out immediately")
        t:eq(sent[1].mode, "fast", "as fast")
        sched:advance(0.005)
        live:add("fast", 15, 15, 30, 30)
        live:add("fast", 30, 5, 40, 12)
        t:eq(#sent, 1, "boxes inside the interval are held")
        t:eq(live:hasPending(), true, "and pending")
        t:eq(live:isArmed(), true, "with one trailing timer armed")
        sched:advance(Live.FAST_INTERVAL)
        t:eq(#sent, 2, "the trailing timer flushed once")
        t:eq(sent[2].l, 15, "union left")
        t:eq(sent[2].t, 5, "union top")
        t:eq(sent[2].r, 40, "union right")
        t:eq(sent[2].b, 30, "union bottom")
        t:eq(live:hasPending(), false, "nothing left")
        t:eq(sched:pending(), 0, "no timer left behind")
    end)

    t:case("a sample that crosses the interval flushes synchronously with the union", function()
        local live, sched, sent = fixture()
        live:add("fast", 0, 0, 10, 10)           -- t = 0: flushed
        sched.clock = 0.010                      -- move the clock without running tasks
        live:add("fast", 10, 10, 20, 20)         -- held; timer armed for t = 0.02
        sched.clock = 0.021                      -- the loop has not run the timer yet
        live:add("fast", 20, 20, 30, 30)
        t:eq(#sent, 2, "flushed from the sample itself, not a timer")
        t:eq(sent[2].l .. "," .. sent[2].t .. "," .. sent[2].r .. "," .. sent[2].b,
            "10,10,30,30", "with the union of the held boxes")
        sched:drain()
        t:eq(#sent, 2, "the late timer found nothing")
        t:eq(sched:pending(), 0, "and did not re-arm")
    end)

    t:case("the flush count is bounded by the interval, whatever the sample rate", function()
        local live, sched, sent = fixture()
        for i = 1, 200 do                        -- 200 samples in one second
            live:add("fast", i, i, i + 4, i + 4)
            sched:advance(0.005)
        end
        t:check(#sent <= 1 / Live.FAST_INTERVAL + 2,
            "at most one per interval plus the edges, got " .. #sent)
        t:check(#sent >= 1 / Live.FAST_INTERVAL - 2, "and not starved, got " .. #sent)
    end)

    t:describe("ink_live_refresh / modes")

    t:case("shortening the interval reschedules a held gray region without losing its tail", function()
        local live, sched, sent = fixture()
        live:add("ui", 0, 0, 10, 10)
        sched:advance(0.02)
        live:add("ui", 10, 20, 40, 50)
        live:setSlowIntervalMs(50)
        t:eq(#sent, 1, "changing a setting never refreshes inside the callback")
        t:eq(sched:pending(), 1, "the old timer was replaced, not duplicated")
        sched:advance(0.02)
        t:eq(#sent, 1, "held until the new interval")
        sched:advance(0.011)
        t:eq(#sent, 2, "tail arrives on the new timer without another sample")
        t:eq(sent[2].mode, "ui", "gray remains gray")
        t:eq(sent[2].l .. "," .. sent[2].t .. "," .. sent[2].r .. "," .. sent[2].b,
            "10,20,40,50", "pending coverage survives the change")
        sched:advance(0.10)
        t:eq(#sent, 2, "no stale timer refreshes it again")
    end)

    t:case("lengthening the interval holds a pending union and leaves the fast cadence alone", function()
        local live, sched, sent = fixture()
        live:add("ui", 0, 0, 10, 10)
        sched:advance(0.01)
        live:add("ui", 20, 20, 30, 30)
        live:setSlowIntervalMs(200)
        sched:advance(0.10)
        t:eq(#sent, 1, "the old deadline no longer flushes")
        sched:advance(0.09)
        t:eq(#sent, 2, "the new deadline flushes")
        live:add("fast", 30, 30, 40, 40)
        sched:advance(0.021)
        t:eq(#sent, 3, "black still uses the fast interval")
        live:add("ui", 40, 40, 50, 50)
        live:flush()
        t:eq(#sent, 4, "stroke-end flush still bypasses the selected interval")
        live:close()
        t:eq(live:setSlowIntervalMs(20), false, "a setting cannot reopen a closed owner")
        t:eq(sched:pending(), 0, "teardown removes the timer")
    end)

    t:case("only the millisecond presets can replace the default", function()
        for _, value in ipairs({ 20, 33, 50, 75, 100, 150, 200 }) do
            t:eq(Live.normalizeSlowIntervalMs(value), value, "valid preset")
        end
        for _, value in ipairs({ 0, -1, 0.02, 1, 999999, math.huge, 0/0, "bad" }) do
            t:eq(Live.normalizeSlowIntervalMs(value), 100, "invalid settings keep the default")
        end
        t:eq(Live.normalizeSlowIntervalMs(nil), 100, "missing preference keeps the default")
    end)

    t:case("an idle timer left by a lift cannot delay the next stroke at a new cadence", function()
        local live, sched, sent = fixture()
        live:add("ui", 0, 0, 10, 10)
        sched:advance(0.005)
        live:add("ui", 10, 10, 20, 20)
        live:flush()
        t:eq(live:isArmed(), true, "the old trailing timer survived the explicit flush")
        live:setSlowIntervalMs(50)
        t:eq(sched:pending(), 0, "changing cadence retires the idle timer too")
        sched:advance(0.01)
        live:add("ui", 20, 20, 30, 30)
        sched:advance(0.039)
        t:eq(#sent, 2, "the next stroke still observes the selected interval")
        sched:advance(0.002)
        t:eq(#sent, 3, "the next stroke's held tail reaches the new deadline")
    end)

    t:case("a gray box promotes the union to ui and to the slow interval", function()
        local live, sched, sent = fixture()
        live:add("fast", 0, 0, 10, 10)
        sched:advance(0.001)
        live:add("fast", 10, 10, 20, 20)         -- arms the fast timer, due 0.02
        live:add("ui", 5, 5, 8, 8)               -- promotes the pending union
        sched:advance(Live.FAST_INTERVAL)        -- the fast timer fires and finds it too early
        t:eq(#sent, 1, "the fast interval no longer flushes it")
        t:eq(live:isArmed(), true, "the timer re-armed for the remainder")
        sched:advance(Live.SLOW_INTERVAL - Live.FAST_INTERVAL)
        t:eq(#sent, 2, "the slow interval does")
        t:eq(sent[2].mode, "ui", "as ui")
        t:eq(sent[2].l .. "," .. sent[2].r, "5,20", "and it carries every box")
    end)

    t:case("partial ranks above fast and below ui", function()
        local live, sched, sent = fixture()
        live:add("partial", 0, 0, 10, 10)
        t:eq(sent[1].mode, "partial", "partial alone")
        sched:advance(0.001)
        live:add("partial", 0, 0, 10, 10)
        live:add("fast", 0, 0, 10, 10)
        live:flush()
        t:eq(sent[2].mode, "partial", "fast does not lower it")
        live:add("partial", 0, 0, 10, 10)
        live:add("ui", 0, 0, 10, 10)
        live:flush()
        t:eq(sent[3].mode, "ui", "ui raises it")
    end)

    t:case("an unknown mode raises, a degenerate box is refused", function()
        local live = fixture()
        t:eq(live:add("fast", 10, 10, 10, 20), false, "zero width")
        t:eq(live:add("fast", 10, 10, 20, 10), false, "zero height")
        t:eq(live:hasPending(), false, "nothing taken")
        local ok = pcall(live.add, live, "flashui", 0, 0, 1, 1)
        t:eq(ok, false, "flashui is not a live mode")
    end)

    t:describe("ink_live_refresh / lifetime")

    t:case("flush is explicit at a stroke end and idempotent", function()
        local live, sched, sent = fixture()
        live:add("fast", 0, 0, 10, 10)
        sched:advance(0.001)
        live:add("fast", 10, 10, 20, 20)
        t:eq(live:flush(), true, "a lift flushes the tail")
        t:eq(#sent, 2, "went out")
        t:eq(live:flush(), false, "nothing more to send")
        sched:advance(1)
        t:eq(#sent, 2, "the stale timer found nothing")
    end)

    t:case("close disarms the timer and refuses further boxes", function()
        local live, sched, sent = fixture()
        live:add("fast", 0, 0, 10, 10)
        sched:advance(0.001)
        live:add("fast", 10, 10, 20, 20)
        live:close()
        t:eq(sched:pending(), 0, "timer removed")
        t:eq(live:add("fast", 0, 0, 5, 5), false, "closed")
        sched:advance(1)
        t:eq(#sent, 1, "nothing after close")
    end)

    t:case("adding does not allocate", function()
        local live, sched = fixture()
        live:add("fast", 0, 0, 10, 10)        -- the first flush and the arm
        sched:advance(0.001)
        live:add("fast", 1, 1, 11, 11)        -- arms the timer (the fake allocates once here)
        local function add()
            for i = 1, 200 do live:add("fast", i, i, i + 3, i + 3) end
        end
        add()
        local settled, last = false, nil
        for _ = 1, 8 do
            collectgarbage()
            collectgarbage()
            local before = collectgarbage("count")
            add()
            collectgarbage()
            collectgarbage()
            last = collectgarbage("count") - before
            if last <= 0 then settled = true; break end
        end
        t:eq(settled, true, "growth reaches zero (last round " .. tostring(last) .. " KiB)")
    end)
end
