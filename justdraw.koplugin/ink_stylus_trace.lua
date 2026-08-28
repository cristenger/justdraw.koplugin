--[[--
Bounded, opt-in tracing for the stylus sequence normalizer.

The trace accepts scalars only and writes each event immediately. It never
retains a mutable KOReader slot table (or any notebook/book identity), so a
later slot mutation cannot rewrite already recorded evidence. Callers should
not construct or call a Trace while diagnostics are disabled; that keeps the
normal input hot path to one nil branch in InkStylusSequence.
]]

local Trace = {}
Trace.__index = Trace

local SOURCES = {
    direct = true,
    epub_canvas = true,
    notebook = true,
}

local STATES = {
    idle = true,
    contact_pending = true,
    geometry_pending = true,
    active_draw = true,
    active_block = true,
    active_pass = true,
    suspended = true,
    proximity_wait = true,
    forwarded_wait_lift = true,
}

local DECISIONS = {
    pending = true,
    accept = true,
    begin = true,
    append = true,
    lift = true,
    split_id = true,
    proximity_out = true,
    suspend = true,
    discard = true,
    abort_budget = true,
    pass = true,
}

-- Never put an arbitrary host/storage error in a coordinate trace. Besides
-- being noisy, it may contain a path or a document identity. The sequence
-- reports the exact error to on_domain_error; the trace uses only this closed
-- vocabulary of physical decisions.
local REASONS = {
    none = true,
    hover = true,
    contact_down = true,
    geometry_pending = true,
    geometry_unverified = true,
    geometry_rejected = true,
    non_finite = true,
    accepted = true,
    foreign_slot = true,
    foreign_lift = true,
    owner_lift = true,
    replacement_id = true,
    tool_change = true,
    wacom_proximity = true,
    late_lift = true,
    route_draw = true,
    route_block = true,
    route_pass = true,
    pending_pass_discard = true,
    drop_succeeded = true,
    drop_failed = true,
    point_budget = true,
    sample_budget = true,
    finish_suspend = true,
    abort_suspend = true,
    domain_error = true,
    external_abort = true,
    reset = true,
    pending_dot = true,
    pending_discard = true,
    invalid_geometry = true,
}

local function positiveInteger(value, fallback)
    value = tonumber(value)
    if not value or value == math.huge or value == -math.huge
        or value < 1 or value ~= math.floor(value) then
        return fallback
    end
    return value
end

local function numberToken(value)
    if value == nil then return "-" end
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return "-"
    end
    return tostring(number)
end

local function closedToken(value, allowed)
    if allowed[value] then return value end
    return "redacted"
end

local function defaultEmit(line)
    require("logger").info(line)
end

function Trace.new(opts)
    opts = opts or {}
    if not SOURCES[opts.source] then
        error("invalid stylus trace source", 2)
    end
    local now = opts.now or os.time
    local started_at = tonumber(now())
    if not started_at then
        error("stylus trace clock must return a number", 2)
    end
    return setmetatable({
        source = opts.source,
        emit = opts.emit or defaultEmit,
        now = now,
        deadline = started_at + positiveInteger(opts.duration_seconds, 60),
        max_events = positiveInteger(opts.max_events, 8192),
        events = 0,
        active = true,
        truncated = false,
        contacts = {},
    }, Trace)
end

function Trace:isActive()
    return self.active
end

function Trace:count()
    return self.events
end

function Trace:_truncate(reason)
    if not self.active then return false end
    self.active = false
    self.truncated = true
    self.contacts = {}
    self.emit("JUSTDRAW-STYLUS trace_truncated=" .. reason)
    return false
end

function Trace:stop(reason)
    if not self.active then return false end
    self.active = false
    self.contacts = {}
    self.emit("JUSTDRAW-STYLUS trace_end="
        .. closedToken(reason or "none", REASONS))
    return false
end

--- Start a new diagnostic contact epoch without stopping the bounded trace.
--- Capture teardown, rotation, and lease replacement may happen without a
--- physical lift. Forgetting the scalar history prevents the next reused
--- Wacom slot/id from producing a synthetic cross-boundary delta.
function Trace:resetContactHistory()
    self.contacts = {}
end

--- Return deltas only within one scalar slot/contact generation.
--- KOReader reuses slot tables, Wacom reuses its fixed pen ID, and a frame may
--- interleave several slots. A lift closes the remembered generation; hover
--- does not mutate it. No mutable KOReader object is retained.
function Trace:deltas(slot, id, tool, x, y, timev)
    local slot_number = tonumber(slot)
    local contact_id = tonumber(id)
    if slot_number == nil or contact_id == nil then return nil, nil, nil end

    local tool_number = tonumber(tool)
    local nx, ny = tonumber(x), tonumber(y)
    local nt = tonumber(timev)
    if nx ~= nil and (nx ~= nx or nx == math.huge or nx == -math.huge) then nx = nil end
    if ny ~= nil and (ny ~= ny or ny == math.huge or ny == -math.huge) then ny = nil end
    if nt ~= nil and (nt ~= nt or nt == math.huge or nt == -math.huge) then nt = nil end

    local prior = self.contacts[slot_number]
    local positive = contact_id >= 0
    local same = prior ~= nil and (not positive
        or (prior.id == contact_id and prior.tool == tool_number))
    local dx = same and nx and prior.x and nx - prior.x or nil
    local dy = same and ny and prior.y and ny - prior.y or nil
    local dt = same and nt and prior.timev and nt - prior.timev or nil

    if positive then
        if not same then
            prior = { id = contact_id, tool = tool_number }
            self.contacts[slot_number] = prior
        end
        if nx ~= nil then prior.x = nx end
        if ny ~= nil then prior.y = ny end
        if nt ~= nil then prior.timev = nt end
    else
        self.contacts[slot_number] = nil
    end
    return dx, dy, dt
end

-- Called with the already-decided transition. The fixed formatting contract is
-- intentional: there is no generic metadata table through which a title, path,
-- xpointer, or mutable slot can accidentally enter the log.
function Trace:record(event_ordinal, frame_ordinal,
        slot, id, tool, x, y, timev,
        state_before, state_after, delivery_before, delivery_after,
        decision, reason, dx, dy, dt)
    if not self.active then return false end
    local now = tonumber(self.now())
    if not now or now >= self.deadline then
        return self:_truncate("time_limit")
    end

    self.events = self.events + 1
    self.emit(string.format(
        "JUSTDRAW-STYLUS source=%s event=%s frame=%s slot=%s id=%s tool=%s"
            .. " x=%s y=%s timev=%s from=%s to=%s delivery_from=%s"
            .. " delivery_to=%s decision=%s reason=%s dx=%s dy=%s dt=%s",
        self.source,
        numberToken(event_ordinal), numberToken(frame_ordinal),
        numberToken(slot), numberToken(id), numberToken(tool),
        numberToken(x), numberToken(y), numberToken(timev),
        closedToken(state_before, STATES), closedToken(state_after, STATES),
        delivery_before and "dominate" or "forward",
        delivery_after and "dominate" or "forward",
        closedToken(decision, DECISIONS),
        closedToken(reason or "none", REASONS),
        numberToken(dx), numberToken(dy), numberToken(dt)))

    if self.events >= self.max_events then
        return self:_truncate("event_limit")
    end
    return true
end

-- Time can expire in a frame with no stylus slot. Hosts call this from the same
-- residual frame hook that advances InkStylusSequence's SYN ordinal.
function Trace:afterFrame()
    if not self.active then return false end
    local now = tonumber(self.now())
    if not now or now >= self.deadline then
        return self:_truncate("time_limit")
    end
    return true
end

return Trace
