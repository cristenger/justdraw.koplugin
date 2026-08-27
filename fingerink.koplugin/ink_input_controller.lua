--[[--
Process-wide ownership for FingerInk's one input capture.

KOReader exposes one stylus callback, while FileManager and ReaderUI create
separate plugin instances over their lifetimes.  InkCapture owns the hooks;
this module owns the right to install or remove them.  A stale plugin instance
can therefore no longer tear down a newer instance's capture.
]]

local Capture = require("ink_capture")
local logger = require("logger")

local Controller = {
    current = nil,
    generation = 0,
}

local Lease = {}
Lease.__index = Lease

local function captureGone()
    return not Capture.active and Capture.input == nil
        and Capture.gesture_detector == nil
end

function Controller:_normalise()
    if self.current and not self.current.releasing and captureGone() then
        self.current.active = false
        self.current = nil
    end
end

function Controller:acquire(owner, spec)
    self:_normalise()
    if owner == nil or type(spec) ~= "table" then return nil, "bad_owner" end
    if self.current then return nil, "already_installed" end

    local backend = spec.backend
    local lease = setmetatable({
        controller = self,
        owner = owner,
        active = false,
        releasing = false,
        has_active_contact = spec.has_active_contact,
    }, Lease)

    local function onError(err)
        lease.active = false
        lease.releasing = false
        if self.current == lease then self.current = nil end
        if spec.on_error then spec.on_error(err) end
    end

    local ok, reason
    if backend == "stylus" then
        ok, reason = Capture:installStylus(
            spec.stylus_handler, spec.frame_handler, onError)
    elseif backend == "finger" then
        ok, reason = Capture:installFinger(spec.frame_handler, onError)
    else
        return nil, "bad_backend"
    end
    if not ok then return nil, reason end

    self.generation = self.generation + 1
    lease.generation = self.generation
    lease.backend = backend
    lease.active = true
    self.current = lease
    return lease
end

function Controller:activeOwner()
    self:_normalise()
    return self.current and self.current.owner or nil
end

function Controller:activeLease()
    self:_normalise()
    return self.current
end

function Controller:forceRelease(owner, reason)
    local lease = self.current
    if not lease then return true end
    if lease.owner ~= owner then return nil, "not_owner" end
    return lease:release(reason)
end

function Lease:isOwner(owner)
    return self.owner == owner
end

function Lease:hasActiveContact()
    if not self.active or type(self.has_active_contact) ~= "function" then
        return false
    end
    local ok, active = pcall(self.has_active_contact)
    if not ok then
        logger.err("FingerInk: active-contact probe failed:", active)
        return true
    end
    return active and true or false
end

function Lease:release()
    if not self.active and not self.releasing then return true end
    if self.controller.current ~= self then return nil, "not_owner" end
    self.active = false
    self.releasing = false
    Capture:remove()
    if self.controller.current == self then self.controller.current = nil end
    return true
end

-- Use this when the caller may be running inside routeStylusEvents.  The
-- controller remains occupied until InkCapture has unhooked on a safe tick,
-- so another owner cannot install over half-removed wrappers.
function Lease:releaseDeferred(after)
    if not self.active and not self.releasing then return true end
    if self.controller.current ~= self then return nil, "not_owner" end
    if self.releasing then return true end
    self.active = false
    self.releasing = true
    Capture:removeDeferred(function()
        self.releasing = false
        if self.controller.current == self then self.controller.current = nil end
        if after then after() end
    end)
    return true
end

return Controller
