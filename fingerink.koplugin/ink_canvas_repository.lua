--[[--
Everything the canvas feature knows about SQLite, and nothing else.

Canvas ink does not go in the document sidecar. `DocSettings:flush()`
serialises the whole settings table and rewrites the file, so one new stroke
would re-serialise every point in the book -- and the Lua representation of a
point costs around 67 bytes against the 4 bytes it takes here. The database
lives beside KOReader's own, under `DataStorage:getSettingsDir()`, following
the pattern the Statistics plugin established: `lua-ljsqlite3`, `user_version`
for the schema, and WAL only where the device supports it.

A book is keyed by `(partial_md5_checksum, file_size)`, never by path, so
renaming or moving a book keeps its canvases. `last_path` is recorded for
diagnosis only.

Two properties of the driver shape most of this file, and both are invisible
until they bite:

  * INTEGER columns come back as int64 cdata under LuaJIT. `1LL == 1` is true,
    but `t[1LL]` and `t[1]` are different table keys and `1LL .. ""` raises. So
    every value crossing back out of here goes through `num`, and the rest of
    the plugin never sees a cdata.
  * a Lua string binds as TEXT even into a column declared BLOB, and SQL that
    touches a TEXT value stops at its first NUL -- `length()` on a point blob
    would answer 1. `CAST(?n AS BLOB)` going in and `CAST(points AS TEXT)`
    coming out keep plain Lua strings on both sides of a genuine blob.

Failures never destroy data. A database that will not open is not recreated, a
schema newer than this one is opened read-only rather than downgraded, and a
migration copies the file before it writes a single statement.
]]

local logger = require("logger")

-- LuaJIT and Lua 5.1 have unpack as a global; 5.2 moved it to table. The
-- device is always LuaJIT, but the test suite also runs under a stock Lua.
local unpack = unpack or table.unpack

local Codec = require("ink_canvas_codec")

local Repository = {}
Repository.__index = Repository

--- Bumped when the schema changes. Every bump needs a MIGRATIONS entry for the
--- version below it, or opening an older database refuses rather than guesses.
Repository.SCHEMA_VERSION = 1

--- `MIGRATIONS[v]` upgrades a database at version v to version v + 1. Empty
--- while there has only ever been one schema.
Repository.MIGRATIONS = {}

--[[--
The v1 schema.

`conn:exec` splits on `;` without regard for quoting, so no statement here may
contain one inside a literal. `UNIQUE(id, book_id)` on canvases exists only so
`canvas_layout_cache` can carry a composite foreign key and have its rows
cascade away with the canvas.
]]
Repository.SCHEMA = [[
CREATE TABLE books (
    id           INTEGER PRIMARY KEY,
    partial_md5  TEXT    NOT NULL,
    file_size    INTEGER NOT NULL,
    last_path    TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    UNIQUE(partial_md5, file_size)
);
CREATE TABLE canvases (
    id                    INTEGER PRIMARY KEY,
    book_id               INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    anchor_kind           TEXT    NOT NULL CHECK(anchor_kind IN ('xpointer', 'page')),
    anchor_key            TEXT    NOT NULL,
    anchor_raw            TEXT,
    anchor_normalized     TEXT,
    anchor_dom_version    INTEGER,
    fixed_page            INTEGER,
    logical_w             INTEGER NOT NULL,
    logical_h             INTEGER NOT NULL,
    created_at            INTEGER NOT NULL,
    updated_at            INTEGER NOT NULL,
    UNIQUE(book_id, anchor_key),
    UNIQUE(id, book_id)
);
CREATE TABLE canvas_layout_cache (
    canvas_id      INTEGER NOT NULL,
    book_id        INTEGER NOT NULL,
    layout_hash    TEXT    NOT NULL,
    resolved_page  INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    PRIMARY KEY(canvas_id, layout_hash),
    FOREIGN KEY(canvas_id, book_id)
        REFERENCES canvases(id, book_id) ON DELETE CASCADE
);
CREATE TABLE strokes (
    id           INTEGER PRIMARY KEY,
    canvas_id    INTEGER NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
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
    UNIQUE(canvas_id, seq)
);
CREATE TABLE stroke_chunks (
    stroke_id    INTEGER NOT NULL REFERENCES strokes(id) ON DELETE CASCADE,
    chunk_no     INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    points       BLOB    NOT NULL,
    PRIMARY KEY(stroke_id, chunk_no)
);
CREATE INDEX canvases_by_book ON canvases(book_id, updated_at);
CREATE INDEX layout_by_page
    ON canvas_layout_cache(book_id, layout_hash, resolved_page, canvas_id);
CREATE INDEX strokes_by_canvas ON strokes(canvas_id, seq);
]]

