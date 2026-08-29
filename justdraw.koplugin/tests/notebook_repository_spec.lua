return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Repository = require("ink_notebook_repository")
    local PATH = "/tmp/justdraw-notebooks-test.sqlite3"

    local function openRepo(opts)
        opts = opts or {}
        local driver = support.newSqlDriver{
            int64 = opts.int64,
            fail_on = opts.fail_on,
            on_open = function(conn)
                conn:answer("PRAGMA user_version", {
                    { opts.user_version == nil and Repository.SCHEMA_VERSION
                        or opts.user_version },
                })
                conn:answer("SELECT changes", { { 1 } })
                if opts.answers then opts.answers(conn) end
            end,
        }
        local repo, err = Repository.open{
            path = PATH, driver = driver, wal = opts.wal == true,
            now = function() return 4242 end,
        }
        return repo, driver, err
    end

    t:describe("ink_notebook_repository / schema and boundaries")

    t:case("a fresh database creates only the notebook domain", function()
        local repo, driver = openRepo{ user_version = 0 }
        local conn = driver.last()
        t:check(repo ~= nil, "opened")
        t:check(conn:saw("CREATE TABLE notebooks"), "notebooks table")
        t:check(conn:saw("CREATE TABLE notebook_pages"), "pages table")
        t:check(conn:saw("CREATE TABLE notebook_state"), "state table")
        t:check(conn:saw("CREATE TABLE notebook_strokes"), "strokes table")
        t:check(conn:saw("CREATE TABLE notebook_stroke_chunks"), "chunks table")
        t:eq(conn:saw("CREATE TABLE books"), false, "canvas database is not imported")
        t:eq(conn:saw("ON DELETE CASCADE"), false, "large deletes are not cascaded")
    end)

    t:case("future schemas reopen read-only and refuse writes", function()
        local repo, driver = openRepo{
            user_version = Repository.SCHEMA_VERSION + 3,
        }
        t:eq(repo.read_only, true, "read-only")
        t:eq(driver.modes[#driver.modes], "ro", "SQLite enforces it")
        local result, err = repo:createNotebook{
            title = "Future", logical_w = 1000, logical_h = 1400,
        }
        t:eq(result, nil, "no write")
        t:eq(err, "read_only", "stable reason")
    end)

    t:case("numeric cdata is normalized at the repository boundary", function()
        local repo = openRepo{
            int64 = true,
            answers = function(conn)
                conn:answer("FROM notebooks n LEFT JOIN notebook_state", {
                    { 7, "Notes", 2, 3072, 10, 11, nil, 9 },
                })
            end,
        }
        local notebook = repo:getNotebook(7)
        t:eq(type(notebook.id), "number", "id")
        t:eq(type(notebook.page_count), "number", "page count")
        t:eq(type(notebook.current_page_id), "number", "current page")
    end)

    t:case("listings are bounded metadata-only keyset queries", function()
        local repo, driver = openRepo()
        repo:listNotebooks({ after_updated_at = 100, after_id = 20, limit = 9999 })
        repo:listPages(1, { after_sort_key = 1024, after_id = 5, limit = 9999 })
        local conn = driver.last()
        local books = conn:statement("ORDER BY updated_at DESC")
        local pages = conn:statement("ORDER BY sort_key, id LIMIT")
        t:check(books:find("id < %?2") ~= nil, "library keyset")
        t:check(pages:find("id > %?3") ~= nil, "page keyset")
        t:eq(books:find("notebook_strokes") ~= nil, false, "library reads no strokes")
        t:eq(pages:find("notebook_stroke_chunks") ~= nil, false, "pages read no blobs")
        local bb = conn:bindsFor("ORDER BY updated_at DESC")
        local pb = conn:bindsFor("ORDER BY sort_key, id LIMIT")
        t:eq(bb[#bb], Repository.MAX_LIMIT, "library limit capped")
        t:eq(pb[#pb], Repository.MAX_LIMIT, "page limit capped")
    end)

    t:case("titles and all geometry reject invalid or non-finite values", function()
        local repo, driver = openRepo()
        local before = #driver.last().log
        t:eq(repo:createNotebook{
            title = " ", logical_w = 1000, logical_h = 1400,
        }, nil, "blank title")
        t:eq(repo:createNotebook{
            title = "x", logical_w = math.huge, logical_h = 1400,
        }, nil, "infinite width")
        t:eq(repo:appendPage(1, {
            logical_w = 1000, logical_h = -math.huge,
        }), nil, "infinite height")
        t:eq(#driver.last().log, before, "nothing reached SQLite")
    end)

    t:case("stroke deletion is a constant-size tombstone", function()
        local repo, driver = openRepo()
        t:eq(repo:deleteStroke(91), true, "accepted")
        local sql = driver.last():statement("UPDATE notebook_strokes SET deleted_at")
        t:check(sql ~= nil, "one metadata update")
        t:eq(sql:find("notebook_stroke_chunks") ~= nil, false,
            "no chunk scan in the interactive path")
    end)

    t:case("every create step rolls the whole notebook back on failure", function()
        for _, pattern in ipairs({
            "INSERT INTO notebooks",
            "INSERT INTO notebook_pages",
            "UPDATE notebooks SET page_count",
            "INSERT INTO notebook_state",
        }) do
            local repo, driver = openRepo{
                fail_on = pattern,
                answers = function(conn)
                    conn:answer("last_insert_rowid", { { 7 } })
                end,
            }
            local notebook = repo:createNotebook{
                title = "Atomic", logical_w = 1000, logical_h = 1400,
            }
            t:eq(notebook, nil, pattern .. " failure is returned")
            t:check(driver.last():saw("ROLLBACK"), pattern .. " rolls back")
        end
    end)

    t:case("a page's ruling is scoped to its notebook and moves both dates", function()
        local repo, driver = openRepo()
        t:eq(repo:setPageTemplate(1, 11, "dots"), true, "accepted")
        local conn = driver.last()
        local sql = conn:statement("UPDATE notebook_pages SET template_kind")
        t:check(sql ~= nil, "one page update")
        t:check(sql:find("notebook_id = %?2") ~= nil,
            "a page id alone cannot reach another notebook's page")
        t:check(sql:find("deleted_at IS NULL") ~= nil, "and not a tombstone")
        local binds = conn:bindsFor("UPDATE notebook_pages SET template_kind")
        t:eq(binds[3], "dots", "the kind is bound, never interpolated")
        t:check(conn:indexOf("UPDATE notebook_pages SET template_kind")
            < conn:indexOf("UPDATE notebooks SET updated_at"),
            "the notebook's recency follows the page's")
        t:check(conn:saw("BEGIN"), "in one transaction")
        t:eq(conn:saw("notebook_strokes"), false, "and touches no ink")
    end)

    t:case("only a ruling this build can draw is accepted", function()
        local repo, driver = openRepo()
        local before = #driver.last().log
        for _, kind in ipairs({ "future-template", "", "blank; DROP" }) do
            local ok, err = repo:setPageTemplate(1, 11, kind)
            t:eq(ok, nil, kind .. " refused")
            t:eq(err, "bad_template", kind .. " reason")
        end
        t:eq(repo:setPageTemplate(1, 11, nil), nil, "no kind refused")
        t:eq(repo:setPageTemplate(0, 11, "dots"), nil, "bad notebook refused")
        t:eq(repo:setPageTemplate(1, -3, "dots"), nil, "bad page refused")
        t:eq(#driver.last().log, before, "nothing reached SQLite")
        for kind in pairs(Repository.KNOWN_TEMPLATES) do
            t:eq(repo:setPageTemplate(1, 11, kind), true, kind .. " accepted")
        end
    end)

    t:case("a ruling change on a missing page is not reported as done", function()
        -- Its own driver: openRepo scripts one changed row for every case,
        -- and the fake answers the first pattern that matches.
        local driver = support.newSqlDriver{
            on_open = function(conn)
                conn:answer("PRAGMA user_version",
                    { { Repository.SCHEMA_VERSION } })
                conn:answer("SELECT changes", { { 0 } })
            end,
        }
        local repo = Repository.open{
            path = PATH, driver = driver, wal = false,
            now = function() return 4242 end,
        }
        local ok, err = repo:setPageTemplate(1, 11, "ruled")
        t:eq(ok, nil, "refused")
        t:eq(err, "not_found", "stable reason")
        t:check(driver.last():saw("ROLLBACK"), "and rolled back")
    end)

    t:case("one purge call contains bounded leaf-to-root work", function()
        local repo, driver = openRepo()
        local counts = repo:purgeDeletedBatch{
            chunks = 999, strokes = 999, pages = 999, notebooks = 999,
        }
        local conn = driver.last()
        t:check(counts ~= nil, "batch completed")
        t:check(conn:indexOf("DELETE FROM notebook_stroke_chunks")
            < conn:indexOf("DELETE FROM notebook_strokes"), "chunks first")
        t:check(conn:indexOf("DELETE FROM notebook_strokes")
            < conn:indexOf("DELETE FROM notebook_pages"), "then strokes")
        t:check(conn:indexOf("DELETE FROM notebook_pages")
            < conn:indexOf("DELETE FROM notebooks"), "parents last")
        local binds = conn:bindsFor("DELETE FROM notebook_stroke_chunks")
        t:eq(binds[1], 256, "caller cannot make a huge chunk batch")
        t:eq(conn:saw("VACUUM"), false, "no automatic full-file rewrite")
    end)

    t:case("purge rolls back when SQLite cannot report its progress", function()
        local repo, driver = openRepo{ fail_on = "SELECT changes" }
        local counts, err = repo:purgeDeletedBatch()
        t:eq(counts, nil, "unknown progress is not reported as a clean batch")
        t:check(err ~= nil, "the SQLite error is propagated")
        t:check(driver.last():saw("ROLLBACK"), "partial maintenance is rolled back")
    end)
end
