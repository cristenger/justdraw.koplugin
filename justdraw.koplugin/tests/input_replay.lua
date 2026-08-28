--[[--
Per-SYN replay bus for stylus tests.

This models the public boundary used by JustDraw, not Linux evdev translation:
slot tables persist and are mutated field-by-field, only touched slots enter a
frame, every touched slot appears once, and frame order is stable.

Unit mode calls InkStylusSequence directly. Integration mode mirrors
Input:routeStylusEvents and then calls the already wrapped
GestureDetector:feedEvent exactly once; the wrapper owns frame_handler.
]]

local Replay = {}
Replay.__index = Replay

-- pairs() cannot carry an explicit nil. Tests use Replay.NIL when they need to
-- clear a durable slot field.
Replay.NIL = {}

function Replay.new(opts)
    opts = opts or {}
    local mode = opts.mode or (opts.sequence and "unit" or "integration")
    if mode ~= "unit" and mode ~= "integration" then
        error("invalid input replay mode", 2)
    end
    if mode == "unit" and not opts.sequence then
        error("unit replay requires sequence", 2)
    end
    if mode == "integration" and not opts.input then
        error("integration replay requires input", 2)
    end
    return setmetatable({
        mode = mode,
        sequence = opts.sequence,
        input = opts.input,
        capture = opts.capture,
        is_stylus = opts.is_stylus,
        slots = {},
        dirty = {},
        dirty_order = {},
        frame_count = 0,
        last_frame = nil,
        last_kept = nil,
        last_dominated = nil,
        last_deliveries = nil,
        last_gestures = nil,
    }, Replay)
end

function Replay:slot(number)
    local slot = self.slots[number]
    if not slot then
        slot = { slot = number }
        self.slots[number] = slot
    end
    return slot
end

function Replay:_touch(number)
    if not self.dirty[number] then
        self.dirty[number] = true
        self.dirty_order[#self.dirty_order + 1] = number
    end
end

function Replay:set(number, fields)
    local slot = self:slot(number)
    if fields then
        for key, value in pairs(fields) do
            if value == Replay.NIL then
                slot[key] = nil
            else
                slot[key] = value
            end
        end
    end
    self:_touch(number)
    return slot
end

function Replay:clear(number, field)
    local slot = self:slot(number)
    slot[field] = nil
    self:_touch(number)
    return slot
end

function Replay:touch(number)
    local slot = self:slot(number)
    self:_touch(number)
    return slot
end

function Replay:_takeFrame()
    local frame = {}
    for i = 1, #self.dirty_order do
        local number = self.dirty_order[i]
        frame[i] = self:slot(number)
        self.dirty[number] = nil
    end
    self.dirty_order = {}
    self.frame_count = self.frame_count + 1
    self.last_frame = frame
    return frame
end

function Replay:_unit(frame)
    local deliveries = {}
    for i = 1, #frame do
        deliveries[i] = self.sequence:feed(frame[i])
    end
    self.sequence:afterFrame()
    self.last_deliveries = deliveries
    self.last_kept = nil
    self.last_dominated = nil
    self.last_gestures = nil
    return deliveries, frame
end

function Replay:_isStylus(slot)
    if self.is_stylus then return self.is_stylus(slot, self.input) end
    if self.capture then
        return self.capture:isKORoutedStylusSlot(slot, self.input)
    end
    return true
end

function Replay:_integration(frame)
    local input = self.input
    local kept, dominated = {}, {}
    local dominated_indices = {}

    -- Mirror Input:routeStylusEvents exactly where callback lifetime matters:
    -- KOReader guards the singleton once before the loop, then resolves the
    -- table field directly for every stylus slot. If a callback unregisters
    -- itself in-frame, the next stylus slot therefore attempts to call nil.
    if input.stylus_callback and #frame > 0 then
        for i = 1, #frame do
            local slot = frame[i]
            if self:_isStylus(slot)
                and input.stylus_callback(input, slot) then
                dominated_indices[i] = true
            end
        end
    end

    for i = 1, #frame do
        local slot = frame[i]
        if dominated_indices[i] then
            dominated[#dominated + 1] = slot
        else
            kept[#kept + 1] = slot
        end
    end

    local gd = input.gesture_detector
    if not gd or type(gd.feedEvent) ~= "function" then
        error("integration replay requires GestureDetector.feedEvent", 2)
    end
    -- Do not call frame_handler here. InkCapture's wrapper does it once.
    local gestures = gd.feedEvent(gd, kept)
    self.last_kept = kept
    self.last_dominated = dominated
    self.last_gestures = gestures
    self.last_deliveries = nil
    return gestures, kept, dominated
end

function Replay:syn()
    local frame = self:_takeFrame()
    if self.mode == "unit" then return self:_unit(frame) end
    return self:_integration(frame)
end

return Replay
