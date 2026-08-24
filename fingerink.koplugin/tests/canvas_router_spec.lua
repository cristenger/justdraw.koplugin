--[[--
Where a contact's input goes, decided once and not revisited.

The bug this module exists to prevent is a contact changing owner mid-sequence.
Handing a slot back to GestureDetector part-way through makes it open a fresh
contact and emit a spurious tap on lift; taking one away part-way through
strands a contact that never sees its lift, leaving a pending hold timer that
blocks the slot. So the destination is latched on the first frame that carries
real coordinates, and crossing a border afterwards changes nothing.

The one deliberate exception is a finger already resting on the page when the
pen lands. That finger is cancelled -- its contact is dropped, timers and all
-- because a palm turning the page mid-stroke is the failure the stylus route
exists to prevent. The toolbar is exempt from every version of that rule:
pressing Stop has to work with the pen down, or there is no way out.
]]

return function(ctx)
    local t = ctx.t
    local Router = require("ink_contact_router")

    --- Regions laid out as horizontal bands, so a test can name a place by its
    --- y coordinate: bar 0-99, handle 100-199, canvas 200-299, reader 300+.
    local function regionAt(_, y)
        if y < 100 then return "bar" end
        if y < 200 then return "handle" end
        if y < 300 then return "canvas" end
        return "reader"
    end

    local BAR, HANDLE, CANVAS, READER = 50, 150, 250, 350

    local function router(opts)
        opts = opts or {}
        local state = { dialog = opts.dialog or false }
        local r = Router.new{
            backend = opts.backend or "stylus",
            regions = regionAt,
            dialogOnTop = function() return state.dialog end,
        }
        return r, state
    end

    -- =================================================================
    t:describe("ink_contact_router / classifying the pen")

    t:case("the pen is placed by where it lands", function()
        for _, case in ipairs({
            { BAR, "bar" }, { HANDLE, "handle" },
            { CANVAS, "canvas" }, { READER, "reader" },
        }) do
            local r = router()
            t:eq(r:penContact(10, case[1]), case[2], "y = " .. case[1])
        end
    end)

    t:case("a dialog on top beats every region", function()
        local r, state = router()
        state.dialog = true
        t:eq(r:penContact(10, CANVAS), "dialog", "even over the canvas")
        t:eq(r:penDominates(), false, "so the dialog gets its taps")
    end)

    t:case("the pen dominates on the canvas and over the text, but not on the bar", function()
        local cases = {
            { CANVAS, true }, { READER, true },
            { BAR, false }, { HANDLE, false },
        }
        for _, case in ipairs(cases) do
            local r = router()
            r:penContact(10, case[1])
            t:eq(r:penDominates(), case[2], "y = " .. case[1])
        end
    end)

    t:case("the pen only inks on the canvas", function()
        local r = router()
        r:penContact(10, READER)
        t:eq(r:penDraws(), false,
            "dominated so the palm rule holds, but the text is not a drawing surface")
        local r2 = router()
        r2:penContact(10, CANVAS)
        t:eq(r2:penDraws(), true, "here it is")
    end)

    -- =================================================================
    t:describe("ink_contact_router / latching")

    t:case("a contact with no coordinates yet is undecided", function()
        local r = router()
        t:eq(r:penContact(nil, nil), nil, "nothing to classify from")
        t:eq(r:penDominates(), false, "and no decision has been taken")
    end)

    t:case("the first frame with coordinates is the one that decides", function()
        local r = router()
        r:penContact(nil, nil)
        t:eq(r:penContact(10, CANVAS), "canvas", "decided now")
        t:eq(r:penContact(10, BAR), "canvas", "and not revisited")
    end)

    t:case("a pen stroke dragged onto the toolbar stays the canvas's", function()
        local r = router()
        r:penContact(10, CANVAS)
        r:penContact(10, BAR)
        t:eq(r:penDominates(), true, "still dominated, so no button is pressed")
    end)

    t:case("a pen contact that started on the toolbar stays passthrough", function()
        local r = router()
        r:penContact(10, BAR)
        r:penContact(10, CANVAS)
        t:eq(r:penDominates(), false, "dragging off the button does not start a stroke")
        t:eq(r:penDraws(), false, "and inks nothing")
    end)

    t:case("a lift ends the latch and the next contact is classified afresh", function()
        local r = router()
        r:penContact(10, BAR)
        r:penUp()
        t:eq(r:penContact(10, CANVAS), "canvas", "a new sequence, a new decision")
    end)

    t:case("a finger keeps the destination it landed on", function()
        local r = router{ backend = "finger" }
        r:touchContact(0, 10, READER)
        r:touchContact(0, 10, CANVAS)
        t:eq(r:destinationOf(0), "reader", "crossing into the sheet changes nothing")
    end)

    t:case("each finger is latched on its own", function()
        local r = router{ backend = "finger" }
        r:touchContact(0, 10, BAR)
        r:touchContact(1, 10, READER)
        t:eq(r:destinationOf(0), "bar", "the one on the toolbar")
        t:eq(r:destinationOf(1), "reader", "and the one on the page")
    end)

    -- =================================================================
    t:describe("ink_contact_router / touch under the stylus route")

    t:case("a finger on the canvas is a palm", function()
        local r = router{ backend = "stylus" }
        t:eq(r:touchContact(0, 10, CANVAS), "palm",
            "there is no way to tell a palm from a finger, so neither draws")
        t:eq(r:suppresses(0), true, "and it reaches nothing")
    end)

    t:case("a finger above the sheet still turns the page", function()
        local r = router{ backend = "stylus" }
        t:eq(r:touchContact(0, 10, READER), "reader", "reading keeps working")
        t:eq(r:suppresses(0), false, "nothing is swallowed")
        t:eq(r:forwards(0), true, "it goes to the reader")
    end)

    t:case("a finger on the toolbar reaches the toolbar", function()
        local r = router{ backend = "stylus" }
        t:eq(r:touchContact(0, 10, BAR), "bar", "always")
        t:eq(r:suppresses(0), false, "never swallowed")
    end)

    t:case("a finger on the canvas draws on the finger route", function()
        local r = router{ backend = "finger" }
        t:eq(r:touchContact(0, 10, CANVAS), "canvas", "that is the whole route")
        t:eq(r:draws(0), true, "and it inks")
    end)

    -- =================================================================
    t:describe("ink_contact_router / the pen and the hand")

    t:case("a finger landing while the pen is down is a palm, even over the text", function()
        local r = router{ backend = "stylus" }
        r:penContact(10, CANVAS)
        t:eq(r:touchContact(0, 10, READER), "palm",
            "the hand does not turn the page mid-stroke")
    end)

    t:case("the toolbar is still reachable with the pen down", function()
        -- The safety invariant: there is always a way to stop drawing.
        local r = router{ backend = "stylus" }
        r:penContact(10, CANVAS)
        t:eq(r:touchContact(0, 10, BAR), "bar", "Stop can always be pressed")
        t:eq(r:suppresses(0), false, "and the tap gets through")
    end)

    t:case("a finger already resting when the pen lands is cancelled", function()
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, READER)
        t:eq(r:destinationOf(0), "reader", "it was the reader's")
        r:penContact(10, CANVAS)
        t:eq(r:destinationOf(0), "palm", "and now it is nobody's")
        t:eq(r:takeCancelled()[1], 0, "the slot is reported so its contact can be dropped")
    end)

    t:case("a finger on the toolbar is not cancelled when the pen lands", function()
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, BAR)
        r:penContact(10, CANVAS)
        t:eq(r:destinationOf(0), "bar", "the way out is never taken away")
        t:eq(#r:takeCancelled(), 0, "and its contact is left alone")
    end)

    t:case("cancelled slots are reported once, not on every frame", function()
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, READER)
        r:penContact(10, CANVAS)
        t:eq(#r:takeCancelled(), 1, "reported")
        t:eq(#r:takeCancelled(), 0, "and not again")
    end)

    t:case("a cancelled finger stays suppressed until its own lift", function()
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, READER)
        r:penContact(10, CANVAS)
        r:penUp()
        t:eq(r:destinationOf(0), "palm", "the pen going up does not give it back")
        r:touchUp(0)
        r:touchContact(0, 10, READER)
        t:eq(r:destinationOf(0), "reader", "only a fresh contact is classified again")
    end)

    t:case("touch navigation comes back once the pen lifts", function()
        local r = router{ backend = "stylus" }
        r:penContact(10, CANVAS)
        r:penUp()
        t:eq(r:touchContact(1, 10, READER), "reader", "a new finger reads normally")
    end)

    t:case("a pen contact with no coordinates yet still guards the page", function()
        -- The pen is touching; only where is unknown. Letting a finger through
        -- in that window is the same page turn, one frame earlier.
        local r = router{ backend = "stylus" }
        r:penContact(nil, nil)
        t:eq(r:touchContact(0, 10, READER), "palm", "guarded from the first frame")
    end)

    -- =================================================================
    t:describe("ink_contact_router / bookkeeping")

    t:case("lifting the last finger leaves nothing behind", function()
        local r = router{ backend = "finger" }
        r:touchContact(0, 10, CANVAS)
        r:touchContact(1, 10, READER)
        t:eq(r:touchCount(), 2, "two down")
        r:touchUp(0)
        r:touchUp(1)
        t:eq(r:touchCount(), 0, "and none left")
        t:eq(r:destinationOf(0), nil, "no stale latch")
    end)

    t:case("a repeated lift is harmless", function()
        local r = router{ backend = "finger" }
        r:touchContact(0, 10, CANVAS)
        r:touchUp(0)
        r:touchUp(0)
        t:eq(r:touchCount(), 0, "hover frames re-deliver a lift, and it must not go negative")
    end)

    t:case("reset clears every latch", function()
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, CANVAS)
        r:penContact(10, CANVAS)
        r:reset()
        t:eq(r:touchCount(), 0, "no fingers")
        t:eq(r:penDominates(), false, "no pen")
        t:eq(r:destinationOf(0), nil, "no destinations")
        t:eq(#r:takeCancelled(), 0, "and nothing queued to drop")
    end)

    t:case("changing backend resets the latches with it", function()
        -- Swapping routes mid-sequence is what tears down capture inside a
        -- live contact; the router must not carry a stylus-era decision into
        -- the finger route.
        local r = router{ backend = "stylus" }
        r:touchContact(0, 10, CANVAS)
        t:eq(r:destinationOf(0), "palm", "suppressed as a palm")
        r:setBackend("finger")
        t:eq(r:destinationOf(0), nil, "and the latch is gone with the route")
    end)
end
