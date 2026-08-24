--[[--
Contrast the test harness's assumptions against the KOReader runtime that is
actually installed. Run it under an emulator build's LuaJIT, from inside that
build's directory so KOReader's own package.path resolves; it needs a real
Device, not a running session.

Three outcomes per claim. UNCHECKABLE is a first-class result: the local runtime
may be older than the stylus API, and pretending otherwise is how a suite ends
up proving only what it already believed. A MISMATCH means a stub in
tests/support.lua describes something KOReader does not do -- fix the stub, not
this file.
]]

-- KOReader's own search paths. reader.lua does exactly this before anything
-- else; running from the build directory is what makes it resolvable.
require("setupkoenv")

-- The plugin's own modules, resolved from this file rather than from the
-- working directory: this script is run from inside a KOReader build.
local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
-- Device pulls settings in on the way up, and nothing has created the global
-- yet because there is no session here.
_G.G_reader_settings = _G.G_reader_settings
    or LuaSettings:open(DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
local Input = Device.input

local rows = {}
local function claim(name, checkable, ok, detail)
    if not checkable then
        rows[#rows + 1] = { "UNCHECKABLE", name, detail or "API absent in this runtime" }
    elseif ok then
        rows[#rows + 1] = { "OK", name, detail or "" }
    else
        rows[#rows + 1] = { "MISMATCH", name, detail or "" }
    end
end

local gd = Input.gesture_detector

claim("gesture_detector.feedEvent is a function on the instance",
    true, type(gd) == "table" and type(gd.feedEvent) == "function")

claim("GestureDetector exposes getContact and dropContact",
    true, type(gd) == "table"
      and type(gd.getContact) == "function"
      and type(gd.dropContact) == "function")

claim("Screen:getTouchRotation exists",
    true, type(Device.screen.getTouchRotation) == "function")

claim("Input exports the TOOL_TYPE_* constants",
    Input.TOOL_TYPE_PEN ~= nil,
    Input.TOOL_TYPE_FINGER == 0 and Input.TOOL_TYPE_PEN == 1
      and Input.TOOL_TYPE_ERASER == 2 and Input.TOOL_TYPE_HIGHLIGHTER == 3,
    "TOOL_TYPE_PEN = " .. tostring(Input.TOOL_TYPE_PEN))

claim("registerStylusCallback and unregisterStylusCallback exist",
    type(Input.registerStylusCallback) == "function",
    type(Input.unregisterStylusCallback) == "function")

claim("pen_slot is defined",
    Input.pen_slot ~= nil, true, "pen_slot = " .. tostring(Input.pen_slot))

-- The suite's SlotBus models ev_slots as durable tables handed out by
-- reference. If getMtSlot ever returned a fresh table the sticky-id tests would
-- all be proving nothing.
claim("getMtSlot hands out one persistent table per slot",
    type(Input.getMtSlot) == "function",
    type(Input.getMtSlot) == "function"
      and rawequal(Input:getMtSlot(0), Input:getMtSlot(0)))

claim("UIManager:sendEvent exists",
    true, type(require("ui/uimanager").sendEvent) == "function")

-- The whole widget-layer story depends on containers offering events to their
-- children before their own handler.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local order = {}
local Probe = WidgetContainer:extend{}
function Probe:onFingerInkProbe() order[#order + 1] = "parent" end
local probe = Probe:new{
    { handleEvent = function() order[#order + 1] = "child" end },
}
probe:handleEvent(require("ui/event"):new("FingerInkProbe"))
claim("WidgetContainer offers events to children before itself",
    true, order[1] == "child" and order[2] == "parent",
    table.concat(order, " then "))

-- =====================================================================
-- Viewport clipping, against a real BlitBuffer
--
-- The canvas paints live ink and repairs erased regions through
-- `BlitBuffer:viewport`, and the whole reason that is safe is that the buffer
-- bounds a write rather than trusting the caller's arithmetic. Clipping the
-- refresh rectangle alone would not stop the pixels. If this ever came back as
-- a MISMATCH, the canvas would be scribbling over the reader's text.
-- =====================================================================

do
    local BB = require("ffi/blitbuffer")
    local WHITE, BLACK = BB.COLOR_WHITE, BB.COLOR_BLACK
    local canvas = BB.new(100, 100, BB.TYPE_BB8)
    canvas:fill(WHITE)

    local view = canvas:viewport(20, 20, 30, 30)

    claim("BlitBuffer:viewport reports the size it was asked for",
        true, view:getWidth() == 30 and view:getHeight() == 30,
        view:getWidth() .. "x" .. view:getHeight())

    -- A write inside the viewport lands in the parent, offset.
    view:paintRect(0, 0, 5, 5, BLACK)
    claim("a write inside a viewport lands in the parent at the offset",
        true, canvas:getPixel(20, 20) == BLACK and canvas:getPixel(19, 19) == WHITE,
        "no separate buffer is allocated")

    -- A write that starts outside is clipped to the part that is inside.
    view:paintRect(-10, -10, 12, 12, BLACK)
    claim("a viewport clips a write that starts before its origin",
        true, canvas:getPixel(10, 10) == WHITE,
        "the part outside is dropped, not wrapped")

    -- A write wholly past the far edge is dropped entirely.
    view:paintRect(40, 40, 10, 10, BLACK)
    claim("a viewport drops a write wholly past its far edge",
        true, canvas:getPixel(60, 60) == WHITE and canvas:getPixel(99, 99) == WHITE)

    canvas:free()
end

-- =====================================================================
-- The canvas database, against real SQLite
--
-- tests/run.lua drives the repository through a recorder that executes
-- nothing, so this is the only place the schema is ever parsed, a constraint
-- ever fires, and a point blob makes a real round trip. A MISMATCH here means
-- the repository's SQL is wrong, not that a stub is.
-- =====================================================================

local sq3_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")

if not sq3_ok then
    claim("canvas database: SQLite driver is available", false, false,
        "lua-ljsqlite3 did not load")
else
    local Repository = require("ink_canvas_repository")
    local Codec = require("ink_canvas_codec")

    local db_path = os.tmpname() .. ".fingerink-conformance.sqlite3"
    os.remove(db_path)

    local repo, open_err = Repository.open{
        path = db_path,
        driver = SQ3,
        wal = false,   -- a temp file with no sidecars left behind
        now = function() return 1000 end,
    }

    claim("canvas database: the v1 schema is accepted by SQLite",
        true, repo ~= nil, tostring(open_err or db_path))

    if repo then
        local conn = repo.conn

        claim("canvas database: user_version is stamped at the schema version",
            true, tonumber(conn:rowexec("PRAGMA user_version;")) == Repository.SCHEMA_VERSION)

        claim("canvas database: foreign keys are actually enforced",
            true, tonumber(conn:rowexec("PRAGMA foreign_keys;")) == 1)

        -- The hazard the repository's `num` exists for. If this ever comes
        -- back as a Lua number the guard is merely harmless, not wrong.
        local raw = conn:rowexec("SELECT 1;")
        claim("canvas database: INTEGER columns arrive as int64 cdata, not numbers",
            true, type(raw) == "cdata", "type(raw) = " .. type(raw))

        local book_id = repo:bookId("conformance-md5", 4242, "/tmp/book.epub")
        claim("canvas database: a book row is created and its id is a Lua number",
            true, type(book_id) == "number", "book_id = " .. tostring(book_id))

        claim("canvas database: the same book resolves to the same row",
            true, repo:bookId("conformance-md5", 4242, "/tmp/moved.epub") == book_id)

        local canvas = repo:createCanvas(book_id, {
            anchor_kind = "xpointer",
            anchor_key = "xp:/body/DocFragment[3]/body/p[7]/text().0",
            anchor_raw = "/body/DocFragment[3]/body/p[7]/text().0",
            anchor_normalized = "/body/DocFragment[3]/body/p[7]/text().0",
            anchor_dom_version = 20240114,
            logical_w = 1860,
            logical_h = 2480,
        })
        claim("canvas database: a canvas row is created",
            true, canvas ~= nil and type(canvas.id) == "number")

        -- UNIQUE(book_id, anchor_key): the guard against a double tap making
        -- two canvases at one position.
        local dup = repo:createCanvas(book_id, {
            anchor_key = "xp:/body/DocFragment[3]/body/p[7]/text().0",
            logical_w = 1860, logical_h = 2480,
        })
        claim("canvas database: a duplicate anchor is rejected by the schema",
            true, dup == nil)

        claim("canvas database: anchor_kind is constrained",
            true, repo:createCanvas(book_id, {
                anchor_kind = "nonsense", anchor_key = "other",
                logical_w = 10, logical_h = 10 }) == nil)

        -- A stroke long enough to span chunks, with coordinates that exercise
        -- the whole quantiser range.
        local n = Codec.MAX_POINTS + 77
        local points = {}
        for i = 1, n do
            points[#points + 1] = (i * 7) % 1861
            points[#points + 1] = (i * 13) % 2481
        end
        local stroke_id = repo:addStroke(canvas,
            { seq = 1, width = 4, tool = 1, points = points, n = n })
        claim("canvas database: a multi-chunk stroke is written",
            true, type(stroke_id) == "number", "stroke_id = " .. tostring(stroke_id))

        local chunk_rows = tonumber(conn:rowexec(
            "SELECT count(*) FROM stroke_chunks WHERE stroke_id = " .. tostring(stroke_id)))
        claim("canvas database: it occupies the number of chunks the codec predicts",
            true, chunk_rows == Codec.chunkCount(n),
            tostring(chunk_rows) .. " vs " .. tostring(Codec.chunkCount(n)))

        -- The blob story: a Lua string binds as TEXT even into a BLOB column,
        -- and length() on a TEXT value stops at its first NUL. The CAST on the
        -- way in is what makes this a real blob.
        local kind = conn:rowexec(
            "SELECT typeof(points) FROM stroke_chunks WHERE stroke_id = "
            .. tostring(stroke_id) .. " AND chunk_no = 0")
        claim("canvas database: point payloads are stored as blobs, not as text",
            true, kind == "blob", "typeof = " .. tostring(kind))

        local blob_len = tonumber(conn:rowexec(
            "SELECT length(points) FROM stroke_chunks WHERE stroke_id = "
            .. tostring(stroke_id) .. " AND chunk_no = 0"))
        claim("canvas database: SQL sees the whole payload, not one byte of it",
            true, blob_len == Codec.HEADER + 4 * Codec.MAX_POINTS,
            "length = " .. tostring(blob_len))

        local back, back_n = repo:readStroke(canvas, { id = stroke_id, point_count = n })
        local worst = 0
        if back then
            for i = 1, n do
                local dx = math.abs(back[i * 2 - 1] - points[i * 2 - 1])
                local dy = math.abs(back[i * 2] - points[i * 2])
                if dx > worst then worst = dx end
                if dy > worst then worst = dy end
            end
        end
        claim("canvas database: every point survives the round trip through SQLite",
            true, back ~= nil and back_n == n and worst <= 2480 / 65535 / 2 + 1e-9,
            "n = " .. tostring(back_n) .. ", worst error = " .. tostring(worst))

        -- The layout cache, its composite foreign key, and the prune.
        repo:saveLayoutPages(book_id, "layout-a", { [canvas.id] = 41 })
        local pages = repo:layoutPages(book_id, "layout-a")
        claim("canvas database: a resolved page comes back keyed by canvas id",
            true, pages ~= nil and pages[canvas.id] == 41)

        repo.now = function() return 1001 end
        repo:saveLayoutPages(book_id, "layout-b", { [canvas.id] = 42 })
        repo.now = function() return 1002 end
        repo:saveLayoutPages(book_id, "layout-c", { [canvas.id] = 43 })
        local hashes = tonumber(conn:rowexec(
            "SELECT count(DISTINCT layout_hash) FROM canvas_layout_cache"))
        claim("canvas database: only the two most recent layouts are kept",
            true, hashes == 2, "distinct layouts = " .. tostring(hashes))

        -- Cascades. Deleting the canvas has to take its strokes, its chunks
        -- and its cached pages with it, through the composite key too.
        repo:deleteCanvas(canvas.id)
        local left = tonumber(conn:rowexec("SELECT count(*) FROM strokes"))
            + tonumber(conn:rowexec("SELECT count(*) FROM stroke_chunks"))
            + tonumber(conn:rowexec("SELECT count(*) FROM canvas_layout_cache"))
        claim("canvas database: deleting a canvas cascades to everything it owns",
            true, left == 0, "rows left behind = " .. tostring(left))

        -- PRAGMA user_version has to be transactional, or a rolled-back
        -- migration could leave a stamp claiming work that was undone.
        conn:exec("BEGIN;")
        conn:exec("PRAGMA user_version=999;")
        conn:exec("ROLLBACK;")
        claim("canvas database: a rolled-back version stamp does not stick",
            true, tonumber(conn:rowexec("PRAGMA user_version;")) == Repository.SCHEMA_VERSION,
            "user_version = " .. tostring(conn:rowexec("PRAGMA user_version;")))

        repo:close()
    end

    os.remove(db_path)
end

local bad = 0
for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-56s %s\n", r[1], r[2], r[3]))
    if r[1] == "MISMATCH" then bad = bad + 1 end
end
io.write(string.format("\n%d claims, %d mismatches\n", #rows, bad))
os.exit(bad == 0 and 0 or 1)
