--[[--
Sheets on a PDF's pages, end to end, on the KOReader runtime that is installed.

The suite proves each seam of ADR-67/68 and the amended ADR-38/40 against
fakes; this drives them through a real ReaderUI over a real MuPDF document and
a real SQLite file, because the parts that can only go wrong for real are the
ones in between: the sheet session sharing page ink's connection, the offer
reaching the window stack as a real ConfirmBox, the header laid out with real
Buttons for a note of two sheets, the book's pages rendered off-screen beside
the notes into a PDF another program accepts, and one transaction deleting
sheets and their note.

    cd <koreader-build>/koreader && SDL_VIDEODRIVER=dummy KO_HOME=$(mktemp -d) \
      ./luajit <repo>/justdraw.koplugin/tests/pdf_sheets_native.lua [book.pdf]

Requires a NEW, empty KO_HOME under the temporary directory; every write stays
there. `qpdf`, when installed, checks the exported file (exit 0 only). Prints
PDF_SHEETS_NATIVE_OK and exits 0 only when every check held. Deliberately not
in tests/run.lua, which must run on bare LuaJIT.
]]
require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local home = assert(os.getenv("KO_HOME"), "Provide a fresh KO_HOME")
local tmp = os.getenv("TMPDIR") or "/tmp"
assert(home:sub(1, 5) == "/tmp/" or home:sub(1, 13) == "/private/tmp/"
    or home:sub(1, #tmp) == tmp, "KO_HOME must be temporary")
assert(not lfs.attributes(home .. "/settings.reader.lua"), "KO_HOME must be fresh")
local this = debug.getinfo(1, "S").source:sub(2)
local plugin = assert(this:match("^(.*)/tests/[^/]+$"))
package.path = plugin .. "/?.lua;" .. package.path
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
G_reader_settings:saveSetting("document_metadata_folder", "dir")
G_reader_settings:saveSetting("extra_plugin_paths", { plugin:match("^(.*)/[^/]+$") })
local disabled = {}
for name in lfs.dir("plugins") do
    if name:match("%.koplugin$") then disabled[name:sub(1, -10)] = true end
end
disabled.justdraw = nil
G_reader_settings:saveSetting("plugins_disabled", disabled)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UI = require("ui/uimanager")
local Event = require("ui/event")
local time = require("ui/time")

local function pump(until_fn, what)
    local deadline = time.now() + time.s(60)
    repeat
        UI:_checkTasks()
        UI:_repaint()
    until until_fn() or time.now() > deadline
    assert(until_fn(), (what or "deferred work") .. " did not settle")
end

local checks = 0
local function check(cond, what)
    assert(cond, what)
    checks = checks + 1
    print("OK   " .. what)
end

local function top()
    local stack = UI._window_stack
    return stack[#stack] and stack[#stack].widget
end

local book = ffiutil.realpath(arg[1] or "../../test/sample.pdf")
local doc = assert(require("document/documentregistry"):openDocument(book))
local reader = require("apps/reader/readerui"):new{ dimen = Device.screen:getSize(), document = doc }
UI:show(reader)
reader:handleEvent(Event:new("SetScrollMode", false))
local host = assert(reader.justdraw or require("pluginloader"):getPluginInstance("justdraw"))
pump(function()
    return host.document_session and host.document_session:isAvailable()
        and host.session and host.session:isAvailable() and not host.session:isIndexing()
end, "the sessions")

-- 1. One connection, two surfaces (ADR-67).
check(host.session.anchor_mode == "page", "a PDF's sheet session hangs sheets on pages")
check(host.session.repository == host.document_session.repository,
    "and writes through page ink's connection")

-- 2. Page ink under the pixel filters, not under straightening (ADR-38).
local DocumentTransform = require("ink_document_transform")
local page = host:currentPage()
local spec = assert(DocumentTransform.surfaceSpec(doc, page))
local screen = { w = Device.screen:getWidth(), h = Device.screen:getHeight() }
local saved = { page_opt = doc.configurable.page_opt,
    auto_straighten = doc.configurable.auto_straighten }
doc.configurable.page_opt = 1
check(DocumentTransform.fromView(reader, reader.view, spec, { screen = screen }) ~= nil,
    "dewatermark on: the real view still maps page ink")
doc.configurable.auto_straighten = 5
local _, straight = DocumentTransform.fromView(reader, reader.view, spec, { screen = screen })
check(straight == "unsupported_straightening", "Auto Straighten on: refused by name")
doc.configurable.page_opt, doc.configurable.auto_straighten = saved.page_opt, saved.auto_straighten

-- 3. A refused view offers a sheet, and a yes hangs one on this page -- one
-- with print on it, so the book's page in the export below shows something.
reader:handleEvent(Event:new("GotoPage", math.min(2, doc:getPageCount())))
pump(function() return host:currentPage() == math.min(2, doc:getPageCount()) end, "the page turn")
reader:handleEvent(Event:new("SetScrollMode", true))
pump(function() return host.document_session:stateName() == "suspended" end, "scroll mode")
host:setDrawing(true)
local offer = top()
check(offer and offer.ok_text == "Open drawing sheet", "Draw in scroll mode offers a drawing sheet")
check(offer.text:find("continuous scrolling", 1, true) ~= nil, "and says why page notes cannot")
offer.ok_callback()
pump(function()
    return host.canvas_open and host.session:cache() and host.session:cache():isReady()
end, "the sheet")
local first = host.session:activeCanvas()
check(first.anchor_kind == "page" and first.fixed_page == host:currentPage(),
    "the sheet hangs on the page being read")
check(host.drawing, "and Draw is on, on the sheet")
check(top() ~= offer, "the question has left the stack")

-- 4. Ink on the sheet reaches the database.
local w, h = tonumber(first.logical_w), tonumber(first.logical_h)
assert(host.session:addStroke({ w * 0.2, h * 0.2, w * 0.6, h * 0.4, w * 0.8, h * 0.3 }, 3, 4, 1))
assert(host.session:flush())
local SQL = require("lua-ljsqlite3/init")
local db_path = require("datastorage"):getSettingsDir() .. "/justdraw.sqlite3"
local function count(sql)
    local conn = assert(SQL.open(db_path, "ro"))
    local n = tonumber(conn:rowexec(sql))
    conn:close()
    return n
end
check(count("SELECT count(*) FROM strokes WHERE canvas_id = " .. first.id) == 1,
    "the stroke is committed under the sheet")

-- 5. A note of two sheets, turned from its own header (ADR-68).
host:setDrawing(false)
assert(host:addNoteSheet())
pump(function() return host.session:cache() and host.session:cache():isReady() end, "the new sheet")
local second = host.session:activeCanvas()
local pages = host.session:notePageState()
check(second.id ~= first.id and pages.total == 2 and pages.position == 2,
    "Add sheet turns to the second sheet of a note of two")
local bar = host.bar
check(bar.sheet_btn ~= nil and bar.previous_btn ~= nil and bar.next_btn ~= nil,
    "the header counts the sheets with real buttons")
check(bar.dimen.w <= Device.screen:getWidth(), "and fits the screen")
UI:_repaint()
Device.screen.bb:writePNG(home .. "/pdf-sheet-header.png")
host:turnNoteSheet(-1)
pump(function() return host.session:activeCanvas().id == first.id end, "the turn")
check(true, "previous turns back to the first sheet")
host:closeCanvas()

-- 6. The dossier with the book's pages, to a PDF another program accepts.
local built = assert(host:buildExport("notes", "pdf", { include_source_pages = true }))
local kinds = {}
for i, item in ipairs(built.items) do kinds[i] = item.kind end
check(kinds[1] == "source_page" and kinds[2] == "sheet" and kinds[3] == "sheet",
    "the book's page comes before the two sheets hung on it")
local done
local job = assert(require("ink_export").start{
    format = "pdf", dir = home, stem = "with-book-pages",
    items = built.items, render = built.render, flush = built.flush,
    schedule = function(fn) UI:nextTick(fn) end,
    on_done = function(value) done = value; if built.finish then built.finish() end end,
    on_cancel = built.cancel,
})
assert(job)
pump(function() return done ~= nil end, "the export")
check(done.status == "done", "the export finished")
local file = home .. "/with-book-pages.pdf"
check((lfs.attributes(file, "size") or 0) > 0, "and wrote a file")
local qpdf = io.popen("command -v qpdf 2>/dev/null"):read("*l")
if qpdf and qpdf ~= "" then
    local status = os.execute(string.format("%q --check %q >/dev/null 2>&1", qpdf, file))
    check(status == 0 or status == true, "qpdf --check accepts it, with no warning")
    local pipe = io.popen(string.format("%q --show-npages %q", qpdf, file))
    local npages = tonumber(pipe:read("*l"))
    pipe:close()
    check(npages == #built.items, "one PDF page per planned page (" .. tostring(npages) .. ")")
else
    print("SKIP qpdf is not installed")
end

-- 7. One batch delete takes both sheets and their note.
assert(host:deleteDocumentNotes({ first.id, second.id }))
check(count("SELECT count(*) FROM canvases WHERE surface_role = 'sheet'") == 0,
    "the batch delete removed both sheets")
check(count("SELECT count(*) FROM document_notes") == 0, "and the note they made up")
check(not host.canvas_open, "with nothing left open")

reader:handleEvent(Event:new("SetScrollMode", false))
reader:onClose(false)
print(string.format("PDF_SHEETS_NATIVE_OK %d checks, %s", checks, home))
os.exit(0)
