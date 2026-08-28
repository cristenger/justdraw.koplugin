--[[--
Hardware-input adapter for a standalone notebook surface.

It deliberately knows no widget.  NotebookWindow will provide viewport,
touch-pass-through and dirty-region callbacks; this module owns the proven
pen/finger/eraser state machine and turns completed contacts into
InkSurfaceSession operations.
]]

local Capture = require("ink_capture")
local Device = require("device")
local Geom = require("ui/geometry")
local time = require("ui/time")
local Limits = require("ink_limits")

local Adapter = {}
Adapter.__index = Adapter

local function truthy(fn, ...)
    return type(fn) == "function" and fn(...) and true or false
end

local function updateLiveRasterToken(stroke, box, cache, generation)
    if stroke.live_raster_complete == false then return end
    if not box or not cache or generation == nil then
        stroke.live_raster_complete = false
        return
    end
    if stroke.raster_cache == nil then
        stroke.raster_cache = cache
        stroke.raster_generation = generation
        stroke.live_raster_complete = true
    elseif stroke.raster_cache ~= cache
        or stroke.raster_generation ~= generation then
        stroke.live_raster_complete = false
    end
end

function Adapter.new(opts)
    opts = opts or {}
    return setmetatable({
        get_mode = opts.get_mode or function() return "auto" end,
        get_pen_width = opts.get_pen_width or function() return 4 end,
        get_eraser = opts.get_eraser or function() return false end,
        eraser_radius = opts.eraser_radius or 18,
        touch_passthrough = opts.touch_passthrough,
        stylus_passthrough = opts.stylus_passthrough,
        on_dirty = opts.on_dirty,
        on_edit_changed = opts.on_edit_changed,
        on_error = opts.on_error,
        on_domain_error = opts.on_domain_error,
        on_physical_contact_end = opts.on_physical_contact_end,
        now = opts.now or time.now,
        get_stylus_trace = opts.get_stylus_trace,
        control_guard = opts.control_guard or time.ms(300),
        max_open_points = opts.max_open_points or Limits.MAX_OPEN_POINTS,
        max_contact_samples = opts.max_contact_samples or Limits.MAX_CONTACT_SAMPLES,
        active_session = nil,
        transform = nil,
        stylus_active = false,
        stylus_pass_latched = false,
        stylus_dominated = false,
        stylus_geom_latched = false,
        stylus_suspended = false,
        stylus_inked = false,
        stylus_slot = nil,
        stylus_tool = nil,
        last_lift_x = nil,
        last_lift_y = nil,
        stale_down = false,
        last_stylus_lift_time = nil,
        stroke = nil,
        erase_ctx = nil,
        erase_radius = nil,
        edit_pending = false,
        contacts = {},
        contact_count = 0,
        finger_slot = nil,
        residual = {},
        physical_contact_active = false,
        trace_instance = nil,
        trace_event_ordinal = 0,
        trace_frame_ordinal = 0,
        stylus_sample_count = 0,
        stylus_budget_notified = false,
        backpressure_notified = false,
        trace_route_reason = nil,
        pending_domain_reason = nil,
        pending_domain_session = nil,
    }, Adapter)
end

function Adapter:configure(opts)
    opts = opts or {}
    local keys = {
        "get_mode", "get_pen_width", "get_eraser", "eraser_radius",
        "touch_passthrough", "stylus_passthrough", "on_dirty",
        "on_edit_changed", "on_physical_contact_end", "on_error",
        "on_domain_error", "get_stylus_trace",
        "now", "control_guard",
    }
    for i = 1, #keys do
        local key = keys[i]
        if opts[key] ~= nil then self[key] = opts[key] end
    end
    return true
end

function Adapter:_markEditChanged()
    self.edit_pending = true
end

function Adapter:_maybeEmitEditChanged()
    if not self.edit_pending or self:hasActiveContact() then return end
    self.edit_pending = false
    if self.on_edit_changed then self.on_edit_changed(self.active_session) end
end

function Adapter:_markPhysicalContact()
    self.physical_contact_active = true
end

