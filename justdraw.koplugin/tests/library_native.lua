--[[--
The notebook gallery against KOReader's real widgets, SQLite, raster, MuPDF
and PNG codec (Task 9.3).

The suite's widgets are stubs and its store is a table. They cannot say
whether real cards fit the screen at a real density, whether a tap reaches the
card under it through the real gesture ranges, whether a thumbnail rendered
from a real notebook is painted inside its card, whether memory stays put
while a reader pages back and forth a hundred times, or how long a first paint
and the longest single task take with 50 and with 500 notebooks. This does, at
four screen profiles.

    cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/library_native.lua [out-dir]

Like top_toolbar_native.lua it re-runs itself once per profile, because the
SDL framebuffer reads EMULATE_READER_W/H/DPI once per process. Prints
LIBRARY_CHECK_OK and exits 0 only when every profile printed its own marker.
Deliberately not in tests/run.lua, which must run on bare LuaJIT.

The timings are measurements, printed for the record: a scheduler that runs
work on later ticks does not by itself make anything "non-blocking", and this
test does not claim it. What it asserts is that no single task is anywhere
near a second on a desktop CPU, which is the size of bug it can catch.
]]

local this = debug.getinfo(1, "S").source:sub(2)

local PROFILES = {
    { name = "basic-portrait", w = 600, h = 800, dpi = 160, cols = 2 },
    { name = "kpw-portrait", w = 1072, h = 1448, dpi = 300, cols = 2 },
    { name = "scribe-portrait", w = 1860, h = 2480, dpi = 300, cols = 3 },
    { name = "scribe-landscape", w = 2480, h = 1860, dpi = 300, cols = 4 },
    -- Spanish, on the narrowest screen: longer labels, and the selection
    -- header's folding into More, read in the language that makes it longest.
    { name = "basic-portrait-es", w = 600, h = 800, dpi = 160, cols = 2, lang = "es" },
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

if not os.getenv("JUSTDRAW_LIBRARY_PROFILE") then
    local out = arg[1] or run('mktemp -d "${TMPDIR:-/tmp}/justdraw-library.XXXXXX"')
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
            "JUSTDRAW_LIBRARY_PROFILE=" .. quote(profile.name),
            "JUSTDRAW_LIBRARY_LANG=" .. quote(profile.lang or "C"),
            "./luajit", quote(this), ">", quote(log), "2>&1",
        }, " "))
        local file = io.open(log, "r")
        local text = file and file:read("*a") or ""
        if file then file:close() end
        local exited = status == 0 or status == true
        local marked = text:find("LIBRARY_NATIVE_OK " .. profile.name, 1, true) ~= nil
        if exited and marked then
            print("OK   " .. profile.name .. "  " .. home)
            for line in text:gmatch("[^\n]+") do
                if line:find("^BENCH ") then print("     " .. line) end
            end
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
    print("LIBRARY_CHECK_OK " .. out)
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
G_reader_settings:saveSetting("flash_ui", false)
local lang = os.getenv("JUSTDRAW_LIBRARY_LANG") or "C"
if lang ~= "C" then require("gettext").changeLang(lang) end