-- ------------------------------------------------------------------ helpers

--- Anything out of a result row that is meant to be a number. See the header:
--- an int64 that reaches a table key silently loses every lookup.
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

--- Byte-for-byte copy, used before a migration. Deliberately not a rename: the
--- point is that the original is still there if the migration goes wrong.
local function copyFile(src, dest)
    local fi = io.open(src, "rb")
    if not fi then return nil, "cannot read " .. tostring(src) end
    local fo = io.open(dest, "wb")
    if not fo then
        fi:close()
        return nil, "cannot write " .. tostring(dest)
    end
    while true do
        local block = fi:read(64 * 1024)
        if not block or block == "" then break end
        if not fo:write(block) then
            fi:close()
            fo:close()
            return nil, "write failed"
        end
    end
    fi:close()
    if not fo:close() then return nil, "close failed" end
    return true
end

-- ------------------------------------------------------------------ opening

--[[--
Open, or create, the canvas database.

  opts.path            file to open
  opts.driver          SQ3-alike; defaults to require("lua-ljsqlite3/init")
  opts.wal             true for WAL, false for TRUNCATE (Device:canUseWAL())
  opts.now             clock, defaults to os.time
  opts.backup          copy function, defaults to a plain byte copy
  opts.schema_version  target version, defaults to SCHEMA_VERSION
  opts.migrations      ladder, defaults to MIGRATIONS

The last two are injectable so the migration policy -- copy first, one
transaction, refuse a gap -- can be exercised before a second schema version
exists. Without that the whole path would first run on a reader's notes.

Returns the repository, or nil plus one of `no_driver`, `open_failed`,
`schema_failed`, `backup_failed`, `migration_missing`, `migration_failed`.
]]
function Repository.open(opts)
    opts = opts or {}

    local driver = opts.driver
    if driver == nil then
        local ok, mod = pcall(require, "lua-ljsqlite3/init")
        driver = ok and mod or nil
    end
    if type(driver) ~= "table" or type(driver.open) ~= "function" then
        logger.warn("FingerInk: no SQLite driver; canvases are unavailable")
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
        read_only_reason = nil,
        depth = 0,
    }, Repository)

    local conn, err = self:_connect("rwc")
    if not conn then return nil, err end

    local ok, version = pcall(function()
        return num(conn:rowexec("PRAGMA user_version;")) or 0
    end)
    if not ok then
        logger.err("FingerInk: cannot read the canvas schema version:", version)
        self:_disconnect()
        return nil, "open_failed"
    end

    if version == 0 then
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        local created, cerr = self:_createSchema()
        if not created then
            self:_disconnect()
            return nil, cerr
        end
    elseif version > self.target then
        -- A newer FingerInk wrote this. Reading it is fine; writing to it with
        -- an older understanding of the schema is how notes get lost.
        self:_disconnect()
        local readonly, ro_err = self:_connect("ro")
        if not readonly then return nil, ro_err end
        self.read_only = true
        self.read_only_reason = "canvas database is newer than this plugin"
        self.version = version
        logger.warn("FingerInk: canvas database is version", version,
            "but this plugin knows", self.target, "- opening read-only")
    elseif version < self.target then
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        local migrated, merr = self:_migrate(version)
        if not migrated then
            self:_disconnect()
            return nil, merr
        end
    else
        local configured, config_err = self:_configureWritable()
        if not configured then self:_disconnect(); return nil, config_err end
        self.version = version
    end

    return self
end

