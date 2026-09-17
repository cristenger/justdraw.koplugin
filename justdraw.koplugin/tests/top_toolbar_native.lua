--[[--
The two top toolbars against KOReader's real widgets: the notebook editor's row
and a document sheet's header.

The suite's Button is a stub with no frame and no pixels. It cannot say whether
a real Button fits the slot it was handed, whether the plugin's SVGs rasterize,
whether the selection mark lands under the glyph -- or stays visible on a
focused, inverted button -- or whether a tap reaches a callback through the
real gesture ranges. This does, at four screen profiles, and leaves a PNG of
each header behind to look at.

    cd <koreader-build>/koreader && ./luajit <repo>/justdraw.koplugin/tests/top_toolbar_native.lua [out-dir]

Run like that it is a driver. The SDL framebuffer reads EMULATE_READER_W/H/DPI
once per process, so it runs itself again for each profile, with a fresh
KO_HOME under out-dir (a new temporary folder when omitted) and SDL's dummy
video driver: no window, no document, no personal settings. Exit 0 and
TOP_TOOLBAR_CHECK_OK only when every profile exited cleanly and printed its own
marker. Deliberately not in tests/run.lua, which must run on bare LuaJIT.
]]

local this = debug.getinfo(1, "S").source:sub(2)

local PROFILES = {
    -- paper_h: the height a new sheet is stored with. page_w/page_h: the shape
    -- a new notebook page is stored with, in logical units (8 per mm) at this
    -- profile's density. Both pinned, because a header that changes height
    -- letterboxes every sheet and every notebook created afterwards.
    { name = "portrait", w = 600, h = 800, dpi = 160, paper_h = 650,
        page_w = 762, page_h = 843 },
    { name = "landscape", w = 800, h = 600, dpi = 160, paper_h = 456,
        page_w = 1016, page_h = 589 },
    { name = "scribe-portrait", w = 1860, h = 2480, dpi = 300, paper_h = 2122,
        page_w = 1260, page_h = 1432 },
    { name = "scribe-landscape", w = 2480, h = 1860, dpi = 300, paper_h = 1502,
        page_w = 1680, page_h = 1012 },
}

local function quote(value)
    return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command))
    local out = pipe:read("*a")
    pipe:close()
    return (out:gsub("%s+$", ""))
end

if not os.getenv("JUSTDRAW_TOOLBAR_PROFILE") then
    local out = arg[1] or run('mktemp -d "${TMPDIR:-/tmp}/justdraw-top-toolbar.XXXXXX"')
    assert(out ~= "", "could not create an output folder")
    os.execute("mkdir -p " .. quote(out))
    local failed = 0
    for _, profile in ipairs(PROFILES) do
        local home = run("mktemp -d " .. quote(out .. "/" .. profile.name .. ".XXXXXX"))
        local log = home .. "/probe.log"
        local status = os.execute(table.concat({
            "KO_HOME=" .. quote(home),
            "SDL_VIDEODRIVER=dummy",
            "EMULATE_READER_W=" .. profile.w,
            "EMULATE_READER_H=" .. profile.h,
            "EMULATE_READER_DPI=" .. profile.dpi,
            "JUSTDRAW_TOOLBAR_PROFILE=" .. quote(profile.name),
            "./luajit", quote(this), ">", quote(log), "2>&1",
        }, " "))
        local file = io.open(log, "r")
        local text = file and file:read("*a") or ""
        if file then file:close() end
        -- LuaJIT answers os.execute with a number, or with true under 5.2
        -- compatibility; either way only a clean exit and the marker pass.
        local exited = status == 0 or status == true
        local marked = text:find("TOP_TOOLBAR_NATIVE_OK " .. profile.name, 1, true) ~= nil
        if exited and marked then
            print("OK   " .. profile.name .. "  " .. home)
        else
            failed = failed + 1
            print("FAIL " .. profile.name .. "  " .. home)
            print(text)
        end
    end
    if failed > 0 then
        print(failed .. " profile(s) failed")
        os.exit(1)
    end
    print("TOP_TOOLBAR_CHECK_OK " .. out)
    os.exit(0)
end

-- ------------------------------------------------------------ one profile

