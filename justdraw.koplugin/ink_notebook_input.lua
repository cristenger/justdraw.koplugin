--[[--
Hardware-input adapter for a standalone notebook surface.

It deliberately knows no widget.  NotebookWindow provides viewport,
touch-pass-through and dirty-region callbacks; this module turns completed
contacts into InkSurfaceSession operations.

The pen contact machine itself is not here.  Slot ownership, Wacom proximity,
budgets and delivery monotonicity live in InkStylusSequence, the palm ledger in
InkWacomPalm and the axis-coherence rule in InkStylusGeometry, all three shared
with the reader's direct and canvas routes.  A second copy of that logic here
is what let the three surfaces disagree about what a Scribe palm is, so what
remains in this file is only the notebook's own domain: what a point does to a
surface, and when the editor is allowed to hear about it.

The finger backend is unchanged and deliberately separate: it is the
compatibility floor for devices with no pen at all.
]]

local Capture = require("ink_capture")
local Device = require("device")
local Geom = require("ui/geometry")
local time = require("ui/time")
local Limits = require("ink_limits")
local PalmGate = require("ink_wacom_palm")
local Sequence = require("ink_stylus_sequence")
local StylusGeometry = require("ink_stylus_geometry")

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
        -- One contact normalizer, one palm ledger and one geometry policy per
        -- capture lease. Never reused across leases; see captureSpec.
        sequence = nil,
        sequence_factory = nil,
        palm_gate = nil,
        geometry = nil,
        capture_input = nil,
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
        stylus_budget_notified = false,
        backpressure_notified = false,
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
    -- One aggregate boundary per abort. Suppress the sequence's own end so the
    -- editor hears about it exactly once, after every latch is already clear.
    self.physical_contact_active = false
    -- Contacts already forwarded to GestureDetector have armed its Contact
    -- state and timers. If a resize/error tears down capture before their
    -- physical lift, retire them explicitly rather than suppressing that lift
    -- after the adapter latches are reset.
    local sequence = self.sequence
    if sequence then
        local forwarded = sequence:forwardedSlot()
        if forwarded ~= nil then Capture:dropContact(forwarded) end
        sequence:abort("external_abort", true)
        if sequence:isLifecycleBlocked() or sequence:hasForwardedContact() then
            -- The GestureDetector contact could not be reclaimed, normally
            -- because capture is already gone. A stranded owner would keep
            -- hasActiveContact true for as long as this adapter lives, which
            -- is the exact failure this route exists to remove, so the lease's
            -- machine starts over instead.
            self.sequence = self.sequence_factory and self.sequence_factory() or nil
        end
    end
    for slot, state in pairs(self.contacts) do
        if state.pass then Capture:dropContact(slot) end
    end
    for slot, pass in pairs(self.residual) do
        if pass then Capture:dropContact(slot) end
    end
    if self.palm_gate then self.palm_gate:reset() end
    self:_discardLiveInk()
    self.stylus_budget_notified = false
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

--[[--
Is any part of the reader still touching the device?

Every term matters, and each one was a way to answer wrongly. The sequence
covers a trusted pen whether it is drawing or has been handed to the UI; the
palm ledger covers a promoted palm, whose lift the tool-based bookkeeping used
to miss entirely, leaving Add page disabled with nothing on the glass; and the
finger/residual tables cover ordinary touch.
]]
function Adapter:hasActiveContact(session)
    if session and self.active_session and session ~= self.active_session then return false end
    local sequence = self.sequence
    if sequence and (sequence:hasOwnedPhysicalContact()
        or sequence:hasForwardedContact()) then
        return true
    end
    if self.palm_gate and self.palm_gate:hasActiveContact() then return true end
    return self.contact_count > 0 or next(self.residual) ~= nil
end

function Adapter:isStylusContactActive()
    local sequence = self.sequence
    return sequence ~= nil and (sequence:hasOwnedPhysicalContact()
        or sequence:hasForwardedContact())
end

function Adapter:controlTouchAllowed()
    if self:isStylusContactActive() then return false end
    if self.last_stylus_lift_time ~= nil then
        local now = self.now()
        if now - self.last_stylus_lift_time < self.control_guard then return false end
    end
    return true
end

--- Resolve the active bounded trace and hand it to the sequence once per
--- change, so diagnostics costs one comparison per event rather than a
--- formatted line.
function Adapter:_activeStylusTrace()
    local trace = self.get_stylus_trace and self.get_stylus_trace() or nil
    if trace ~= self.trace_instance then
        self.trace_instance = trace
        if self.sequence then self.sequence:setTrace(trace) end
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

-- ------------------------------------------------- stylus domain callbacks

