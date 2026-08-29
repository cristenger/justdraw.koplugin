--[[--
ink_slot_steer: one cursor per input device.

Every scenario is a sequence recorded on a Kindle Scribe on 2026-08-28; the
line numbers refer to that crash.log. The slot machine is support.newSlotInput,
a copy of Input's own; tests/conformance.lua replays the same scenarios
against the real one.
]]
return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Steer = require("ink_slot_steer")
    local C = Steer.codes

    local function abs(code, value) return { type = C.EV_ABS, code = code, value = value } end
    local function key(code, value) return { type = C.EV_KEY, code = code, value = value } end
    local function syn(code) return { type = C.EV_SYN, code = code or 0, value = 0 } end

    --- Drive one event through the policy and then through the (replicated)
    --- KOReader bookkeeping the way waitEvent would: hook first, handler after.
    local function feed(state, input, ev)
        Steer.apply(state, input, ev)
        if ev.type == C.EV_ABS then
            if ev.code == C.ABS_MT_SLOT then input:setupSlotData(ev.value)
            elseif ev.code == C.ABS_MT_TRACKING_ID then input:setCurrentMtSlotChecked("id", ev.value)
            elseif ev.code == C.ABS_MT_TOOL_TYPE then input:setCurrentMtSlot("tool", ev.value)
            elseif ev.code == C.ABS_MT_POSITION_X or ev.code == C.ABS_X then input:setCurrentMtSlotChecked("x", ev.value)
            elseif ev.code == C.ABS_MT_POSITION_Y or ev.code == C.ABS_Y then input:setCurrentMtSlotChecked("y", ev.value)
            end
        elseif ev.type == C.EV_KEY and ev.code == C.BTN_TOUCH then
            -- input.lua @ 60ce80ed, 770-790: only a PEN/ERASER tool takes the id
            local tool = input:getCurrentMtSlotData("tool")
            if tool == 1 or tool == 2 then
                input:setupSlotData(input.pen_slot)
                input:setCurrentMtSlot("id", ev.value == 1 and input.pen_slot or -1)
            end
        elseif ev.type == C.EV_SYN and ev.code == 0 then
            input:newFrame()
        end
    end

    -- =================================================================
    t:describe("slot steer / gate")

    t:case("it is refused off wacom, without a pen slot, or under the mixed handler", function()
        t:eq((Steer.new(support.newSlotInput{ wacom_protocol = false })), nil, "no wacom: nil")
        local no_pen = support.newSlotInput(); no_pen.pen_slot = nil
        t:eq((Steer.new(no_pen)), nil, "no pen slot: nil")
        local generic = function() end
        t:eq((Steer.new(support.newSlotInput{ mixed_handler = true }, generic)), nil,
            "reMarkable's handleMixedTouchEv shares ABS_X between panel and pen")
        local snow_off = support.newSlotInput(); snow_off.handleTouchEv = generic
        t:eq(type(Steer.new(snow_off, generic)), "table",
            "an instance field that is the class's own generic is still generic (input.lua 1173)")
        local inhibited = support.newSlotInput()
        inhibited._abs_ev_handler = generic; inhibited.handleTouchEv = function() end
        t:eq(type(Steer.new(inhibited, generic)), "table",
            "inhibitInput's voidEv does not hide a generic handler (input.lua 1741-1743)")
        t:eq(type(Steer.new(support.newSlotInput(), generic)), "table", "the Scribe shape is accepted")
    end)

    -- =================================================================
    t:describe("slot steer / R3: pen written into the panel's slot")

    t:case("a pen-down while the hand's slot is current lands in the pen slot (log 71495-71503)", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        -- Proximity: KOReader put the pen in slot 4 (BTN_TOOL_PEN, not steered).
        input:setupSlotData(4); input:setCurrentMtSlot("tool", 1); input:newFrame()
        -- The hand: a panel frame on slot 0.
        feed(state, input, abs(C.ABS_MT_SLOT, 0)); feed(state, input, abs(C.ABS_MT_TRACKING_ID, 7))
        feed(state, input, abs(C.ABS_MT_POSITION_X, 585)); feed(state, input, syn())
        -- The pen touches while cur_slot is still 0.
        feed(state, input, abs(C.ABS_X, 1100)); feed(state, input, abs(C.ABS_Y, 1579))
        feed(state, input, key(C.BTN_TOUCH, 1))
        t:eq(input.ev_slots[4].x, 1100, "the pen's x is in the pen slot")
        t:eq(input.ev_slots[4].y, 1579, "and its y")
        t:eq(input.ev_slots[4].id, 4, "and BTN_TOUCH set the pen id")
        t:eq(input.ev_slots[0].x, 585, "the hand's slot kept its own position")
        t:eq(input.ev_slots[0].id, 7, "and its own id")
        t:eq(#input.MTSlots, 1, "the pen slot is the only slot of this frame")
        t:eq(input.MTSlots[1].slot, 4, "and it is referenced for the SYN_REPORT")
        local pen, panel = Steer.counts(state)
        t:eq(pen, 1, "the first pen event moved the cursor; the rest found it there")
        t:eq(panel, 0, "no panel event needed steering")
    end)

    t:case("without the policy the same sequence loses the pen-down", function()
        local input = support.newSlotInput()
        local state = Steer.new(input)            -- active stays false
        input:setupSlotData(4); input:setCurrentMtSlot("tool", 1); input:newFrame()
        feed(state, input, abs(C.ABS_MT_SLOT, 0)); feed(state, input, abs(C.ABS_MT_TRACKING_ID, 7))
        feed(state, input, syn())
        feed(state, input, abs(C.ABS_X, 1100)); feed(state, input, key(C.BTN_TOUCH, 1))
        t:eq(input.ev_slots[0].x, 1100, "KOReader wrote the pen's x into the hand's slot")
        t:eq(input.ev_slots[4].id, nil, "and the pen never touched")
    end)

    -- =================================================================
    t:describe("slot steer / R4: panel written into the pen slot")

    t:case("a panel frame without ABS_MT_SLOT goes back to the panel's last slot (log 201452-201473)", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        -- The panel last used slot 1, some frames ago.
        feed(state, input, abs(C.ABS_MT_SLOT, 1)); feed(state, input, abs(C.ABS_MT_TRACKING_ID, -1))
        feed(state, input, syn())
        -- The pen hovers: KOReader's BTN_TOOL_PEN made slot 4 current.
        input:setupSlotData(4); input:setCurrentMtSlot("tool", 1); input:setCurrentMtSlot("id", -1)
        feed(state, input, abs(C.ABS_X, 834)); feed(state, input, syn())
        -- The hand comes down on the panel's slot 1, which the panel does not repeat.
        feed(state, input, abs(C.ABS_MT_TRACKING_ID, 1)); feed(state, input, abs(C.ABS_MT_TOOL_TYPE, 0))
        feed(state, input, abs(C.ABS_MT_POSITION_X, 473)); feed(state, input, abs(C.ABS_MT_POSITION_Y, 88))
        feed(state, input, syn())
        feed(state, input, abs(C.ABS_MT_TOOL_TYPE, 2)); feed(state, input, abs(C.ABS_MT_TRACKING_ID, -1))
        feed(state, input, syn())
        t:eq(input.ev_slots[4].tool, 1, "the pen slot is still a pen")
        t:eq(input.ev_slots[4].id, -1, "still hovering")
        t:eq(input.ev_slots[4].x, 834, "at its own position")
        t:eq(input.ev_slots[1].tool, 2, "the palm value went where the palm is")
        t:eq(input.ev_slots[1].x, 473, "with the palm's position")
        local pen, panel = Steer.counts(state)
        t:eq(panel, 1, "one move of the cursor covered both panel frames")
        t:eq(pen, 0, "and no pen event needed it")
    end)

    t:case("a lift that arrives in its own frame while the hand's slot is current still lifts the pen", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        input:setupSlotData(4); input:setCurrentMtSlot("tool", 1); input:setCurrentMtSlot("id", 4)
        input:newFrame()
        feed(state, input, abs(C.ABS_MT_SLOT, 0)); feed(state, input, abs(C.ABS_MT_TRACKING_ID, 7))
        feed(state, input, syn())
        -- log 18789: BTN_TOUCH 0 alone in its frame, with the hand's slot current
        feed(state, input, key(C.BTN_TOUCH, 0)); feed(state, input, syn())
        t:eq(input.ev_slots[4].id, -1, "the pen slot took the lift")
        t:eq(input.ev_slots[0].id, 7, "the hand's slot did not")
        t:eq((Steer.counts(state)), 1, "one move, for the key event alone")
    end)

    t:case("with no ABS_MT_SLOT ever seen the panel falls back to the main finger slot", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        input:setupSlotData(4); input:setCurrentMtSlot("tool", 1)
        feed(state, input, abs(C.ABS_MT_TRACKING_ID, 3))
        t:eq(input.cur_slot, 0, "main_finger_slot")
        t:eq(input.ev_slots[0].id, 3, "took the id")
        t:eq(input.ev_slots[4].id, nil, "and the pen slot did not")
    end)

    -- =================================================================
    t:describe("slot steer / R5 and cost")

    t:case("SYN_DROPPED is counted and nothing else", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        feed(state, input, syn(C.SYN_DROPPED))
        local _, _, drops = Steer.counts(state)
        t:eq(drops, 1, "one drop")
        t:eq(#input.MTSlots, 0, "no slot was touched")
    end)

    t:case("an inactive state changes nothing and counts nothing", function()
        local input = support.newSlotInput()
        local state = Steer.new(input)
        feed(state, input, abs(C.ABS_MT_SLOT, 0)); feed(state, input, abs(C.ABS_X, 5))
        t:eq(input.ev_slots[0].x, 5, "KOReader's own behaviour")
        t:eq((Steer.counts(state)), 0, "nothing counted")
    end)

    t:case("reset clears the counters and keeps the panel's slot", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        feed(state, input, abs(C.ABS_MT_SLOT, 1)); feed(state, input, syn(C.SYN_DROPPED))
        Steer.reset(state)
        local pen, panel, drops = Steer.counts(state)
        t:eq(pen + panel + drops, 0, "all three at zero")
        t:eq(state.panel_slot, 1, "the panel's last slot is state, not a counter")
    end)

    t:case("apply allocates nothing per event", function()
        local input = support.newSlotInput()
        local state = Steer.new(input); state.active = true
        input:setupSlotData(4)
        local ev = abs(C.ABS_X, 10)
        local function burst() for _ = 1, 1000 do Steer.apply(state, input, ev) end end
        -- The same loop twice: the JIT compiling it is an allocation too, and
        -- not the one this case is about.
        burst()
        collectgarbage("stop")
        local before = collectgarbage("count")
        burst()
        local grown = collectgarbage("count") - before
        collectgarbage("restart")
        t:eq(grown < 0.5, true, "a thousand events grew the heap by " .. grown .. " KB")
    end)

    -- =================================================================
    t:describe("slot steer / installation")

    local Capture = require("ink_capture")
    local Device = ctx.Device

    --- A Scribe-shaped Input: the stylus API and gesture detector the
    --- capture needs, plus the slot machine the policy drives.
    local function scribeInput()
        local input = support.newInput{ wacom_protocol = true }
        local machine = support.newSlotInput()
        for k, v in pairs(machine) do if input[k] == nil then input[k] = v end end
        return input
    end

    t:case("installing the stylus capture registers the hook once and arms it", function()
        ctx.reset()
        local input = scribeInput(); Device.input = input
        local ok = Capture:installStylus(function() return true end, function() end)
        t:eq(ok, true, "installed")
        t:eq(input.adjust_hooks_registered, 1, "one hook")
        t:eq(input.__justdraw_slot_steer.active, true, "armed")
        Capture:remove()
        t:eq(input.__justdraw_slot_steer.active, false, "disarmed on remove")
        t:eq(input.adjust_hooks_registered, 1, "and never unregistered: there is no API for it")
        Capture:installStylus(function() return true end, function() end)
        t:eq(input.adjust_hooks_registered, 1, "a second install does not chain a second hook")
        t:eq(input.__justdraw_slot_steer.active, true, "it re-arms the one that is there")
        Capture:remove()
    end)

    t:case("an armed hook steers; a disarmed one is a field read", function()
        ctx.reset()
        local input = scribeInput(); Device.input = input
        Capture:installStylus(function() return true end, function() end)
        input:setupSlotData(0)                        -- the hand owns the cursor
        input:eventAdjustHook({ type = C.EV_ABS, code = C.ABS_X, value = 12 })
        t:eq(input.cur_slot, 4, "the pen's x moved the cursor to the pen slot")
        Capture:remove()
        input:setupSlotData(0)
        input:eventAdjustHook({ type = C.EV_ABS, code = C.ABS_X, value = 12 })
        t:eq(input.cur_slot, 0, "off, KOReader's behaviour is untouched")
    end)

    t:case("the finger backend does not arm the steer", function()
        ctx.reset()
        local input = scribeInput(); Device.input = input
        Capture:installFinger(function() end, function() end)
        t:eq(input.__justdraw_slot_steer, nil, "nothing installed for finger capture")
        Capture:remove()
    end)

    t:case("a raise inside the hook disarms the whole capture", function()
        ctx.reset()
        local input = scribeInput(); Device.input = input
        local failed
        Capture:installStylus(function() return true end, function() end,
            function(err) failed = err end)
        input.setupSlotData = function() error("boom") end
        input:eventAdjustHook({ type = C.EV_ABS, code = C.ABS_X, value = 1 })
        t:eq(input.__justdraw_slot_steer.active, false, "disarmed at once")
        ctx.env.UIManager:flush()                     -- Capture:fail removes on the next tick
        t:eq(Capture.active, false, "the capture is gone")
        t:eq(tostring(failed):match("boom") ~= nil, true, "and the owner was told why")
    end)

    t:case("steer counts reach the diagnostics and reset with the lease", function()
        ctx.reset()
        local input = scribeInput(); Device.input = input
        Capture:installStylus(function() return true end, function() end)
        input:setupSlotData(0)
        input:eventAdjustHook({ type = C.EV_ABS, code = C.ABS_X, value = 1 })
        input:eventAdjustHook({ type = C.EV_SYN, code = C.SYN_DROPPED, value = 0 })
        local pen, panel, drops = Capture:steerCounts()
        t:eq(pen, 1, "one pen event steered"); t:eq(panel, 0, "no panel event"); t:eq(drops, 1, "one drop")
        Capture:remove()
        t:eq((Capture:steerCounts()), 0, "gone with the lease")
    end)
end
