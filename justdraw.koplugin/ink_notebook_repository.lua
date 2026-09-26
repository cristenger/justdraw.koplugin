--[[--
Persistence for standalone notebooks.

This database is deliberately separate from justdraw.sqlite3: canvases are
identified by books and anchors, notebook pages are not.  The implementation
mirrors the canvas repository's proven SQLite boundaries (numeric conversion,
BLOB casts, transactional migrations and future-schema read-only mode) without
coupling either schema to the other.
]]

local logger = require("logger")
local Codec = require("ink_canvas_codec")

local unpack = unpack or table.unpack

local Repository = {}
Repository.__index = Repository

Repository.SCHEMA_VERSION = 3
--- `SCHEMA` below describes this version; a new database replays every later
--- migration on top of it, so a created and a migrated library are the same
--- database by construction, not by a second hand-written copy.
Repository.BASE_SCHEMA_VERSION = 2
Repository.MIGRATIONS = {}
Repository.SORT_STEP = 1024
Repository.DEFAULT_LIMIT = 50
Repository.MAX_LIMIT = 200

Repository.SCHEMA = [[
CREATE TABLE notebooks (
    id             INTEGER PRIMARY KEY,
    title          TEXT    NOT NULL,
    page_count     INTEGER NOT NULL DEFAULT 0 CHECK(page_count >= 0),
    next_sort_key  INTEGER NOT NULL DEFAULT 1024 CHECK(next_sort_key > 0),
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    deleted_at     INTEGER
);
CREATE TABLE notebook_pages (
    id             INTEGER PRIMARY KEY,
    notebook_id    INTEGER NOT NULL REFERENCES notebooks(id),
    sort_key       INTEGER NOT NULL,
    logical_w      INTEGER NOT NULL CHECK(logical_w > 0),
    logical_h      INTEGER NOT NULL CHECK(logical_h > 0),
    template_kind  TEXT    NOT NULL DEFAULT 'blank',
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    deleted_at     INTEGER,
    UNIQUE(notebook_id, sort_key),
    UNIQUE(id, notebook_id)
);
CREATE TABLE notebook_state (
    notebook_id     INTEGER PRIMARY KEY REFERENCES notebooks(id),
    current_page_id INTEGER NOT NULL,
    FOREIGN KEY(current_page_id, notebook_id)
        REFERENCES notebook_pages(id, notebook_id)
);
CREATE TABLE notebook_strokes (
    id           INTEGER PRIMARY KEY,
    page_id      INTEGER NOT NULL REFERENCES notebook_pages(id),
    seq          INTEGER NOT NULL,
    width        REAL    NOT NULL,
    tool         INTEGER NOT NULL,
    codec        INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    min_x        REAL    NOT NULL,
    min_y        REAL    NOT NULL,
    max_x        REAL    NOT NULL,
    max_y        REAL    NOT NULL,
    created_at   INTEGER NOT NULL,
    deleted_at   INTEGER,
    paint_seq    INTEGER,
    UNIQUE(page_id, seq)
);
CREATE TABLE notebook_stroke_chunks (
    stroke_id    INTEGER NOT NULL REFERENCES notebook_strokes(id),
    chunk_no     INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    points       BLOB    NOT NULL,
    PRIMARY KEY(stroke_id, chunk_no)
);
CREATE INDEX notebooks_active_recent
    ON notebooks(deleted_at, updated_at DESC, id DESC);
CREATE INDEX pages_by_notebook
    ON notebook_pages(notebook_id, deleted_at, sort_key, id);
CREATE INDEX pages_deleted
    ON notebook_pages(deleted_at, id);
CREATE INDEX state_by_current_page
    ON notebook_state(current_page_id);
CREATE INDEX strokes_by_page
    ON notebook_strokes(page_id, deleted_at, seq);
CREATE INDEX strokes_deleted
    ON notebook_strokes(deleted_at, id);
]]

Repository.MIGRATIONS[1] = function(conn)
    conn:exec("ALTER TABLE notebook_strokes ADD COLUMN paint_seq INTEGER;")
end

--[[--
v3: the gallery (ADR-58).

* `library_meta.db_uid` and `notebooks.uid`: random identities for caches.
  Row ids are not identities -- `INTEGER PRIMARY KEY` hands a purged
  notebook's id to the next one -- and a thumbnail keyed by row id would show
  the dead notebook's page on the new one.
* `notebook_folders` and `notebooks.folder_id`: one level of folders, deleted
  logically; a deleted folder's notebooks go back to the root.
* `notebook_pages.revision`: bumped in the same transaction as every content
  or paper change, so a thumbnail can tell "changed" from "same second".
* `notebooks.copy_state`, `copy_source`: a duplicate is written in batches and
  stays invisible to every public query until it is complete.
]]
Repository.MIGRATIONS[2] = function(conn)
    conn:exec([[
CREATE TABLE library_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO library_meta (key, value) VALUES ('db_uid', lower(hex(randomblob(8))));
CREATE TABLE notebook_folders (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    deleted_at  INTEGER
);
ALTER TABLE notebooks ADD COLUMN folder_id INTEGER REFERENCES notebook_folders(id);
ALTER TABLE notebooks ADD COLUMN uid TEXT;
ALTER TABLE notebooks ADD COLUMN copy_state TEXT;
ALTER TABLE notebooks ADD COLUMN copy_source INTEGER;
ALTER TABLE notebook_pages ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
UPDATE notebooks SET uid = lower(hex(randomblob(8))) WHERE uid IS NULL;
UPDATE notebook_pages SET revision = 1;
CREATE INDEX notebooks_scope_recent
    ON notebooks(deleted_at, copy_state, folder_id, updated_at, id);
CREATE INDEX notebooks_scope_title
    ON notebooks(deleted_at, copy_state, folder_id, title COLLATE NOCASE, id);
CREATE INDEX notebooks_all_title
    ON notebooks(deleted_at, copy_state, title COLLATE NOCASE, id);
CREATE INDEX folders_active
    ON notebook_folders(deleted_at, name COLLATE NOCASE, id);
]])
end

--- Process-lifetime token for copies in progress: a copy marked by another
--- process is an abandoned one, and only those are ever swept (ADR-58).
local PROCESS_TOKEN = string.format("%x-%s", os.time(),
    tostring({}):match("(%x+)$") or tostring(math.floor(os.clock() * 1e6)))
Repository.PROCESS_TOKEN = PROCESS_TOKEN

local function num(v)
    if v == nil then return nil end
    return tonumber(v)
end

local function str(v)
    if v == nil then return nil end
    return tostring(v)
end

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function positiveInteger(v)
    v = tonumber(v)
    if not finite(v) or v <= 0 or v ~= math.floor(v) then return nil end
    return v
end

local function validTitle(value)
    if type(value) ~= "string" then return nil end
    local title = value:match("^%s*(.-)%s*$")
    if title == "" or #title > 255 then return nil end
    return title
end

local KNOWN_TEMPLATES = {
    blank = true, ruled = true, ruled_narrow = true, grid = true, dots = true,
    checklist = true,
}
local function storedTemplate(value)
    if type(value) ~= "string" or value == "" or #value > 64 then return "blank" end
    return value
end
local function visibleTemplate(value)
    value = str(value) or "blank"
    return KNOWN_TEMPLATES[value] and value or "blank"
end
--- Published so the renderer can be checked against it: a kind that persists
--- but cannot be drawn is a page that silently comes back blank, and the two
--- lists live in different modules for different reasons (ADR-27).
Repository.KNOWN_TEMPLATES = KNOWN_TEMPLATES

local function copyFile(src, dest)
    local fi = io.open(src, "rb")
    if not fi then return nil, "cannot read " .. tostring(src) end
    local fo = io.open(dest, "wb")
    if not fo then fi:close(); return nil, "cannot write " .. tostring(dest) end
    while true do
        local block = fi:read(64 * 1024)
        if not block or block == "" then break end
        if not fo:write(block) then
            fi:close(); fo:close(); return nil, "write failed"
        end
    end
    fi:close()
    if not fo:close() then return nil, "close failed" end
    return true
end

