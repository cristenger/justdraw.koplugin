-- Real ReaderUI, SQLite, widgets, raster and PDF export. Run in a KOReader build.
-- Requires a NEW, empty KO_HOME under /tmp or TMPDIR; all writes stay there.
require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local home = assert(os.getenv("KO_HOME"), "Provide a fresh KO_HOME")
local tmp = os.getenv("TMPDIR") or "/tmp"
assert(home:sub(1,5) == "/tmp/" or home:sub(1,13) == "/private/tmp/"
    or home:sub(1,#tmp) == tmp, "KO_HOME must be temporary")
assert(not lfs.attributes(home .. "/settings.reader.lua"), "KO_HOME must be fresh")
local this = debug.getinfo(1,"S").source:sub(2)
local plugin = assert(this:match("^(.*)/tests/[^/]+$"))
package.path = plugin .. "/?.lua;" .. package.path
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("document_metadata_folder", "dir")
G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
G_reader_settings:saveSetting("extra_plugin_paths", {plugin:match("^(.*)/[^/]+$")})
local disabled = {}
for name in lfs.dir("plugins") do if name:match("%.koplugin$") then disabled[name:sub(1,-10)] = true end end
disabled.justdraw = nil
G_reader_settings:saveSetting("plugins_disabled", disabled)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UI = require("ui/uimanager")
local Event = require("ui/event")
local time = require("ui/time")
local function pump(until_fn)
    local deadline = time.now() + time.s(120)
    repeat
        UI:_checkTasks()
        UI:_repaint()
    until until_fn() or time.now() > deadline
    assert(until_fn(), "deferred work did not settle")
end
local function picture(widget, name)
    -- Capture what the user sees. Direct paintTo hid the crash (8) stack bug.
    UI:_repaint()
    local found
    for _, window in ipairs(UI._window_stack) do
        if window.widget == widget then
            found = true
        elseif found then
            assert(not window.widget.covers_fullscreen, name .. " is covered by a full-screen window")
        end
    end
    assert(found, name .. " is absent from the window stack")
    local w,h = Device.screen:getWidth(),Device.screen:getHeight()
    assert(widget:getSize().w <= w and widget:getSize().h <= h, name .. " overflows screen")
    Device.screen.bb:writePNG(home .. "/" .. name .. ".png")
end
local function topOwned(notes)
    for i = #UI._window_stack, 1, -1 do
        local widget = UI._window_stack[i].widget
        if notes.modals[widget] then return widget end
    end
end
local doc = assert(require("document/documentregistry"):openDocument(ffiutil.realpath(arg[1] or "../../test/sample.pdf")))
local reader = require("apps/reader/readerui"):new{dimen=Device.screen:getSize(),document=doc}
UI:show(reader)
reader:handleEvent(Event:new("SetScrollMode",false))
local host = assert(reader.justdraw or require("pluginloader"):getPluginInstance("justdraw"))
pump(function() return host.document_session and host.document_session:isAvailable() end)
local repo, book = host.document_session:exportSources()
assert(repo and book)
local ink_page = math.min(2,doc:getPageCount())
local size = doc:getNativePageDimensions(ink_page)
local surface = assert(repo:createPageInkSurface(book,ink_page,size.w,size.h))
for i = 1, 20 do
    local styles = {1,3,65,66,67,68}
    assert(repo:addStroke(surface,{points={20,20+i*5,100,40+i*5,200,20+i*5},n=3,width=2,
        tool=styles[(i-1) % #styles + 1]}))
end
assert(host:onShowDocumentNotes())
local notes = host.notes_controller
pump(function() return notes.catalog.state == "ready" and not notes.catalog.busy end)
notes.browser:_rebuild()
assert(#notes.catalog.items == 1)
assert(notes.browser[1]:getSize().w <= Device.screen:getWidth(),"list children exceed width")
assert(notes.browser[1]:getSize().h <= Device.screen:getHeight(),"list children exceed height")
picture(notes.browser,"notes-list")
local function menuPicture(open, name)
    open()
    if notes.preparation then pump(function()return not notes.preparation end) end
    local dialog = topOwned(notes)
    assert(dialog and dialog ~= notes.browser, "menu was not shown above browser")
    if name:find("keyboard", 1, true) then
        assert(dialog:isKeyboardVisible(), "virtual keyboard was not exercised")
    end
    picture(dialog, name)
    if name == "notes-export-dialog" then
        dialog:onCloseKeyboard()
        local folder_button
        for _, row in ipairs(dialog.buttons) do
            for _, button in ipairs(row) do
                if button.text == "Folder…" then folder_button = button end
            end
        end
        assert(folder_button, "export folder button missing").callback()
        local folder = UI:getNthTopWidget()
        assert(folder ~= dialog, "native folder dialog opened below export settings")
        picture(folder, "notes-export-folder")
        UI:close(folder)
        picture(dialog, "notes-return-from-folder")
    end
    notes:closeModal(dialog)
    UI:_repaint()
    assert(topOwned(notes) == notes.browser, "closing menu did not return to browser")
end
menuPicture(function() notes.browser:showFilters() end, "notes-filters")
menuPicture(function() notes:showExportOptions() end, "notes-export-scopes")
menuPicture(function() notes:export(notes.catalog.items,"full",150) end, "notes-export-dialog")
menuPicture(function() notes.browser:showRange() end, "notes-page-range-keyboard")
menuPicture(function()
    notes.browser:showFilters()
    local filters = topOwned(notes)
    for _, choice in ipairs(filters.item_table) do
        if choice.text == "Search annotation text…" then choice.callback(); return end
    end
    error("search filter missing")
end, "notes-search-keyboard")
assert(UI._window_stack[#UI._window_stack].widget == notes.browser, "input keyboard leaked")
local rotation = Device.screen:getRotationMode()
Device.screen:setRotationMode((rotation + 1) % 4)
notes.browser:onScreenResize()
assert(notes.browser[1]:getSize().h <= Device.screen:getHeight(),"landscape children exceed height")
picture(notes.browser, "notes-landscape")
menuPicture(function() notes.browser:showFilters() end, "notes-landscape-filters")
Device.screen:setRotationMode(rotation)
notes.browser:onScreenResize()
picture(notes.browser, "notes-list")
local item = notes.catalog.result[1]
-- Send a real gesture through the widget tree, not just its callback.
local row = notes.browser.layout[2][1]
assert(row.dimen)
assert(notes.browser:handleEvent(Event:new("Gesture",{ges="tap",pos=require("ui/geometry"):new{
    x=row.dimen.x + row.dimen.w/2,y=row.dimen.y + row.dimen.h/2}})))
pump(function() return notes.detail ~= nil end)
picture(notes.detail,"notes-detail")
notes.detail:onZoomIn()
picture(notes.detail,"notes-zoom")
notes.detail:note_actions()
local actions = assert(topOwned(notes))
assert(actions ~= notes.detail and actions ~= notes.browser)
picture(actions, "notes-actions")
notes:closeModal(actions)
picture(notes.detail, "notes-return-from-actions")
notes:closeDetail()
assert(not notes.preview_job and not notes.preview_result)
notes.catalog:toggle(item.id)
assert(#notes.catalog:exportItems("selected") == 1)

local page_before, zoom_before = host:currentPage(), reader.view.state.zoom
local built = assert(host.export_controller:buildNotes(notes.catalog.items,"full"))
assert(#built.items == doc:getPageCount())
local result
local export_started = time.now()
local job, reason = require("ink_export").start{format="pdf",dir=home,stem="complete-document",
    compress=require("ffi/zlib").zlib_compress,
    items=built.items,render=built.render,flush=built.flush,
    schedule=function(fn) UI:nextTick(fn) end,
    on_done=function(value) result=value;built.finish() end,
    on_cancel=built.cancel}
assert(job,reason)
pump(function() return result ~= nil end)
assert(result.status == "done",tostring(result.error))
print(string.format("Full PDF: %d pages in %.2f seconds", #built.items,
    (time.now() - export_started) / time.s(1)))
assert(host:currentPage() == page_before,"export moved reading position")
assert(reader.view.state.zoom == zoom_before,"export changed zoom")
-- Cancel after the native document raster exists but before ink replay settles.
local pending, tracker, delivered = {}, {}, false
local renderer = require("ink_document_export_full").renderer{document=doc,tracker=tracker,
    schedule=function(fn) pending[#pending+1]=fn end}
renderer({kind="document_page",page=ink_page,note=item},1,function(value)
    delivered=true; if value then value.release() end
end)
table.remove(pending,1)()
assert(tracker.job and tracker.release,"page and overlay were not prepared")
tracker.closed=true;tracker.job:close();tracker.release()
while #pending > 0 do table.remove(pending,1)() end
assert(not delivered,"cancelled overlay delivered stale pixels")
local cancelled
local cancel_build = assert(host.export_controller:buildNotes(notes.catalog.items,"full"))
local cancel_job = assert(require("ink_export").start{format="pdf",dir=home,stem="cancelled-document",
    items=cancel_build.items,render=cancel_build.render,flush=cancel_build.flush,
    schedule=function(fn) UI:nextTick(fn) end,
    on_done=function(value) cancelled=value;cancel_build.finish() end,
    on_cancel=cancel_build.cancel})
cancel_job:cancel()
pump(function() return cancelled ~= nil end)
assert(cancelled.status == "cancelled")
assert(not lfs.attributes(home .. "/cancelled-document.pdf"),"cancel kept a final file")
assert(notes:navigate(item,false))
assert(not notes.browser and not notes.preview_result and not notes.preview_job)
assert(next(notes.modals) == nil,"modal leaked")
assert(host:onShowDocumentNotes())
pump(function() return notes.catalog.state == "ready" and not notes.catalog.busy end)
assert(notes.catalog:selectionCount() == 1,"return lost selection")
assert(#notes.catalog.items == 1)
host:onSuspend();host:teardown()
assert(#notes.catalog.items == 0 and next(notes.catalog.opts) == nil,"catalogue retained borrowed sources")
print("PASS PDF notes: real reader, portrait/landscape menus, detail, zoom, selection, full PDF, cancellation, return, cleanup")
reader:onClose(false)

doc = assert(require("document/documentregistry"):openDocument(ffiutil.realpath("../../test/juliet.epub")))
reader = require("apps/reader/readerui"):new{dimen=Device.screen:getSize(),document=doc}
UI:show(reader)
host = assert(reader.justdraw or require("pluginloader"):getPluginInstance("justdraw"))
pump(function() return host.session and host.session:isAvailable() and not host.session:isIndexing() end)
local canvas = assert(host.session:createHere(host:currentPage()))
repo = host.session:exportSources()
assert(repo:addStroke(canvas,{points={10,10,200,100,300,10},n=3,width=3,tool=1}))
local orphan = assert(repo:createCanvas(host.session.book_id,{
    anchor_kind="xpointer",anchor_key="xp:/missing[1]",anchor_raw="/missing[1]",
    logical_w=600,logical_h=800}))
assert(repo:addStroke(orphan,{points={10,10,300,400},n=2,width=3,tool=66}))
host.session.index:add(orphan)
assert(host:onShowDocumentNotes())
notes = host.notes_controller
pump(function() return notes.catalog.state == "ready" and not notes.catalog.busy end)
notes.browser:_rebuild()
assert(#notes.catalog.result == 2)
assert(notes.catalog.result[1].page ~= nil,"valid EPUB anchor was lost")
assert(notes.catalog.result[2].page == nil,"orphan received invented location")
picture(notes.browser,"epub-notes-list")
item = notes.catalog.result[2]
assert(notes:showDetail(item.id))
pump(function() return notes.detail ~= nil end)
assert(notes.detail.can_navigate == false,"orphan navigation enabled")
picture(notes.detail,"epub-orphan-detail")
notes:closeDetail()
local location_before, hash_before = doc:getXPointer(), doc:getDocumentRenderingHash()
built = assert(host.export_controller:buildNotes(notes.catalog.items,"notes"))
result = nil
assert(require("ink_export").start{format="pdf",dir=home,stem="epub-notes",
    items=built.items,render=built.render,flush=built.flush,
    compress=require("ffi/zlib").zlib_compress,
    schedule=function(fn) UI:nextTick(fn) end,
    on_done=function(value) result=value;built.finish() end,on_cancel=built.cancel})
pump(function() return result ~= nil end)
assert(result.status == "done",result.error)
assert(doc:getXPointer() == location_before and doc:getDocumentRenderingHash() == hash_before,
    "dossier changed EPUB position or layout")
assert(notes:navigate(notes.catalog.result[1],false))
assert(host:onShowDocumentNotes())
pump(function() return notes.catalog.state == "ready" and not notes.catalog.busy end)
assert(notes:showDetail(notes.catalog.result[1].id))
-- Suspending during deferred preview must release it without a late modal.
host:onSuspend()
UI:_checkTasks()
UI:_repaint()
assert(not notes.browser and not notes.preview_job and not notes.preview_result and next(notes.modals)==nil)
host:teardown();reader:onClose(false)
print("PASS EPUB notes: anchors, orphan detail, dossier, unchanged reader, navigation, suspend during preview")
dofile(plugin.."/tests/document_notes_advanced_cases.lua"){UI=UI,home=home,pump=pump,picture=picture,topOwned=topOwned}
print("Artifacts: " .. home)