require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local home = assert(os.getenv("KO_HOME"), "KO_HOME is required")
assert(not lfs.attributes(home .. "/settings.reader.lua"), "KO_HOME must be fresh")
local root = assert(this:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
-- No highlight dance: the dummy screen has nothing to flash, and the callback
-- is what is under test.
G_reader_settings:saveSetting("flash_ui", false)

local Device = require("device")
require("document/canvascontext"):init(Device)
local BB = require("ffi/blitbuffer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Editor = require("ink_notebook_editor")
local Layout = require("ink_notebook_layout")
local Overlay = require("ink_canvas_overlay")

local profile = os.getenv("JUSTDRAW_TOOLBAR_PROFILE")
local Screen = Device.screen
local W, H = Screen:getWidth(), Screen:getHeight()
local checks = 0
local function check(ok, why)
    assert(ok, profile .. ": " .. why)
    checks = checks + 1
end

check(W == tonumber(os.getenv("EMULATE_READER_W"))
    and H == tonumber(os.getenv("EMULATE_READER_H")), "the profile's screen is the one in use")

local function gray(bb, x, y)
    return bb:getPixel(x, y):getColor8().a
end

local function tap(widget, button)
    local d = button.dimen
    return widget:handleEvent(Event:new("Gesture", {
        ges = "tap", pos = Geom:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2) },
    }))
end

--- Where ink_tool_button puts the selection mark: the middle of its bar.
local function markPoint(button)
    local d = button.dimen
    local inset = (button.bordersize or 0) + (button.padding_v or button.padding or 0)
    local thickness = math.max(2, 2 * Size.border.button)
    return d.x + math.floor(d.w / 2), d.y + d.h - inset - thickness + math.floor(thickness / 2)
end

local function checkIcon(button, where)
    local icon = button.label_widget
    check(icon.file:find("/icons/toolbar-" .. button.icon .. ".svg", 1, true) ~= nil,
        where .. " " .. button.icon .. " uses the plugin's own file")
    check(lfs.attributes(icon.file, "mode") == "file", where .. " " .. button.icon .. " file resolves")
    local bb = icon._bb
    check(bb ~= nil, where .. " " .. button.icon .. " rasterized before paint")
    local dark = 0
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            if gray(bb, x, y) < 0x80 then dark = dark + 1 end
        end
    end
    check(dark > 0, where .. " " .. button.icon .. " has a visible glyph")
end

local bb = BB.new(W, H, BB.TYPE_BB8)

-- ------------------------------------------------------------ notebook

-- A new notebook page is born with the shape of the paper under this header,
-- and pinned: the header's height is part of every notebook's shape.
local pinned_page
for _, entry in ipairs(PROFILES) do
    if entry.name == profile then pinned_page = entry end
end
local born = assert(Layout.screenPage())
check(born.logical_w == pinned_page.page_w and born.logical_h == pinned_page.page_h,
    ("a new notebook page is stored %dx%d, got %dx%d")
        :format(pinned_page.page_w, pinned_page.page_h, born.logical_w, born.logical_h))
local page = { id = 1, logical_w = born.logical_w, logical_h = born.logical_h }
local snapshot = {
    state = "ready", writable = true, can_ink = true, can_undo = true, can_close = true,
    can_navigate = true, has_previous = false, has_next = true, page_count = 2, page_position = 1,
}
local surface = { isReady = function() return false end, cache = function() return nil end }
local session = { currentPage = function() return page end, surface = function() return surface end }
local controller = {
    activeSession = function() return session end,
    uiSnapshot = function() return snapshot end,
}
local erasing = false
local editor = Editor:new{
    controller = controller,
    notebook = { id = 1, title = "Toolbar geometry", page_count = 2 },
    get_eraser = function() return erasing end,
    set_eraser = function(value) erasing = value end,
    get_raw_pen_style = function() return 1 end,
    get_pen_width = function() return 4 end,
}
editor:_refreshSnapshot()
editor:_rebuildControls()
bb:fill(BB.COLOR_WHITE)
editor:paintTo(bb, 0, 0)

