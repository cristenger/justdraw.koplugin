--[[--
The geometry policy InkStylusSequence was built to wait for.

KOReader hands the stylus callback its own persistent `ev_slots[n]` table, and
X and Y are written into it independently as the axes arrive. There is no
public "which axes changed in this frame" mask, so a frame can present one
fresh axis paired with the *previous* contact's other axis, and a contact-down
frame that carried only BTN_TOUCH presents both of the previous contact's
coordinates. Drawing from either produces ink the pen never made: a segment
bridging two strokes, or the axis-aligned L a half-fresh pair traces on its way
to becoming coherent. Both were recorded on a Kindle Scribe.

The only evidence available at this boundary is that a coordinate *differs from
the last trusted pen boundary*. So a new contact draws nothing until both axes
have proven themselves against that baseline, and the first pair that has is
the stroke's first point -- never appended to anything earlier. Only trusted
pen contacts move the baseline; a routed palm never reaches this module.

Deliberately absent: a distance threshold, a "skip N samples" rule, a time
cutoff, and any buffer of pending points. A stale pair is indistinguishable
from a real one by magnitude, so a threshold would only trade a page-spanning
false line for a shorter one.

The cost is stated rather than hidden: a contact that never changes one axis --
a perfect horizontal or vertical line, a dot, a same-pixel re-tap -- draws
nothing and finishes as a single dot at its last position. That is the
trade-off this file exists to make, and it is what the physical acceptance
matrix in the remediation plan measures. It applies to ink only: see the
three-way answer in `observe`, which is what keeps controls tappable.

See ADR-22.
]]

local Geometry = {}
Geometry.__index = Geometry

local function finiteNumber(value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

function Geometry.new()
    return setmetatable({
        -- The last trusted pen boundary. Survives a contact, not a lease.
        base_x = nil,
        base_y = nil,
        -- The last finite pair of the contact in progress.
        last_x = nil,
        last_y = nil,
        observations = 0,
        x_fresh = false,
        y_fresh = false,
        accepted = false,
    }, Geometry)
end

--[[--
One accumulated sample, in raw device units -- the same units the baseline was
recorded in, and the reason this runs before rotation.

Three answers, because "may I draw from this?" and "may I decide who this
contact belongs to?" are not the same question:

  * "accept", x, y -- both axes have moved. Coherent; may become ink.
  * "route", x, y  -- at least one axis has moved, so the pair is not wholly
    the previous contact's, but the other axis may still be. Good enough to
    hand the contact to somebody else, never good enough to draw.
  * "pending"      -- every axis still matches the last trusted boundary. This
    is the stale contact-down frame; it means nothing at all.

Dropping "route" would be tidier and wrong. A pen tap whose position happens to
share one axis with the previous contact -- two taps in a row on the same rail
button, or the first contact of a session -- would then be dominated all the
way to its lift and discarded, and the toolbar is the only way out of a
drawing session.
]]
function Geometry:observe(x, y)
    self.last_x, self.last_y = x, y
    if self.accepted then return "accept", x, y, "accepted" end
    self.observations = self.observations + 1

    if self.base_x == nil then
        -- Nothing trusted to compare against: the first pair of a lease could
        -- itself be a leftover, so it becomes the provisional baseline. It may
        -- route, because a session whose first act is tapping a control has to
        -- work, but it may not ink.
        self.base_x, self.base_y = x, y
        return "route", x, y, "axis_both_pending"
    end

    if not self.x_fresh and x ~= self.base_x then self.x_fresh = true end
    if not self.y_fresh and y ~= self.base_y then self.y_fresh = true end
    if self.x_fresh and self.y_fresh then
        self.accepted = true
        return "accept", x, y, "accepted"
    end
    if self.x_fresh then return "route", x, y, "axis_y_pending" end
    if self.y_fresh then return "route", x, y, "axis_x_pending" end
    -- Both axes still match the boundary. Only the frame that *opens* a
    -- contact can be the sticky pair, because it is the one BTN_TOUCH can
    -- reach without any ABS update; if the same position survives into a later
    -- frame of the same contact, the pen really is there. Enough to hand the
    -- contact over -- two taps running on one button -- never enough to draw.
    if self.observations > 1 then return "route", x, y, "axis_both_pending" end
    return "pending", nil, nil, "axis_both_pending"
end

--[[--
The contact ended while still pending.

At most one dot, at the last position actually observed. Never the pending
path, and never a segment from the baseline: the whole point of the pending
state is that nothing proved the pen travelled between the two.

A dot here is not a consolation prize. It is how a tap, a full stop, and a
re-tap on the previous stroke's last pixel keep working.
]]
function Geometry:onLift(x, y)
    x, y = finiteNumber(x), finiteNumber(y)
    if x ~= nil and y ~= nil then
        self.last_x, self.last_y = x, y
    end
    if self.last_x == nil then return "discard", nil, nil, "pending_discard" end
    return "dot", self.last_x, self.last_y, "pending_dot"
end

--[[--
A physical boundary. `clear_history` distinguishes the two kinds.

false is the pen leaving the page: the coordinates it left at are exactly the
ones the next contact-down will present if it presents stale data, so they
become the next baseline.

true is the capture itself going away -- lease replacement, rotation, teardown.
Nothing about the old baseline can be trusted to describe the next one, so the
next contact starts from no baseline at all.
]]
function Geometry:reset(clear_history)
    if clear_history == true then
        self.base_x, self.base_y = nil, nil
    elseif self.last_x ~= nil then
        self.base_x, self.base_y = self.last_x, self.last_y
    end
    self.last_x, self.last_y = nil, nil
    self.observations = 0
    self.x_fresh, self.y_fresh, self.accepted = false, false, false
end

--- Whether a coherent point of the current contact has been accepted.
function Geometry:isAccepted()
    return self.accepted
end

--- The trusted baseline, for tests and diagnostics. Two numbers or nil.
function Geometry:baseline()
    return self.base_x, self.base_y
end

return Geometry
