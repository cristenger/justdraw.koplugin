return function(ctx)
    local t = ctx.t
    local Sequence = require("ink_stylus_sequence")
    local Limits = require("ink_limits")
    local Trace = require("ink_stylus_trace")
    local Replay = require("input_replay")

    local function acceptGeometry(opts)
        opts = opts or {}
        local geometry = { resets = {} }
        function geometry:observe(x, y, _, phase)
            if opts.observe then return opts.observe(self, x, y, phase) end
            return "accept", x, y, "accepted"
        end
        function geometry:onLift(x, y)
            if opts.on_lift then return opts.on_lift(self, x, y) end
            return "discard", "pending_discard"
        end
        function geometry:reset(clear_history)
            self.resets[#self.resets + 1] = clear_history
        end
        return geometry
    end

    local function pendingGeometry(dot)
        return acceptGeometry{
            observe = function() return "pending", "geometry_pending" end,
            on_lift = function(_, x, y)
                if dot then return "dot", x, y end
                return "discard", "pending_discard"
            end,
        }
    end

    local function harness(opts)
        opts = opts or {}
        local log = {
            starts = 0, points = {}, finishes = 0, aborts = 0,
            ends = 0, errors = {}, order = {},
        }
        local function order(value)
            log.order[#log.order + 1] = value
        end
        local seq = Sequence.new{
            wacom_protocol = opts.wacom_protocol,
            pen_slot = opts.pen_slot or 4,
            tool_finger = opts.tool_finger or 0,
            geometry = opts.geometry or acceptGeometry(),
            max_open_points = opts.max_open_points,
            max_contact_samples = opts.max_contact_samples,
            drop_contact = opts.drop_contact,
            to_screen = opts.to_screen,
            trace = opts.trace,
            classify = opts.classify or function(_, _, tool)
                return "draw", tool == 2 and "erase" or "ink"
            end,
            on_contact_start = opts.on_contact_start or function(reason)
                log.starts = log.starts + 1
                order("start:" .. reason)
                return true
            end,
            on_point = opts.on_point or function(x, y, tool, first)
                log.points[#log.points + 1] = {
                    x = x, y = y, tool = tool, first = first,
                }
                order(first and "point:first" or "point:next")
                return "continue"
            end,
            on_finish = opts.on_finish or function(reason)
                log.finishes = log.finishes + 1
                order("finish:" .. reason)
                return true
            end,
            on_abort = opts.on_abort or function(reason)
                log.aborts = log.aborts + 1
                order("abort:" .. reason)
                return true
            end,
            on_contact_end = opts.on_contact_end or function(reason)
                log.ends = log.ends + 1
                order("end:" .. reason)
                return true
            end,
            on_domain_error = opts.on_domain_error or function(reason, phase)
                log.errors[#log.errors + 1] = { reason = reason, phase = phase }
            end,
        }
        return seq, log
    end

    local function pen(id, x, y, tool, slot, timev)
        return {
            slot = slot or 4, id = id, x = x, y = y,
            tool = tool == nil and 1 or tool, timev = timev,
        }
    end

    t:describe("ink_limits / one source of defaults")

    t:case("safety budgets are stable internal constants", function()
        t:eq(Limits.MAX_OPEN_POINTS, 8192, "open point budget")
        t:eq(Limits.MAX_CONTACT_SAMPLES, 32768, "contact sample budget")
    end)

    t:describe("input_replay / persistent per-SYN slots")

    t:case("fields persist, touched slots deduplicate, and order is stable", function()
        local seen, frames = {}, 0
        local sequence = {}
        function sequence:feed(slot)
            seen[#seen + 1] = {
                ref = slot, slot = slot.slot, id = slot.id,
                x = slot.x, y = slot.y,
            }
            return slot.slot == 4
        end
        function sequence:afterFrame() frames = frames + 1 end

        local replay = Replay.new{ mode = "unit", sequence = sequence }
        local ref = replay:set(4, { id = 7 })
        replay:set(4, { x = 20 })
        replay:set(2, { id = 9, y = 30 })
        local deliveries, frame = replay:syn()

        t:eq(#frame, 2, "one entry per touched slot")
        t:eq(frame[1].slot, 4, "first-touch order retained")
        t:eq(frame[2].slot, 2, "second slot follows")
        t:eq(seen[1].id, 7, "id survived partial update")
        t:eq(seen[1].x, 20, "x update visible")
        t:eq(seen[1].ref, ref, "same durable table delivered")
        t:eq(deliveries[1], true, "unit delivery captured")
        t:eq(frames, 1, "afterFrame exactly once")

        replay:set(4, { y = 40 })
        replay:syn()
        t:eq(seen[3].id, 7, "id persists into later SYN")
        t:eq(seen[3].x, 20, "untouched x persists")
        replay:set(4, { id = Replay.NIL })
        replay:syn()
        t:eq(seen[4].id, nil, "explicit nil clears a durable field")
    end)

    t:describe("ink_stylus_sequence / conservative geometry gate")

    t:case("default policy cannot persist the adversarial hybrid L", function()
        local seq, log = harness{ geometry = nil }
        -- Omit geometry explicitly by constructing without the harness default.
        seq = Sequence.new{
            tool_finger = 0,
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return true end,
            on_point = function(x, y)
                log.points[#log.points + 1] = { x = x, y = y }
                return "continue"
            end,
            on_finish = function() return true end,
            on_abort = function() return true end,
            on_contact_end = function() log.ends = log.ends + 1; return true end,
        }
        seq:feed(pen(4, 100, 100))
        seq:feed(pen(4, 100, 100))
        seq:feed(pen(4, 500, 100))
        seq:feed(pen(4, 500, 600))
        seq:feed(pen(-1, 500, 600, 0))
        t:eq(#log.points, 0, "no unproven coordinate reached host")
        t:eq(log.ends, 1, "physical contact still closed")
        t:eq(seq.state, "idle", "sequence returned to idle")
    end)

    t:case("persistent Y-then-X axis updates also remain unproven", function()
        local points = 0
        local seq = Sequence.new{
            tool_finger = 0,
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return true end,
            on_point = function() points = points + 1; return "continue" end,
            on_finish = function() return true end,
            on_abort = function() return true end,
            on_contact_end = function() return true end,
        }
        local replay = Replay.new{ mode = "unit", sequence = seq }
        replay:set(4, { id = 4, x = 100, y = 100, tool = 1 })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()
        replay:set(4, { id = 5 })
        replay:syn()
        replay:set(4, { y = 600 })
        replay:syn()
        replay:set(4, { x = 500 })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()
        t:eq(points, 0, "reverse split axes cannot synthesize geometry")
        t:eq(seq.state, "idle", "contact still closes normally")
    end)

    t:case("an explicit trace-backed policy can accept an atomic pair", function()
        local seq, log = harness()
        t:eq(seq:feed(pen(1, 10, 20)), true, "draw dominates")
        seq:feed(pen(-1, 10, 20, 0))
        t:eq(#log.points, 1, "accepted point emitted")
        t:eq(log.points[1].x, 10, "x preserved")
        t:eq(log.points[1].y, 20, "y preserved")
        t:eq(log.finishes, 1, "dot finished once")
    end)

    t:case("pending dot recovery is policy-owned and pass dots are discarded", function()
        local seq, log = harness{ geometry = pendingGeometry(true) }
        seq:feed(pen(1, 30, 40))
        seq:feed(pen(-1, 30, 40, 0))
        t:eq(#log.points, 1, "policy-certified dot recovered")
        t:eq(log.finishes, 1, "dot finished")
        t:eq(log.ends, 1, "contact ended")

        local passed = harness{
            geometry = pendingGeometry(true),
            classify = function() return "pass" end,
        }
        local pass_seq = passed
        t:eq(pass_seq:feed(pen(2, 50, 60)), true, "pending down dominated")
        t:eq(pass_seq:feed(pen(-1, 50, 60, 0)), true,
            "lift not forwarded without a matching down")
        t:eq(pass_seq.state, "idle", "pending pass discarded")
    end)

    t:case("two policy-certified dots at one pixel remain distinct", function()
        local seq, log = harness{ geometry = pendingGeometry(true) }
        for id = 1, 2 do
            seq:feed(pen(id, 44, 55))
            seq:feed(pen(-1, 44, 55, 0))
        end
        t:eq(#log.points, 2, "same-pixel contacts are not deduplicated")
        t:eq(log.finishes, 2, "each dot owns one effect")
    end)

    t:case("nil and non-finite coordinates never reach geometry or host", function()
        local observations = 0
        local geometry = acceptGeometry{
            observe = function(_, x, y)
                observations = observations + 1
                return "accept", x, y
            end,
        }
        local seq, log = harness{ geometry = geometry }
        seq:feed(pen(1, nil, nil))
        seq:feed(pen(1, math.huge, 10))
        seq:feed(pen(1, 10, 0 / 0))
        t:eq(observations, 0, "invalid pairs rejected before policy")
        t:eq(#log.points, 0, "invalid pairs rejected before host")
        seq:feed(pen(1, 20, 30))
        t:eq(#log.points, 1, "later finite pair remains usable")

        local bad_screen, bad_log = harness{
            to_screen = function() return math.huge, 10 end,
        }
        bad_screen:feed(pen(1, 1, 2))
        t:eq(#bad_log.points, 0, "non-finite transform rejected")
        t:eq(bad_screen.state, "suspended", "contact fails closed")
    end)

    t:describe("ink_stylus_sequence / ownership and physical boundaries")

    t:case("hover is inert and foreign slots cannot end the owner", function()
        local seq, log = harness()
        t:eq(seq:feed(pen(nil, 1, 2)), true, "idle hover consumed")
        t:eq(log.starts, 0, "hover starts nothing")
        seq:feed(pen(7, 10, 10))
        local samples = seq.sample_count
        t:eq(seq:feed(pen(nil, 11, 11)), true, "owner hover stays dominated")
        t:eq(seq.sample_count, samples, "hover is outside sample budget")
        t:eq(seq:feed(pen(-1, 90, 90, 0, 8)), false,
            "foreign lift forwarded")
        t:eq(log.ends, 0, "foreign lift did not close owner")
        t:eq(seq:feed(pen(8, 90, 90, 1, 8)), false,
            "foreign positive forwarded coherently")
        seq:feed(pen(-1, 10, 10, 0))
        t:eq(log.ends, 1, "owner lift closes once")
    end)

    t:case("positive tracking-id replacement splits before the new begin", function()
        local seq, log = harness()
        seq:feed(pen(1, 10, 10))
        log.order = {}
        seq:feed(pen(2, 50, 50))
        t:eq(log.order[1], "finish:replacement_id", "old effect finished first")
        t:eq(log.order[2], "end:replacement_id", "old physical contact ended")
        t:eq(log.order[3], "start:replacement_id", "new contact started next")
        t:eq(log.order[4], "point:first", "new geometry emitted last")
        seq:feed(pen(-1, 50, 50, 0))
        t:eq(log.finishes, 2, "two effects, not one joined stroke")
        t:eq(log.ends, 2, "two physical generations")
    end)

    t:case("replacement discards pending and never resurrects suspended work", function()
        local pending, pending_log = harness{
            geometry = pendingGeometry(false),
        }
        pending:feed(pen(1, 10, 10))
        pending:feed(pen(2, 20, 20))
        t:eq(pending_log.finishes, 0, "pending generation has no effect to finish")
        t:eq(pending_log.ends, 1, "pending physical generation ended")
        t:eq(pending_log.starts, 2, "replacement began separately")
        t:eq(pending.state, "geometry_pending", "new generation stays pending")

        local suspended, suspended_log = harness{
            on_point = function() return "abort_suspend" end,
        }
        suspended:feed(pen(1, 10, 10))
        t:eq(suspended_log.aborts, 1, "old effect aborted once")
        suspended:feed(pen(2, 20, 20))
        t:eq(suspended_log.ends, 1, "suspended generation ended")
        t:eq(suspended_log.starts, 2, "replacement starts new host generation")
        t:eq(suspended_log.aborts, 2, "new effect follows its own policy")
    end)

    t:case("PEN to ERASER is a dominated modality boundary", function()
        local seq, log = harness()
        seq:feed(pen(4, 10, 10, 1))
        log.order = {}
        seq:feed(pen(4, 20, 20, 2))
        t:eq(log.order[1], "finish:tool_change", "pen effect finished")
        t:eq(log.order[2], "end:tool_change", "pen contact ended")
        t:eq(log.order[3], "start:tool_change", "eraser contact started")
        t:eq(log.points[#log.points].tool, 2, "new effect owns eraser tool")
        t:eq(seq.effect, "erase", "modalities never share one effect")
    end)

    t:case("Wacom FINGER closes only the owning pen slot and keeps tool", function()
        local seq, log = harness{ wacom_protocol = true, pen_slot = 4 }
        seq:feed(pen(4, 10, 10, 2))
        t:eq(seq:feed(pen(4, 10, 10, 0)), true,
            "owner proximity-out dominated")
        t:eq(seq.state, "proximity_wait", "waits idempotently for late lift")
        t:eq(seq.current_tool, 2, "eraser tool preserved")
        t:eq(log.finishes, 1, "effect closed once")
        t:eq(log.ends, 1, "physical end published once")
        t:eq(seq:isLifecycleBlocked(), false, "proximity wait does not gate UI")
        seq:feed(pen(-1, 10, 10, 0))
        t:eq(log.ends, 1, "late lift is idempotent")
        seq:feed(pen(4, 20, 20, 1))
        t:eq(log.starts, 2, "same fixed Wacom id can begin again")
    end)

    t:case("TOOL_FINGER is not a boundary off Wacom or another slot", function()
        local seq, log = harness{ wacom_protocol = false, pen_slot = 4 }
        seq:feed(pen(1, 10, 10, 1))
        seq:feed(pen(1, 20, 20, 0))
        t:eq(seq.state, "active_draw", "non-Wacom finger value is an update")
        t:eq(log.points[#log.points].tool, 1, "last stylus tool preserved")

        local wacom, wlog = harness{ wacom_protocol = true, pen_slot = 9 }
        wacom:feed(pen(1, 10, 10, 1, 4))
        wacom:feed(pen(1, 20, 20, 0, 4))
        t:eq(wacom.state, "active_draw", "non-pen slot does not use fallback")
        t:eq(wlog.ends, 0, "no false physical end")
    end)

    t:case("runtime constants are instance-local rather than cached", function()
        local first = harness{ wacom_protocol = true, pen_slot = 7, tool_finger = 9 }
        local second = harness{ wacom_protocol = true, pen_slot = 7, tool_finger = 0 }
        first:feed(pen(1, 10, 10, 1, 7))
        second:feed(pen(1, 10, 10, 1, 7))
        first:feed(pen(1, 10, 10, 9, 7))
        second:feed(pen(1, 10, 10, 9, 7))
        t:eq(first.state, "proximity_wait", "first runtime uses finger=9")
        t:eq(second.state, "active_draw", "second runtime uses finger=0")
    end)

    t:describe("ink_stylus_sequence / forwarded contacts")

    t:case("pass delivery remains false through tool changes and lift", function()
        local seq, log = harness{
            classify = function() return "pass" end,
            wacom_protocol = false,
        }
        t:eq(seq:feed(pen(1, 10, 10, 1)), false, "down forwarded")
        t:eq(seq:hasForwardedContact(), true, "forwarded contact visible")
        t:eq(seq:forwardedSlot(), 4, "forwarded slot exposed")
        t:eq(seq:feed(pen(1, 20, 20, 2)), false,
            "tool change never reclaims pass")
        t:eq(log.starts, 1, "no new host generation")
        t:eq(seq:feed(pen(-1, 20, 20, 0)), false, "lift forwarded")
        t:eq(log.ends, 1, "physical end still published")
        t:eq(seq.state, "idle", "pass reset")
    end)

    t:case("pass replacement reclaims only after confirmed drop", function()
        local drops = 0
        local seq, log = harness{
            classify = function() return "pass" end,
            drop_contact = function(slot)
                drops = drops + 1
                return slot == 4
            end,
        }
        seq:feed(pen(1, 10, 10))
        log.order = {}
        t:eq(seq:feed(pen(2, 20, 20)), false,
            "new pass remains forwarded after successful reclaim/reclassify")
        t:eq(drops, 1, "drop attempted once")
        t:eq(log.order[1], "end:replacement_id", "old pass ended")
        t:eq(log.order[2], "start:replacement_id", "new generation began")
        t:eq(log.starts, 2, "two physical contacts observed")
    end)

    t:case("failed forwarded end cannot start the replacement host", function()
        local starts, points, ends, errors = 0, 0, 0, {}
        local seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function(x)
                if x == 10 then return "pass" end
                return "draw", "ink"
            end,
            drop_contact = function() return true end,
            on_contact_start = function()
                starts = starts + 1
                return true
            end,
            on_point = function()
                points = points + 1
                return "continue"
            end,
            on_finish = function() return true end,
            on_abort = function() return true end,
            on_contact_end = function()
                ends = ends + 1
                return nil, "end_failed"
            end,
            on_domain_error = function(reason, phase)
                errors[#errors + 1] = reason .. ":" .. phase
            end,
        }

        t:eq(seq:feed(pen(1, 10, 10)), false, "old contact was forwarded")
        t:eq(seq:feed(pen(2, 20, 20)), true,
            "replacement stays dominated after the confirmed drop")
        t:eq(seq.state, "suspended", "replacement is held inert")
        t:eq(starts, 1, "failed old end prevents a new host start")
        t:eq(points, 0, "failed old end prevents replacement geometry")
        t:eq(ends, 1, "old physical end attempted once")
        t:eq(#errors, 0, "notifier remains outside routeStylusEvents")
        seq:afterFrame()
        t:eq(errors[1], "end_failed:on_contact_end", "original failure delivered")
        seq:feed(pen(-1, 20, 20, 0))
        t:eq(ends, 1, "unstarted replacement has no synthetic end callback")
        t:eq(seq.state, "idle", "replacement lift rearms the sequence")
    end)

    t:case("failed or raising drop stays forwarded and reports afterFrame", function()
        for _, drop in ipairs({
            function() return false end,
            function() error("drop exploded", 0) end,
        }) do
            local seq, log = harness{
                classify = function() return "pass" end,
                drop_contact = drop,
            }
            seq:feed(pen(1, 10, 10))
            t:eq(seq:feed(pen(2, 20, 20)), false, "replacement not reclaimed")
            t:eq(seq.state, "forwarded_wait_lift", "waits for physical lift")
            t:eq(#log.errors, 0, "no in-callback notifier")
            seq:afterFrame()
            t:eq(#log.errors, 1, "error notified from safe frame boundary")
            t:eq(log.errors[1].phase, "drop_contact", "drop phase retained")
            t:eq(seq:feed(pen(-1, 20, 20, 0)), false,
                "final lift still reaches detector")
            t:eq(log.ends, 1, "end callback runs once at lift")
        end
    end)

    t:case("Wacom pass proximity preserves Contact until lift or safe reclaim", function()
        local allow_drop = false
        local seq, log = harness{
            classify = function() return "pass" end,
            wacom_protocol = true,
            pen_slot = 4,
            drop_contact = function() return allow_drop end,
        }
        seq:feed(pen(4, 10, 10, 1))
        t:eq(seq:feed(pen(4, 10, 10, 0)), false, "proximity forwarded")
        t:eq(seq.state, "forwarded_wait_lift", "Contact remains owned by GD")
        t:eq(seq:feed(pen(4, 20, 20, 1)), false,
            "new pen not reclaimed when drop fails")
        seq:afterFrame()
        allow_drop = true
        -- A later replacement can be reclaimed only after a successful drop.
        t:eq(seq:feed(pen(4, 30, 30, 1)), false,
            "new pass reclassified after successful drop")
        t:eq(log.ends, 1, "old forwarded contact ended once")
        t:eq(log.starts, 2, "new physical generation started")
    end)

    t:case("external abort of pass obeys drop result", function()
        local allow = false
        local seq, log = harness{
            classify = function() return "pass" end,
            drop_contact = function() return allow end,
        }
        seq:feed(pen(1, 10, 10))
        local ok, reason = seq:abort("external_abort", true)
        t:eq(ok, false, "failed drop prevents reset")
        t:eq(reason, "contact_forwarded", "explicit failure reason")
        t:eq(seq.state, "forwarded_wait_lift", "still waiting for lift")
        allow = true
        t:eq(seq:abort("external_abort", true), true, "successful drop resets")
        t:eq(seq.state, "idle", "capture can now tear down")
        t:eq(log.ends, 1, "contact end emitted after confirmed drop")
    end)

    t:describe("ink_stylus_sequence / actions and bounded work")

    t:case("finish and abort actions suspend without ending physical contact", function()
        for _, action in ipairs({ "finish_suspend", "abort_suspend" }) do
            local seq, log = harness{
                on_point = function()
                    log = log
                    return action
                end,
            }
            seq:feed(pen(1, 10, 10))
            t:eq(seq.state, "suspended", action .. " enters suspended")
            t:eq(seq:hasInkContact(), false, action .. " closes effect")
            t:eq(seq:hasOwnedPhysicalContact(), true,
                action .. " retains physical ownership")
            t:eq(seq:isLifecycleBlocked(), true, action .. " gates lifecycle")
            t:eq(log.ends, 0, action .. " does not publish a false lift")
            seq:feed(pen(1, 20, 20))
            t:eq(log.ends, 0, "later sample is O(1) suspended work")
            seq:feed(pen(-1, 20, 20, 0))
            t:eq(log.ends, 1, "real lift ends physical contact")
            if action == "finish_suspend" then
                t:eq(log.finishes, 1, "finish callback once")
            else
                t:eq(log.aborts, 1, "abort callback once")
            end
        end
    end)

    t:case("point budget aborts ink before point N+1 and never splits", function()
        local seq, log = harness{ max_open_points = 2 }
        seq:feed(pen(1, 1, 1))
        seq:feed(pen(1, 2, 2))
        seq:feed(pen(1, 3, 3))
        t:eq(#log.points, 2, "third point never emitted")
        t:eq(log.aborts, 1, "whole live ink repaired once")
        t:eq(log.finishes, 0, "no partial stroke persisted")
        t:eq(seq.state, "suspended", "contact suspended until boundary")
        seq:feed(pen(-1, 3, 3, 0))
        t:eq(log.ends, 1, "lift rearms next contact")
        seq:feed(pen(2, 4, 4))
        t:eq(#log.points, 3, "next physical contact works")
    end)

    t:case("sample cap counts duplicates and is effect-aware", function()
        local ink, ilog = harness{ max_contact_samples = 2 }
        ink:feed(pen(1, 1, 1))
        ink:feed(pen(1, 1, 1))
        ink:feed(pen(1, 1, 1))
        t:eq(#ilog.points, 2, "duplicate over cap not delivered")
        t:eq(ilog.aborts, 1, "ink repaired")
        t:eq(ink.sample_count, 2, "counter saturates")
        ink:feed(pen(1, 1, 1))
        t:eq(ilog.aborts, 1, "suspended callbacks remain O(1)")

        local erase, elog = harness{
            max_contact_samples = 2,
            classify = function() return "draw", "erase" end,
        }
        erase:feed(pen(1, 1, 1, 2))
        erase:feed(pen(1, 1, 1, 2))
        erase:feed(pen(1, 1, 1, 2))
        t:eq(elog.finishes, 1, "accepted erases close and remain")
        t:eq(elog.aborts, 0, "eraser does not claim rollback")

        local pending, plog = harness{
            max_contact_samples = 1,
            geometry = pendingGeometry(false),
        }
        pending:feed(pen(1, 1, 1))
        pending:feed(pen(1, 1, 1))
        t:eq(pending.state, "suspended", "pending candidates discarded")
        t:eq(#plog.points, 0, "pending cap has no host work")

        local block = harness{
            max_contact_samples = 1,
            classify = function() return "block" end,
        }
        block:feed(pen(1, 1, 1))
        block:feed(pen(1, 1, 1))
        t:eq(block.state, "suspended", "block also suspends at cap")

        local pass = harness{
            max_contact_samples = 1,
            classify = function() return "pass" end,
        }
        t:eq(pass:feed(pen(1, 1, 1)), false, "pass begins forwarded")
        t:eq(pass:feed(pen(1, 1, 1)), false, "budget never reclaims pass")
        t:eq(pass.state, "active_pass", "pass remains forwarded")
    end)

    t:case("logical suspend preserves geometry history until boundary", function()
        local geometry = acceptGeometry()
        local seq = harness{
            geometry = geometry,
            on_point = function() return "abort_suspend" end,
        }
        seq:feed(pen(1, 1, 1))
        t:eq(#geometry.resets, 0, "logical abort keeps current history")
        seq:feed(pen(-1, 1, 1, 0))
        t:eq(#geometry.resets, 1, "physical boundary resets candidates")
        t:eq(geometry.resets[1], false, "normal boundary preserves baseline")
        seq:reset(true)
        t:eq(geometry.resets[#geometry.resets], true,
            "explicit lifecycle reset clears baseline")
    end)

    t:describe("ink_stylus_sequence / expected and unexpected failures")

    t:case("contact-start failure dominates and notifies only after frame", function()
        local errors, ends = {}, 0
        local seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return nil, "start_failed" end,
            on_contact_end = function() ends = ends + 1; return true end,
            on_domain_error = function(reason, phase)
                errors[#errors + 1] = reason .. ":" .. phase
            end,
        }
        t:eq(seq:feed(pen(1, 1, 1)), true, "owner frame dominated")
        t:eq(seq.state, "suspended", "failed start cannot open effect")
        t:eq(#errors, 0, "notifier deferred")
        seq:afterFrame()
        t:eq(errors[1], "start_failed:on_contact_start", "exact phase delivered")
        seq:abort("external_abort", true)
        t:eq(ends, 1, "partial start cleaned exactly once")
    end)

    t:case("point failure suspends and defers domain error", function()
        local seq, log = harness{
            on_point = function() return nil, "write_failed" end,
        }
        t:eq(seq:feed(pen(1, 1, 1)), true, "failed owner point dominated")
        t:eq(seq.state, "suspended", "host repair remains suspended")
        t:eq(#log.errors, 0, "no callback-stack release")
        seq:afterFrame()
        t:eq(log.errors[1].reason, "write_failed", "reason retained")
        t:eq(log.errors[1].phase, "on_point", "phase retained")
    end)

    t:case("finish failure still marks physical end before afterFrame", function()
        local errors, finishes, ends = {}, 0, 0
        local seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return true end,
            on_point = function() return "continue" end,
            on_finish = function() finishes = finishes + 1; return nil, "commit_failed" end,
            on_abort = function() return true end,
            on_contact_end = function() ends = ends + 1; return true end,
            on_domain_error = function(reason, phase)
                errors[#errors + 1] = reason .. ":" .. phase
            end,
        }
        seq:feed(pen(1, 1, 1))
        t:eq(seq:feed(pen(-1, 1, 1, 0)), true, "lift remains dominated")
        t:eq(seq.state, "idle", "physical state reset before notifier")
        t:eq(finishes, 1, "finish attempted once")
        t:eq(ends, 1, "end executed despite finish failure")
        seq:afterFrame()
        t:eq(errors[1], "commit_failed:on_finish", "safe-tick error")
    end)

    t:case("expected abort failure is deferred without releasing the frame", function()
        local errors = {}
        local seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return true end,
            on_point = function() return "abort_suspend" end,
            on_abort = function() return nil, "repair_failed" end,
            on_contact_end = function() return true end,
            on_domain_error = function(reason, phase)
                errors[#errors + 1] = reason .. ":" .. phase
            end,
        }
        t:eq(seq:feed(pen(1, 1, 1)), true, "owner frame remains dominated")
        t:eq(seq.state, "suspended", "effect cannot resume")
        t:eq(#errors, 0, "release callback is not in routeStylusEvents")
        seq:afterFrame()
        t:eq(errors[1], "repair_failed:on_abort", "abort phase retained")
    end)

    t:case("external abort and reset report lifecycle failures immediately", function()
        local abort_errors = {}
        local abort_seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "draw", "ink" end,
            on_contact_start = function() return true end,
            on_point = function() return "continue" end,
            on_finish = function() return true end,
            on_abort = function() return nil, "repair_failed" end,
            on_contact_end = function() return true end,
            on_domain_error = function(reason, phase)
                abort_errors[#abort_errors + 1] = reason .. ":" .. phase
            end,
        }
        abort_seq:feed(pen(1, 1, 1))
        local ok, reason, phase = abort_seq:abort("external_abort", true)
        t:eq(ok, false, "external abort reports callback failure")
        t:eq(reason, "repair_failed", "external abort preserves reason")
        t:eq(phase, "on_abort", "external abort preserves phase")
        t:eq(abort_errors[1], "repair_failed:on_abort",
            "external abort notifies without another frame")
        t:eq(abort_seq.pending_domain_reason, nil, "abort leaves no stranded error")
        t:eq(abort_seq.state, "idle", "abort still repairs physical state")

        local reset_errors = {}
        local reset_seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "block" end,
            on_contact_start = function() return true end,
            on_contact_end = function()
                return nil, "end_failed"
            end,
            on_domain_error = function(end_reason, end_phase)
                reset_errors[#reset_errors + 1] = end_reason .. ":" .. end_phase
            end,
        }
        reset_seq:feed(pen(1, 1, 1))
        ok, reason, phase = reset_seq:reset(true)
        t:eq(ok, false, "external reset reports end failure")
        t:eq(reason, "end_failed", "external reset preserves reason")
        t:eq(phase, "on_contact_end", "external reset preserves phase")
        t:eq(reset_errors[1], "end_failed:on_contact_end",
            "external reset notifies without another frame")
        t:eq(reset_seq.pending_domain_reason, nil, "reset leaves no stranded error")
        t:eq(reset_seq.state, "idle", "reset still clears physical state")
    end)

    t:case("contact-end failure is marked before callback and never repeats", function()
        local attempts, errors = 0, 0
        local seq = Sequence.new{
            tool_finger = 0,
            geometry = acceptGeometry(),
            classify = function() return "block" end,
            on_contact_start = function() return true end,
            on_contact_end = function()
                attempts = attempts + 1
                return nil, "end_failed"
            end,
            on_domain_error = function(_, phase)
                if phase == "on_contact_end" then errors = errors + 1 end
            end,
        }
        seq:feed(pen(1, 1, 1))
        seq:feed(pen(-1, 1, 1, 0))
        seq:feed(pen(-1, 1, 1, 0))
        t:eq(attempts, 1, "late lift cannot repeat failed callback")
        seq:afterFrame()
        t:eq(errors, 1, "one deferred error")
    end)

    t:case("unexpected programming exceptions escape to InkCapture guard", function()
        local seq = harness{
            on_point = function() error("programming bug", 0) end,
        }
        local ok, err = pcall(seq.feed, seq, pen(1, 1, 1))
        t:eq(ok, false, "sequence adds no blanket pcall")
        t:check(tostring(err):find("programming bug", 1, true) ~= nil,
            "original programming failure escapes")
    end)

    t:describe("ink_stylus_trace / bounded scalar evidence")

    t:case("events are post-decision, frame-numbered, and immutable", function()
        local lines, now = {}, 0
        local trace = Trace.new{
            source = "notebook", now = function() return now end,
            max_events = 10, duration_seconds = 60,
            emit = function(line) lines[#lines + 1] = line end,
        }
        local seq = harness{ trace = trace }
        local replay = Replay.new{ mode = "unit", sequence = seq }
        local first = replay:set(4, { id = 1, x = 10, y = 20, tool = 1 })
        replay:set(8, { id = 2, x = 30, y = 40, tool = 1 })
        replay:syn()
        first.x = 999
        replay:set(4, { x = 11 })
        replay:syn()

        t:check(lines[1]:find("event=1 frame=1", 1, true) ~= nil,
            "first event ordinal")
        t:check(lines[2]:find("event=2 frame=1", 1, true) ~= nil,
            "two slots share SYN ordinal")
        t:check(lines[3]:find("event=3 frame=2", 1, true) ~= nil,
            "next SYN increments frame")
        t:check(lines[1]:find("to=active_draw", 1, true) ~= nil,
            "decision logged after transition")
        t:check(lines[1]:find("x=10", 1, true) ~= nil,
            "copied scalar remains original")
        t:check(lines[1]:find("x=999", 1, true) == nil,
            "later slot mutation cannot rewrite line")
    end)

    t:case("event and time limits truncate once", function()
        local event_lines, now = {}, 0
        local event_trace = Trace.new{
            source = "direct", now = function() return now end,
            max_events = 3, duration_seconds = 60,
            emit = function(line) event_lines[#event_lines + 1] = line end,
        }
        for i = 1, 5 do
            event_trace:record(i, 1, 4, 1, 1, i, i, i,
                "idle", "idle", true, true, "pending", "hover")
        end
        t:eq(event_trace:count(), 3, "hard event cap")
        t:eq(#event_lines, 4, "three records plus one truncation")
        t:check(event_lines[4]:find("trace_truncated=event_limit", 1, true) ~= nil,
            "event cause recorded once")

        local time_lines = {}
        local time_trace = Trace.new{
            source = "epub_canvas", now = function() return now end,
            max_events = 10, duration_seconds = 2,
            emit = function(line) time_lines[#time_lines + 1] = line end,
        }
        now = 2
        time_trace:afterFrame()
        time_trace:afterFrame()
        t:eq(#time_lines, 1, "time truncation emitted once")
        t:check(time_lines[1]:find("trace_truncated=time_limit", 1, true) ~= nil,
            "time cause recorded")
    end)

    t:case("non-finite injected limits fall back to bounded defaults", function()
        local trace = Trace.new{
            source = "direct",
            now = function() return 0 end,
            duration_seconds = math.huge,
            max_events = math.huge,
            emit = function() end,
        }
        t:eq(trace.deadline, 60, "infinite duration cannot disable the time cap")
        t:eq(trace.max_events, 8192, "infinite count cannot disable the event cap")

        local seq = Sequence.new{
            max_open_points = math.huge,
            max_contact_samples = math.huge,
        }
        t:eq(seq.max_open_points, 8192, "point cap falls back")
        t:eq(seq.max_contact_samples, 32768, "sample cap falls back")
    end)

    t:case("diagnostic deltas never cross slots or contact generations", function()
        local trace = Trace.new{
            source = "notebook", now = function() return 0 end,
            emit = function() end,
        }
        local dx, dy, dt = trace:deltas(4, 7, 1, 10, 20, 1)
        t:eq(dx, nil, "first sample has no x delta")
        trace:deltas(8, 9, 1, 500, 600, 2)
        dx, dy, dt = trace:deltas(4, 7, 1, 13, 25, 4)
        t:eq(dx, 3, "interleaved slot keeps its own x history")
        t:eq(dy, 5, "interleaved slot keeps its own y history")
        t:eq(dt, 3, "interleaved slot keeps its own time history")

        dx, dy, dt = trace:deltas(4, -1, 0, 13, 25, 5)
        t:eq(dx, 0, "owner lift may close the current generation")
        t:eq(dt, 1, "lift delta remains contact-local")
        dx = trace:deltas(4, 7, 1, 13, 25, 6)
        t:eq(dx, nil, "reused Wacom ID after lift starts a new generation")
        dx = trace:deltas(4, 7, 2, 14, 25, 7)
        t:eq(dx, nil, "tool boundary also starts a new generation")

        trace:deltas(4, 7, 2, 20, 30, 8)
        trace:resetContactHistory()
        dx, dy, dt = trace:deltas(4, 7, 2, 900, 700, 500)
        t:eq(dx, nil, "lease boundary clears x history")
        t:eq(dy, nil, "lease boundary clears y history")
        t:eq(dt, nil, "lease boundary clears time history")
    end)

    t:case("diagnostics retain no mutable KOReader slot", function()
        local trace = Trace.new{
            source = "direct", now = function() return 0 end,
            emit = function() end,
        }
        local seq = harness{ trace = trace }
        local weak = setmetatable({}, { __mode = "v" })
        do
            local slot = pen(1, 10, 20, 1, 4, 100)
            weak[1] = slot
            seq:feed(slot)
        end
        collectgarbage("collect")
        collectgarbage("collect")
        t:eq(weak[1], nil, "slot table is collectible after feed")
    end)

    t:case("function diagnostics start a new delta epoch after reset", function()
        local events = {}
        local seq = harness{
            trace = function(...)
                events[#events + 1] = { ... }
                return true
            end,
        }
        seq:feed(pen(1, 10, 20, 1, 4, 100))
        t:eq(seq:reset(true), true, "physical reset succeeds")
        seq:feed(pen(1, 900, 700, 1, 4, 500))
        local event = events[#events]
        t:eq(event[15], nil, "x delta cannot cross reset")
        t:eq(event[16], nil, "y delta cannot cross reset")
        t:eq(event[17], nil, "time delta cannot cross reset")
    end)

    t:case("failed forwarded abort preserves the physical trace epoch", function()
        local lines = {}
        local trace = Trace.new{
            source = "direct", now = function() return 0 end,
            emit = function(line) lines[#lines + 1] = line end,
        }
        local seq = harness{
            trace = trace,
            classify = function() return "pass" end,
            drop_contact = function() return false end,
        }
        seq:feed(pen(1, 10, 20, 1, 4, 100))
        local ok, err = seq:abort("external_abort")
        t:eq(ok, false, "failed drop leaves contact forwarded")
        t:eq(err, "contact_forwarded", "failure is classified")
        seq:feed(pen(1, 15, 27, 1, 4, 110))
        local line = lines[#lines]
        t:check(line:find("dx=5", 1, true) ~= nil,
            "x delta remains in the same physical epoch")
        t:check(line:find("dy=7", 1, true) ~= nil,
            "y delta remains in the same physical epoch")
        t:check(line:find("dt=10", 1, true) ~= nil,
            "time delta remains in the same physical epoch")
    end)

    t:case("closed scalar schema cannot leak arbitrary identities", function()
        local lines = {}
        local trace = Trace.new{
            source = "notebook", now = function() return 0 end,
            emit = function(line) lines[#lines + 1] = line end,
        }
        trace:record(1, 1, "/secret/book.epub", "Notebook title", 1,
            1, 2, "xpointer(/secret)", "idle", "idle", true, true,
            "unknown decision", "/secret/book.epub")
        local line = lines[1]
        t:check(line:find("/secret", 1, true) == nil, "path absent")
        t:check(line:find("Notebook title", 1, true) == nil, "title absent")
        t:check(line:find("xpointer", 1, true) == nil, "xpointer absent")
        t:check(line:find("redacted", 1, true) ~= nil, "unknown token redacted")
    end)

    t:describe("input_replay / full callback pipeline")

    t:case("integration replay exposes synchronous callback removal", function()
        local input = ctx.reset{ wacom_protocol = true }
        local callback_calls = 0
        input.stylus_callback = function(owner)
            callback_calls = callback_calls + 1
            owner.stylus_callback = nil
            return true
        end
        local replay = Replay.new{
            mode = "integration",
            input = input,
            is_stylus = function() return true end,
        }
        replay:set(4, { id = 1, x = 10, y = 10, tool = 1 })
        replay:set(5, { id = 2, x = 20, y = 20, tool = 1 })
        local ok = pcall(replay.syn, replay)
        t:eq(ok, false, "second slot observes KOReader's nil callback crash")
        t:eq(callback_calls, 1, "unsafe callback ran only for the first slot")
        t:eq(input.gesture_detector.calls, 0,
            "a routeStylusEvents failure never reaches GestureDetector")
    end)

    t:case("integration replay accepts deferred callback removal", function()
        local Capture = require("ink_capture")
        local input = ctx.reset{ wacom_protocol = true }
        local handler_calls = 0
        local installed = Capture:installStylus(function()
            handler_calls = handler_calls + 1
            Capture:removeDeferred()
            return true
        end, function(slots) return slots end)
        t:eq(installed, true, "real Capture callback installed")
        local callback = input.stylus_callback
        local replay = Replay.new{
            mode = "integration", input = input, capture = Capture,
        }
        replay:set(4, { id = 1, x = 10, y = 10, tool = Capture.TOOL_PEN })
        replay:set(5, { id = 2, x = 20, y = 20, tool = Capture.TOOL_PEN })
        local _, kept, dominated = replay:syn()
        t:eq(handler_calls, 1, "inert callback skips plugin work for later slots")
        t:eq(#dominated, 1, "first slot keeps its completed decision")
        t:eq(#kept, 1, "later slot fails open while capture is inert")
        t:eq(input.stylus_callback, callback, "callback remains installed in-frame")
        ctx.env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "callback unhooks on the safe tick")
    end)

    t:case("integration replay calls wrapped frame handler once per SYN", function()
        local Capture = require("ink_capture")
        local input = ctx.reset{ wacom_protocol = true }
        local contacts, taps = {}, 0
        local gd = { calls = 0, dropped = {} }
        function gd:feedEvent(slots)
            self.calls = self.calls + 1
            for i = 1, #slots do
                local slot = slots[i]
                if slot.id and slot.id >= 0 then
                    contacts[slot.slot] = contacts[slot.slot] or { slot = slot.slot }
                elseif slot.id and slot.id < 0 and contacts[slot.slot] then
                    contacts[slot.slot] = nil
                    taps = taps + 1
                end
            end
            return {}
        end
        function gd:getContact(slot) return contacts[slot] end
        function gd:dropContact(contact)
            contacts[contact.slot] = nil
            self.dropped[#self.dropped + 1] = contact.slot
        end
        input.gesture_detector = gd

        local seq = harness{
            wacom_protocol = true,
            pen_slot = 4,
            classify = function() return "pass" end,
            drop_contact = function(slot)
                local contact = gd:getContact(slot)
                if not contact then return false end
                gd:dropContact(contact)
                return true
            end,
        }
        local frame_calls = 0
        local installed = Capture:installStylus(
            function(slot) return seq:feed(slot) end,
            function(slots)
                frame_calls = frame_calls + 1
                seq:afterFrame()
                return slots
            end)
        t:eq(installed, true, "real Capture wrapper installed")

        local replay = Replay.new{
            mode = "integration", input = input, capture = Capture,
        }
        replay:set(4, { id = 4, x = 10, y = 10, tool = 1 })
        local _, kept_down, dominated_down = replay:syn()
        t:eq(#kept_down, 1, "pass down reaches detector")
        t:eq(#dominated_down, 0, "pass down not removed")
        replay:set(4, { tool = 0 })
        replay:syn()
        replay:set(4, { id = -1 })
        replay:syn()

        t:eq(gd.calls, 3, "GestureDetector called once per SYN")
        t:eq(frame_calls, 3, "wrapper frame handler called once per SYN")
        t:eq(taps, 1, "down and final lift form one control tap")
        Capture:remove()
    end)
end
