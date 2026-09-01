--[[--
The Kindle Scribe palm, end to end.

Linux reports a rejected touch as MT_TOOL_PALM. That value is 2, and so is
KOReader's TOOL_TYPE_ERASER, so `Input:routeStylusEvents` hands a resting hand
to the stylus callback wearing the rear eraser's number. A physical recording
shows what followed: the palm ran the erase path, it overwrote the pen's last
lift position, the next pen contact started from that stale pair and drew a
page-wide line to where the pen actually was, and the palm's lift was never
counted, so Add page stayed disabled with nothing on the glass.

Every case below drives the exact recorded numbers through the whole boundary
-- persistent slot update, SYN frame, KOReader's routing predicate, the
callback, the palm gate, the sequence, removal of dominated slots, and the
wrapped GestureDetector frame -- rather than calling private handlers, because
the ordering between those stages is where the defects lived.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Device = ctx.Device
    local Capture = require("ink_capture")
    local PalmGate = require("ink_wacom_palm")
    local Geometry = require("ink_stylus_geometry")
    local Sequence = require("ink_stylus_sequence")
    local Replay = require("input_replay")
    local Replays = require("wacom_scribe_replays")
    local Adapter = require("ink_notebook_input")
    local Session = require("ink_notebook_session")

    --- Push one recorded fixture through a Replay bus, one SYN per frame.
    local function play(replay, frames)
        for f = 1, #frames do
            local frame = frames[f]
            for e = 1, #frame do
                replay:set(frame[e].slot, frame[e].fields)
            end
            replay:syn()
        end
    end

    -- =================================================================
    t:describe("wacom fixtures / provenance")

    t:case("every recorded fixture carries scalar slot data and nothing else", function()
        local names = {
            "palm_promotes_two_touch_slots", "palm_then_stale_pen_pair",
            "split_x_then_y", "split_y_then_x", "palm_promote_and_lift",
            "palm_reverts_before_lift", "physical_eraser_on_pen_slot",
        }
        for i = 1, #names do
            local ok, offending = Replays.validate(Replays[names[i]]())
            t:eq(ok, true, names[i] .. " is sanitized: " .. tostring(offending))
        end
        t:eq(Replays.validate({ { { slot = 0, fields = { title = 1 } } } }), nil,
            "a non-slot field is refused")
        t:eq(Replays.validate({ { { slot = 0, fields = { x = "left" } } } }), nil,
            "a non-scalar value is refused")
        t:eq(Replays.PEN_SLOT, 4, "the recorded pen slot")
    end)

    -- =================================================================
    t:describe("ink_capture / physical slot classification")

    local function wacomInput()
        local input = support.newInput{ wacom_protocol = true }
        Capture:resolveTools(input)
        return input
    end

    t:case("the ambiguous predicate is gone, not merely unused", function()
        -- It answered two different questions with one boolean, and every
        -- caller that wanted the second one got the first. Leaving an alias
        -- behind would let a later caller make the same mistake.
        t:eq(Capture.isStylusSlot, nil, "isStylusSlot no longer exists")
        t:eq(type(Capture.isKORoutedStylusSlot), "function", "routing has its own name")
        t:eq(type(Capture.physicalSlotRole), "function", "and so does trust")
    end)

    t:case("a callback invocation is not proof of pen identity", function()
        local input = wacomInput()
        local palm = { slot = 0, id = 3, x = 10, y = 20, tool = 2 }
        t:eq(Capture:isKORoutedStylusSlot(palm, input), true,
            "KOReader routes it, because tool 2 is its ERASER value")
        local role, reason = Capture:physicalSlotRole(palm, input)
        t:eq(role, "routed_palm", "JustDraw does not call it a pen")
        t:eq(reason, "wacom_non_pen_tool", "and says exactly why")
    end)

    t:case("on Wacom only the digitizer's own slot can be trusted", function()
        local input = wacomInput()
        local role, reason = Capture:physicalSlotRole(
            { slot = 4, id = 1, tool = 2 }, input)
        t:eq(role, "trusted_stylus", "tool 2 on the pen slot is the rear eraser")
        t:eq(reason, "wacom_pen_slot", "identified by slot, not by tool")

        t:eq(Capture:physicalSlotRole({ slot = 4, id = 1, tool = 0 }, input),
            "trusted_stylus", "and stays the pen while leaving proximity")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 0 }, input),
            "touch", "an ordinary touch slot is ordinary touch")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 1 }, input),
            "routed_palm", "a pen tool off the pen slot is still a hand")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 3 }, input),
            "routed_palm", "so is a highlighter")
    end)

    --[[--
    Off Wacom the tool value is the panel's, unedited.

    KOReader copies ABS_MT_TOOL_TYPE through without a range check, and only
    writes tool values of its own where `wacom_protocol or isSDL` holds. So on
    an ordinary panel the number means what the Linux UAPI says it means:
    0 finger, 1 pen, 2 MT_TOOL_PALM, 3 MT_TOOL_DIAL. Reading 2 as an eraser
    there is the same mistake ADR-22 closed for Wacom, one device class over --
    a resting hand that erases.
    ]]
    t:case("off Wacom only a pen-valued tool is a pen", function()
        local input = support.newInput{ wacom_protocol = false }
        Capture:resolveTools(input)
        local role, reason = Capture:physicalSlotRole(
            { slot = 1, id = 2, tool = 1 }, input)
        t:eq(role, "trusted_stylus", "a Kobo stylus reports MT_TOOL_PEN")
        t:eq(reason, "tool_type", "named as such")
        local palm_role, palm_reason = Capture:physicalSlotRole(
            { slot = 1, id = 2, tool = 2 }, input)
        t:eq(palm_role, "routed_palm",
            "with no button held, tool 2 is MT_TOOL_PALM, not an eraser")
        t:eq(palm_reason, "panel_tool_not_pen", "and says which namespace it read")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 3 }, input),
            "routed_palm", "so is MT_TOOL_DIAL")

        --[[--
        The same number, written by KOReader instead of by the panel.

        `BTN_STYLUS` sets `stylus_eraser_active` and routeStylusEvents rewrites
        the slot to ERASER. That branch is gated on `not isSDL`, not on the pen
        protocol, so it is live on an ordinary Kobo: this is a real stylus with
        its barrel button held, and refusing it would leave that device with no
        eraser and -- because a tracked palm stops consulting the tool -- no pen
        either until the lift.
        ]]
        input.stylus_eraser_active = true
        local held_role, held_reason = Capture:physicalSlotRole(
            { slot = 1, id = 2, tool = 2 }, input)
        t:eq(held_role, "trusted_stylus", "a held barrel button is a real eraser")
        t:eq(held_reason, "stylus_button", "named by the latch that wrote it")
        input.stylus_eraser_active = false
        input.stylus_highlighter_active = true
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 3 }, input),
            "trusted_stylus", "and the second button is a real highlighter")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 2 }, input),
            "routed_palm",
            "the highlighter latch does not vouch for an eraser value")
        input.stylus_highlighter_active = false
        local sdl_role, sdl_reason = Capture:physicalSlotRole(
            { slot = 4, id = 2, tool = 2 }, input)
        t:eq(sdl_role, "trusted_stylus",
            "an eraser on the dedicated pen slot is still the pen: that is "
                .. "where KOReader puts its own BTN_TOOL_RUBBER on SDL")
        t:eq(sdl_reason, "configured_pen_slot", "named by the slot, not the tool")
        t:eq(Capture:physicalSlotRole({ slot = 4, id = 2, tool = 0 }, input),
            "trusted_stylus", "a configured pen slot still counts")
        t:eq(Capture:physicalSlotRole({ slot = 1, id = 2, tool = 0 }, input),
            "touch", "and everything else is touch")
    end)

    --[[--
    Which of the two things an ERASER tool is, counted apart.

    KOReader rewrites PEN to ERASER while BTN_STYLUS is held and never writes
    PEN back, so the value survives the button. Nothing here can undo that; the
    counters exist so a diagnostics report says whether the erases came from a
    button that was down or from a tool value on its own.
    ]]
    t:case("erases are counted by where the eraser tool came from", function()
        Capture:resetEraserCounts()
        local held = support.newInput{ wacom_protocol = true }
        held.stylus_eraser_active = true
        t:eq(Capture:eraserToolSource(held), "button", "the latch is readable")
        t:eq(Capture:noteEraserContact(held), "button", "and counted as its own")
        local bare = support.newInput{ wacom_protocol = true }
        t:eq(Capture:eraserToolSource(bare), "tool",
            "a rear eraser or a stuck value looks the same, and is not the button")
        Capture:noteEraserContact(bare)
        Capture:noteEraserContact(bare)
        local by_button, by_tool = Capture:eraserCounts()
        t:eq(by_button, 1, "one erase came from the held button")
        t:eq(by_tool, 2, "two came from the tool value alone")
        Capture:resolveTools(bare)
        by_button, by_tool = Capture:eraserCounts()
        t:eq(by_button, 0, "a new lease starts the count over")
        t:eq(by_tool, 0, "on both halves")
    end)

    t:case("a Wacom runtime with no pen slot is refused, not guessed at", function()
        local input = support.newInput{ wacom_protocol = true }
        input.pen_slot = nil
        Capture:resolveTools(input)
        local ok, reason = Capture:validateStylusInput(input)
        t:eq(ok, nil, "activation refuses it")
        t:eq(reason, "wacom_pen_slot_missing", "with a closed reason")
        local role, why = Capture:physicalSlotRole({ slot = 0, id = 1, tool = 2 }, input)
        t:eq(role, "routed_palm", "and classification fails closed anyway")
        t:eq(why, "wacom_pen_slot_missing", "for the same reason")
        t:eq(Capture:validateStylusInput(wacomInput()), true,
            "a complete Wacom runtime is accepted")
    end)

    t:case("nil fields never classify as a pen", function()
        local input = wacomInput()
        t:eq(Capture:physicalSlotRole(nil, input), "touch", "no slot at all")
        t:eq(Capture:physicalSlotRole({ id = 1, tool = 2 }, input), "routed_palm",
            "a stylus tool on a slot with no number is not the pen slot")
        t:eq(Capture:physicalSlotRole({ id = 1 }, input), "touch",
            "and without one it is ordinary touch")
        t:eq(Capture:isKORoutedStylusSlot(nil, input), false, "and routes nowhere")
    end)

    -- =================================================================
    t:describe("ink_wacom_palm / the slot ledger")

    local function newGate(input)
        local retired = {}
        local gate = PalmGate.new{
            classify = function(slot) return Capture:physicalSlotRole(slot, input) end,
            retire_touch = function(slot_number)
                retired[#retired + 1] = slot_number
            end,
        }
        return gate, retired
    end

    t:case("promotion retires the touch it used to be, exactly once", function()
        local gate, retired = newGate(wacomInput())
        t:eq(gate:routeStylus{ slot = 0, id = 30, x = 1, y = 2, tool = 0 }, false,
            "a finger is not this gate's business")
        local handled, dominate, decision, reason =
            gate:routeStylus{ slot = 0, id = 30, x = 1, y = 2, tool = 2 }
        t:eq(handled, true, "the promotion is")
        t:eq(dominate, true, "and it is dominated")
        t:eq(decision, "palm", "traced as a palm")
        t:eq(reason, "palm_promoted", "on promotion")
        t:eq(#retired, 1, "the touch state it had is given back once")

        local _, _, _, again = gate:routeStylus{ slot = 0, id = 30, tool = 2 }
        t:eq(again, "palm_continued", "further samples are the same contact")
        t:eq(#retired, 1, "and retire nothing a second time")
        t:eq(gate:hasActiveContact(), true, "the hand is still down")
    end)

    t:case("two palms are tracked and released independently", function()
        local gate = newGate(wacomInput())
        gate:routeStylus{ slot = 0, id = 30, tool = 2 }
        gate:routeStylus{ slot = 1, id = 31, tool = 2 }
        t:eq(gate:activeCount(), 2, "both hands counted")
        gate:routeStylus{ slot = 0, id = -1, tool = 2 }
        t:eq(gate:activeCount(), 1, "one lifted")
        t:eq(gate:isTracked(1), true, "the other is still down")
        gate:routeStylus{ slot = 1, id = -1, tool = 2 }
        t:eq(gate:hasActiveContact(), false, "and then nothing is")
    end)

    t:case("a palm whose tool reverts to finger still ends at its real lift", function()
        local gate, retired = newGate(wacomInput())
        gate:routeStylus{ slot = 0, id = 60, x = 300, y = 900, tool = 2 }
        -- KOReader stops routing it here once the tool is finger again, so it
        -- turns up in the residual frame instead.
        t:eq(gate:filterResidual{ slot = 0, id = 60, x = 310, y = 915, tool = 0 }, true,
            "still suppressed: the tracking id says it is the same hand")
        t:eq(gate:hasActiveContact(), true, "and still counted")
        local suppress, boundary =
            gate:filterResidual{ slot = 0, id = -1, x = 310, y = 915, tool = 0 }
        t:eq(suppress, true, "its lift is withheld too")
        t:eq(boundary, "palm_lift", "and named as the boundary")
        t:eq(gate:hasActiveContact(), false, "the ledger is empty")
        t:eq(#retired, 1, "the promotion retired its touch state once")
    end)

    t:case("a lift closes a tracked palm whatever its tool says", function()
        local gate = newGate(wacomInput())
        gate:routeStylus{ slot = 0, id = 60, x = 300, y = 900, tool = 2 }
        -- The residual frame is where this arrives if the callback was
        -- disarmed mid-frame, and the tool there is still the eraser's number.
        -- A tracking id below zero ends the contact on its own; consulting the
        -- tool instead is what left `hasActiveContact` stuck true with nothing
        -- on the glass.
        local suppress, boundary = gate:filterResidual{ slot = 0, id = -1, tool = 2 }
        t:eq(suppress, true, "still withheld")
        t:eq(boundary, "palm_lift", "and named as the boundary")
        t:eq(gate:hasActiveContact(), false, "the ledger is empty")

        gate:routeStylus{ slot = 1, id = 61, x = 300, y = 900, tool = 2 }
        gate:filterResidual{ slot = 1, id = -1 }
        t:eq(gate:hasActiveContact(), false, "and a lift with no tool at all ends it too")
    end)

    t:case("a new tracking id on the same slot is a new contact", function()
        local gate = newGate(wacomInput())
        gate:routeStylus{ slot = 0, id = 60, tool = 2 }
        local suppress = gate:filterResidual{ slot = 0, id = 61, x = 1, y = 2, tool = 0 }
        t:eq(suppress, false, "handed back for the host to classify")
        t:eq(gate:hasActiveContact(), false, "the stale generation is closed")
    end)

    t:case("a promotion first seen in the residual frame is still caught", function()
        local gate, retired = newGate(wacomInput())
        t:eq(gate:filterResidual{ slot = 1, id = 70, x = 5, y = 6, tool = 2 }, true,
            "classified on the spot")
        t:eq(#retired, 1, "and its touch state retired")
        t:eq(gate:hasActiveContact(), true, "counted")
    end)

    t:case("reset forgets everything without inventing a lift", function()
        local gate, retired = newGate(wacomInput())
        gate:routeStylus{ slot = 0, id = 30, tool = 2 }
        gate:reset()
        t:eq(gate:hasActiveContact(), false, "nothing is tracked")
        t:eq(#retired, 1, "and no callback was made up on the way out")
    end)

    t:case("the pen slot is never consumed by the gate", function()
        local gate = newGate(wacomInput())
        t:eq(gate:routeStylus{ slot = 4, id = 1, tool = 2 }, false,
            "the rear eraser belongs to the sequence")
        t:eq(gate:filterResidual{ slot = 4, id = 1, tool = 0 }, false,
            "and so does a pen slot handed back to the UI")
    end)

    -- =================================================================
    t:describe("ink_stylus_geometry / axis coherence")

    t:case("a pair that matches the last boundary proves nothing", function()
        local g = Geometry.new()
        g:observe(400, 900)
        g:reset(false)
        local status, _, _, why = g:observe(400, 900)
        t:eq(status, "pending", "the sticky contact-down frame is refused")
        t:eq(why, "axis_both_pending", "neither axis has moved")
        t:eq(g:isAccepted(), false, "nothing was accepted")
    end)

    t:case("a half-fresh pair decides nothing at all", function()
        -- It is a fresh axis wearing the previous contact's other one: a
        -- position that never existed. Routing from it would hand a stroke to
        -- whoever owns the region its stale axis points at.
        local g = Geometry.new()
        g:observe(405, 894)
        g:reset(false)
        local status, x, y, why = g:observe(1594, 894)
        t:eq(status, "pending", "refused for every purpose")
        t:eq(x, nil, "with no pair offered")
        t:eq(y, nil, "on either axis")
        t:eq(why, "axis_y_pending", "naming the one still unproven")
        t:eq(g:isAccepted(), false, "and certainly not a point")

        status, x, y = g:observe(1594, 1070)
        t:eq(status, "accept", "both axes have now moved")
        t:eq(x, 1594, "the first point is the coherent pair")
        t:eq(y, 1070, "not the hybrid one before it")
    end)

    t:case("the other axis order behaves identically", function()
        local g = Geometry.new()
        g:observe(758, 1309)
        g:reset(false)
        t:eq(g:observe(758, 660), "pending", "y moved first, x is still stale")
        local status, x, y = g:observe(1676, 660)
        t:eq(status, "accept", "x completed the pair")
        t:eq(x, 1676, "at the real position")
        t:eq(y, 660, "on both axes")
    end)

    t:case("a seeded boundary spares the first contact of a lease", function()
        -- Without one, the first pair of every lease is unproven and the
        -- contact spends a frame proving where it is. The slot already knows.
        local g = Geometry.new(400, 900)
        local bx, by = g:baseline()
        t:eq(bx, 400, "the seed is the boundary")
        t:eq(by, 900, "on both axes")
        t:eq(g:observe(700, 300), "accept", "so the first real pair is a point")

        local unseeded = Geometry.new(nil, 900)
        t:eq(unseeded:baseline(), nil, "half a seed is no seed")
    end)

    t:case("a latched contact keeps the boundary moving with the slot", function()
        -- InkStylusSequence stops asking once a contact is passed, blocked or
        -- suspended. If the boundary froze there, the next contact-down would
        -- look fresh against a position the pen left long ago, and paint a
        -- line to it -- which is the defect this module exists to remove.
        local g = Geometry.new(10, 10)
        g:observe(200, 300)
        g:note(900, 900)
        g:reset(false)
        local bx, by = g:baseline()
        t:eq(bx, 900, "the boundary is where the slot actually ended")
        t:eq(by, 900, "on both axes")
        t:eq(g:observe(900, 900), "pending", "so the sticky pair is still sticky")
    end)

    t:case("a repeated position may route once the contact is under way", function()
        local g = Geometry.new()
        g:observe(450, 100)
        g:reset(false)
        t:eq(g:observe(450, 100), "pending", "the frame that opens it is sticky")
        t:eq(g:observe(450, 100), "route",
            "a position that survives into a later frame is really there")
        t:eq(g:isAccepted(), false, "which is still not enough to draw")
    end)

    t:case("a pending contact ends as one dot, never as a line", function()
        local g = Geometry.new()
        g:observe(400, 900)
        g:reset(false)
        g:observe(400, 900)
        local status, x, y = g:onLift(400, 900)
        t:eq(status, "dot", "at most a dot")
        t:eq(x, 400, "at the last position observed")
        t:eq(y, 900, "and nowhere else")

        local empty = Geometry.new()
        t:eq(empty:onLift(), "discard", "with nothing observed there is no dot")
    end)

    t:case("the boundary moves the baseline, teardown clears it", function()
        local g = Geometry.new()
        g:observe(10, 10)
        g:observe(20, 30)
        g:reset(false)
        local bx, by = g:baseline()
        t:eq(bx, 20, "the last finite pair becomes the next baseline")
        t:eq(by, 30, "on both axes")
        t:eq(g:observe(20, 30), "pending", "so the same pair is sticky again")

        g:reset(true)
        t:eq(g:baseline(), nil, "a lease boundary keeps nothing")
        t:eq(g:observe(20, 30), "route",
            "and the first pair of the next lease is a provisional baseline")
    end)

    t:case("an accepted contact takes later single-axis frames as they come", function()
        local g = Geometry.new()
        g:observe(10, 10)
        g:reset(false)
        g:observe(50, 60)
        t:eq(g:isAccepted(), true, "coherent")
        local status, x, y = g:observe(90, 60)
        t:eq(status, "accept", "one axis is enough once the contact is proven")
        t:eq(x, 90, "because both values now belong to it")
        t:eq(y, 60, "whichever arrived last")
    end)

    -- =================================================================
    t:describe("ink_stylus_sequence / recorded false lines")

    local function penHarness(opts)
        opts = opts or {}
        local log = { points = {}, starts = 0, finishes = 0, aborts = 0, ends = 0 }
        local sequence = Sequence.new{
            wacom_protocol = true,
            pen_slot = Replays.PEN_SLOT,
            tool_finger = Replays.TOOL_FINGER,
            geometry = Geometry.new(),
            classify = opts.classify or function(_, _, tool)
                return "draw", tool == Replays.TOOL_ERASER and "erase" or "ink"
            end,
            on_contact_start = function() log.starts = log.starts + 1; return true end,
            on_point = function(x, y, tool, is_first)
                log.points[#log.points + 1] =
                    { x = x, y = y, tool = tool, first = is_first }
                return "continue"
            end,
            on_finish = function() log.finishes = log.finishes + 1; return true end,
            on_abort = function() log.aborts = log.aborts + 1; return true end,
            on_contact_end = function() log.ends = log.ends + 1; return true end,
        }
        return sequence, log
    end

    t:case("the recorded stale pair never bridges two contacts", function()
        local sequence, log = penHarness()
        local replay = Replay.new{ mode = "unit", sequence = sequence }
        play(replay, Replays.palm_then_stale_pen_pair())

        for i = 1, #log.points do
            t:check(not (log.points[i].x == 456 and log.points[i].y == 1903
                and log.points[i].first == false),
                "the stale pair was never appended to anything")
        end
        local last = log.points[#log.points]
        t:eq(last.x, 1756, "the second contact starts where the pen really was")
        t:eq(last.y, 1752, "on both axes")
        t:eq(last.first, true, "as a new stroke, not as a segment")
    end)

    --[[--
    The lift is the only thing separating two pen contacts on Wacom.

    KOReader writes `pen_slot` into the pen's id on BTN_TOUCH down and -1 on the
    lift, and nothing else ever changes it, so `replacement_id` can never fire
    for a Scribe pen. This asserts the two halves of that: with the lift, two
    strokes; without it, the second contact is silently appended to the first --
    which is what makes a blind window (Input:inhibitInput) able to draw a line
    across a page, and why the hosts end the contact themselves when one opens.
    ]]
    t:case("a pinned pen id separates contacts only by the lift", function()
        local sequence, log = penHarness()
        local replay = Replay.new{ mode = "unit", sequence = sequence }
        play(replay, Replays.pen_id_pinned_across_contacts())
        t:eq(log.starts, 2, "two physical contacts")
        t:eq(log.ends, 2, "two boundaries")
        t:eq(#log.points, 3, "three points across the two")
        t:eq(log.points[1].first, true, "the first contact starts a stroke")
        t:eq(log.points[2].first, true,
            "and so does the second: the boundary the first left behind is far "
                .. "enough away to prove the new position on both axes at once")
        t:eq(log.points[2].x, 900, "where the pen actually came back down")
        t:eq(log.points[3].first, false, "its next sample continues that stroke")

        -- The same frames with the lift removed, which is exactly what a blind
        -- window leaves behind.
        local blind, blind_log = penHarness()
        local blind_replay = Replay.new{ mode = "unit", sequence = blind }
        local frames = Replays.pen_id_pinned_across_contacts()
        table.remove(frames, 3)
        play(blind_replay, frames)
        t:eq(blind_log.starts, 1, "without it there is only ever one contact")
        t:eq(blind_log.points[#blind_log.points].first, false,
            "and the second contact's position is appended to the first stroke")
    end)

    t:case("the recorded X-then-Y sequence draws no L", function()
        local sequence, log = penHarness()
        local replay = Replay.new{ mode = "unit", sequence = sequence }
        play(replay, Replays.split_x_then_y())

        for i = 1, #log.points do
            t:check(not (log.points[i].x == 1594 and log.points[i].y == 894),
                "the hybrid pair never became a point")
        end
        local last = log.points[#log.points]
        t:eq(last.x, 1594, "only the coherent pair did")
        t:eq(last.y, 1070, "on both axes")
        t:eq(last.first, true, "and it started the stroke")
    end)

    t:case("the recorded Y-then-X sequence draws no L either", function()
        local sequence, log = penHarness()
        local replay = Replay.new{ mode = "unit", sequence = sequence }
        play(replay, Replays.split_y_then_x())

        for i = 1, #log.points do
            t:check(not (log.points[i].x == 758 and log.points[i].y == 660),
                "the hybrid pair never became a point")
        end
        local last = log.points[#log.points]
        t:eq(last.x, 1676, "only the coherent pair did")
        t:eq(last.y, 660, "on both axes")
    end)

    t:case("a promoted palm reaching the sequence is discarded whole", function()
        local sequence, log = penHarness()
        local replay = Replay.new{ mode = "unit", sequence = sequence }
        play(replay, Replays.palm_promotes_two_touch_slots())
        t:eq(#log.points, 0, "no point")
        t:eq(log.starts, 0, "no contact")
        t:eq(log.ends, 0, "no boundary")
        t:eq(sequence.owner_slot, nil, "and no owner")
    end)

    -- =================================================================
    t:describe("standalone notebooks / recorded Scribe contacts")

    local function notebookFixture(opts)
        opts = opts or {}
        local store = support.newNotebookStore{
            pages = { { id = 11, notebook_id = 1, sort_key = 1024,
                logical_w = 1000, logical_h = 1400, template_kind = "blank" } },
        }
        local session = Session.new{
            repository = store,
            schedule = function(fn) fn() end,
            scheduleIn = function() end,
            unschedule = function() end,
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
        }
        session:open(1)
        local counters = { dirty = 0, errors = {}, ends = {} }
        local adapter = Adapter.new{
            get_mode = function() return "stylus" end,
            stylus_passthrough = opts.stylus_passthrough,
            touch_passthrough = opts.touch_passthrough,
            on_dirty = function() counters.dirty = counters.dirty + 1 end,
            on_error = function(reason)
                counters.errors[#counters.errors + 1] = reason
            end,
            on_physical_contact_end = function(_, reason)
                counters.ends[#counters.ends + 1] = reason
            end,
        }
        local spec = adapter:captureSpec(session, session:currentPage(),
            session:surface():transform())
        return session, adapter, spec, counters, store
    end

    --- Drive a fixture the way capture does: the stylus callback for every
    --- routed slot, then the residual frame with the dominated ones removed.
    local function playNotebook(spec, input, frames)
        for f = 1, #frames do
            local frame = frames[f]
            local slots, kept = {}, {}
            for e = 1, #frame do
                local entry = frame[e]
                local slot = { slot = entry.slot }
                for key, value in pairs(entry.fields) do slot[key] = value end
                slots[#slots + 1] = slot
            end
            for i = 1, #slots do
                local dominated = Capture:isKORoutedStylusSlot(slots[i], input)
                    and spec.stylus_handler(slots[i])
                if not dominated then kept[#kept + 1] = slots[i] end
            end
            spec.frame_handler(kept)
        end
    end

    --[[--
    Expand a fixture into whole slot states, one snapshot per SYN.

    A fixture names only the fields that changed, exactly as the device does.
    Accumulating them here rather than sharing one mutable table is the point:
    a shared table would make every frame look like the last one, which is the
    same mistake that makes a stale contact-down frame look like a real point.
    ]]
    local function persistentFrames(frames)
        local slots, out = {}, {}
        for f = 1, #frames do
            local frame, entries = frames[f], {}
            for e = 1, #frame do
                local entry = frame[e]
                local slot = slots[entry.slot]
                if not slot then
                    slot = { slot = entry.slot }
                    slots[entry.slot] = slot
                end
                for key, value in pairs(entry.fields) do slot[key] = value end
                local snapshot = {}
                for key, value in pairs(slot) do snapshot[key] = value end
                entries[#entries + 1] = { slot = entry.slot, fields = snapshot }
            end
            out[#out + 1] = entries
        end
        return out
    end

    t:case("a promoted palm does no work at all and leaves nothing behind", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, adapter, spec, counters = notebookFixture()
        local surface = session:surface()

        playNotebook(spec, input,
            persistentFrames(Replays.palm_promote_and_lift()))

        t:eq(#surface:cache():strokes(), 0, "no ink was rastered")
        t:eq(surface:pendingWrites(), 0, "nothing was queued")
        t:eq(counters.dirty, 0, "no dirty region was requested")
        t:eq(#counters.errors, 0, "and nothing failed")
        t:eq(adapter:hasActiveContact(session), false,
            "the palm's lift emptied the contact ledger")
        t:eq(next(adapter.residual), nil, "residual bookkeeping is clear")
        t:eq(adapter.palm_gate:hasActiveContact(), false, "so is the palm gate")
    end)

    t:case("a palm whose tool reverts is still released at its real lift", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, adapter, spec = notebookFixture()

        local frames = persistentFrames(Replays.palm_reverts_before_lift())
        for f = 1, #frames - 1 do
            playNotebook(spec, input, { frames[f] })
            t:eq(adapter:hasActiveContact(session), true,
                "the hand is on the glass for frame " .. f)
        end
        playNotebook(spec, input, { frames[#frames] })
        t:eq(adapter:hasActiveContact(session), false, "and off it after the lift")
        t:eq(#session:surface():cache():strokes(), 0, "having drawn nothing")
    end)

    t:case("the physical rear eraser still erases", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, _, spec = notebookFixture()
        local surface = session:surface()
        surface:addStroke({ 505, 505, 515, 520 }, 2, 4, Replays.TOOL_PEN)
        t:eq(#surface:cache():strokes(), 1, "a stroke to erase")

        playNotebook(spec, input,
            persistentFrames(Replays.physical_eraser_on_pen_slot()))
        t:eq(#surface:cache():strokes(), 0, "tool 2 on the pen slot is the eraser")
    end)

    t:case("a palm cannot erase", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, _, spec = notebookFixture()
        local surface = session:surface()
        surface:addStroke({ 300, 900, 310, 915 }, 2, 4, Replays.TOOL_PEN)
        local before = #surface:cache():strokes()

        playNotebook(spec, input,
            persistentFrames(Replays.palm_promote_and_lift()))
        t:eq(#surface:cache():strokes(), before,
            "the hand landed on the ink and it is still there")
    end)

    t:case("a hover on a palm-tooled slot invents no contact", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, adapter, spec, counters = notebookFixture()

        -- A slot that has never carried a tracking id, already reporting the
        -- eraser's tool number. Counting it would create a contact with
        -- nothing on the glass, and then publish a boundary for a contact that
        -- never began -- which now drives a rail rebuild.
        spec.stylus_handler{ slot = 0, x = 300, y = 900, tool = 2 }
        t:eq(adapter:hasActiveContact(session), false, "nothing is on the glass")
        spec.frame_handler({})
        t:eq(#counters.ends, 0, "so no boundary was published for it")
    end)

    t:case("a palm burst does no host work and does not grow", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, adapter, spec, counters = notebookFixture()
        local surface = session:surface()

        local slot = { slot = 0, id = 80, x = 300, y = 900, tool = 2 }
        for i = 1, 10000 do
            slot.x = 300 + i % 17
            slot.y = 900 + i % 13
            spec.stylus_handler(slot)
        end
        local tracked = 0
        for _ in pairs(adapter.palm_gate.palms) do tracked = tracked + 1 end

        t:eq(tracked, 1, "ten thousand samples are one ledger entry")
        t:eq(counters.dirty, 0, "no dirty region")
        t:eq(#surface:cache():strokes(), 0, "no raster")
        t:eq(surface:pendingWrites(), 0, "no queued write")
        t:eq(#counters.errors, 0, "no error")
        slot.id = -1
        spec.stylus_handler(slot)
        t:eq(adapter:hasActiveContact(session), false, "and it ends when the hand lifts")
    end)

    t:case("the recorded false line never reaches the surface", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, _, spec = notebookFixture()
        local surface = session:surface()

        playNotebook(spec, input,
            persistentFrames(Replays.palm_then_stale_pen_pair()))

        local strokes = surface:cache():strokes()
        for i = 1, #strokes do
            local stroke = strokes[i]
            local points = stroke.points or stroke
            for j = 1, (stroke.n or 0) do
                local x, y = points[j * 2 - 1], points[j * 2]
                t:check(not (x == 456 and y == 1903 and (stroke.n or 0) > 1),
                    "no persisted stroke contains the previous contact's position")
            end
        end
    end)

    t:case("the pen's own slot still writes ink through the same path", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local session, adapter, spec = notebookFixture()

        playNotebook(spec, input, persistentFrames({
            { { slot = 4, fields = { id = 90, x = 100, y = 100, tool = 1 } } },
            { { slot = 4, fields = { x = 140, y = 160 } } },
            { { slot = 4, fields = { x = 180, y = 220 } } },
            { { slot = 4, fields = { id = -1 } } },
        }))
        t:eq(session:surface():pendingWrites(), 1, "one durable stroke")
        t:eq(adapter:hasActiveContact(session), false, "and the pen is off the glass")
    end)

    t:case("a palm cannot move the trusted pen baseline", function()
        ctx.reset{ wacom_protocol = true }
        local input = Device.input
        Capture:resolveTools(input)
        local _, adapter, spec = notebookFixture()

        playNotebook(spec, input, persistentFrames({
            { { slot = 4, fields = { id = 91, x = 100, y = 100, tool = 1 } } },
            { { slot = 4, fields = { x = 400, y = 500 } } },
            { { slot = 4, fields = { id = -1 } } },
        }))
        local bx, by = adapter.geometry:baseline()
        t:eq(bx, 400, "the pen's own boundary is the baseline")
        t:eq(by, 500, "on both axes")

        playNotebook(spec, input,
            persistentFrames(Replays.palm_promote_and_lift()))
        local ax, ay = adapter.geometry:baseline()
        t:eq(ax, 400, "and a whole palm contact leaves it alone")
        t:eq(ay, 500, "on both axes")
    end)

    -- =================================================================
    t:describe("direct ink / recorded Scribe contacts")

    local function penPlugin()
        local p = ctx.realBarPlugin{ wacom_protocol = true }
        p:setDrawing(true)
        return p, Device.input
    end

    t:case("a promoted palm never inks, erases, or turns a page", function()
        local p, input = penPlugin()
        p.store:add(1, { n = 1, w = 4, 300, 900 })
        local before_refreshes = #Device.screen.refreshes
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.palm_promote_and_lift())

        t:eq(#p.store:get(1), 1, "the stroke under the hand is untouched")
        t:eq(p.stroke, nil, "nothing was drawn")
        t:eq(#Device.screen.refreshes, before_refreshes, "and nothing was refreshed")
        t:eq(p:hasActivePhysicalContact(), false, "the ledger is empty after the lift")
        t:eq(p.n_contacts, 0, "and so is the touch bookkeeping")
    end)

    t:case("gray direct ink refreshes ride a grayscale pass, never DU", function()
        -- Same rule as the sheet (ADR-36): the fast refresh is forced
        -- monochrome on device and drops gray, so a graphite stroke's own
        -- boxes go partial. Direct ink has no raster to remember gray
        -- content, so the decision is per stroke, by its style.
        local p = penPlugin()
        local function kindsAfter(mark)
            local kinds = {}
            for i = mark + 1, #Device.screen.refreshes do
                kinds[#kinds + 1] = Device.screen.refreshes[i][1]
            end
            return table.concat(kinds, ",")
        end

        local mark = #Device.screen.refreshes
        p:startStroke(100, 300, 1)
        p:addPoint(140, 300)
        p:endStroke()
        t:check(kindsAfter(mark):find("fast", 1, true) ~= nil,
            "pen ink refreshes fast")
        t:check(kindsAfter(mark):find("partial", 1, true) == nil,
            "and needs no grayscale pass")

        mark = #Device.screen.refreshes
        p:startStroke(100, 350, 65)
        p:addPoint(140, 350)
        p:endStroke()
        t:check(kindsAfter(mark):find("partial", 1, true) ~= nil,
            "a graphite segment refreshes through a grayscale pass")
        t:check(kindsAfter(mark):find("fast", 1, true) == nil,
            "and never through DU, which would drop it")

        mark = #Device.screen.refreshes
        p:startStroke(200, 300, 65)
        p:endStroke()
        t:check(kindsAfter(mark):find("partial", 1, true) ~= nil,
            "a graphite dot painted at the lift rides the same pass")
    end)

    t:case("a palm still on the glass keeps the lease occupied", function()
        local p, input = penPlugin()
        local replay = Replay.new{ input = input, capture = Capture }

        replay:set(0, { id = 50, x = 300, y = 900, tool = 0 })
        replay:syn()
        replay:set(0, { tool = 2 })
        replay:syn()
        -- The palm ledger is the only thing that still knows about this hand:
        -- the touch bookkeeping gave it back at promotion. Losing it here is
        -- what let a notebook take the capture over with a hand down, and what
        -- left navigation disabled after it lifted.
        t:eq(p.n_contacts, 0, "it is no longer ordinary touch")
        t:eq(p.palm_gate:hasActiveContact(), true, "the ledger has it")
        t:eq(p:hasActivePhysicalContact(), true, "so the lease reports a contact")

        replay:set(0, { id = -1 })
        replay:syn()
        t:eq(p:hasActivePhysicalContact(), false, "and only its lift releases it")
    end)

    t:case("a promoted palm is withheld from gesture detection entirely", function()
        local p, input = penPlugin()
        local gd = input.gesture_detector
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.palm_promote_and_lift())
        t:eq(gd:getContact(0), nil, "no contact was ever opened for it")
    end)

    t:case("a palm promoted after its touch was already forwarded is retired", function()
        local p, input = penPlugin()
        local gd = input.gesture_detector
        local replay = Replay.new{ input = input, capture = Capture }

        -- The finger frame goes to the detector as usual; suppression is per
        -- gesture at the widget layer. Then the tool changes under it.
        replay:set(0, { id = 50, x = 300, y = 900, tool = 0 })
        replay:syn()
        t:check(gd:getContact(0) ~= nil, "the detector opened a contact")
        gd.dropped = {}

        replay:set(0, { tool = 2 })
        replay:syn()
        t:eq(gd.dropped[1], 0, "promotion retires it, hold timer included")
        t:eq(p.n_contacts, 0, "and it stops being counted as touch")
    end)

    t:case("the recorded false line is not drawn on the page", function()
        local p, input = penPlugin()
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.palm_then_stale_pen_pair())

        local list = p.store:get(1) or {}
        for i = 1, #list do
            local stroke = list[i]
            if stroke.n > 1 then
                for j = 1, stroke.n do
                    t:check(not (stroke[j * 2 - 1] == 456 and stroke[j * 2] == 1903),
                        "no multi-point stroke starts at the previous lift")
                end
            end
        end
    end)

    t:case("the recorded axis splits produce no axis-aligned segment", function()
        for _, name in ipairs({ "split_x_then_y", "split_y_then_x" }) do
            local p, input = penPlugin()
            local replay = Replay.new{ input = input, capture = Capture }
            play(replay, Replays[name]())

            local list = p.store:get(1) or {}
            for i = 1, #list do
                local stroke = list[i]
                for j = 2, stroke.n do
                    local dx = stroke[j * 2 - 1] - stroke[j * 2 - 3]
                    local dy = stroke[j * 2] - stroke[j * 2 - 2]
                    t:check(not ((dx == 0) ~= (dy == 0)),
                        name .. " drew no perfectly axis-aligned segment")
                end
            end
        end
    end)

    t:case("a lease starts from where the pen slot already is", function()
        -- Input's slot table outlives every capture, so the pen has a position
        -- before drawing is switched on. Reading it once is what spares the
        -- session's first contact from proving where it is the slow way.
        local p, input = penPlugin()
        p:setDrawing(false)
        input.ev_slots[Replays.PEN_SLOT] =
            { slot = Replays.PEN_SLOT, id = -1, x = 900, y = 950, tool = 1 }
        local seed_x, seed_y = Capture:penSlotPosition(input)
        t:eq(seed_x, 900, "capture can read the slot's position")
        t:eq(seed_y, 950, "on both axes")

        p:setDrawing(true)
        local bx, by = p.stylus_geometry:baseline()
        t:eq(bx, 900, "and the lease begins with it as the boundary")
        t:eq(by, 950, "on both axes")

        local replay = Replay.new{ input = input, capture = Capture }
        replay:set(Replays.PEN_SLOT, { id = 1, x = 300, y = 400, tool = 1 })
        replay:syn()
        t:check(p.stroke ~= nil, "so the first sample of the session draws")
        t:eq(p.stroke and p.stroke[1], 300, "at the real x")

        -- And a slot table that says nothing leaves the boundary unseeded,
        -- which is the old, slower, still-correct behaviour.
        t:eq(Capture:penSlotPosition({ pen_slot = 4, ev_slots = { [4] = {} } }), nil,
            "an empty slot seeds nothing")
        t:eq(Capture:penSlotPosition({ pen_slot = 4 }), nil, "nor does a missing table")
        t:eq(Capture:penSlotPosition({ ev_slots = {} }), nil, "nor a missing pen slot")
    end)

    t:case("a contact that never drew still moves the trusted boundary", function()
        -- The sequence stops consulting the geometry once a contact is
        -- suspended, but the pen keeps travelling and the slot keeps tracking
        -- it. If the boundary froze at the last judged sample, the next
        -- contact-down would look fresh on both axes against a position the
        -- pen left long ago -- and paint a line all the way to it.
        local p, input = penPlugin()
        local bar = p.bar.dimen
        local replay = Replay.new{ input = input, capture = Capture }

        replay:set(4, { id = 1, x = 100, y = 100, tool = 1 })
        replay:syn()
        replay:set(4, { x = 200, y = 220 })
        replay:syn()
        replay:set(4, { x = bar.x + 5, y = bar.y + 5 })
        replay:syn()
        replay:set(4, { x = bar.x + 30, y = bar.y + 60 })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()

        -- The next contact-down carries no ABS update at all, so it presents
        -- exactly where the pen left.
        replay:set(4, { id = 2, tool = 1 })
        replay:syn()
        t:eq(p.stroke, nil, "the sticky pair started nothing")
        replay:set(4, { x = 300, y = 700 })
        replay:syn()

        local stroke = p.stroke
        t:check(stroke ~= nil, "the first real sample starts the stroke")
        t:eq(stroke and stroke[1], 300, "at the real x")
        t:eq(stroke and stroke[2], 700, "and the real y")
        t:eq(stroke and stroke.n, 1, "with no segment from the previous contact")
    end)

    t:case("a half-fresh pair cannot hand a page stroke to the reader", function()
        -- A fresh axis paired with the previous contact's other one is a
        -- position that never existed. Deciding from it sends the stroke to
        -- whoever owns the region the stale axis points at -- here the
        -- toolbar, which would turn the pen's stroke into a swipe.
        local p, input = penPlugin()
        local bar = p.bar.dimen
        local replay = Replay.new{ input = input, capture = Capture }

        replay:set(4, { id = 1, x = bar.x + 5, y = bar.y + 5, tool = 1 })
        replay:syn()
        replay:set(4, { x = bar.x + 5, y = bar.y + 5 })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()

        replay:set(4, { id = 2, tool = 1 })
        replay:syn()
        replay:set(4, { y = 300 })
        replay:syn()
        t:eq(p.stylus_sequence.state, "geometry_pending",
            "the half-fresh pair handed nothing over")
        t:eq(p.stroke, nil, "and drew nothing")

        replay:set(4, { x = 400 })
        replay:syn()
        t:check(p.stroke ~= nil, "the coherent pair draws on the page")
        t:eq(p.stroke and p.stroke[1], 400, "at the real x")
        t:eq(p.stroke and p.stroke[2], 300, "and the real y")
    end)

    t:case("a palm whose tool reverts is not handed back to the detector", function()
        -- The route drops the contact when the hand is promoted. Returning the
        -- whole frame afterwards gave it straight back one frame later, hold
        -- timer included, and a dialog latching passthrough would then let the
        -- palm's tap through to the dialog.
        local p, input = penPlugin()
        local gd = input.gesture_detector
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.palm_reverts_before_lift())
        t:eq(gd:getContact(0), nil, "no detector contact survives the hand")
        t:eq(p.n_contacts, 0, "and it is not counted as touch")
        t:eq(p:hasActivePhysicalContact(), false, "the glass is clear")
    end)

    t:case("the physical eraser still reaches the page", function()
        local p, input = penPlugin()
        -- The recorded path crosses where the six-button bar sits on the small
        -- fake screen; on a Scribe it is nowhere near the bar. Keep the
        -- toolbar out of the recorded coordinates, never the reverse.
        ctx.env.UIManager:close(p.bar)
        p.bar = ctx.newRealBar(p, "left")
        ctx.env.UIManager:show(p.bar)
        -- The contact-down pair is a baseline, so the erase happens at the
        -- second, coherent sample.
        p.store:add(1, { n = 1, w = 4, 520, 530 })
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.physical_eraser_on_pen_slot())
        t:eq(p.store:get(1), nil, "tool 2 on the pen slot erased")
    end)

    t:case("two promoted palms leak nothing", function()
        local p, input = penPlugin()
        local replay = Replay.new{ input = input, capture = Capture }

        play(replay, Replays.palm_promotes_two_touch_slots())
        t:eq(p.n_contacts, 0, "no touch contact survived")
        t:eq(next(p.contacts), nil, "no bookkeeping survived")
        t:eq(p.palm_gate:hasActiveContact(), false, "no palm survived")
        t:eq(p:hasActivePhysicalContact(), false, "and the lease is free")
    end)

    -- =================================================================
    t:describe("standalone notebooks / Add page after a palm")

    --- The whole stack: FileManager host, library, editor, the real capture
    --- KOReader installed, and the recorded slot numbers going through it.
    local function openNotebookForPen()
        ctx.reset{ wacom_protocol = true }
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        env.UIManager:flush()
        plugin.notebook_ui.library.layout[1][1].callback()
        env.UIManager:flush()
        return plugin, controller, plugin.notebook_ui.editor
    end

    t:case("Add page works once the hand is off the glass", function()
        local plugin, controller, editor = openNotebookForPen()
        local input = Device.input
        t:check(input.stylus_callback ~= nil, "the pen route is installed")
        t:eq(controller:uiSnapshot().page_count, 1, "one page to begin with")

        local replay = Replay.new{ input = input, capture = Capture }
        play(replay, Replays.palm_promote_and_lift())

        local snapshot = controller:uiSnapshot()
        t:eq(snapshot.can_navigate, true, "navigation is available again")
        t:eq(snapshot.navigation_block_reason, nil, "with nothing blocking it")
        t:eq(editor:_runDomain("add"), true, "Add page runs")
        t:eq(controller:uiSnapshot().page_count, 2, "and appends exactly one page")
        plugin:teardown()
    end)

    t:case("Add page during a real contact explains itself and changes nothing", function()
        local plugin, controller, editor = openNotebookForPen()
        local input = Device.input
        local replay = Replay.new{ input = input, capture = Capture }

        -- The hand lands and stays down: promotion without a lift.
        replay:set(0, { id = 50, x = 300, y = 900, tool = 0 })
        replay:syn()
        replay:set(0, { tool = 2 })
        replay:syn()

        local snapshot = controller:uiSnapshot()
        t:eq(snapshot.can_navigate, false, "navigation is refused")
        t:eq(snapshot.navigation_block_reason, "contact_active", "and says why")

        env.shown_messages = {}
        local before = controller:uiSnapshot().page_count
        local ok, reason = editor:_runDomain("add")
        t:eq(ok, nil, "nothing ran")
        t:eq(reason, "contact_active", "for a reason the caller can act on")
        t:eq(controller:uiSnapshot().page_count, before, "storage is untouched")
        env.UIManager:flush()
        t:eq(env.shown_messages[1], "Lift the pen and your hand, then try again.",
            "and the reader is told, in English, exactly what to do")

        -- The same hand lifting is what makes the action available again.
        replay:set(0, { id = -1 })
        replay:syn()
        t:eq(controller:uiSnapshot().can_navigate, true, "the lift releases it")
        t:eq(editor:_runDomain("add"), true, "and Add page works")
        t:eq(controller:uiSnapshot().page_count, before + 1, "appending one page")
        plugin:teardown()
    end)

    t:case("the rail catches up on its own when the last contact ends", function()
        local plugin, controller, editor = openNotebookForPen()
        local input = Device.input
        local replay = Replay.new{ input = input, capture = Capture }

        replay:set(0, { id = 50, x = 300, y = 900, tool = 0 })
        replay:syn()
        replay:set(0, { tool = 2 })
        replay:syn()
        editor:_refreshActionAvailability()
        t:eq(editor:_actionAvailability("add"), false, "Add is unavailable, correctly")

        replay:set(0, { id = -1 })
        replay:syn()
        -- No further interaction: the contact-end callback is the only event
        -- there is, and it has to bring the rail back by itself.
        t:eq(editor.snapshot.can_navigate, true, "the snapshot behind the rail caught up")
        t:eq(editor:_actionAvailability("add"), true, "and Add is live again")
        plugin:teardown()
    end)

    t:case("rotation clears palm and pen state without inventing a lift", function()
        local p, input = penPlugin()
        local replay = Replay.new{ input = input, capture = Capture }
        replay:set(0, { id = 30, x = 300, y = 900, tool = 2 })
        replay:syn()
        t:eq(p.palm_gate:hasActiveContact(), true, "a hand is down")

        p:setDrawing(false)
        t:eq(p.stylus_sequence, nil, "the pen machine went with the lease")
        t:eq(p.palm_gate, nil, "and so did the ledger")
        t:eq(p:hasActivePhysicalContact(), false, "nothing is left claiming the glass")
    end)
end
