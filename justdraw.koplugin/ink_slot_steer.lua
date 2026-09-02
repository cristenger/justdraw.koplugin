--[[--
ink_slot_steer: one slot cursor per input device.

KOReader's Input keeps a single `cur_slot` for every evdev device it reads,
and writes each ABS event into whichever slot that cursor names
(frontend/device/input.lua @ 60ce80ed, 1064-1074). On a Kindle Scribe two
devices feed it: the Wacom digitizer, which speaks ABS_X/ABS_Y/BTN_TOUCH and
is moved to `pen_slot` only on BTN_TOOL_PEN (757-769); and the capacitive
panel, which speaks ABS_MT_* and omits ABS_MT_SLOT whenever its own slot did
not change (protocol B). Whichever device spoke last owns the cursor, so a
hand resting on the glass steals the pen's frames -- BTN_TOUCH is then ignored
because the slot's tool is not a pen (770-790) and the stroke never exists --
and a pen hovering while the hand comes down hands the pen slot the hand's
id and MT_TOOL_PALM, after which the plugin, trusting the pen slot, erases.
A device log measured 23 of 256 pen-downs lost and 8 strokes erased in four
minutes (scribe-log-analysis-2026-08-28.md).

This module is the missing second cursor. Run before KOReader's handlers on
every event, it moves the cursor to the pen slot for the pen's own codes and
back to the panel's last slot for the panel's, using nothing but
`Input:setupSlotData`, the call KOReader itself makes on ABS_MT_SLOT. It has
no state of its own beyond three counters and the panel's last slot, and it
allocates nothing per event. It is refused wherever ABS_X is not the pen's
alone: off `wacom_protocol`, without a `pen_slot`, and under any touch handler
but the class's generic one -- the reMarkable's handleMixedTouchEv, where the
panel emits ABS_X too (1102-1120), or a snow/phoenix device. ADR-25.
]]

local Steer = {}

-- Linux evdev codes (include/uapi/linux/input-event-codes.h). ABI constants;
-- read from KOReader's own cdefs when they load, literal otherwise.
local codes = {
    EV_SYN = 0, EV_KEY = 1, EV_ABS = 3,
    SYN_DROPPED = 3,
    ABS_X = 0, ABS_Y = 1,
    ABS_MT_SLOT = 0x2f, ABS_MT_TOUCH_MAJOR = 0x30, ABS_MT_TOOL_Y = 0x3d,
    BTN_TOUCH = 0x14a,
    -- Not consulted by the policy (S3 is the whole ABS_MT_* range); exported
    -- so the specs and the conformance probe name the codes they replay.
    ABS_MT_POSITION_X = 0x35, ABS_MT_POSITION_Y = 0x36, ABS_MT_TOOL_TYPE = 0x37,
    ABS_MT_TRACKING_ID = 0x39, BTN_TOOL_PEN = 0x140,
}
do
    local ok, ffi = pcall(require, "ffi")
    if ok and pcall(require, "ffi/linux_input_h") then
        for name in pairs(codes) do
            local got, value = pcall(function() return ffi.C[name] end)
            if got and value ~= nil then codes[name] = tonumber(value) end
        end
    end
end
Steer.codes = codes

--- The touch handler this Input will actually run. inhibitInput parks the
--- real one in _abs_ev_handler and installs voidEv (input.lua 1741-1743).
local function touchHandler(input)
    return input._abs_ev_handler or rawget(input, "handleTouchEv")
end

--[[--
Build the state for one Input, or refuse. `state.active` starts false; the
owner of the capture flips it (ink_capture). Nothing here reads Device.

`generic_handler` is the class's own Input.handleTouchEv, the only handler
under which ABS_X and ABS_Y are the pen's alone. An instance override that is
not it -- handleTouchEvSnow, handleMixedTouchEv, or a device's own -- is
another protocol, and the policy would corrupt it. An override that *is* the
generic (input.lua 1173, snow quirks disabled at runtime) is fine.
]]
function Steer.new(input, generic_handler)
    if type(input) ~= "table" then return nil, "no_input" end
    if input.wacom_protocol ~= true then return nil, "not_wacom" end
    if type(input.pen_slot) ~= "number" then return nil, "no_pen_slot" end
    if type(input.setupSlotData) ~= "function" then return nil, "no_slot_api" end
    local handler = touchHandler(input)
    if handler ~= nil and handler ~= generic_handler then
        return nil, "custom_touch_handler"
    end
    return {
        active = false,
        panel_slot = nil,
        steered_pen = 0,
        steered_panel = 0,
        drops = 0,
        touch_edges = 0,
    }
end

--[[--
The policy. Called for every event before KOReader's own dispatch; must not
allocate and must not raise (the caller wraps it, but a raise here disarms
the whole capture).

S1  ABS_X / ABS_Y / BTN_TOUCH are the pen's: cursor to pen_slot.
S2  ABS_MT_SLOT names the panel's slot: remember it, KOReader does the rest.
S3  any other ABS_MT_* while the pen slot is current: the panel omitted its
    ABS_MT_SLOT (protocol B); cursor back to the panel's last slot.
S4  SYN_DROPPED: the kernel overflowed; count it (KOReader only names it).
S5  every BTN_TOUCH, whichever slot is current, is a transition the pen
    really reported: InkStylusSequence resynchronises on it after a drop,
    because KOReader's `id` cannot show one (ADR-44).
]]
function Steer.apply(state, input, ev)
    if not state.active then return end
    local etype = ev.type
    if etype == codes.EV_ABS then
        local code = ev.code
        if code == codes.ABS_X or code == codes.ABS_Y then
            if input.cur_slot ~= input.pen_slot then
                input:setupSlotData(input.pen_slot)
                state.steered_pen = state.steered_pen + 1
            end
        elseif code == codes.ABS_MT_SLOT then
            state.panel_slot = ev.value
        elseif code >= codes.ABS_MT_TOUCH_MAJOR and code <= codes.ABS_MT_TOOL_Y then
            if input.cur_slot == input.pen_slot then
                input:setupSlotData(state.panel_slot or input.main_finger_slot)
                state.steered_panel = state.steered_panel + 1
            end
        end
    elseif etype == codes.EV_KEY then
        if ev.code == codes.BTN_TOUCH then
            state.touch_edges = state.touch_edges + 1
            if input.cur_slot ~= input.pen_slot then
                input:setupSlotData(input.pen_slot)
                state.steered_pen = state.steered_pen + 1
            end
        end
    elseif etype == codes.EV_SYN and ev.code == codes.SYN_DROPPED then
        state.drops = state.drops + 1
    end
end

function Steer.counts(state)
    return state.steered_pen, state.steered_panel, state.drops, state.touch_edges
end

function Steer.reset(state)
    state.steered_pen = 0
    state.steered_panel = 0
    state.drops = 0
    state.touch_edges = 0
end

return Steer