function Repository.open(opts)
    opts = opts or {}
    local driver = opts.driver
    if driver == nil then
        local ok, module = pcall(require, "lua-ljsqlite3/init")
        driver = ok and module or nil
    end
    if type(driver) ~= "table" or type(driver.open) ~= "function" then
        return nil, "no_driver"
    end
    local self = setmetatable({
        path = opts.path,
        driver = driver,
        wal = opts.wal and true or false,
        now = opts.now or os.time,
        backup = opts.backup or copyFile,
        target = opts.schema_version or Repository.SCHEMA_VERSION,
        migrations = opts.migrations or Repository.MIGRATIONS,
        read_only = false,
        depth = 0,
    }, Repository)
    local conn, open_err = self:_connect("rwc")
    if not conn then return nil, open_err end
    local ok, version = pcall(function()
        return num(conn:rowexec("PRAGMA user_version;")) or 0
    end)
    if not ok then self:_disconnect(); return nil, "open_failed" end

    if version == 0 then
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        local created, create_err = self:_createSchema()
        if not created then self:_disconnect(); return nil, create_err end
    elseif version > self.target then
        self:_disconnect()
        local readonly, ro_err = self:_connect("ro")
        if not readonly then return nil, ro_err end
        self.read_only = true
        self.read_only_reason = "notebook database is newer than this plugin"
        self.version = version
    elseif version < self.target then
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        local migrated, migrate_err = self:_migrate(version)
        if not migrated then self:_disconnect(); return nil, migrate_err end
    else
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        self.version = version
    end
    return self
end

function Repository:_connect(mode)
    local ok, conn = pcall(self.driver.open, self.path, mode or "rwc")
    if not ok or not conn then return nil, "open_failed" end
    self.conn = conn
    local configured = pcall(conn.exec, conn, "PRAGMA foreign_keys=ON;")
    if not configured then self:_disconnect(); return nil, "open_failed" end
    return conn
end

function Repository:_configureWritable()
    local ok = pcall(self.conn.exec, self.conn,
        self.wal and "PRAGMA journal_mode=WAL;" or "PRAGMA journal_mode=TRUNCATE;")
    if not ok then return nil, "open_failed" end
    return true
end

function Repository:_disconnect()
    if self.conn then pcall(self.conn.close, self.conn) end
    self.conn = nil
end

function Repository:_createSchema()
    local partial, partial_err = self:_select([[
        SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%';]], nil,
        function(row) return str(row[1]) end)
    if not partial then return nil, partial_err end
    if #partial > 0 then return nil, "schema_failed" end
    local began = false
    local ok = pcall(function()
        self.conn:exec("BEGIN;")
        began = true
        self.conn:exec(Repository.SCHEMA)
        for version = Repository.BASE_SCHEMA_VERSION, self.target - 1 do
            self.migrations[version](self.conn)
        end
        self.conn:exec(string.format("PRAGMA user_version=%d;", self.target))
        self.conn:exec("COMMIT;")
    end)
    if not ok then
        if began then pcall(self.conn.exec, self.conn, "ROLLBACK;") end
        return nil, "schema_failed"
    end
    self.version = self.target
    return true
end

function Repository:_migrate(from)
    for version = from, self.target - 1 do
        if type(self.migrations[version]) ~= "function" then
            return nil, "migration_missing"
        end
    end
    if self.wal then
        local ok, busy, frames, done = pcall(
            self.conn.rowexec, self.conn, "PRAGMA wal_checkpoint(TRUNCATE);")
        busy, frames, done = tonumber(busy), tonumber(frames), tonumber(done)
        if not ok or busy == nil or frames == nil or done == nil or busy ~= 0
            or not ((frames == -1 and done == -1) or frames == done) then
            return nil, "migration_checkpoint_failed"
        end
    end
    self:_disconnect()
    local copied = self.backup(self.path,
        tostring(self.path) .. ".backup-v" .. tostring(from))
    if not copied then return nil, "backup_failed" end
    local conn, open_err = self:_connect("rwc")
    if not conn then return nil, open_err end
    local configured, config_err = self:_configureWritable()
    if not configured then return nil, config_err end
    -- `foreign_keys` is per connection and cannot change inside a
    -- transaction; `_connect` turned it on, and a connection that did not take
    -- it would migrate without the checks the new columns rely on.
    local fk_ok, fk = pcall(conn.rowexec, conn, "PRAGMA foreign_keys;")
    if fk_ok and fk ~= nil and tonumber(fk) == 0 then return nil, "migration_failed" end
    local violations = {}
    local ok = pcall(function()
        conn:exec("BEGIN;")
        for version = from, self.target - 1 do self.migrations[version](conn) end
        local stmt = conn:prepare("PRAGMA foreign_key_check;")
        local row = stmt:step()
        if row then violations[1] = row end
        pcall(stmt.close, stmt)
        if #violations > 0 then error("foreign key violation", 0) end
        conn:exec(string.format("PRAGMA user_version=%d;", self.target))
        conn:exec("COMMIT;")
    end)
    if not ok then
        pcall(conn.exec, conn, "ROLLBACK;")
        return nil, "migration_failed"
    end
    self.version = self.target
    return true
end

function Repository:close()
    self:_disconnect()
end

function Repository:_ready(write)
    if not self.conn then return nil, "closed" end
    if write and self.read_only then return nil, "read_only" end
    return true
end

function Repository:_select(sql, binds, map)
    local ok, result = pcall(function()
        local stmt = self.conn:prepare(sql)
        local rows = {}
        local stepped, step_err = pcall(function()
            if binds then stmt:bind(unpack(binds)) end
            while true do
                local row = stmt:step()
                if not row then break end
                rows[#rows + 1] = map(row)
            end
        end)
        pcall(stmt.close, stmt)
        if not stepped then error(step_err, 0) end
        return rows
    end)
    if not ok then
        logger.err("JustDraw: notebook query failed:", result)
        return nil, tostring(result)
    end
    return result
end

function Repository:_run(sql, binds)
    local ok, err = pcall(function()
        local stmt = self.conn:prepare(sql)
        local stepped, step_err = pcall(function()
            if binds then stmt:bind(unpack(binds)) end
            stmt:step()
        end)
        pcall(stmt.close, stmt)
        if not stepped then error(step_err, 0) end
    end)
    if not ok then return nil, tostring(err) end
    return true
end

function Repository:_lastId()
    local ok, id = pcall(self.conn.rowexec, self.conn, "SELECT last_insert_rowid();")
    if not ok then return nil, tostring(id) end
    return num(id)
end

function Repository:_changes()
    local ok, count = pcall(self.conn.rowexec, self.conn, "SELECT changes();")
    if not ok then return nil, tostring(count) end
    return num(count) or 0
end

function Repository:transaction(fn)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if self.depth > 0 then
        local ok, value, err = pcall(fn, self)
        if not ok then return nil, value end
        if value == nil then return nil, err end
        return value
    end
    local began, begin_err = pcall(self.conn.exec, self.conn, "BEGIN;")
    if not began then return nil, tostring(begin_err) end
    self.depth = 1
    local ok, value, err = pcall(fn, self)
    self.depth = 0
    if not ok or value == nil then
        pcall(self.conn.exec, self.conn, "ROLLBACK;")
        return nil, ok and err or value
    end
    local committed, commit_err = pcall(self.conn.exec, self.conn, "COMMIT;")
    if not committed then
        pcall(self.conn.exec, self.conn, "ROLLBACK;")
        return nil, tostring(commit_err)
    end
    return value
end

local function notebookRow(row)
    return {
        id = num(row[1]),
        title = str(row[2]),
        page_count = num(row[3]),
        next_sort_key = num(row[4]),
        created_at = num(row[5]),
        updated_at = num(row[6]),
        deleted_at = num(row[7]),
        current_page_id = num(row[8]),
        folder_id = num(row[9]),
        uid = str(row[10]),
        copy_state = str(row[11]),
    }
end

local function pageRow(row)
    return {
        id = num(row[1]),
        notebook_id = num(row[2]),
        sort_key = num(row[3]),
        logical_w = num(row[4]),
        logical_h = num(row[5]),
        template_kind = visibleTemplate(row[6]),
        created_at = num(row[7]),
        updated_at = num(row[8]),
        deleted_at = num(row[9]),
        revision = num(row[10]) or 0,
    }
end

local function boundedLimit(value)
    value = positiveInteger(value) or Repository.DEFAULT_LIMIT
    if value > Repository.MAX_LIMIT then value = Repository.MAX_LIMIT end
    return value
end

function Repository:listNotebooks(opts)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    opts = opts or {}
    local limit = boundedLimit(opts.limit)
    local after_time, after_id = tonumber(opts.after_updated_at), tonumber(opts.after_id)
    if after_time ~= nil and (not finite(after_time) or not positiveInteger(after_id)) then
        return nil, "bad_cursor"
    end
    if after_time == nil then
        return self:_select([[
            SELECT id, title, page_count, next_sort_key,
                   created_at, updated_at, deleted_at, NULL, folder_id, uid, copy_state
              FROM notebooks
             WHERE deleted_at IS NULL AND copy_state IS NULL
             ORDER BY updated_at DESC, id DESC LIMIT ?1;]],
            { limit }, notebookRow)
    end
    return self:_select([[
        SELECT id, title, page_count, next_sort_key,
               created_at, updated_at, deleted_at, NULL, folder_id, uid, copy_state
          FROM notebooks
         WHERE deleted_at IS NULL AND copy_state IS NULL
           AND (updated_at < ?1 OR (updated_at = ?1 AND id < ?2))
         ORDER BY updated_at DESC, id DESC LIMIT ?3;]],
        { after_time, after_id, limit }, notebookRow)
end

function Repository:getNotebook(id, include_deleted)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    -- Deleted and incomplete (copying) notebooks are invisible unless the
    -- caller is the purge or the copy job that owns them.
    local deleted = include_deleted and "" or " AND n.deleted_at IS NULL AND n.copy_state IS NULL"
    local rows, err = self:_select([[
        SELECT n.id, n.title, n.page_count, n.next_sort_key,
               n.created_at, n.updated_at, n.deleted_at, s.current_page_id,
               n.folder_id, n.uid, n.copy_state
          FROM notebooks n LEFT JOIN notebook_state s ON s.notebook_id = n.id
         WHERE n.id = ?1]] .. deleted .. ";", { id }, notebookRow)
    if not rows then return nil, err end
    if not rows[1] then return nil, "not_found" end
    return rows[1]
end

function Repository:createNotebook(spec)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    spec = spec or {}
    local title = validTitle(spec.title)
    local w, h = positiveInteger(spec.logical_w), positiveInteger(spec.logical_h)
    if not title then return nil, "bad_title" end
    if not w or not h then return nil, "bad_geometry" end
    local template = storedTemplate(spec.template_kind)
    local notebook, page
    local result, err = self:transaction(function()
        local now = self.now()
        local ok, insert_err = self:_run([[
            INSERT INTO notebooks
                (title, page_count, next_sort_key, created_at, updated_at, deleted_at,
                 uid, folder_id)
            VALUES (?1, 0, ?2, ?3, ?3, NULL, lower(hex(randomblob(8))), ?4);]],
            { title, Repository.SORT_STEP, now, positiveInteger(spec.folder_id) })
        if not ok then return nil, insert_err end
        local notebook_id, id_err = self:_lastId()
        if not notebook_id then return nil, id_err end
        ok, insert_err = self:_run([[
            INSERT INTO notebook_pages
                (notebook_id, sort_key, logical_w, logical_h, template_kind,
                 created_at, updated_at, deleted_at, revision)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL, 1);]],
            { notebook_id, Repository.SORT_STEP, w, h, template, now })
        if not ok then return nil, insert_err end
        local page_id, page_err = self:_lastId()
        if not page_id then return nil, page_err end
        ok, insert_err = self:_run([[
            UPDATE notebooks SET page_count = 1, next_sort_key = ?2
             WHERE id = ?1;]],
            { notebook_id, Repository.SORT_STEP * 2 })
        if not ok then return nil, insert_err end
        ok, insert_err = self:_run([[
            INSERT INTO notebook_state (notebook_id, current_page_id)
            VALUES (?1, ?2);]], { notebook_id, page_id })
        if not ok then return nil, insert_err end
        local uids = self:_select("SELECT uid FROM notebooks WHERE id = ?1;",
            { notebook_id }, function(row) return str(row[1]) end)
        notebook = {
            id = notebook_id, title = title, page_count = 1,
            next_sort_key = Repository.SORT_STEP * 2,
            created_at = now, updated_at = now, current_page_id = page_id,
            folder_id = positiveInteger(spec.folder_id), uid = uids and uids[1],
        }
        page = {
            id = page_id, notebook_id = notebook_id,
            sort_key = Repository.SORT_STEP, logical_w = w, logical_h = h,
            template_kind = visibleTemplate(template), created_at = now, updated_at = now,
        }
        return true
    end)
    if not result then return nil, err end
    return notebook, page
end

function Repository:renameNotebook(id, title)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    id, title = positiveInteger(id), validTitle(title)
    if not id then return nil, "bad_id" end
    if not title then return nil, "bad_title" end
    local ok, err = self:_run([[
        UPDATE notebooks SET title = ?2, updated_at = ?3
         WHERE id = ?1 AND deleted_at IS NULL;]], { id, title, self.now() })
    if not ok then return nil, err end
    local changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    return true
end

function Repository:softDeleteNotebook(id)
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    return self:transaction(function()
        local notebook, err = self:getNotebook(id)
        if not notebook then return nil, err end
        local ok, run_err = self:_run(
            "DELETE FROM notebook_state WHERE notebook_id = ?1;", { id })
        if not ok then return nil, run_err end
        return self:_run([[
            UPDATE notebooks SET deleted_at = ?2, updated_at = ?2
             WHERE id = ?1 AND deleted_at IS NULL;]], { id, self.now() })
    end)
end

function Repository:listPages(notebook_id, opts)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    notebook_id = positiveInteger(notebook_id)
    if not notebook_id then return nil, "bad_id" end
    opts = opts or {}
    local limit = boundedLimit(opts.limit)
    local after_key, after_id = tonumber(opts.after_sort_key), tonumber(opts.after_id)
    if after_key ~= nil and (not finite(after_key) or not positiveInteger(after_id)) then
        return nil, "bad_cursor"
    end
    if after_key == nil then
        return self:_select([[
            SELECT id, notebook_id, sort_key, logical_w, logical_h,
                   template_kind, created_at, updated_at, deleted_at, revision
              FROM notebook_pages
             WHERE notebook_id = ?1 AND deleted_at IS NULL
             ORDER BY sort_key, id LIMIT ?2;]],
            { notebook_id, limit }, pageRow)
    end
    return self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at, revision
          FROM notebook_pages
         WHERE notebook_id = ?1 AND deleted_at IS NULL
           AND (sort_key > ?2 OR (sort_key = ?2 AND id > ?3))
         ORDER BY sort_key, id LIMIT ?4;]],
        { notebook_id, after_key, after_id, limit }, pageRow)
