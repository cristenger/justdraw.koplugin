--[[--
Hand exported `.xopp` files to programs that share nothing with the writer,
and see whether they agree it is gzip around well-formed Xournal++ XML.

Everything else that reads these files has a stake in them. The job spec reads
the XML back with Lua patterns written from the same understanding as the
writer, through a fake libarchive; the native check proves the adapter against
KOReader's library but judges only its own fixtures. Here `gzip -t` walks the
stream and its trailer (CRC and length, which nothing in the plugin computes),
`xmllint` parses the XML as a strict XML 1.0 parser does -- where a stray
control byte, an unescaped `&` in a title or an unbalanced element is fatal --
and XPath counts the pages and strokes independently of any regex.

The files are made the way a reader makes them: a real notebook database,
the real job through `ink_export`, the real filesystem and KOReader's own
libarchive. That last one is why this runs with KOReader's LuaJIT, from its
`lib/koreader` directory; under a bare LuaJIT the fixtures cannot be built and
every claim is UNCHECKABLE (a failure under STRICT).

Deliberately outside `tests/run.lua`, like pdf_external_check.lua: the suite
must keep running with nothing but LuaJIT. CI runs this with STRICT, where an
absent tool means the workflow is broken rather than the machine older.

  cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/xopp_external_check.lua
  JUSTDRAW_XOPP_EXTERNAL_STRICT=1 ...   tool or library absent becomes a failure
  JUSTDRAW_XOPP_EXTERNAL_KEEP=1 ...     leave the fixtures behind to look at
]]

