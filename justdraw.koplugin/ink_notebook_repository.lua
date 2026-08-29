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

Repository.SCHEMA_VERSION = 1
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

local KNOWN_TEMPLATES = { blank = true, ruled = true, grid = true, dots = true }
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
    local ok = pcall(function()
        conn:exec("BEGIN;")
        for version = from, self.target - 1 do self.migrations[version](conn) end
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
                   created_at, updated_at, deleted_at, NULL
              FROM notebooks
             WHERE deleted_at IS NULL
             ORDER BY updated_at DESC, id DESC LIMIT ?1;]],
            { limit }, notebookRow)
    end
    return self:_select([[
        SELECT id, title, page_count, next_sort_key,
               created_at, updated_at, deleted_at, NULL
          FROM notebooks
         WHERE deleted_at IS NULL
           AND (updated_at < ?1 OR (updated_at = ?1 AND id < ?2))
         ORDER BY updated_at DESC, id DESC LIMIT ?3;]],
        { after_time, after_id, limit }, notebookRow)
end

function Repository:getNotebook(id, include_deleted)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    local deleted = include_deleted and "" or " AND n.deleted_at IS NULL"
    local rows, err = self:_select([[
        SELECT n.id, n.title, n.page_count, n.next_sort_key,
               n.created_at, n.updated_at, n.deleted_at, s.current_page_id
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
                (title, page_count, next_sort_key, created_at, updated_at, deleted_at)
            VALUES (?1, 0, ?2, ?3, ?3, NULL);]],
            { title, Repository.SORT_STEP, now })
        if not ok then return nil, insert_err end
        local notebook_id, id_err = self:_lastId()
        if not notebook_id then return nil, id_err end
        ok, insert_err = self:_run([[
            INSERT INTO notebook_pages
                (notebook_id, sort_key, logical_w, logical_h, template_kind,
                 created_at, updated_at, deleted_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL);]],
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
        notebook = {
            id = notebook_id, title = title, page_count = 1,
            next_sort_key = Repository.SORT_STEP * 2,
            created_at = now, updated_at = now, current_page_id = page_id,
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
                   template_kind, created_at, updated_at, deleted_at
              FROM notebook_pages
             WHERE notebook_id = ?1 AND deleted_at IS NULL
             ORDER BY sort_key, id LIMIT ?2;]],
            { notebook_id, limit }, pageRow)
    end
    return self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at
          FROM notebook_pages
         WHERE notebook_id = ?1 AND deleted_at IS NULL
           AND (sort_key > ?2 OR (sort_key = ?2 AND id > ?3))
         ORDER BY sort_key, id LIMIT ?4;]],
        { notebook_id, after_key, after_id, limit }, pageRow)
end

function Repository:getPage(id, include_deleted)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    id = positiveInteger(id)
    if not id then return nil, "bad_id" end
    local deleted = include_deleted and "" or " AND deleted_at IS NULL"
    local rows, err = self:_select([[
        SELECT id, notebook_id, sort_key, logical_w, logical_h,
               template_kind, created_at, updated_at, deleted_at
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
                 created_at, updated_at, deleted_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL);]],
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
               template_kind, created_at, updated_at, deleted_at
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
    return self:transaction(function()
        local inserted, insert_err = self:_run([[
            INSERT INTO notebook_strokes
                (page_id, seq, width, tool, codec, point_count,
                 min_x, min_y, max_x, max_y, created_at, deleted_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL);]],
            { page.id, seq, width, tool, Codec.VERSION, n,
              min_x, min_y, max_x, max_y, self.now() })
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
               min_x, min_y, max_x, max_y
          FROM notebook_strokes
         WHERE page_id = ?1 AND deleted_at IS NULL ORDER BY seq;]],
        { page_id }, function(row)
            return {
                id = num(row[1]), seq = num(row[2]), width = num(row[3]),
                tool = num(row[4]), codec = num(row[5]), point_count = num(row[6]),
                min_x = num(row[7]), min_y = num(row[8]),
                max_x = num(row[9]), max_y = num(row[10]),
            }
        end)
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
        UPDATE notebook_pages SET updated_at = ?3
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

return Repository