end

-- Ordinals follow the same active-page ordering as listPages, not row ids.
-- Called at page boundaries only: COUNT/OFFSET may scan page metadata.
function Repository:pagePosition(page)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local id = page and positiveInteger(page.id)
    local notebook_id = page and positiveInteger(page.notebook_id)
    local key = page and positiveInteger(page.sort_key)
    if not id or not notebook_id or not key then return nil, "bad_id" end
    local rows, err = self:_select([[
        SELECT COUNT(*) FROM notebook_pages
         WHERE notebook_id = ?1 AND deleted_at IS NULL
           AND (sort_key < ?2 OR (sort_key = ?2 AND id <= ?3));]],
        { notebook_id, key, id }, function(row) return num(row[1]) end)
    if not rows then return nil, err end
    if not rows[1] or rows[1] == 0 then return nil, "not_found" end
    return rows[1]
end

function Repository:pageAtPosition(notebook_id, position)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    notebook_id = positiveInteger(notebook_id)
    position = positiveInteger(position)
    if not notebook_id then return nil, "bad_id" end
    if not position or position > 9007199254740991 then return nil, "bad_position" end
    local rows, err = self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at, revision
          FROM notebook_pages
         WHERE notebook_id = ?1 AND deleted_at IS NULL
         ORDER BY sort_key, id LIMIT 1 OFFSET ?2;]],
        { notebook_id, position - 1 }, pageRow)
    if not rows then return nil, err end
    if not rows[1] then return nil, "not_found" end
    return rows[1]
end

function Repository:getPage(id, include_deleted)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    local deleted = include_deleted and "" or " AND deleted_at IS NULL"
    local rows, err = self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at, revision
          FROM notebook_pages WHERE id = ?1]] .. deleted .. ";", { id }, pageRow)
    if not rows then return nil, err end
    if not rows[1] then return nil, "not_found" end
    return rows[1]
end