function Adapter:_maybeEmitPhysicalContactEnd(reason, session)
    if not self.physical_contact_active or self:hasActiveContact(session) then
        return false
    end
    self.physical_contact_active = false
    if self.on_physical_contact_end then
        self.on_physical_contact_end(session or self.active_session, reason)
    end
    return true
end

function Adapter:presentDirtyBox(box, kind, session)
    if session and self.active_session ~= session then return nil, "stale_session" end
    self:_dirty(box, kind or "repair")
    return true
end

function Adapter:_surface()
    return self.active_session and self.active_session:surface() or nil
end

function Adapter:_dirty(box, kind)
    if box and self.on_dirty then
        local sx, sy = self.transform:fromCache(box.x, box.y)
        local visible = self.transform:visibleCanvasRect()
        local left = math.max(sx, visible.x)
        local top = math.max(sy, visible.y)
        local right = math.min(sx + box.w, visible.x + visible.w)
        local bottom = math.min(sy + box.h, visible.y + visible.h)
        if right <= left or bottom <= top then return end
        local screen_box = Geom:new{
            x = left, y = top, w = right - left, h = bottom - top,
        }
        local source_box = {
            x = box.x + left - sx,
            y = box.y + top - sy,
            w = screen_box.w,
            h = screen_box.h,
        }
        self.on_dirty(screen_box, kind, self.active_session,
            self.transform, source_box)
    end
end

function Adapter:_accepts(sx, sy)
    return self.transform and self.transform:contains(sx, sy)
end

function Adapter:_passesTouch(sx, sy)
    if self.touch_passthrough then
        return self.touch_passthrough(sx, sy, self.active_session,
            self.transform) and true or false
    end
    return not self:_accepts(sx, sy)
end

function Adapter:_stylusRegionPasses(sx, sy)
    if self.stylus_passthrough then
        if self.stylus_passthrough(sx, sy, self.active_session,
            self.transform) then return true end
    end
    return false
end

function Adapter:_passesStylus(sx, sy)
    return self:_stylusRegionPasses(sx, sy) or not self:_accepts(sx, sy)
end

function Adapter:_resetInk()
    self.stroke = nil
    self.erase_ctx = nil
    self.erase_radius = nil
end

function Adapter:_discardLiveInk()
    local surface = self:_surface()
    if self.erase_ctx and surface then surface:endErase(self.erase_ctx) end
    if self.stroke and surface then
        local stroke = self.stroke
        local box = surface:repair(stroke.min_x, stroke.min_y,
            stroke.max_x, stroke.max_y, stroke.width)
        self:_dirty(box, "repair")
    end
    self:_resetInk()
end

function Adapter:_beginInk(sx, sy, tool)
    if not self:_accepts(sx, sy) then return false end
    local surface = self:_surface()
    if not surface or not surface:isReady() then return false end
    local cx, cy = self.transform:toCanvas(sx, sy)
    local erasing = tool == Capture.TOOL_ERASER
        or truthy(self.get_eraser, self.active_session)
    if erasing then
        self.erase_ctx = surface:beginErase()
        self.erase_radius = (tonumber(self.eraser_radius) or 18)
            / self.transform.scale
        local box, err = surface:eraseAt(cx, cy, self.erase_radius,
            self.erase_ctx)
        if box then
            self:_dirty(box, "erase")
            self:_markEditChanged()
        end
        if err and self.on_error then self.on_error(err) end
        return true
    end
    -- Preferences describe physical screen pixels. Persist logical width so
    -- Cache's scale multiplication preserves the same visible nib after a
    -- rotation or on a different-sized device.
    local width = (tonumber(self.get_pen_width(self.active_session)) or 4)
        / self.transform.scale
    self.stroke = {
        points = { cx, cy }, n = 1, width = width,
        tool = tonumber(tool) or Capture.TOOL_PEN,
        min_x = cx, min_y = cy, max_x = cx, max_y = cy,
    }
    local box, raster_cache, raster_generation =
        surface:cache():drawSegment(cx, cy, cx, cy, width)
    updateLiveRasterToken(self.stroke, box, raster_cache, raster_generation)
    self:_dirty(box, "ink")
    return true
