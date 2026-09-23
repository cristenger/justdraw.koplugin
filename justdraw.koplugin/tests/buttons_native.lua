--[[--
Every button and menu entry the plugin puts on screen, pressed on a real
KOReader, one at a time, with what each one is supposed to do checked after.

The other native scripts prove geometry (top_toolbar_native) or the ink path
(reader_smoke). This one is about the controls themselves: that a tap on a
button reaches its action through the real window stack, that the action
happened, and -- the failure a unit suite cannot see -- that whatever it put
up can be closed again and leaves the stack exactly as it found it. A dialog
left on the stack is a menu that "stays stuck": drawing yields to it, taps go
to it, and the reader looks frozen.

Taps are real touch frames: evdev ABS/SYN events through `Input:handleTouchEv`,
the gestures it returns sent through `UIManager:sendEvent`, which offers them
to the topmost window first. So JustDraw's feed wrapper and stylus callback,
its toolbar's forwarding and every widget's own gesture ranges all run for
real. Every touch paints the screen first, because a person only ever touches
a painted screen and that is also what gives each widget its `dimen`.

    cd <koreader-build>/koreader && SDL_VIDEODRIVER=dummy \
      JUSTDRAW_PDF=<sample.pdf> JUSTDRAW_EPUB=<juliet.epub> \
      ./luajit <repo>/justdraw.koplugin/tests/buttons_native.lua

  KO_HOME           an isolated data dir; a fresh one is created when unset
  JUSTDRAW_PDF      a fixed-layout document (KOReader's test-data sample.pdf)
  JUSTDRAW_EPUB     a reflowable one (test-data juliet.epub)
  JUSTDRAW_FLASH=0  tap without the button highlight (default: highlight on,
                    which is the path real devices take)
  JUSTDRAW_SHOTS=1  write a PNG of the screen after each case, and of every
                    window a control opens, into KO_HOME/shots
  JUSTDRAW_DEBUG=1  print every gesture and the window it was offered to

The fixtures come from https://github.com/koreader/test-data. A section whose
document is missing is reported SKIP, not passed. Exit 0 and
BUTTONS_NATIVE_OK only when every case passed. Deliberately not in
tests/run.lua, which must run on bare LuaJIT.
]]

require("setupkoenv")

local ffi = require("ffi")
ffi.cdef [[
    int setenv(const char *name, const char *value, int overwrite);
    int symlink(const char *target, const char *linkpath);
    int getpid(void);
    int usleep(unsigned int usec);
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local DEBUG = os.getenv("JUSTDRAW_DEBUG") == "1"

-- ------------------------------------------------------------------ home

local function isDir(path)
    return path ~= nil and lfs.attributes(path, "mode") == "directory"
end

local home = os.getenv("KO_HOME")
if not home or home == "" then
    local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    home = string.format("%s/justdraw-buttons-%d-%d", base, ffi.C.getpid(), os.time())
    assert(lfs.mkdir(home), "could not create " .. home)
end
assert(isDir(home), "KO_HOME is not a directory: " .. home)
assert(not lfs.attributes(home .. "/settings.reader.lua"), "KO_HOME must be fresh")
local user_home = os.getenv("HOME")
assert(not user_home or home ~= user_home .. "/.config/koreader",
    "refusing to run against the reader's own data dir")
if not isDir("plugins/justdraw.koplugin") then
    lfs.mkdir(home .. "/plugins")
    assert(ffi.C.symlink(plugin_dir, home .. "/plugins/justdraw.koplugin") == 0,
        "could not link the plugin into " .. home .. "/plugins")
end
assert(ffi.C.setenv("KO_HOME", home, 1) == 0)

_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
-- Sidecars under KO_HOME, never beside the fixture.
G_reader_settings:saveSetting("document_metadata_folder", "dir")
G_reader_settings:saveSetting("flash_ui", os.getenv("JUSTDRAW_FLASH") ~= "0")
G_reader_settings:saveSetting("quickstart_shown_version", 99999999)

local Device = require("device")
require("document/canvascontext"):init(Device)
local C = ffi.C
require("ffi/linux_input_h")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Screen, Input = Device.screen, Device.input

-- Anything logged at error level fails the case it happened in: plugin event
-- handlers run inside a sandbox that logs instead of raising.
local logged_errors = {}
local original_err = logger.err
logger.err = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    logged_errors[#logged_errors + 1] = table.concat(parts, " ")
    return original_err(...)
end

-- ------------------------------------------------------------- reporting

local results = { pass = 0, fail = 0, skip = 0 }
local shots = os.getenv("JUSTDRAW_SHOTS") == "1"
local shot_n = 0

--- The screen as it is now, numbered in order and named after what is on it.
local function shot(what)
    if not shots then return end
    shot_n = shot_n + 1
    lfs.mkdir(home .. "/shots")
    UIManager:forceRePaint()
    local slug = what:gsub("[^%w]+", "-"):sub(1, 60)
    Screen.bb:writePNG(string.format("%s/shots/%03d-%s.png", home, shot_n, slug))
end

local function expect(cond, fmt, ...)
    if cond then return cond end
    error(select("#", ...) > 0 and string.format(fmt, ...) or fmt, 2)
end

-- The reader under test and its JustDraw instance, set by openReader.
local reader, plugin

-- Assigned below. `case` calls it after a failure, so one stuck dialog is one
-- FAIL rather than every case after it failing for the same reason.
local restore

local function case(title, fn)
    local before = #logged_errors
    local ok, err = xpcall(fn, debug.traceback)
    if ok and #logged_errors > before then
        ok, err = false, "logged an error: " .. logged_errors[#logged_errors]
    end
    if ok then
        results.pass = results.pass + 1
        print("OK   " .. title)
    else
        results.fail = results.fail + 1
        print("FAIL " .. title)
        for line in tostring(err):gmatch("[^\n]+") do print("       " .. line) end
        if restore then pcall(restore) end
    end
    if shots then shot(title) end
    return ok
end

local function skip(title, why)
    results.skip = results.skip + 1
    print("SKIP " .. title .. " -- " .. why)
end

-- ------------------------------------------------------------------ pump

local function tick(rounds)
    for _ = 1, rounds or 3 do UIManager:_checkTasks() end
end

--- Let wall-clock time pass with the task queue running, for what KOReader
--- schedules by delay rather than by tick.
local function wait(seconds, until_fn)
    local deadline = time.now() + time.s(seconds)
    while time.now() < deadline do
        if until_fn and until_fn() then return true end
        C.usleep(20000)
        tick(1)
    end
    return until_fn ~= nil and until_fn() or false
end

--- Opening a document inhibits input for a moment (`Input:inhibitInput`
--- swaps `handleTouchEv` for a sink) and a timer gives it back.
local function waitForInput()
    return wait(5, function() return Input.handleTouchEv ~= Input.voidEv end)
end

local function paint()
    tick(1)
    UIManager:forceRePaint()
end

-- ----------------------------------------------------------------- stack

local function stack()
    local out = {}
    for i = #UIManager._window_stack, 1, -1 do
        out[#out + 1] = UIManager._window_stack[i].widget
    end
    return out
end

local function name(widget)
    if not widget then return "nil" end
    local label = widget.name or widget.title or widget.text
    if type(label) ~= "string" then
        local mt = getmetatable(widget)
        label = widget.id or (mt and type(mt.__index) == "table" and mt.__index.name) or "widget"
    end
    return (tostring(label):gsub("\n", " "):sub(1, 40))
end

local function describeStack()
    local names = {}
    for _, widget in ipairs(stack()) do names[#names + 1] = name(widget) end
    return table.concat(names, " > ")
end

--- Toasts and timed messages close themselves on a timer this loop never
--- reaches. Closing them is what waiting would do.
local function dropToasts()
    for _, widget in ipairs(stack()) do
        if widget.toast or (widget.timeout and widget.text) then UIManager:close(widget) end
    end
    tick(2)
end

local function onStack(widget)
    for _, w in ipairs(stack()) do if w == widget then return true end end
    return false
end

-- ----------------------------------------------------------------- touch

local tracking = 0
local clock = 1000000

local function advance(ms) clock = clock + ms * 1000 end

local function frame(events)
    local gestures = {}
    for _, ev in ipairs(events) do
        local out = Input:handleTouchEv({ type = ev[1], code = ev[2], value = ev[3],
            time = { sec = math.floor(clock / 1e6), usec = clock % 1e6 } })
        if out then
            for _, g in ipairs(out) do gestures[#gestures + 1] = g end
        end
    end
    for _, g in ipairs(gestures) do
        if DEBUG then
            local a = g.args[1]
            print(string.format("  ges %s %s,%s -> %s", a.ges, tostring(a.pos and a.pos.x),
                tostring(a.pos and a.pos.y), describeStack()))
        end
        UIManager:sendEvent(g)
    end
    tick(2)
    return gestures
end

--[[--
Screen coordinates to the panel's own. A rotated screen reads touches in the
panel's native orientation and GestureDetector:translateCoordinates turns them
round, so a point meant for the screen is sent as the panel would report it.
]]
local function toNative(x, y)
    local mode, W, H = Screen:getTouchRotation(), Screen:getWidth(), Screen:getHeight()
    if mode == Screen.DEVICE_ROTATED_CLOCKWISE then return y, W - x end
    if mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then return H - y, x end
    if mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN then return W - x, H - y end
    return x, y
end

local function contactDown(slot, tool, x, y)
    x, y = toNative(x, y)
    tracking = tracking + 1
    frame{
        { C.EV_ABS, C.ABS_MT_SLOT, slot },
        { C.EV_ABS, C.ABS_MT_TRACKING_ID, tracking },
        { C.EV_ABS, C.ABS_MT_TOOL_TYPE, tool },
        { C.EV_ABS, C.ABS_MT_POSITION_X, x },
        { C.EV_ABS, C.ABS_MT_POSITION_Y, y },
        { C.EV_SYN, C.SYN_REPORT, 0 },
    }
end

local function contactUp(slot)
    return frame{
        { C.EV_ABS, C.ABS_MT_SLOT, slot },
        { C.EV_ABS, C.ABS_MT_TRACKING_ID, -1 },
        { C.EV_SYN, C.SYN_REPORT, 0 },
    }
end

local function slotFor(tool)
    if tool == "pen" then return Input.pen_slot or 4, 1 end
    return 0, 0
end

--- One contact down at x,y and up again 60 ms later. A pen reports several
--- samples while it rests, each a pixel or so off the last, and the stylus
--- route decides only once it has a coherent pair -- so a pen tap is sent the
--- way a pen sends one.
local function tapAt(x, y, tool)
    local slot, tool_type = slotFor(tool)
    paint()
    advance(400)   -- well clear of any double-tap window
    contactDown(slot, tool_type, x, y)
    if tool == "pen" then
        for i = 1, 4 do
            advance(12)
            local nx, ny = toNative(x + (i % 2), y + (i % 2))
            frame{
                { C.EV_ABS, C.ABS_MT_SLOT, slot },
                { C.EV_ABS, C.ABS_MT_POSITION_X, nx },
                { C.EV_ABS, C.ABS_MT_POSITION_Y, ny },
                { C.EV_SYN, C.SYN_REPORT, 0 },
            }
        end
    end
    advance(tool == "pen" and 12 or 60)
    local out = contactUp(slot)
    tick(3)
    return out
end

--- A drag from one point to another in `steps` moves, for drawing.
local function drag(x1, y1, x2, y2, steps, tool)
    local slot, tool_type = slotFor(tool)
    paint()
    advance(400)
    contactDown(slot, tool_type, x1, y1)
    for i = 1, steps do
        advance(12)
        local nx, ny = toNative(math.floor(x1 + (x2 - x1) * i / steps),
            math.floor(y1 + (y2 - y1) * i / steps))
        frame{
            { C.EV_ABS, C.ABS_MT_SLOT, slot },
            { C.EV_ABS, C.ABS_MT_POSITION_X, nx },
            { C.EV_ABS, C.ABS_MT_POSITION_Y, ny },
            { C.EV_SYN, C.SYN_REPORT, 0 },
        }
    end
    advance(12)
    contactUp(slot)
    tick(4)
end

local function centre(rect)
    return rect.x + math.floor(rect.w / 2), rect.y + math.floor(rect.h / 2)
end

-- ------------------------------------------------------------ widget tree

local Button = require("ui/widget/button")
local IconButton = require("ui/widget/iconbutton")

local function inherits(w, class)
    local mt = getmetatable(w)
    local seen = 0
    while mt and seen < 20 do
        if mt == class or mt.__index == class then return true end
        local parent = mt.__index
        mt = type(parent) == "table" and getmetatable(parent) or nil
        seen = seen + 1
    end
    return false
end

--- Every widget under `root`, depth first. Returns as soon as `visit` does.
local function walk(root, visit, seen)
    seen = seen or {}
    if type(root) ~= "table" or seen[root] then return end
    seen[root] = true
    if visit(root) then return true end
    for i = 1, #root do
        if walk(root[i], visit, seen) then return true end
    end
    for _, key in ipairs({ "movable", "buttontable", "button_table", "title_bar",
            "_input_widget", "dialog_frame", "vgroup", "item_group", "radio_button_table",
            "_added_widgets", "entries" }) do
        if type(root[key]) == "table" and walk(root[key], visit, seen) then return true end
    end
    if root.widget and type(root.widget) == "table" and walk(root.widget, visit, seen) then
        return true
    end
end

local function labelOf(w)
    return w.tool_label or w.text or w.help_text or ""
end

--- The Button under `root` whose label is `text`. Failing an exact match, the
--- one whose label starts with it, for labels that carry a state suffix such
--- as a check mark -- never both, or "Close" would find "Close sheet".
local function findButton(root, text)
    local exact, prefix
    walk(root, function(w)
        if inherits(w, Button) then
            local label = labelOf(w)
            if label == text or w.help_text == text then
                exact = w
                return true
            end
            if not prefix and label:sub(1, #text) == text then prefix = w end
        end
    end)
    return exact or prefix
end

local function buttonLabels(root)
    local out = {}
    walk(root, function(w)
        if inherits(w, Button) then out[#out + 1] = (labelOf(w):gsub("\n.*", "")) end
    end)
    return out
end

--- Tap a widget where it is painted.
local function tap(widget, tool)
    expect(widget, "nothing to tap")
    paint()
    local d = expect(widget.dimen, "%s has no dimen: it was never painted", name(widget))
    expect(d.w > 0 and d.h > 0, "%s is painted with no area", name(widget))
    local x, y = centre(d)
    return tapAt(x, y, tool)
end

--- Press the button labelled `text` in `root` (default: the top window).
local function press(text, root, tool)
    root = root or stack()[1]
    local button = findButton(root, text)
    expect(button, "no button %q in %s; it has: %s", text, name(root),
        table.concat(buttonLabels(root), " | "))
    expect(button.enabled ~= false, "button %q is disabled", text)
    tap(button, tool)
    return button
end

-- ------------------------------------------------------------ stack checks

local baseline

local function sameStack(expected)
    local now = stack()
    if #now ~= #expected then return false end
    for i = 1, #now do if now[i] ~= expected[i] then return false end end
    return true
end

--- The stack is back to the baseline: nothing was left open.
local function settled(what)
    dropToasts()
    expect(sameStack(baseline), "%s left the stack as [%s]", what, describeStack())
end

--- Something new is on top of the stack, and it is returned.
local function opened(before, what)
    dropToasts()
    local top = stack()[1]
    expect(top ~= before, "%s opened nothing (stack: %s)", what, describeStack())
    shot("open " .. what)
    return top
end

restore = function()
    -- A case that failed in landscape must not leave every later one there.
    if reader and Screen:getRotationMode() ~= 0 then
        reader:handleEvent(Event:new("SetRotationMode", 0))
        tick(4)
    end
    if reader and reader.menu.menu_container then
        reader.menu:onCloseReaderMenu()
        tick(2)
    end
    -- Close only what the baseline does not hold, topmost first: a failure
    -- may have left a dialog *under* one of the plugin's own windows.
    for _ = 1, 20 do
        local extra
        for _, w in ipairs(stack()) do
            -- The plugin's live windows are never the leftover: a rebuilt
            -- toolbar is a new object the baseline has not seen.
            local overlay = plugin and plugin.session and plugin.session:overlay()
            local known = w == reader or (plugin and w == plugin.bar) or w == overlay
                or (plugin and plugin.notebook_ui and (w == plugin.notebook_ui.library
                    or w == plugin.notebook_ui.editor))
            for _, b in ipairs(baseline or {}) do if b == w then known = true end end
            if not known then extra = w; break end
        end
        if not extra then break end
        if DEBUG then print("  restore closes " .. name(extra) .. " from " .. describeStack()) end
        if extra.onClose then pcall(extra.onClose, extra) end
        tick(2)
        if onStack(extra) then UIManager:close(extra); tick(2) end
    end
    dropToasts()
    baseline = stack()
end

--- Close the top window the way a person would: its Close or Cancel button,
--- else its title bar's close icon. Fails when neither exists or it stays up.
local function dismiss(what)
    local top = stack()[1]
    for _, label in ipairs({ "Close", "Cancel" }) do
        local b = findButton(top, label)
        if b and b.enabled ~= false then
            tap(b)
            expect(not onStack(top), "%s: %s did not close it", what, label)
            return
        end
    end
    local icon
    walk(top, function(w)
        if inherits(w, IconButton) and w.icon == "close" then icon = w; return true end
    end)
    expect(icon, "%s offers no Close, Cancel or close icon: %s", what,
        table.concat(buttonLabels(top), " | "))
    tap(icon)
    expect(not onStack(top), "%s: its close icon did not close it", what)
end

--- Open something with `act`, check `check(top)` on it, dismiss it, and
--- require the stack to be what it was.
local function roundTrip(what, act, check)
    local before = stack()[1]
    act()
    local top = opened(before, what)
    if check then check(top) end
    dismiss(what)
    settled(what)
end

-- ------------------------------------------------------------- reader menu

local function menuText(item)
    return item.text_func and item.text_func() or item.text
end

local function paintedItems(touchmenu)
    local items = {}
    walk(touchmenu.item_group, function(w)
        if w.item and w.dimen then items[#items + 1] = w end
    end)
    return items
end

--- Open the reader's main menu on the tab whose top level holds `path[1]`,
--- then tap the painted entries of `path` in turn. Returns the TouchMenu.
local function openMenu(path)
    reader.menu:onShowMenu()
    tick(2)
    local container = expect(reader.menu.menu_container, "the main menu did not open")
    local touchmenu = container[1]
    local found
    for i, tab in ipairs(touchmenu.tab_item_table) do
        for _, item in ipairs(tab) do
            if menuText(item) == path[1] then found = i end
        end
        if found then break end
    end
    expect(found, "no menu tab holds %q", path[1])
    touchmenu:switchMenuTab(found)
    for _, text in ipairs(path) do
        paint()
        local target, seen
        for _ = 1, touchmenu.page_num or 1 do
            seen = {}
            for _, w in ipairs(paintedItems(touchmenu)) do
                seen[#seen + 1] = menuText(w.item)
                if menuText(w.item) == text then target = w end
            end
            if target then break end
            touchmenu:onNextPage()
            paint()
        end
        expect(target, "no menu entry %q; the menu shows: %s", text, table.concat(seen, " | "))
        tap(target)
    end
    return touchmenu
end

--- The items of the menu level a path ends on, by text.
local function menuEntries(touchmenu)
    local out = {}
    for _, item in ipairs(touchmenu.item_table) do out[#out + 1] = item end
    return out
end

local function closeMenu()
    if reader and reader.menu.menu_container then
        reader.menu:onCloseReaderMenu()
        tick(2)
    end
end

-- ------------------------------------------------------------- documents

local DocumentRegistry = require("document/documentregistry")
local ReaderUI = require("apps/reader/readerui")
local PluginLoader = require("pluginloader")

local function openReader(path)
    path = require("ffi/util").realpath(path) or path
    local document = expect(DocumentRegistry:openDocument(path), "could not open %s", path)
    reader = ReaderUI:new{ dimen = Screen:getSize(), document = document }
    ReaderUI.instance = reader
    UIManager:show(reader)
    tick(4)
    expect(waitForInput(), "input is still inhibited after opening %s", path)
    plugin = expect(reader.justdraw or PluginLoader:getPluginInstance("justdraw"),
        "PluginLoader did not load justdraw")
    dropToasts()
    -- Start-up notices only; the plugin's own windows are under test.
    for _, widget in ipairs(stack()) do
        if widget ~= reader and widget ~= plugin.bar then UIManager:close(widget) end
    end
    tick(2)
    baseline = stack()
    return reader
end

local function closeReader()
    closeMenu()
    restore()
    if plugin and plugin.canvas_open then plugin:closeCanvas() end
    if plugin and plugin.bar then plugin:setBarShown(false) end
    tick(2)
    reader:onClose()
    tick(4)
    dropToasts()
    reader, plugin, baseline = nil, nil, nil
end

local function position()
    if reader.paging then
        return reader.view.state.page .. ":" .. tostring(reader.view.visible_area.y)
    end
    return tostring(reader.document:getCurrentPos())
end

--- A row across the page, clear of every JustDraw window from `x1` to `x2`.
local function readerRow(x1, x2)
    local H = Screen:getHeight()
    for y = math.floor(H * 0.3), math.floor(H * 0.7), 10 do
        local clear = true
        if plugin then
            for x = math.min(x1, x2), math.max(x1, x2), 10 do
                if plugin:regionAt(x, y) ~= "reader" then clear = false; break end
            end
        end
        if clear then return y end
    end
    error("no row across the page is clear of the plugin's windows")
end

--- A point on the page outside every JustDraw window, for a tap that must
--- land on the reader rather than on a control.
local function readerSpot(backward)
    local W = Screen:getWidth()
    local x = math.floor(W * (backward and 0.1 or 0.5))
    return x, readerRow(x, x)
end

--- A swipe across the page turns it, wherever the reader's tap zones are:
--- the proof that nothing is swallowing input. Then back again.
local function readerStillAnswers(what)
    local W = Screen:getWidth()
    local left, right = math.floor(W * 0.2), math.floor(W * 0.6)
    local y = readerRow(left, right)
    local before = position()
    drag(right, y, left, y, 4)
    tick(4)
    expect(position() ~= before, "%s: a swipe on the page does nothing (stack: %s)",
        what, describeStack())
    drag(left, y, right, y, 4)
    tick(4)
end

--- Turn the screen the way the reader's rotation setting does, and let the
--- rebuilds it triggers run. `mode` is a LinuxFB rotation: 0 portrait,
--- 1 landscape.
local function rotate(mode)
    reader:handleEvent(Event:new("SetRotationMode", mode))
    tick(4)
    wait(0.3)
    dropToasts()
    expect(Screen:getRotationMode() == mode, "the screen did not rotate to %d", mode)
end

--- Every window that can be seen is inside the screen: those above, and
--- including, the topmost that covers it. A covered window may wait to be
--- uncovered before it relays (the notebook library does, on purpose).
local function allOnScreen(what)
    paint()
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _, w in ipairs(stack()) do
        local d = w.dimen
        if d and d.w and d.w > 0 and not w.toast then
            expect(d.x >= 0 and d.y >= 0 and d.x + d.w <= W and d.y + d.h <= H,
                "%s: %s is off the %dx%d screen at %d,%d %dx%d", what, name(w), W, H,
                d.x, d.y, d.w, d.h)
            if d.x == 0 and d.y == 0 and d.w == W and d.h == H then break end
        end
    end
end

-- ------------------------------------------------------------------ shared

--- The toolbar's More, then one entry of it, then that entry's dialog
--- dismissed. `bar` is whichever toolbar is up.
local function moreEntry(bar, entry, check)
    roundTrip("More > " .. entry, function()
        local before = stack()[1]
        tap(bar.more_btn)
        local more = opened(before, "More")
        press(entry, more)
    end, check)
end

local function pressMoreAndClose(bar)
    local before = stack()[1]
    tap(bar.more_btn)
    local more = opened(before, "More")
    press("Close", more)
    expect(not onStack(more), "More > Close left More open")
end

--- Put drawing in the state a case starts from, through the Draw/Stop button.
local function ensureDrawing(bar, on, tool)
    if plugin.drawing ~= on then tap(bar.draw_btn, tool) end
    expect(plugin.drawing == on, "Draw/Stop could not turn drawing %s", on and "on" or "off")
end

--- Every icon on `root` names itself on a hold, as a toast. The hold gesture
--- comes from a timer in `Input:waitEvent`, which this script does not run,
--- so the Button's own hold handler is what is called.
local function iconsNameThemselves(root, where)
    local icons = 0
    walk(root, function(w)
        if inherits(w, Button) and w.icon and w.tool_label then
            icons = icons + 1
            local depth = #stack()
            w:onHoldSelectButton()
            tick(2)
            local top = stack()[1]
            expect(#stack() == depth + 1 and top.toast,
                "%s: a hold on %s showed nothing (stack: %s)", where, w.icon, describeStack())
            expect(top.text == w.tool_label, "%s: a hold on %s said %q", where, w.icon,
                tostring(top.text))
            UIManager:close(top)
            tick(1)
        end
    end)
    expect(icons > 0, "%s has no icons", where)
    return icons
end

--- The real Button for one style and width in the pen dialog: the row the
--- style's name heads, the cell that says the width.
local function penCell(dialog, style, width)
    local rows = expect(dialog.buttontable, "no button table in %s", name(dialog)).buttons_layout
    for _, row in ipairs(rows) do
        if row[1].text == style then
            for i = 2, #row do
                if row[i].text:sub(1, #width) == width then return row[i] end
            end
        end
    end
    error(("no %s · %s cell in the pen dialog"):format(style, width))
end

--- The eraser/pen pair and the pen dialog, on whichever toolbar is up.
local function toolCases(prefix, bar_of, tool)
    case(prefix .. ": Eraser selects the eraser, Pen gives it back", function()
        ensureDrawing(bar_of(), true, tool)
        tap(bar_of().eraser_btn, tool)
        expect(plugin.eraser, "Eraser did not select the eraser")
        tap(bar_of().pen_btn, tool)
        expect(not plugin.eraser, "Pen did not leave the eraser")
        settled("Eraser/Pen")
    end)

    case(prefix .. ": the selected Pen opens pen settings; a choice applies and closes", function()
        ensureDrawing(bar_of(), true, tool)
        local before = stack()[1]
        tap(bar_of().pen_btn, tool)
        local dialog = opened(before, "Pen")
        local cell = penCell(dialog, "Graphite", "Thick")
        expect(cell.hold_callback, "a hold on a width cell names nothing")
        tap(cell)
        expect(not onStack(dialog), "a pen choice left the dialog open")
        expect(plugin.pen_width == 7, "width is %s, not Thick", tostring(plugin.pen_width))
        settled("pen choice")
        roundTrip("Pen settings, again", function() tap(bar_of().pen_btn, tool) end)
        -- Back to the default, through the dialog.
        tap(bar_of().pen_btn, tool)
        tap(penCell(stack()[1], "Ink pen", "Medium"))
        settled("pen reset")
    end)
end

-- ===================================================================== PDF

local pdf = os.getenv("JUSTDRAW_PDF")
local epub = os.getenv("JUSTDRAW_EPUB")

if not pdf or lfs.attributes(pdf, "mode") ~= "file" then
    skip("PDF: side toolbar and page notes", "set JUSTDRAW_PDF to test-data sample.pdf")
else
    local ok_open = case("PDF: the reader opens with the plugin loaded", function()
        openReader(pdf)
        -- Single-page view: page ink refuses continuous mode (ADR-38).
        if reader.view.page_scroll then
            reader:handleEvent(Event:new("SetScrollMode", false))
            tick(3)
        end
        expect(plugin.document_session, "no page-ink session: %s",
            tostring(plugin.document_open_error))
        baseline = stack()
    end)
    if ok_open then
        case("PDF: nothing is stuck before we start", function()
            settled("opening")
            readerStillAnswers("a fresh reader")
        end)

        case("PDF menu: JustDraw > Show toolbar hides and shows the side toolbar", function()
            if plugin.bar then
                openMenu({ "JustDraw", "Show toolbar" })
                expect(not plugin.bar, "Show toolbar did not hide the toolbar")
                closeMenu()
                expect(sameStack({ reader }), "hiding left [%s]", describeStack())
            end
            openMenu({ "JustDraw", "Show toolbar" })
            expect(plugin.bar, "no toolbar after Show toolbar")
            closeMenu()
            baseline = stack()
            expect(baseline[1] == plugin.bar, "the toolbar is not the top window")
            readerStillAnswers("toolbar up, drawing off")
        end)

        if plugin.bar then
            local function bar() return plugin.bar end

            case("PDF toolbar: Draw turns drawing on and the button says so", function()
                tap(bar().draw_btn)
                expect(plugin.drawing, "Draw did not turn drawing on")
                expect(bar().draw_btn.text == "Stop", "the button reads %q",
                    tostring(bar().draw_btn.text))
                settled("Draw")
            end)

            case("PDF toolbar: a finger stroke is ink on the page, and Undo takes it back", function()
                local session = plugin.document_session
                local rect = expect(session:transform(), "no transform"):canvasRect()
                local x, y = centre(rect)
                local before = #session:cache():strokes()
                drag(x - 80, y - 40, x + 60, y + 50, 10)
                expect(#session:cache():strokes() == before + 1,
                    "a stroke on the page made %d strokes, from %d",
                    #session:cache():strokes(), before)
                tap(bar().undo_btn)
                expect(#session:cache():strokes() == before, "Undo left %d strokes",
                    #session:cache():strokes())
                settled("Undo")
            end)

            case("PDF toolbar: Undo with nothing to undo is harmless", function()
                tap(bar().undo_btn)
                settled("Undo on an empty page")
            end)

            toolCases("PDF toolbar", bar)

            case("PDF toolbar: a hold on every icon names it", function()
                iconsNameThemselves(bar(), "the side toolbar")
                settled("holds")
            end)

            case("PDF toolbar: More > Document notes turns drawing off and opens the browser", function()
                ensureDrawing(bar(), true)
                moreEntry(bar(), "Document notes", function()
                    expect(not plugin.drawing, "the browser opened over live drawing")
                end)
            end)
            case("PDF toolbar: More > Pen settings", function()
                moreEntry(bar(), "Pen settings")
            end)
            case("PDF toolbar: More > Drawing refresh; a choice applies and closes", function()
                local before = stack()[1]
                tap(bar().more_btn)
                press("Drawing refresh", opened(before, "More"))
                local dialog = opened(before, "Drawing refresh")
                local was = plugin:getDrawingRefreshInterval()
                local labels = buttonLabels(dialog)
                local pick
                for _, label in ipairs(labels) do
                    if label:match("^%d+ ms") and not label:find(tostring(was), 1, true) then
                        pick = label; break
                    end
                end
                press(expect(pick, "no other interval among %s", table.concat(labels, " | ")), dialog)
                expect(plugin:getDrawingRefreshInterval() ~= was, "the interval did not change")
                settled("a refresh choice")
                moreEntry(bar(), "Drawing refresh")
            end)
            case("PDF toolbar: More > Input mode is locked while drawing, and closes", function()
                ensureDrawing(bar(), true)
                moreEntry(bar(), "Input mode", function(dialog)
                    local stylus = expect(findButton(dialog, "Stylus"), "no Stylus choice")
                    expect(stylus.enabled == false, "Stylus is selectable while drawing")
                end)
            end)
            case("PDF toolbar: More > Export… opens the export form, Cancel closes it", function()
                moreEntry(bar(), "Export…")
            end)
            case("PDF toolbar: More > Toolbar side moves the toolbar and closes More", function()
                local x = bar().dimen.x
                local before = stack()[1]
                tap(bar().more_btn)
                local more = opened(before, "More")
                press("Toolbar side", more)
                expect(bar().dimen.x ~= x, "the toolbar did not move")
                dropToasts()
                expect(not onStack(more), "More stayed open over the moved toolbar (stack: %s)",
                    describeStack())
                baseline = stack()
                expect(baseline[1] == plugin.bar, "the moved toolbar is not on top")
                -- And back.
                tap(bar().more_btn)
                press("Toolbar side")
                expect(bar().dimen.x == x, "the toolbar did not move back")
                baseline = stack()
                settled("Toolbar side")
            end)
            case("PDF toolbar: More > Close", function()
                pressMoreAndClose(bar())
                settled("More > Close")
            end)
            case("PDF toolbar: a tap outside More closes it", function()
                local before = stack()[1]
                tap(bar().more_btn)
                local more = opened(before, "More")
                paint()
                local d = more.movable and more.movable.dimen or more.dimen
                local x = readerSpot(true)
                local y = d.y > 40 and math.floor(d.y / 2) or d.y + d.h + 20
                tapAt(x, y)
                expect(not onStack(more), "a tap outside left More open (stack: %s)",
                    describeStack())
                settled("tap outside More")
            end)

            case("PDF toolbar: Stop turns drawing off, and the page turns again", function()
                ensureDrawing(bar(), true)
                tap(bar().draw_btn)
                expect(not plugin.drawing, "Stop did not turn drawing off")
                expect(bar().draw_btn.text == "Draw", "the button reads %q", tostring(bar().draw_btn.text))
                settled("Stop")
                readerStillAnswers("after Stop")
            end)

            case("PDF toolbar: More > Input mode offers every mode with drawing off", function()
                ensureDrawing(bar(), false)
                local before = stack()[1]
                tap(bar().more_btn)
                press("Input mode", opened(before, "More"))
                local dialog = opened(before, "Input mode")
                press("Finger", dialog)
                expect(plugin.input_mode == "finger", "input mode is %s", tostring(plugin.input_mode))
                settled("Input mode > Finger")
                tap(bar().more_btn)
                press("Input mode")
                press("Automatic")
                expect(plugin.input_mode == "auto", "input mode is %s", tostring(plugin.input_mode))
                settled("Input mode > Automatic")
            end)

            case("PDF toolbar: Hide takes the toolbar down with drawing off", function()
                ensureDrawing(bar(), true)
                tap(bar().hide_btn)
                expect(not plugin.bar, "Hide left the toolbar up")
                expect(not plugin.drawing, "Hide left drawing on with no way to stop it")
                baseline = { reader }
                settled("Hide")
                readerStillAnswers("after Hide")
            end)
        end

        -- The main menu, entry by entry.
        case("PDF menu: Start drawing turns drawing on and brings the toolbar", function()
            openMenu({ "JustDraw", "Start drawing" })
            closeMenu()
            expect(plugin.drawing, "Start drawing left drawing off")
            expect(plugin.bar, "drawing is on with no toolbar to stop it")
            baseline = stack()
            tap(plugin.bar.draw_btn)
            expect(not plugin.drawing, "Stop did not turn drawing off")
            settled("Start drawing")
        end)

        case("PDF menu: Toolbar side > Left and Right move the toolbar", function()
            for _, side in ipairs({ "Left", "Right" }) do
                openMenu({ "JustDraw", "Toolbar side", side })
                closeMenu()
                expect(plugin.bar_side == side:lower(), "side is %s after %s",
                    tostring(plugin.bar_side), side)
                baseline = stack()
            end
            settled("Toolbar side")
        end)

        case("PDF menu: Input mode radios apply", function()
            for _, mode in ipairs({ { "Finger", "finger" }, { "Automatic", "auto" } }) do
                openMenu({ "JustDraw", "Input mode", mode[1] })
                closeMenu()
                expect(plugin.input_mode == mode[2], "mode is %s after %s",
                    tostring(plugin.input_mode), mode[1])
            end
            settled("Input mode")
        end)

        case("PDF menu: Pen style and Pen width radios apply", function()
            openMenu({ "JustDraw", "Pen width", "Thin" })
            closeMenu()
            expect(plugin.pen_width == 2, "width is %s after Thin", tostring(plugin.pen_width))
            openMenu({ "JustDraw", "Pen width", "Medium" })
            closeMenu()
            openMenu({ "JustDraw", "Pen style", "Graphite" })
            closeMenu()
            openMenu({ "JustDraw", "Pen style", "Ink pen" })
            closeMenu()
            settled("Pen style/width")
        end)

        case("PDF menu: Drawing refresh opens its chooser, and it closes", function()
            roundTrip("Drawing refresh", function()
                openMenu({ "JustDraw", "Drawing refresh" })
                if stack()[1] == reader.menu.menu_container then
                    error("Drawing refresh left the main menu on top")
                end
            end)
            closeMenu()
            settled("Drawing refresh")
        end)

        case("PDF menu: Fast refresh while drawing toggles and toggles back", function()
            local touchmenu = openMenu({ "JustDraw" })
            local item
            for _, entry in ipairs(menuEntries(touchmenu)) do
                if menuText(entry) == "Fast refresh while drawing" then item = entry end
            end
            expect(item and item.checked_func, "no Fast refresh toggle")
            local was = item.checked_func()
            closeMenu()
            openMenu({ "JustDraw", "Fast refresh while drawing" })
            expect(item.checked_func() ~= was, "the toggle did not change")
            closeMenu()
            openMenu({ "JustDraw", "Fast refresh while drawing" })
            expect(item.checked_func() == was, "the toggle did not change back")
            closeMenu()
            settled("Fast refresh")
        end)

        case("PDF menu: Stylus diagnostics asks first, and Cancel starts nothing", function()
            roundTrip("Stylus diagnostics", function()
                openMenu({ "JustDraw", "Stylus diagnostics" })
            end)
            closeMenu()
            settled("Stylus diagnostics")
        end)

        case("PDF menu: Export… opens the export form, Cancel closes it", function()
            roundTrip("Export", function() openMenu({ "JustDraw", "Export…" }) end)
            closeMenu()
            settled("Export")
        end)

        case("PDF menu: Document notes opens the browser, and it closes", function()
            roundTrip("Document notes", function() openMenu({ "JustDraw", "Document notes" }) end)
            closeMenu()
            settled("Document notes")
        end)

        case("PDF menu: Page notes > Delete this page note asks, Cancel keeps the ink", function()
            -- Put a stroke on the page so there is something to delete.
            openMenu({ "JustDraw", "Start drawing" })
            closeMenu()
            baseline = stack()
            local session = plugin.document_session
            local rect = session:transform():canvasRect()
            local x, y = centre(rect)
            drag(x - 50, y, x + 50, y + 30, 8)
            tap(plugin.bar.draw_btn)
            local strokes = #session:cache():strokes()
            expect(strokes >= 1, "no stroke to delete")
            for _, entry in ipairs({ "Delete this page note", "Delete all page notes" }) do
                -- These keep the menu open under their question, on purpose:
                -- Cancel goes back to the menu, not to the page.
                local before = stack()[1]
                local touchmenu = openMenu({ "JustDraw", "Page notes", entry })
                opened(before, entry)
                dismiss(entry)
                expect(stack()[1] == reader.menu.menu_container,
                    "%s + Cancel did not go back to the menu (stack: %s)", entry, describeStack())
                expect(touchmenu, "no menu")
                closeMenu()
                expect(#session:cache():strokes() == strokes, "%s + Cancel deleted ink", entry)
            end
            settled("Page notes")
        end)

        case("PDF menu: Page notes > Delete this page note, confirmed, removes the ink", function()
            local session = plugin.document_session
            openMenu({ "JustDraw", "Page notes", "Delete this page note" })
            press("Delete")
            closeMenu()
            local cache = session:cache()
            expect(not cache or #cache:strokes() == 0, "the page still has %d strokes",
                cache and #cache:strokes() or -1)
            settled("Delete this page note")
        end)
    end
    if ok_open then
        case("PDF rotation: More open over the toolbar, then landscape and back", function()
            if not plugin.bar then
                openMenu({ "JustDraw", "Show toolbar" })
                closeMenu()
            end
            baseline = stack()
            local before = stack()[1]
            tap(plugin.bar.more_btn)
            local more = opened(before, "More")
            rotate(1)
            expect(plugin.bar and onStack(plugin.bar), "the toolbar is gone after rotating")
            expect(not onStack(more), "More stayed open under the rebuilt toolbar (stack: %s)",
                describeStack())
            allOnScreen("landscape")
            baseline = stack()
            expect(sameStack({ plugin.bar, reader }), "landscape left [%s]", describeStack())
            readerStillAnswers("in landscape")
            rotate(0)
            allOnScreen("portrait again")
            baseline = stack()
            expect(sameStack({ plugin.bar, reader }), "portrait left [%s]", describeStack())
            readerStillAnswers("back in portrait")
        end)
    end
    if reader then closeReader() end
end

-- ==================================================================== EPUB

if not epub or lfs.attributes(epub, "mode") ~= "file" then
    skip("EPUB: drawing sheet", "set JUSTDRAW_EPUB to test-data juliet.epub")
else
    local ok_open = case("EPUB: the reader opens with the plugin loaded", function()
        openReader(epub)
        expect(plugin.session, "no sheet session: %s", tostring(plugin.open_error))
        wait(5, function() return not plugin.session:isIndexing() end)
        -- The sheet's own toolbar replaces the side one; start without it.
        if plugin.bar then plugin:setBarShown(false) end
        tick(2)
        baseline = stack()
    end)
    if ok_open then
        local function sheetBar()
            local overlay = plugin.session and plugin.session:overlay()
            return overlay and overlay.bar
        end
        local function overlay() return plugin.session:overlay() end

        case("EPUB menu: Drawing sheet > Open sheet here opens a sheet with drawing on", function()
            openMenu({ "JustDraw", "Drawing sheet", "Open sheet here" })
            closeMenu()
            expect(plugin.canvas_open, "no sheet open")
            expect(overlay() and onStack(overlay()), "the sheet is not on the stack")
            expect(plugin.drawing, "a new sheet does not start with drawing on")
            baseline = stack()
        end)

        if plugin.canvas_open then
            case("EPUB sheet: Stop and Draw toggle drawing", function()
                tap(sheetBar().draw_btn)
                expect(not plugin.drawing, "Stop did not turn drawing off")
                tap(sheetBar().draw_btn)
                expect(plugin.drawing, "Draw did not turn drawing on")
                settled("Draw/Stop")
            end)

            case("EPUB sheet: switch to the stylus route through More > Input mode", function()
                tap(sheetBar().draw_btn)   -- the mode is locked while drawing
                local before = stack()[1]
                tap(sheetBar().more_btn)
                press("Input mode", opened(before, "More"))
                press("Stylus")
                expect(plugin.input_mode == "stylus", "mode is %s", tostring(plugin.input_mode))
                settled("Input mode > Stylus")
                tap(sheetBar().draw_btn, "pen")
                expect(plugin.drawing and plugin.input_backend == "stylus",
                    "drawing %s on backend %s", tostring(plugin.drawing), tostring(plugin.input_backend))
            end)

            case("EPUB sheet: a pen stroke is ink on the sheet, and Undo takes it back", function()
                local rect = overlay().transform:canvasRect()
                local x, y = centre(rect)
                local cache = expect(plugin.session:cache(), "the sheet has no raster")
                local before = #cache:strokes()
                drag(x - 60, y - 20, x + 60, y + 30, 10, "pen")
                expect(#plugin.session:cache():strokes() == before + 1,
                    "a pen stroke made %d strokes, from %d", #plugin.session:cache():strokes(), before)
                tap(sheetBar().undo_btn, "pen")
                expect(#plugin.session:cache():strokes() == before, "Undo left %d strokes",
                    #plugin.session:cache():strokes())
                settled("sheet Undo")
            end)

            toolCases("EPUB sheet", sheetBar, "pen")

            case("EPUB sheet: a hold on every icon names it", function()
                expect(iconsNameThemselves(sheetBar(), "the sheet header") >= 6,
                    "the sheet header has fewer icons than expected")
                settled("holds")
            end)

            case("EPUB sheet: Notes opens the document notes, and they close", function()
                roundTrip("Notes", function() tap(sheetBar().notes_btn, "pen") end)
            end)

            for _, entry in ipairs({ "Document notes", "Pen settings", "Drawing refresh",
                    "Input mode", "Export…" }) do
                case("EPUB sheet: More > " .. entry, function() moreEntry(sheetBar(), entry) end)
            end

            case("EPUB sheet: More > Delete sheet asks, Cancel keeps it", function()
                moreEntry(sheetBar(), "Delete sheet")
                expect(plugin.canvas_open, "Cancel closed the sheet")
            end)

            case("EPUB sheet: More > Close", function()
                pressMoreAndClose(sheetBar())
                settled("More > Close")
            end)

            case("EPUB sheet: the height button steps 40 → 70 → 100 → 40", function()
                local seen = {}
                for _ = 1, 4 do
                    tap(sheetBar().height_btn, "pen")
                    tick(3)
                    seen[#seen + 1] = overlay().height_pct
                    baseline = stack()
                end
                local s = table.concat(seen, ",")
                expect(s == "40,70,100,40" or s == "70,100,40,70" or s == "100,40,70,100",
                    "the height went %s", s)
                expect(sheetBar().height_btn.text == overlay().height_pct .. " %",
                    "the button reads %q at %d%%", tostring(sheetBar().height_btn.text),
                    overlay().height_pct)
                settled("height")
            end)

            case("EPUB sheet: rotating keeps the sheet and its header across the screen", function()
                rotate(1)
                expect(plugin.canvas_open, "rotating closed the sheet")
                expect(sheetBar().dimen.w == Screen:getWidth(), "the header is %d wide on a %d screen",
                    sheetBar().dimen.w, Screen:getWidth())
                allOnScreen("sheet in landscape")
                rotate(0)
                expect(sheetBar().dimen.w == Screen:getWidth(), "the header did not follow back")
                allOnScreen("sheet in portrait")
                baseline = stack()
                settled("sheet rotation")
            end)

            case("EPUB sheet: Hide puts the sheet away and gives the page back", function()
                tap(sheetBar().draw_btn, "pen")   -- Stop, so the mode can change back
                tap(sheetBar().hide_btn, "pen")
                expect(not plugin.canvas_open, "Hide left the sheet open")
                expect(not plugin.drawing, "Hide left drawing on")
                baseline = { reader }
                settled("Hide")
                plugin:setInputMode("auto")
                readerStillAnswers("after the sheet")
            end)

            case("EPUB menu: the same sheet reopens here, and Close sheet closes it", function()
                openMenu({ "JustDraw", "Drawing sheet", "Open sheet here" })
                closeMenu()
                expect(plugin.canvas_open, "the sheet did not reopen")
                baseline = stack()
                openMenu({ "JustDraw", "Drawing sheet", "Close sheet" })
                closeMenu()
                expect(not plugin.canvas_open, "Close sheet left it open")
                baseline = { reader }
                settled("Close sheet")
            end)
        end
    end

    -- ======================================================= document notes

    if reader then
        local notes
        local function browser() return notes and notes.browser end
        local function catalogReady()
            local c = notes and notes.catalog
            return c ~= nil and c.state == "ready" and not c.busy
        end

        --- The catalogue is ready and the browser has caught up with it: its
        --- rebuild is debounced by 0.2 s (Controller:changed).
        local function settleBrowser()
            return wait(5, function()
                return catalogReady() and not notes.refresh_pending
            end)
        end

        --- Open the browser from the menu and wait for its catalogue.
        local function openBrowser()
            openMenu({ "JustDraw", "Document notes" })
            notes = expect(plugin.notes_controller, "no notes controller")
            expect(browser() and onStack(browser()), "the browser is not up (stack: %s)",
                describeStack())
            local ready = settleBrowser()
            if DEBUG then
                local c = notes.catalog
                print("  catalog", c and c.state, c and c.busy, c and #c.items, c and #c.result,
                    "filter enabled", findButton(browser(), "Filter") and findButton(browser(), "Filter").enabled)
            end
            expect(ready, "the catalogue never finished loading (state %s)",
                tostring(notes.catalog and notes.catalog.state))
            paint()
            baseline = stack()
        end

        --- Each case starts in the browser, whatever the last one left.
        local function ensureBrowser()
            if not (browser() and onStack(browser())) then openBrowser() end
            settleBrowser()
            baseline = stack()
        end

        --- A KOReader Menu's entry by its text, or the start of it (Menu items
        --- are not Buttons), turning the Menu's pages until it shows.
        local function menuEntry(root, text)
            local found, seen
            for _ = 1, root.page_num or 1 do
                paint()
                seen = {}
                walk(root, function(w)
                    if type(w.text) == "string" and w.dimen and w.onTapSelect then
                        seen[#seen + 1] = w.text
                        if w.text == text or w.text:sub(1, #text) == text then
                            found = w
                            return true
                        end
                    end
                end)
                if found or not root.onNextPage then break end
                root:onNextPage()
            end
            return expect(found, "no entry %q in %s; it shows: %s", text, name(root),
                table.concat(seen, " | "))
        end

        --- Every entry of a Menu is on its first page.
        local function onePage(menu, what)
            expect((menu.page_num or 1) == 1, "%s spreads over %d pages", what, menu.page_num or 1)
        end

        --- The browser's rows: every row button between the actions and the pager.
        local function rows()
            local out = {}
            for y = 2, #browser().layout - 1 do out[#out + 1] = browser().layout[y][1] end
            return out
        end

        local ok_notes = case("Notes: a sheet with ink, to have something to browse", function()
            openMenu({ "JustDraw", "Drawing sheet", "Open sheet here" })
            closeMenu()
            baseline = stack()
            local bar = plugin.session:overlay().bar
            ensureDrawing(bar, false)
            plugin:setInputMode("stylus")
            tap(plugin.session:overlay().bar.draw_btn, "pen")
            local rect = plugin.session:overlay().transform:canvasRect()
            local x, y = centre(rect)
            drag(x - 60, y - 20, x + 60, y + 30, 10, "pen")
            expect(#plugin.session:cache():strokes() >= 1, "no stroke on the sheet")
            tap(plugin.session:overlay().bar.draw_btn, "pen")
            tap(plugin.session:overlay().bar.hide_btn, "pen")
            plugin:setInputMode("auto")
            expect(not plugin.canvas_open, "the sheet did not close")
            baseline = { reader }
            settled("a sheet with ink")
        end)

        if ok_notes then
            case("Notes browser: opens from the menu and lists the sheet", function()
                openBrowser()
                expect(#rows() >= 1, "the browser lists nothing")
                local actions = browser().layout[1]
                expect(#actions == 3, "the action row has %d buttons", #actions)
            end)

            case("Notes browser: Filter lists every filter, and each one applies", function()
                ensureBrowser()
                local c = notes.catalog
                for _, entry in ipairs({ "Drawing sheets", "Page notes", "Without location",
                        "All notes" }) do
                    local before = stack()[1]
                    press(entry == "All notes" and "Filtered" or "Filter", browser())
                    local menu = opened(before, "Filter")
                    tap(menuEntry(menu, entry))
                    expect(not onStack(menu), "%s left the filter menu open", entry)
                    settleBrowser()
                    settled("Filter > " .. entry)
                    if entry == "All notes" then
                        expect(next(c.filter) == nil, "All notes left a filter")
                        expect(findButton(browser(), "Filter"), "the button still says Filtered")
                    else
                        expect(next(c.filter) ~= nil, "%s set no filter", entry)
                        expect(findButton(browser(), "Filtered"), "the button does not say Filtered")
                    end
                end
            end)

            for _, entry in ipairs({ "Page range…", "Search annotation text…" }) do
                case("Notes browser: Filter > " .. entry .. " opens a form, Cancel closes it", function()
                    local before = stack()[1]
                    press("Filter", browser())
                    tap(menuEntry(opened(before, "Filter"), entry))
                    local form = opened(before, entry)
                    if form.onCloseKeyboard then form:onCloseKeyboard() end
                    dismiss(entry)
                    settled(entry)
                end)
            end

            case("Notes browser: Filter > Sort flips the order and its label", function()
                ensureBrowser()
                local c = notes.catalog
                local order = c.order
                local before = stack()[1]
                press("Filter", browser())
                local menu = opened(before, "Filter")
                local label = order == "recent" and "Sort in document order" or "Sort by last change"
                tap(menuEntry(menu, label))
                settleBrowser()
                expect(c.order ~= order, "the order is still %s", tostring(order))
                settled("Sort")
                press("Filter", browser())
                tap(menuEntry(opened(before, "Filter"),
                    c.order == "recent" and "Sort in document order" or "Sort by last change"))
                settleBrowser()
                expect(c.order == order, "the order did not flip back")
                settled("Sort back")
            end)

            case("Notes browser: Filter > Chapter… opens and closes", function()
                ensureBrowser()
                local before = stack()[1]
                press("Filter", browser())
                tap(menuEntry(opened(before, "Filter"), "Chapter…"))
                dropToasts()
                if stack()[1] ~= before then dismiss("Chapter") end
                settled("Chapter")
            end)

            case("Notes browser: Filter > KOReader annotations hands over to KOReader's list", function()
                ensureBrowser()
                local before = stack()[1]
                press("Filter", browser())
                tap(menuEntry(opened(before, "Filter"), "KOReader annotations"))
                dropToasts()
                expect(browser() == nil, "the browser stayed open under KOReader's list")
                if stack()[1] ~= reader then dismiss("KOReader's annotations") end
                baseline = { reader }
                settled("KOReader annotations")
            end)

            case("Notes browser: the Filter menu has no Close row; its ✕ closes it", function()
                ensureBrowser()
                local before = stack()[1]
                press("Filter", browser())
                local menu = opened(before, "Filter")
                for _, item in ipairs(menu.item_table) do
                    expect(item.text ~= "Close", "a Close row: the title bar's ✕ already closes it")
                end
                dismiss("Filter")
                settled("Filter ✕")
            end)

            case("Notes browser: Select marks a row, Done selecting ends it", function()
                ensureBrowser()
                press("Select", browser())
                expect(browser().select_mode, "Select did not start selecting")
                expect(findButton(browser(), "Done selecting"), "the button does not say Done selecting")
                tap(rows()[1])
                settleBrowser()
                expect(notes.catalog:selectionCount() == 1, "a tap selected %d notes",
                    notes.catalog:selectionCount())
                expect(labelOf(rows()[1]):find("☑", 1, true), "the row is not marked")
                tap(rows()[1])
                settleBrowser()
                expect(notes.catalog:selectionCount() == 0, "a second tap did not unselect")
                press("Done selecting", browser())
                expect(not browser().select_mode, "Done selecting did not end it")
                settled("Select")
            end)

            case("Notes browser: Export… fits one page; a scope opens its form, Cancel closes it", function()
                ensureBrowser()
                local before = stack()[1]
                press("Export…", browser())
                onePage(opened(before, "Export options"), "Export and selection")
                dismiss("Export options")
                settled("Export options")
                press("Export…", browser())
                tap(menuEntry(opened(before, "Export options"), "All document notes ("))
                -- "Preparing notes…" first, then the form.
                expect(wait(5, function() return notes.loading == nil and stack()[1] ~= before end),
                    "the export form never came up (stack: %s)", describeStack())
                dismiss("Export form")
                settled("Export all")
            end)

            case("Notes browser: the page counter asks for a page, Cancel closes it", function()
                ensureBrowser()
                local pager = browser().layout[#browser().layout]
                expect(pager[1].enabled == false and pager[3].enabled == false,
                    "Previous/Next are enabled on a single page")
                local before = stack()[1]
                tap(pager[2])
                local dialog = opened(before, "Go to list page")
                if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
                dismiss("Go to list page")
                settled("Go to list page")
            end)

            local function openDetail()
                local before = stack()[1]
                tap(rows()[1])
                expect(wait(5, function()
                    return notes.detail ~= nil and onStack(notes.detail)
                end), "the note never opened (stack: %s)", describeStack())
                paint()
                return notes.detail, before
            end

            case("Note detail: opens from a row; Previous/Next are off for a single note", function()
                ensureBrowser()
                local detail = openDetail()
                local bt = detail.button_table
                expect(#notes.catalog.result == 1, "the list holds %d notes", #notes.catalog.result)
                expect(findButton(bt, "Previous").enabled == false, "Previous is on for the only note")
                expect(findButton(bt, "Next").enabled == false, "Next is on for the only note (%s)",
                    labelOf(findButton(bt, "Next")))
                dismiss("the note")
                settled("detail")
            end)

            case("Note detail: Scale and Rotate relabel, − and + zoom, all in place", function()
                ensureBrowser()
                local detail = openDetail()
                local fit = findButton(detail.button_table, "Original size") and "Original size" or "Scale"
                local other = fit == "Scale" and "Original size" or "Scale"
                press(fit, detail)
                expect(findButton(notes.detail.button_table, other), "%s did not relabel", fit)
                press(other, notes.detail)
                press("Rotate", notes.detail)
                expect(findButton(notes.detail.button_table, "No rotation"), "Rotate did not relabel")
                press("No rotation", notes.detail)
                local scale = notes.detail.scale_factor
                press("+", notes.detail)
                press("−", notes.detail)
                expect(notes.detail and onStack(notes.detail), "zooming closed the note")
                expect(stack()[1] == notes.detail, "zooming opened something over the note")
                dismiss("the note")
                settled("zoom")
                expect(scale ~= nil, "no scale")
            end)

            case("Note detail: Actions… offers its actions; Organize and Export open and close", function()
                ensureBrowser()
                local detail = openDetail()
                press("Actions…", detail)
                local actions = opened(detail, "Actions")
                expect(findButton(actions, "Add sheet at end"), "no Add sheet at end")
                expect(findButton(actions, "Edit in document"), "no Edit in document")
                expect(findButton(actions, "Organize sheets…").enabled == false,
                    "Organize is offered for a note with one sheet")
                -- Export closes the note first, to free its preview, and
                -- Cancel lands in the list.
                press("Export this note…", actions)
                expect(wait(5, function() return notes.loading == nil and stack()[1] ~= browser() end),
                    "the export form never came up (stack: %s)", describeStack())
                dismiss("Export this note")
                expect(stack()[1] == browser(), "Export left [%s]", describeStack())
                openDetail()
                press("Actions…", notes.detail)
                press("Close", opened(notes.detail, "Actions"))
                expect(stack()[1] == notes.detail, "Actions > Close did not go back to the note")
                dismiss("the note")
                settled("actions")
            end)

            case("Note detail: Actions > Add sheet at end opens a new sheet of the same note", function()
                ensureBrowser()
                openDetail()
                press("Actions…", notes.detail)
                press("Add sheet at end", opened(notes.detail, "Actions"))
                tick(4)
                expect(browser() == nil, "the browser is still open")
                expect(plugin.canvas_open, "no sheet opened (stack: %s)", describeStack())
                baseline = stack()
                local bar = plugin.session:overlay().bar
                ensureDrawing(bar, false)
                tap(bar.hide_btn)
                tick(4)
                if plugin.bar and plugin.bar.note_return then tap(plugin.bar.dismiss_btn) end
                expect(not plugin.canvas_open, "the new sheet stayed open")
                baseline = stack()
                settled("Add sheet")
            end)

            case("Note detail: two sheets -- Next sheet steps, Organize opens its list", function()
                ensureBrowser()
                openDetail()
                local next_sheet = expect(findButton(notes.detail.button_table, "Next sheet"),
                    "no Next sheet on a two-sheet note: %s",
                    table.concat(buttonLabels(notes.detail.button_table), " | "))
                tap(next_sheet)
                expect(wait(5, function() return notes.detail ~= nil and onStack(notes.detail) end),
                    "Next sheet closed the note")
                paint()
                expect(findButton(notes.detail.button_table, "Previous sheet"), "no Previous sheet on sheet 2")
                expect(findButton(notes.detail.button_table, "Next").enabled == false,
                    "Next is on at the last sheet")
                press("Actions…", notes.detail)
                press("Organize sheets…", opened(notes.detail, "Actions"))
                dismiss("Reorder sheets")
                expect(stack()[1] == notes.detail, "Organize left [%s]", describeStack())
                dismiss("the note")
                settled("two sheets")
            end)

            case("Note detail: Read from here goes to the text and puts up the note bar", function()
                ensureBrowser()
                openDetail()
                press("Read from here", notes.detail)
                tick(4)
                expect(browser() == nil, "the browser is still open")
                expect(plugin.bar and plugin.bar.note_return, "no note bar (stack: %s)", describeStack())
                expect(not plugin.canvas_open, "Read from here opened the sheet")
                baseline = stack()
                expect(baseline[1] == plugin.bar, "the note bar is not on top")
                readerStillAnswers("with the note bar up")
            end)

            if plugin.bar and plugin.bar.note_return then
                case("Note bar: Show note opens the sheet; its ✕ brings the bar back", function()
                    tap(plugin.bar.show_btn)
                    tick(4)
                    expect(plugin.canvas_open, "Show note did not open the sheet")
                    local hide = plugin.session:overlay().bar.hide_btn
                    expect(hide.tool_label == "Hide note", "the ✕ is named %q", tostring(hide.tool_label))
                    tap(hide)
                    tick(4)
                    expect(not plugin.canvas_open, "Hide note left the sheet open")
                    expect(plugin.bar and plugin.bar.note_return, "the note bar did not come back")
                    baseline = stack()
                    settled("Show/Hide note")
                end)

                case("Note bar: the notes icon reopens the browser, its ✕ closes it", function()
                    roundTrip("notes from the note bar", function() tap(plugin.bar.notes_btn) end)
                end)

                case("Note bar: a hold on every icon names it", function()
                    iconsNameThemselves(plugin.bar, "the note bar")
                    settled("holds")
                end)

                case("Note bar: ✕ dismisses it", function()
                    tap(plugin.bar.dismiss_btn)
                    expect(not (plugin.bar and plugin.bar.note_return), "the note bar is still up")
                    baseline = stack()
                    settled("Dismiss")
                    readerStillAnswers("after the note bar")
                end)
            end

            case("Note detail: View on page opens the sheet as a note, at 40 %", function()
                openBrowser()
                openDetail()
                press("View on page", notes.detail)
                tick(4)
                expect(browser() == nil, "the browser is still open")
                expect(plugin.canvas_open, "View on page did not open the sheet")
                expect(plugin.session:overlay().height_pct == 40, "the note opened at %d%%",
                    plugin.session:overlay().height_pct)
                baseline = stack()
                tap(plugin.session:overlay().bar.hide_btn)
                tick(4)
                if plugin.bar and plugin.bar.note_return then tap(plugin.bar.dismiss_btn) end
                expect(not plugin.canvas_open, "the note stayed open")
                baseline = stack()
                settled("View on page")
            end)

            case("Notes browser: rotating with Filter open closes Filter and relays the list", function()
                ensureBrowser()
                local before = stack()[1]
                press("Filter", browser())
                local menu = opened(before, "Filter")
                rotate(1)
                expect(not onStack(menu), "Filter survived the rotation, laid out for the old screen")
                expect(browser() and onStack(browser()), "the browser is gone")
                expect(browser().dimen.w == Screen:getWidth(), "the list was not relaid")
                rotate(0)
                expect(browser().dimen.w == Screen:getWidth(), "the list did not follow back")
                settleBrowser()
                baseline = stack()
                settled("browser rotation")
            end)

            case("Notes browser: its close icon closes it", function()
                openBrowser()
                dismiss("the browser")
                expect(browser() == nil, "the controller still holds the browser")
                baseline = stack()
                settled("browser")
            end)
        end
    end

    -- ============================================================ notebooks

    if reader then
        local nui
        local function library() return nui and nui.library end
        local function editor() return nui and nui.editor end

        local ok_lib = case("Notebooks: JustDraw > Notebooks opens the library", function()
            -- The finger draws in a notebook only on the finger route.
            plugin:setInputMode("auto")
            openMenu({ "JustDraw", "Notebooks" })
            closeMenu()
            nui = expect(plugin.notebook_ui, "no notebook UI")
            expect(library() and onStack(library()), "the library is not on the stack")
            wait(3, function() return library().batch ~= nil end)
            baseline = stack()
        end)

        if ok_lib then
            case("Notebooks library: New notebook, Cancel", function()
                roundTrip("New notebook", function() press("New notebook", library()) end)
            end)

            case("Notebooks library: New notebook with a name and Ruled paper opens it", function()
                local before = stack()[1]
                press("New notebook", library())
                local dialog = opened(before, "New notebook")
                if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
                tick(2)
                dialog = library().create_dialog or dialog
                dialog.input_fields[1]:setText("Buttons")
                local ruled
                walk(dialog, function(w)
                    if w.text == "Ruled" and w.dimen then ruled = w; return true end
                end)
                if ruled then tap(ruled) end
                press("Create", dialog)
                expect(editor(), "Create did not open the notebook (stack: %s)", describeStack())
                wait(3, function() return editor().snapshot and editor().snapshot.state == "ready" end)
                expect(editor().snapshot.state == "ready", "the page is %s",
                    tostring(editor().snapshot.state))
                baseline = stack()
            end)

            if editor() then
                local function rail(i) return editor().layout[1][i] end
                local EXIT, PEN, ERASER, UNDO, PREV, NEXT, ADD, MORE = 1, 2, 3, 4, 5, 6, 7, 8

                case("Notebook editor: Eraser selects the eraser, Pen gives it back", function()
                    tap(rail(ERASER))
                    expect(plugin.eraser or editor().get_eraser(), "Eraser did not select the eraser")
                    expect(rail(ERASER).tool_selected, "the eraser does not show as selected")
                    tap(rail(PEN))
                    expect(not editor().get_eraser(), "Pen did not leave the eraser")
                    settled("Eraser/Pen")
                end)

                case("Notebook editor: a hold on every icon names it", function()
                    expect(iconsNameThemselves(editor(), "the notebook rail") == 8,
                        "the rail is not eight icons")
                    settled("holds")
                end)

                case("Notebook editor: the selected Pen opens pen settings, Close closes them", function()
                    roundTrip("Pen settings", function() tap(rail(PEN)) end)
                end)

                case("Notebook editor: a stroke enables Undo, and Undo takes it back", function()
                    expect(rail(UNDO).enabled == false, "Undo is enabled on an empty page")
                    local paper = editor().layout_geometry.paper_rect
                    local x, y = centre(paper)
                    drag(x - 60, y - 20, x + 60, y + 40, 10)
                    tick(4)
                    expect(editor().snapshot.can_undo, "the stroke gave nothing to undo")
                    expect(rail(UNDO).enabled, "Undo is still disabled after a stroke")
                    tap(rail(UNDO))
                    tick(4)
                    expect(not editor().snapshot.can_undo, "Undo left something to undo")
                    settled("notebook Undo")
                end)

                case("Notebook editor: page buttons -- Add, Previous, Next, and the edges", function()
                    local s = editor().snapshot
                    expect(s.page_count == 1, "a new notebook has %d pages", s.page_count)
                    expect(rail(PREV).enabled == false and rail(NEXT).enabled == false,
                        "Previous/Next are enabled on a one-page notebook")
                    tap(rail(ADD))
                    wait(3, function() return editor().snapshot.page_count == 2
                        and editor().snapshot.state == "ready" end)
                    s = editor().snapshot
                    expect(s.page_count == 2 and s.page_position == 2,
                        "Add page made page %s of %s", tostring(s.page_position), tostring(s.page_count))
                    tap(rail(PREV))
                    wait(3, function() return editor().snapshot.page_position == 1
                        and editor().snapshot.state == "ready" end)
                    expect(editor().snapshot.page_position == 1, "Previous did not go to page 1")
                    expect(rail(PREV).enabled == false, "Previous is enabled on the first page")
                    tap(rail(NEXT))
                    wait(3, function() return editor().snapshot.page_position == 2
                        and editor().snapshot.state == "ready" end)
                    expect(editor().snapshot.page_position == 2, "Next did not go to page 2")
                    settled("page buttons")
                end)

                local function editorMore(entry, check)
                    roundTrip("More > " .. entry, function()
                        local before = stack()[1]
                        tap(rail(MORE))
                        press(entry, opened(before, "More"))
                    end, check)
                end

                for _, entry in ipairs({ "Go to page…", "Pen settings", "Export…",
                        "Rename", "Drawing refresh", "Input mode",
                        "Stylus diagnostics", "Delete page", "Delete notebook" }) do
                    case("Notebook editor: More > " .. entry .. " opens, and closes", function()
                        editorMore(entry)
                        expect(editor(), "the editor went away")
                    end)
                end

                case("Notebook editor: More > Go to page… 1, Go", function()
                    local before = stack()[1]
                    tap(rail(MORE))
                    press("Go to page…", opened(before, "More"))
                    local dialog = opened(before, "Go to page")
                    if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
                    dialog._input_widget:setText("1")
                    press("Go", dialog)
                    wait(3, function() return editor().snapshot.page_position == 1
                        and editor().snapshot.state == "ready" end)
                    expect(editor().snapshot.page_position == 1, "Go to page 1 went to page %s",
                        tostring(editor().snapshot.page_position))
                    settled("Go to page")
                end)

                case("Notebook editor: More > Paper style, Squared applies and closes", function()
                    local before = stack()[1]
                    tap(rail(MORE))
                    press("Paper style", opened(before, "More"))
                    press("Squared", opened(before, "Paper"))
                    settled("Paper > Squared")
                end)

                case("Notebook editor: More > Delete page, confirmed, leaves one page", function()
                    local before = stack()[1]
                    tap(rail(MORE))
                    press("Delete page", opened(before, "More"))
                    press("Delete", opened(before, "Delete page"))
                    wait(3, function() return editor().snapshot.page_count == 1 end)
                    expect(editor().snapshot.page_count == 1, "the notebook has %d pages",
                        editor().snapshot.page_count)
                    settled("Delete page")
                end)

                case("Notebook editor: More > Close", function()
                    local before = stack()[1]
                    tap(rail(MORE))
                    press("Close", opened(before, "More"))
                    settled("More > Close")
                end)

                case("Notebook editor: rotating with More open relays the rail", function()
                    local before = stack()[1]
                    tap(rail(MORE))
                    local more = opened(before, "More")
                    rotate(1)
                    expect(editor(), "rotating closed the notebook")
                    expect(editor().layout_geometry.rail_rect.w <= Screen:getWidth()
                        and editor().dimen.w == Screen:getWidth(), "the rail was not relaid")
                    if onStack(more) then dismiss("More, rotated") end
                    allOnScreen("notebook in landscape")
                    rotate(0)
                    expect(editor().dimen.w == Screen:getWidth(), "the editor did not follow back")
                    allOnScreen("notebook in portrait")
                    baseline = stack()
                    settled("notebook rotation")
                end)

                case("Notebook editor: Exit notebook goes back to the library", function()
                    tap(rail(EXIT))
                    wait(3, function() return editor() == nil end)
                    expect(editor() == nil, "the editor is still open")
                    expect(stack()[1] == library(), "the library is not on top (stack: %s)",
                        describeStack())
                    baseline = stack()
                end)
            end

            case("Notebooks library: Actions > Rename, Delete, Export… each open and close", function()
                for _, entry in ipairs({ "Rename", "Delete", "Export…" }) do
                    roundTrip("Actions > " .. entry, function()
                        local before = stack()[1]
                        press("Actions", library())
                        press(entry, opened(before, "Actions"))
                    end)
                end
            end)

            case("Notebooks library: Actions > Close", function()
                local before = stack()[1]
                press("Actions", library())
                press("Close", opened(before, "Actions"))
                settled("Actions > Close")
            end)

            case("Notebooks library: a row opens its notebook, and Exit comes back", function()
                local row = expect(findButton(library(), "Buttons"), "no row for the notebook")
                tap(row)
                wait(3, function() return editor() ~= nil end)
                expect(editor(), "the row did not open the notebook")
                tap(editor().layout[1][1])
                wait(3, function() return editor() == nil end)
                expect(stack()[1] == library(), "not back in the library (stack: %s)", describeStack())
                settled("row")
            end)

            case("Notebooks library: its close icon closes the library", function()
                dismiss("library")
                baseline = { reader }
                settled("library")
                expect(nui.library == nil, "the UI still holds the library")
            end)
        end
    end
    if reader then closeReader() end
end

-- ================================================================== report

print(string.format("SUMMARY %d passed, %d failed, %d skipped", results.pass, results.fail,
    results.skip))
if results.fail == 0 and results.pass > 0 then
    print("BUTTONS_NATIVE_OK " .. home)
    os.exit(0)
end
os.exit(1)