function Repository:_connect(mode)
    local ok, conn = pcall(self.driver.open, self.path, mode or "rwc")
    if not ok or not conn then
        logger.err("FingerInk: cannot open the canvas database:", conn)
        return nil, "open_failed"
    end
    self.conn = conn

    local pragmas_ok, perr = pcall(function()
        conn:exec("PRAGMA foreign_keys=ON;")
    end)
    if not pragmas_ok then
        logger.err("FingerInk: cannot configure the canvas database:", perr)
        self:_disconnect()
        return nil, "open_failed"
    end
    return conn
end

function Repository:_configureWritable()
    local ok, err = pcall(function()
        -- Never synchronous=OFF: the whole point of leaving the sidecar was
        -- durability, and a corrupt database loses more than a slow one.
        self.conn:exec(self.wal and "PRAGMA journal_mode=WAL;"
                                or "PRAGMA journal_mode=TRUNCATE;")
    end)
    if not ok then
        logger.err("FingerInk: cannot configure the canvas database:", err)
        return nil, "open_failed"
    end
    return true
end

--- Drop the connection without marking the repository permanently closed.
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
    if #partial > 0 then
        logger.err("FingerInk: schema version is zero but tables already exist")
        return nil, "schema_failed"
    end

    local began = false
    local ok, err = pcall(function()
        self.conn:exec("BEGIN;")
        began = true
        self.conn:exec(Repository.SCHEMA)
        self.conn:exec(string.format("PRAGMA user_version=%d;", self.target))
        self.conn:exec("COMMIT;")
    end)
    if not ok then
        if began then pcall(self.conn.exec, self.conn, "ROLLBACK;") end
        logger.err("FingerInk: cannot create the canvas schema:", err)
        return nil, "schema_failed"
    end
    self.version = self.target
    return true
end

--[[--
Bring an older database up to the target version.

Order matters and is the point of the tests around it: the ladder is checked
for completeness before anything is touched, WAL is checkpointed and the
connection closed so the copy is a whole database rather than a stale main file
beside a live sidecar, the copy is taken, and only then does a single
transaction run every step and stamp the new version.
]]
function Repository:_migrate(from)
    for v = from, self.target - 1 do
        if type(self.migrations[v]) ~= "function" then
            logger.err("FingerInk: no canvas migration from version", v)
            return nil, "migration_missing"
        end
    end

    if self.wal then
        local checkpointed, busy, log_frames, done_frames = pcall(
            self.conn.rowexec, self.conn, "PRAGMA wal_checkpoint(TRUNCATE);")
        local busy_n = tonumber(busy)
        local log_n = tonumber(log_frames)
        local done_n = tonumber(done_frames)
        if not checkpointed or busy_n == nil or log_n == nil or done_n == nil
            or busy_n ~= 0
            or not ((log_n == -1 and done_n == -1) or log_n == done_n) then
            logger.err("FingerInk: canvas WAL checkpoint did not complete:",
                checkpointed and busy or log_frames)
            return nil, "migration_checkpoint_failed"
        end
    end
    self:_disconnect()

    local dest = tostring(self.path) .. ".backup-v" .. tostring(from)
    local copied, cerr = self.backup(self.path, dest)
    if not copied then
        logger.err("FingerInk: cannot back up the canvas database:", cerr)
        return nil, "backup_failed"
    end
    logger.info("FingerInk: canvas database backed up to", dest)

    local conn, oerr = self:_connect("rwc")
    if not conn then return nil, oerr end
    local configured, config_err = self:_configureWritable()
    if not configured then return nil, config_err end

    local ok, err = pcall(function()
        conn:exec("BEGIN;")
        for v = from, self.target - 1 do
            self.migrations[v](conn)
        end
        conn:exec(string.format("PRAGMA user_version=%d;", self.target))
        conn:exec("COMMIT;")
    end)
    if not ok then
        pcall(conn.exec, conn, "ROLLBACK;")
        logger.err("FingerInk: canvas migration failed:", err)
        return nil, "migration_failed"
    end

    self.version = self.target
    logger.info("FingerInk: canvas database migrated from", from, "to", self.target)
    return true
end

function Repository:close()
    self:_disconnect()
