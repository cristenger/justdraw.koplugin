--[[--
Thumbnails against KOReader's real raster, MuPDF reduction, PNG writer and
image loader (Task 9.2).

The suite's fakes cannot say whether the export raster really renders a
notebook page from SQLite, whether MuPDF's reduction and `writePNG` produce a
file KOReader's own image widget can read back at the requested size, or
whether a new revision really is a new file. This does.

    cd <koreader>/lib/koreader && SDL_VIDEODRIVER=dummy ./luajit <repo>/justdraw.koplugin/tests/thumbnail_native.lua

Prints THUMBNAIL_NATIVE_OK and exits 0 when every check passes.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;" .. package.path
local tmp = os.getenv("TMPDIR") or "/tmp"
local home = string.format("%s/jd-thumb-home-%d", tmp, os.time())
require("libs/libkoreader-lfs").mkdir(home)
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
local Repository = require("ink_notebook_repository")
local Thumbs = require("ink_thumbnail")
local RenderImage = require("ui/renderimage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")

local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end

local stamp = string.format("%d-%d", os.time(), math.random(1, 1e6))
local db_path = string.format("%s/jd-thumb-native-%s.sqlite3", tmp, stamp)
local dir = string.format("%s/jd-thumbs-%s", tmp, stamp)
local repo = assert(Repository.open{ path = db_path, driver = SQ3 })
local nb, page = assert(repo:createNotebook{ title = "Thumb", logical_w = 800, logical_h = 1000,
    template_kind = "grid" })
nb = assert(repo:getNotebook(nb.id))
repo:transaction(function()
    local pts = {}
    for i = 0, 49 do pts[#pts + 1] = 100 + i * 12; pts[#pts + 1] = 200 + (i % 7) * 40 end
    assert(repo:addStroke(page, { points = pts, n = 50, width = 8, tool = 1 }))
    return repo:touchSurface(page)
end)
page = assert(repo:getPage(page.id))

-- A scheduler queue the test drains: the raster must never run inline.
local tasks = {}
local function drain()
    local guard = 0
    while #tasks > 0 do
        guard = guard + 1
        assert(guard < 100000, "the raster never settled")
        table.remove(tasks, 1).fn()
    end
end

local deps = Thumbs.nativeDeps()
local thumbs = Thumbs.new{ dir = dir, repository = function() return repo end,
    schedule = function(delay, fn) tasks[#tasks + 1] = { delay = delay, fn = fn } end,
    unschedule = function(fn)
        for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) end end
    end,
    raster_open = deps.raster_open, scale = deps.scale, write = deps.write, fs = deps.fs }

local req = Thumbs.request(repo:dbUid(), nb, page, 120, 150)
local got, reason
local path, why = thumbs:want(req, function(p, _, r) got, reason = p, r end)
check(path == nil and why == "pending", "the first request is queued")
drain()
check(got ~= nil, "a thumbnail was published: " .. tostring(reason))
check(lfs.attributes(got, "size") > 0, "a non-empty file")
check(lfs.attributes(got .. ".tmp", "mode") == nil, "no temporary left")

local bb = RenderImage:renderImageFile(got, false)
check(bb ~= nil, "KOReader's image loader reads it back")
check(bb:getWidth() == 120 and bb:getHeight() == 150, "at the requested size: "
    .. bb:getWidth() .. "x" .. bb:getHeight())
local dark, light = 0, 0
for y = 0, bb:getHeight() - 1, 2 do
    for x = 0, bb:getWidth() - 1, 2 do
        local v = tonumber(bb:getPixel(x, y):getColor8().a)
        if v < 96 then dark = dark + 1 elseif v > 200 then light = light + 1 end
    end
end
bb:free()
check(dark > 0, "the ink is visible")
check(light > dark, "mostly paper")

-- Served at once the second time.
check(thumbs:want(req, function() end) == got, "a published thumbnail is served directly")

-- An edit is a new revision, and so a new file; the old one is untouched.
repo:transaction(function() return repo:touchSurface(page) end)
page = assert(repo:getPage(page.id))
local req2 = Thumbs.request(repo:dbUid(), nb, page, 120, 150)
check(Thumbs.key(req2) ~= Thumbs.key(req), "a new revision is a new key")
local got2
thumbs:want(req2, function(p) got2 = p end)
drain()
check(got2 and got2 ~= got, "published under a new name")
check(lfs.attributes(got, "mode") == "file", "the old file is left for the LRU")

-- A render that goes stale before it finishes is thrown away.
local req3 = Thumbs.request(repo:dbUid(), nb, page, 90, 110)
local got3, reason3
thumbs:want(req3, function(p, _, r) got3, reason3 = p, r end)
repo:transaction(function() return repo:touchSurface(page) end)
drain()
check(got3 == nil and reason3 == "stale", "a stale render is not published")
check(lfs.attributes(thumbs:pathFor(Thumbs.key(req3)), "mode") == nil, "no file")

-- Cancelled before it settles: nothing is written.
page = assert(repo:getPage(page.id))
local req4 = Thumbs.request(repo:dbUid(), nb, page, 60, 75)
thumbs:want(req4, function() error("a cancelled card is not called back") end)
thumbs:retain({})
drain()
check(lfs.attributes(thumbs:pathFor(Thumbs.key(req4)), "mode") == nil, "a cancelled job writes nothing")

thumbs:close()
repo:close()
for name in lfs.dir(dir) do
    if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
end
lfs.rmdir(dir)
lfs.rmdir(home)
os.remove(db_path)
print(string.format("THUMBNAIL_NATIVE_OK %d checks", checks))
