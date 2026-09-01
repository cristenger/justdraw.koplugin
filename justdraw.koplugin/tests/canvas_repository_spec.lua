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

    -- =================================================================
    t:describe("ink_canvas_repository / schema v2")

    --[[
    The v1 schema, frozen.

    Copied out of the module before the surface columns were added, and
    deliberately *not* derived from `Repository.SCHEMA`: a constant that tracks
    the module can never notice that the fresh schema and the migration have
    drifted apart, which is the one thing a reader's existing database depends
    on.
    ]]
    local V1_SCHEMA = [[
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

    --- Alignment inside the DDL is cosmetic; the declaration is not.
    local function squash(s) return (tostring(s):gsub("%s+", " ")) end

    --- Every statement `MIGRATIONS[1]` executes, in order, against a
    --- connection that records and runs nothing.
    local function migrationStatements()
        local seen = {}
        local conn = {}
        function conn:exec(sql) seen[#seen + 1] = sql end
        Repository.MIGRATIONS[1](conn)
        return seen
    end

    --- A v1 database migrated by the real ladder, not an injected one.
    local function realMigratingRepo(extra)
        extra = extra or {}
        local backups = {}
        local driver
        driver = ctx.support.newSqlDriver{
            fail_on = extra.fail_on,
            on_open = function(conn)
                conn:answer("PRAGMA user_version", { { 1 } })
            end,
        }
        local repo, err = Repository.open{
            path = PATH,
            driver = driver,
            wal = true,
            now = function() return 4242 end,
            backup = function(src, dest)
                local live = driver.conns[#driver.conns]
                backups[#backups + 1] = {
                    src = src, dest = dest, closed = live.closed,
                    wrote = live:saw("ALTER TABLE") or live:saw("BEGIN"),
                }
                return true
            end,
        }
        return repo, driver, backups, err
    end

    t:case("the schema version is 2 and the fresh schema declares both surfaces", function()
        t:eq(Repository.SCHEMA_VERSION, 2, "version 2")
        local schema = squash(Repository.SCHEMA)
        t:check(schema:find(squash([[surface_role TEXT NOT NULL DEFAULT 'sheet']]), 1, true) ~= nil,
            "surface_role defaults to sheet, so every existing row stays one")
        t:check(schema:find(squash([[CHECK(surface_role IN ('sheet', 'page_ink'))]]), 1, true) ~= nil,
            "and only those two roles exist")
        t:check(schema:find(squash([[coordinate_space TEXT NOT NULL DEFAULT 'surface']]), 1, true) ~= nil,
            "coordinate_space defaults to surface")
        t:check(schema:find(squash([[CHECK(coordinate_space IN ('surface', 'native_page'))]]), 1, true) ~= nil,
            "and only those two spaces exist")
        t:check(schema:find(squash(
            "CREATE INDEX canvases_by_book_role_page ON canvases(book_id, surface_role, fixed_page, id)"),
            1, true) ~= nil, "with the index the page-ink lookups need")
    end)

    t:case("the v1 schema had neither column, so the migration is the only way in", function()
        t:eq(V1_SCHEMA:find("surface_role", 1, true), nil, "no role column")
        t:eq(V1_SCHEMA:find("coordinate_space", 1, true), nil, "no coordinate space")
        t:eq(V1_SCHEMA:find("canvases_by_book_role_page", 1, true), nil, "and no index")
    end)

    t:case("a migrated database ends up declaring what a fresh one declares", function()
        -- The failure this closes is a fresh install and a migrated one
        -- disagreeing about a constraint, which shows up much later as a write
        -- that works on one device and raises on another.
        local ran = squash(table.concat(migrationStatements(), " "))
        local schema = squash(Repository.SCHEMA)
        local declarations = {
            [[surface_role TEXT NOT NULL DEFAULT 'sheet']],
            [[CHECK(surface_role IN ('sheet', 'page_ink'))]],
            [[coordinate_space TEXT NOT NULL DEFAULT 'surface']],
            [[CHECK(coordinate_space IN ('surface', 'native_page'))]],
            "CREATE INDEX canvases_by_book_role_page ON canvases(book_id, surface_role, fixed_page, id)",
        }
        for i = 1, #declarations do
            local decl = squash(declarations[i])
            t:check(ran:find(decl, 1, true) ~= nil, "the migration adds " .. decl)
            t:check(schema:find(decl, 1, true) ~= nil, "and the fresh schema has " .. decl)
        end
    end)

    t:case("the migration step is DDL only and leaves the transaction to _migrate", function()
        local seen = migrationStatements()
        t:eq(#seen, 3, "three statements")
        t:check(seen[1]:find("ALTER TABLE canvases ADD COLUMN surface_role", 1, true) ~= nil,
            "the role column first")
        t:check(seen[2]:find("ALTER TABLE canvases ADD COLUMN coordinate_space", 1, true) ~= nil,
            "then the coordinate space")
        t:check(seen[3]:find("CREATE INDEX canvases_by_book_role_page", 1, true) ~= nil,
            "then the index, which needs both columns to exist")
        local joined = table.concat(seen, " ")
        t:eq(joined:find("BEGIN", 1, true), nil,
            "it opens no transaction -- an inner COMMIT would end _migrate's early")
        t:eq(joined:find("COMMIT", 1, true), nil, "nor closes one")
        t:eq(joined:find("user_version", 1, true), nil, "the version stamp is _migrate's job")
        t:eq(joined:find("UPDATE", 1, true), nil, "the DEFAULTs are the backfill, not an UPDATE")
        for i = 1, #seen do
            local _, semicolons = seen[i]:gsub(";", "")
            t:eq(semicolons, 1, "exactly one statement per exec, because exec splits on ;")
            t:eq(seen[i]:sub(-1), ";", "and the ; is the terminator, not part of a literal")
        end
    end)

    t:case("a v1 database is migrated by the real ladder, backup first", function()
        local repo, driver, backups = realMigratingRepo()
        t:check(repo ~= nil, "opened")
        t:eq(repo.version, 2, "at version 2")
        local conn = driver.last()
        local begin_at = conn:indexOf("BEGIN")
        local role_at = conn:indexOf("ADD COLUMN surface_role")
        local space_at = conn:indexOf("ADD COLUMN coordinate_space")
        local index_at = conn:indexOf("CREATE INDEX canvases_by_book_role_page")
        local stamp_at = conn:indexOf("PRAGMA user_version=2")
        local commit_at = conn:indexOf("COMMIT")
        t:check(begin_at and role_at and space_at and index_at and stamp_at and commit_at,
            "every step ran")
        t:check(begin_at < role_at and role_at < space_at and space_at < index_at
            and index_at < stamp_at and stamp_at < commit_at, "in that order")
        t:eq(conn:saw("UPDATE canvases"), false, "no row was rewritten to fill the columns in")
        t:eq(#backups, 1, "exactly one backup")
        t:eq(backups[1].dest, PATH .. ".backup-v1", "named for the version it holds")
        t:eq(backups[1].wrote, false, "taken before a single migration statement")
    end)

    t:case("a migration step that raises refuses the open and leaves the stamp alone", function()
        local repo, driver, backups, _, err = migratingRepo{
            migrations = { [1] = function() error("no space left on device", 0) end },
        }
        t:eq(repo, nil, "no repository")
        t:eq(err, "migration_failed", "and the caller can say why")
        t:check(driver.last():saw("ROLLBACK"), "the transaction was rolled back")
        t:eq(driver.last():saw("PRAGMA user_version=2"), false,
            "so the file is still a v1 file, stamp included")
        t:eq(#backups, 1, "with the v1 backup beside it either way")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / surface roles")

    --[[
    Everything section 2 of the schema refuses. The repository and the suite's
    fake store are both run over this table: a fake that accepts a row SQLite's
    CHECK would reject is a mismatch nobody notices until a device writes it.
    ]]
    local BAD_SURFACES = {
        { "a sheet in native page coordinates", {
            anchor_key = "k", logical_w = 10, logical_h = 10,
            surface_role = "sheet", coordinate_space = "native_page" } },
        { "page ink in surface coordinates", {
            anchor_kind = "page", anchor_key = "page-ink:3", fixed_page = 3,
            logical_w = 10, logical_h = 10,
            surface_role = "page_ink", coordinate_space = "surface" } },
        { "page ink anchored by xpointer", {
            anchor_kind = "xpointer", anchor_key = "page-ink:3", fixed_page = 3,
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink with no page number", {
            anchor_kind = "page", anchor_key = "page-ink:3",
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink on page zero", {
            anchor_kind = "page", anchor_key = "page-ink:0", fixed_page = 0,
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink on a fractional page", {
            anchor_kind = "page", anchor_key = "page-ink:2.5", fixed_page = 2.5,
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink on an infinite page", {
            anchor_kind = "page", anchor_key = "page-ink:inf", fixed_page = math.huge,
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink carrying a raw xpointer", {
            anchor_kind = "page", anchor_key = "page-ink:3", fixed_page = 3,
            anchor_raw = "/body/p[1]",
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink carrying a normalised xpointer", {
            anchor_kind = "page", anchor_key = "page-ink:3", fixed_page = 3,
            anchor_normalized = "/body/p[1]",
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "page ink carrying a dom version", {
            anchor_kind = "page", anchor_key = "page-ink:3", fixed_page = 3,
            anchor_dom_version = 20240101,
            logical_w = 10, logical_h = 10, surface_role = "page_ink" } },
        { "a role that is neither", {
            anchor_key = "k", logical_w = 10, logical_h = 10,
            surface_role = "scribble" } },
    }

    t:case("a sheet defaults to the surface coordinate space", function()
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 31 } }) end,
        }
        local c = repo:createCanvas(12, {
            anchor_kind = "xpointer", anchor_key = "xp:/body/p[7]",
            logical_w = 1860, logical_h = 2480,
        })
        t:eq(c.surface_role, "sheet", "a canvas with no role stated is a sheet")
        t:eq(c.coordinate_space, "surface", "in surface coordinates")
        local binds = driver.last():bindsFor("INSERT INTO canvases")
        t:eq(binds[8], "sheet", "both are written, not left to the column default")
        t:eq(binds[9], "surface", "which is what makes a v1 row and a v2 row agree")
    end)

    t:case("a page-ink surface defaults to native page coordinates", function()
        local repo, driver = openRepo{
            answers = function(conn) conn:answer("last_insert_rowid", { { 32 } }) end,
        }
        local c = repo:createCanvas(12, {
            anchor_kind = "page", anchor_key = "page-ink:7", fixed_page = 7,
            surface_role = "page_ink", logical_w = 612, logical_h = 792,
        })
        t:check(c ~= nil, "created")
        t:eq(c.coordinate_space, "native_page", "page ink is in the page's own units")
        t:eq(c.fixed_page, 7, "and carries its page")
        local binds = driver.last():bindsFor("INSERT INTO canvases")
        t:eq(binds[7], 7, "the page is bound")
        t:eq(binds[8], "page_ink", "with the role")
    end)

    t:case("every surface rule the schema states is refused before the insert", function()
        for i = 1, #BAD_SURFACES do
            local repo, driver = openRepo{
                answers = function(conn) conn:answer("last_insert_rowid", { { 31 } }) end,
            }
            local c, err = repo:createCanvas(12, BAD_SURFACES[i][2])
            t:eq(c, nil, BAD_SURFACES[i][1] .. " is not created")
            t:eq(err, "bad_surface", BAD_SURFACES[i][1] .. " is named")
            t:eq(driver.last():saw("INSERT INTO canvases"), false,
                "and nothing reached the database")
        end
    end)

    t:case("the fake store refuses exactly what the repository refuses", function()
        for i = 1, #BAD_SURFACES do
            local store = support.newCanvasStore{}
            local c, err = store:createCanvas(12, BAD_SURFACES[i][2])
            t:eq(c, nil, BAD_SURFACES[i][1] .. " is not created")
            t:eq(err, "bad_surface", BAD_SURFACES[i][1] .. " is named")
            t:eq(#store.canvases, 0, "and nothing was stored")
        end
    end)

    t:case("a listed canvas carries its role and coordinate space", function()
        local repo = openRepo{
            answers = function(conn)
                conn:answer("FROM canvases", {
                    { 3, "xpointer", "xp:/body/p[7]", "raw", "norm", 20240101, nil,
                      1860, 2480, 4242, "sheet", "surface" },
                })
            end,
        }
        local c = repo:listCanvases(12)[1]
        t:eq(c.surface_role, "sheet", "role")
        t:eq(c.coordinate_space, "surface", "coordinate space")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / page-ink queries")

    local function pageInkRepo(rows)
        return openRepo{
            answers = function(conn)
                -- Scripted answers are matched in order and a count is also a
                -- statement "FROM canvases", so the narrower pattern goes first.
                conn:answer("count%(%*%)", { { 3 } })
                conn:answer("FROM canvases", rows or {})
                conn:answer("last_insert_rowid", { { 44 } })
            end,
        }
    end

    t:case("the sheet listing asks for sheets only", function()
        local repo, driver = pageInkRepo()
        repo:listCanvases(12)
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("surface_role = 'sheet'", 1, true) ~= nil,
            "page ink never reaches the anchor index")
    end)

    t:case("sheets are counted without their rows", function()
        local repo, driver = pageInkRepo()
        t:eq(repo:countCanvases(12), 3, "the count comes back as a Lua number")
        local sql = driver.last():statement("count")
        t:check(sql:find("surface_role = 'sheet'", 1, true) ~= nil, "sheets only")
        t:eq(sql:find("stroke_chunks", 1, true), nil, "and no point data is touched")
    end)

    t:case("a sheet batch walks by id and drags no points along", function()
        local repo, driver = pageInkRepo{
            { 3, "xpointer", "k", nil, nil, nil, nil, 1860, 2480, 4242, "sheet", "surface" },
        }
        local batch = repo:listCanvasesBatch(12)
        t:eq(#batch, 1, "rows come back mapped")
        t:eq(batch[1].id, 3, "as canvas rows")
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("ORDER BY id", 1, true) ~= nil, "ordered by id, which is stable")
        t:eq(sql:find("stroke_chunks", 1, true), nil, "the chunk table is not joined")
        t:eq(sql:find("points", 1, true), nil, "and the points column is not named")
    end)

    t:case("a batch defaults to 200 rows and is clamped to 500", function()
        local function limitOf(opts)
            local repo, driver = pageInkRepo()
            repo:listCanvasesBatch(12, opts)
            local binds = driver.last():bindsFor("FROM canvases")
            return binds[#binds]
        end
        t:eq(limitOf(nil), 200, "the default batch")
        t:eq(limitOf{ limit = 50 }, 50, "a smaller batch is honoured")
        t:eq(limitOf{ limit = 5000 }, 500, "a caller cannot ask for the whole book")
        t:eq(limitOf{ limit = 0 }, 1, "nor for nothing at all")
    end)

    t:case("a batch cursor selects strictly beyond the last id", function()
        local repo, driver = pageInkRepo()
        repo:listCanvasesBatch(12, { after_id = 41, limit = 10 })
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("id > ", 1, true) ~= nil, "strictly greater, so no row repeats")
        local binds = driver.last():bindsFor("FROM canvases")
        t:eq(binds[2], 41, "the cursor is bound")
        t:eq(binds[3], 10, "and the limit after it")
    end)

    t:case("a page-ink surface is looked up by role and page", function()
        local repo, driver = pageInkRepo{
            { 9, "page", "page-ink:7", nil, nil, nil, 7, 612, 792, 4242,
              "page_ink", "native_page" },
        }
        local row = repo:findPageInkSurface(12, 7)
        t:eq(row.id, 9, "found")
        t:eq(row.fixed_page, 7, "on its page")
        t:eq(row.coordinate_space, "native_page", "in page units")
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("surface_role = 'page_ink'", 1, true) ~= nil, "page ink only")
        local binds = driver.last():bindsFor("FROM canvases")
        t:eq(binds[2], 7, "and the page is bound, not interpolated")
    end)

    t:case("a page with no surface answers not_found, not an empty list", function()
        local repo = pageInkRepo()
        local row, err = repo:findPageInkSurface(12, 7)
        t:eq(row, nil, "nothing there")
        t:eq(err, "not_found", "which the caller turns into a create")
    end)

    t:case("creating a page-ink surface fills in the whole spec", function()
        local repo, driver = pageInkRepo()
        local row = repo:createPageInkSurface(12, 7, 612, 792)
        t:eq(row.id, 44, "the new id")
        t:eq(row.anchor_kind, "page", "anchored by page")
        t:eq(row.anchor_key, "page-ink:7", "with the key the UNIQUE constraint keys on")
        t:eq(row.surface_role, "page_ink", "as page ink")
        t:eq(row.coordinate_space, "native_page", "in page units")
        t:eq(row.logical_w, 612, "at the page's own width")
        t:eq(row.logical_h, 792, "and height")
        t:check(driver.last():saw("INSERT INTO canvases"), "written")
    end)

    t:case("a page-ink surface with no usable page is refused before the insert", function()
        local repo, driver = pageInkRepo()
        local row, err = repo:createPageInkSurface(12, nil, 612, 792)
        t:eq(row, nil, "not created")
        t:eq(err, "bad_surface", "named")
        t:eq(driver.last():saw("INSERT INTO canvases"), false, "and nothing was written")
    end)

    t:case("page-ink surfaces are listed by page, then by id", function()
        local repo, driver = pageInkRepo()
        repo:listPageInkSurfaces(12)
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("surface_role = 'page_ink'", 1, true) ~= nil, "page ink only")
        t:check(sql:find("ORDER BY fixed_page, id", 1, true) ~= nil,
            "the order the export reads them in")
        local binds = driver.last():bindsFor("FROM canvases")
        t:eq(binds[2], 100, "a page-ink batch is 100 rows by default")
    end)

    t:case("the page-ink cursor is the pair, so a shared page cannot loop", function()
        local repo, driver = pageInkRepo()
        repo:listPageInkSurfaces(12, { after_page = 7, after_id = 9, limit = 600 })
        local sql = driver.last():statement("FROM canvases")
        t:check(sql:find("fixed_page > ", 1, true) ~= nil, "past that page")
        t:check(sql:find("id > ", 1, true) ~= nil, "or past that id on the same page")
        local binds = driver.last():bindsFor("FROM canvases")
        t:eq(binds[2], 7, "the page is bound")
        t:eq(binds[3], 9, "and the id")
        t:eq(binds[4], 500, "with the same clamp as any other batch")
    end)

    t:case("page-ink surfaces are counted, deleted by page and deleted wholesale", function()
        local repo, driver = pageInkRepo()
        t:eq(repo:countPageInkSurfaces(12), 3, "counted")
        t:check(driver.last():statement("count"):find("surface_role = 'page_ink'", 1, true) ~= nil,
            "page ink only")

        local one, one_driver = pageInkRepo()
        t:eq(one:deletePageInkSurface(12, 7), true, "one page deleted")
        local sql = one_driver.last():statement("DELETE FROM canvases")
        t:check(sql:find("surface_role = 'page_ink'", 1, true) ~= nil, "never a sheet")
        t:eq(one_driver.last():bindsFor("DELETE FROM canvases")[2], 7, "on that page alone")

        local all, all_driver = pageInkRepo()
        t:eq(all:deleteAllPageInkSurfaces(12), true, "and the whole book can go")
        local all_sql = all_driver.last():statement("DELETE FROM canvases")
        t:check(all_sql:find("surface_role = 'page_ink'", 1, true) ~= nil,
            "still never a sheet")
        t:eq(all_sql:find("fixed_page", 1, true), nil, "and no page narrows it")
    end)

    -- =================================================================
    t:describe("ink_canvas_repository / page ink through the fake store")

    --[[
    The fake is what every other suite drives, so it has to answer the way the
    repository does -- roles, defaults, ordering, cursors, limits. What the
    recorder above cannot show, because it executes nothing, is that those
    orderings and that keyset actually walk a set of rows exactly once.
    ]]
    local function sheetStore(n)
        local store = support.newCanvasStore{}
        for i = 1, n do
            store:createCanvas(12, {
                anchor_kind = "xpointer", anchor_key = "xp:" .. i,
                logical_w = 100, logical_h = 100,
            })
        end
        return store
    end

    t:case("a page-ink surface is found only once it exists", function()
        local store = support.newCanvasStore{}
        local missing, err = store:findPageInkSurface(12, 7)
        t:eq(missing, nil, "nothing yet")
        t:eq(err, "not_found", "said the way the repository says it")

        local made = store:createPageInkSurface(12, 7, 612, 792)
        t:check(made ~= nil, "created")
        t:eq(made.anchor_key, "page-ink:7", "keyed by page")
        t:eq(made.surface_role, "page_ink", "as page ink")
        t:eq(made.coordinate_space, "native_page", "in page units")

        local found = store:findPageInkSurface(12, 7)
        t:eq(found.id, made.id, "and found again")

        local dup, dup_err = store:createPageInkSurface(12, 7, 612, 792)
        t:eq(dup, nil, "a second surface for one page is refused")
        t:check(dup_err ~= nil, "with a reason -- on SQLite it is the UNIQUE constraint")
    end)

    t:case("page-ink surfaces walk page order across batches, once each", function()
        local store = support.newCanvasStore{}
        for _, page in ipairs{ 9, 2, 5 } do
            store:createPageInkSurface(12, page, 612, 792)
        end
        local pages, after_page, after_id = {}, nil, nil
        for _ = 1, 4 do
            local batch = store:listPageInkSurfaces(12,
                { after_page = after_page, after_id = after_id, limit = 1 })
            if #batch == 0 then break end
            t:eq(#batch, 1, "one row per batch, as asked")
            pages[#pages + 1] = batch[1].fixed_page
            after_page, after_id = batch[1].fixed_page, batch[1].id
        end
        t:eq(table.concat(pages, ","), "2,5,9", "in page order, no repeats and no gaps")
        local done = store:listPageInkSurfaces(12,
            { after_page = after_page, after_id = after_id, limit = 1 })
        t:eq(#done, 0, "and the cursor runs out")
    end)

    t:case("counting and deleting page ink never touches a sheet", function()
        local store = sheetStore(2)
        store:createPageInkSurface(12, 3, 612, 792)
        store:createPageInkSurface(12, 4, 612, 792)
        t:eq(store:countPageInkSurfaces(12), 2, "two page surfaces")
        t:eq(store:countCanvases(12), 2, "and two sheets, counted apart")
        t:eq(#store:listCanvases(12), 2, "the sheet listing excludes page ink")

        t:eq(store:deletePageInkSurface(12, 3), true, "one page deleted")
        t:eq(store:countPageInkSurfaces(12), 1, "only that one")
        t:eq(store:countCanvases(12), 2, "the sheets are untouched")

        t:eq(store:deleteAllPageInkSurfaces(12), true, "and then all of it")
        t:eq(store:countPageInkSurfaces(12), 0, "no page ink left")
        t:eq(store:countCanvases(12), 2, "and still every sheet")
    end)

    t:case("a sheet batch walks ids once and opens no stroke", function()
        local store = sheetStore(5)
        store:createPageInkSurface(12, 3, 612, 792)
        store:putStroke(store.canvases[1].id,
            { width = 4, tool = 1, points = { 1, 1, 2, 2 }, n = 2 })
        local ids, after = {}, nil
        while true do
            local batch = store:listCanvasesBatch(12, { after_id = after, limit = 2 })
            if #batch == 0 then break end
            for i = 1, #batch do
                ids[#ids + 1] = batch[i].id
                after = batch[i].id
            end
        end
        t:eq(#ids, 5, "every sheet, and only the sheets")
        local sorted = true
        for i = 2, #ids do
            if ids[i] <= ids[i - 1] then sorted = false end
        end
        t:check(sorted, "in ascending id order")
        t:eq(store.calls.stroke_read, 0, "no stroke was read")
        t:eq(store.calls.stroke_chunk, 0, "and no chunk was decoded")
    end)

    t:case("the fake clamps a batch the way the repository does", function()
        local store = sheetStore(501)
        t:eq(#store:listCanvasesBatch(12), 200, "the default batch")
        t:eq(#store:listCanvasesBatch(12, { limit = 5000 }), 500, "clamped high")
        t:eq(#store:listCanvasesBatch(12, { limit = 0 }), 1, "and clamped low")
        t:eq(#store:listCanvasesBatch(12, { limit = 50 }), 50, "otherwise honoured")
    end)
end