local geometry = editor.layout_geometry
check(#editor.layout == 1 and #editor.layout[1] == 8, "notebook focus is one row of eight")
for _, entry in ipairs(editor.control_entries) do
    local size = entry.widget:getSize()
    check(size.w <= entry.rect.w and size.h <= entry.rect.h, "notebook button fits its slot")
    check(entry.rect.h >= geometry.target_size, "notebook slot keeps the 10 mm target")
    check(entry.rect.y + entry.rect.h <= geometry.paper_rect.y, "notebook button is above the paper")
    if entry.widget.icon then checkIcon(entry.widget, "notebook") end
end

-- The page fills the paper the painted header leaves: no strip on either side,
-- and at most one pixel row of paper under it, because two integers cannot
-- hold the paper's exact proportion.
local fit, paper = geometry.fit_rect, geometry.paper_rect
check(fit.x == 0 and fit.w == W,
    ("the page spans the screen, got x=%d w=%d"):format(fit.x, fit.w))
check(fit.y == paper.y and paper.h - fit.h >= 0 and paper.h - fit.h <= 1,
    ("the page is the paper, got %d px left under it"):format(paper.h - fit.h))
check(paper.y == geometry.rail_rect.y + geometry.rail_rect.h + geometry.gap,
    "the paper starts one gap under the painted row")

local pen, eraser = editor.layout[1][2], editor.layout[1][3]
local px, py = markPoint(pen)
local ex, ey = markPoint(eraser)
check(gray(bb, px, py) < 0x40, "the selected pen carries its mark")
check(gray(bb, ex, ey) > 0xC0, "the eraser does not")
bb:writePNG(home .. "/notebook-toolbar.png")

check(tap(editor, eraser), "the eraser tap is consumed")
check(erasing, "the eraser tap reached the action through the real gesture range")
eraser = editor.layout[1][3]
check(eraser.tool_selected, "the rebuilt eraser is the selected tool")
eraser.frame.invert = true   -- what keyboard focus does
bb:fill(BB.COLOR_WHITE)
editor:paintTo(bb, 0, 0)
ex, ey = markPoint(eraser)
check(gray(bb, ex, ey) > 0xC0, "the mark inverts with a focused button")
check(gray(bb, ex, ey - 2 * Size.border.button - 1) < 0x40, "over the inverted background")
eraser.frame.invert = false

-- ------------------------------------------------------------ sheet

local host = { drawing = true, eraser = false, pen_width = 4 }
function host:effectiveStyle() return 1 end
function host:setEraser(value) self.eraser = value; self.overlay.bar:update(false) end
function host:setDrawing(value) self.drawing = value; self.overlay.bar:update(false) end
function host:showPenSettingsDialog() end
function host:onJustDrawUndo() end
function host:onShowDocumentNotes() end
function host:showBarMenu() end
function host:setBarShown() end

local canvas = { id = 1, logical_w = W, logical_h = H }
local overlay = Overlay:new{ plugin = host, canvas = canvas, height_pct = 100 }
host.overlay = overlay
local scale = overlay.transform.scale
check(Overlay.geometry(canvas, 100).scale == scale, "the session opens with the overlay's scale")

for _, pct in ipairs({ 40, 70, 100 }) do
    overlay:setHeight(pct)
    check(overlay.height_pct == pct, "the " .. pct .. "% stop fits this screen")
    bb:fill(BB.COLOR_BLACK)
    overlay:paintTo(bb, 0, 0)
    local bar, handle = overlay.bar, overlay:handleRect()
    local visible = overlay.transform:canvasRect()
    check(bar.dimen.y == handle.y + handle.h, "the toolbar starts under the handle")
    check(bar.dimen.w == W, "the toolbar spans the sheet")
    check(visible.y >= bar.dimen.y + bar.dimen.h, "no paper under the toolbar at " .. pct .. "%")
    check(overlay.transform.scale == scale, "the " .. pct .. "% stop keeps the scale")
    for _, entry in ipairs(bar.entries) do
        local size = entry.widget:getSize()
        check(size.w <= entry.rect.w and size.h <= entry.rect.h, "sheet button fits its slot")
        check(entry.rect.y + entry.rect.h <= overlay.transform.clip_rect.y, "sheet button is above the paper")
        if entry.widget.icon then checkIcon(entry.widget, "sheet") end
    end
    bb:writePNG(home .. "/sheet-" .. pct .. ".png")
end

local x, y = overlay.transform:toScreen(canvas.logical_w, canvas.logical_h)
check(x <= W and y <= H, "a full-screen sheet's far corner is visible at 100%")

-- A new sheet is born with the shape of the paper under this header: exactly
-- what the header the real widgets paint leaves of the screen, and pinned.
local paper_w, paper_h = Overlay.paperSize()
local pinned
for _, entry in ipairs(PROFILES) do
    if entry.name == profile then pinned = entry.paper_h end
end
check(paper_w == W and paper_h == pinned, ("a new sheet is stored %dx%s, got %dx%d")
    :format(W, tostring(pinned), paper_w, paper_h))
check(overlay.height_pct == 100
    and paper_h == H - overlay:handleRect().h - overlay.bar.dimen.h,
    "the stored height is what the painted header leaves")
for _, pct in ipairs({ 40, 70, 100 }) do
    local born = assert(Overlay.geometry({ logical_w = paper_w, logical_h = paper_h }, pct))
    check(born.offset_x == 0 and born.draw_w == W, "a new sheet has no side margins at " .. pct .. "%")
    check(born.scale == 1, "a new sheet is drawn 1:1 at " .. pct .. "%")
end
check(tap(overlay, overlay.bar.eraser_btn), "the sheet eraser tap is consumed")
check(host.eraser and overlay.bar.eraser_btn.tool_selected, "and reached the plugin")
check(not overlay.bar.pen_btn.tool_selected, "the pen let go of the selection")

overlay:onCloseWidget()
bb:free()
print("TOP_TOOLBAR_NATIVE_OK " .. profile .. " " .. W .. "x" .. H .. " checks=" .. checks)
