--[[--
Send with LocalSend, end to end on KOReader's real UI stack, exports and file
system -- up to the hand-off (Task 11.2).

LocalSend itself is a stub here: its real flow needs its own network binary
and a receiving device, neither of which a CI runner has. What this proves is
everything on JustDraw's side of `showFileSendFlow(path)`: real PDF and
Xournal++ exports of real notebooks into a real staging folder, one file
handed over by path and several by folder, the manifest naming exactly what
was written, nothing handed over when LocalSend disappears before the
hand-off (the files kept), and the staging swept only by a later process.

    cd <koreader>/lib/koreader && SDL_VIDEODRIVER=dummy ./luajit <repo>/justdraw.koplugin/tests/send_native.lua

Prints SEND_NATIVE_OK and exits 0 when every check passes.
]]
require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path
local tmp = os.getenv("TMPDIR") or "/tmp"
local base = string.format("%s/jd-send-e2e-%d-%d", tmp, os.time(), math.random(1, 1e6))
assert(lfs.mkdir(base))
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(base .. "/settings.reader.lua")
G_reader_settings:saveSetting("flash_ui", false)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local SQ3 = require("lua-ljsqlite3/init")
local Controller = require("ink_notebook_controller")
local Layout = require("ink_notebook_layout")
local LocalSend = require("ink_localsend")
local NotebookUI = require("ink_notebook_ui")
local Repository = require("ink_notebook_repository")

local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end

local function tick(rounds)
    for _ = 1, rounds or 50 do UIManager:_checkTasks() end
end

--- The top window, and the button labelled `text` on it, pressed.
--- The top window that is not a toast (a Notification covers nothing).
local Notification = require("ui/widget/notification")
local function top()
    local s = UIManager._window_stack
    for i = #s, 1, -1 do
        local w = s[i].widget
        if getmetatable(w) == nil or not (w.toast or w.class == Notification or w.notify_source) then
            if not (w.text and w.text:find("LocalSend is open", 1, true)) then return w end
        end
    end
end
local function pressIn(widget, text)
    local found
    local function walk(w, depth)
        if found or type(w) ~= "table" or depth > 30 then return end
        if w.text == text and type(w.callback) == "function" then found = w; return end
        for _, child in ipairs(w) do walk(child, depth + 1) end
        for _, key in ipairs({ "buttontable", "movable", "dialog_frame", "button_table" }) do
            if w[key] then walk(w[key], depth + 1) end
        end
        if type(w.buttons) == "table" then
            for _, row in ipairs(w.buttons) do
                for _, b in ipairs(row) do
                    if b.text == text and not found then found = b end
                end
            end
        end
    end
    walk(widget, 0)
    assert(found, "no " .. text .. " on " .. tostring(widget and (widget.title or widget.text)))
    found.callback()
end

-- ------------------------------------------------------------ notebooks