end

-- ------------------------------------------------------------------- guards

--- nil plus a reason when the repository cannot serve this call at all.
function Repository:_ready(write)
    if not self.conn then return nil, "closed" end
    if write and self.read_only then return nil, "read_only" end
    return true
end

--[[--
Run a prepared statement and collect every row, as plain Lua values.

`map` turns one row array into whatever the caller wants; it is where `num`
gets applied, so no cdata escapes this file. The statement is always closed,
including on the failure path.
]]
function Repository:_select(sql, binds, map)
    local ok, res = pcall(function()
        local stmt = self.conn:prepare(sql)
        local out = {}
        local bind_ok, bind_err = pcall(function()
            if binds then stmt:bind(unpack(binds)) end
            while true do
                local row = stmt:step()
                if not row then break end
                out[#out + 1] = map(row)
            end
        end)
        pcall(stmt.close, stmt)
        if not bind_ok then error(bind_err, 0) end
        return out
    end)
    if not ok then
        logger.err("FingerInk: canvas query failed:", res)
        return nil, tostring(res)
    end
    return res
end

--- Run a statement for its effect. Returns true, or nil plus the message.
function Repository:_run(sql, binds)
    local ok, err = pcall(function()
        local stmt = self.conn:prepare(sql)
        local step_ok, step_err = pcall(function()
            if binds then stmt:bind(unpack(binds)) end
            stmt:step()
        end)
        pcall(stmt.close, stmt)
        if not step_ok then error(step_err, 0) end
    end)
    if not ok then
        logger.err("FingerInk: canvas statement failed:", err)
        return nil, tostring(err)
    end
    return true
end

function Repository:_lastId()
    local ok, id = pcall(function()
        return num(self.conn:rowexec("SELECT last_insert_rowid();"))
    end)
    if not ok then return nil, tostring(id) end
    return id
end

-- ------------------------------------------------------------- transactions

--[[--
Run `fn` in a transaction and commit, or roll back and report.

`fn` signals failure either by raising or by returning nil plus a reason; both
roll back. A nested call joins the outer transaction rather than opening a
second one, because SQLite has no nested BEGIN and the inner COMMIT would
otherwise end the outer transaction early.
]]
function Repository:transaction(fn)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end

    if self.depth > 0 then
        local ok, res, err = pcall(fn, self)
        if not ok then return nil, res end
        if res == nil then return nil, err end
        return res
    end

    local began, berr = pcall(self.conn.exec, self.conn, "BEGIN;")
    if not began then
        logger.err("FingerInk: cannot begin a canvas transaction:", berr)
        return nil, tostring(berr)
    end

    self.depth = 1
    local ok, res, err = pcall(fn, self)
    self.depth = 0

    if not ok or res == nil then
        pcall(self.conn.exec, self.conn, "ROLLBACK;")
        local why = ok and err or res
        logger.err("FingerInk: canvas transaction rolled back:", why)
        return nil, why
    end

    local committed, cerr = pcall(self.conn.exec, self.conn, "COMMIT;")
    if not committed then
        -- A COMMIT that raises has not necessarily left the transaction open,
        -- but assuming it succeeded is the one thing that must not happen.
        pcall(self.conn.exec, self.conn, "ROLLBACK;")
        logger.err("FingerInk: canvas commit failed:", cerr)
        return nil, tostring(cerr)
    end
    return res
end

-- ------------------------------------------------------------------- books

--- Find a book without updating last_path or creating a row. This is the only
--- identity operation allowed when a newer schema is open read-only.
function Repository:findBookId(partial_md5, file_size)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    if not partial_md5 or not file_size then return nil, "no_identity" end
    local found, err = self:_select(
        "SELECT id FROM books WHERE partial_md5 = ?1 AND file_size = ?2;",
        { partial_md5, file_size }, function(row) return num(row[1]) end)
    if not found then return nil, err end
    if not found[1] then return nil, "not_found" end
    return found[1]
end

--[[--
The row id for a book, creating it if this is the first time.

Identity is the checksum and the size. Without both, the only thing left is the
path, and keying notes on a path loses them the first time a book is renamed --
so this refuses instead.
]]
function Repository:bookId(partial_md5, file_size, last_path)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if not partial_md5 or not file_size then return nil, "no_identity" end

    local found, ferr = self:_select(
        "SELECT id FROM books WHERE partial_md5 = ?1 AND file_size = ?2;",
        { partial_md5, file_size },
        function(row) return num(row[1]) end)
    if not found then return nil, ferr end

    local now = self.now()
    if found[1] then
        -- Diagnosis only. Nothing keys off last_path.
        self:_run("UPDATE books SET last_path = ?1, updated_at = ?2 WHERE id = ?3;",
            { last_path, now, found[1] })
        return found[1]
    end

    local ok, err = self:_run([[
        INSERT INTO books (partial_md5, file_size, last_path, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5);]],
        { partial_md5, file_size, last_path, now, now })
    if not ok then return nil, err end
    return self:_lastId()
end

-- ----------------------------------------------------------------- canvases

local CANVAS_COLUMNS = [[
    SELECT id, anchor_kind, anchor_key, anchor_raw, anchor_normalized,
           anchor_dom_version, fixed_page, logical_w, logical_h, updated_at
      FROM canvases]]

local function canvasRow(row)
    return {
        id                 = num(row[1]),
        anchor_kind        = str(row[2]),
        anchor_key         = str(row[3]),
        anchor_raw         = str(row[4]),
        anchor_normalized  = str(row[5]),
        anchor_dom_version = num(row[6]),
        fixed_page         = num(row[7]),
        logical_w          = num(row[8]),
        logical_h          = num(row[9]),
        updated_at         = num(row[10]),
    }
end

--[[--
Every canvas of a book, metadata only.

This is what runs when a book opens, so it must not touch a point. The anchor
index is built from these rows; the strokes of a canvas are read only when that
canvas is opened.
]]
function Repository:listCanvases(book_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    return self:_select(
        CANVAS_COLUMNS .. " WHERE book_id = ?1 ORDER BY updated_at DESC, id;",
        { book_id }, canvasRow)
end


--[[--
Create a canvas and return its row, geometry included.

The geometry travels with the row because every coordinate transform needs it
and re-reading it per stroke would be a query per stroke.
]]
function Repository:createCanvas(book_id, spec)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if not spec or not spec.anchor_key or spec.anchor_key == "" then
        return nil, "no_anchor"
    end
    local w, h = tonumber(spec.logical_w), tonumber(spec.logical_h)
    if not finite(w) or not finite(h) or w <= 0 or h <= 0 then
        return nil, "bad_geometry"
    end

    local kind = spec.anchor_kind or "xpointer"
    local now = self.now()
    local ok, err = self:_run([[
        INSERT INTO canvases (book_id, anchor_kind, anchor_key, anchor_raw,
                              anchor_normalized, anchor_dom_version, fixed_page,
                              logical_w, logical_h, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);]],
        { book_id, kind, spec.anchor_key, spec.anchor_raw, spec.anchor_normalized,
          spec.anchor_dom_version, spec.fixed_page, w, h, now, now })
    if not ok then return nil, err end

    local id, ierr = self:_lastId()
    if not id then return nil, ierr end
    return {
        id                 = id,
        book_id            = book_id,
        anchor_kind        = kind,
        anchor_key         = spec.anchor_key,
        anchor_raw         = spec.anchor_raw,
        anchor_normalized  = spec.anchor_normalized,
        anchor_dom_version = spec.anchor_dom_version,
        fixed_page         = spec.fixed_page,
        logical_w          = w,
        logical_h          = h,
        updated_at         = now,
    }
end

function Repository:touchCanvas(canvas_id)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    return self:_run("UPDATE canvases SET updated_at = ?1 WHERE id = ?2;",
        { self.now(), canvas_id })
end

--- Delete a canvas. Its strokes, chunks and cached pages go with it through
--- the schema's cascades, which is why foreign keys are switched on.
function Repository:deleteCanvas(canvas_id)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    return self:_run("DELETE FROM canvases WHERE id = ?1;", { canvas_id })
end

-- ------------------------------------------------------------------ strokes

--- One past the highest sequence number on this canvas, and 1 on an empty one.
function Repository:nextSeq(canvas_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local rows, err = self:_select(
        "SELECT MAX(seq) FROM strokes WHERE canvas_id = ?1;",
        { canvas_id }, function(row) return num(row[1]) or 0 end)
    if not rows then return nil, err end
    return (rows[1] or 0) + 1
end

--[[--
Write one stroke: a metadata row plus its chunks, in a single transaction.

The bounding box is computed here, once, because it is what the spatial index
and regional repainting are built on and recomputing it from points would mean
decoding a stroke to find out where it is.
]]
function Repository:addStroke(canvas, stroke)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end

    local n = tonumber(stroke.n) or 0
    local valid, validation_err = Codec.validate(stroke.points, n,
        canvas.logical_w, canvas.logical_h)
    if not valid then return nil, validation_err end
    local min_x, min_y = stroke.points[1], stroke.points[2]
    local max_x, max_y = min_x, min_y
    for i = 2, n do
        local x, y = stroke.points[i * 2 - 1], stroke.points[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end

    local seq = stroke.seq
    if not seq then
        seq = self:nextSeq(canvas.id)
        if not seq then return nil, "no_seq" end
    end

    return self:transaction(function()
        local ok, err = self:_run([[
            INSERT INTO strokes (canvas_id, seq, width, tool, codec, point_count,
                                 min_x, min_y, max_x, max_y, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);]],
            { canvas.id, seq, stroke.width, stroke.tool, Codec.VERSION, n,
              min_x, min_y, max_x, max_y, self.now() })
        if not ok then return nil, err end

        local id, ierr = self:_lastId()
        if not id then return nil, ierr end

        local encoded, eerr = Codec.eachEncodedChunk(stroke.points, n,
            canvas.logical_w, canvas.logical_h,
            function(chunk_no, point_count, blob)
                -- The cast is what makes this a blob rather than a TEXT value
                -- that SQL would read as one byte long.
                local cok, cerr2 = self:_run([[
                INSERT INTO stroke_chunks (stroke_id, chunk_no, point_count, points)
                VALUES (?1, ?2, ?3, CAST(?4 AS BLOB));]],
                    { id, chunk_no, point_count, blob })
                if not cok then return nil, cerr2 end
                return true
            end)
        if not encoded then return nil, eerr end
        return id
    end)
end

--- Metadata for every stroke of a canvas, in drawing order. No points.
function Repository:listStrokes(canvas_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    return self:_select([[
        SELECT id, seq, width, tool, codec, point_count, min_x, min_y, max_x, max_y
          FROM strokes WHERE canvas_id = ?1 ORDER BY seq;]],
        { canvas_id },
        function(row)
            return {
                id          = num(row[1]),
                seq         = num(row[2]),
                width       = num(row[3]),
                tool        = num(row[4]),
                codec       = num(row[5]),
                point_count = num(row[6]),
                min_x       = num(row[7]),
                min_y       = num(row[8]),
                max_x       = num(row[9]),
                max_y       = num(row[10]),
            }
        end)
end

--[[--
Stream one stroke's chunk rows without materialising the complete payload.

`CAST(points AS TEXT)` is the other half of the blob story: it hands the driver
a value it returns as a Lua string, rather than a pointer the caller would have
to reach into with FFI.
]]
function Repository:openStrokeCursor(stroke_id)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local stmt
    local ok, err = pcall(function()
        stmt = self.conn:prepare([[
        SELECT chunk_no, point_count, CAST(points AS TEXT)
          FROM stroke_chunks WHERE stroke_id = ?1 ORDER BY chunk_no;]])
        stmt:bind(stroke_id)
    end)
    if not ok then
        if stmt then pcall(stmt.close, stmt) end
        logger.err("FingerInk: cannot open canvas stroke cursor:", err)
        return nil, tostring(err)
    end

    local cursor = { stmt = stmt, closed = false }
    function cursor:close()
        if self.closed then return true end
        self.closed = true
        local closed, cerr = pcall(self.stmt.close, self.stmt)
        self.stmt = nil
        if not closed then return nil, tostring(cerr) end
        return true
    end
    function cursor:next()
        if self.closed then return nil, "closed" end
        local stepped, row = pcall(self.stmt.step, self.stmt)
        if not stepped then
            self:close()
            return nil, tostring(row)
        end
        if not row then
            local closed, close_err = self:close()
            if not closed then return nil, close_err end
            return nil, nil, true
        end
        return {
            chunk_no = num(row[1]),
            point_count = num(row[2]),
            points = row[3],
        }
    end
    return cursor
end

function Repository:readStrokeChunk(stroke_id, chunk_no)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local rows, err = self:_select([[
        SELECT chunk_no, point_count, CAST(points AS TEXT)
          FROM stroke_chunks WHERE stroke_id = ?1 AND chunk_no = ?2;]],
        { stroke_id, chunk_no },
        function(row)
            return { chunk_no = num(row[1]), point_count = num(row[2]), points = row[3] }
        end)
    if not rows then return nil, err end
    if not rows[1] then return nil, "missing_chunk" end
    return rows[1]
end

function Repository:readStroke(canvas, meta)
    local cursor, err = self:openStrokeCursor(meta.id)
    if not cursor then return nil, err end
    local chunks = {}
    while true do
        local row, rerr, done = cursor:next()
        if rerr then return nil, rerr end
        if done then break end
        chunks[#chunks + 1] = row
    end
    return Codec.join(chunks, canvas.logical_w, canvas.logical_h)
end

function Repository:deleteStroke(stroke_id)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    return self:_run("DELETE FROM strokes WHERE id = ?1;", { stroke_id })
end

-- ------------------------------------------------------------- layout cache

--[[--
Which page each canvas of this book resolved to, the last time the book was
laid out this way.

Purely derived: a miss costs an xpointer resolution, never a wrong answer. The
hash is `getDocumentRenderingHash(true)`, so a font or margin change simply
makes every entry a miss.
]]
function Repository:layoutPages(book_id, layout_hash)
    local ready, reason = self:_ready(false)
    if not ready then return nil, reason end
    local rows, err = self:_select([[
        SELECT canvas_id, resolved_page FROM canvas_layout_cache
         WHERE book_id = ?1 AND layout_hash = ?2;]],
        { book_id, layout_hash },
        function(row) return { num(row[1]), num(row[2]) } end)
    if not rows then return nil, err end
    local pages = {}
    for i = 1, #rows do pages[rows[i][1]] = rows[i][2] end
    return pages
end

--[[--
Store one bounded resolved-page batch. The final batch also prunes everything
but the two newest layouts of this book. Direct callers that omit `finalize`
retain the original whole-map behaviour.

Two, not one: trying a font size and going back should not throw away the index
that was just built. More than two would let a table of derived data grow with
every typography experiment the reader ever makes.
]]
function Repository:saveLayoutPages(book_id, layout_hash, pages, finalize)
    local ready, reason = self:_ready(true)
    if not ready then return nil, reason end
    if next(pages) == nil and finalize == nil then return true end
    if finalize == nil then finalize = true end
    if next(pages) == nil and not finalize then return true end

    local now = self.now()
    return self:transaction(function()
        local stmt
        local written, write_err = pcall(function()
            stmt = self.conn:prepare([[
                INSERT OR REPLACE INTO canvas_layout_cache
                    (canvas_id, book_id, layout_hash, resolved_page, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5);]])
            for canvas_id, page in pairs(pages) do
                stmt:reset():bind(canvas_id, book_id, layout_hash, page, now):step()
            end
        end)
        if stmt then pcall(stmt.close, stmt) end
        if not written then return nil, tostring(write_err) end

        if finalize then
            return self:_run([[
                DELETE FROM canvas_layout_cache
                 WHERE book_id = ?1
                   AND layout_hash NOT IN (
                       SELECT layout_hash FROM canvas_layout_cache
                        WHERE book_id = ?1
                        GROUP BY layout_hash
                        ORDER BY MAX(updated_at) DESC
                        LIMIT 2);]],
                { book_id })
        end
        return true
    end)
end

return Repository
