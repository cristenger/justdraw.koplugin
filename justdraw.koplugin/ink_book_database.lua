--[[--
Getting to a book's row in the canvas database, once, for every surface that
needs one.

Sheets and page ink are different features with different tables, different
coordinates and different lifetimes -- but they live in the same file and they
reach it the same way, and that way is four decisions deep. Which of the two
filenames to open (a JustDraw database, a FingerInk one left over from the
rename, and the refusal when both exist, ADR `ink_compat`). Whether the
connection was opened here or handed in, because only the first may be closed
again. Whether the schema is newer than this plugin, which turns the book
lookup from `bookId` -- which inserts -- into `findBookId`, which must not.
And the one case where "no book row" is not a failure: a read-only database a
newer plugin has never registered this book in, where there is simply nothing
to find and nothing this plugin may write.

Those four had been written twice, once per session, and three of them are
invariants: a second copy is a place for them to drift apart, silently, in the
half of the plugin nobody was editing that day.

What stays with the callers is everything that differs. Each session keeps its
own wording for a refusal, because "sheets are unavailable for this book" and
"page notes are unavailable for this book" are different sentences to a
reader; each keeps its own decision about when to notify; and each keeps
ownership of the connection's lifetime, which is not the same for both -- a
sheet session ties it to the document, a page-ink session closes only what it
opened. So this seam answers with a plain handle and never notifies anyone.

`device` and `datastorage` are required inside the functions that need them,
so a session handed a repository -- which is every session in the suite --
pulls in neither, and both stay loadable and drivable with no device at all.
]]

local logger = require("logger")

local Compat = require("ink_compat")
local Repository = require("ink_canvas_repository")

local BookDatabase = {}

BookDatabase.CURRENT_FILENAME = "justdraw.sqlite3"
BookDatabase.LEGACY_FILENAME = "fingerink.sqlite3"

--- The database to open: the current name, an existing legacy one, or nil
--- plus `database_conflict` when both are there. Same returns as
--- `Compat.databasePath`, whose last two are the paths that clashed.
function BookDatabase.path()
    local DataStorage = require("datastorage")
    return Compat.databasePath(DataStorage:getSettingsDir(),
        BookDatabase.CURRENT_FILENAME, BookDatabase.LEGACY_FILENAME)
end

function BookDatabase.canUseWAL()
    local Device = require("device")
    return Device.canUseWAL and Device:canUseWAL() or false
end

--[[--
Connect, if there is nothing connected yet, and resolve the book.

  opts.repository     an open repository, `false` to refuse, nil to open one
  opts.identity       { partial_md5 = , file_size = }
  opts.file           the book's path, stored as `last_path`
  opts.path_provider  overrides `BookDatabase.path`, so a caller keeps a seam
                      of its own to fake the file selection through

Answers a handle -- `{ repository, owns_repository, book_id, empty_read_only,
read_only }` -- or nil, one of `no_repository`, `database_conflict`,
`no_identity`, and the underlying driver or lookup error as a third value for
the log.

`book_id` is nil only together with `empty_read_only`: a newer schema that has
never heard of this book. There is nothing to read and this plugin must not
insert the row, but browsing what is there is still fine.

A connection opened *here* is closed again when the book cannot be resolved,
because nobody else has been told about it yet. One handed in is left alone:
its lifetime belongs to whoever opened it.
]]
function BookDatabase.open(opts)
    opts = opts or {}
    local repository = opts.repository
    if repository == false then return nil, "no_repository" end

    local owns_repository = false
    if not repository then
        local provider = opts.path_provider or BookDatabase.path
        local path, path_err, current_path, legacy_path = provider()
        if not path then
            logger.warn("JustDraw: notes database conflict:",
                path_err, current_path, legacy_path)
            return nil, path_err or "database_conflict"
        end
        local repo, open_err = Repository.open{
            path = path,
            wal = BookDatabase.canUseWAL(),
        }
        if not repo then
            logger.warn("JustDraw: notes database unavailable:", open_err)
            return nil, "no_repository", open_err
        end
        repository = repo
        owns_repository = true
    end

    local identity = opts.identity or {}
    local read_only = repository.read_only == true
    local book_id, err
    if read_only then
        book_id, err = repository:findBookId(
            identity.partial_md5, identity.file_size)
    else
        book_id, err = repository:bookId(
            identity.partial_md5, identity.file_size, opts.file)
    end
    local empty_read_only = read_only and err == "not_found"
    if not book_id and not empty_read_only then
        logger.warn("JustDraw: no stable identity for this book:", err)
        BookDatabase.close{
            repository = repository,
            owns_repository = owns_repository,
        }
        return nil, "no_identity", err
    end

    return {
        repository = repository,
        owns_repository = owns_repository,
        book_id = book_id,
        empty_read_only = empty_read_only,
        read_only = read_only,
    }
end

--- Close a connection this seam opened. A repository that was handed in is
--- never closed here: the caller that opened it decides when it goes.
function BookDatabase.close(handle)
    if type(handle) ~= "table" then return false end
    if not handle.owns_repository then return false end
    local repository = handle.repository
    if not repository or not repository.close then return false end
    repository:close()
    return true
end

return BookDatabase