end

function Adapter:_continueInk(sx, sy, tool)
    if not self:_accepts(sx, sy) then return nil, "outside" end
    local surface = self:_surface()
    if not surface or not surface:isReady() then return nil, "not_ready" end
    local cx, cy = self.transform:toCanvas(sx, sy)
    if self.erase_ctx then
        local box, err = surface:eraseAt(cx, cy,
            self.erase_radius or (tonumber(self.eraser_radius) or 18)
                / self.transform.scale,
            self.erase_ctx)
        if box then
            self:_dirty(box, "erase")
            self:_markEditChanged()
        end
        if err and self.on_error then self.on_error(err) end
        return true
    end
    local stroke = self.stroke
    if not stroke then return self:_beginInk(sx, sy, tool) end
    local previous_x = stroke.points[stroke.n * 2 - 1]
    local previous_y = stroke.points[stroke.n * 2]
    if cx == previous_x and cy == previous_y then return true end
    if stroke.n >= self.max_open_points then
        self:_discardLiveInk()
        return nil, "point_budget"
    end
    stroke.n = stroke.n + 1
    stroke.points[stroke.n * 2 - 1] = cx
    stroke.points[stroke.n * 2] = cy
    if cx < stroke.min_x then stroke.min_x = cx elseif cx > stroke.max_x then stroke.max_x = cx end
    if cy < stroke.min_y then stroke.min_y = cy elseif cy > stroke.max_y then stroke.max_y = cy end
    local box, raster_cache, raster_generation =
        surface:cache():drawSegment(previous_x, previous_y,
            cx, cy, stroke.width)
    updateLiveRasterToken(stroke, box, raster_cache, raster_generation)
    self:_dirty(box, "ink")
    return true
end

function Adapter:_finishInk()
    local surface = self:_surface()
    if self.erase_ctx then
        if surface then surface:endErase(self.erase_ctx) end
        self.erase_ctx = nil
        return true
    end
    local stroke = self.stroke
    self.stroke = nil
    if not stroke or not surface then return true end
    local id, err, painted, left, top, right, bottom =
        surface:addStroke(stroke.points, stroke.n,
            stroke.width, stroke.tool, {
                raster_cache = stroke.raster_cache,
                raster_generation = stroke.raster_generation,
                live_raster_complete = stroke.live_raster_complete == true,
            })
    if not id then
        local box = surface:repair(stroke.min_x, stroke.min_y,
            stroke.max_x, stroke.max_y, stroke.width)
        self:_dirty(box, "repair")
        if err == "queue_backpressure" then
            if not self.backpressure_notified and self.on_error then
                self.backpressure_notified = true
                self.on_error(err)
            end
        elseif self.on_error then
            self.on_error(err or "stroke_failed")
        end
        if err == "operation_too_large" and self.on_domain_error then
            -- Calling releaseDeferred from the stylus callback makes
            -- InkCapture's feed wrapper inert before this same SYN_REPORT is
            -- filtered. Deliver only after the residual frame has run.
            self.pending_domain_reason = err
            self.pending_domain_session = self.active_session
        end
        return nil, err
    end
    self.backpressure_notified = false
    if painted then
        self:_dirty({ x = left, y = top, w = right - left, h = bottom - top },
            "ink")
    end
    self:_markEditChanged()
    return true
end

function Adapter:abort(session)
    if session and self.active_session and session ~= self.active_session then return true end
    local had_contact = self.physical_contact_active or self:hasActiveContact(session)
    local active_session = self.active_session
    -- Contacts already forwarded to GestureDetector have armed its Contact
    -- state and timers. If a resize/error tears down capture before their
    -- physical lift, retire them explicitly rather than suppressing that lift
    -- after the adapter latches are reset.
    if self.stylus_pass_latched and self.stylus_slot ~= nil then
        Capture:dropContact(self.stylus_slot)
    end
    for slot, state in pairs(self.contacts) do
        if state.pass then Capture:dropContact(slot) end
    end
    for slot, pass in pairs(self.residual) do
        if pass then Capture:dropContact(slot) end
    end
    self:_discardLiveInk()
    self.stylus_active = false
    self.stylus_pass_latched = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_inked = false
    self.stylus_slot = nil
    self.stylus_tool = nil
    self.stale_down = false
    self.stylus_sample_count = 0
    self.stylus_budget_notified = false
    self.trace_route_reason = nil
    self.pending_domain_reason = nil
    self.pending_domain_session = nil
    self.contacts = {}
    self.contact_count = 0
    self.finger_slot = nil
    self.residual = {}
    self.physical_contact_active = had_contact and true or false
    self:_maybeEmitPhysicalContactEnd("external_abort", active_session)
    self:_maybeEmitEditChanged()
    self:_resetStylusTraceContactHistory()
    return true
