-- Context navigation through real ReaderUI, SQLite, native buttons and repaint.
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
    local deadline = time.now() + time.s(30)
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
local function copyFixture(source, name)
    local input = assert(io.open(source, "rb"))
    local bytes = input:read("*a"); assert(input:close())
    local path = home .. "/" .. name
    local output = assert(io.open(path, "wb")); assert(output:write(bytes)); assert(output:close())
    return path
end
local doc = assert(require("document/documentregistry"):openDocument(
    copyFixture("../../test/juliet.epub", "navigation.epub")))
local reader = require("apps/reader/readerui"):new{dimen=Device.screen:getSize(),document=doc}
UI:show(reader)
local host = assert(reader.justdraw or require("pluginloader"):getPluginInstance("justdraw"))
pump(function() return host.session and host.session:isAvailable() and not host.session:isIndexing() end)
local session, repo = host.session, host.session.repository
local function go(page)
    reader:handleEvent(Event:new("GotoPage",page))
    UI:_repaint()
end
local function makeSheet(page)
    go(page)
    return assert(session:createHere(host:currentPage()))
end
local a, b = makeSheet(3), makeSheet(10)
local groups = require("ink_note_repository").new(repo)
local b2 = assert(groups:append(session.book_id,b)); session.index:add(b2,10)
for i = 13, 30 do makeSheet(i) end
for _, row in ipairs({a,b,b2}) do
    for i = 1, 32 do
        local y = row.logical_h * i / 34
        assert(repo:addStroke(row,{width=3,tool=1,n=3,
            points={40,y,row.logical_w/2,y+15,row.logical_w-120,y},}))
    end
end
local group_id
for _, member in ipairs(assert(groups:memberships(session.book_id))) do
    if member.canvas_id == b2.id then group_id="note:"..member.note_id end
end
assert(group_id)
go(3)
assert(host:openCanvas(a))
pump(function() return session:cache():isReady() end)
assert(host.drawing)
assert(host:onShowDocumentNotes())
local notes = host.notes_controller
local function listReady()
    pump(function() return notes.catalog.state=="ready" and not notes.catalog.busy
        and not notes.restore_state and not notes.restore_job end)
    notes.browser:_rebuild(); UI:_repaint()
end
listReady()
notes.catalog:query({kind="sheet"},"recent"); listReady()
local target_index
for i,item in ipairs(notes.catalog.result) do if item.id==group_id then target_index=i end end
assert(target_index)
while target_index >= notes.browser.first + notes.browser.per_page do notes.browser:onNext() end
UI:_repaint()
local first_id=notes.browser.visible_ids[1]
notes.catalog:toggle(group_id)
local function tap(button)
    UI:_repaint()
    assert(button and button.dimen, "button has no painted geometry")
    assert(button.enabled ~= false,"button is disabled: "..tostring(button.text))
    local d=button.dimen
    assert(d.x>=0 and d.y>=0 and d.x+d.w<=Device.screen:getWidth()
        and d.y+d.h<=Device.screen:getHeight(),"button is off screen: "..tostring(button.text))
    UI:sendEvent(Event:new("Gesture",{ges="tap",pos=require("ui/geometry"):new{
        x=d.x+d.w/2,y=d.y+d.h/2}}))
    UI:_repaint()
end
local function selectedReady()
    pump(function() return host.canvas_open and session:cache():isReady() and not notes.pending_navigation end)
    assert(session:activeCanvas().id==b2.id,"wrong sheet above destination")
    assert(session:openCanvasPlacement()=="here","sheet is off-page")
    assert(not host.drawing and not host.input_lease,"view acquired capture")
end
local function checkBar()
    UI:_repaint()
    for _, key in ipairs({"draw_btn","pen_btn","eraser_btn","undo_btn","notes_btn","more_btn","hide_btn"}) do
        local btn=assert(host.bar[key],"missing control "..key)
        local d=assert(btn.dimen)
        local label=btn.label_widget
        assert(not label.line_with_ellipsis and not (label.isTruncated and label:isTruncated()),
            key.." label is truncated")
        assert(d.x>=0 and d.y>=0 and d.x+d.w<=Device.screen:getWidth()
            and d.y+d.h<=Device.screen:getHeight(), key.." overflows")
    end
