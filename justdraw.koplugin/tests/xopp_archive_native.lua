--[[--
The Xournal++ archive adapter against KOReader's own libarchive (Task 10.2).

The suite's fake libarchive answers what the spec tells it to, so it can say
that every result is *checked*; it cannot say that this build has the symbols,
that `raw` + `gzip` produces a stream `gzip -t` accepts, that nothing pads the
end of it, that a full disk really surfaces at the close, or what one
synchronous block costs. This does, and then runs a whole export -- a real
notebook database, the real job, the real filesystem -- and hands the file to
tools that share nothing with the writer.

    cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/xopp_archive_native.lua [work-dir]

Prints XOPP_ARCHIVE_NATIVE_OK and exits 0 when every check passes. The worst
block latency is printed as XOPP_ARCHIVE_WORST_BLOCK_MS.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;" .. package.path

local base = (arg[1] or os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
math.randomseed(os.time())
local work = base .. "/justdraw-xopp-native-" .. os.time() .. "-" .. math.random(100000, 999999)
os.execute("mkdir -p '" .. work .. "'")

local ffi = require("ffi")
local Archive = require("ink_export_xopp_archive")
local Export = require("ink_export")
local Repository = require("ink_notebook_repository")
local Xopp = require("ink_export_xopp")
local XoppJob = require("ink_export_xopp_job")

--- The notebook layout's units, stated rather than required: the layout
--- module loads Device, and this check needs no screen.
local UNITS = 8

local checks = 0
local function check(ok, why)
    if not ok then
        io.write("FAIL ", why, "\n")
        os.exit(1)
    end
    checks = checks + 1
end

local function exitCode(raw)
    if type(raw) == "boolean" then return raw and 0 or 1 end
    local code = tonumber(raw) or 1
    if code >= 256 then return math.floor(code / 256) end
    return code
end

local function haveTool(name)
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null")
    if not pipe then return false end
    local found = pipe:read("*l")
    pipe:close()
    return found ~= nil and found ~= ""
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- KOReader's own declarations; nothing redefined here either.
require("ffi/posix_h")
local ts = ffi.new("struct timespec")
local function nowMs()
    ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
    return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

-- --------------------------------------------------------------- 1. symbols

local ok, err, missing = Archive.available()
check(ok, "every adapter symbol resolves: " .. tostring(err) .. " " .. tostring(missing))
local backend = assert(Archive.load())
for _, name in ipairs(Archive.REQUIRED) do
    check(pcall(function() return backend.lib[name] end), name .. " resolves")
end
print(string.format("OK   conformance: %d libarchive symbols resolve in this build", #Archive.REQUIRED))

-- ------------------------------------------------- 2. a real .xopp, measured

--- A spool of real Xournal++ XML: `pages` pages of `strokes` strokes, with
--- coordinates varied enough that deflate has work to do.
local function writeSpool(path, pages, strokes, n)
    local f = assert(io.open(path, "wb"))
    local bytes = 0
    local writer = assert(Xopp.beginDocument(function(chunk)
        bytes = bytes + #chunk
        return f:write(chunk) and true
    end, { units_per_mm = 8, title = "JustDraw native check" }))
    for p = 1, pages do
        assert(writer:beginPage{ width = 1184, height = 1680, paper = "ruled" })
        for s = 1, strokes do
            local pts = {}
            for k = 1, n do
                pts[k * 2 - 1] = (k * 3.137 + s * 17.21 + math.random() * 5) % 1183
                pts[k * 2] = (k * 1.913 + s * 29.03 + p + math.random() * 5) % 1679
            end
            assert(writer:writeStroke{ points = pts, n = n, width = 12 + s % 5, tool = (s % 3 == 0) and 67 or 1 })
        end
        assert(writer:endPage())
    end
    assert(writer:endDocument())
    assert(f:close())
    return bytes
end

local function compress(spool, out, size, block)
    local reader = assert(io.open(spool, "rb"))
    local w, open_err, detail = Archive.open(out, { size = size })
    check(w ~= nil, "adapter opens: " .. tostring(open_err) .. " " .. tostring(detail))
    local worst, total = 0, 0
    while true do
        local chunk = reader:read(block)
        if not chunk then break end
        local t0 = nowMs()
        local wrote, werr, wdetail = w:write(chunk)
        local dt = nowMs() - t0
        check(wrote, "block written: " .. tostring(werr) .. " " .. tostring(wdetail))
        if dt > worst then worst = dt end
        total = total + dt
    end
    reader:close()
    local t0 = nowMs()
    local closed, cerr, cdetail = w:close()
    local close_ms = nowMs() - t0
    check(closed, "close and free both succeed: " .. tostring(cerr) .. " " .. tostring(cdetail))
    return worst, close_ms, total
end

local spool = work .. "/spool.xml"
local size = writeSpool(spool, 40, 30, 400)
check(size > 1000000, "a spool of real size: " .. size)
local worst_by_block = {}
for _, block in ipairs({ XoppJob.BLOCK, Archive.MAX_BLOCK }) do
    local out = work .. "/measured-" .. block .. ".xopp"
    local worst, close_ms, total = compress(spool, out, size, block)
    worst_by_block[block] = worst
    local gz = readAll(out)
    check(Archive.verify(out, size), "the adapter's own verification accepts it")
    print(string.format("OK   %d B XML -> %d B gzip in %d B blocks: worst block %.2f ms, close %.2f ms, all blocks %.1f ms",
        size, #gz, block, worst, close_ms, total))
end

local out = work .. "/measured-" .. XoppJob.BLOCK .. ".xopp"
local have_gzip = haveTool("gzip")
check(have_gzip, "gzip is installed (needed to judge the stream)")
check(exitCode(os.execute("gzip -t '" .. out .. "' 2>/dev/null")) == 0, "gzip -t accepts the stream (no padding, no trailing bytes)")
check(exitCode(os.execute("gzip -dc '" .. out .. "' > '" .. work .. "/round.xml'")) == 0, "it decompresses")
local round = readAll(work .. "/round.xml")
check(round == readAll(spool), "byte for byte the spool")
check(round:sub(1, 5) == "<?xml", "starts with <?xml")
check(round:find("<xournal", 1, true) ~= nil, "contains <xournal")
print("OK   gzip -t and gzip -dc agree it is the spool, byte for byte")

-- ----------------------------------------------------- 3. failures, for real

-- /dev/full accepts the open and refuses every write with ENOSPC. Small data
-- sits in libarchive's buffer, so the failure can only show at the close --
-- exactly the result KOReader's own Writer:close() throws away.
do
    local tiny = "<?xml version=\"1.0\"?><xournal/>"
    local w = Archive.open("/dev/full", { size = #tiny })
    if w then
        local wrote = w:write(tiny)
        local closed, cerr, detail = true, nil, nil
        if wrote then closed, cerr, detail = w:close() end
        check(not wrote or not closed, "a full device fails the write or the close")
        print("OK   /dev/full: refused at " .. (wrote and "close" or "write") .. " (" .. tostring(detail or cerr) .. ")")
    else
        print("OK   /dev/full: refused at open")
    end
    -- The same full device through KOReader's own wrapper: every call it
    -- makes answers success, and `close()` has nothing to say. This is the
    -- reason the adapter exists.
    local Writer = require("ffi/archiver").Writer
    local kw = Writer:new()
    local opened = kw:open("/dev/full", "raw.gz")
    local added = opened and kw:addFileFromMemory("document.xml", tiny)
    local closed_answer = opened and kw:close()
    check(opened and added and closed_answer == nil and kw.err == nil,
        "KOReader's Writer reports the full device as success (unchanged upstream?)")
    print("OK   Archiver.Writer on /dev/full: open, add and close all silent -- the failure is invisible there")

    local nowhere = Archive.open(work .. "/no/such/dir/x.xopp", { size = 1 })
    check(nowhere == nil, "an unwritable path fails at open")
    print("OK   a missing directory is refused at open")
end

-- ------------------------------------------- 4. the whole export, end to end

local db = work .. "/notebooks.sqlite3"
local repo = assert(Repository.open{ path = db })
local notebook, first = assert(repo:createNotebook{ title = "Native & <check>", logical_w = 1184, logical_h = 1680, template_kind = "grid" })
local pages = { first, assert(repo:appendPage(notebook.id, { logical_w = 1184, logical_h = 1680, template_kind = "ruled" })),
    assert(repo:appendPage(notebook.id, { logical_w = 1680, logical_h = 1184 })) }
local strokes = 0
for p, page in ipairs(pages) do
    for s = 1, 25 do
        local n = (s == 1) and 2500 or (s % 7 + 1) * 20 -- one multi-chunk stroke per page
        local pts = {}
        for k = 1, n do
            pts[k * 2 - 1] = (k * 2.5 + s * 13) % (page.logical_w - 1)
            pts[k * 2] = (k * 1.5 + s * 31 + p) % (page.logical_h - 1)
        end
        -- Paint order reversed from insertion for the second page.
        local paint = p == 2 and (100 - s) or nil
        assert(repo:addStroke(page, { points = pts, n = n, width = 10 + s % 4, tool = 1, paint_seq = paint }))
        strokes = strokes + 1
    end
end
-- An erased stroke must not be exported.
local doomed = assert(repo:addStroke(pages[1], { points = { 10, 10, 20, 20 }, n = 2, width = 99, tool = 1 }))
assert(repo:deleteStroke(doomed))

local batch = assert(repo:listStrokesBatch(pages[2].id, { limit = 5 }))
check(#batch == 5 and batch[1].paint_seq < batch[2].paint_seq, "listStrokesBatch pages in paint order on real SQLite")
local rest = assert(repo:listStrokesBatch(pages[2].id, { limit = 200, after_paint_seq = batch[5].paint_seq, after_seq = batch[5].seq }))
check(#rest == 20, "and resumes strictly after the cursor: " .. #rest)
local rev = assert(repo:strokeRevision(pages[1].id))
check(rev.count == 25, "strokeRevision counts live strokes only: " .. rev.count)

-- The pages as the dialog's build lists them (ink_export_source walks the
-- same keyset; it is not required here because it loads Device).
local list = assert(repo:listPages(notebook.id, { limit = 100 }))
check(#list == 3, "three pages listed")
local dest = work .. "/out"
assert(os.execute("mkdir -p '" .. dest .. "' '" .. work .. "/spool' '" .. work .. "/home'") == 0 or true)
-- The first export finds its spool folder the way the plugin does: under
-- KOReader's data directory, created through `ink_export`'s own filesystem.
-- KO_HOME points that directory into the work folder.
ffi.C.setenv("KO_HOME", work .. "/home", 1)
local queue, result = {}, nil
local job, start_err = Export.start{
    format = "xopp", dir = dest, stem = "Native export", items = list,
    schedule = function(fn) queue[#queue + 1] = fn end,
    produce = XoppJob.producer{ repository = repo, notebook_id = notebook.id,
        title = notebook.title, units_per_mm = UNITS },
    on_done = function(r) result = r end,
}
check(job ~= nil, "the export starts: " .. tostring(start_err))
local turns, worst_turn = 0, 0
while #queue > 0 do
    local fn = table.remove(queue, 1)
    local t0 = nowMs()
    fn()
    local dt = nowMs() - t0
    if dt > worst_turn then worst_turn = dt end
    turns = turns + 1
end
check(result and result.status == "done", "the export finished: " .. tostring(result and result.error))
local target = dest .. "/Native export.xopp"
check(readAll(target) ~= nil, "published under the chosen name")
check(exitCode(os.execute("gzip -t '" .. target .. "' 2>/dev/null")) == 0, "gzip -t accepts the export")
check(exitCode(os.execute("gzip -dc '" .. target .. "' > '" .. work .. "/export.xml'")) == 0, "and it decompresses")
local xml = readAll(work .. "/export.xml")
local function count(s, pattern) local c = 0 for _ in s:gmatch(pattern) do c = c + 1 end return c end
check(xml:sub(1, 5) == "<?xml" and xml:find("<xournal", 1, true), "Xournal++ XML")
check(count(xml, "<page ") == 3, "three pages")
check(count(xml, "<stroke ") == strokes, "every live stroke: " .. count(xml, "<stroke "))
check(xml:find("<title>Native &amp; &lt;check&gt;</title>", 1, true) ~= nil, "the title, escaped")
check(xml:find('style="graph"', 1, true) ~= nil, "the grid paper")
if haveTool("xmllint") then
    check(exitCode(os.execute("xmllint --noout '" .. work .. "/export.xml' 2>/dev/null")) == 0, "xmllint: well formed")
    print("OK   xmllint --noout accepts the export")
else
    print("SKIP xmllint not installed")
end
local leftovers = 0
for name in require("libs/libkoreader-lfs").dir(dest) do
    if name:sub(1, 1) == "." and name ~= "." and name ~= ".." then leftovers = leftovers + 1 end
end
local spool_dir = work .. "/home/" .. XoppJob.SPOOL_SUBDIR
check(require("libs/libkoreader-lfs").attributes(spool_dir, "mode") == "directory",
    "the spool folder was created under the data directory")
for name in require("libs/libkoreader-lfs").dir(spool_dir) do
    if name ~= "." and name ~= ".." then leftovers = leftovers + 1 end
end
check(leftovers == 0, "no temporary and no spool left behind")
print(string.format("OK   end to end: %d pages, %d strokes, %d turns, worst turn %.2f ms", 3, strokes, turns, worst_turn))

-- A stroke drawn while the export runs: refused, nothing published.
local queue2, result2 = {}, nil
local job2 = Export.start{
    format = "xopp", dir = dest, stem = "Changed", items = list,
    schedule = function(fn) queue2[#queue2 + 1] = fn end,
    produce = XoppJob.producer{ repository = repo, notebook_id = notebook.id,
        spool_dir = work .. "/spool", units_per_mm = UNITS },
    on_done = function(r) result2 = r end,
}
check(job2 ~= nil, "second export starts")
local drawn = false
while #queue2 > 0 do
    table.remove(queue2, 1)()
    if not drawn and job2.producer and job2.producer:phase() == "compress" then
        assert(repo:addStroke(pages[1], { points = { 5, 5, 50, 50 }, n = 2, width = 8, tool = 1 }))
        drawn = true
    end
end
check(drawn and result2 and result2.error == "notebook_changed", "an edit during the export is refused: " .. tostring(result2 and result2.error))
check(readAll(dest .. "/Changed.xopp") == nil, "and nothing was published")
repo:close()

os.execute("rm -rf '" .. work .. "'")
print(string.format("XOPP_ARCHIVE_WORST_BLOCK_MS=%.2f (the job's %d B block; %.2f at %d B)",
    worst_by_block[XoppJob.BLOCK], XoppJob.BLOCK, worst_by_block[Archive.MAX_BLOCK], Archive.MAX_BLOCK))
print(string.format("XOPP_ARCHIVE_NATIVE_OK (%d checks)", checks))
os.exit(0)
