--[[--
Physical stylus-contact normalizer shared by JustDraw's drawing hosts.

This module owns only contact semantics: slot/id ownership, Wacom proximity
boundaries, pass-through monotonicity, host callback ordering, and bounded
work. It knows nothing about widgets, documents, persistence, or refreshes.

KOReader's public callback exposes accumulated slot state but no per-SYN axis
freshness mask. Consequently, the production default geometry policy is
deliberately fail-closed: it never accepts coordinates. InkStylusGeometry is
the trace-backed policy hosts inject; tests inject explicit ones to exercise
the physical state machine without turning a guess about N samples, distance,
or time into production behavior.

A policy may answer "route" as well as "accept" and "pending": evidence that is
good enough to decide whose contact this is, but not good enough to draw from.
Only a hand-over acts on it, which is what keeps a control tappable with a pen
while ink still waits for a coordinate pair it can prove.
]]

local Limits = require("ink_limits")

local Sequence = {}
Sequence.__index = Sequence

local function trueCallback()
    return true
end

local function continueCallback()
    return "continue"
end

local function blockCallback()
    return "block", nil, "route_block"
end

local function identity(x, y)
    return x, y
end

local function finiteNumber(value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function positiveInteger(value, fallback)
    value = tonumber(value)
    if not value or value == math.huge or value == -math.huge
        or value < 1 or value ~= math.floor(value) then
        return fallback
    end
    return value
end

-- The stop condition in the design is intentional: without a physical trace
-- there is no public signal proving that both accumulated axes are fresh.
local ConservativeGeometry = {}

function ConservativeGeometry:observe()
    return "pending", nil, nil, "geometry_unverified"
end

function ConservativeGeometry:onLift()
    return "discard", nil, nil, "geometry_unverified"
end

function ConservativeGeometry:reset()
end

local function isPendingState(state)
    return state == "contact_pending" or state == "geometry_pending"
end

local function isForwardedState(state)
    return state == "active_pass" or state == "forwarded_wait_lift"
end

function Sequence.new(spec)
    spec = spec or {}
    local geometry = spec.geometry or ConservativeGeometry
    if type(geometry.observe) ~= "function"
        or type(geometry.onLift) ~= "function" then
        error("stylus geometry policy requires observe and onLift", 2)
    end

    return setmetatable({
        wacom_protocol = spec.wacom_protocol == true,
        pen_slot = finiteNumber(spec.pen_slot),
        tool_finger = finiteNumber(spec.tool_finger) or 0,
        to_screen = spec.to_screen or identity,
        max_open_points = positiveInteger(
            spec.max_open_points, Limits.MAX_OPEN_POINTS),
        max_contact_samples = positiveInteger(
            spec.max_contact_samples, Limits.MAX_CONTACT_SAMPLES),

        geometry = geometry,
        geometry_observe = geometry.observe,
        geometry_on_lift = geometry.onLift,
        geometry_reset = geometry.reset,
        geometry_note = geometry.note,

        classify = spec.classify or blockCallback,
        on_contact_start = spec.on_contact_start or trueCallback,
        on_point = spec.on_point or continueCallback,
        on_finish = spec.on_finish or trueCallback,
        on_abort = spec.on_abort or trueCallback,
        on_contact_end = spec.on_contact_end or trueCallback,
        on_pending_finish = spec.on_pending_finish,
        on_domain_error = spec.on_domain_error,
        drop_contact = spec.drop_contact,

        --- Kernel-side evidence, read once per frame (ADR-44):
        --- `function() -> syn_dropped_count, btn_touch_count`, the two
        --- counters ink_slot_steer keeps. Absent on a runtime with no steer,
        --- and then nothing below it runs.
        sync_counts = spec.sync_counts,
        on_desync = spec.on_desync,
        sync_drops = nil,
        sync_edges = nil,
        desync_edges = nil,
        desyncs = 0,
        desync_cuts = 0,

        state = "idle",
        owner_slot = nil,
        owner_id = nil,
        current_tool = nil,
        effect = nil,
        effect_active = false,
        physical_started = false,
        contact_end_called = true,
        point_count = 0,
        sample_count = 0,

        pending_domain_reason = nil,
        pending_domain_phase = nil,

        trace = spec.trace,
        frame_ordinal = 1,
        event_ordinal = 0,
        last_delivery = true,
        trace_slot = nil,
        trace_id = nil,
        trace_tool = nil,
        trace_contact_active = false,
        trace_x = nil,
        trace_y = nil,
        trace_timev = nil,
    }, Sequence)
end

function Sequence:setTrace(trace)
    self.trace = trace
    if trace and type(trace) ~= "function"
        and type(trace.resetContactHistory) == "function" then
        trace:resetContactHistory()
    end
    self.frame_ordinal = 1
    self.event_ordinal = 0
    self.last_delivery = true
    self.trace_slot = nil
    self.trace_id, self.trace_tool, self.trace_contact_active = nil, nil, false
    self.trace_x, self.trace_y, self.trace_timev = nil, nil, nil
end

function Sequence:_resetTraceContactHistory()
    -- Function sinks use this local scalar fallback instead of Trace:deltas().
    -- Both forms must begin a new epoch at the same lifecycle boundaries.
    self.trace_slot = nil
    self.trace_id, self.trace_tool, self.trace_contact_active = nil, nil, false
    self.trace_x, self.trace_y, self.trace_timev = nil, nil, nil
    local trace = self.trace
    if trace and type(trace) ~= "function"
        and type(trace.resetContactHistory) == "function" then
        trace:resetContactHistory()
    end
end

function Sequence:_traceResult(delivery, decision, reason, state_before,
        slot, id, tool, x, y, timev)
    local trace = self.trace
    if trace then
        self.event_ordinal = self.event_ordinal + 1
        local dx, dy, dt
        local nx, ny = finiteNumber(x), finiteNumber(y)
        local nt = finiteNumber(timev)
        if type(trace) ~= "function" and type(trace.deltas) == "function" then
            dx, dy, dt = trace:deltas(slot, id, tool, x, y, timev)
        else
            local contact_id, contact_tool = finiteNumber(id), finiteNumber(tool)
            local positive = contact_id ~= nil and contact_id >= 0
            local same_sequence = slot == self.trace_slot
                and self.trace_contact_active
                and (not positive or (contact_id == self.trace_id
                    and contact_tool == self.trace_tool))
            dx = same_sequence and nx and self.trace_x and nx - self.trace_x or nil
            dy = same_sequence and ny and self.trace_y and ny - self.trace_y or nil
            dt = same_sequence and nt and self.trace_timev
                and nt - self.trace_timev or nil
            if positive then
                if not same_sequence then
                    self.trace_x, self.trace_y, self.trace_timev = nil, nil, nil
                end
                self.trace_slot = slot
                self.trace_id, self.trace_tool = contact_id, contact_tool
                self.trace_contact_active = true
                if nx ~= nil then self.trace_x = nx end
                if ny ~= nil then self.trace_y = ny end
                if nt ~= nil then self.trace_timev = nt end
            elseif contact_id ~= nil then
                self.trace_contact_active = false
                self.trace_id, self.trace_tool = nil, nil
                self.trace_x, self.trace_y, self.trace_timev = nil, nil, nil
            end
        end

        local keep
        if type(trace) == "function" then
            keep = trace(self.event_ordinal, self.frame_ordinal,
                slot, id, tool, x, y, timev,
                state_before, self.state, self.last_delivery, delivery,
                decision, reason, dx, dy, dt)
        else
            keep = trace:record(self.event_ordinal, self.frame_ordinal,
                slot, id, tool, x, y, timev,
                state_before, self.state, self.last_delivery, delivery,
                decision, reason, dx, dy, dt)
        end
        if keep == false then self.trace = nil end
    end
    self.last_delivery = delivery
    return delivery
end

--[[--
Record a slot that is not, and never becomes, this sequence's contact.

A routed palm and a foreign Wacom slot both need to appear in the trace -- a
discarded event with no explanation is the hardest kind to read afterwards --
but neither is a transition of the owner, so the owner's delivery history must
survive them intact.
]]
function Sequence:_traceForeign(delivery, decision, reason,
        slot, id, tool, x, y, timev)
    if not self.trace then return end
    local delivery_before = self.last_delivery
    local t_slot, t_id, t_tool = self.trace_slot, self.trace_id, self.trace_tool
    local t_active = self.trace_contact_active
    local t_x, t_y, t_timev = self.trace_x, self.trace_y, self.trace_timev
    self:_traceResult(delivery, decision, reason, self.state,
        slot, id, tool, x, y, timev)
    self.last_delivery = delivery_before
    self.trace_slot, self.trace_id, self.trace_tool = t_slot, t_id, t_tool
    self.trace_contact_active = t_active
    self.trace_x, self.trace_y, self.trace_timev = t_x, t_y, t_timev
end

--[[--
Record a palm InkWacomPalm dominated before it reached this sequence.

Called by the host so one bounded trace explains every discarded contact,
including the ones this module never sees.
]]
function Sequence:tracePalm(slot, reason)
    if not self.trace or not slot then return end
    self:_traceForeign(true, "palm", reason,
        finiteNumber(slot.slot), finiteNumber(slot.id), finiteNumber(slot.tool),
        slot.x, slot.y, slot.timev)
end

function Sequence:_deliverDomainError()
    local reason, phase = self.pending_domain_reason, self.pending_domain_phase
    if reason ~= nil then
        self.pending_domain_reason = nil
        self.pending_domain_phase = nil
        if self.on_domain_error then
            -- Deliberately not protected here. Feed paths reach this from the
            -- guarded frame handler; external lifecycle callers must likewise
            -- see a programming error instead of silently losing it.
            self.on_domain_error(reason, phase)
        end
    end
    return reason, phase
end

function Sequence:_externalResult()
    local reason, phase = self:_deliverDomainError()
    if reason ~= nil then return false, reason, phase end
    return true
end

function Sequence:afterFrame()
    local trace = self.trace
    if trace and type(trace) ~= "function"
        and type(trace.afterFrame) == "function"
        and trace:afterFrame() == false then
        self.trace = nil
    end
    if trace then self.frame_ordinal = self.frame_ordinal + 1 end

    self:_deliverDomainError()
end

function Sequence:_domainError(reason, phase)
    if self.pending_domain_reason == nil then
        self.pending_domain_reason = reason or (phase .. "_failed")
        self.pending_domain_phase = phase
    end
end

--[[--
Tell the policy where the owner's slot is, on every frame of its contact.

A contact that latched into pass, block or suspended never reaches
`_observeGeometry` again, so without this the policy's idea of "the last place
the pen was" stops at whatever sample happened to be the last one it judged --
and that frozen point becomes the next contact's trusted boundary while the
slot itself keeps moving to the real lift position. The next stale
contact-down then looks fresh on both axes and paints a line to it.
]]
function Sequence:_noteGeometry(x, y)
    if self.geometry_note then self.geometry_note(self.geometry, x, y) end
end

function Sequence:_resetGeometry(clear_history)
    if self.geometry_reset then
        self.geometry_reset(self.geometry, clear_history == true)
    end
end

function Sequence:_clearOwner()
    self.owner_slot = nil
    self.owner_id = nil
    self.current_tool = nil
    self.effect = nil
    self.effect_active = false
    self.physical_started = false
    self.contact_end_called = true
    self.point_count = 0
    self.sample_count = 0
end

function Sequence:_callContactEnd(reason)
    if not self.physical_started or self.contact_end_called then return true end
    -- Mark it before calling the host, so a failing callback can never be
    -- repeated by teardown.
    self.contact_end_called = true
    self.physical_started = false
    local ok, err = self.on_contact_end(reason)
    if ok ~= true then
        self:_domainError(err, "on_contact_end")
        return false
    end
    return true
end

function Sequence:_endPhysical(target_state, reason, clear_history)
    self.effect_active = false
    self.effect = nil
    self.point_count = 0
    self.sample_count = 0
    self.state = target_state
    self:_resetGeometry(clear_history == true)
    local ended = self:_callContactEnd(reason)
    if target_state == "idle" then
        self:_clearOwner()
    end
    return ended
end

--[[--
The kernel overflowed evdev, and `ink_slot_steer` counted the `SYN_DROPPED`.

Frames were lost, and the slot now carries whichever axes the tail of the
lost window happened to rewrite: (1048,1061) -> drop -> a frame with only
ABS_Y -> (1048,990) -> (1204,989), the corner nobody drew (crash.log
2026-09-02, line 60695). Nothing after this point is known to be adjacent to
what came before, so the ink in flight is *finished* where it stands -- it was
real -- and no later frame is joined to it.

The contact stays owned. The pen may well still be down, and the write queue
and the sheet index have to keep yielding to it. But it draws nothing until
`BTN_TOUCH` moves: a lift, or a down after a lift that was lost inside the
window. That edge is the only evidence available here -- KOReader writes
`id = pen_slot` on every BTN_TOUCH 1 (input.lua 783-787), so a fresh contact
looks exactly like the old one from inside this callback. The kernel's own
rule is to ignore everything up to and including the next SYN_REPORT, so an
edge counted in the frame that carried the drop is not one of those
boundaries either (ADR-44).
]]
function Sequence:_desync(edges)
    self.desyncs = self.desyncs + 1
    self.desync_edges = edges
    local state = self.state
    local cut = false
    -- A forwarded contact is GestureDetector's: a lift it never sees is
    -- KOReader's to notice, and taking the slot back here would strand a
    -- pending hold timer (ADR-22). Nothing below may move for one.
    if not isForwardedState(state) then
        if state == "idle" or state == "proximity_wait" then
            -- No contact to cut, but the boundary the next one is measured
            -- against may name a place the pen has since left: make the next
            -- pair provisional rather than trusted.
            self:_resetGeometry(true)
        else
            if self.effect_active then
                self:_closeEffect("finish", "evdev_desync")
                cut = true
                self.desync_cuts = self.desync_cuts + 1
            end
            self.effect = nil
            self.effect_active = false
            self.point_count = 0
            self.state = "desync_wait"
            self:_resetGeometry(true)
        end
    end
    -- Told in every case, forwarded included: a drop with nothing beside it
    -- in the log is a drop nothing noticed.
    if self.on_desync then self.on_desync(cut) end
end

--- How many overflows this lease has seen, and how many of them cut a stroke.
function Sequence:desyncCounts()
    return self.desyncs, self.desync_cuts
end

function Sequence:_closeEffect(mode, reason)
    if not self.effect_active then return true end
    -- Clear first: an expected failure means the host has already repaired
    -- its partial work, and an unexpected raise must not cause a second call.
    self.effect_active = false
    local callback = mode == "abort" and self.on_abort or self.on_finish
    local ok, err = callback(reason)
    if ok ~= true then
        self:_domainError(err, mode == "abort" and "on_abort" or "on_finish")
        return false
    end
    return true
end

function Sequence:_beginOwner(slot, id, tool, timev, reason)
    self.owner_slot = slot
    self.owner_id = id
    self.current_tool = tool ~= self.tool_finger and tool or nil
    self.effect = nil
    self.effect_active = false
    self.physical_started = true
    self.contact_end_called = false
    self.point_count = 0
    self.sample_count = 0
    self.state = "contact_pending"
    local ok, err = self.on_contact_start(reason)
    if ok ~= true then
        self.state = "suspended"
        self:_domainError(err, "on_contact_start")
        return false
    end
    return true
end

function Sequence:_tryDrop(slot)
    if type(self.drop_contact) ~= "function" then
        return false, "drop_failed"
    end
    -- This pcall is confined to the exceptional reclaim path; it is not on
    -- ordinary per-sample delivery.
    local called, dropped = pcall(self.drop_contact, slot)
    if not called or dropped ~= true then
        return false, "drop_failed"
    end
    return true, "drop_succeeded"
end

function Sequence:_handleSampleBudget()
    self.sample_count = self.max_contact_samples
    if isForwardedState(self.state) then
        return false, "pass", "sample_budget"
    end
    if self.state == "suspended" then
        return true, "suspend", "sample_budget"
    end
    if self.state == "active_draw" then
        if self.effect == "erase" then
            self:_closeEffect("finish", "sample_budget")
        else
            self:_closeEffect("abort", "sample_budget")
        end
    end
    self.effect_active = false
    self.state = "suspended"
    return true, "abort_budget", "sample_budget"
end

function Sequence:_countOwnerSample()
    if self.sample_count >= self.max_contact_samples then
        return self:_handleSampleBudget()
    end
    self.sample_count = self.sample_count + 1
    return nil
end

function Sequence:_emitPoint(x, y, is_first)
    if self.effect == "ink" and self.point_count >= self.max_open_points then
        self:_closeEffect("abort", "point_budget")
        self.state = "suspended"
        return "abort_budget", "point_budget"
    end

    local action, err = self.on_point(x, y, self.current_tool, is_first)
    if action == nil then
        -- Expected host failures repair their own partial raster/store state.
        self.effect_active = false
        self.state = "suspended"
        self:_domainError(err, "on_point")
        return "suspend", "domain_error"
    end
    if action ~= "continue" and action ~= "finish_suspend"
        and action ~= "abort_suspend" then
        error("invalid stylus on_point action: " .. tostring(action), 2)
    end

    if self.effect == "ink" then
        self.point_count = self.point_count + 1
    end
    if action == "finish_suspend" then
        self:_closeEffect("finish", "finish_suspend")
        self.state = "suspended"
        return "suspend", "finish_suspend"
    elseif action == "abort_suspend" then
        self:_closeEffect("abort", "abort_suspend")
        self.state = "suspended"
        return "suspend", "abort_suspend"
    end
    return is_first and "begin" or "append", "accepted"
end

function Sequence:_acceptGeometry(raw_x, raw_y, is_first)
    local x, y = self.to_screen(raw_x, raw_y)
    x, y = finiteNumber(x), finiteNumber(y)
    if not x or not y then
        if self.effect_active then
            self:_closeEffect("abort", "invalid_geometry")
        end
        self.state = "suspended"
        return true, "discard", "non_finite"
    end

    if is_first then
        local route, effect = self.classify(x, y, self.current_tool, true)
        if route == "draw" then
            if effect ~= "ink" and effect ~= "erase" then
                error("draw route requires ink or erase effect", 2)
            end
            self.state = "active_draw"
            self.effect = effect
            self.effect_active = true
            local decision, reason = self:_emitPoint(x, y, true)
            return true, decision, reason
        elseif route == "block" then
            self.state = "active_block"
            self.effect = nil
            return true, "accept", "route_block"
        elseif route == "pass" then
            self.state = "active_pass"
            self.effect = nil
            return false, "pass", "route_pass"
        end
        error("invalid stylus classify route: " .. tostring(route), 2)
    end

    local decision, reason = self:_emitPoint(x, y, false)
    return true, decision, reason
end

--[[--
Hand the contact over on evidence good enough to route but not to draw from.

A pair with one accumulated axis still unproven can be a long way from where
the pen actually is, so it may never become ink. It can still answer the one
question that has to be answered while the contact is still down: does this
belong to somebody else? Without that, a pen tap whose position shares an axis
with the previous contact -- two taps running on the same button -- would be
dominated to its lift and then discarded, because forwarding a lone lift for a
contact GestureDetector never opened produces no tap at all.

Only a hand-over acts on this. "draw" and "block" change nothing and wait for a
coherent pair, so a half-proven coordinate can never start ink or latch a host
destination.
]]
function Sequence:_routePending(raw_x, raw_y)
    local x, y = self.to_screen(raw_x, raw_y)
    x, y = finiteNumber(x), finiteNumber(y)
    if not x or not y then return false end
    if self.classify(x, y, self.current_tool, false) ~= "pass" then return false end
    self.state = "active_pass"
    self.effect = nil
    self.effect_active = false
    return true
end

function Sequence:_observeGeometry(raw_x, raw_y, timev, phase, is_first)
    raw_x, raw_y = finiteNumber(raw_x), finiteNumber(raw_y)
    if not raw_x or not raw_y then
        return true, "discard", "non_finite"
    end

    local status, a, b, why = self.geometry_observe(
        self.geometry, raw_x, raw_y, timev, phase)
    if status == "pending" or status == "route" then
        if status == "route" and is_first then
            local rx, ry = finiteNumber(a), finiteNumber(b)
            if rx and ry and self:_routePending(rx, ry) then
                return false, "pass", "route_pass"
            end
        end
        if is_first then self.state = "geometry_pending" end
        -- The policy names which axis is still unproven; that token is the
        -- only way a trace tells "waiting for evidence" apart from "refused".
        return true, "pending", type(why) == "string" and why or "geometry_pending"
    elseif status == "reject" then
        if self.effect_active then
            self:_closeEffect("abort", "geometry_rejected")
        end
        self.state = "suspended"
        return true, "discard", "geometry_rejected"
    elseif status ~= "accept" then
        error("invalid stylus geometry result: " .. tostring(status), 2)
    end

    a, b = finiteNumber(a), finiteNumber(b)
    if not a or not b then
        if self.effect_active then
            self:_closeEffect("abort", "invalid_geometry")
        end
        self.state = "suspended"
        return true, "discard", "invalid_geometry"
    end
    return self:_acceptGeometry(a, b, is_first)
end

function Sequence:_beginAndProcess(slot, id, tool, x, y, timev, reason)
    if not self:_beginOwner(slot, id, tool, timev, reason) then
        return true, "suspend", "domain_error"
    end
    local limited, decision, why = self:_countOwnerSample()
    if limited ~= nil then return limited, decision, why end
    return self:_observeGeometry(x, y, timev, "begin", true)
end

--[[--
Close a contact whose geometry was never proven.

The host may pass `on_pending_finish(kind)` to hear the outcome: "dot" for a
contact that still delivered its single lift point, "discard" for one that
never had a position. A contact that was handed to the UI reports neither --
a tap ending as a tap is not a collapse. Called after the outcome is fully
decided, so it can never influence it.
]]
function Sequence:_finishPending(target_state, reason, x, y, timev)
    local status, a, b = self.geometry_on_lift(
        self.geometry, x, y, timev)
    -- A policy that can route may answer with either token here; both mean
    -- "this is the last position observed", which is at most one dot.
    if status == "route" then status = "dot" end
    local decision, trace_reason = "discard", "pending_discard"

    if status == "dot" then
        a, b = finiteNumber(a), finiteNumber(b)
        if a and b then
            local delivery
            delivery, decision, trace_reason =
                self:_acceptGeometry(a, b, true)
            if self.state == "active_pass" then
                -- Earlier frames were dominated, so forwarding only the lift
                -- would synthesize a broken GestureDetector sequence.
                decision, trace_reason = "discard", "pending_pass_discard"
            elseif self.effect_active then
                self:_closeEffect("finish", reason)
                decision, trace_reason = "lift", "pending_dot"
            end
        else
            trace_reason = "invalid_geometry"
        end
    elseif status ~= "discard" and status ~= "pending" then
        error("invalid stylus geometry onLift result: " .. tostring(status), 2)
    end

    if self.on_pending_finish then
        if trace_reason == "pending_dot" then
            self.on_pending_finish("dot")
        elseif trace_reason == "pending_discard" then
            self.on_pending_finish("discard")
        end
    end
    self:_endPhysical(target_state, reason, false)
    return true, decision, trace_reason
end

function Sequence:_finishOwnedBoundary(target_state, reason)
    if self.state == "active_draw" and self.effect_active then
        self:_closeEffect("finish", reason)
    end
    self:_endPhysical(target_state, reason, false)
end

function Sequence:_holdUnstartedReplacement(slot, id, tool)
    self.owner_slot = slot
    self.owner_id = id
    self.current_tool = tool ~= self.tool_finger and tool or nil
    self.physical_started = false
    self.contact_end_called = true
    self.effect = nil
    self.effect_active = false
    self.point_count = 0
    self.sample_count = 1
    self.state = "suspended"
end

function Sequence:_replaceOwned(slot, id, tool, x, y, timev, reason)
    if isPendingState(self.state) then
        -- Pending candidates never reached a host effect.
    elseif self.state == "active_draw" and self.effect_active then
        self:_closeEffect("finish", reason)
    end
    self:_endPhysical("idle", reason, false)

    if self.pending_domain_reason ~= nil then
        self:_holdUnstartedReplacement(slot, id, tool)
        return true, "suspend", "domain_error"
    end
    return self:_beginAndProcess(slot, id, tool, x, y, timev, reason)
end

function Sequence:_replaceForwarded(slot, id, tool, x, y, timev, reason)
    local dropped, drop_reason = self:_tryDrop(self.owner_slot)
    if not dropped then
        self.state = "forwarded_wait_lift"
        self.owner_id = id
        self:_domainError(drop_reason, "drop_contact")
        return false, "pass", "drop_failed"
    end

    local ended = self:_endPhysical("idle", reason, false)
    if not ended or self.pending_domain_reason ~= nil then
        -- The old GestureDetector Contact was reclaimed, so the replacement
        -- must now remain dominated. Do not start a new host generation after
        -- its predecessor failed to close; keep it inert until its boundary
        -- while afterFrame reports the original domain error.
        self:_holdUnstartedReplacement(slot, id, tool)
        return true, "suspend", "domain_error"
    end
    local delivery, decision, why =
        self:_beginAndProcess(slot, id, tool, x, y, timev, reason)
    return delivery, decision, why
end

function Sequence:feed(slot)
    -- Snapshot every public field before any host callback can mutate the
    -- reusable KOReader slot table.
    local slot_number = finiteNumber(slot and slot.slot)
    local id = finiteNumber(slot and slot.id)
    local x = slot and slot.x
    local y = slot and slot.y
    local tool = finiteNumber(slot and slot.tool)
    local timev = slot and slot.timev
    local before = self.state

    -- Before anything is decided from this frame: did the kernel drop any
    -- since the last one? (ADR-44.) The first frame of a lease only records
    -- the counters -- an overflow older than this sequence is not its stroke.
    if self.sync_counts then
        local drops, edges = self.sync_counts()
        local overflowed = self.sync_drops ~= nil and drops ~= self.sync_drops
        self.sync_drops, self.sync_edges = drops, edges
        if overflowed then self:_desync(edges) end
    end

    -- Defense in depth behind InkWacomPalm. On Wacom the digitizer owns one
    -- slot; a stylus-valued tool anywhere else is a promoted palm wearing the
    -- eraser's number, and no state here may move because of it. Dominated,
    -- because handing a palm back to GestureDetector is the other half of the
    -- bug this rejects.
    if self.wacom_protocol and self.pen_slot ~= nil
        and slot_number ~= nil and slot_number ~= self.pen_slot then
        self:_traceForeign(true, "discard", "wacom_non_pen",
            slot_number, id, tool, x, y, timev)
        return true
    end

    if id == nil then
        local delivery = not isForwardedState(self.state)
        if self.state ~= "idle" and slot_number ~= self.owner_slot then
            delivery = false
        end
        return self:_traceResult(delivery, "pending", "hover", before,
            slot_number, nil, tool, x, y, timev)
    end

    if self.state == "idle" then
        if id < 0 then
            return self:_traceResult(false, "pass", "foreign_lift", before,
                slot_number, id, tool, x, y, timev)
        end
        if slot_number == nil then
            return self:_traceResult(true, "discard", "foreign_slot", before,
                nil, id, tool, x, y, timev)
        end
        local delivery, decision, reason =
            self:_beginAndProcess(slot_number, id, tool, x, y, timev,
                "contact_down")
        return self:_traceResult(delivery, decision, reason, before,
            slot_number, id, tool, x, y, timev)
    end

    if slot_number ~= self.owner_slot then
        return self:_traceResult(false, "pass",
            id < 0 and "foreign_lift" or "foreign_slot", before,
            slot_number, id, tool, x, y, timev)
    end

    -- Every frame of the owner's contact, whatever this sequence decides to do
    -- with it. Only the trusted pen reaches here, so only the trusted pen ever
    -- moves the boundary.
    self:_noteGeometry(x, y)

    if self.state == "desync_wait" then
        if self.sync_edges ~= self.desync_edges then
            -- BTN_TOUCH moved after the overflow: a boundary the pen itself
            -- reported, and the first thing since the drop that can be
            -- trusted (ADR-44).
            self:_endPhysical("idle", "evdev_desync", true)
            if id < 0 then
                return self:_traceResult(true, "lift", "desync_lift", before,
                    slot_number, id, tool, x, y, timev)
            end
            local delivery, decision, reason =
                self:_beginAndProcess(slot_number, id, tool, x, y, timev,
                    "contact_down")
            return self:_traceResult(delivery, decision, reason, before,
                slot_number, id, tool, x, y, timev)
        end
        if tool == self.tool_finger and self.wacom_protocol
            and slot_number == self.pen_slot then
            -- Proximity-out is a physical boundary too, and the only one a
            -- pen lifted clear of the digitizer will ever report.
            self:_endPhysical("proximity_wait", "wacom_proximity", true)
            return self:_traceResult(true, "proximity_out", "desync_proximity",
                before, slot_number, id, tool, x, y, timev)
        end
        return self:_traceResult(true, "discard", "desync_wait", before,
            slot_number, id, tool, x, y, timev)
    end

    if self.state == "proximity_wait" then
        if id < 0 then
            self.state = "idle"
            self:_resetGeometry(false)
            self:_clearOwner()
            return self:_traceResult(true, "lift", "late_lift", before,
                slot_number, id, tool, x, y, timev)
        end
        if tool == self.tool_finger then
            return self:_traceResult(true, "pending", "wacom_proximity", before,
                slot_number, id, tool, x, y, timev)
        end
        self:_clearOwner()
        local delivery, decision, reason =
            self:_beginAndProcess(slot_number, id, tool, x, y, timev,
                "contact_down")
        return self:_traceResult(delivery, decision, reason, before,
            slot_number, id, tool, x, y, timev)
    end

    if self.state == "forwarded_wait_lift" then
        if id < 0 then
            self:_endPhysical("idle", "owner_lift", false)
            return self:_traceResult(false, "lift", "late_lift", before,
                slot_number, id, tool, x, y, timev)
        end
        if tool == self.tool_finger then
            return self:_traceResult(false, "pass", "wacom_proximity", before,
                slot_number, id, tool, x, y, timev)
        end
        local delivery, decision, reason =
            self:_replaceForwarded(slot_number, id, tool, x, y, timev,
                "replacement_id")
        return self:_traceResult(delivery, decision, reason, before,
            slot_number, id, tool, x, y, timev)
    end

    if id < 0 then
        if isPendingState(self.state) then
            local delivery, decision, reason =
                self:_finishPending("idle", "owner_lift", x, y, timev)
            return self:_traceResult(delivery, decision, reason, before,
                slot_number, id, tool, x, y, timev)
        elseif self.state == "active_pass" then
            self:_endPhysical("idle", "owner_lift", false)
            return self:_traceResult(false, "lift", "owner_lift", before,
                slot_number, id, tool, x, y, timev)
        end
        self:_finishOwnedBoundary("idle", "owner_lift")
        return self:_traceResult(true, "lift", "owner_lift", before,
            slot_number, id, tool, x, y, timev)
    end

    -- Wacom proximity-out is narrower than a generic TOOL_FINGER transition:
    -- it is valid only for the configured pen slot that owns this sequence.
    if tool == self.tool_finger and self.wacom_protocol
        and slot_number == self.pen_slot then
        if isPendingState(self.state) then
            local delivery, decision, reason =
                self:_finishPending("proximity_wait", "wacom_proximity",
                    x, y, timev)
            return self:_traceResult(delivery, decision, reason, before,
                slot_number, id, tool, x, y, timev)
        elseif self.state == "active_pass" then
            self.state = "forwarded_wait_lift"
            return self:_traceResult(false, "proximity_out",
                "wacom_proximity", before,
                slot_number, id, tool, x, y, timev)
        end
        self:_finishOwnedBoundary("proximity_wait", "wacom_proximity")
        return self:_traceResult(true, "proximity_out", "wacom_proximity",
            before, slot_number, id, tool, x, y, timev)
    end

    if id ~= self.owner_id then
        local delivery, decision, reason
        if self.state == "active_pass" then
            delivery, decision, reason =
                self:_replaceForwarded(slot_number, id, tool, x, y, timev,
                    "replacement_id")
        else
            delivery, decision, reason =
                self:_replaceOwned(slot_number, id, tool, x, y, timev,
                    "replacement_id")
        end
        return self:_traceResult(delivery, "split_id",
            reason == "domain_error" and "domain_error" or "replacement_id",
            before, slot_number, id, tool, x, y, timev)
    end

    local non_finger_tool = tool ~= nil and tool ~= self.tool_finger
    if non_finger_tool and self.current_tool ~= nil
        and tool ~= self.current_tool then
        if self.state == "active_pass" then
            return self:_traceResult(false, "pass", "tool_change", before,
                slot_number, id, tool, x, y, timev)
        end
        local delivery, decision, reason =
            self:_replaceOwned(slot_number, id, tool, x, y, timev,
                "tool_change")
        return self:_traceResult(delivery, "split_id",
            reason == "domain_error" and "domain_error" or "tool_change",
            before, slot_number, id, tool, x, y, timev)
    elseif non_finger_tool and self.current_tool == nil then
        self.current_tool = tool
    end

    local limited, decision, reason = self:_countOwnerSample()
    if limited ~= nil then
        return self:_traceResult(limited, decision, reason, before,
            slot_number, id, tool, x, y, timev)
    end

    if self.state == "active_pass" then
        return self:_traceResult(false, "pass", "route_pass", before,
            slot_number, id, tool, x, y, timev)
    elseif self.state == "active_block" then
        return self:_traceResult(true, "accept", "route_block", before,
            slot_number, id, tool, x, y, timev)
    elseif self.state == "suspended" then
        return self:_traceResult(true, "suspend", "none", before,
            slot_number, id, tool, x, y, timev)
    end

    local delivery, next_decision, why = self:_observeGeometry(
        x, y, timev, self.state == "active_draw" and "active" or "update",
        isPendingState(self.state))
    return self:_traceResult(delivery, next_decision, why, before,
        slot_number, id, tool, x, y, timev)
end

--[[--
End whatever is in flight.

`detector_reset` is the caller telling this sequence that GestureDetector's
contacts have already been dropped underneath it -- which is what
`Input:resetState` does from inside `Input:inhibitInput`. It matters because a
failed drop normally means the opposite: a contact the detector still owns,
with a live hold timer and a lift still coming, which must not be forgotten.
When the detector has been reset there is nothing left to hand back, and
refusing to end the contact would leave this sequence latched in
`forwarded_wait_lift` waiting for a lift that can no longer arrive.
]]
function Sequence:abort(reason, clear_history, detector_reset)
    reason = reason or "external_abort"
    if isForwardedState(self.state) then
        local dropped = self:_tryDrop(self.owner_slot) or detector_reset == true
        if not dropped then
            self.state = "forwarded_wait_lift"
            if clear_history then self:_resetGeometry(true) end
            local domain_reason, phase = self:_deliverDomainError()
            if domain_reason ~= nil then
                return false, domain_reason, phase
            end
            return false, "contact_forwarded"
        end
        self:_endPhysical("idle", reason, clear_history == true)
        self:_resetTraceContactHistory()
        return self:_externalResult()
    elseif self.state == "proximity_wait" then
        self.state = "idle"
        self:_clearOwner()
        self:_resetGeometry(clear_history == true)
        self:_resetTraceContactHistory()
        return self:_externalResult()
    elseif self.state == "idle" then
        if clear_history then self:_resetGeometry(true) end
        self:_resetTraceContactHistory()
        return self:_externalResult()
    end

    if self.effect_active then
        self:_closeEffect("abort", reason)
    end
    self:_endPhysical("idle", reason, clear_history == true)
    self:_resetTraceContactHistory()
    return self:_externalResult()
end

function Sequence:reset(clear_history)
    return self:abort("reset", clear_history)
end

function Sequence:hasInkContact()
    return self.effect_active
end

function Sequence:hasOwnedPhysicalContact()
    local state = self.state
    return state == "contact_pending" or state == "geometry_pending"
        or state == "active_draw" or state == "active_block"
        or state == "suspended" or state == "desync_wait"
end

function Sequence:hasForwardedContact()
    return isForwardedState(self.state)
end

function Sequence:isLifecycleBlocked()
    return self.state ~= "idle" and self.state ~= "proximity_wait"
end

function Sequence:forwardedSlot()
    if isForwardedState(self.state) then return self.owner_slot end
    return nil
end

return Sequence