local Device = require("device")
require("document/canvascontext"):init(Device)
local BB = require("ffi/blitbuffer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local SQ3 = require("lua-ljsqlite3/init")
local time = require("ui/time")
local Controller = require("ink_notebook_controller")
local Layout = require("ink_notebook_layout")
local Library = require("ink_notebook_library")
local Repository = require("ink_notebook_repository")
local Thumbs = require("ink_thumbnail")

local profile_name = os.getenv("JUSTDRAW_LIBRARY_PROFILE")
local profile
for _, p in ipairs(PROFILES) do if p.name == profile_name then profile = p end end
local Screen = Device.screen
local W, H = Screen:getWidth(), Screen:getHeight()
local checks = 0
local function check(ok, why)
    assert(ok, profile_name .. ": " .. why)
    checks = checks + 1
end

local function rssKiB()
    local f = io.open("/proc/self/statm", "r")
    if not f then return 0 end
    local _, resident = f:read("*a"):match("(%d+)%s+(%d+)")
    f:close()
    return (tonumber(resident) or 0) * 4
end

-- ------------------------------------------------------------ the queue

--- One queue for the library, the controller and the thumbnails, drained by
--- hand and timed task by task: the longest task is the number that matters.
local tasks = {}
local longest = 0
local function schedule(fn) tasks[#tasks + 1] = fn end
local function unschedule(fn)
    for i = #tasks, 1, -1 do if tasks[i] == fn then table.remove(tasks, i) end end
end
local function drain(limit)
    local n = 0
    while #tasks > 0 do
        local fn = table.remove(tasks, 1)
        local t0 = time.now()
        fn()
        local ms = time.to_ms(time.since(t0))
        if ms > longest then longest = ms end
        n = n + 1
        assert(n < (limit or 100000), "the queue never settled")
    end
end

-- ------------------------------------------------------------ the library

local function build(count, folders)
    local path = string.format("%s/notebooks-%d.sqlite3", home, count)
    local repo = assert(Repository.open{ path = path, driver = SQ3 })
    local shape = assert(Layout.screenPage())
    local ids = {}
    repo:transaction(function()
        for i = 1, folders do assert(repo:createFolder("Carpeta " .. i)) end
        return true
    end)
    for i = 1, count do
        local title = (i % 7 == 0) and ("Cuaderno de física cuántica y apuntes del año académico " .. i)
            or ("Notebook " .. i)
        local nb, page = assert(repo:createNotebook{ title = title, logical_w = shape.logical_w,
            logical_h = shape.logical_h, template_kind = (i % 2 == 0) and "ruled" or "blank" })
        ids[i] = nb.id
        if i <= 12 then
            repo:transaction(function()
                local pts = {}
                for k = 0, 39 do
                    pts[#pts + 1] = math.floor(shape.logical_w * (0.15 + 0.7 * k / 39))
                    pts[#pts + 1] = math.floor(shape.logical_h * (0.3 + 0.1 * math.sin(k / 3)))
                end
                assert(repo:addStroke(page, { points = pts, n = 40, width = 24, tool = 1 }))
                return repo:touchSurface(page)
            end)
        end
    end
    if folders > 0 then
        for i = count - 4, count do assert(repo:moveNotebook(ids[i], 1)) end
    end
    return repo, path
end

local function openLibrary(repo, with_thumbs, dir)
    local controller = Controller.new{ repository = repo, schedule = schedule,
        scheduleIn = function(_, fn) schedule(fn) end, unschedule = unschedule }
    local opened = {}
    local thumbs
    if with_thumbs then
        local deps = Thumbs.nativeDeps()
        lfs.mkdir(dir)
        thumbs = Thumbs.new{ dir = dir, repository = function() return repo end,
            schedule = function(_, fn) schedule(fn) end, unschedule = unschedule,
            raster_open = deps.raster_open, scale = deps.scale, write = deps.write, fs = deps.fs }
    end
    local library = Library:new{ controller = controller, schedule = schedule,
        thumbnails = thumbs, on_open = function(item) opened[#opened + 1] = item end }
    library:markShown()
    return library, controller, opened
end

local bb = BB.new(W, H, BB.TYPE_BB8)

local function paint(library)
    bb:fill(BB.COLOR_WHITE)
    library:paintTo(bb, 0, 0)
end

-- ------------------------------------------------------------ geometry

local repo = build(50, 3)
local library, _, opened = openLibrary(repo, true, home .. "/thumbs")
local t0 = time.now()
library:startLoading()
drain()
paint(library)
local first_ms = time.to_ms(time.since(t0))

local m = library.metrics
local mm30 = Layout.physicalPixels(30)
check(m.cols == profile.cols, ("%d columns (got %d)"):format(profile.cols, m.cols))
check(m.card_w >= mm30, "every card is at least 30 mm wide")
check(m.card_h >= mm30, "and at least 30 mm tall")
check(m.rows >= 1, "at least one row")
check(#library.cards == m.per_screen, "a full first screen")
check(library.cards[1].kind == "folder", "folders first")
local header_bottom = 0
for _, button in ipairs(library.header_buttons) do
    local d = button.dimen
    check(d and d.x >= 0 and d.x + d.w <= W, "header button " .. tostring(button.action_id) .. " on screen")
    check(d.h >= Layout.physicalPixels(10) - 2, "a 10 mm header target")
    header_bottom = math.max(header_bottom, d.y + d.h)
end
local footer_top = H
for _, button in ipairs(library.footer_buttons) do
    footer_top = math.min(footer_top, button.dimen.y)
    check(button.dimen.y + button.dimen.h <= H, "footer on screen")
end
for i, card in ipairs(library.cards) do
    local d = card.dimen
    check(d.x >= 0 and d.x + d.w <= W, "card " .. i .. " inside the width")
    check(d.y >= header_bottom and d.y + d.h <= footer_top, "card " .. i .. " between header and footer")
    for j = i + 1, #library.cards do
        local e = library.cards[j].dimen
        check(not (d.x < e.x + e.w and e.x < d.x + d.w and d.y < e.y + e.h and e.y < d.y + d.h),
            "cards " .. i .. " and " .. j .. " do not overlap")
    end
end

-- A tap through the real gesture ranges reaches the card under the finger.
local function tapAt(widget, x, y)
    return widget:handleEvent(Event:new("Gesture", { ges = "tap",
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 } }))
end
local target
for _, card in ipairs(library.cards) do
    if card.kind == "notebook" and not target then target = card end
end
local d = target.dimen
tapAt(library, d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
check(opened[1] and opened[1].id == target.item.id, "a tap opens the card under it")
local folder_card = library.cards[1]
tapAt(library, folder_card.dimen.x + 5, folder_card.dimen.y + 5)
drain()
check(library.folder and library.folder.id == folder_card.item.id, "a tap enters the folder")
paint(library)
check(library.cards[1].kind == "back", "Back is the first card inside")
tapAt(library, library.cards[1].dimen.x + 5, library.cards[1].dimen.y + 5)
drain()
check(library.folder == nil, "Back returns")
paint(library)

if lang == "es" then
    -- The plugin's own catalogue answers, not the source text.
    check(library.header_buttons[1].text == "Nuevo cuaderno",
        "the header is in Spanish: " .. tostring(library.header_buttons[1].text))
    library:setSelecting(true)
    paint(library)
    local labels = {}
    for _, b in ipairs(library.header_buttons) do
        labels[#labels + 1] = b.text
        check(b.dimen.x + b.dimen.w <= W, "selection action " .. b.text .. " on screen")
        check(b.dimen.w >= Layout.physicalPixels(20) - 2, b.text .. " keeps its target width")
    end
    print("BENCH selection header: " .. table.concat(labels, " | ")
        .. "  (More: " .. table.concat(library.header_more, ", ") .. ")")
    check(labels[#labels] == "Hecho", "Done stays on the row")
    bb:writePNG(home .. "/library-select.png")
    library:setSelecting(false)
    paint(library)
end

-- A long delete confirmation: every title, in a list that scrolls, with its
-- buttons on the screen however many items there are.
do
    local many = {}
    for i = 1, 40 do many[i] = { kind = "notebook", id = 1000 + i, title = "Cuaderno " .. i, page_count = 1 } end
    local box = library:confirmDeleteItems(many)
    check(box and box.buttons_table ~= nil, "forty items get a scrolling list")
    box:paintTo(bb, 0, 0)
    local frame = box.dimen or (box[1] and box[1].dimen)
    check(frame and frame.y >= 0 and frame.y + frame.h <= H, "and it fits the screen")
    library:_closeModal(box)
    paint(library)
end

-- ------------------------------------------------------------ thumbnails

drain()
paint(library)
local with_image = 0
for _, card in ipairs(library.cards) do
    if card.kind == "notebook" then
        check(card.image_state == "ready", "card " .. card.item.id .. " has its thumbnail: "
            .. tostring(card.image_state))
        check(card.image ~= nil, "and it was decoded by ImageWidget")
        with_image = with_image + 1
        local size = card.image:getSize()
        check(size.w <= m.thumb_w and size.h <= m.thumb_h, "the picture fits its box")
    end
end
check(with_image > 0, "some notebooks on the first screen")
-- The newest notebooks were created last, so the first screen shows blank
-- pages; the inked ones (the first twelve) are further on. Find one, and
-- count dark pixels inside its picture.
library:setSort("oldest")
drain(); paint(library); drain(); paint(library)
local inked
for _, card in ipairs(library.cards) do
    if card.kind == "notebook" and card.item.id <= 12 and card.image then inked = card end
end
check(inked ~= nil, "an inked notebook on the oldest-first screen")
local ix, iy = inked.dimen.x + inked.pad, inked.dimen.y + inked.pad
local dark = 0
for y = iy, iy + m.thumb_h - 1, 2 do
    for x = ix, ix + m.thumb_w - 1, 2 do
        if bb:getPixel(x, y):getColor8().a < 96 then dark = dark + 1 end
    end
end
check(dark > 0, "the notebook's ink is visible in its card")
-- Left behind to look at, as top_toolbar_native.lua does.
bb:writePNG(home .. "/library.png")

-- ------------------------------------------------------------ memory

-- A hundred page changes, pictures and all, after one warm-up round.
local function pageBackAndForth(n)
    for i = 1, n do
        if not library:nextScreen() then library:previousScreen() end
        drain(); paint(library)
        if i % 2 == 0 then library:previousScreen(); drain(); paint(library) end
    end
end
pageBackAndForth(10)
collectgarbage(); collectgarbage()
local rss_before, lua_before = rssKiB(), collectgarbage("count")
pageBackAndForth(100)
collectgarbage(); collectgarbage()
local rss_after, lua_after = rssKiB(), collectgarbage("count")
print(("BENCH memory: rss %d -> %d KiB, lua %.0f -> %.0f KiB over 100 page changes")
    :format(rss_before, rss_after, lua_before, lua_after))
check(lua_after - lua_before < 2048, "the Lua heap is stable across 100 page changes")
check(rss_after - rss_before < 24 * 1024, "resident memory is stable across 100 page changes")

library:shutdown()
repo:close()
print(("BENCH 50 notebooks: first paint %.1f ms, longest task %.1f ms"):format(first_ms, longest))

-- ------------------------------------------------------------ 500

longest = 0
local big = build(500, 20)
local rss0 = rssKiB()
local big_library = openLibrary(big, false)
t0 = time.now()
big_library:startLoading()
drain()
paint(big_library)
local big_first = time.to_ms(time.since(t0))
local peak = rssKiB()
local screens = 1
while big_library:nextScreen() do
    drain(); paint(big_library)
    screens = screens + 1
    peak = math.max(peak, rssKiB())
end
print(("BENCH 500 notebooks: first paint %.1f ms, longest task %.1f ms, %d screens, peak rss +%d KiB")
    :format(big_first, longest, screens, peak - rss0))
-- 20 folders and 495 notebooks at the root; five live in folder 1.
check(screens == math.ceil(515 / m.per_screen), "every item reachable by Next, and no empty screen")
check(longest < 1000, "no single task near a second")
check(big_library.batch and #big_library.batch.items <= 50, "a bounded batch in memory")
big_library:shutdown()
big:close()

print(("LIBRARY_NATIVE_OK %s %d checks"):format(profile_name, checks))