end

function Adapter:hasActiveContact(session)
    if session and self.active_session and session ~= self.active_session then return false end
    return self.stylus_active or self.stylus_pass_latched
        or self.contact_count > 0 or next(self.residual) ~= nil
end

function Adapter:isStylusContactActive()
    return self.stylus_active or self.stylus_pass_latched
end

function Adapter:controlTouchAllowed()
    if self:isStylusContactActive() then return false end
    if self.last_stylus_lift_time ~= nil then
        local now = self.now()
        if now - self.last_stylus_lift_time < self.control_guard then return false end
    end
    return true
end

function Adapter:_legacyStylusTraceState()
    if self.stylus_pass_latched then return "active_pass" end
    if self.stylus_suspended then return "suspended" end
    if self.stylus_active then
        if not self.stylus_geom_latched then return "geometry_pending" end
        if self.stylus_inked then return "active_draw" end
        return "active_block"
    end
    return "idle"
end

local function legacyTraceDelivery(state)
    return state ~= "active_pass" and state ~= "forwarded_wait_lift"
end

function Adapter:_activeStylusTrace()
    local trace = self.get_stylus_trace and self.get_stylus_trace() or nil
    if trace ~= self.trace_instance then
        self.trace_instance = trace
        self.trace_event_ordinal = 0
        self.trace_frame_ordinal = 0
    end
    return trace
end

function Adapter:_resetStylusTraceContactHistory()
    local trace = self:_activeStylusTrace()
    if trace and type(trace.resetContactHistory) == "function" then
        trace:resetContactHistory()
    end
end

function Adapter:_deliverPendingDomainError()
    local reason, session = self.pending_domain_reason,
        self.pending_domain_session
    self.pending_domain_reason = nil
    self.pending_domain_session = nil
    if reason and self.on_domain_error then
        self.on_domain_error(reason, session)
    end
end

function Adapter:_recordLegacyStylusTrace(trace, slot_number, id, tool,
        x, y, timev, before_state, before_delivery, delivery, decision, reason)
    self.trace_event_ordinal = self.trace_event_ordinal + 1
    local dx, dy, dt = trace:deltas(slot_number, id, tool, x, y, timev)
    trace:record(self.trace_event_ordinal, self.trace_frame_ordinal + 1,
        slot_number, id, tool, x, y, timev,
        before_state, self:_legacyStylusTraceState(),
        before_delivery, delivery, decision, reason, dx, dy, dt)
end