--- Notify a budget stop once per contact. Both budgets mean the same thing to
--- the reader -- the contact never ended -- and repeating it per sample would
--- be worse than saying nothing.
function Adapter:_noteStylusBudget(reason)
    if reason ~= "point_budget" and reason ~= "sample_budget" then return end
    if self.stylus_budget_notified then return end
    self.stylus_budget_notified = true
    if self.on_error then self.on_error(reason) end
end

function Adapter:_stylusContactStart()
    self.stylus_budget_notified = false
    self:_markPhysicalContact()
    return true
end

--[[--
What a trusted pen contact means here, latched for the whole sequence.

"pass" hands the contact to GestureDetector so the rail keeps working; anything
on the paper draws. `coherent` is false when the geometry policy is asking only
whether this contact belongs to somebody else, from a pair it would not draw
from -- nothing here latches, so the answer is the same either way.
]]
function Adapter:_classifyStylus(sx, sy, tool, coherent)
    if self.pending_domain_reason ~= nil then return "block" end
    if self:_passesStylus(sx, sy) then return "pass" end
    local by_tool = tool == Capture.TOOL_ERASER
    -- `coherent` changes no answer here -- nothing latches, so a half-proven
    -- pair gets the same route as a proven one. It does decide *counting*: the
    -- sequence asks again on every pending frame while the geometry is still
    -- unproven, and only the coherent call happens once per contact.
    if by_tool and coherent then
        Capture:noteEraserContact(self.capture_input)
    end
    local erasing = by_tool or truthy(self.get_eraser, self.active_session)
    return "draw", erasing and "erase" or "ink"
end

function Adapter:_stylusPoint(sx, sy, tool, is_first)
    if self.pending_domain_reason ~= nil then return "abort_suspend" end
    -- A modal or the rail can appear over the paper after a contact began.
    -- The contact stays dominated -- handing it back mid-sequence would make
    -- GestureDetector emit a spurious tap -- but it stops leaving ink under
    -- the new overlay.
    if not is_first and self:_stylusRegionPasses(sx, sy) then
        return "abort_suspend"
    end
    if is_first then
        self:_beginInk(sx, sy, tool)
        return "continue"
    end
    local continued, reason = self:_continueInk(sx, sy, tool)
    if continued then return "continue" end
    if reason == "outside" then return "finish_suspend" end
    if reason == "point_budget" then return "abort_suspend" end
    return "continue"
end

function Adapter:_finishStylusInk(reason)
    self:_noteStylusBudget(reason)
    -- A rejected operation reports itself through on_error and, when fatal,
    -- through the deferred domain error; it is not a sequence failure.
    self:_finishInk()
    return true
end

function Adapter:_abortStylusInk(reason)
    self:_noteStylusBudget(reason)
    self:_discardLiveInk()
    return true
end

function Adapter:_stylusContactEnd(reason)
    self.last_stylus_lift_time = self.now()
    -- Logical ink end is not physical contact end: a palm or a finger may
    -- still be down, and the editor must not re-enable anything until the
    -- glass is clear.
    self:_maybeEmitPhysicalContactEnd(reason, self.active_session)
    self:_maybeEmitEditChanged()
    return true
end

--- A touch slot has just been promoted to a palm. Give back everything the
--- ordinary touch route had already granted it, exactly once.
function Adapter:_retireTouchSlot(slot_number)
    local pass = self.residual[slot_number]
    if pass ~= nil then
        self.residual[slot_number] = nil
        -- Only a forwarded contact exists inside GestureDetector; a dominated
        -- one never opened a Contact and has no hold timer to cancel.
        if pass then Capture:dropContact(slot_number) end
    end
    local state = self.contacts[slot_number]
    if state then
        self.contacts[slot_number] = nil
        self.contact_count = self.contact_count - 1
        if self.contact_count < 0 then self.contact_count = 0 end
        if self.finger_slot == slot_number then self.finger_slot = nil end
        if state.pass then Capture:dropContact(slot_number) end
    end
end

-- ------------------------------------------------------------ stylus route

--[[--
One slot KOReader routed to the stylus callback. Returning true dominates it.

The order is the fix. Classification comes first, because a callback
invocation is not proof of pen identity: on Wacom a resting hand is promoted to
MT_TOOL_PALM, whose value is KOReader's ERASER, and it is routed here exactly
like a pen. Only what survives that reaches the contact machine.
]]
function Adapter:_stylus(slot)
    local trace = self:_activeStylusTrace()
    local gate = self.palm_gate
    if gate then
        local handled, _dominate, _decision, reason = gate:routeStylus(slot)
        if handled then
            if trace and self.sequence then
                self.sequence:tracePalm(slot, reason)
            end
            if reason == "palm_lift" then
                self:_maybeEmitPhysicalContactEnd("palm_lift", self.active_session)
                self:_maybeEmitEditChanged()
            elseif reason ~= "wacom_non_pen" then
                -- `wacom_non_pen` is a slot that has never carried a tracking
                -- id. Counting it would invent a contact with nothing on the
                -- glass, and then publish a boundary for it when it never
                -- began.
                self:_markPhysicalContact()
            end
            return true
        end
    end
    local sequence = self.sequence
    if not sequence then return true end
    return sequence:feed(slot)
