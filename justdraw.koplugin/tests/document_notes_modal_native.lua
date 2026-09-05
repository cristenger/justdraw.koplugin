-- Native regression for crash (8): never manually paint a widget before _repaint.
-- Run from a KOReader build with a fresh temporary KO_HOME.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"), "Provide a fresh KO_HOME")
local tmp = os.getenv("TMPDIR") or "/tmp"
assert(home:match("^/tmp/") or home:match("^/private/tmp/") or home:sub(1, #tmp) == tmp)
assert(not require("libs/libkoreader-lfs").attributes(home .. "/settings.reader.lua"))
local plugin = assert(debug.getinfo(1, "S").source:sub(2):match("^(.*)/tests/[^/]+$"))
package.path = plugin .. "/?.lua;" .. package.path
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UI = require("ui/uimanager")
local BB = require("ffi/blitbuffer")
local Controller = require("ink_document_notes_controller")
local Detail = require("ink_document_notes_detail")
local host = {
    ui = {document = {file = "modal-regression.epub"}},
    showReaderModal = function(_, widget) UI:show(widget); return widget end,
    closeReaderModal = function(_, widget) UI:close(widget); return true end,
}
local controller = Controller.new(host)
local item = require("ink_document_note").new{kind = "sheet", page = 1, surface = {id = 8}}
local catalog = require("ink_document_notes_catalog").new{}
catalog.state, catalog.items, catalog.result, catalog.by_id = "ready", {item}, {item}, {[item.id] = item}
controller.catalog, controller.title = catalog, "Modal regression"
controller.browser = require("ink_document_notes_ui"):new{controller = controller}
controller:showModal(controller.browser)
UI:_repaint()
local released, created = 0, 0
local function top(widget)
    assert(UI._window_stack[#UI._window_stack].widget == widget, "child is covered by another window")
end
local function drain()
    UI:_repaint()
    assert(#UI._refresh_func_stack == 0, "deferred refreshes did not drain")
end
local function preview()
    controller:closeDetail()
    created = created + 1
    local raster = BB.new(800, 1200, BB.TYPE_BB8)
    raster:fill(BB.COLOR_WHITE)
    raster:paintRect(50, 50, 120, 120, BB.COLOR_BLACK)
    controller.preview_result = {release = function() released = released + 1; raster:free() end}
    controller.detail = Detail:new{
        image = raster, title_text = "Note preview", caption = "Page 1",
        can_navigate = true, has_previous = false, has_next = false,
        close_note = function() controller:closeDetail() end,
        note_actions = function() end, go_to_document = function() end,
    }
    controller:showModal(controller.detail)
    return controller.detail
end

local detail = preview()
assert(not detail.main_frame.dimen, "test must exercise the first real paint")
-- This line fails in the original implementation at imageviewer.lua:383.
drain()
top(detail)
assert(detail.main_frame.dimen, "visible preview did not get painted geometry")
Device.screen.bb:writePNG(home .. "/modal-preview.png")
detail:onZoomIn(); drain()
detail.rotated = true; detail:update(); drain()
detail:onClose(); drain(); top(controller.browser)
controller:closeDetail()
assert(released == 1, "preview was released more than once")
print("PASS modal ordering, initial repaint, zoom, rotation, idempotent close")

detail = preview()
detail:onClose()
drain(); top(controller.browser)
assert(released == 2, "close before first paint retained the raster")
print("PASS close before first paint")

detail = preview()
-- A full-screen child can cover a preview before it has ever painted.
local text = require("ui/widget/textviewer"):new{title = "Long note", covers_fullscreen = true,
    text = string.rep("A note line\n", 400)}
controller:showModal(text)
drain(); top(text)
assert(not detail.main_frame.dimen, "covered preview was unexpectedly painted")
text:findDialog()
drain()
local find = UI:getNthTopWidget(2) -- The virtual keyboard is on top of the input.
assert(find and find.title == "Enter text to search for", "native Find dialog is underneath its owner")
assert(find:isKeyboardVisible(), "native Find keyboard was not exercised")
UI:close(find)
drain(); top(text)
controller:closeModal(text)
drain(); top(detail)
assert(detail.main_frame.dimen)
detail:onClose(); drain()
print("PASS covered preview, native Find and keyboard, return to preview")

for _ = 1, 8 do
    preview()
    detail = preview() -- Replace without an intervening repaint.
    drain(); top(detail)
    detail:onZoomOut()
    detail:onClose() -- Close with an update still queued.
    drain(); top(controller.browser)
end
preview()
controller:close()
drain()
assert(#UI._window_stack == 0 and next(controller.modals) == nil, "owner cleanup leaked a window")
assert(created == released, "preview lifetime mismatch")
assert(not controller.preview_result and not controller.preview_job)
print("PASS rapid replacement and owner cleanup; released " .. released .. " of " .. created .. " rasters")
print("PASS native notes modal regression at " .. Device.screen:getWidth() .. "x" .. Device.screen:getHeight())