function Repository:appendPage(notebook_id, spec)
    notebook_id = positiveInteger(notebook_id)
    spec = spec or {}
    local w, h = positiveInteger(spec.logical_w), positiveInteger(spec.logical_h)
    if not notebook_id then return nil, "bad_id" end
    if not w or not h then return nil, "bad_geometry" end
    local template = storedTemplate(spec.template_kind)
    local page
    local ok, err = self:transaction(function()
        local notebook, notebook_err = self:getNotebook(notebook_id)
        if not notebook then return nil, notebook_err end
        local key = positiveInteger(notebook.next_sort_key)
        if not key or key > 9007199254740000 - Repository.SORT_STEP then
            return nil, "sort_exhausted"
        end
        local now = self.now()
        local inserted, insert_err = self:_run([[
            INSERT INTO notebook_pages
                (notebook_id, sort_key, logical_w, logical_h, template_kind,
                 created_at, updated_at, deleted_at, revision)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL, 1);]],
            { notebook_id, key, w, h, template, now })
        if not inserted then return nil, insert_err end
        local page_id, id_err = self:_lastId()
        if not page_id then return nil, id_err end
        inserted, insert_err = self:_run([[
            UPDATE notebooks
               SET page_count = page_count + 1,
                   next_sort_key = ?2, updated_at = ?3
             WHERE id = ?1 AND deleted_at IS NULL;]],
            { notebook_id, key + Repository.SORT_STEP, now })
        if not inserted then return nil, insert_err end
        page = {
            id = page_id, notebook_id = notebook_id, sort_key = key,
            logical_w = w, logical_h = h,
            template_kind = visibleTemplate(template), created_at = now, updated_at = now,
        }
        return true
    end)
    if not ok then return nil, err end
    return page
end

--[[--
Change one page's ruling.

Deliberately stricter than `storedTemplate`. Creation stays permissive so that
a notebook written by a newer build keeps its own template name intact when an
older one touches it; but a value this build is about to *rule paper with* has
to be one this build can draw, or the write would succeed, the page would come
back blank, and nothing would have said so.

The notebook's activity date moves with the page's, the way `touchSurface`
moves it for ink: changing the paper is an edit, and the library orders by
recent activity.
]]
function Repository:setPageTemplate(notebook_id, page_id, kind)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    notebook_id, page_id = positiveInteger(notebook_id), positiveInteger(page_id)
    if not notebook_id or not page_id then return nil, "bad_id" end
    if type(kind) ~= "string" or not KNOWN_TEMPLATES[kind] then
        return nil, "bad_template"
    end
    return self:transaction(function()
        local now = self.now()
        local ok, run_err = self:_run([[
            UPDATE notebook_pages SET template_kind = ?3, updated_at = ?4,
                   revision = revision + 1
             WHERE id = ?1 AND notebook_id = ?2 AND deleted_at IS NULL;]],
            { page_id, notebook_id, kind, now })
        if not ok then return nil, run_err end
        local changed, change_err = self:_changes()
        if changed == nil then return nil, change_err end
        if changed == 0 then return nil, "not_found" end
        ok, run_err = self:_run([[
            UPDATE notebooks SET updated_at = ?2
             WHERE id = ?1 AND deleted_at IS NULL;]], { notebook_id, now })
        if not ok then return nil, run_err end
        changed, change_err = self:_changes()
        if changed == nil then return nil, change_err end
        if changed == 0 then return nil, "not_found" end
        return true
    end)
end

function Repository:selectCurrentPage(notebook_id, page_id)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    notebook_id, page_id = positiveInteger(notebook_id), positiveInteger(page_id)
    if not notebook_id or not page_id then return nil, "bad_id" end
    local rows, err = self:_select([[
        SELECT id FROM notebook_pages
         WHERE id = ?1 AND notebook_id = ?2 AND deleted_at IS NULL;]],
        { page_id, notebook_id }, function(row) return num(row[1]) end)
    if not rows then return nil, err end
    if not rows[1] then return nil, "not_found" end
    local updated, update_err = self:_run([[
        UPDATE notebook_state SET current_page_id = ?2
         WHERE notebook_id = ?1;]], { notebook_id, page_id })
    if not updated then return nil, update_err end
    local changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    return true
end

function Repository:_neighbour(notebook_id, sort_key, id, direction)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    notebook_id, sort_key, id = positiveInteger(notebook_id),
        tonumber(sort_key), positiveInteger(id)
    if not notebook_id or not finite(sort_key) or not id then
        return nil, "bad_cursor"
    end
    local comparator, order
    if direction == "previous" then comparator, order = "<", "DESC"
    else comparator, order = ">", "ASC" end
    local rows, err = self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at, revision
          FROM notebook_pages
         WHERE notebook_id = ?1 AND deleted_at IS NULL
           AND (sort_key ]] .. comparator .. [[ ?2
                OR (sort_key = ?2 AND id ]] .. comparator .. [[ ?3))
         ORDER BY sort_key ]] .. order .. [[, id ]] .. order .. [[ LIMIT 1;]],
        { notebook_id, sort_key, id }, pageRow)
    if not rows then return nil, err end
    return rows[1]
end

function Repository:previousPage(page)
    return self:_neighbour(page.notebook_id, page.sort_key, page.id, "previous")
end

function Repository:nextPage(page)
    return self:_neighbour(page.notebook_id, page.sort_key, page.id, "next")
end