end

function Adapter:_afterStylusFrame()
    if self.sequence then self.sequence:afterFrame() end
end

--[[--
Residual touch on the pen route, after the stylus decision for this frame.

Three kinds of slot arrive here. A tracked palm is withheld entirely, down
frame and lift alike: forwarding only one half would leave GestureDetector a
contact it never opened or one that never ends. A trusted pen slot handed back
to the UI is not touch at all and must not be counted as one. Everything else
is ordinary touch and keeps the behaviour it always had.
]]
function Adapter:_filterResidual(slots)
    local kept = {}
    local gate = self.palm_gate
    local input = self.capture_input
    for i = 1, #slots do
        local event = slots[i]
        local key = event.slot or 0
        if gate and gate:filterResidual(event) then
            if gate:isTracked(key) then self:_markPhysicalContact() end
        elseif Capture:physicalSlotRole(event, input) == "trusted_stylus" then
            kept[#kept + 1] = event
        else
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

--[[--
Build this lease's contact machine over one Input.

`input` is read once, here, rather than per sample: the slot classifier, the
proximity rule and the finger-tool constant all describe the device we are
about to hook, and re-reading Device.input inside the callback would let a
lease outlive the thing it was built for.
]]
function Adapter:_buildStylusMachine(input)
    self.capture_input = input
    self.geometry = StylusGeometry.new(Capture:penSlotPosition(input))
    self.palm_gate = PalmGate.new{
        classify = function(slot) return Capture:physicalSlotRole(slot, input) end,
        retire_touch = function(slot_number) self:_retireTouchSlot(slot_number) end,
    }
    local spec = {
        wacom_protocol = input ~= nil and input.wacom_protocol == true,
        pen_slot = input and input.pen_slot,
        tool_finger = input and input.TOOL_TYPE_FINGER or 0,
        to_screen = Capture.toScreen,
        max_open_points = self.max_open_points,
        max_contact_samples = self.max_contact_samples,
        geometry = self.geometry,
        classify = function(x, y, tool, coherent)
            return self:_classifyStylus(x, y, tool, coherent)
        end,
        on_contact_start = function() return self:_stylusContactStart() end,
        on_point = function(x, y, tool, is_first)
            return self:_stylusPoint(x, y, tool, is_first)
        end,
        on_finish = function(reason) return self:_finishStylusInk(reason) end,
        on_abort = function(reason) return self:_abortStylusInk(reason) end,
        on_contact_end = function(reason) return self:_stylusContactEnd(reason) end,
        -- Increments two integers; cannot raise inside the raw callback.
        on_pending_finish = function(kind)
            Capture:noteCollapsedContact(kind)
        end,
        on_domain_error = function(reason)
            if self.on_domain_error then
                self.on_domain_error(reason, self.active_session)
            end
        end,
        drop_contact = function(slot) return Capture:dropContact(slot) end,
    }
    self.sequence_factory = function()
        local sequence = Sequence.new(spec)
        sequence:setTrace(self.trace_instance)
        return sequence
    end
    self.sequence = self.sequence_factory()
    return self.sequence
end

function Adapter:captureSpec(session, _, transform)
    -- Clear the factory before aborting: a new lease must not be handed a
    -- machine rebuilt against the previous lease's Input.
    self.sequence_factory = nil
    self:abort()
    self.sequence = nil
    self.palm_gate = nil
    self.geometry = nil
    self.capture_input = nil
    self.active_session = session
    self.transform = transform
    local mode = self.get_mode(session)
    local backend = mode
    local input = Device.input
    if backend == "auto" then
        -- Match the reader route: availability of the callback alone does not
        -- prove that the current device exposes a Wacom-compatible stylus.
        -- A Wacom runtime that does not name its pen slot cannot tell a real
        -- eraser from a promoted palm, so it is not a stylus device either.
        backend = Capture:supportsStylus()
            and input and input.wacom_protocol == true
            and Capture:validateStylusInput(input)
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
        self:_buildStylusMachine(input)
        spec.stylus_handler = function(slot) return self:_stylus(slot) end
        spec.frame_handler = function(slots)
            local kept = self:_filterResidual(slots)
            self:_afterStylusFrame()
            self:_deliverPendingDomainError()
            return kept
        end
    else
        spec.frame_handler = function(slots) return self:_fingerFrame(slots) end
    end
    return spec
end

return Adapter
