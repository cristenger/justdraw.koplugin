--[[--
Keeping a contact from ever existing, and retiring one that already does.

These two are the only mechanism left for telling a palm's gesture from the
reader's. An emitted gesture carries `ges`, `pos` and `time` and no slot
number, and the overlay deliberately hands gestures above the sheet to the
book, so once a palm's `hold` has been produced there is nothing left to
distinguish it by. Removing the slot from its first frame means the Contact --
and therefore the hold timer -- is never created at all.

The late case is the one a filter cannot reach: a contact-down frame with no
coordinates has already gone through by the time the next frame says where it
landed. `dropContact` retires that one, per slot, so a finger on the toolbar is
not caught up in it.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Device = ctx.Device
    local Capture = require("ink_capture")

    local function install(handler)
        ctx.reset()
        local input = Device.input
        local ok = Capture:installFinger(handler, function() end)
        return input, ok
    end

    local function frame(bus, ...)
        return bus:frame(...)
    end

    -- =================================================================
    t:describe("ink_capture / slot filtering")

    t:case("a handler that returns nothing leaves the frame untouched", function()
        local input = install(function() end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        bus:set(1, { id = 2, x = 20, y = 20 })
        local sent = frame(bus, 0, 1)
        input.gesture_detector:feedEvent(sent)
        t:eq(input.gesture_detector.last_slots, sent, "the same array went through")
        t:eq(#input.gesture_detector.last_slots, 2, "with both contacts")
    end)

    t:case("a handler can withhold a slot from the detector", function()
        local input = install(function(slots)
            local kept = {}
            for i = 1, #slots do
                if slots[i].slot ~= 1 then kept[#kept + 1] = slots[i] end
            end
            return kept
        end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        bus:set(1, { id = 2, x = 20, y = 20 })
        input.gesture_detector:feedEvent(frame(bus, 0, 1))
        local seen = input.gesture_detector.last_slots
        t:eq(#seen, 1, "one contact got through")
        t:eq(seen[1].slot, 0, "the one that was kept")
    end)

    t:case("a withheld slot never opens a contact, so no hold timer is armed", function()
        local input = install(function(slots)
            local kept = {}
            for i = 1, #slots do
                if slots[i].slot ~= 1 then kept[#kept + 1] = slots[i] end
            end
            return kept
        end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        bus:set(1, { id = 2, x = 20, y = 20 })
        input.gesture_detector:feedEvent(frame(bus, 0, 1))
        local gd = input.gesture_detector
        t:check(gd:getContact(0) ~= nil, "the kept contact exists")
        t:eq(gd:getContact(1), nil, "and the palm's never did")
    end)

    t:case("a handler that raises passes the whole frame through", function()
        local input = install(function() error("boom", 0) end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        local sent = frame(bus, 0)
        input.gesture_detector:feedEvent(sent)
        t:eq(input.gesture_detector.last_slots, sent,
            "degrading has to mean 'as if we were not here', not a broken frame")
    end)

    t:case("a handler returning something that is not a frame is ignored", function()
        local input = install(function() return true end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        local sent = frame(bus, 0)
        input.gesture_detector:feedEvent(sent)
        t:eq(input.gesture_detector.last_slots, sent, "the real frame went through")
    end)

    -- =================================================================
    t:describe("ink_capture / dropping one contact")

    t:case("dropping a slot retires its contact and its timers", function()
        local input = install(function() end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        input.gesture_detector:feedEvent(frame(bus, 0))
        local contact = input.gesture_detector:getContact(0)
        t:eq(contact.pending_hold_timer, true, "the timer was armed")
        t:eq(Capture:dropContact(0), true, "dropped")
        t:eq(input.gesture_detector:getContact(0), nil, "the contact is gone")
        t:eq(contact.pending_hold_timer, nil, "and so is its hold timer")
    end)

    t:case("dropping one slot leaves the others alone", function()
        local input = install(function() end)
        local bus = support.newSlotBus()
        bus:set(0, { id = 1, x = 10, y = 10 })
        bus:set(1, { id = 2, x = 20, y = 20 })
        input.gesture_detector:feedEvent(frame(bus, 0, 1))
        Capture:dropContact(1)
        t:check(input.gesture_detector:getContact(0) ~= nil,
            "the finger on the toolbar keeps its contact")
        t:eq(#input.gesture_detector.dropped, 1, "exactly one was dropped")
    end)

    t:case("dropping a slot with no contact is harmless", function()
        install(function() end)
        t:eq(Capture:dropContact(3), false, "nothing to do, nothing done")
    end)

    t:case("dropping without the API is a no-op rather than a crash", function()
        ctx.reset()
        local input = Device.input
        input.gesture_detector.getContact = nil
        Capture:installFinger(function() end, function() end)
        t:eq(Capture:dropContact(0), false, "an older GestureDetector is survivable")
    end)

    t:case("dropping before anything is installed is harmless", function()
        ctx.reset()
        Capture:remove()
        t:eq(Capture:dropContact(0), false, "no detector, no contact")
    end)
end