function Repository:softDeletePage(notebook_id, page_id)
    notebook_id, page_id = positiveInteger(notebook_id), positiveInteger(page_id)
    if not notebook_id or not page_id then return nil, "bad_id" end
    local selected
    local ok, err = self:transaction(function()
        local notebook, notebook_err = self:getNotebook(notebook_id)
        if not notebook then return nil, notebook_err end
        if notebook.page_count <= 1 then return nil, "last_page" end
        local page, page_err = self:getPage(page_id)
        if not page or page.notebook_id ~= notebook_id then return nil, page_err or "not_found" end
        local neighbour_err
        selected, neighbour_err = self:previousPage(page)
        if not selected and neighbour_err then return nil, neighbour_err end
        if not selected then
            selected, neighbour_err = self:nextPage(page)
            if not selected and neighbour_err then return nil, neighbour_err end
        end
        if not selected then return nil, "last_page" end
        if notebook.current_page_id == page_id then
            local changed, change_err = self:_run([[
                UPDATE notebook_state SET current_page_id = ?2
                 WHERE notebook_id = ?1;]], { notebook_id, selected.id })
            if not changed then return nil, change_err end
        end
        local now = self.now()
        local deleted, delete_err = self:_run([[
            UPDATE notebook_pages SET deleted_at = ?2, updated_at = ?2
             WHERE id = ?1 AND deleted_at IS NULL;]], { page_id, now })
        if not deleted then return nil, delete_err end
        deleted, delete_err = self:_run([[
            UPDATE notebooks SET page_count = page_count - 1, updated_at = ?2
             WHERE id = ?1 AND deleted_at IS NULL;]], { notebook_id, now })
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return nil, err end
    return selected
end

function Repository:nextSeq(page_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    page_id = positiveInteger(page_id)
    if not page_id then return nil, "bad_id" end
    local rows, err = self:_select(
        "SELECT MAX(seq) FROM notebook_strokes WHERE page_id = ?1;",
        { page_id }, function(row) return num(row[1]) or 0 end)
    if not rows then return nil, err end
    return (rows[1] or 0) + 1
end

function Repository:addStroke(page, stroke)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if type(page) ~= "table" or type(stroke) ~= "table"
        or not positiveInteger(page.id)
        or not positiveInteger(page.logical_w)
        or not positiveInteger(page.logical_h) then
        return nil, "bad_stroke"
    end
    local n = tonumber(stroke.n) or 0
    local valid, validation_err = Codec.validate(stroke.points, n,
        page.logical_w, page.logical_h)
    if not valid then return nil, validation_err end
    local width, tool = tonumber(stroke.width), tonumber(stroke.tool)
    if not finite(width) or width < 0 or not finite(tool) then return nil, "bad_stroke" end
    local min_x, min_y = stroke.points[1], stroke.points[2]
    local max_x, max_y = min_x, min_y
    for i = 2, n do
        local x, y = stroke.points[i * 2 - 1], stroke.points[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end
    local seq = positiveInteger(stroke.seq)
    if not seq then seq = self:nextSeq(page.id) end
    if not seq then return nil, "no_seq" end
    local paint_seq = positiveInteger(stroke.paint_seq or seq)
    if not paint_seq then return nil, "bad_stroke" end
    return self:transaction(function()
        local inserted, insert_err = self:_run([[
            INSERT INTO notebook_strokes
                (page_id, seq, width, tool, codec, point_count,
                 min_x, min_y, max_x, max_y, created_at, deleted_at, paint_seq)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, ?12);]],
            { page.id, seq, width, tool, Codec.VERSION, n,
              min_x, min_y, max_x, max_y, self.now(), paint_seq })
        if not inserted then return nil, insert_err end
        local id, id_err = self:_lastId()
        if not id then return nil, id_err end
        local encoded, encode_err = Codec.eachEncodedChunk(stroke.points, n,
            page.logical_w, page.logical_h,
            function(chunk_no, point_count, blob)
                return self:_run([[
                    INSERT INTO notebook_stroke_chunks
                        (stroke_id, chunk_no, point_count, points)
                    VALUES (?1, ?2, ?3, CAST(?4 AS BLOB));]],
                    { id, chunk_no, point_count, blob })
            end)
        if not encoded then return nil, encode_err end
        return id
    end)
end

function Repository:listStrokes(page_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    page_id = positiveInteger(page_id)
    if not page_id then return nil, "bad_id" end
    return self:_select([[
        SELECT id, seq, width, tool, codec, point_count,
               min_x, min_y, max_x, max_y, COALESCE(paint_seq, seq)
          FROM notebook_strokes
         WHERE page_id = ?1 AND deleted_at IS NULL ORDER BY seq;]],
        { page_id }, function(row)
            return {
                id = num(row[1]), seq = num(row[2]), width = num(row[3]),
                tool = num(row[4]), codec = num(row[5]), point_count = num(row[6]),
                min_x = num(row[7]), min_y = num(row[8]),
                max_x = num(row[9]), max_y = num(row[10]),
                paint_seq = num(row[11]) or num(row[2]),
            }
        end)
end

--[[--
One keyset page of a page's stroke metadata, in visual order.

`listStrokes` answers a whole page at once, which suits a renderer that keeps
every stroke's bounds anyway and does not suit an export that walks a notebook
one stroke at a time. This answers at most `opts.limit` rows ordered by
`(COALESCE(paint_seq, seq), seq)` -- later on top -- strictly after the
`(opts.after_paint_seq, opts.after_seq)` cursor. `seq` is unique per page, so
the order is total and a walk neither repeats nor skips a stroke.
]]
function Repository:listStrokesBatch(page_id, opts)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    page_id = positiveInteger(page_id)
    if not page_id then return nil, "bad_id" end
    opts = opts or {}
    local limit = boundedLimit(opts.limit)
    local after_key, after_seq = opts.after_paint_seq, opts.after_seq
    local cursor = ""
    local binds = { page_id, limit }
    if after_key ~= nil or after_seq ~= nil then
        after_key, after_seq = tonumber(after_key), tonumber(after_seq)
        if not finite(after_key) or not finite(after_seq) then
            return nil, "bad_cursor"
        end
        cursor = [[
           AND (COALESCE(paint_seq, seq) > ?3
                OR (COALESCE(paint_seq, seq) = ?3 AND seq > ?4))]]
        binds[3], binds[4] = after_key, after_seq
    end
    return self:_select([[
        SELECT id, seq, width, tool, codec, point_count,
               min_x, min_y, max_x, max_y, COALESCE(paint_seq, seq)
          FROM notebook_strokes
         WHERE page_id = ?1 AND deleted_at IS NULL]] .. cursor .. [[
         ORDER BY COALESCE(paint_seq, seq), seq LIMIT ?2;]],
        binds, function(row)
            return {
                id = num(row[1]), seq = num(row[2]), width = num(row[3]),
                tool = num(row[4]), codec = num(row[5]), point_count = num(row[6]),
                min_x = num(row[7]), min_y = num(row[8]),
                max_x = num(row[9]), max_y = num(row[10]),
                paint_seq = num(row[11]) or num(row[2]),
            }
        end)
end

--[[--
A page's ink, reduced to what changes whenever the ink does.

`count` of live strokes, and the largest live `seq` and `id`. A stroke drawn
raises `max_id` (row ids only grow while rows exist); a stroke erased lowers
`count`; an erase that splits a stroke does both. Deleted rows are left out on
purpose, so the maintenance purge, which only removes rows that were already
deleted, never reads as an edit. An export compares this before and after, and
refuses to publish if it moved.
]]
function Repository:strokeRevision(page_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    page_id = positiveInteger(page_id)
    if not page_id then return nil, "bad_id" end
    local rows, err = self:_select([[
        SELECT COUNT(*), MAX(seq), MAX(id)
          FROM notebook_strokes
         WHERE page_id = ?1 AND deleted_at IS NULL;]],
        { page_id }, function(row)
            return { count = num(row[1]) or 0, max_seq = num(row[2]) or 0,
                max_id = num(row[3]) or 0 }
        end)
    if not rows then return nil, err end
    return rows[1] or { count = 0, max_seq = 0, max_id = 0 }
end

function Repository:openStrokeCursor(stroke_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    stroke_id = positiveInteger(stroke_id)
    if not stroke_id then return nil, "bad_id" end
    local stmt
    local ok, err = pcall(function()
        stmt = self.conn:prepare([[
            SELECT c.chunk_no, c.point_count, CAST(c.points AS TEXT)
              FROM notebook_stroke_chunks c
              JOIN notebook_strokes s ON s.id = c.stroke_id
             WHERE c.stroke_id = ?1 AND s.deleted_at IS NULL
             ORDER BY c.chunk_no;]])
        stmt:bind(stroke_id)
    end)
    if not ok then
        if stmt then pcall(stmt.close, stmt) end
        return nil, tostring(err)
    end
    local cursor = { stmt = stmt, closed = false }
    function cursor:close()
        if self.closed then return true end
        self.closed = true
        local closed, close_err = pcall(self.stmt.close, self.stmt)
        self.stmt = nil
        if not closed then return nil, tostring(close_err) end
        return true
    end
    function cursor:next()
        if self.closed then return nil, "closed" end
        local stepped, row = pcall(self.stmt.step, self.stmt)
        if not stepped then self:close(); return nil, tostring(row) end
        if not row then
            local closed, close_err = self:close()
            if not closed then return nil, close_err end
            return nil, nil, true
        end
        return { chunk_no = num(row[1]), point_count = num(row[2]), points = row[3] }
    end
    return cursor
end

function Repository:readStrokeChunk(stroke_id, chunk_no)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    stroke_id, chunk_no = positiveInteger(stroke_id), tonumber(chunk_no)
    if not stroke_id or not finite(chunk_no) or chunk_no < 0
        or chunk_no ~= math.floor(chunk_no) then
        return nil, "bad_id"
    end
    local rows, err = self:_select([[
        SELECT c.chunk_no, c.point_count, CAST(c.points AS TEXT)
          FROM notebook_stroke_chunks c
          JOIN notebook_strokes s ON s.id = c.stroke_id
         WHERE c.stroke_id = ?1 AND c.chunk_no = ?2 AND s.deleted_at IS NULL;]],
        { stroke_id, chunk_no }, function(row)
            return { chunk_no = num(row[1]), point_count = num(row[2]), points = row[3] }
        end)
    if not rows then return nil, err end
    if not rows[1] then return nil, "missing_chunk" end
    return rows[1]
end

function Repository:deleteStroke(stroke_id)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    stroke_id = positiveInteger(stroke_id)
    if not stroke_id then return nil, "bad_id" end
    local deleted, delete_err = self:_run([[
        UPDATE notebook_strokes SET deleted_at = ?2
         WHERE id = ?1 AND deleted_at IS NULL;]], { stroke_id, self.now() })
    if not deleted then return nil, delete_err end
    local changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    return true
end

-- Called once per committed Queue batch, never per live segment.  This keeps
-- library recency truthful without turning handwriting into a stream of extra
-- flash writes.
function Repository:touchSurface(page)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if type(page) ~= "table" then return nil, "bad_id" end
    local page_id = positiveInteger(page.id)
    local notebook_id = positiveInteger(page.notebook_id)
    if not page_id or not notebook_id then return nil, "bad_id" end
    local now = self.now()
    local touched, touch_err = self:_run([[
        UPDATE notebook_pages SET updated_at = ?3, revision = revision + 1
         WHERE id = ?1 AND notebook_id = ?2 AND deleted_at IS NULL;]],
        { page_id, notebook_id, now })
    if not touched then return nil, touch_err end
    local changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    touched, touch_err = self:_run([[
        UPDATE notebooks SET updated_at = ?2
         WHERE id = ?1 AND deleted_at IS NULL;]], { notebook_id, now })
    if not touched then return nil, touch_err end
    changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    return true
end

local function purgeLimit(value, default, maximum)
    value = positiveInteger(value) or default
    return value > maximum and maximum or value
end

function Repository:purgeDeletedBatch(limits)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    limits = limits or {}
    local chunk_limit = purgeLimit(limits.chunks, 64, 256)
    local stroke_limit = purgeLimit(limits.strokes, 32, 128)
    local page_limit = purgeLimit(limits.pages, 8, 32)
    local notebook_limit = purgeLimit(limits.notebooks, 1, 4)
    local counts = {
        marked_pages = 0, marked_strokes = 0,
        chunks = 0, strokes = 0, pages = 0, notebooks = 0,
    }
    local ok, err = self:transaction(function()
        local function recordChanges(field)
            local changed, change_err = self:_changes()
            if changed == nil then return nil, change_err end
            counts[field] = changed
            return true
        end
        -- Propagate a deleted parent into bounded child tombstones first.
        -- This keeps the physical leaf queries index-driven: they never need
        -- an OR across every active chunk merely to discover an ancestor.
        local ran, run_err = self:_run([[
            UPDATE notebook_pages SET deleted_at = ?2, updated_at = ?2
             WHERE id IN (
                SELECT p.id
                  FROM notebooks n INDEXED BY notebooks_active_recent
                  CROSS JOIN notebook_pages p INDEXED BY pages_by_notebook
                    ON p.notebook_id = n.id
                 WHERE n.deleted_at IS NOT NULL AND p.deleted_at IS NULL
                 LIMIT ?1);]], { page_limit, self.now() })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("marked_pages")
        if not ran then return nil, run_err end

        ran, run_err = self:_run([[
            UPDATE notebook_strokes SET deleted_at = ?2
             WHERE id IN (
                SELECT s.id
                  FROM notebook_pages p INDEXED BY pages_deleted
                  CROSS JOIN notebook_strokes s INDEXED BY strokes_by_page
                    ON s.page_id = p.id
                 WHERE p.deleted_at IS NOT NULL AND s.deleted_at IS NULL
                 LIMIT ?1);]], { stroke_limit, self.now() })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("marked_strokes")
        if not ran then return nil, run_err end

        ran, run_err = self:_run([[
            DELETE FROM notebook_stroke_chunks
             WHERE rowid IN (
                SELECT c.rowid
                  FROM notebook_strokes s INDEXED BY strokes_deleted
                  CROSS JOIN notebook_stroke_chunks c ON c.stroke_id = s.id
                 WHERE s.deleted_at IS NOT NULL
                 LIMIT ?1);]], { chunk_limit })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("chunks")
        if not ran then return nil, run_err end

        ran, run_err = self:_run([[
            DELETE FROM notebook_strokes
             WHERE id IN (
                SELECT s.id
                  FROM notebook_strokes s INDEXED BY strokes_deleted
                 WHERE s.deleted_at IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_stroke_chunks c
                        WHERE c.stroke_id = s.id)
                 LIMIT ?1);]], { stroke_limit })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("strokes")
        if not ran then return nil, run_err end

        ran, run_err = self:_run([[
            DELETE FROM notebook_pages
             WHERE id IN (
                SELECT p.id
                  FROM notebook_pages p INDEXED BY pages_deleted
                 WHERE p.deleted_at IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_strokes s WHERE s.page_id = p.id)
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_state st WHERE st.current_page_id = p.id)
                 LIMIT ?1);]], { page_limit })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("pages")
        if not ran then return nil, run_err end

        ran, run_err = self:_run([[
            DELETE FROM notebooks
             WHERE id IN (
                SELECT n.id
                  FROM notebooks n INDEXED BY notebooks_active_recent
                 WHERE n.deleted_at IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_pages p WHERE p.notebook_id = n.id)
                   AND NOT EXISTS (
                       SELECT 1 FROM notebook_state st WHERE st.notebook_id = n.id)
                 LIMIT ?1);]], { notebook_limit })
        if not ran then return nil, run_err end
        ran, run_err = recordChanges("notebooks")
        if not ran then return nil, run_err end
        return true
    end)
    if not ok then return nil, err end
    counts.changed = counts.marked_pages + counts.marked_strokes
        + counts.chunks + counts.strokes + counts.pages + counts.notebooks
    return counts
end

-- ------------------------------------------------------------ gallery (v3)

--- This database's random identity, for caches kept outside it (thumbnails).
function Repository:dbUid()
    if self.db_uid then return self.db_uid end
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local rows, err = self:_select(
        "SELECT value FROM library_meta WHERE key = 'db_uid';", nil,
        function(row) return str(row[1]) end)
    if not rows then return nil, err end
    if not rows[1] then return nil, "no_uid" end
    self.db_uid = rows[1]
    return self.db_uid
end

local function folderRow(row)
    return {
        id = num(row[1]), name = str(row[2]), created_at = num(row[3]),
        updated_at = num(row[4]), notebook_count = num(row[5]) or 0,
    }
end

--[[--
Live folders, ordered by name (ASCII case-insensitive -- SQLite's NOCASE --
then id), with how many complete, live notebooks each holds. Paginated by
`{after_name, after_id}`.
]]
function Repository:listFolders(opts)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    opts = opts or {}
    local limit = boundedLimit(opts.limit)
    local sql = [[
        SELECT f.id, f.name, f.created_at, f.updated_at,
               (SELECT COUNT(*) FROM notebooks n
                 WHERE n.folder_id = f.id AND n.deleted_at IS NULL
                   AND n.copy_state IS NULL)
          FROM notebook_folders f
         WHERE f.deleted_at IS NULL]]
    local binds = {}
    if opts.after_name ~= nil then
        local after_id = positiveInteger(opts.after_id)
        if type(opts.after_name) ~= "string" or not after_id then return nil, "bad_cursor" end
        sql = sql .. [[
           AND (f.name COLLATE NOCASE > ?1
                OR (f.name COLLATE NOCASE = ?1 AND f.id > ?2))]]
        binds = { opts.after_name, after_id }
    end
    binds[#binds + 1] = limit
    sql = sql .. string.format([[
         ORDER BY f.name COLLATE NOCASE, f.id LIMIT ?%d;]], #binds)
    return self:_select(sql, binds, folderRow)
end

function Repository:createFolder(name)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    name = validTitle(name)
    if not name then return nil, "bad_title" end
    local folder
    local ok, err = self:transaction(function()
        local now = self.now()
        local inserted, insert_err = self:_run([[
            INSERT INTO notebook_folders (name, created_at, updated_at, deleted_at)
            VALUES (?1, ?2, ?2, NULL);]], { name, now })
        if not inserted then return nil, insert_err end
        local id, id_err = self:_lastId()
        if not id then return nil, id_err end
        folder = { id = id, name = name, created_at = now, updated_at = now, notebook_count = 0 }
        return true
    end)
    if not ok then return nil, err end
    return folder
end

function Repository:renameFolder(id, name)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    id, name = positiveInteger(id), validTitle(name)
    if not id then return nil, "bad_id" end
    if not name then return nil, "bad_title" end
    local ok, err = self:_run([[
        UPDATE notebook_folders SET name = ?2, updated_at = ?3
         WHERE id = ?1 AND deleted_at IS NULL;]], { id, name, self.now() })
    if not ok then return nil, err end
    local changed, change_err = self:_changes()
    if changed == nil then return nil, change_err end
    if changed == 0 then return nil, "not_found" end
    return true
end

--- Delete a folder logically; its notebooks go back to the root, in the same
--- transaction, never with it.
function Repository:deleteFolder(id)
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    return self:transaction(function()
        local now = self.now()
        local ok, err = self:_run([[
            UPDATE notebooks SET folder_id = NULL WHERE folder_id = ?1;]], { id })
        if not ok then return nil, err end
        ok, err = self:_run([[
            UPDATE notebook_folders SET deleted_at = ?2, updated_at = ?2
             WHERE id = ?1 AND deleted_at IS NULL;]], { id, now })
        if not ok then return nil, err end
        local changed, change_err = self:_changes()
        if changed == nil then return nil, change_err end
        if changed == 0 then return nil, "not_found" end
        return true
    end)
end

--- Move a live, complete notebook to a live folder, or to the root with nil.
function Repository:moveNotebook(notebook_id, folder_id)
    notebook_id = positiveInteger(notebook_id)
    if not notebook_id then return nil, "bad_id" end
    if folder_id ~= nil then
        folder_id = positiveInteger(folder_id)
        if not folder_id then return nil, "bad_id" end
    end
    return self:transaction(function()
        local notebook, notebook_err = self:getNotebook(notebook_id)
        if not notebook then return nil, notebook_err end
        if folder_id then
            local rows, err = self:_select([[
                SELECT id FROM notebook_folders WHERE id = ?1 AND deleted_at IS NULL;]],
                { folder_id }, function(row) return num(row[1]) end)
            if not rows then return nil, err end
            if not rows[1] then return nil, "not_found" end
        end
        return self:_run([[
            UPDATE notebooks SET folder_id = ?2
             WHERE id = ?1 AND deleted_at IS NULL AND copy_state IS NULL;]],
            { notebook_id, folder_id })
    end)
end

--- The orders the gallery offers, as fixed SQL: nothing the caller passes is
--- ever interpolated into a statement.
local SORTS = {
    recent = { order = "updated_at DESC, id DESC", key = "updated_at", cmp = "<", tie = "<" },
    oldest = { order = "updated_at ASC, id ASC", key = "updated_at", cmp = ">", tie = ">" },
    title_asc = { order = "title COLLATE NOCASE ASC, id ASC",
        key = "title COLLATE NOCASE", cmp = ">", tie = ">", text = true },
    title_desc = { order = "title COLLATE NOCASE DESC, id DESC",
        key = "title COLLATE NOCASE", cmp = "<", tie = "<", text = true },
}
Repository.SORTS = SORTS

--[[--
One page of the gallery. `opts.scope` is "all", "root" (no folder) or
"folder" with `opts.folder_id`; `opts.sort` one of `SORTS`; `opts.cursor` the
`next_cursor` of the previous page. Returns rows and a next cursor (nil at the
end), or nil and a reason. A cursor from another scope, folder or sort is
refused rather than followed into the wrong list.
]]
function Repository:listNotebookPage(opts)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    opts = opts or {}
    local scope = opts.scope or "all"
    local sort = SORTS[opts.sort or "recent"]
    if not sort then return nil, "bad_sort" end
    local folder_id
    if scope == "folder" then
        folder_id = positiveInteger(opts.folder_id)
        if not folder_id then return nil, "bad_id" end
    elseif scope ~= "all" and scope ~= "root" then
        return nil, "bad_scope"
    end
    local limit = boundedLimit(opts.limit)
    local where = { "deleted_at IS NULL", "copy_state IS NULL" }
    local binds = {}
    if scope == "root" then where[#where + 1] = "folder_id IS NULL" end
    if folder_id then
        binds[#binds + 1] = folder_id
        where[#where + 1] = string.format("folder_id = ?%d", #binds)
    end
    local cursor = opts.cursor
    if cursor ~= nil then
        if type(cursor) ~= "table" or cursor.v ~= 1 or cursor.scope ~= scope
            or cursor.folder_id ~= folder_id or cursor.sort ~= (opts.sort or "recent")
            or not positiveInteger(cursor.id)
            or (sort.text and type(cursor.key) ~= "string")
            or (not sort.text and not finite(cursor.key)) then
            return nil, "bad_cursor"
        end
        binds[#binds + 1] = cursor.key
        local k = #binds
        binds[#binds + 1] = cursor.id
        local i = #binds
        where[#where + 1] = string.format("(%s %s ?%d OR (%s = ?%d AND id %s ?%d))",
            sort.key, sort.cmp, k, sort.key, k, sort.tie, i)
    end
    binds[#binds + 1] = limit + 1
    local sql = string.format([[
        SELECT id, title, page_count, next_sort_key, created_at, updated_at,
               deleted_at, NULL, folder_id, uid, copy_state
          FROM notebooks WHERE %s ORDER BY %s LIMIT ?%d;]],
        table.concat(where, " AND "), sort.order, #binds)
    local rows, err = self:_select(sql, binds, notebookRow)
    if not rows then return nil, err end
    local next_cursor
    if #rows > limit then
        table.remove(rows)
        local last = rows[#rows]
        next_cursor = {
            v = 1, scope = scope, folder_id = folder_id, sort = opts.sort or "recent",
            key = sort.text and last.title or last.updated_at, id = last.id,
        }
    end
    return rows, next_cursor
end

--- The page a notebook's thumbnail shows: its current page when that is
--- live, else its first live page.
function Repository:thumbnailPage(notebook_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local notebook, err = self:getNotebook(notebook_id)
    if not notebook then return nil, err end
    if notebook.current_page_id then
        local page = self:getPage(notebook.current_page_id)
        if page and page.notebook_id == notebook.id then return page, notebook end
    end
    local pages, list_err = self:listPages(notebook.id, { limit = 1 })
    if not pages then return nil, list_err end
    if not pages[1] then return nil, "no_page" end
    return pages[1], notebook
end

-- ------------------------------------------------------------ copies

--- Everything that must not change while a notebook is being copied.
function Repository:_copySignature(notebook_id)
    local rows, err = self:_select([[
        SELECT COUNT(*), COALESCE(SUM(revision), 0)
          FROM notebook_pages WHERE notebook_id = ?1 AND deleted_at IS NULL;]],
        { notebook_id }, function(row)
            return tostring(num(row[1]) or 0) .. ":" .. tostring(num(row[2]) or 0)
        end)
    if not rows then return nil, err end
    return rows[1]
end

--[[--
Start duplicating a notebook: a hidden notebook with the same pages (geometry,
paper, order), marked as a copy in progress by this process. Nothing is
visible until `finishCopy`. Returns the copy's state, to hand to `copyBatch`.
]]
function Repository:beginCopy(source_id, title)
    source_id = positiveInteger(source_id)
    if not source_id then return nil, "bad_id" end
    local state
    local ok, err = self:transaction(function()
        local source, source_err = self:getNotebook(source_id)
        if not source then return nil, source_err end
        local signature, sig_err = self:_copySignature(source_id)
        if not signature then return nil, sig_err end
        title = validTitle(title) or validTitle(source.title .. " (copy)")
            or validTitle(source.title:sub(1, 240) .. " (copy)")
        local now = self.now()
        local inserted, insert_err = self:_run([[
            INSERT INTO notebooks
                (title, page_count, next_sort_key, created_at, updated_at, deleted_at,
                 uid, folder_id, copy_state, copy_source)
            VALUES (?1, ?2, ?3, ?4, ?4, NULL, lower(hex(randomblob(8))), ?5, ?6, ?7);]],
            { title, source.page_count, source.next_sort_key, now, source.folder_id,
              "copying:" .. PROCESS_TOKEN, source_id })
        if not inserted then return nil, insert_err end
        local dest_id, id_err = self:_lastId()
        if not dest_id then return nil, id_err end
        inserted, insert_err = self:_run([[
            INSERT INTO notebook_pages
                (notebook_id, sort_key, logical_w, logical_h, template_kind,
                 created_at, updated_at, deleted_at, revision)
            SELECT ?2, sort_key, logical_w, logical_h, template_kind, ?3, ?3, NULL, 1
              FROM notebook_pages WHERE notebook_id = ?1 AND deleted_at IS NULL
             ORDER BY sort_key, id;]], { source_id, dest_id, now })
        if not inserted then return nil, insert_err end
        state = {
            source_id = source_id, dest_id = dest_id, signature = signature,
            after_stroke = 0, strokes = 0, chunks = 0, done = false,
            current_sort_key = nil,
        }
        return true
    end)
    if not ok then return nil, err end
    return state
end

--[[--
Copy the next batch of live strokes (and their chunks, byte for byte: codec,
seq, paint order, width, style and box preserved) in one transaction. Stops at
`limits.strokes` strokes, `limits.chunks` chunks or `limits.bytes` encoded
bytes -- always after at least one stroke -- so no turn grows with the
notebook. Refuses with `source_changed` if the source was edited meanwhile.
Returns true when everything is copied, false when there is more, or nil and
a reason.
]]
function Repository:copyBatch(state, limits)
    if type(state) ~= "table" or state.done then return nil, "bad_state" end
    limits = limits or {}
    local max_strokes = positiveInteger(limits.strokes) or 32
    local max_chunks = positiveInteger(limits.chunks) or 128
    local max_bytes = positiveInteger(limits.bytes) or 512 * 1024
    local finished
    local ok, err = self:transaction(function()
        local signature, sig_err = self:_copySignature(state.source_id)
        if not signature then return nil, sig_err end
        if signature ~= state.signature then return nil, "source_changed" end
        local rows, list_err = self:_select([[
            SELECT s.id, p.sort_key, s.seq, s.width, s.tool, s.codec, s.point_count,
                   s.min_x, s.min_y, s.max_x, s.max_y, s.created_at, s.paint_seq
              FROM notebook_strokes s JOIN notebook_pages p ON p.id = s.page_id
             WHERE p.notebook_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL
               AND s.id > ?2
             ORDER BY s.id LIMIT ?3;]], { state.source_id, state.after_stroke, max_strokes },
            function(row)
                local out = {}
                for i = 1, 13 do out[i] = row[i] end
                return out
            end)
        if not rows then return nil, list_err end
        local chunks, bytes = 0, 0
        local copied = 0
        for i = 1, #rows do
            local r = rows[i]
            local points = num(r[7]) or 0
            local stroke_chunks = Codec.chunkCount(points)
            if copied > 0 and (chunks + stroke_chunks > max_chunks
                or bytes + points * 4 > max_bytes) then break end
            local pages, page_err = self:_select([[
                SELECT id FROM notebook_pages
                 WHERE notebook_id = ?1 AND sort_key = ?2 AND deleted_at IS NULL;]],
                { state.dest_id, num(r[2]) }, function(row) return num(row[1]) end)
            if not pages then return nil, page_err end
            if not pages[1] then return nil, "copy_page_missing" end
            local inserted, insert_err = self:_run([[
                INSERT INTO notebook_strokes
                    (page_id, seq, width, tool, codec, point_count,
                     min_x, min_y, max_x, max_y, created_at, deleted_at, paint_seq)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL, ?12);]],
                { pages[1], num(r[3]), num(r[4]), num(r[5]), num(r[6]), points,
                  num(r[8]), num(r[9]), num(r[10]), num(r[11]), num(r[12]), num(r[13]) })
            if not inserted then return nil, insert_err end
            local new_id, id_err = self:_lastId()
            if not new_id then return nil, id_err end
            inserted, insert_err = self:_run([[
                INSERT INTO notebook_stroke_chunks (stroke_id, chunk_no, point_count, points)
                SELECT ?1, chunk_no, point_count, points
                  FROM notebook_stroke_chunks WHERE stroke_id = ?2 ORDER BY chunk_no;]],
                { new_id, num(r[1]) })
            if not inserted then return nil, insert_err end
            chunks = chunks + stroke_chunks
            bytes = bytes + points * 4
            copied = copied + 1
            state.after_stroke = num(r[1])
        end
        state.strokes = state.strokes + copied
        state.chunks = state.chunks + chunks
        finished = #rows < max_strokes and copied == #rows
        return true
    end)
    if not ok then return nil, err end
    return finished
end

--[[--
Make a finished copy visible. Verifies, in the same transaction, that it holds
as many live strokes and chunks as the source, and gives it the source's
current page (by position) before clearing its copy mark.
]]
function Repository:finishCopy(state)
    if type(state) ~= "table" then return nil, "bad_state" end
    local ok, err = self:transaction(function()
        local signature, sig_err = self:_copySignature(state.source_id)
        if not signature then return nil, sig_err end
        if signature ~= state.signature then return nil, "source_changed" end
        local function counts(notebook_id)
            local rows, count_err = self:_select([[
                SELECT COUNT(DISTINCT s.id), COUNT(c.chunk_no)
                  FROM notebook_strokes s
                  JOIN notebook_pages p ON p.id = s.page_id
                  LEFT JOIN notebook_stroke_chunks c ON c.stroke_id = s.id
                 WHERE p.notebook_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL;]],
                { notebook_id }, function(row)
                    return tostring(num(row[1]) or 0) .. ":" .. tostring(num(row[2]) or 0)
                end)
            if not rows then return nil, count_err end
            return rows[1]
        end
        local a, a_err = counts(state.source_id)
        if not a then return nil, a_err end
        local b, b_err = counts(state.dest_id)
        if not b then return nil, b_err end
        if a ~= b then return nil, "copy_incomplete" end
        local current, current_err = self:_select([[
            SELECT d.id FROM notebook_state st
              JOIN notebook_pages sp ON sp.id = st.current_page_id
              JOIN notebook_pages d ON d.notebook_id = ?2 AND d.sort_key = sp.sort_key
             WHERE st.notebook_id = ?1 AND d.deleted_at IS NULL;]],
            { state.source_id, state.dest_id }, function(row) return num(row[1]) end)
        if not current then return nil, current_err end
        local page_id = current[1]
        if not page_id then
            local first, first_err = self:_select([[
                SELECT id FROM notebook_pages WHERE notebook_id = ?1 AND deleted_at IS NULL
                 ORDER BY sort_key, id LIMIT 1;]], { state.dest_id },
                function(row) return num(row[1]) end)
            if not first then return nil, first_err end
            page_id = first[1]
        end
        if not page_id then return nil, "no_page" end
        local done, run_err = self:_run([[
            INSERT INTO notebook_state (notebook_id, current_page_id) VALUES (?1, ?2);]],
            { state.dest_id, page_id })
        if not done then return nil, run_err end
        done, run_err = self:_run([[
            UPDATE notebooks SET copy_state = NULL, updated_at = ?2
             WHERE id = ?1 AND copy_state = ?3;]],
            { state.dest_id, self.now(), "copying:" .. PROCESS_TOKEN })
        if not done then return nil, run_err end
        local changed, change_err = self:_changes()
        if changed == nil then return nil, change_err end
        if changed == 0 then return nil, "copy_lost" end
        return true
    end)
    if not ok then return nil, err end
    state.done = true
    return state.dest_id
end

--- Abandon a copy; `purgeAbandonedCopies` removes it later, in batches.
function Repository:cancelCopy(state)
    if type(state) ~= "table" or not positiveInteger(state.dest_id) then return nil, "bad_state" end
    state.done = true
    return self:_run([[
        UPDATE notebooks SET copy_state = 'cancelled' WHERE id = ?1 AND copy_state IS NOT NULL;]],
        { state.dest_id })
end

--[[--
Remove cancelled copies, and copies left "in progress" by another process --
never one this process is still writing, however long it takes. One bounded
batch per call: returns true when nothing is left, false when there is more.
]]
function Repository:purgeAbandonedCopies(limits)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    limits = limits or {}
    local chunk_limit = positiveInteger(limits.chunks) or 256
    local mine = "copying:" .. PROCESS_TOKEN
    local finished
    local ok, err = self:transaction(function()
        local victims, list_err = self:_select([[
            SELECT id FROM notebooks
             WHERE copy_state IS NOT NULL AND copy_state <> ?1
             ORDER BY id LIMIT 1;]], { mine }, function(row) return num(row[1]) end)
        if not victims then return nil, list_err end
        local id = victims[1]
        if not id then finished = true; return true end
        local done, run_err = self:_run([[
            UPDATE notebooks SET copy_state = 'cancelled' WHERE id = ?1;]], { id })
        if not done then return nil, run_err end
        done, run_err = self:_run([[
            DELETE FROM notebook_stroke_chunks WHERE rowid IN (
                SELECT c.rowid FROM notebook_stroke_chunks c
                  JOIN notebook_strokes s ON s.id = c.stroke_id
                  JOIN notebook_pages p ON p.id = s.page_id
                 WHERE p.notebook_id = ?1 LIMIT ?2);]], { id, chunk_limit })
        if not done then return nil, run_err end
        local removed, change_err = self:_changes()
        if removed == nil then return nil, change_err end
        if removed > 0 then finished = false; return true end
        for _, sql in ipairs({
            "DELETE FROM notebook_strokes WHERE page_id IN (SELECT id FROM notebook_pages WHERE notebook_id = ?1);",
            "DELETE FROM notebook_state WHERE notebook_id = ?1;",
            "DELETE FROM notebook_pages WHERE notebook_id = ?1;",
            "DELETE FROM notebooks WHERE id = ?1;",
        }) do
            done, run_err = self:_run(sql, { id })
            if not done then return nil, run_err end
        end
        finished = false
        return true
    end)
    if not ok then return nil, err end
    return finished
end

return Repository
