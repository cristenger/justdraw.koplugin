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

-- The plugin's own modules, resolved from this file rather than from the
-- working directory: this script is run from inside a KOReader build.
local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local ConformancePolicy = require("conformance_policy")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
-- The two globals reader.lua creates before anything else. Nothing has made
-- them here because there is no session; document/doccache.lua indexes
-- G_defaults at load time and would fail with a bare "attempt to index a nil
-- value" a long way from the cause.
_G.G_defaults = _G.G_defaults or require("luadefaults"):open()
_G.G_reader_settings = _G.G_reader_settings
    or LuaSettings:open(DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
-- reader.lua's third act, and the one the widget claims below need: anything
-- that reaches ui/font asks CanvasContext what device it is on, and an
-- uninitialised one fails as a bare "attempt to call method 'isKindle'".
require("document/canvascontext"):init(Device)
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

claim("Input:routeStylusEvents exists",
    type(Input.routeStylusEvents) == "function",
    type(Input.routeStylusEvents) == "function")

claim("registerStylusCallback and unregisterStylusCallback exist",
    type(Input.registerStylusCallback) == "function",
    type(Input.unregisterStylusCallback) == "function")

claim("pen_slot is defined",
    Input.pen_slot ~= nil, true, "pen_slot = " .. tostring(Input.pen_slot))

-- ---------------------------------------------------------------------
-- The shared slot cursor (ADR-25). Both scenarios are sequences recorded on a
-- Kindle Scribe (crash.log 2026-08-28, lines 71495-71503 and 201452-201473).
-- They run against the *class's* methods on a controlled state: Device.input
-- is the emulator's SDL instance, with its own hooks and handler swaps, and
-- the claims are about the generic code path the Scribe runs.
do
    local ffi = require("ffi")
    local codes_ok = pcall(require, "ffi/linux_input_h")
    local C = ffi.C
    local InputClass = require("device/input")
    local Steer = require("ink_slot_steer")
    local ok_shape = codes_ok
        and type(InputClass.handleTouchEv) == "function"
        and type(InputClass.handleKeyBoardEv) == "function"
        and type(InputClass.registerEventAdjustHook) == "function"
        and type(InputClass.setupSlotData) == "function"

    --- A controlled state that runs the real methods.
    local function realState()
        return setmetatable({
            main_finger_slot = 0, pen_slot = 4, wacom_protocol = true,
            cur_slot = 0, ev_slots = { [0] = { slot = 0 } },
            MTSlots = {}, active_slots = {}, snow_protocol = false,
            stylus_eraser_active = false, stylus_highlighter_active = false,
            eventAdjustHook = InputClass.eventAdjustHook,
            -- Since v2026.07.2 handleKeyBoardEv asks the device whether it is
            -- SDL (frontend/device/input.lua, the barrel-button branch ADR-24
            -- documents). The recorded sequences are a Kindle Scribe's, and a
            -- Scribe answers no.
            device = { isSDL = function() return false end },
        }, { __index = InputClass })
    end
    local function ev(t, c, v) return { type = t, code = c, value = v, time = { sec = 0, usec = 0 } } end
    local function run(state, steer, e)
        if steer then Steer.apply(steer, state, e) end
        if e.type == C.EV_KEY then InputClass.handleKeyBoardEv(state, e)
        else InputClass.handleTouchEv(state, e) end
    end
    --- log 71495-71503: the hand owns the cursor, the pen touches.
    local function penDownUnderHand(with_steer)
        local state = realState()
        local steer = with_steer and Steer.new(state, InputClass.handleTouchEv) or nil
        if steer then steer.active = true end
        run(state, steer, ev(C.EV_KEY, C.BTN_TOOL_PEN, 1))          -- proximity
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_SLOT, 0))           -- the hand
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, 7))
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_POSITION_X, 585))
        run(state, steer, ev(C.EV_ABS, C.ABS_X, 1100))             -- the pen
        run(state, steer, ev(C.EV_ABS, C.ABS_Y, 1579))
        run(state, steer, ev(C.EV_KEY, C.BTN_TOUCH, 1))
        return state
    end
    local lost = ok_shape and penDownUnderHand(false)
    claim("real Input loses a pen-down while a panel slot owns the cursor (the defect)",
        ok_shape, lost and lost.ev_slots[4].id == nil and lost.ev_slots[0].x == 1100,
        ok_shape and string.format("pen id=%s hand x=%s",
            tostring(lost.ev_slots[4].id), tostring(lost.ev_slots[0].x)) or "no handler")
    local kept = ok_shape and penDownUnderHand(true)
    claim("with the slot steer the same sequence lands in the pen slot",
        ok_shape, kept and kept.ev_slots[4].id == 4 and kept.ev_slots[4].x == 1100
            and kept.ev_slots[0].x == 585,
        ok_shape and string.format("pen id=%s x=%s hand x=%s", tostring(kept.ev_slots[4].id),
            tostring(kept.ev_slots[4].x), tostring(kept.ev_slots[0].x)) or "no handler")

    --- log 201452-201473: the pen hovers, the hand's frame omits ABS_MT_SLOT.
    local function handUnderHoveringPen(with_steer)
        local state = realState()
        local steer = with_steer and Steer.new(state, InputClass.handleTouchEv) or nil
        if steer then steer.active = true end
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_SLOT, 1))
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, -1))
        run(state, steer, ev(C.EV_KEY, C.BTN_TOOL_PEN, 1))
        run(state, steer, ev(C.EV_ABS, C.ABS_X, 834))
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_TRACKING_ID, 1))
        run(state, steer, ev(C.EV_ABS, C.ABS_MT_TOOL_TYPE, 2))
        return state
    end
    local clobbered = ok_shape and handUnderHoveringPen(false)
    claim("real Input hands the pen slot the hand's id and palm tool (the defect)",
        ok_shape, clobbered and clobbered.ev_slots[4].id == 1 and clobbered.ev_slots[4].tool == 2,
        ok_shape and string.format("pen id=%s tool=%s", tostring(clobbered.ev_slots[4].id),
            tostring(clobbered.ev_slots[4].tool)) or "no handler")
    local guarded = ok_shape and handUnderHoveringPen(true)
    claim("with the slot steer the hand's frame goes to the panel's last slot",
        ok_shape, guarded and guarded.ev_slots[4].tool == 1 and guarded.ev_slots[1].tool == 2
            and guarded.ev_slots[1].id == 1,
        ok_shape and string.format("pen tool=%s slot1 tool=%s id=%s", tostring(guarded.ev_slots[4].tool),
            tostring(guarded.ev_slots[1].tool), tostring(guarded.ev_slots[1].id)) or "no handler")

    --- The hook contract the install relies on.
    local chained = {}
    local probe = realState()
    if ok_shape then
        InputClass.registerEventAdjustHook(probe, function() chained[#chained + 1] = "a" end)
        InputClass.registerEventAdjustHook(probe, function() chained[#chained + 1] = "b" end)
        probe:eventAdjustHook(ev(C.EV_SYN, 0, 0))
    end
    claim("registerEventAdjustHook chains and offers no way to unregister",
        ok_shape, #chained == 2 and chained[1] == "a" and chained[2] == "b"
            and InputClass.unregisterEventAdjustHook == nil,
        table.concat(chained, ","))
end

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
function Probe:onJustDrawProbe() order[#order + 1] = "parent" end
local probe = Probe:new{
    { handleEvent = function() order[#order + 1] = "child" end },
}
probe:handleEvent(require("ui/event"):new("JustDrawProbe"))
claim("WidgetContainer offers events to children before itself",
    true, order[1] == "child" and order[2] == "parent",
    table.concat(order, " then "))

-- =====================================================================
-- Button's box, against the real widget
--
-- The notebook library and the notebook rail both lay out in outer boxes: a
-- row occupies its slot, the footer occupies the strip left at the bottom.
-- Button does not read `width` and `height` the same way -- it subtracts its
-- chrome from the width but adds it to the height -- and tests/support.lua's
-- stub used to return whatever it was handed, which is how a footer could walk
-- off a Kindle Scribe with every assertion green. ink_notebook_layout does the
-- arithmetic; this is where it is checked against the widget itself.
-- =====================================================================
do
    local Button = require("ui/widget/button")
    local Size = require("ui/size")
    local NotebookLayout = require("ink_notebook_layout")
    local box = Size.item.height_large * 2
    local width = require("device").screen:getWidth()
    local made = Button:new{
        text = "Conformance", width = width, height = box,
        margin = NotebookLayout.BUTTON_MARGIN, padding = Size.padding.button,
    }
    local size = made:getSize()
    claim("Button treats `width` as the widget's own width",
        true, size.w == width, size.w .. " for a requested " .. width)
    claim("Button treats `height` as the label box, not the widget's height",
        true, size.h == box + NotebookLayout.buttonChrome(),
        size.h .. " for a requested " .. box .. " plus a computed chrome of "
            .. NotebookLayout.buttonChrome())

    -- And the correction, end to end: ask for a label box sized so the widget
    -- lands on the budget, and it has to land on it exactly.
    local fitted = Button:new{
        text = "Conformance", width = width,
        height = NotebookLayout.buttonLabelHeight(box),
        margin = NotebookLayout.BUTTON_MARGIN, padding = Size.padding.button,
    }
    claim("buttonLabelHeight makes a Button occupy the budget it was given",
        true, fitted:getSize().h == box,
        fitted:getSize().h .. " for a budget of " .. box)

    -- ink_bar borrows Button's checkmark glyph for its label-carried tool
    -- check, and tests/support.lua's stub hardcodes the same constant. If the
    -- widget ever stops exposing it, the stub is lying and the toolbar would
    -- concatenate nil on a device.
    claim("Button exposes the checkmark constant the toolbar labels borrow",
        true, type(Button.checkmark) == "string",
        tostring(Button.checkmark))
end

-- =====================================================================
-- Blitbuffer color constants the style table names
--
-- ink_style.lua maps marker and graphite onto named grays, and the fakes
-- stand in for them as strings. If the real module ever drops one, the
-- fake is lying and every styled stroke would paint nil on a device.
-- =====================================================================
do
    local Blitbuffer = require("ffi/blitbuffer")
    -- rawequal, never ~= nil: a real colour is cdata whose __eq indexes its
    -- argument, so comparing one to nil raises — the exact trap this file
    -- states against BB.COLOR_GRAY further down.
    claim("Blitbuffer exposes COLOR_LIGHT_GRAY for the marker",
        true, not rawequal(Blitbuffer.COLOR_LIGHT_GRAY, nil), "COLOR_LIGHT_GRAY")
    claim("Blitbuffer exposes COLOR_GRAY_6 for graphite",
        true, not rawequal(Blitbuffer.COLOR_GRAY_6, nil), "COLOR_GRAY_6")
end

-- =====================================================================
-- Viewport clipping, against a real BlitBuffer
--
-- The canvas paints live ink and repairs erased regions through
-- `BlitBuffer:viewport`, and the whole reason that is safe is that the buffer
-- bounds a write rather than trusting the caller's arithmetic. Clipping the
-- refresh rectangle alone would not stop the pixels. If this ever came back as
-- a MISMATCH, the canvas would be scribbling over the reader's text.
-- =====================================================================

do
    local BB = require("ffi/blitbuffer")
    local Render = require("ink_render")
    local WHITE, BLACK = BB.COLOR_WHITE, BB.COLOR_BLACK
    local canvas = BB.new(100, 100, BB.TYPE_BB8)
    canvas:fill(WHITE)

    local view = canvas:viewport(20, 20, 30, 30)

    claim("BlitBuffer:viewport reports the size it was asked for",
        true, view:getWidth() == 30 and view:getHeight() == 30,
        view:getWidth() .. "x" .. view:getHeight())

    -- A write inside the viewport lands in the parent, offset.
    view:paintRect(0, 0, 5, 5, BLACK)
    claim("a write inside a viewport lands in the parent at the offset",
        true, canvas:getPixel(20, 20) == BLACK and canvas:getPixel(19, 19) == WHITE,
        "no separate buffer is allocated")

    -- A write that starts outside is clipped to the part that is inside.
    view:paintRect(-10, -10, 12, 12, BLACK)
    claim("a viewport clips a write that starts before its origin",
        true, canvas:getPixel(10, 10) == WHITE,
        "the part outside is dropped, not wrapped")

    -- A write wholly past the far edge is dropped entirely.
    view:paintRect(40, 40, 10, 10, BLACK)
    claim("a viewport drops a write wholly past its far edge",
        true, canvas:getPixel(60, 60) == WHITE and canvas:getPixel(99, 99) == WHITE)

    canvas:free()

    -- Exercise the production renderer against the real FFI buffer as well as
    -- the recording fake used by the unit suite. A regression that moves the
    -- DDA clip after iteration would make this crossing effectively unbounded;
    -- a regression that forwards raw coordinates could wrap or escape here.
    local rendered = BB.new(32, 32, BB.TYPE_BB8)
    rendered:fill(WHITE)
    local painted, left, top, right, bottom = Render.segment(
        rendered, -1e9, 16, 1e9, 16, 3, BLACK)
    claim("Render.segment clips an extreme crossing on a real BlitBuffer",
        true, painted and left == 0 and right == 32
            and top >= 0 and bottom <= 32 and bottom > top
            and rendered:getPixel(0, 16) == BLACK
            and rendered:getPixel(31, 16) == BLACK
            and rendered:getPixel(0, 0) == WHITE
            and rendered:getPixel(31, 31) == WHITE,
        string.format("painted=%s coverage=%s,%s..%s,%s",
            tostring(painted), tostring(left), tostring(top),
            tostring(right), tostring(bottom)))

    local overflow, overflow_left, overflow_top,
        overflow_right, overflow_bottom = Render.segment(
            rendered, -1e308, 8, 1e308, 8, 3, BLACK)
    claim("Render.segment rejects overflow arithmetic on a real BlitBuffer",
        true, overflow == false and overflow_left == nil
            and overflow_top == nil and overflow_right == nil
            and overflow_bottom == nil,
        "no invalid geometry reaches the FFI paint boundary")
    rendered:free()

    --[[--
    Why `ink_paper` never writes `color == nil`.

    A real colour is cdata whose `__eq` calls `color:getColorRGB32()` on its
    argument, and LuaJIT dispatches that metamethod even when the other side
    is nil -- so the ordinary-looking guard raises instead of answering. The
    unit suite cannot see this: `tests/support.lua` uses plain strings for
    colours, where `== nil` is simply false. This states the real behaviour,
    and then that the renderer survives it.
    ]]
    local comparable = pcall(function() return BB.COLOR_GRAY == nil end)
    claim("a real BlitBuffer colour cannot be compared to nil",
        true, comparable == false,
        "so a nil-colour guard must use rawequal")

    local Paper = require("ink_paper")
    local ruled = BB.new(64, 64, BB.TYPE_BB8)
    ruled:fill(WHITE)
    local ok, marked = pcall(Paper.paint, ruled, "ruled", 1,
        0, 0, 64, 64, BB.COLOR_GRAY)
    local guarded, unmarked = pcall(Paper.paint, ruled, "ruled", 1,
        0, 0, 64, 64, nil)
    claim("ink_paper rules a real BlitBuffer and refuses a nil colour without raising",
        true, ok and marked == true and guarded and unmarked == false
            and ruled:getPixel(0, 48) == BB.COLOR_GRAY
            and ruled:getPixel(0, 40) == WHITE,
        string.format("painted=%s guarded=%s", tostring(marked), tostring(guarded)))
    ruled:free()

    --[[--
    The four KOReader behaviours the modal-close fix rests on (ADR-28).

    All of them belong to KOReader, not to us, and none is visible to
    tests/support.lua, whose dialog stubs are bare tables and whose UIManager
    is a stand-in.
    ]]
    local UIManagerReal = require("ui/uimanager")
    local ButtonDialogReal = require("ui/widget/buttondialog")
    local ConfirmBoxReal = require("ui/widget/confirmbox")
    local WidgetContainerReal = require("ui/widget/container/widgetcontainer")
    local EventReal = require("ui/event")

    local notified = 0
    -- A real container, not a bare table: close() dispatches FlushSettings and
    -- CloseWidget through handleEvent, which only widgets have.
    local absent = WidgetContainerReal:new{}
    absent.onCloseWidget = function() notified = notified + 1 end
    local saved_stack, saved_dirty = UIManagerReal._window_stack, UIManagerReal._dirty
    UIManagerReal._window_stack, UIManagerReal._dirty = {}, {}
    UIManagerReal:close(absent)
    UIManagerReal._window_stack, UIManagerReal._dirty = saved_stack, saved_dirty
    claim("UIManager:close notifies a widget that is no longer on the stack",
        true, notified == 1,
        "so a second close refreshes with nothing repainting behind it")

    local cancels, self_closed = 0, false
    local probe_box = ConfirmBoxReal:new{
        text = "conformance probe",
        cancel_callback = function() cancels = cancels + 1 end,
    }
    local real_close = UIManagerReal.close
    UIManagerReal.close = function(_, w) if w == probe_box then self_closed = true end end
    probe_box:onClose()
    UIManagerReal.close = real_close
    claim("ConfirmBox closes itself on dismissal, so a cancel_callback must not",
        true, cancels == 1 and self_closed,
        "onClose runs cancel_callback and then closes, unconditionally")

    claim("a dialog's own close refresh exists for ButtonDialog and ConfirmBox alike",
        true, type(ButtonDialogReal.onCloseWidget) == "function"
            and type(ConfirmBoxReal.onCloseWidget) == "function",
        "the modes differ (flashui vs ui); ADR-28 stops depending on either")

    local reached = false
    local container = WidgetContainerReal:new{}
    container.onCloseWidget = function() reached = true end
    container:handleEvent(EventReal:new("CloseWidget"))
    claim("CloseWidget reaches an instance-level onCloseWidget through the container",
        true, reached,
        "propagateEvent stops only on a true return, so our chained handler runs")

    --[[--
    Why the modal cleanup passes no region.

    `mxc_update` fences a request against the update still in flight only for a
    REAGL mode, for GC16 itself, or for a flashing UI update that covers the
    whole screen. On MTK `waveform_flashui` is `waveform_ui` is AUTO, so a
    regional flash is none of the three -- which is what left the DU highlight
    of a tapped button racing it. This states the two halves that make the
    full-screen form necessary; both are read from the framebuffer the running
    device actually built.
    ]]
    local fb = Device.screen
    local has_wf = fb.waveform_flashui ~= nil and fb.waveform_full ~= nil
    claim("this device's flashui waveform is distinguishable from its full one",
        has_wf, has_wf and fb.waveform_flashui ~= nil,
        has_wf and ("flashui=" .. tostring(fb.waveform_flashui)
            .. " full=" .. tostring(fb.waveform_full)
            .. " ui=" .. tostring(fb.waveform_ui)) or "no mxcfb waveforms here")
    claim("a full-screen refresh region is what _isFullScreen recognises",
        type(fb._isFullScreen) == "function",
        type(fb._isFullScreen) == "function"
            and fb:_isFullScreen(fb:getWidth(), fb:getHeight())
            and not fb:_isFullScreen(fb:getWidth() - 1, fb:getHeight() - 1),
        "so setDirty with no region is the form that earns the fence")
end

-- =====================================================================
-- Where the menu entry lands, against the real MenuSorter
--
-- `addToMainMenu` hands KOReader an id its menu order has never heard of, so
-- the entry is an orphan and `sorting_hint` is the only thing deciding where it
-- goes. Two claims from KOReader hold that up: "tools" names a top-level button
-- in both shipped orders, and MenuSorter's orphan pass resolves a hint that
-- names a tab rather than a submenu. Neither is stated anywhere but in the
-- sorter's own lookup, and if the first stopped being true the sorter would
-- raise on a nil menu rather than misplace the entry -- during menu build, in
-- the reader, on the device.
--
-- The plugin's half of the contract -- that it sends "tools" -- is asserted in
-- tests/notebook_host_spec.lua. This is KOReader's half.
-- =====================================================================

do
    local MenuSorter = require("ui/menusorter")
    local HINT = "tools"
    local PROBE = "justdraw_conformance_probe"

    -- Build the item table the way ReaderMenu does: one entry per id the order
    -- names, so the sorter has a whole tree to place the orphan into.
    local function landsOn(order_name)
        local order = require(order_name)
        local items = { ["KOMenu:menu_buttons"] = {} }
        for id in pairs(order) do
            if id ~= "KOMenu:menu_buttons" and id ~= "KOMenu:disabled" then
                items[id] = { text = id, icon = "appbar.menu" }
            end
        end
        items[PROBE] = { text = "JustDraw", sorting_hint = HINT }
        local ok, tabs = pcall(MenuSorter.sort, MenuSorter, items, order)
        if not ok then return nil, tostring(tabs) end
        for _, tab in ipairs(tabs) do
            for _, item in ipairs(tab) do
                if type(item) == "table" and item.id == PROBE then
                    return tab.id, item.text
                end
            end
        end
        return nil, "the entry was dropped"
    end

    for _, order_name in ipairs({
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }) do
        local tab, detail = landsOn(order_name)
        claim("menu: '" .. HINT .. "' is the tab itself in " .. order_name:match("([^/]+)$"),
            true,
            -- A resolved hint also means no rename: MenuSorter prefixes an
            -- orphan it had to guess a home for with "NEW: ".
            tab == HINT and detail == "JustDraw",
            tab and ("landed on " .. tostring(tab) .. ", labelled " .. tostring(detail))
                or tostring(detail))
    end
end

-- =====================================================================
-- Rename compatibility, against KOReader's real lfs and LuaSettings
-- =====================================================================

do
    local Compat = require("ink_compat")
    local seed = os.tmpname()
    os.remove(seed)
    local dir, base = seed:match("^(.*)/([^/]+)$")
    local current_name = base .. "-justdraw.sqlite3"
    local legacy_name = base .. "-fingerink.sqlite3"
    local current_path = dir .. "/" .. current_name
    local legacy_path = dir .. "/" .. legacy_name

    local legacy_file = assert(io.open(legacy_path, "wb"))
    legacy_file:write("legacy")
    legacy_file:close()
    claim("rename: real lfs selects one existing legacy database",
        true, Compat.databasePath(dir, current_name, legacy_name) == legacy_path)

    local current_file = assert(io.open(current_path, "wb"))
    current_file:write("current")
    current_file:close()
    local selected, reason = Compat.databasePath(dir, current_name, legacy_name)
    claim("rename: two real database files fail closed",
        true, selected == nil and reason == "database_conflict", tostring(reason))
    os.remove(current_path)
    os.remove(legacy_path)

    local settings_path = seed .. "-sidecar.lua"
    local sidecar = LuaSettings:open(settings_path)
    sidecar:saveSetting("fingerink_strokes", {
        [1] = { { n = 2, w = 4, 1, 1, 2, 2 } },
    })
    sidecar:flush()

    local upgraded = LuaSettings:open(settings_path)
    local pages, storage_id = Compat.readDataSetting(upgraded, "strokes")
    pages[2] = { { n = 2, w = 4, 3, 3, 4, 4 } }
    Compat.saveDataSetting(upgraded, "strokes", storage_id, pages)
    upgraded:flush()

    -- Simulate an editable rollback. FingerInk knows only its legacy key and
    -- adds a stroke there before JustDraw is started again.
    local rollback = LuaSettings:open(settings_path)
    local legacy_pages = rollback:readSetting("fingerink_strokes")
    legacy_pages[3] = { { n = 2, w = 4, 5, 5, 6, 6 } }
    rollback:saveSetting("fingerink_strokes", legacy_pages)
    rollback:flush()

    local returned = LuaSettings:open(settings_path)
    local returned_pages, returned_id = Compat.readDataSetting(returned, "strokes")
    Compat.saveDataSetting(returned, "strokes", returned_id, returned_pages)
    returned:flush()
    local final = LuaSettings:open(settings_path)
    local current_ink = final:readSetting("justdraw_strokes")
    local legacy_ink = final:readSetting("fingerink_strokes")
    claim("rename: legacy direct ink stays one in-place table across restarts",
        true, storage_id == "fingerink" and returned_id == "fingerink"
            and current_ink == nil and legacy_ink
            and legacy_ink[1] and legacy_ink[2] and legacy_ink[3]
            and #legacy_ink[2] == 1 and #legacy_ink[3] == 1)
    os.remove(settings_path)
    os.remove(settings_path .. ".old")

    local divergent_path = seed .. "-divergent-sidecar.lua"
    local divergent = LuaSettings:open(divergent_path)
    divergent:saveSetting("justdraw_strokes", {
        [1] = { { n = 2, w = 4, 1, 1, 2, 2 } },
    })
    divergent:saveSetting("fingerink_strokes", {
        [3] = { { n = 2, w = 4, 5, 5, 6, 6 } },
    })
    divergent:flush()
    local active = LuaSettings:open(divergent_path)
    local _, active_id, present = Compat.readDataSetting(active, "strokes")
    Compat.saveDataSetting(active, "strokes", active_id, {})
    active:flush()
    local preserved = LuaSettings:open(divergent_path)
    local empty_current = preserved:readSetting("justdraw_strokes")
    local preserved_legacy = preserved:readSetting("fingerink_strokes")
    claim("rename: empty current tombstone preserves divergent legacy ink",
        true, present and active_id == "justdraw"
            and type(empty_current) == "table" and next(empty_current) == nil
            and preserved_legacy and preserved_legacy[3] ~= nil)
    os.remove(divergent_path)
    os.remove(divergent_path .. ".old")
end

-- =====================================================================
-- The canvas database, against real SQLite
--
-- tests/run.lua drives the repository through a recorder that executes
-- nothing, so this is the only place the schema is ever parsed, a constraint
-- ever fires, and a point blob makes a real round trip. A MISMATCH here means
-- the repository's SQL is wrong, not that a stub is.
-- =====================================================================

local sq3_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")

if not sq3_ok then
    claim("canvas database: SQLite driver is available", false, false,
        "lua-ljsqlite3 did not load")
else
    local Repository = require("ink_canvas_repository")
    local Codec = require("ink_canvas_codec")

    local db_path = os.tmpname() .. ".justdraw-conformance.sqlite3"
    os.remove(db_path)

    local repo, open_err = Repository.open{
        path = db_path,
        driver = SQ3,
        wal = false,   -- a temp file with no sidecars left behind
        now = function() return 1000 end,
    }

    claim("canvas database: the v1 schema is accepted by SQLite",
        true, repo ~= nil, tostring(open_err or db_path))

    if repo then
        local conn = repo.conn

        claim("canvas database: user_version is stamped at the schema version",
            true, tonumber(conn:rowexec("PRAGMA user_version;")) == Repository.SCHEMA_VERSION)

        claim("canvas database: foreign keys are actually enforced",
            true, tonumber(conn:rowexec("PRAGMA foreign_keys;")) == 1)

        -- The hazard the repository's `num` exists for. If this ever comes
        -- back as a Lua number the guard is merely harmless, not wrong.
        local raw = conn:rowexec("SELECT 1;")
        claim("canvas database: INTEGER columns arrive as int64 cdata, not numbers",
            true, type(raw) == "cdata", "type(raw) = " .. type(raw))

        local book_id = repo:bookId("conformance-md5", 4242, "/tmp/book.epub")
        claim("canvas database: a book row is created and its id is a Lua number",
            true, type(book_id) == "number", "book_id = " .. tostring(book_id))

        claim("canvas database: the same book resolves to the same row",
            true, repo:bookId("conformance-md5", 4242, "/tmp/moved.epub") == book_id)

        local canvas = repo:createCanvas(book_id, {
            anchor_kind = "xpointer",
            anchor_key = "xp:/body/DocFragment[3]/body/p[7]/text().0",
            anchor_raw = "/body/DocFragment[3]/body/p[7]/text().0",
            anchor_normalized = "/body/DocFragment[3]/body/p[7]/text().0",
            anchor_dom_version = 20240114,
            logical_w = 1860,
            logical_h = 2480,
        })
        claim("canvas database: a canvas row is created",
            true, canvas ~= nil and type(canvas.id) == "number")

        -- The next two constraints fire on purpose, and the repository logs
        -- an error with a traceback for each. That is correct behaviour and it
        -- buries the report, so it is muted for exactly these two calls.
        local logger = require("logger")
        local real_err = logger.err
        logger.err = function() end

        -- UNIQUE(book_id, anchor_key): the guard against a double tap making
        -- two canvases at one position.
        local dup = repo:createCanvas(book_id, {
            anchor_key = "xp:/body/DocFragment[3]/body/p[7]/text().0",
            logical_w = 1860, logical_h = 2480,
        })
        claim("canvas database: a duplicate anchor is rejected by the schema",
            true, dup == nil)

        claim("canvas database: anchor_kind is constrained",
            true, repo:createCanvas(book_id, {
                anchor_kind = "nonsense", anchor_key = "other",
                logical_w = 10, logical_h = 10 }) == nil)

        logger.err = real_err

        -- A stroke long enough to span chunks, with coordinates that exercise
        -- the whole quantiser range.
        local n = Codec.MAX_POINTS + 77
        local points = {}
        for i = 1, n do
            points[#points + 1] = (i * 7) % 1861
            points[#points + 1] = (i * 13) % 2481
        end
        local stroke_id = repo:addStroke(canvas,
            { seq = 1, width = 4, tool = 1, points = points, n = n })
        claim("canvas database: a multi-chunk stroke is written",
            true, type(stroke_id) == "number", "stroke_id = " .. tostring(stroke_id))

        local chunk_rows = tonumber(conn:rowexec(
            "SELECT count(*) FROM stroke_chunks WHERE stroke_id = " .. tostring(stroke_id)))
        claim("canvas database: it occupies the number of chunks the codec predicts",
            true, chunk_rows == Codec.chunkCount(n),
            tostring(chunk_rows) .. " vs " .. tostring(Codec.chunkCount(n)))

        -- The blob story: a Lua string binds as TEXT even into a BLOB column,
        -- and length() on a TEXT value stops at its first NUL. The CAST on the
        -- way in is what makes this a real blob.
        local kind = conn:rowexec(
            "SELECT typeof(points) FROM stroke_chunks WHERE stroke_id = "
            .. tostring(stroke_id) .. " AND chunk_no = 0")
        claim("canvas database: point payloads are stored as blobs, not as text",
            true, kind == "blob", "typeof = " .. tostring(kind))

        local blob_len = tonumber(conn:rowexec(
            "SELECT length(points) FROM stroke_chunks WHERE stroke_id = "
            .. tostring(stroke_id) .. " AND chunk_no = 0"))
        claim("canvas database: SQL sees the whole payload, not one byte of it",
            true, blob_len == Codec.HEADER + 4 * Codec.MAX_POINTS,
            "length = " .. tostring(blob_len))

        local back, back_n = repo:readStroke(canvas, { id = stroke_id, point_count = n })
        local worst = 0
        if back then
            for i = 1, n do
                local dx = math.abs(back[i * 2 - 1] - points[i * 2 - 1])
                local dy = math.abs(back[i * 2] - points[i * 2])
                if dx > worst then worst = dx end
                if dy > worst then worst = dy end
            end
        end
        claim("canvas database: every point survives the round trip through SQLite",
            true, back ~= nil and back_n == n and worst <= 2480 / 65535 / 2 + 1e-9,
            "n = " .. tostring(back_n) .. ", worst error = " .. tostring(worst))

        local cursor = repo:openStrokeCursor(stroke_id)
        local streamed, streamed_rows, stream_err = 0, 0, nil
        if cursor then
            while true do
                local row, cursor_err, done = cursor:next()
                if cursor_err then stream_err = cursor_err; break end
                if done then break end
                streamed_rows = streamed_rows + 1
                streamed = streamed + row.point_count - (streamed_rows > 1 and 1 or 0)
            end
        end
        claim("canvas database: the cursor streams normalized chunks in order",
            true, cursor ~= nil and streamed_rows == Codec.chunkCount(n)
                and streamed == n and stream_err == nil,
            tostring(streamed_rows) .. " chunks, " .. tostring(streamed)
                .. " points, error = " .. tostring(stream_err))

        -- The layout cache, its composite foreign key, and the prune.
        repo:saveLayoutPages(book_id, "layout-a", { [canvas.id] = 41 })
        local pages = repo:layoutPages(book_id, "layout-a")
        claim("canvas database: a resolved page comes back keyed by canvas id",
            true, pages ~= nil and pages[canvas.id] == 41)

        repo.now = function() return 1001 end
        repo:saveLayoutPages(book_id, "layout-b", { [canvas.id] = 42 })
        repo.now = function() return 1002 end
        repo:saveLayoutPages(book_id, "layout-c", { [canvas.id] = 43 })
        local hashes = tonumber(conn:rowexec(
            "SELECT count(DISTINCT layout_hash) FROM canvas_layout_cache"))
        claim("canvas database: only the two most recent layouts are kept",
            true, hashes == 2, "distinct layouts = " .. tostring(hashes))

        -- Cascades. Deleting the canvas has to take its strokes, its chunks
        -- and its cached pages with it, through the composite key too.
        repo:deleteCanvas(canvas.id)
        local left = tonumber(conn:rowexec("SELECT count(*) FROM strokes"))
            + tonumber(conn:rowexec("SELECT count(*) FROM stroke_chunks"))
            + tonumber(conn:rowexec("SELECT count(*) FROM canvas_layout_cache"))
        claim("canvas database: deleting a canvas cascades to everything it owns",
            true, left == 0, "rows left behind = " .. tostring(left))

        -- PRAGMA user_version has to be transactional, or a rolled-back
        -- migration could leave a stamp claiming work that was undone.
        conn:exec("BEGIN;")
        conn:exec("PRAGMA user_version=999;")
        conn:exec("ROLLBACK;")
        claim("canvas database: a rolled-back version stamp does not stick",
            true, tonumber(conn:rowexec("PRAGMA user_version;")) == Repository.SCHEMA_VERSION,
            "user_version = " .. tostring(conn:rowexec("PRAGMA user_version;")))

        repo:close()

        -- Hold an old read snapshot while a writer appends a WAL frame. A
        -- TRUNCATE checkpoint cannot complete in that state; Repository must
        -- refuse the backup rather than copy only the stale main file.
        local writer = SQ3.open(db_path, "rw")
        writer:exec("PRAGMA journal_mode=WAL;")
        local reader = SQ3.open(db_path, "ro")
        reader:exec("BEGIN;")
        reader:rowexec("SELECT count(*) FROM books;")
        writer:exec("UPDATE books SET updated_at = updated_at + 1;")
        local backups = 0
        local migrated, migration_err = Repository.open{
            path = db_path,
            driver = SQ3,
            wal = true,
            schema_version = Repository.SCHEMA_VERSION + 1,
            migrations = {
                [Repository.SCHEMA_VERSION] = function(conn)
                    conn:exec("CREATE TABLE migration_probe(id INTEGER);")
                end,
            },
            backup = function() backups = backups + 1; return true end,
        }
        claim("canvas database: a busy WAL checkpoint prevents a stale backup",
            true, migrated == nil and migration_err == "migration_checkpoint_failed"
                and backups == 0,
            tostring(migration_err) .. ", backups = " .. tostring(backups))
        if migrated then migrated:close() end
        reader:exec("ROLLBACK;")
        reader:close()
        writer:close()
    end

    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
end

-- =====================================================================
-- Standalone notebook database, against real SQLite
-- =====================================================================

if not sq3_ok then
    claim("notebook database: SQLite driver is available", false, false,
        "lua-ljsqlite3 did not load")
else
    local NotebookRepository = require("ink_notebook_repository")
    local Codec = require("ink_canvas_codec")
    local db_path = os.tmpname() .. ".justdraw-notebooks-conformance.sqlite3"
    os.remove(db_path)

    local notebook_now = 2000
    local repo, open_err = NotebookRepository.open{
        path = db_path, driver = SQ3, wal = false,
        now = function() return notebook_now end,
    }
    claim("notebook database: the v1 schema is accepted by SQLite",
        true, repo ~= nil, tostring(open_err or db_path))

    if repo then
        local conn = repo.conn
        claim("notebook database: version and foreign keys are active", true,
            tonumber(conn:rowexec("PRAGMA user_version;"))
                == NotebookRepository.SCHEMA_VERSION
                and tonumber(conn:rowexec("PRAGMA foreign_keys;")) == 1)

        local notebook, first = repo:createNotebook{
            title = "Conformance", logical_w = 1860, logical_h = 2480,
            template_kind = "ruled",
        }
        claim("notebook database: create atomically returns notebook, page and state",
            true, notebook ~= nil and first ~= nil
                and notebook.current_page_id == first.id
                and tonumber(conn:rowexec("SELECT count(*) FROM notebook_state;")) == 1)

        local second = notebook and repo:appendPage(notebook.id, {
            logical_w = 1860, logical_h = 2480, template_kind = "future-template",
        })
        local read_second = second and repo:getPage(second.id)
        claim("notebook database: append consumes monotonic sort keys and tolerates future templates",
            true, second ~= nil and second.sort_key == 2048
                and read_second.template_kind == "blank",
            second and tostring(second.sort_key) or "append failed")

        -- Re-ruling a page. Strict where creation is permissive: a kind this
        -- build cannot draw must not be accepted here, or the write would
        -- succeed and the page would come back blank with nothing said.
        local ruled = notebook
            and repo:setPageTemplate(notebook.id, first.id, "dots")
        local reread = ruled and repo:getPage(first.id)
        local rejected, reject_reason
        if notebook then
            rejected, reject_reason =
                repo:setPageTemplate(notebook.id, first.id, "future-template")
        end
        local crossed = notebook and second
            and repo:setPageTemplate(notebook.id + 1, first.id, "grid")
        claim("notebook database: a page is re-ruled in place, and only with a drawable kind",
            true, ruled == true and reread ~= nil
                and reread.template_kind == "dots"
                and rejected == nil and reject_reason == "bad_template"
                and crossed == nil,
            "kind = " .. tostring(reread and reread.template_kind)
                .. ", rejected = " .. tostring(reject_reason)
                .. ", cross-notebook = " .. tostring(crossed))

        local ruled_pages = notebook and tonumber(conn:rowexec(
            "SELECT count(*) FROM notebook_pages WHERE template_kind = 'dots';"))
        claim("notebook database: re-ruling one page leaves its siblings alone",
            true, ruled_pages == 1, tostring(ruled_pages) .. " dotted pages")
        if notebook then repo:setPageTemplate(notebook.id, first.id, "blank") end

        local n = Codec.MAX_POINTS + 19
        local points = {}
        for i = 1, n do
            points[#points + 1] = (i * 17) % 1861
            points[#points + 1] = (i * 23) % 2481
        end
        local stroke_id = first and repo:addStroke(first, {
            seq = 1, width = 4, tool = 1, points = points, n = n,
        })
        claim("notebook database: a multi-chunk stroke is written", true,
            type(stroke_id) == "number", tostring(stroke_id))

        if stroke_id then
            local kind, bytes = conn:rowexec([[
                SELECT typeof(points), length(points)
                  FROM notebook_stroke_chunks
                 WHERE stroke_id = ]] .. tostring(stroke_id) .. [[ AND chunk_no = 0;]])
            claim("notebook database: binary point data survives embedded NUL bytes", true,
                kind == "blob" and tonumber(bytes)
                    == Codec.HEADER + 4 * Codec.MAX_POINTS,
                tostring(kind) .. ", " .. tostring(bytes) .. " bytes")

            local cursor = repo:openStrokeCursor(stroke_id)
            local rows_seen, points_seen, cursor_err = 0, 0, nil
            while cursor do
                local row, err, done = cursor:next()
                if err then cursor_err = err; break end
                if done then break end
                rows_seen = rows_seen + 1
                points_seen = points_seen + row.point_count
                    - (rows_seen > 1 and 1 or 0)
            end
            claim("notebook database: cursor streams all chunks and reports clean EOF",
                true, rows_seen == Codec.chunkCount(n) and points_seen == n
                    and cursor_err == nil,
                tostring(rows_seen) .. " chunks, error = " .. tostring(cursor_err))

            local metadata = repo:listStrokes(first.id)
            claim("notebook database: stroke listings contain metadata but no point blobs",
                true, metadata and #metadata == 1 and metadata[1].points == nil)

            repo:deleteStroke(stroke_id)
            claim("notebook database: interactive undo tombstones one row and leaves chunks for purge",
                true, tonumber(conn:rowexec(
                    "SELECT count(*) FROM notebook_strokes WHERE deleted_at IS NOT NULL;")) == 1
                    and tonumber(conn:rowexec(
                    "SELECT count(*) FROM notebook_stroke_chunks;")) == Codec.chunkCount(n))

            local first_batch = repo:purgeDeletedBatch{
                chunks = 1, strokes = 1, pages = 1, notebooks = 1,
            }
            claim("notebook database: one purge call respects its requested bounds",
                true, first_batch and first_batch.chunks <= 1
                    and first_batch.strokes <= 1 and first_batch.pages <= 1
                    and first_batch.notebooks <= 1)
            for _ = 1, Codec.chunkCount(n) + 4 do
                local batch = repo:purgeDeletedBatch{
                    chunks = 1, strokes = 1, pages = 1, notebooks = 1,
                }
                if not batch or batch.changed == 0 then break end
            end
            claim("notebook database: bounded purge resumes until tombstoned ink is gone",
                true, tonumber(conn:rowexec(
                    "SELECT count(*) FROM notebook_strokes WHERE id = "
                    .. tostring(stroke_id))) == 0
                    and tonumber(conn:rowexec(
                    "SELECT count(*) FROM notebook_stroke_chunks WHERE stroke_id = "
                    .. tostring(stroke_id))) == 0)
        end

        if second then
            repo:selectCurrentPage(notebook.id, second.id)
            local selected = repo:softDeletePage(notebook.id, second.id)
            local refused, refuse_err = repo:softDeletePage(notebook.id, first.id)
            claim("notebook database: deleting current page selects a neighbour and keeps the last",
                true, selected and selected.id == first.id
                    and refused == nil and refuse_err == "last_page")
        end

        local function planContains(sql, binds, needle)
            local stmt = conn:prepare("EXPLAIN QUERY PLAN " .. sql)
            if binds then stmt:bind(unpack(binds)) end
            local found = false
            while true do
                local row = stmt:step()
                if not row then break end
                if tostring(row[4]):find(needle, 1, true) then found = true end
            end
            stmt:close()
            return found
        end
        claim("notebook database: library lookup uses its composite index", true,
            planContains([[
                SELECT id FROM notebooks WHERE deleted_at IS NULL
                 ORDER BY updated_at DESC, id DESC LIMIT ?1;]], { 50 },
                "notebooks_active_recent"))
        claim("notebook database: page lookup uses keyset index order", true,
            planContains([[
                SELECT id FROM notebook_pages
                 WHERE notebook_id = ?1 AND deleted_at IS NULL
                 ORDER BY sort_key, id LIMIT ?2;]], { notebook.id, 50 },
                "pages_by_notebook"))
        claim("notebook database: active-page strokes use their page index", true,
            planContains([[
                SELECT id FROM notebook_strokes
                 WHERE page_id = ?1 AND deleted_at IS NULL ORDER BY seq;]],
                { first.id }, "strokes_by_page"))
        claim("notebook database: purge discovery starts at tombstone indexes", true,
            planContains([[
                SELECT p.id
                  FROM notebooks n INDEXED BY notebooks_active_recent
                  CROSS JOIN notebook_pages p INDEXED BY pages_by_notebook
                    ON p.notebook_id = n.id
                 WHERE n.deleted_at IS NOT NULL AND p.deleted_at IS NULL
                 LIMIT ?1;]], { 8 }, "notebooks_active_recent")
            and planContains([[
                SELECT s.id
                  FROM notebook_pages p INDEXED BY pages_deleted
                  CROSS JOIN notebook_strokes s INDEXED BY strokes_by_page
                    ON s.page_id = p.id
                 WHERE p.deleted_at IS NOT NULL AND s.deleted_at IS NULL
                 LIMIT ?1;]], { 32 }, "pages_deleted")
            and planContains([[
                SELECT c.rowid
                  FROM notebook_strokes s INDEXED BY strokes_deleted
                  CROSS JOIN notebook_stroke_chunks c ON c.stroke_id = s.id
                 WHERE s.deleted_at IS NOT NULL LIMIT ?1;]],
                { 64 }, "strokes_deleted")
            and planContains([[
                SELECT p.id
                  FROM notebook_pages p INDEXED BY pages_deleted
                 WHERE p.deleted_at IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_state st
                        WHERE st.current_page_id = p.id)
                 LIMIT ?1;]], { 8 }, "state_by_current_page")
            and planContains([[
                SELECT n.id
                  FROM notebooks n INDEXED BY notebooks_active_recent
                 WHERE n.deleted_at IS NOT NULL LIMIT ?1;]],
                { 1 }, "notebooks_active_recent"))

        -- Populate a genuinely large page set in one setup transaction. The
        -- operation under test remains the public bounded/keyset listing, not
        -- the cost of manufacturing fixture rows one by one.
        conn:exec([[
            INSERT INTO notebooks
                (title, page_count, next_sort_key, created_at, updated_at, deleted_at)
            VALUES ('Scale', 10000, 10241024, 2500, 2500, NULL);
        ]])
        local scale_id = tonumber(conn:rowexec("SELECT last_insert_rowid();"))
        conn:exec([[
            WITH RECURSIVE seq(x) AS (
                VALUES(1) UNION ALL SELECT x + 1 FROM seq WHERE x < 10000
            )
            INSERT INTO notebook_pages
                (notebook_id, sort_key, logical_w, logical_h, template_kind,
                 created_at, updated_at, deleted_at)
            SELECT ]] .. tostring(scale_id) .. [[, x * 1024, 1860, 2480,
                   'blank', 2500, 2500, NULL FROM seq;
        ]])
        conn:exec([[
            INSERT INTO notebook_state (notebook_id, current_page_id)
            SELECT ]] .. tostring(scale_id) .. [[, MIN(id)
              FROM notebook_pages WHERE notebook_id = ]] .. tostring(scale_id) .. [[;
        ]])
        local scale_rows = repo:listPages(scale_id, { limit = 50 })
        local scale_next = scale_rows and repo:listPages(scale_id, {
            after_sort_key = scale_rows[#scale_rows].sort_key,
            after_id = scale_rows[#scale_rows].id,
            limit = 50,
        })
        claim("notebook database: 10,000 real pages remain bounded and keyset-paginated",
            true, tonumber(conn:rowexec(
                "SELECT count(*) FROM notebook_pages WHERE notebook_id = "
                .. tostring(scale_id) .. ";")) == 10000
                and scale_rows and #scale_rows == 50
                and scale_next and #scale_next == 50
                and scale_next[1].sort_key > scale_rows[#scale_rows].sort_key)

        conn:exec([[
            WITH RECURSIVE seq(x) AS (
                VALUES(1) UNION ALL SELECT x + 1 FROM seq WHERE x < 5000
            )
            INSERT INTO notebooks
                (title, page_count, next_sort_key, created_at, updated_at, deleted_at)
            SELECT 'Library scale ' || x, 0, 1024, 20000 + x,
                   20000 + x, NULL FROM seq;
        ]])
        local library_rows = repo:listNotebooks{ limit = 51 }
        local library_next = library_rows and repo:listNotebooks{
            after_updated_at = library_rows[#library_rows].updated_at,
            after_id = library_rows[#library_rows].id,
            limit = 51,
        }
        claim("notebook database: 5,000 real notebooks remain bounded and keyset-paginated",
            true, tonumber(conn:rowexec(
                "SELECT count(*) FROM notebooks WHERE title LIKE 'Library scale %';")) == 5000
                and library_rows and #library_rows == 51
                and library_next and #library_next == 51
                and library_next[1].updated_at < library_rows[#library_rows].updated_at)

        repo:close()
        local writer = SQ3.open(db_path, "rw")
        writer:exec("PRAGMA user_version="
            .. tostring(NotebookRepository.SCHEMA_VERSION + 1) .. ";")
        writer:close()
        local future = NotebookRepository.open{
            path = db_path, driver = SQ3, wal = false,
        }
        local write, write_err
        if future then
            write, write_err = future:createNotebook{
                title = "No write", logical_w = 1, logical_h = 1,
            }
        end
        claim("notebook database: a future schema opens read-only and writes nothing",
            true, future and future.read_only and write == nil
                and write_err == "read_only",
            "future = " .. tostring(future) .. ", read_only = "
                .. tostring(future and future.read_only) .. ", write_err = "
                .. tostring(write_err))
        if future then future:close() end
    end

    -- End-to-end domain lifecycle over a second real connection: create,
    -- draw, append, switch, close, reopen with a new controller instance.
    local lifecycle_path = os.tmpname() .. ".justdraw-notebook-lifecycle.sqlite3"
    os.remove(lifecycle_path)
    local lifecycle_now = 3000
    local first_repo = NotebookRepository.open{
        path = lifecycle_path, driver = SQ3, wal = false,
        now = function() return lifecycle_now end,
    }
    lifecycle_now = 3001
    local created = first_repo and first_repo:createNotebook{
        title = "Lifecycle", logical_w = 1000, logical_h = 1400,
    }
    local NotebookController = require("ink_notebook_controller")
    local first_controller = first_repo and NotebookController.new{
        repository = first_repo,
        schedule = function(fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
    local first_session = created and first_controller:openNotebook(created.id)
    local first_ink = first_session and first_session:surface():addStroke(
        { 10, 10, 20, 20 }, 2, 4, 1)
    local appended = first_session and first_session:appendPage()
    local second_page = first_session and first_session:currentPage()
    lifecycle_now = 3002
    local second_ink = first_session and first_session:surface():addStroke(
        { 30, 30, 40, 40 }, 2, 4, 1)
    local first_closed = first_controller and first_controller:close()
    local first_page_updated, notebook_updated
    if first_repo and created then
        first_page_updated = tonumber(first_repo.conn:rowexec(
            "SELECT updated_at FROM notebook_pages WHERE id = "
            .. tostring(created.current_page_id) .. ";"))
        notebook_updated = tonumber(first_repo.conn:rowexec(
            "SELECT updated_at FROM notebooks WHERE id = "
            .. tostring(created.id) .. ";"))
    end
    if first_repo then first_repo:close() end

    local second_repo = NotebookRepository.open{
        path = lifecycle_path, driver = SQ3, wal = false,
    }
    local second_controller = second_repo and NotebookController.new{
        repository = second_repo,
        schedule = function(fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
    local reopened = created and second_controller:openNotebook(created.id)
    local reopened_strokes = reopened and second_repo:listStrokes(
        reopened:currentPage().id)
    claim("notebook lifecycle: a new controller restores current page and durable ink",
        true, first_ink ~= nil and appended and second_ink ~= nil and first_closed
            and reopened and second_page
            and reopened:currentPage().id == second_page.id
            and reopened_strokes and #reopened_strokes == 1,
        "current page = " .. tostring(reopened and reopened:currentPage().id)
            .. ", strokes = " .. tostring(reopened_strokes and #reopened_strokes))
    claim("notebook lifecycle: committed ink updates page and library recency once per batch",
        true, first_page_updated == 3001 and notebook_updated == 3002,
        "first page = " .. tostring(first_page_updated)
            .. ", notebook = " .. tostring(notebook_updated))
    if second_controller then second_controller:close() end
    if second_repo then second_repo:close() end
    os.remove(lifecycle_path)
    os.remove(lifecycle_path .. "-wal")
    os.remove(lifecycle_path .. "-shm")

    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
end

-- =====================================================================
-- Anchors, against a real CreDocument
--
-- Needs a book, so pass one:
--
--     ./luajit .../conformance.lua /path/to/some.epub
--
-- Without it these come back UNCHECKABLE and the anchor code is covered only
-- by a fake document -- which is exactly the situation this file exists to
-- flag rather than to paper over.
-- =====================================================================

local book = arg and arg[1]

if not book then
    claim("anchors: a real EPUB was supplied", false, false,
        "pass a book path to check the xpointer API")
else
    -- reader.lua does this before it touches a document; without it
    -- doccache.lua asks an uninitialised CanvasContext for the screen width.
    require("document/canvascontext"):init(Device)

    local DocumentRegistry = require("document/documentregistry")
    local Anchor = require("ink_anchor")

    local opened, document = pcall(function()
        local doc = DocumentRegistry:openDocument(book)
        if doc then doc:render() end
        return doc
    end)

    if not opened or not document then
        claim("anchors: the book opens as a CreDocument", true, false,
            tostring(document))
    else
        claim("anchors: the book opens and renders", true, document.been_rendered == true)

        local xp = document:getXPointer()
        claim("anchors: getXPointer returns a pointer to the current position",
            true, type(xp) == "string" and xp ~= "", tostring(xp))

        -- The one that is easy to get wrong: not found is `false`, not nil.
        local normalized = document:getNormalizedXPointer(xp)
        claim("anchors: getNormalizedXPointer answers a string or false",
            true, type(normalized) == "string" or normalized == false,
            "type = " .. type(normalized) .. ", value = " .. tostring(normalized))

        claim("anchors: the document vouches for its own pointer",
            true, document:isXPointerInDocument(xp) == true)

        local page = document:getPageFromXPointer(xp)
        claim("anchors: a pointer resolves to a page number",
            true, type(page) == "number", "page = " .. tostring(page))

        claim("anchors: the current position is on the current page",
            true, document:isXPointerInCurrentPage(xp) == true)

        -- y first, x second. Getting these the wrong way round puts every
        -- margin mark at the left edge and every one of them at the same
        -- height, which looks plausible enough to ship.
        local y, x = document:getScreenPositionFromXPointer(xp)
        claim("anchors: getScreenPositionFromXPointer returns y then x",
            true, type(y) == "number" and type(x) == "number",
            "y = " .. tostring(y) .. ", x = " .. tostring(x))

        claim("anchors: getVisiblePageNumberCount is a number",
            true, type(document:getVisiblePageNumberCount()) == "number",
            tostring(document:getVisiblePageNumberCount()))

        local hash = document:getDocumentRenderingHash(true)
        claim("anchors: the rendering hash is a value and is stable across reads",
            true, hash ~= nil and hash == document:getDocumentRenderingHash(true),
            "hash = " .. tostring(hash))

        -- And the plugin's own use of all of it.
        local spec, err = Anchor.forCurrentPosition(document, 20240114)
        claim("anchors: an anchor can be made at the reader's position",
            true, spec ~= nil and type(spec.anchor_key) == "string",
            spec and spec.anchor_key or tostring(err))

        if spec then
            claim("anchors: the anchor resolves back to a pointer the document knows",
                true, Anchor.resolve(document, {
                    anchor_kind = "xpointer",
                    anchor_raw = spec.anchor_raw,
                    anchor_normalized = spec.anchor_normalized,
                    anchor_dom_version = spec.anchor_dom_version,
                }) ~= nil)
        end

        document:close()
    end
end

-- ---------------------------------------------------------------------
-- Export. Everything here is a promise `ink_export*` makes about KOReader
-- that tests/support.lua cannot keep: the encoder's return convention, the
-- exact byte count behind a BlitBuffer, whether zlib is present at all, and
-- whether a PDF this plugin wrote is one MuPDF will open.
do
    local Blitbuffer = require("ffi/blitbuffer")

    claim("Blitbuffer.tostring exists and is the export's source of bytes",
        type(Blitbuffer.tostring) == "function",
        type(Blitbuffer.tostring) == "function")

    -- The PDF writer is handed `w * h` bytes and declares that as the image
    -- size. `tostring` returns `stride * h`, so the compact copy the export
    -- makes is the only form where those two are the same number.
    if type(Blitbuffer.tostring) == "function" then
        local w, h = 7, 5
        local compact = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8, nil, w, w)
        compact:fill(Blitbuffer.COLOR_WHITE)
        local bytes = Blitbuffer.tostring(compact)
        claim("a compact BB8 is exactly one byte per pixel",
            true, #bytes == w * h,
            string.format("%d bytes for %dx%d", #bytes, w, h))
        claim("and those bytes are the pixels, not padding",
            true, bytes:byte(1) == 255 and bytes:byte(#bytes) == 255,
            "white page reads as 0xFF")
        compact:free()

        local padded = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        claim("an unpadded BB8 is what the export must not assume",
            true, type(Blitbuffer.tostring(padded)) == "string",
            string.format("stride=%s w=%d", tostring(padded.stride), w))
        padded:free()
    end

    local ExportJob = require("ink_export")
    local lfs = require("libs/libkoreader-lfs")
    local probe_dir = os.getenv("TMPDIR") or "/tmp"
    local png_path = probe_dir .. "/justdraw-conformance.png"
    local shot = Blitbuffer.new(4, 3, Blitbuffer.TYPE_BB8)
    shot:fill(Blitbuffer.COLOR_WHITE)

    local wrote, write_err = ExportJob.writeImage(shot, png_path, "png", 90)
    claim("BlitBuffer:writeToFile writes a PNG and answers truthy",
        type(shot.writeToFile) == "function", wrote == true,
        tostring(write_err))
    os.remove(png_path)

    -- The one that matters, and it is a trap rather than a contract:
    -- `writeToFile` wraps the encoder in a pcall, but lodepng and turbojpeg
    -- do not report a file error at all, so writing into a folder that does
    -- not exist returns true and creates nothing. `ink_export` therefore
    -- checks that the file is there before it renames it into place.
    local missing_dir = probe_dir .. "/justdraw-absent-" .. tostring(os.time())
    local missing_path = missing_dir .. "/x.png"
    local claimed = ExportJob.writeImage(shot, missing_path, "png", 90)
    local really_there = lfs.attributes(missing_path, "mode")
    claim("writeToFile claims success even when nothing was written",
        true, claimed == true and really_there == nil,
        "so the export verifies the file rather than trusting the return")
    shot:free()

    -- The convention that decides whether a truncated PDF is renamed into
    -- place. `file:close()` answers `true`, or `nil, message, errno` -- never
    -- `false` -- so a `== false` check is dead code, and the buffered tail of
    -- a file (a PDF's xref and trailer are well under BUFSIZ) fails only
    -- here. The suite's own fake used to say `false`, which is how a dead
    -- check passed for a while.
    local close_path = probe_dir .. "/justdraw-close-probe"
    local close_handle = io.open(close_path, "wb")
    local closed_ok, closed_err
    if close_handle then
        close_handle:write("x")
        closed_ok, closed_err = close_handle:close()
    end
    claim("file:close() answers true, never false, so a failure must be `not ok`",
        close_handle ~= nil,
        closed_ok == true and closed_err == nil,
        "close -> " .. tostring(closed_ok))
    os.remove(close_path)

    local zlib_ok, zlib = pcall(require, "ffi/zlib")
    local compressed
    if zlib_ok and type(zlib.zlib_compress) == "function" then
        local sample = string.rep("\0", 4096)
        compressed = zlib.zlib_compress(sample)
        claim("zlib compresses, and the PDF's /FlateDecode reverses it",
            true,
            type(compressed) == "string" and #compressed < #sample
              and zlib.zlib_uncompress(compressed, #sample) == sample,
            string.format("%d bytes from %d", #(compressed or ""), #sample))
    else
        claim("zlib compresses, and the PDF's /FlateDecode reverses it",
            false, false, "ffi/zlib absent; the PDF is written uncompressed")
    end

    -- A PDF written here, opened by KOReader's own MuPDF. Nothing else in the
    -- suite can state that the bytes are a document rather than merely
    -- self-consistent.
    local Pdf = require("ink_export_pdf")
    local pdf_path = probe_dir .. "/justdraw-conformance.pdf"
    local handle = io.open(pdf_path, "wb")
    local built = false
    if handle then
        local writer = Pdf.new{
            write = function(chunk) return handle:write(chunk) end,
            tell = function() return handle:seek() end,
            compress = zlib_ok and zlib.zlib_compress or nil,
            title = "JustDraw conformance",
        }
        built = writer:addImagePage{
            width_pt = 419.53, height_pt = 595.28, w = 4, h = 2,
            gray = string.char(0, 0, 0, 255) .. string.char(255, 255, 255, 0),
        } and writer:finish() and true or false
        handle:close()
    end

    local mupdf_ok, mupdf = pcall(require, "ffi/mupdf")
    if built and mupdf_ok then
        local opened, document = pcall(mupdf.openDocument, pdf_path)
        claim("a PDF written by this plugin opens in KOReader's MuPDF",
            true, opened and document ~= nil, tostring(document))
        if opened and document then
            local pages_ok, pages = pcall(document.getPages, document)
            claim("and MuPDF agrees about the page count",
                true, pages_ok and pages == 1, tostring(pages))
            local page_ok, page = pcall(document.openPage, document, 1)
            if page_ok and page then
                -- getSize answers two numbers at 72 dpi, which is the unit the
                -- MediaBox is written in, so this compares like with like.
                local size_ok, page_w, page_h = pcall(page.getSize, page,
                    { zoom = 1, rotate = 0 })
                local measured = size_ok and type(page_w) == "number"
                claim("and about the page size the MediaBox declared",
                    true,
                    measured and math.abs(page_w - 419.53) < 1.5
                      and math.abs(page_h - 595.28) < 1.5,
                    measured and string.format("%.2f x %.2f", page_w, page_h)
                      or "no size")
                -- The vectorial route is a later spike, never a requirement of
                -- v1; this only records whether this runtime could host it.
                claim("MuPDF ink annotations, for the vectorial spike only",
                    type(page.addInkAnnotation) == "function",
                    type(page.addInkAnnotation) == "function",
                    "not required by v1")
                page:close()
            else
                claim("and about the page size the MediaBox declared",
                    false, false, "page could not be opened")
            end
            document:close()
        end
    else
        claim("a PDF written by this plugin opens in KOReader's MuPDF",
            mupdf_ok, false,
            built and "ffi/mupdf absent" or "the writer produced nothing")
    end
    os.remove(pdf_path)

    -- The export copies `ReaderView:drawSinglePage` argument for argument. If
    -- KOReader changes what `drawPage` takes, this is where it is noticed --
    -- rather than in a page exported at someone else's gamma.
    local Document = require("document/document")
    local nparams
    if type(debug) == "table" and type(debug.getinfo) == "function" then
        local info = debug.getinfo(Document.drawPage, "u")
        nparams = info and info.nparams
    end
    claim("Document:drawPage still takes the nine arguments the export passes",
        type(nparams) == "number", nparams == 10,
        string.format("self plus %s", tostring(nparams and nparams - 1)))

    local util = require("util")
    claim("util.getSafeFilename is available to name an export",
        type(util.getSafeFilename) == "function",
        type(util.getSafeFilename) == "function")

    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    claim("filemanagerutil.showChooseDialog is what picks the folder",
        type(filemanagerutil.showChooseDialog) == "function",
        type(filemanagerutil.showChooseDialog) == "function")

    local PathChooser = require("ui/widget/pathchooser")
    claim("PathChooser still selects a directory and answers onConfirm",
        type(PathChooser) == "table", PathChooser.select_directory ~= nil
          and PathChooser.select_file ~= nil,
        "select_directory and select_file are both settable")

    local DataStorage = require("datastorage")
    claim("the default export folder resolves under KOReader's data directory",
        type(DataStorage.getFullDataDir) == "function",
        type(DataStorage:getFullDataDir()) == "string",
        tostring(DataStorage:getFullDataDir()) .. "/justdraw-exports")

    -- The disk-space forecast. `tests/support.lua` deliberately has no
    -- `diskUsage` fake -- a fake of a `df` would say nothing true -- so the
    -- shape of the real answer is only ever stated here.
    local data_dir = DataStorage:getDataDir()
    local usage = type(util.diskUsage) == "function" and util.diskUsage(data_dir) or nil
    claim("util.diskUsage answers a table with available in bytes",
        type(util.diskUsage) == "function",
        type(usage) == "table" and type(usage.available) == "number"
          and usage.available > 0,
        type(usage) == "table" and tostring(usage.available) .. " bytes free in "
          .. data_dir or "no table")

    local absent_ok, absent = pcall(util.diskUsage, "/justdraw-definitely-not-here")
    claim("util.diskUsage answers nils rather than raising for a bad folder",
        type(util.diskUsage) == "function",
        absent_ok and type(absent) == "table" and absent.available == nil,
        "the export reads that as 'not known' and asks nothing")

    claim("util.getFriendlySize refuses what is not a number",
        type(util.getFriendlySize) == "function",
        util.getFriendlySize("not a size") == nil
          and type(util.getFriendlySize(1048576)) == "string",
        tostring(util.getFriendlySize(1048576)))

    -- The orphan sweep. Both of these are exactly why `Export.orphans` wraps
    -- the whole walk in a pcall and treats a missing modification time as
    -- "unknown age", rather than as "old".
    local lfs = require("libs/libkoreader-lfs")
    local raised = not pcall(function()
        for _ in lfs.dir("/justdraw-definitely-not-here") do end
    end)
    claim("lfs.dir raises for a folder that is not there",
        true, raised, "it does not answer nil, so the sweep runs under pcall")

    local first_two = {}
    for name in lfs.dir(data_dir) do
        first_two[#first_two + 1] = name
        if #first_two >= 2 then break end
    end
    table.sort(first_two)
    claim("lfs.dir yields dot and dot-dot, which the sweep must skip",
        true, first_two[1] == "." and first_two[2] == "..",
        table.concat(first_two, " "))

    claim("lfs.attributes answers a numeric modification time",
        true, type(lfs.attributes(data_dir, "modification")) == "number")

    -- The scope-aware file name. These two are what `tests/support.lua`'s
    -- MultiInputDialog and RadioButtonTable fakes assert about KOReader, and
    -- the whole of `Dialog.proposeStem` rests on them.
    local RadioButtonTable = require("ui/widget/radiobuttontable")
    local selected
    local radio_ok, radio = pcall(RadioButtonTable.new, RadioButtonTable, {
        width = 200,
        radio_buttons = {{ { text = "A", value = "a", checked = true },
                           { text = "B", value = "b" } }},
        button_select_callback = function(entry) selected = entry end,
    })
    local fired = false
    if radio_ok and radio and radio.radio_buttons_layout then
        local row = radio.radio_buttons_layout[1]
        local button = row and row[2]
        if button and type(button.callback) == "function" then
            pcall(button.callback)
            fired = selected ~= nil and selected.value == "b"
        end
    end
    claim("RadioButtonTable calls button_select_callback with the entry",
        radio_ok and radio ~= nil, fired,
        "the scope radio recomputes the proposed name from this")

    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog_ok, dialog = pcall(MultiInputDialog.new, MultiInputDialog, {
        title = "probe",
        fields = {{ description = "File name", text = "proposed" }},
        buttons = {{ { text = "Close", id = "close" } }},
    })
    local field = dialog_ok and dialog and dialog.input_fields
        and dialog.input_fields[1] or nil
    local usable = field ~= nil and type(field.setText) == "function"
        and type(field.isTextEdited) == "function"
    local field_ok = false
    if usable then
        field:setText("replaced")
        field_ok = field:getText() == "replaced"
    end
    claim("MultiInputDialog exposes input_fields that set text and report editing",
        dialog_ok and usable, field_ok,
        "Dialog.proposeStem writes through input_fields[1]")

    -- The half that decides whether a reader's typed name survives a change of
    -- scope. `setText` clears the edited flag unless told to keep it, so a
    -- proposal reads as "not edited" and a proposal made with `keep` would
    -- read as "edited" -- which is why `proposeStem` passes neither and relies
    -- on the default.
    local edited_ok = false
    if usable and type(field.addChars) == "function" then
        field:setText("proposed")
        local proposed_reads_unedited = field:isTextEdited() == false
        -- What the keyboard does.
        field:addChars("x")
        local typing_marks_it = field:isTextEdited() == true
        field:setText("kept", true)
        edited_ok = proposed_reads_unedited and typing_marks_it
            and field:isTextEdited() == true
        field:setText("plain")
        edited_ok = edited_ok and field:isTextEdited() == false
    end
    claim("InputText:setText clears the edited flag unless asked to keep it",
        usable and field ~= nil and type(field.addChars) == "function", edited_ok,
        "a proposed name reads as unedited; a reader's name does not")
    if dialog_ok and dialog and dialog.onCloseWidget then
        pcall(dialog.onCloseWidget, dialog)
    end

end

for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-56s %s\n", r[1], r[2], r[3]))
end
local strict = os.getenv("JUSTDRAW_CONFORMANCE_STRICT_STYLUS") == "1"
local bad, strict_uncheckable = ConformancePolicy.countFailures(rows, strict)
io.write(string.format("\n%d claims, %d failures", #rows, bad))
if strict then io.write(string.format(" (%d required stylus claims uncheckable)", strict_uncheckable)) end
io.write("\n")
os.exit(bad == 0 and 0 or 1)