local repo = assert(Repository.open{ path = base .. "/notebooks.sqlite3", driver = SQ3 })
local shape = assert(Layout.screenPage())
local notebooks = {}
for i, title in ipairs({ "Física", "Física", "Solo" }) do
    local nb, page = assert(repo:createNotebook{ title = title, logical_w = shape.logical_w,
        logical_h = shape.logical_h })
    repo:transaction(function()
        local pts = {}
        for k = 0, 19 do pts[#pts + 1] = 100 + k * 20; pts[#pts + 1] = 200 + (k % 3) * 30 + i end
        assert(repo:addStroke(page, { points = pts, n = 20, width = 12, tool = 1 }))
        return repo:touchSurface(page)
    end)
    notebooks[i] = assert(repo:getNotebook(nb.id))
end

local opened = {}
local present = true
local stub = { showFileSendFlow = function(_, path) opened[#opened + 1] = path end }
local plugin = { ui = {}, configureNotebookInteraction = function() return true end }
local controller = Controller.new{ repository = repo }
local send_root = base .. "/justdraw-send"
local nui = NotebookUI.new{ plugin = plugin, controller = controller, send_root = send_root,
    find_localsend = function() return present and stub or nil end, thumbnail_factory = false }
local library = nui:openLibrary()
tick()

-- ------------------------------------------------------------ two notebooks

nui:sendNotebooks({ notebooks[1], notebooks[2] }, library)
tick(5)
pressIn(top(), "Xournal++")
tick(5)
check(top().text and top().text:find("Xournal++ keeps the strokes editable", 1, true),
    "Xournal++'s limits are told once, before anything is exported")
top().ok_callback()
UIManager:close(top())
tick(400)
check(#opened == 1, "LocalSend was opened once: " .. #opened)
local folder = opened[1]
check(lfs.attributes(folder, "mode") == "directory", "two notebooks go as a folder")
check(folder:sub(1, #send_root + 1) == send_root .. "/", "inside our own root")
local files = {}
for name in lfs.dir(folder) do
    if name ~= "." and name ~= ".." then files[#files + 1] = name end
end
table.sort(files)
check(#files == 3, "two exports and the manifest: " .. table.concat(files, ", "))
check(files[2] == "Física (2).xopp" and files[3] == "Física.xopp",
    "same titles, two files: " .. table.concat(files, ", "))
local manifest = LocalSend.parseManifest(io.open(folder .. "/.justdraw-send"):read("*a"))
check(manifest and #manifest.files == 2, "the manifest lists exactly the two exports")
local gz = io.open(folder .. "/Física.xopp", "rb"):read(2)
check(gz == "\31\139", "a gzip file")

-- ------------------------------------------------------------ one notebook

nui:sendNotebooks({ notebooks[3] }, library)
tick(5)
pressIn(top(), "PDF")
tick(400)
check(#opened == 2, "opened again")
check(opened[2]:match("/Solo%.pdf$") and lfs.attributes(opened[2], "mode") == "file",
    "one notebook goes by path")
check(io.open(opened[2], "rb"):read(5) == "%PDF-", "a PDF")

-- ------------------------------------------------------------ gone before the hand-off

nui:sendNotebooks({ notebooks[3] }, library)
tick(5)
pressIn(top(), "PDF")
present = false
tick(400)
check(#opened == 2, "nothing opened when LocalSend is gone")
local box = top()
check(box and box.text and box.text:find("kept in", 1, true), "the reader is told the files are kept")
local kept
for name in lfs.dir(send_root) do
    local dir = send_root .. "/" .. name
    if name:match("^op%-") and dir ~= folder and dir .. "/Solo.pdf" ~= opened[2]
        and lfs.attributes(dir .. "/Solo.pdf", "mode") == "file" then kept = dir end
end
check(kept ~= nil, "and they are")
pressIn(box, "Cancel")
tick()

-- ------------------------------------------------------------ cancelled mid-export

present = true
local before = #opened
nui:sendNotebooks({ notebooks[1], notebooks[2], notebooks[3] }, library)
tick(5)
pressIn(top(), "PDF")
tick(2)   -- the first export has started, not finished
check(LocalSend.activeFlow() ~= nil, "a send is being prepared")
LocalSend.cancelActive()   -- what suspend and closing the library do
tick(400)
check(#opened == before, "a cancelled send never opens LocalSend")
check(LocalSend.activeFlow() == nil, "and is over")
check(not require("ink_export").isRunning(), "with no export left running")

-- ------------------------------------------------------------ sweeping

local report = nui:_sendStaging():sweep{ min_age = 0 }
check(lfs.attributes(folder, "mode") == "directory", "this process never sweeps what it handed over")
check(report.removed == 0, "nothing of this process is swept")
local later = LocalSend.staging{ root = send_root, token = "ffffffff",
    now = function() return os.time() + 2 * 24 * 3600 end }
check(later:sweep().kept[folder:match("[^/]+$")] == "handed_over",
    "while this process lives, what it handed over is never swept, however old")
LocalSend._resetHanded()   -- what a new KOReader process starts with
later:sweep()
check(lfs.attributes(folder, "mode") == nil, "a later process sweeps it once it is old")
check(lfs.attributes(kept, "mode") == nil, "and the kept one too")

nui:shutdown()
repo:close()
os.execute(string.format("rm -rf '%s'", base))
print(string.format("SEND_NATIVE_OK %d checks", checks))
