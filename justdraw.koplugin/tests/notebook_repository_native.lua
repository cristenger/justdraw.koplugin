--[[--
The notebook repository's v3 schema against KOReader's real SQLite (Task 9.1).

The suite's SQL driver is scripted: it cannot say whether a migration really
runs, whether a created and a migrated library are the same database, whether
NOCASE orders what we think it orders, whether a cursor loses or repeats a row
on ties, or whether a query sorts in a temporary B-tree. This does.

    cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/notebook_repository_native.lua

Prints NOTEBOOK_REPOSITORY_NATIVE_OK and exits 0 when every check passes.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;" .. package.path
local Repository = require("ink_notebook_repository")
local Codec = require("ink_canvas_codec")
local SQ3 = require("lua-ljsqlite3/init")

local tmp = os.getenv("TMPDIR") or "/tmp"
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function path(name)
    local p = string.format("%s/jd-repo-native-%d-%s.sqlite3", tmp, os.time(), name)
    os.remove(p); os.remove(p .. "-journal")
    return p
end

local clock = 1000
local function now() return clock end

local function open(p, version)
    return assert(Repository.open{ path = p, driver = SQ3, now = now, schema_version = version })
end

local function columns(conn, table_name)
    local out = {}
    local stmt = conn:prepare("PRAGMA table_info(" .. table_name .. ");")
    while true do
        local row = stmt:step()
        if not row then break end
        out[#out + 1] = tostring(row[2]) .. ":" .. tostring(row[3]) .. ":" .. tostring(row[4])
            .. ":" .. tostring(row[5])
    end
    stmt:close()
    return table.concat(out, ",")
end

local function schemaOf(repo)
    local out = {}
    for _, t in ipairs({ "notebooks", "notebook_pages", "notebook_state", "notebook_strokes",
            "notebook_stroke_chunks", "notebook_folders", "library_meta" }) do
        out[#out + 1] = t .. "=" .. columns(repo.conn, t)
    end
    local stmt = repo.conn:prepare(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
    while true do
        local row = stmt:step()
        if not row then break end
        out[#out + 1] = "index=" .. tostring(row[1])
    end
    stmt:close()
    return table.concat(out, "\n")
end

local function stroke(page, n, seed)
    local pts = {}
    for i = 1, n do
        pts[#pts + 1] = (i * 7 + seed) % page.logical_w
        pts[#pts + 1] = (i * 13 + seed) % page.logical_h
    end
    return assert(RepositoryAdd(page, pts, n))
end

-- ------------------------------------------------------------ 1. schema

local fresh_path = path("fresh")
local fresh = open(fresh_path)
check(fresh.version == 3, "a new library is v3")
local uid = assert(fresh:dbUid())
check(#uid == 16, "a random 64-bit database identity")
check(tonumber(fresh.conn:rowexec("PRAGMA foreign_keys;")) == 1, "foreign keys are on")

-- A v2 library with content, then opened by this build.
local old_path = path("v2")
local v2 = open(old_path, 2)
check(v2.version == 2, "a v2 library can still be made for the test")
-- Written with v2-era SQL: this build's own writers already know v3 columns.
v2.conn:exec([[
INSERT INTO notebooks (id, title, page_count, next_sort_key, created_at, updated_at)
VALUES (1, 'Old', 1, 2048, 10, 10);
INSERT INTO notebook_pages (id, notebook_id, sort_key, logical_w, logical_h, template_kind,
    created_at, updated_at) VALUES (1, 1, 1024, 800, 1000, 'ruled', 10, 10);
INSERT INTO notebook_state (notebook_id, current_page_id) VALUES (1, 1);
INSERT INTO notebook_strokes (id, page_id, seq, width, tool, codec, point_count,
    min_x, min_y, max_x, max_y, created_at, paint_seq)
    VALUES (1, 1, 1, 4, 1, 1, 2, 10, 10, 20, 20, 10, 1);
]])
local enc = Codec.encode({ 10, 10, 20, 20 }, 2, 800, 1000)
local ins = v2.conn:prepare("INSERT INTO notebook_stroke_chunks (stroke_id, chunk_no, point_count, points) VALUES (1, 0, 2, CAST(?1 AS BLOB));")
ins:bind(enc[1].points); ins:step(); ins:close()
local nb, page = { id = 1 }, { id = 1 }
v2:close()
local migrated = open(old_path)
check(migrated.version == 3, "migrated to v3")
check(schemaOf(migrated) == schemaOf(fresh), "a created and a migrated library are the same schema:\n"
    .. schemaOf(migrated) .. "\n--\n" .. schemaOf(fresh))
local stmt = migrated.conn:prepare("PRAGMA foreign_key_check;")
check(stmt:step() == nil, "no foreign key violations after migrating")
stmt:close()
local old = assert(migrated:getNotebook(nb.id))
check(old.uid and #old.uid == 16, "an existing notebook got an identity")
check(old.folder_id == nil, "in the root")
local p = assert(migrated:getPage(page.id))
check(p.revision == 1, "existing pages start at revision 1")
local f = io.open(old_path .. ".backup-v2", "rb")
check(f ~= nil, "a backup of the v2 file was made before migrating")
if f then f:close() end
migrated:close()

-- ------------------------------------------------------------ 2. revisions

local repo = fresh
function RepositoryAdd(pg, pts, n) return repo:addStroke(pg, { points = pts, n = n, width = 4, tool = 1 }) end
local a, a_page = assert(repo:createNotebook{ title = "alpha", logical_w = 800, logical_h = 1000 })
check(a.uid and a.uid ~= uid, "notebooks have their own identity")
local rev0 = assert(repo:getPage(a_page.id)).revision
repo:transaction(function()
    stroke(a_page, 10, 2)
    return repo:touchSurface(a_page)
end)
check(assert(repo:getPage(a_page.id)).revision == rev0 + 1, "a committed edit bumps the revision")
repo:transaction(function() return repo:touchSurface(a_page) end)
check(assert(repo:getPage(a_page.id)).revision == rev0 + 2, "twice in the same second: two revisions")
assert(repo:setPageTemplate(a.id, a_page.id, "grid"))
check(assert(repo:getPage(a_page.id)).revision == rev0 + 3, "new paper is a new revision")
local tp = assert(repo:thumbnailPage(a.id))
check(tp.id == a_page.id, "the thumbnail shows the current page")

-- ------------------------------------------------------------ 3. folders

local work = assert(repo:createFolder("Work"))
local home = assert(repo:createFolder("home"))
check(repo:moveNotebook(a.id, work.id), "moved into a folder")
local folders = assert(repo:listFolders{})
check(#folders == 2 and folders[1].name == "home" and folders[2].name == "Work",
    "folders by name, ASCII case-insensitive")
check(folders[2].notebook_count == 1, "with their notebook counts")
check(select(2, repo:moveNotebook(a.id, 9999)) == "not_found", "a missing folder is refused")
assert(repo:renameFolder(home.id, "Home"))
assert(repo:deleteFolder(work.id))
check(assert(repo:getNotebook(a.id)).folder_id == nil, "deleting a folder returns its notebooks to the root")
check(#assert(repo:listFolders{}) == 1, "the deleted folder is gone")

-- ------------------------------------------------------------ 4. ordering

local titles = { "beta", "Beta", "alpha", "Émile", "zeta", "Zeta", "gamma" }
local made = { a.id }
for i, t in ipairs(titles) do
    clock = 2000 + (i % 3)            -- ties on updated_at
    local n = assert(repo:createNotebook{ title = t, logical_w = 800, logical_h = 1000,
        folder_id = (i % 2 == 0) and home.id or nil })
    made[#made + 1] = n.id
end
local function walk(scope, sort, folder_id)
    local seen, order, cursor = {}, {}, nil
    for _ = 1, 20 do
        local rows, next_cursor = assert(repo:listNotebookPage{ scope = scope, sort = sort,
            folder_id = folder_id, cursor = cursor, limit = 2 })
        for _, r in ipairs(rows) do
            check(not seen[r.id], sort .. ": no row twice across pages")
            seen[r.id] = true
            order[#order + 1] = r
        end
        if not next_cursor then break end
        cursor = next_cursor
    end
    return order
end
for _, sort in ipairs({ "recent", "oldest", "title_asc", "title_desc" }) do
    local all = walk("all", sort)
    check(#all == #made, sort .. ": every notebook once (" .. #all .. ")")
    for i = 2, #all do
        local x, y = all[i - 1], all[i]
        local ok
        if sort == "recent" then ok = x.updated_at > y.updated_at or (x.updated_at == y.updated_at and x.id > y.id)
        elseif sort == "oldest" then ok = x.updated_at < y.updated_at or (x.updated_at == y.updated_at and x.id < y.id)
        else
            local ax, ay = x.title:lower(), y.title:lower()
            if sort == "title_asc" then ok = ax < ay or (ax == ay and x.id < y.id)
            else ok = ax > ay or (ax == ay and x.id > y.id) end
        end
        check(ok, sort .. ": ordered at " .. i)
    end
    local root = walk("root", sort)
    local inside = walk("folder", sort, home.id)
    check(#root + #inside == #made, sort .. ": root and folder partition the library")
end
local _, c = repo:listNotebookPage{ scope = "all", sort = "recent", limit = 2 }
local rows, err = repo:listNotebookPage{ scope = "root", sort = "recent", cursor = c, limit = 2 }
check(rows == nil and err == "bad_cursor", "a cursor from another scope is refused")
rows, err = repo:listNotebookPage{ scope = "all", sort = "oldest", cursor = c, limit = 2 }
check(rows == nil and err == "bad_cursor", "a cursor from another sort is refused")

-- Query plans: KOReader's SQLite build returns no rows for EXPLAIN QUERY PLAN
-- through lua-ljsqlite3, so the plans are checked by
-- tests/notebook_query_plans.py against the file this script leaves behind
-- (JUSTDRAW_KEEP_DB=1 keeps it and prints its path).

-- ------------------------------------------------------------ 5. copies

local src, src_page = assert(repo:createNotebook{ title = "Source", logical_w = 800, logical_h = 1000 })
local second = assert(repo:appendPage(src.id, { logical_w = 800, logical_h = 1000, template_kind = "ruled" }))
function RepositoryAdd(pg, pts, n) return repo:addStroke(pg, { points = pts, n = n, width = 3, tool = 67 }) end
for i = 1, 5 do stroke(src_page, 300 + i * 500, i) end   -- multi-chunk strokes
for i = 1, 3 do stroke(second, 20, i) end
assert(repo:selectCurrentPage(src.id, second.id))
local listed_before = #walk("all", "recent")
local state = assert(repo:beginCopy(src.id))
check(repo:getNotebook(state.dest_id) == nil, "a copy in progress is invisible")
check(#walk("all", "recent") == listed_before, "and not listed")
local turns = 0
while true do
    local done = repo:copyBatch(state, { strokes = 2, chunks = 3 })
    check(done ~= nil, "a copy batch succeeded")
    turns = turns + 1
    if done then break end
    check(turns < 100, "copying terminates")
end
check(turns >= 3, "the copy took several bounded turns (" .. turns .. ")")
local dest = assert(repo:finishCopy(state))
local copy = assert(repo:getNotebook(dest))
check(copy.title == "Source (copy)", "titled as a copy")
check(copy.page_count == 2, "same page count")
local copied_current = assert(repo:getPage(copy.current_page_id))
check(copied_current.sort_key == second.sort_key and copied_current.template_kind == "ruled",
    "the copy opens on the same page, same paper")
local function blobs(notebook_id)
    local out = {}
    local st = repo.conn:prepare([[
        SELECT p.sort_key, s.seq, s.paint_seq, s.codec, s.tool, c.chunk_no, CAST(c.points AS TEXT)
          FROM notebook_strokes s JOIN notebook_pages p ON p.id = s.page_id
          JOIN notebook_stroke_chunks c ON c.stroke_id = s.id
         WHERE p.notebook_id = ?1 ORDER BY p.sort_key, s.seq, c.chunk_no;]])
    st:bind(notebook_id)
    while true do
        local row = st:step()
        if not row then break end
        out[#out + 1] = table.concat({ tostring(row[1]), tostring(row[2]), tostring(row[3]),
            tostring(row[4]), tostring(row[5]), tostring(row[6]), tostring(row[7]) }, "|")
    end
    st:close()
    return table.concat(out, "\n")
end
check(blobs(dest) == blobs(src.id), "every chunk copied byte for byte, with seq, paint order and codec")

-- An edit during the copy stops it; cancelling leaves nothing visible and
-- the purge removes it in batches.
local st2 = assert(repo:beginCopy(src.id))
assert(repo:copyBatch(st2, { strokes = 1 }) ~= nil)
repo:transaction(function() return repo:touchSurface(src_page) end)
local r2, e2 = repo:copyBatch(st2, { strokes = 1 })
check(r2 == nil and e2 == "source_changed", "an edited source stops the copy")
assert(repo:cancelCopy(st2))
local sweeps = 0
while true do
    local done = assert(repo:purgeAbandonedCopies{ chunks = 2 } ~= nil and true)
    sweeps = sweeps + 1
    local left = tonumber(repo.conn:rowexec("SELECT COUNT(*) FROM notebooks WHERE id = " .. st2.dest_id .. ";"))
    if left == 0 then break end
    check(sweeps < 200, "the purge terminates")
end
check(sweeps > 1, "the purge worked in batches")
-- Another process's abandoned copy is swept; this process's own is not.
local mine = assert(repo:beginCopy(src.id))
repo.conn:exec("UPDATE notebooks SET copy_state = 'copying:someone-else' WHERE id = " .. mine.dest_id .. ";")
local ours = assert(repo:beginCopy(src.id))
for _ = 1, 50 do if repo:purgeAbandonedCopies{} == true then break end end
check(tonumber(repo.conn:rowexec("SELECT COUNT(*) FROM notebooks WHERE id = " .. mine.dest_id .. ";")) == 0,
    "an abandoned copy from another process is swept")
check(tonumber(repo.conn:rowexec("SELECT COUNT(*) FROM notebooks WHERE id = " .. ours.dest_id .. ";")) == 1,
    "a copy this process is still writing is never swept")

repo:close()
if os.getenv("JUSTDRAW_KEEP_DB") == "1" then print("DB " .. fresh_path) end
print("NOTEBOOK_REPOSITORY_NATIVE_OK checks=" .. checks)
os.exit(0)
