--[[--
The canvas repository's control flow.

The driver underneath is a recorder, not an SQL engine, so nothing here is
evidence that a statement parses or that a constraint fires -- that is what the
real-SQLite section of tests/conformance.lua is for. What these cases pin down
is the part a database cannot check for us: the order of BEGIN/COMMIT/ROLLBACK,
that a backup happens before a migration and never after, that a newer schema
is opened read-only instead of being rewritten, that the listing query does not
drag point data into memory, and that an integer crossing the driver boundary
arrives as a Lua number rather than as an int64 the rest of the plugin would
silently mis-key a table with.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Repository = require("ink_canvas_repository")
    local Codec = require("ink_canvas_codec")

    local PATH = "/tmp/justdraw-test.sqlite3"

    --- A repository over a fresh recorder, already past schema creation.
    local function openRepo(opts)
        opts = opts or {}
        local driver = support.newSqlDriver{
            int64 = opts.int64,
            fail_on = opts.fail_on,
            on_open = function(conn)
                local version = opts.user_version
                if version == nil then version = Repository.SCHEMA_VERSION end
                conn:answer("PRAGMA user_version", { { version } })
                if opts.answers then opts.answers(conn) end
            end,
        }
        local repo, err = Repository.open{
            path = PATH,
            driver = driver,
            wal = opts.wal ~= false,
            now = function() return 4242 end,
            backup = opts.backup,
            migrations = opts.migrations,
        }
        return repo, driver, err
    end

    local CANVAS = {
        id = 3, logical_w = 1860, logical_h = 2480,
        anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
    }

    -- =================================================================
    t:describe("ink_canvas_repository / opening")

    t:case("a fresh database gets the schema and the version stamp", function()
        local repo, driver = openRepo{ user_version = 0 }
        t:check(repo ~= nil, "opened")
        local conn = driver.last()
        t:check(conn:saw("CREATE TABLE books"), "books")
        t:check(conn:saw("CREATE TABLE canvases"), "canvases")
        t:check(conn:saw("CREATE TABLE canvas_layout_cache"), "layout cache")
        t:check(conn:saw("CREATE TABLE strokes"), "strokes")
        t:check(conn:saw("CREATE TABLE stroke_chunks"), "stroke chunks")
        t:check(conn:saw("PRAGMA user_version=" .. Repository.SCHEMA_VERSION),
            "stamped with the schema version")
        t:check(conn:indexOf("BEGIN") < conn:indexOf("CREATE TABLE books"),
            "DDL starts inside the transaction")
        t:check(conn:indexOf("PRAGMA user_version=") < conn:indexOf("COMMIT"),
            "the stamp commits with the tables")
        t:eq(repo.version, Repository.SCHEMA_VERSION, "and reports it")
    end)

    t:case("the database opens at the path it was given", function()
        local _, driver = openRepo()
        t:eq(driver.opened[1], PATH, "no other file is touched")
    end)

    t:case("foreign keys are turned on, because the schema relies on cascades", function()
        local _, driver = openRepo()
        t:check(driver.last():saw("PRAGMA foreign_keys=ON"), "on this connection")
    end)

    t:case("WAL is used when the device allows it and TRUNCATE when it does not", function()
        local _, wal = openRepo{ wal = true }
        t:check(wal.last():saw("journal_mode=WAL"), "WAL")
        local _, trunc = openRepo{ wal = false }
        t:check(trunc.last():saw("journal_mode=TRUNCATE"), "TRUNCATE")
        t:eq(trunc.last():saw("journal_mode=WAL"), false, "and not both")
    end)

    t:case("synchronous is never turned off", function()
        local _, driver = openRepo()
        t:eq(driver.last():saw("synchronous=OFF"), false,
            "durability is not traded for speed behind the user's back")
    end)

    t:case("an existing database at the current version is left alone", function()
        local repo, driver = openRepo{ user_version = Repository.SCHEMA_VERSION }
        t:eq(driver.last():saw("CREATE TABLE"), false, "no schema rewrite")
        t:eq(repo.read_only, false, "and it is writable")
    end)

    t:case("a database from the future is opened read-only, not rewritten", function()
        local repo, driver = openRepo{ user_version = Repository.SCHEMA_VERSION + 5 }
        t:check(repo ~= nil, "still opens -- the user's notes are still readable")
        t:eq(repo.read_only, true, "but nothing may be written")
        t:eq(driver.last():saw("CREATE TABLE"), false, "and the schema is not recreated")
        t:eq(driver.last():saw("PRAGMA user_version="), false, "nor downgraded")
        t:check(repo.read_only_reason ~= nil, "with a reason to show the user")
        t:eq(driver.modes[#driver.modes], "ro", "the live connection is SQLite read-only")
        t:eq(driver.last():saw("journal_mode"), false,
            "and does not mutate the future database's journal")
    end)

    t:case("every write is refused while read-only", function()
        local repo = openRepo{ user_version = Repository.SCHEMA_VERSION + 5 }
        local _, e1 = repo:bookId("md5", 10, "/x")
        t:eq(e1, "read_only", "bookId")
        local _, e2 = repo:createCanvas(1, { anchor_key = "k", logical_w = 1, logical_h = 1 })
        t:eq(e2, "read_only", "createCanvas")
        local _, e3 = repo:addStroke(CANVAS, { width = 4, tool = 1, points = { 1, 1 }, n = 1 })
        t:eq(e3, "read_only", "addStroke")
        local _, e4 = repo:deleteCanvas(1)
        t:eq(e4, "read_only", "deleteCanvas")
    end)

    t:case("a driver that cannot be reached is reported, not swallowed", function()
        local repo, err = Repository.open{ path = PATH, driver = false }
        t:eq(repo, nil, "no repository")
        t:eq(err, "no_driver", "and the caller can say why")
    end)

    t:case("a database that fails to open is not recreated", function()
        local driver = { opened = {} }
        function driver.open() error("disk I/O error", 0) end
        local repo, err = Repository.open{ path = PATH, driver = driver }
        t:eq(repo, nil, "no repository")
        t:eq(err, "open_failed", "reported")
    end)

    t:case("a schema that fails to create closes the connection behind it", function()
        local repo, driver, err = openRepo{ user_version = 0, fail_on = "CREATE TABLE" }
        t:eq(repo, nil, "no repository")
        t:eq(err, "schema_failed", "reported")
        t:eq(driver.last().closed, true, "and no connection is left dangling")
        t:check(driver.last():saw("ROLLBACK"), "partial DDL was rolled back")
    end)

    t:case("a version-zero database with tables is preserved for diagnosis", function()
        local repo, driver, err = openRepo{
            user_version = 0,
            answers = function(conn)
                conn:answer("FROM sqlite_master", { { "books" } })
            end,
        }
        t:eq(repo, nil, "not recreated")
        t:eq(err, "schema_failed", "partial schema reported")
        t:eq(driver.last():saw("CREATE TABLE"), false, "no destructive guess")
        t:eq(driver.last():saw("DROP TABLE"), false, "nothing was dropped")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / migration")

    --[[
    The schema target and the migration ladder are injectable. Today's
    SCHEMA_VERSION is 1, so there is no real step to run; without injection the
    whole migration path -- backup, ordering, rollback, the refusal on a gap --
    would ship untested and first be exercised on a reader's notes.
    ]]
    local function migratingRepo(extra)
        extra = extra or {}
        local backups, ran = {}, {}
        local driver
        driver = ctx.support.newSqlDriver{
            fail_on = extra.fail_on,
            on_open = function(conn)
                conn:answer("PRAGMA user_version", { { extra.user_version or 1 } })
                if extra.checkpoint then
                    conn:answer("wal_checkpoint", { extra.checkpoint })
                end
            end,
        }
        local repo, err = Repository.open{
            path = PATH,
            driver = driver,
            wal = true,
            now = function() return 4242 end,
            schema_version = extra.schema_version or 2,
            migrations = extra.migrations or {
                [1] = function(conn)
                    ran[#ran + 1] = 1
                    conn:exec("ALTER TABLE canvases ADD COLUMN probe INTEGER")
                end,
            },
            backup = extra.backup or function(src, dest)
                local live = driver.conns[#driver.conns]
                backups[#backups + 1] = {
                    src = src,
                    dest = dest,
                    conns = #driver.conns,
                    closed = live.closed,
                    wrote = live:saw("ALTER TABLE") or live:saw("BEGIN"),
                }
                return true
            end,
        }
        return repo, driver, backups, ran, err
    end

    t:case("an older database is migrated up to the current schema", function()
        local repo, driver, _, ran = migratingRepo()
        t:check(repo ~= nil, "opened")
        t:eq(#ran, 1, "the step ran")
        t:eq(repo.version, 2, "reaching the target version")
        t:check(driver.last():saw("PRAGMA user_version=2"), "and stamped")
    end)

    t:case("the backup is taken with the live database closed, before anything is written", function()
        local _, _, backups = migratingRepo()
        t:eq(#backups, 1, "exactly one backup")
        t:eq(backups[1].src, PATH, "of the live database")
        t:check(backups[1].dest ~= PATH, "written somewhere else")
        t:eq(backups[1].conns, 1, "before a second connection exists")
        t:eq(backups[1].closed, true,
            "with the connection closed, so a WAL sidecar is not left out of the copy")
        t:eq(backups[1].wrote, false, "and before a single migration statement")
    end)

    t:case("WAL is checkpointed before the copy, so the copy is complete", function()
        local _, driver = migratingRepo()
        t:check(driver.conns[1]:saw("wal_checkpoint"), "checkpointed")
    end)

    t:case("a busy WAL checkpoint aborts before copying the main file", function()
        local repo, _, backups, ran, err = migratingRepo{
            checkpoint = { 1, 12, 7 },
        }
        t:eq(repo, nil, "migration refused")
        t:eq(err, "migration_checkpoint_failed", "with the durable reason")
        t:eq(#backups, 0, "no incomplete backup was made")
        t:eq(#ran, 0, "and no migration ran")
    end)

    t:case("a checkpoint without all three result columns is refused", function()
        local repo, _, backups, ran, err = migratingRepo{
            checkpoint = { 0 },
        }
        t:eq(repo, nil, "migration refused")
        t:eq(err, "migration_checkpoint_failed", "frame counts are mandatory")
        t:eq(#backups, 0, "no ambiguous main-file copy was made")
        t:eq(#ran, 0, "and no migration ran")
    end)

    t:case("the migration runs inside a transaction", function()
        local _, driver = migratingRepo()
        local conn = driver.last()
        local begin_at = conn:indexOf("BEGIN")
        local alter_at = conn:indexOf("ALTER TABLE canvases ADD COLUMN probe")
        local commit_at = conn:indexOf("COMMIT")
        t:check(begin_at and alter_at and commit_at, "all three happened")
        t:check(begin_at < alter_at and alter_at < commit_at, "in that order")
    end)

    t:case("the version stamp is inside the transaction with the step it describes", function()
        local _, driver = migratingRepo()
        local conn = driver.last()
        t:check(conn:indexOf("PRAGMA user_version=2") < conn:indexOf("COMMIT"),
            "so a crash cannot leave a stamp without its migration")
    end)

    t:case("a failed migration rolls back and refuses to open", function()
        local repo, driver, _, _, err = migratingRepo{ fail_on = "ALTER TABLE" }
        t:eq(repo, nil, "no repository")
        t:eq(err, "migration_failed", "reported")
        t:check(driver.last():saw("ROLLBACK"), "and the transaction was rolled back")
        t:eq(driver.last():saw("PRAGMA user_version=2"), false, "version not stamped")
    end)

    t:case("a backup that fails stops the migration before it starts", function()
        local repo, driver, _, ran, err = migratingRepo{
            backup = function() return nil, "no space left" end,
        }
        t:eq(repo, nil, "no repository")
        t:eq(err, "backup_failed", "reported")
        t:eq(#ran, 0, "and nothing was migrated")
        t:eq(driver.last():saw("ALTER TABLE"), false, "not one statement")
    end)

    t:case("a gap in the ladder is a refusal, not a silent skip", function()
        local repo, _, _, ran, err = migratingRepo{ schema_version = 3 }
        t:eq(repo, nil, "no repository")
        t:eq(err, "migration_missing", "the ladder has to be complete")
        t:eq(#ran, 0, "and the half of it that does exist is not applied either")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / books and canvases")

    t:case("a book is identified by checksum and size, never by path", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("SELECT id FROM books", { { 12 } })
            end,
        }
        local id = repo:bookId("d41d8c", 90210, "/mnt/us/documents/a.epub")
        t:eq(id, 12, "the existing row is found")
        local binds = driver.last():bindsFor("SELECT id FROM books")
        t:eq(binds[1], "d41d8c", "checksum is bound")
        t:eq(binds[2], 90210, "size is bound")
        t:eq(#binds, 2, "and nothing else identifies the book")
    end)

    t:case("an unknown book is inserted and its new id returned", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("SELECT id FROM books", {})
                conn:answer("last_insert_rowid", { { 77 } })
            end,
        }
        t:eq(repo:bookId("abc", 5, "/x.epub"), 77, "new id")
        t:check(driver.last():saw("INSERT INTO books"), "inserted")
    end)

    t:case("read-only book lookup neither inserts nor updates", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("SELECT id FROM books", { { 12 } })
            end,
        }
        t:eq(repo:findBookId("abc", 5), 12, "found")
        t:eq(driver.last():saw("INSERT INTO books"), false, "no insert")
        t:eq(driver.last():saw("UPDATE books"), false, "no path update")
    end)

    t:case("the path is recorded for diagnosis but is not the key", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("SELECT id FROM books", { { 12 } })
            end,
        }
        repo:bookId("abc", 5, "/mnt/us/x.epub")
        local binds = driver.last():bindsFor("UPDATE books SET last_path")
        t:check(binds ~= nil, "the row's last_path is refreshed")
        t:eq(binds[1], "/mnt/us/x.epub", "with the current path")
    end)

    t:case("a book with no checksum is refused rather than keyed on its path", function()
        local repo = openRepo()
        local id, err = repo:bookId(nil, 5, "/x.epub")
        t:eq(id, nil, "no id")
        t:eq(err, "no_identity", "renaming a book must not orphan its notes")
        local id2, err2 = repo:bookId("abc", nil, "/x.epub")
        t:eq(id2, nil, "size matters too")
        t:eq(err2, "no_identity", "same reason")
    end)

    t:case("listing canvases never selects point data", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("FROM canvases", {
                    { 3, "xpointer", "xp:/body/p[7]", "raw", "norm", 20240101, nil, 1860, 2480, 4242 },
                })
            end,
        }
        local list = repo:listCanvases(12)
        t:eq(#list, 1, "one canvas")
        local sql = driver.last():statement("FROM canvases")
        t:check(sql ~= nil, "the listing query ran")
        t:eq(sql:find("stroke_chunks"), nil, "the chunk table is not joined")
        t:eq(sql:find("points"), nil, "and the points column is not named")
    end)

    t:case("a listed canvas carries everything the index needs and nothing more", function()
        local repo = openRepo{
            answers = function(conn)
                conn:answer("FROM canvases", {
                    { 3, "xpointer", "xp:/body/p[7]", "raw", "norm", 20240101, nil, 1860, 2480, 4242 },
                })
            end,
        }
        local c = repo:listCanvases(12)[1]
        t:eq(c.id, 3, "id")
        t:eq(c.anchor_kind, "xpointer", "kind")
        t:eq(c.anchor_key, "xp:/body/p[7]", "key")
        t:eq(c.anchor_raw, "raw", "raw xpointer")
        t:eq(c.anchor_normalized, "norm", "normalised xpointer")
        t:eq(c.anchor_dom_version, 20240101, "dom version")
        t:eq(c.logical_w, 1860, "width")
        t:eq(c.logical_h, 2480, "height")
    end)

    t:case("integers come back as Lua numbers, not as int64 from the driver", function()
        -- The bug this closes is invisible until something uses an id as a
        -- table key: 1LL == 1 is true, but t[1LL] and t[1] are different
        -- slots, so a page index built from raw driver output silently loses
        -- every lookup.
        local repo = openRepo{
            int64 = true,
            answers = function(conn)
                conn:answer("FROM canvases", {
                    { 3, "xpointer", "k", nil, nil, nil, nil, 1860, 2480, 4242 },
                })
            end,
        }
        local c = repo:listCanvases(12)[1]
        t:eq(type(c.id), "number", "id is a number")
        t:eq(type(c.logical_w), "number", "so is the geometry")
        local index = {}
        index[c.id] = true
        t:eq(index[3], true, "and it keys a table the way a number does")
    end)

    t:case("creating a canvas returns the row, geometry included", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("last_insert_rowid", { { 31 } })
            end,
        }
        local c = repo:createCanvas(12, {
            anchor_kind = "xpointer",
            anchor_key = "xp:/body/p[7]",
            anchor_raw = "/body/p[7]",
            anchor_normalized = "/body/DocFragment[3]/p[7]",
            anchor_dom_version = 20240101,
            logical_w = 1860,
            logical_h = 2480,
        })
        t:eq(c.id, 31, "the new id")
        t:eq(c.logical_w, 1860, "and the geometry the caller has to keep using")
        t:check(driver.last():saw("INSERT INTO canvases"), "written")
    end)

    t:case("a canvas with no anchor key is refused", function()
        local repo = openRepo()
        local c, err = repo:createCanvas(12, { logical_w = 10, logical_h = 10 })
        t:eq(c, nil, "not created")
        t:eq(err, "no_anchor", "a canvas that cannot be found again is not worth writing")
    end)

    t:case("a canvas with no area is refused", function()
        local repo = openRepo()
        local _, err = repo:createCanvas(12, { anchor_key = "k", logical_w = 0, logical_h = 10 })
        t:eq(err, "bad_geometry", "zero width")
        local _, infinite = repo:createCanvas(12, {
            anchor_key = "inf", logical_w = math.huge, logical_h = 10,
        })
        t:eq(infinite, "bad_geometry", "infinite geometry")
    end)

    t:case("deleting a canvas leaves the cascade to do the rest", function()
        local repo, driver = openRepo()
        t:eq(repo:deleteCanvas(3), true, "deleted")
        local conn = driver.last()
        t:check(conn:saw("DELETE FROM canvases"), "the canvas row goes")
        t:eq(conn:saw("DELETE FROM strokes"), false,
            "and its strokes are not deleted by hand -- that is the cascade's job")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / strokes")

    t:case("a stroke is written as metadata plus chunks", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("last_insert_rowid", { { 55 } })
            end,
        }
        local id = repo:addStroke(CANVAS, {
            seq = 1, width = 4, tool = 1,
            points = { 10, 20, 30, 40 }, n = 2,
        })
        t:eq(id, 55, "the new stroke id")
        local conn = driver.last()
        t:check(conn:saw("INSERT INTO strokes"), "metadata row")
        t:check(conn:saw("INSERT INTO stroke_chunks"), "and its chunks")
    end)

    t:case("the bounding box is computed once, on the way in", function()
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 1 } }) end,
        }
        repo:addStroke(CANVAS, {
            seq = 1, width = 4, tool = 1,
            points = { 100, 900, 30, 40, 250, 500 }, n = 3,
        })
        local binds = driver.last():bindsFor("INSERT INTO strokes")
        -- canvas_id, seq, width, tool, codec, point_count, min_x, min_y, max_x, max_y, created_at
        t:eq(binds[6], 3, "point count")
        t:eq(binds[7], 30, "min x")
        t:eq(binds[8], 40, "min y")
        t:eq(binds[9], 250, "max x")
        t:eq(binds[10], 900, "max y")
    end)

    t:case("the codec version is recorded with the stroke", function()
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 1 } }) end,
        }
        repo:addStroke(CANVAS, { seq = 1, width = 4, tool = 1, points = { 1, 2 }, n = 1 })
        local binds = driver.last():bindsFor("INSERT INTO strokes")
        t:eq(binds[5], Codec.VERSION, "so a future format can still read this row")
    end)

    t:case("the point blob is bound as a blob, not as text", function()
        -- The driver binds Lua strings as TEXT even into a BLOB column, and a
        -- TEXT value stops at its first NUL for length() and for any SQL that
        -- touches it. The cast is what makes the stored value a real blob.
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 1 } }) end,
        }
        repo:addStroke(CANVAS, { seq = 1, width = 4, tool = 1, points = { 1, 2 }, n = 1 })
        t:check(driver.last():saw("CAST%(%?4 AS BLOB%)"),
            "the chunk insert casts the payload")
    end)

    t:case("a stroke that spans chunks is written as several rows in order", function()
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 1 } }) end,
        }
        local n = Codec.MAX_POINTS + 500
        local points = {}
        for i = 1, n do points[#points + 1] = i % 1000; points[#points + 1] = i % 900 end
        repo:addStroke(CANVAS, { seq = 1, width = 4, tool = 1, points = points, n = n })

        local chunk_no = {}
        for _, e in ipairs(driver.last().log) do
            if e.op == "step" and e.sql:find("INSERT INTO stroke_chunks") then
                chunk_no[#chunk_no + 1] = e.values[2]
            end
        end
        t:eq(#chunk_no, Codec.chunkCount(n), "one row per chunk")
        t:eq(chunk_no[1], 0, "numbered from zero")
        t:eq(chunk_no[2], 1, "and in order")
    end)

    t:case("an empty stroke is refused before any row is written", function()
        local repo, driver = openRepo()
        local id, err = repo:addStroke(CANVAS, { seq = 1, width = 4, tool = 1, points = {}, n = 0 })
        t:eq(id, nil, "not written")
        t:eq(err, "empty", "the codec's refusal is passed through")
        t:eq(driver.last():saw("INSERT INTO strokes"), false, "and no orphan metadata row")
    end)

    t:case("listing strokes returns metadata with no points", function()
        local repo, driver = openRepo{
            answers = function(conn)
                conn:answer("FROM strokes", {
                    { 55, 1, 4, 1, 1, 2, 10, 20, 30, 40 },
                    { 56, 2, 4, 2, 1, 5, 0, 0, 100, 100 },
                })
            end,
        }
        local list = repo:listStrokes(3)
        t:eq(#list, 2, "two strokes")
        t:eq(list[1].id, 55, "id")
        t:eq(list[1].seq, 1, "seq")
        t:eq(list[2].tool, 2, "tool")
        t:eq(list[1].max_y, 40, "bounding box comes with the metadata")
        t:eq(driver.last():statement("FROM strokes"):find("stroke_chunks"), nil,
            "and no chunk is read")
    end)

    t:case("reading a stroke decodes exactly the chunks of that stroke", function()
        local points = { 100, 200, 300, 400, 500, 600 }
        local chunks = Codec.encode(points, 3, CANVAS.logical_w, CANVAS.logical_h)
        local repo = openRepo{
            answers = function(conn)
                conn:answer("FROM stroke_chunks", { { 0, 3, chunks[1].points } })
            end,
        }
        local got, n = repo:readStroke(CANVAS, { id = 55, point_count = 3 })
        t:eq(n, 3, "three points")
        t:check(math.abs(got[1] - 100) < 0.1, "x0")
        t:check(math.abs(got[6] - 600) < 0.1, "y2")
    end)

    t:case("the production cursor yields one normalized chunk at a time", function()
        local chunks = Codec.encode({ 10, 20, 30, 40 }, 2,
            CANVAS.logical_w, CANVAS.logical_h)
        local repo = openRepo{
            int64 = true,
            answers = function(conn)
                conn:answer("FROM stroke_chunks", { { 0, 2, chunks[1].points } })
            end,
        }
        local cursor = repo:openStrokeCursor(55)
        local row = cursor:next()
        t:eq(type(row.chunk_no), "number", "chunk number normalized")
        t:eq(type(row.point_count), "number", "point count normalized")
        local none, err, done = cursor:next()
        t:eq(none, nil, "EOF")
        t:eq(err, nil, "is not an error")
        t:eq(done, true, "and is explicit")
        t:eq(cursor:close(), true, "close remains idempotent")
    end)

    t:case("a stroke whose chunks are missing is reported, not drawn as empty", function()
        local repo = openRepo{
            answers = function(conn) conn:answer("FROM stroke_chunks", {}) end,
        }
        local got, err = repo:readStroke(CANVAS, { id = 55, point_count = 3 })
        t:eq(got, nil, "nothing decoded")
        t:eq(err, "empty", "and the caller hears about it")
    end)

    t:case("the next sequence number continues from the highest stored", function()
        local repo = openRepo{
            answers = function(conn) conn:answer("MAX%(seq%)", { { 9 } }) end,
        }
        t:eq(repo:nextSeq(3), 10, "one past the last")
    end)

    t:case("the first stroke on an empty canvas is sequence one", function()
        local repo = openRepo{
            answers = function(conn) conn:answer("MAX%(seq%)", { { nil } }) end,
        }
        t:eq(repo:nextSeq(3), 1, "not zero, and not nil")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / transactions")

    t:case("a successful body is committed", function()
        local repo, driver = openRepo()
        local ok = repo:transaction(function() return true end)
        t:eq(ok, true, "reported as done")
        local conn = driver.last()
        t:check(conn:indexOf("BEGIN") < conn:indexOf("COMMIT"), "begin then commit")
        t:eq(conn:saw("ROLLBACK"), false, "and no rollback")
    end)

    t:case("a raising body rolls back and the error comes out", function()
        local repo, driver = openRepo()
        local ok, err = repo:transaction(function() error("boom", 0) end)
        t:eq(ok, nil, "not done")
        t:check(tostring(err):find("boom"), "the original error survives")
        t:check(driver.last():saw("ROLLBACK"), "rolled back")
        t:eq(driver.last():saw("COMMIT"), false, "and never committed")
    end)

    t:case("a body that returns nil plus a reason rolls back too", function()
        local repo, driver = openRepo()
        local ok, err = repo:transaction(function() return nil, "gave up" end)
        t:eq(ok, nil, "not done")
        t:eq(err, "gave up", "the reason is passed through")
        t:check(driver.last():saw("ROLLBACK"), "rolled back")
    end)

    t:case("a failing COMMIT is reported rather than assumed to have worked", function()
        local repo, driver = openRepo{ fail_on = "COMMIT" }
        local ok, err = repo:transaction(function() return true end)
        t:eq(ok, nil, "not done")
        t:check(err ~= nil, "with a reason")
        t:check(driver.last():saw("ROLLBACK"), "and an attempt to unwind")
    end)

    t:case("transactions do not nest", function()
        local repo, driver = openRepo()
        repo:transaction(function()
            repo:transaction(function() return true end)
            return true
        end)
        local begins = 0
        for _, sql in ipairs(driver.last():sqlLog()) do
            if sql:find("BEGIN") then begins = begins + 1 end
        end
        t:eq(begins, 1, "the inner one joins the outer")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / layout cache")

    t:case("a known layout is read straight back as a page map", function()
        local repo = openRepo{
            answers = function(conn)
                conn:answer("FROM canvas_layout_cache", { { 3, 41 }, { 4, 87 } })
            end,
        }
        local pages = repo:layoutPages(12, "hash-a")
        t:eq(pages[3], 41, "first canvas")
        t:eq(pages[4], 87, "second canvas")
    end)

    t:case("layout keys are numbers, so a page lookup actually finds them", function()
        local repo = openRepo{
            int64 = true,
            answers = function(conn)
                conn:answer("FROM canvas_layout_cache", { { 3, 41 } })
            end,
        }
        local pages = repo:layoutPages(12, "hash-a")
        t:eq(pages[3], 41, "keyed by a Lua number")
    end)

    t:case("saving a layout writes in one transaction", function()
        local repo, driver = openRepo()
        repo:saveLayoutPages(12, "hash-a", { [3] = 41, [4] = 87 })
        local conn = driver.last()
        t:check(conn:saw("BEGIN"), "transactional")
        t:check(conn:saw("INSERT"), "and it writes")
        t:check(conn:indexOf("BEGIN") < conn:indexOf("COMMIT"), "committed at the end")
    end)

    t:case("a layout batch prepares its insert once", function()
        local repo, driver = openRepo()
        repo:saveLayoutPages(12, "hash-a", {
            [1] = 11, [2] = 12, [3] = 13, [4] = 14,
        }, false)
        local prepares = 0
        for _, entry in ipairs(driver.last().log) do
            if entry.op == "prepare" and entry.sql:find("INSERT OR REPLACE") then
                prepares = prepares + 1
            end
        end
        t:eq(prepares, 1, "all rows reuse one lua-ljsqlite3 statement")
    end)

    t:case("saving a layout prunes older ones in the same transaction", function()
        local repo, driver = openRepo()
        repo:saveLayoutPages(12, "hash-a", { [3] = 41 })
        local conn = driver.last()
        local prune = conn:indexOf("DELETE FROM canvas_layout_cache")
        t:check(prune ~= nil, "old layouts are pruned")
        t:check(prune < conn:indexOf("COMMIT"), "inside the transaction")
    end)

    t:case("an empty page map is not written at all", function()
        local repo, driver = openRepo()
        repo:saveLayoutPages(12, "hash-a", {})
        t:eq(driver.last():saw("BEGIN"), false, "nothing to do, nothing done")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / closing")

    t:case("closing closes the connection once and stays closed", function()
        local repo, driver = openRepo()
        repo:close()
        t:eq(driver.last().closed, true, "closed")
        repo:close()
        t:eq(repo.conn, nil, "and a second close is harmless")
    end)

    t:case("a closed repository refuses work instead of raising", function()
        local repo = openRepo()
        repo:close()
        local _, err = repo:listCanvases(12)
        t:eq(err, "closed", "reads too, not only writes")
    end)

    t:case("a statement that raises leaves the repository usable and reports", function()
        local repo, driver = openRepo{ fail_on = "FROM canvases" }
        local list, err = repo:listCanvases(12)
        t:eq(list, nil, "no result")
        t:check(err ~= nil, "a reason")
        t:eq(driver.last().closed, false, "and the database stays open")
    end)
end
