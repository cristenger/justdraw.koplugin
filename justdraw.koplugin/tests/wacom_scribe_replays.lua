--[[--
Slot sequences copied from a physical Kindle Scribe recording.

Source: KOReader v2026.07.2-75-g656cb2c27 (commit 656cb2c27d74833d403017e01c
438cb9d5a483c0) on KindleScribe, wacom_protocol true, dedicated pen slot 4,
touch slots 0 and 1. These are the exact numbers behind the palm-becomes-eraser
and the false-line defects, and they are here so those defects stay reproducible
without the log they came from: no test may depend on that file existing.

Nothing but scalar slot data is kept. No timestamps beyond ordering, no
document or notebook identity, no raw log text -- `validate` enforces that, so
a later addition cannot quietly widen what this module carries.

Each fixture is a list of SYN frames; each frame is a list of
`{ slot = n, fields = { ... } }` entries naming only the fields that changed,
because that is exactly how KOReader's persistent `ev_slots` behaves.
]]

local Replays = {}

Replays.RUNTIME = "v2026.07.2-75-g656cb2c27_2026-08-17_kindlehf"
Replays.COMMIT = "656cb2c27d74833d403017e01c438cb9d5a483c0"
Replays.DEVICE = "KindleScribe"
Replays.PEN_SLOT = 4
Replays.TOUCH_SLOTS = { 0, 1 }

-- Values as KOReader exports them; MT_TOOL_PALM shares ERASER's 2, which is
-- the entire reason these fixtures exist.
Replays.TOOL_FINGER = 0
Replays.TOOL_PEN = 1
Replays.TOOL_ERASER = 2

local ALLOWED_FIELDS = {
    slot = true, id = true, x = true, y = true, tool = true, timev = true,
}

--- Refuse anything that is not scalar slot data. Returns true, or nil plus the
--- offending key.
function Replays.validate(frames)
    if type(frames) ~= "table" then return nil, "frames" end
    for f = 1, #frames do
        local frame = frames[f]
        if type(frame) ~= "table" then return nil, "frame" end
        for e = 1, #frame do
            local entry = frame[e]
            if type(entry) ~= "table" or type(entry.slot) ~= "number"
                or type(entry.fields) ~= "table" then
                return nil, "entry"
            end
            for key, value in pairs(entry.fields) do
                if not ALLOWED_FIELDS[key] then return nil, key end
                if type(value) ~= "number" then return nil, key end
            end
        end
    end
    return true
end

--[[--
Two touch slots land as fingers and are promoted to MT_TOOL_PALM mid-contact.

This is what KOReader then routes to the stylus callback, because tool 2 is
its ERASER value. Both slots keep their non-negative tracking IDs across the
promotion, which is what makes them the same physical contacts throughout.
]]
function Replays.palm_promotes_two_touch_slots()
    return {
        { { slot = 0, fields = { id = 30, x = 300, y = 1500, tool = 0 } } },
        { { slot = 1, fields = { id = 31, x = 360, y = 1560, tool = 0 } } },
        { { slot = 0, fields = { x = 305, y = 1508, tool = 2 } } },
        { { slot = 1, fields = { x = 366, y = 1571, tool = 2 } } },
        { { slot = 0, fields = { id = -1 } } },
        { { slot = 1, fields = { id = -1 } } },
    }
end

--[[--
The recorded cross-stroke line.

A pen lift at 456,1903; a palm promotion and lift on slot 0; then a pen
contact-down whose frame carries no ABS update at all, so the slot still
presents 456,1903. The next pen sample is 1756,1752 -- dx 1300, dy -151, which
is the 1304x155 region the device actually refreshed.
]]
function Replays.palm_then_stale_pen_pair()
    return {
        { { slot = 4, fields = { id = 4, x = 452, y = 1899, tool = 1 } } },
        { { slot = 4, fields = { x = 456, y = 1903 } } },
        { { slot = 4, fields = { id = -1 } } },
        { { slot = 0, fields = { id = 40, x = 300, y = 1500, tool = 0 } } },
        { { slot = 0, fields = { tool = 2 } } },
        { { slot = 0, fields = { id = -1 } } },
        { { slot = 4, fields = { id = 5, tool = 1 } } },
        { { slot = 4, fields = { x = 1756, y = 1752 } } },
        { { slot = 4, fields = { id = -1 } } },
    }
end

--[[--
The recorded horizontal-then-vertical L.

Prior boundary 405,894. The new contact repeats it, X moves to 1594 while Y is
still the previous contact's, then Y moves to 1070. The device refreshed
1193x4 and then 4x180: two axis-aligned segments the pen never drew.
]]
function Replays.split_x_then_y()
    return {
        { { slot = 4, fields = { id = 6, x = 401, y = 890, tool = 1 } } },
        { { slot = 4, fields = { x = 405, y = 894 } } },
        { { slot = 4, fields = { id = -1 } } },
        { { slot = 4, fields = { id = 7, tool = 1 } } },
        { { slot = 4, fields = { x = 1594 } } },
        { { slot = 4, fields = { y = 1070 } } },
        { { slot = 4, fields = { id = -1 } } },
    }
end

--[[--
The same defect with the axes the other way round.

Prior boundary 758,1309; Y moves to 660, then X to 1676. Refreshes 4x653 and
then 922x4.
]]
function Replays.split_y_then_x()
    return {
        { { slot = 4, fields = { id = 8, x = 754, y = 1305, tool = 1 } } },
        { { slot = 4, fields = { x = 758, y = 1309 } } },
        { { slot = 4, fields = { id = -1 } } },
        { { slot = 4, fields = { id = 9, tool = 1 } } },
        { { slot = 4, fields = { y = 660 } } },
        { { slot = 4, fields = { x = 1676 } } },
        { { slot = 4, fields = { id = -1 } } },
    }
end

--[[--
The recorded Add page failure, up to the tap.

A touch lands as a finger, is promoted to MT_TOOL_PALM and lifts while still
carrying tool 2 -- so the lift arrives at the stylus callback, not at the
residual frame, which is where the old bookkeeping lost it. `x`/`y` are inside
the paper on the fixtures' 1000x1400 surface so a leak would be visible as ink.
]]
function Replays.palm_promote_and_lift()
    return {
        { { slot = 0, fields = { id = 50, x = 300, y = 900, tool = 0 } } },
        { { slot = 0, fields = { x = 305, y = 908, tool = 2 } } },
        { { slot = 0, fields = { x = 310, y = 915 } } },
        { { slot = 0, fields = { id = -1 } } },
    }
end

--[[--
The same palm, but its tool reverts to finger before the hand lifts.

KOReader stops routing the slot to the stylus callback at that point and it
reappears in the residual frame. Keyed by tracking ID rather than by current
tool, it is still the same palm and it still ends only at its real lift.
]]
function Replays.palm_reverts_before_lift()
    return {
        { { slot = 0, fields = { id = 60, x = 300, y = 900, tool = 0 } } },
        { { slot = 0, fields = { x = 305, y = 908, tool = 2 } } },
        { { slot = 0, fields = { x = 310, y = 915, tool = 0 } } },
        { { slot = 0, fields = { id = -1 } } },
    }
end

--- The physical rear eraser: tool 2 where it is allowed to mean eraser.
function Replays.physical_eraser_on_pen_slot()
    return {
        { { slot = 4, fields = { id = 70, x = 500, y = 500, tool = 2 } } },
        { { slot = 4, fields = { x = 520, y = 530 } } },
        { { slot = 4, fields = { id = -1 } } },
    }
end

return Replays