--- Instrument the current route without choosing an unproven geometry policy.
function Adapter:_stylus(slot)
    local trace = self:_activeStylusTrace()
    if not trace then return self:_routeLegacyStylus(slot) end

    local slot_number, id = slot.slot, slot.id
    local x, y, tool, timev = slot.x, slot.y, slot.tool, slot.timev
    local before_state = self:_legacyStylusTraceState()
    local before_delivery = legacyTraceDelivery(before_state)
    local before_owner = self.stylus_slot
    self.trace_route_reason = nil
    local delivery = self:_routeLegacyStylus(slot)
    local after_state = self:_legacyStylusTraceState()
    local decision, reason
    if id == nil then
        decision, reason = "discard", "hover"
    elseif id < 0 then
        if before_owner ~= nil and slot_number ~= before_owner then
            decision, reason = "lift", "foreign_lift"
        elseif before_state == "idle" then
            decision, reason = "discard", "late_lift"
        elseif before_state == "geometry_pending" then
            decision = "lift"
            reason = x ~= nil and y ~= nil and "pending_dot" or "pending_discard"
        else
            decision, reason = "lift", "owner_lift"
        end
    elseif before_owner ~= nil and slot_number ~= before_owner then
        decision, reason = "discard", "foreign_slot"
    elseif delivery == false then
        decision, reason = "pass", "route_pass"
    elseif after_state == "geometry_pending" then
        decision, reason = "pending", "geometry_pending"
    elseif after_state == "suspended" then
        if self.trace_route_reason == "point_budget"
            or self.trace_route_reason == "sample_budget" then
            decision, reason = "abort_budget", self.trace_route_reason
        else
            decision, reason = "suspend", "abort_suspend"
        end
    elseif after_state == "active_draw" then
        decision = before_state == "active_draw" and "append" or "begin"
        reason = "accepted"
    elseif after_state == "active_block" then
        decision, reason = "accept", "route_block"
    else
        decision, reason = "accept", "route_draw"
    end
    self:_recordLegacyStylusTrace(trace, slot_number, id, tool, x, y, timev,
        before_state, before_delivery, delivery, decision, reason)
    return delivery
end

function Adapter:_afterLegacyStylusFrame()
    local trace = self:_activeStylusTrace()
    if not trace then return end
    trace:afterFrame()
    self.trace_frame_ordinal = self.trace_frame_ordinal + 1
