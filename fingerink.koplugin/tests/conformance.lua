--[[--
Contrast the test harness's assumptions against the KOReader runtime that is
actually installed. Run it under an emulator build's LuaJIT, from inside that
build's directory so KOReader's own package.path resolves; it needs a real
Device, not a running session.

Three outcomes per claim. UNCHECKABLE is a first-class result: the local runtime
may be older than the stylus API, and pretending otherwise is how a suite ends
up proving only what it already believed. A MISMATCH means a stub in
tests/support.lua describes something KOReader does not do -- fix the stub, not
this file.
]]

-- KOReader's own search paths. reader.lua does exactly this before anything
-- else; running from the build directory is what makes it resolvable.
require("setupkoenv")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
-- Device pulls settings in on the way up, and nothing has created the global
-- yet because there is no session here.
_G.G_reader_settings = _G.G_reader_settings
    or LuaSettings:open(DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
local Input = Device.input

local rows = {}
local function claim(name, checkable, ok, detail)
    if not checkable then
        rows[#rows + 1] = { "UNCHECKABLE", name, detail or "API absent in this runtime" }
    elseif ok then
        rows[#rows + 1] = { "OK", name, detail or "" }
    else
        rows[#rows + 1] = { "MISMATCH", name, detail or "" }
    end
end

local gd = Input.gesture_detector

claim("gesture_detector.feedEvent is a function on the instance",
    true, type(gd) == "table" and type(gd.feedEvent) == "function")

claim("GestureDetector exposes getContact and dropContact",
    true, type(gd) == "table"
      and type(gd.getContact) == "function"
      and type(gd.dropContact) == "function")

claim("Screen:getTouchRotation exists",
    true, type(Device.screen.getTouchRotation) == "function")

claim("Input exports the TOOL_TYPE_* constants",
    Input.TOOL_TYPE_PEN ~= nil,
    Input.TOOL_TYPE_FINGER == 0 and Input.TOOL_TYPE_PEN == 1
      and Input.TOOL_TYPE_ERASER == 2 and Input.TOOL_TYPE_HIGHLIGHTER == 3,
    "TOOL_TYPE_PEN = " .. tostring(Input.TOOL_TYPE_PEN))

claim("registerStylusCallback and unregisterStylusCallback exist",
    type(Input.registerStylusCallback) == "function",
    type(Input.unregisterStylusCallback) == "function")

claim("pen_slot is defined",
    Input.pen_slot ~= nil, true, "pen_slot = " .. tostring(Input.pen_slot))

-- The suite's SlotBus models ev_slots as durable tables handed out by
-- reference. If getMtSlot ever returned a fresh table the sticky-id tests would
-- all be proving nothing.
claim("getMtSlot hands out one persistent table per slot",
    type(Input.getMtSlot) == "function",
    type(Input.getMtSlot) == "function"
      and rawequal(Input:getMtSlot(0), Input:getMtSlot(0)))

claim("UIManager:sendEvent exists",
    true, type(require("ui/uimanager").sendEvent) == "function")

-- The whole widget-layer story depends on containers offering events to their
-- children before their own handler.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local order = {}
local Probe = WidgetContainer:extend{}
function Probe:onFingerInkProbe() order[#order + 1] = "parent" end
local probe = Probe:new{
    { handleEvent = function() order[#order + 1] = "child" end },
}
probe:handleEvent(require("ui/event"):new("FingerInkProbe"))
claim("WidgetContainer offers events to children before itself",
    true, order[1] == "child" and order[2] == "parent",
    table.concat(order, " then "))

local bad = 0
for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-56s %s\n", r[1], r[2], r[3]))
    if r[1] == "MISMATCH" then bad = bad + 1 end
end
io.write(string.format("\n%d claims, %d mismatches\n", #rows, bad))
os.exit(bad == 0 and 0 or 1)