local in_koreader = pcall(require, "setupkoenv")

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local rows = {}
local function claim(name, checkable, ok, detail)
    if not checkable then
        rows[#rows + 1] = { "UNCHECKABLE", name, detail or "tool absent" }
    elseif ok then
        rows[#rows + 1] = { "OK", name, detail or "" }
    else
        rows[#rows + 1] = { "MISMATCH", name, detail or "" }
    end
end

-- ------------------------------------------------------------------- tools

--- `os.execute` under Lua 5.1 answers the raw `wait` status. gzip answers 2
--- for a warning (trailing garbage, for one), which must not pass as 0.
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

local function capture(cmd)
    local pipe = io.popen(cmd .. " 2>/dev/null")
    if not pipe then return nil end
    local out = pipe:read("*a")
    pipe:close()
    return out
end

local function count(s, pattern)
    local n = 0
    for _ in s:gmatch(pattern) do n = n + 1 end
    return n
end

-- ------------------------------------------------------------------- setup

local strict = os.getenv("JUSTDRAW_XOPP_EXTERNAL_STRICT") == "1"
local keep = os.getenv("JUSTDRAW_XOPP_EXTERNAL_KEEP") == "1"

math.randomseed(os.time())
local work = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    .. "/justdraw-xopp-check-" .. os.time() .. "-" .. math.random(100000, 999999)
os.execute("mkdir -p '" .. work .. "/out' '" .. work .. "/spool'")

local have_gzip = haveTool("gzip")
local have_xmllint = haveTool("xmllint")

local UNITS = 8 -- the notebook layout's logical units per millimetre
local A5W, A5H = 148 * UNITS, 210 * UNITS
local PEN, MARKER, HIGHLIGHTER, TEXTURED = 1, 3, 67, 68

--[[--
Every fixture: title, pages as { w, h, paper, strokes }, each stroke
{ n, width, tool }. The shapes are the ones a writer gets wrong: a dot, a
stroke over several stored chunks, every tool, every paper including the two
Xournal++ lacks, a landscape page, pages with nothing on them, a title with
markup characters and non-ASCII text, and enough pages to cross every batch.
]]
local function strokes(k, n, tool)
    local out = {}
    for i = 1, k do out[i] = { n = n, width = 8 + i % 5, tool = tool or PEN } end
    return out
end

local FIXTURES = {
    { name = "plain", title = "Plain", pages = {
        { w = A5W, h = A5H, paper = "ruled", strokes = strokes(3, 40) } } },
    { name = "mixed", title = "Café – ✓ & <b>\"notes\"</b>", pages = {
        { w = A5W, h = A5H, paper = "grid", strokes = {
            { n = 1, width = 12, tool = PEN },            -- a dot
            { n = 3000, width = 10, tool = PEN },         -- three stored chunks
            { n = 50, width = 40, tool = HIGHLIGHTER },
            { n = 50, width = 20, tool = MARKER },
            { n = 50, width = 14, tool = TEXTURED },
        } },
        { w = A5W, h = A5H, paper = "dots", strokes = strokes(4, 25) },
        { w = A5W, h = A5H, paper = "checklist", strokes = strokes(2, 10) },
        { w = A5H, h = A5W, paper = "ruled_narrow", strokes = strokes(2, 10) },
    } },
    { name = "blank", title = "Blank", pages = {
        { w = A5W, h = A5H, paper = "blank", strokes = {} },
        { w = A5W, h = A5H, paper = "blank", strokes = {} },
        { w = A5W, h = A5H, paper = "blank", strokes = {} } } },
    { name = "many", title = "Many", pages = (function()
        local out = {}
        for i = 1, 60 do out[i] = { w = A5W, h = A5H, paper = "ruled", strokes = strokes(5, 30) } end
        return out
    end)() },
}

local function expected(fixture)
    local n = 0
    for i = 1, #fixture.pages do n = n + #fixture.pages[i].strokes end
    return #fixture.pages, n
end

--[[--
Build one fixture through the whole export path. Answers the published path,
or nil and why. Needs KOReader: its SQLite, its lfs and its libarchive.
]]
local function build(fixture)
    local Archive = require("ink_export_xopp_archive")
    local available, why, missing = Archive.available()
    if not available then return nil, "libarchive: " .. tostring(why) .. " " .. tostring(missing) end
    local Repository = require("ink_notebook_repository")
    local Export = require("ink_export")
    local XoppJob = require("ink_export_xopp_job")

    local repo, open_err = Repository.open{ path = work .. "/" .. fixture.name .. ".sqlite3" }
    if not repo then return nil, "notebook store: " .. tostring(open_err) end
    local first = fixture.pages[1]
    local notebook, page = repo:createNotebook{ title = fixture.title,
        logical_w = first.w, logical_h = first.h, template_kind = first.paper }
    if not notebook then repo:close() return nil, "createNotebook failed" end
    local all = { page }
    for i = 2, #fixture.pages do
        local spec = fixture.pages[i]
        all[i] = assert(repo:appendPage(notebook.id,
            { logical_w = spec.w, logical_h = spec.h, template_kind = spec.paper }))
    end
    for i, spec in ipairs(fixture.pages) do
        local row = all[i]
        for s, stroke in ipairs(spec.strokes) do
            local pts = {}
            for k = 1, stroke.n do
                pts[k * 2 - 1] = (k * 2.75 + s * 19 + i) % (row.logical_w - 1)
                pts[k * 2] = (k * 1.25 + s * 23 + i * 3) % (row.logical_h - 1)
            end
            assert(repo:addStroke(row, { points = pts, n = stroke.n,
                width = stroke.width, tool = stroke.tool }))
        end
    end

    local items = {}
    local after_key, after_id
    while true do
        local batch = assert(repo:listPages(notebook.id,
            { limit = 100, after_sort_key = after_key, after_id = after_id }))
        if #batch == 0 then break end
        for k = 1, #batch do items[#items + 1] = batch[k] end
        after_key, after_id = batch[#batch].sort_key, batch[#batch].id
    end

    local queue, result = {}, nil
    local job, err = Export.start{
        format = "xopp", dir = work .. "/out", stem = fixture.name, items = items,
        title = fixture.title,
        schedule = function(fn) queue[#queue + 1] = fn end,
        produce = XoppJob.producer{ repository = repo, notebook_id = notebook.id,
            spool_dir = work .. "/spool", title = fixture.title, units_per_mm = UNITS },
        on_done = function(r) result = r end,
    }
    if not job then repo:close() return nil, "export did not start: " .. tostring(err) end
    while #queue > 0 do table.remove(queue, 1)() end
    repo:close()
    if not result or result.status ~= "done" then
        return nil, "export " .. tostring(result and result.status) .. ": "
            .. tostring(result and result.error)
    end
    return result.written[1]
end

-- ---------------------------------------------------------------- claims

for _, fixture in ipairs(FIXTURES) do
    local label = fixture.name
    local path, why
    if in_koreader then
        local ok, res, err = pcall(build, fixture)
        if ok then path, why = res, err else why = tostring(res) end
    else
        why = "not running under KOReader's LuaJIT (no libarchive, lfs or SQLite)"
    end
    claim("the " .. label .. " export could be built", in_koreader, path ~= nil, why)

    local want_pages, want_strokes = expected(fixture)
    local built = path ~= nil

    -- gzip -t: exit 0 only. 2 is a warning -- trailing bytes after the
    -- stream, the symptom of a padded last block -- and is a defect here.
    if not (have_gzip and built) then
        claim("gzip -t accepts the " .. label .. " export", false, false,
            have_gzip and "fixture missing" or "gzip not installed")
    else
        local code = exitCode(os.execute("gzip -t '" .. path .. "' 2>/dev/null"))
        claim("gzip -t accepts the " .. label .. " export", true, code == 0,
            code ~= 0 and ("exit " .. code) or "")
    end

    local xml_path = work .. "/" .. label .. ".xml"
    local xml
    if have_gzip and built
        and exitCode(os.execute("gzip -dc '" .. path .. "' > '" .. xml_path .. "' 2>/dev/null")) == 0 then
        xml = readAll(xml_path)
    end

    claim("the " .. label .. " export is Xournal++ XML", xml ~= nil,
        xml ~= nil and xml:sub(1, 5) == "<?xml" and xml:find("<xournal ", 1, true) ~= nil,
        xml and xml:sub(1, 60):gsub("%s+", " ") or "not decompressed")

    if not (have_xmllint and xml) then
        claim("xmllint finds the " .. label .. " export well formed", false, false,
            have_xmllint and "no XML" or "xmllint not installed")
        claim("XPath counts " .. want_pages .. " pages and " .. want_strokes
            .. " strokes in " .. label, false, false,
            have_xmllint and "no XML" or "xmllint not installed")
    else
        local log = work .. "/" .. label .. "-xmllint.txt"
        local code = exitCode(os.execute("xmllint --noout '" .. xml_path .. "' > '" .. log .. "' 2>&1"))
        claim("xmllint finds the " .. label .. " export well formed", true, code == 0,
            code ~= 0 and ((readAll(log) or ""):gsub("%s+", " "):sub(1, 160)) or "")
        local pages = tonumber(capture("xmllint --xpath 'count(/xournal/page)' '" .. xml_path .. "'"))
        local strokes_seen = tonumber(capture("xmllint --xpath 'count(/xournal/page/layer/stroke)' '" .. xml_path .. "'"))
        -- xmllint ends an XPath string result with a newline of its own.
        local title = (capture("xmllint --xpath 'string(/xournal/title)' '"
            .. xml_path .. "'") or ""):gsub("\n$", "")
        claim("XPath counts " .. want_pages .. " pages and " .. want_strokes
            .. " strokes in " .. label, true,
            pages == want_pages and strokes_seen == want_strokes and title == fixture.title,
            string.format("pages %s, strokes %s, title %q", tostring(pages),
                tostring(strokes_seen), tostring(title)))
    end

    -- Counted a second way, independent of xmllint, so a missing tool still
    -- leaves one check of the counts.
    if xml then
        local pages, seen = count(xml, "<page "), count(xml, "<stroke ")
        claim("the " .. label .. " export holds every page and stroke", true,
            pages == want_pages and seen == want_strokes,
            string.format("%d/%d pages, %d/%d strokes", pages, want_pages, seen, want_strokes))
    else
        claim("the " .. label .. " export holds every page and stroke", false, false, "no XML")
    end
end

-- ------------------------------------------------------------------ report

if not keep then os.execute("rm -rf '" .. work .. "'") end

for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-60s %s\n", r[1], r[2], r[3]))
end

local bad, uncheckable = 0, 0
for _, r in ipairs(rows) do
    if r[1] == "MISMATCH" then bad = bad + 1
    elseif r[1] == "UNCHECKABLE" then uncheckable = uncheckable + 1 end
end
if strict then bad = bad + uncheckable end

io.write(string.format("\n%d claims, %d failures", #rows, bad))
if uncheckable > 0 then
    io.write(string.format(" (%d uncheckable%s)", uncheckable,
        strict and ", counted because STRICT is set" or ""))
end
io.write("\n")
if keep then io.write("fixtures kept in " .. work .. "\n") end
os.exit(bad == 0 and 0 or 1)