end
function Adapter:_routeLegacyStylus(slot)
    local id = slot.id
    -- Hover before BTN_TOUCH is not a lift. In particular it must not replace
    -- the previous lift coordinates used to identify sticky contact-down data.
    if id == nil then return true end

    -- A fatal operation from an earlier stylus slot in this SYN is delivered
    -- only after residual filtering. Dominate any remaining positive slots;
    -- they must not start new work or leak into GestureDetector meanwhile.
    if id >= 0 and self.pending_domain_reason then
        self:_markPhysicalContact()
        self.stylus_suspended = true
        self.stylus_dominated = true
        return true
    end

    if id >= 0 then
        self:_markPhysicalContact()
        if self.stylus_pass_latched then return false end
        if not self.stylus_active then
            self.stylus_active = true
            self.stylus_slot = slot.slot
            self.stylus_sample_count = 0
            self.stylus_budget_notified = false
            self.stylus_dominated = false
            self.stylus_geom_latched = false
            self.stylus_suspended = false
            self.stylus_inked = false
            self.stale_down = slot.x ~= nil and slot.y ~= nil
                and slot.x == self.last_lift_x and slot.y == self.last_lift_y
        elseif slot.slot ~= self.stylus_slot then
            return false
        end

        if self.stylus_sample_count >= self.max_contact_samples then
            if not self.stylus_suspended then
                self:_discardLiveInk()
                self.stylus_suspended = true
                self.trace_route_reason = "sample_budget"
                if not self.stylus_budget_notified and self.on_error then
                    self.stylus_budget_notified = true
                    self.on_error("sample_budget")
                end
            end
            self.stylus_dominated = true
            return true
        end
        self.stylus_sample_count = self.stylus_sample_count + 1

        if slot.tool ~= nil and slot.tool ~= Capture.TOOL_FINGER then
            self.stylus_tool = slot.tool
        end
        -- Some Wacom frames carry BTN_TOUCH before ABS_X/Y. Own that frame but
        -- postpone classification; handing it to GestureDetector would create
        -- a contact and arm its hold timer before paper/chrome is known.
        if slot.x == nil or slot.y == nil then
            self.stylus_dominated = true
            return true
        end
        if self.stale_down then
            -- Only the tracking-id frame can carry the previous contact's
            -- sticky coordinates. GestureDetector has not seen that frame,
            -- so the next frame can still become its coherent contact-down,
            -- even when the pen really returned to the exact same pixel.
            self.stale_down = false
            return true
        end

        local sx, sy = Capture.toScreen(slot.x, slot.y)
        if not self.stylus_geom_latched then
            self.stylus_geom_latched = true
            if self:_passesStylus(sx, sy) then
                if not self.stylus_dominated then
                    self.stylus_active = false
                    self.stylus_pass_latched = true
                    return false
                end
                -- A coordinate-less first frame was already dominated. Never
                -- hand that undecidable half-contact back to gestures. A
                -- stale coordinate frame returns earlier without setting the
                -- dominated latch, so its first fresh successor may pass.
                self.stylus_suspended = true
                return true
            end
        end
        -- A modal/control can appear after a contact began. Never flip a
        -- dominated sequence back into GestureDetector mid-contact, but also
        -- never leave live ink underneath the new overlay.
        if not self.stylus_suspended and self.stylus_geom_latched
            and self:_stylusRegionPasses(sx, sy) then
            self:_discardLiveInk()
            self.stylus_suspended = true
        end
        if not self.stylus_suspended then
            local continued, reason
            if self.stroke or self.erase_ctx then
                continued, reason = self:_continueInk(sx, sy, self.stylus_tool)
            else
                continued = self:_beginInk(sx, sy, self.stylus_tool)
            end
            if continued then
                self.stylus_inked = true
            elseif reason == "outside" then
                self:_finishInk()
                self.stylus_suspended = true
            elseif reason == "point_budget" then
                self.stylus_suspended = true
                self.trace_route_reason = reason
                if not self.stylus_budget_notified and self.on_error then
                    self.stylus_budget_notified = true
                    self.on_error(reason)
                end
            end
        end
        self.stylus_dominated = true
        return true
    end

    -- Contact lift. A passthrough sequence stays entirely somebody else's.
    local was_passthrough = self.stylus_pass_latched
    local dominated = not was_passthrough
        and (self.stylus_active or self.stylus_suspended)
    if self.stylus_active and not self.stylus_inked
        and not self.stylus_suspended and slot.x ~= nil and slot.y ~= nil then
        local sx, sy = Capture.toScreen(slot.x, slot.y)
        if not self:_passesStylus(sx, sy) and self:_accepts(sx, sy) then
            self.stylus_inked = self:_beginInk(
                sx, sy, self.stylus_tool or slot.tool) and true or false
        end
    end
    if self.stylus_active and not self.stylus_suspended then self:_finishInk() end
    if slot.x ~= nil and slot.y ~= nil then
        self.last_lift_x, self.last_lift_y = slot.x, slot.y
    end
    self.stylus_active = false
    self.stylus_pass_latched = false
    self.stylus_dominated = false
    self.stylus_geom_latched = false
    self.stylus_suspended = false
    self.stylus_inked = false
    self.stylus_slot = nil
    self.stylus_tool = nil
    self.stale_down = false
    self.stylus_sample_count = 0
    self.stylus_budget_notified = false
    self.last_stylus_lift_time = self.now()
    self:_maybeEmitPhysicalContactEnd("owner_lift", self.active_session)
    self:_maybeEmitEditChanged()
    return dominated
end

