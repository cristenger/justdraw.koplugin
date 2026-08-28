--[[--
The ledger that keeps a Kindle Scribe palm from becoming an eraser.

Linux reports a rejected touch as `MT_TOOL_PALM`, which is the value 2. That is
also KOReader's `TOOL_TYPE_ERASER`, and `Input:routeStylusEvents` routes any
slot whose tool is PEN, ERASER or HIGHLIGHTER -- so on a Scribe a resting hand
arrives at the stylus callback wearing the eraser's number. Trusting the
callback is therefore not the same as trusting the contact, and a physical log
from v2026.07.2 shows the difference costing whole pages of ink to a palm that
ran the erase path.

On Wacom the distinction is available and cheap: the digitizer owns one
dedicated `pen_slot`, and a stylus-valued tool on any other physical slot is a
promoted palm. This module is the one place that decision is remembered, so all
three drawing surfaces answer it identically.

Two things make this a ledger rather than a predicate. A palm is promoted
*mid-contact* -- the slot was an ordinary touch first, may already have been
handed to GestureDetector, and may have armed its hold timer -- so promotion
has to retire that contact exactly once. And the tool may revert to finger
before the hand lifts, at which point KOReader stops routing the slot here and
it reappears in the residual frame; keyed by tracking ID rather than by current
tool, it is still the same palm, and it still ends at its real lift. Missing
that lift is what left `hasActiveContact` stuck true and made Add page a button
that flashed and did nothing.

State is one non-negative tracking ID per active palm slot and a count. No
coordinates, no history, no allocation per sample. It knows nothing about
notebooks, documents, erasing, storage, or widgets. See ADR-22.
]]

local PalmGate = {}
PalmGate.__index = PalmGate

--[[--
  opts.classify      function(slot) -> role, reason   (InkCapture:physicalSlotRole)
  opts.retire_touch  function(slot_number)            host bookkeeping + dropContact
]]
function PalmGate.new(opts)
    opts = opts or {}
    if type(opts.classify) ~= "function" then
        error("wacom palm gate requires a classify function", 2)
    end
    return setmetatable({
        classify = opts.classify,
        retire_touch = opts.retire_touch,
        palms = {},
        count = 0,
    }, PalmGate)
end

local function slotKey(slot)
    -- The same key the hosts use for their residual tables, so a promotion can
    -- always find the touch state it has to retire.
    return slot.slot or 0
end

function PalmGate:_retire(key)
    if self.retire_touch then self.retire_touch(key) end
end

function PalmGate:_open(key, id)
    local previous = self.palms[key]
    if previous == nil then
        self.count = self.count + 1
        self.palms[key] = id
        -- The slot may already be an ordinary contact GestureDetector opened.
        self:_retire(key)
        return "palm_promoted"
    end
    if previous ~= id then
        -- A new non-negative Type-B tracking ID is a new physical generation
        -- on the same slot. Close the stale one and adopt this one.
        self.palms[key] = id
        self:_retire(key)
        return "palm_promoted"
    end
    return "palm_continued"
end

function PalmGate:_close(key)
    if self.palms[key] == nil then return false end
    self.palms[key] = nil
    self.count = self.count - 1
    if self.count < 0 then self.count = 0 end
    return true
end

--[[--
A slot KOReader routed to the stylus callback.

Returns handled=false for anything this gate does not own, which is every
trusted pen frame; the host then feeds InkStylusSequence exactly as before.
For a routed palm it returns handled=true plus the closed trace tokens, and the
caller must dominate the slot -- down frame, hover frame and lift alike.
]]
function PalmGate:routeStylus(slot)
    if not slot then return false end
    local role = self.classify(slot)
    if role ~= "routed_palm" then return false end

    local key = slotKey(slot)
    local id = tonumber(slot.id)
    if id == nil then
        -- Hover before this slot ever carried a tracking id. Nothing to open
        -- and nothing to close; it is still not the pen.
        return true, true, "palm",
            self.palms[key] ~= nil and "palm_continued" or "wacom_non_pen"
    end
    if id < 0 then
        -- A lift closes the generation whatever the tool says, and retires any
        -- touch state defensively: the promotion may have happened in a frame
        -- this gate never saw.
        local tracked = self:_close(key)
        if not tracked then self:_retire(key) end
        return true, true, "palm", "palm_lift"
    end
    return true, true, "palm", self:_open(key, id)
end

--[[--
A slot in the residual frame, after the pen's decision for it is already made.

Returns true when the slot must be withheld from GestureDetector entirely.
False means "not mine": either it was never a palm, or its tracking ID changed,
which makes it a new contact the host must classify from scratch.

The tool is deliberately not consulted for a tracked slot. A promoted palm
whose tool reverts to finger stops being routed to the stylus callback and
turns up here; it is the same hand, and only its lift ends it.
]]
function PalmGate:filterResidual(slot)
    if not slot then return false end
    local key = slotKey(slot)
    local tracked = self.palms[key]
    local id = tonumber(slot.id)

    if tracked == nil then
        -- Not tracked yet. It can still be a promotion this gate has not seen,
        -- if the host's residual filter runs before any stylus callback for it.
        if self.classify(slot) ~= "routed_palm" then return false end
        if id == nil then return true, "wacom_non_pen" end
        if id < 0 then
            self:_retire(key)
            return true, "palm_lift"
        end
        return true, self:_open(key, id)
    end

    if id == nil then return true, "palm_continued" end
    if id < 0 then
        self:_close(key)
        return true, "palm_lift"
    end
    if id ~= tracked then
        -- The palm generation ended without this gate seeing its lift. Hand
        -- the new contact back so the host classifies it from its own rules.
        self:_close(key)
        return false, "palm_lift"
    end
    return true, "palm_continued"
end

--- Whether any physical palm is still down. O(1).
function PalmGate:hasActiveContact()
    return self.count > 0
end

function PalmGate:activeCount()
    return self.count
end

function PalmGate:isTracked(slot_number)
    return self.palms[slot_number] ~= nil
end

--[[--
Forget everything, without inventing lifts.

Contacts already forwarded to GestureDetector were retired at promotion, so
there is nothing left here that owes anyone a callback. Reset is for the
capture going away -- lease replacement, rotation, teardown -- where the next
frame this gate sees belongs to a different epoch entirely.
]]
function PalmGate:reset()
    for key in pairs(self.palms) do self.palms[key] = nil end
    self.count = 0
end

return PalmGate