end
print("PROFILE",Device.screen:getWidth(),Device.screen:getHeight())
tap(notes.browser.layout[2+target_index-notes.browser.first][1])
pump(function() return notes.detail end)
notes.detail.next_note(); pump(function() return notes.detail end)
assert(notes.surface_id==b2.id,"next sheet did not select B2")
picture(notes.detail,"01-selected-sheet-viewer")
local history=#reader.link.location_stack
tap(notes.detail.button_table:getButtonById("view_on_page"))
selectedReady()
assert(host:currentPage()==10)
assert(#reader.link.location_stack==history+1,"history duplicated")
assert(not notes.preview_job and not notes.preview_result and not notes.browser,"preview resources retained")
assert(session:overlay().height_pct==40)
checkBar(); picture(session:overlay(),"02-view-on-page-40")
tap(host.bar.draw_btn); assert(host.drawing,"Draw did not arm")
assert(session:addStroke({50,50,90,90},2,3,1))
tap(host.bar.draw_btn); assert(not host.drawing,"Stop did not release")
session:overlay():setHeight(100)
checkBar(); picture(session:overlay(),"03-expanded-note")
tap(host.bar.hide_btn)
assert(not host.canvas_open and not session:cache(),"Hide retained raster")
picture(host.bar,"04-show-note")
history=#reader.link.location_stack
tap(host.bar.show_btn); selectedReady()
assert(session:overlay().height_pct==100,"expansion lost on Show")
assert(#reader.link.location_stack==history,"Show navigated")
tap(host.bar.hide_btn)
local page=host:currentPage()
-- Actual gesture through the topmost compact bar must reach the book.
UI:sendEvent(Event:new("Gesture",{ges="swipe",direction="west",time=time.now(),distance=400,pos=require("ui/geometry"):new{x=40,y=100}}))
UI:_repaint()
assert(host:currentPage()~=page,"return bar swallowed reader gesture")
assert(host.bar.show_btn.text=="Go to note")
picture(host.bar,"05-go-to-note")
tap(host.bar.show_btn); selectedReady()
tap(host.bar.hide_btn); tap(host.bar.dismiss_btn)
assert(not host.bar or not host.bar.note_return,"Dismiss retained compact bar")
local reopen
for _,item in ipairs(host:canvasMenu()) do if item.text=="Show note" then reopen=item end end
assert(reopen and reopen.enabled_func()); reopen.callback(); selectedReady()
tap(host.bar.notes_btn); listReady()
assert(notes.catalog.filter.kind=="sheet" and notes.catalog.order=="recent","filter/order lost")
assert(notes.catalog.selected[group_id],"export selection lost")
assert(notes.browser.visible_ids[1]==first_id,"list viewport lost")
assert(notes.surface_id==b2.id,"selected leaf lost")
picture(notes.browser,"06-restored-list")
-- Reorder while outside the browser, then restore the same leaf by identity.
notes:close()
assert(groups:reorder(session.book_id,tonumber(group_id:match("%d+")),{b2.id,b.id}))
assert(host:onShowDocumentNotes()); listReady()
assert(notes:showDetail(group_id)); pump(function() return notes.detail end)
assert(notes.focus_sheet_index==1 and notes.surface_id==b2.id,"reorder changed selected leaf")
picture(notes.detail,"07-restored-exact-sheet")
tap(notes.detail.button_table:getButtonById("read_from_here"))
pump(function() return not notes.pending_navigation end)
assert(not host.canvas_open and not host.drawing and host:currentPage()==10,"Read retained panel")
picture(host.bar,"08-read-from-here")
local return_page
for i=#reader.link.location_stack,1,-1 do
    local location=reader.link.location_stack[i]
    local page=location.xpointer and doc:getPageFromXPointer(location.xpointer)
    if page and page~=host:currentPage() then return_page=page; break end
end
assert(return_page,"no reading-history location to exercise")
reader.link:onGoBackLink(); UI:_repaint()
assert(host:currentPage()==return_page,"KOReader Back lost the original reading location")
reader.link:onGoForwardLink(); UI:_repaint()
assert(host:currentPage()==10,"KOReader Forward lost the note location")
-- Existing preview can close before its first paint without reviving the crash.
assert(host:onShowDocumentNotes()); listReady()
notes:showDetail(group_id); notes:close(); UI:_checkTasks(); UI:_repaint()
assert(not notes.detail and not notes.preview_result)
-- Read-only is the repository's supported mode, not a chmod assumption.
repo.read_only=true
local leaf={kind="sheet",surface=b2,page=10}
assert(not notes:canEdit(leaf))
assert(notes:navigate(leaf,"view")); selectedReady()
assert(not host.bar.draw_btn.enabled and not host.bar.undo_btn.enabled)
checkBar()
picture(session:overlay(),"09-read-only-note")
-- Keyboard focus can move to another row without opening its detail.
-- It must supersede the last detail's leaf ID on the next list restoration.
assert(host:onShowDocumentNotes()); listReady()
local focus_row
for i,id in ipairs(notes.browser.visible_ids) do
    if id~=group_id then focus_row=i; break end
end
assert(focus_row,"fixture needs another visible row")
local focused_id=notes.browser.visible_ids[focus_row]
notes.browser.selected={x=1,y=focus_row+1}
notes.browser:onClose()
assert(host:onShowDocumentNotes()); listReady()
assert(notes.focus_id==focused_id and notes.surface_id==nil,"old detail overrode new list focus")
host:teardown(); reader:onClose(false)
UI:_checkTasks(); UI:_repaint()
assert(not host.bar and not host.input_lease and not notes.pending_navigation)
print("PASS contextual navigation: exact sheet, view/edit/read, hide/show, gestures, restore, reorder, read-only, cleanup")
print("EVIDENCE "..home)