function Adapter:_filterResidual(slots)
    local kept = {}
    for i = 1, #slots do
        local event = slots[i]
        if Capture:isStylusSlot(event) then
            kept[#kept + 1] = event
        else
            local key = event.slot or 0
            local down = event.id ~= nil and event.id >= 0
            if down then self:_markPhysicalContact() end
            local pass = self.residual[key]
            if down and pass == nil then
                if event.x ~= nil and event.y ~= nil then
                    local sx, sy = Capture.toScreen(event.x, event.y)
                    pass = self:_passesTouch(sx, sy)
                else
                    pass = false
                end
                self.residual[key] = pass
            end
            if pass then kept[#kept + 1] = event end
            if not down then self.residual[key] = nil end
        end
    end
    self:_maybeEmitPhysicalContactEnd("residual_lift", self.active_session)
    self:_maybeEmitEditChanged()
    return kept
end

function Adapter:_fingerFrame(slots)
    local kept = {}
    for i = 1, #slots do
        local event = slots[i]
        local key = event.slot or 0
        local down = event.id ~= nil and event.id >= 0
        if down then
            self:_markPhysicalContact()
            local state = self.contacts[key]
            if not state then
                local pass = false
                local undecided = event.x == nil or event.y == nil
                if event.x ~= nil and event.y ~= nil then
                    local sx, sy = Capture.toScreen(event.x, event.y)
                    pass = self:_passesTouch(sx, sy)
                end
                -- A coordinate-less down has already been suppressed, so it
                -- cannot later be handed to GestureDetector as a half-contact.
                -- Keep it undecided until geometry arrives, then either draw
                -- on paper or suppress the rest of an outside sequence.
                state = { pass = pass, undecided = undecided,
                    dominated = undecided }
                self.contacts[key] = state
                self.contact_count = self.contact_count + 1
                if not pass and not self.finger_slot and self.contact_count == 1 then
                    if not undecided then self.finger_slot = key end
                elseif not pass and self.contact_count > 1 then
                    self:_discardLiveInk()
                    self.finger_slot = nil
                    for _, contact in pairs(self.contacts) do
                        if not contact.pass then contact.suspended = true end
                    end
                end
            end
            if state.undecided and event.x ~= nil and event.y ~= nil then
                state.undecided = false
                local sx, sy = Capture.toScreen(event.x, event.y)
                if self:_passesTouch(sx, sy) then
                    state.pass = false
                    state.suspended = true
                elseif not self.finger_slot and self.contact_count == 1 then
                    self.finger_slot = key
                elseif self.finger_slot ~= key then
                    self:_discardLiveInk()
                    self.finger_slot = nil
                    for _, contact in pairs(self.contacts) do
                        if not contact.pass then contact.suspended = true end
                    end
                end
            end
            if state.pass then
                kept[#kept + 1] = event
            elseif not state.suspended and self.finger_slot == key
                and event.x ~= nil and event.y ~= nil then
                local sx, sy = Capture.toScreen(event.x, event.y)
                if self.stroke or self.erase_ctx then
                    local ok, reason = self:_continueInk(sx, sy, Capture.TOOL_FINGER)
                    if not ok and reason == "outside" then
                        self:_finishInk()
                        self.finger_slot = nil
                    elseif not ok and reason == "point_budget" then
                        state.suspended = true
                        self.finger_slot = nil
                        if self.on_error then self.on_error(reason) end
                    end
                else
                    self:_beginInk(sx, sy, Capture.TOOL_FINGER)
                end
            end
        else
            local state = self.contacts[key]
            if state and state.pass then kept[#kept + 1] = event end
            if self.finger_slot == key then self:_finishInk(); self.finger_slot = nil end
            if state then
                self.contacts[key] = nil
                self.contact_count = self.contact_count - 1
                if self.contact_count < 0 then self.contact_count = 0 end
            end
        end
    end
    self:_maybeEmitPhysicalContactEnd("finger_lift", self.active_session)
    self:_maybeEmitEditChanged()
    self:_deliverPendingDomainError()
    return kept
end

function Adapter:captureSpec(session, _, transform)
    self:abort()
    self.active_session = session
    self.transform = transform
    local mode = self.get_mode(session)
    local backend = mode
    if backend == "auto" then
        -- Match the reader route: availability of the callback alone does not
        -- prove that the current device exposes a Wacom-compatible stylus.
        backend = Capture:supportsStylus()
            and Device.input and Device.input.wacom_protocol == true
            and "stylus" or "finger"
    end
    if backend ~= "stylus" and backend ~= "finger" then backend = "finger" end
    local spec = {
        backend = backend,
        has_active_contact = function() return self:hasActiveContact(session) end,
        on_error = function(reason)
            self:abort(session)
            if self.on_error then self.on_error(reason) end
        end,
    }
    if backend == "stylus" then
        spec.stylus_handler = function(slot) return self:_stylus(slot) end
        spec.frame_handler = function(slots)
            local kept = self:_filterResidual(slots)
            self:_afterLegacyStylusFrame()
            self:_deliverPendingDomainError()
            return kept
        end
    else
        spec.frame_handler = function(slots) return self:_fingerFrame(slots) end
    end
    return spec
end

return Adapter
