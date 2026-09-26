--[[--
A notebook exported to Xournal++, one bounded piece per scheduler turn.

`ink_export_xopp` knows how to *write* the XML and nothing about where strokes
come from; `ink_export_xopp_archive` knows how to gzip and nothing about XML;
`ink_export` owns the destination -- the name, the collision question, the
temporary beside the target, the rename, Cancel, "one export at a time". This
is the part in between: reading a notebook out of SQLite and through the
writer, without ever holding more of it than one stroke, and refusing to
publish a file that no longer describes the notebook.

Without it the tempting version is short and wrong in three ways. It calls
`listStrokes` and decodes every page up front, and a few hundred dense pages
become a few hundred megabytes of Lua tables on a device with less than that.
It runs in one go inside a button callback, and the UI freezes for as long as
the notebook is long, with a Cancel button that cannot be pressed. And it
reads a notebook that the reader can still edit between turns, so the file
that lands can mix two states of the same page.

So the job is a producer that `ink_export` drives through `step()`, one turn
at a time, and every turn is bounded by counts rather than by hope:

  open      sweep this plugin's stale spools, create a fresh private spool
  snapshot  per page: its row and its stroke revision (count, max seq, max id)
  pages     per page, stroke metadata in keyset batches in paint order
            `(paint_seq, seq)`, and each stroke's chunks read one keyed lookup
            at a time into the one stroke that is resident; written, dropped
  xml_end   close the document; close the spool, checked; size is now known
  compress  the spool, block by block, through the archive adapter into the
            temporary `ink_export` gave us, beside the destination
  validate  the gzip on disk is magic-first and trailer-last with the length
  verify    every page and revision again; any difference is a refusal
  cleanup   the spool goes

No SQLite statement lives across a turn (the same rule as InkCanvasCache: an
open statement pins a WAL snapshot on the Scribe and blocks writers on
rollback-journal devices), and only the job's own files are open between
turns. `close()` releases all of them from any phase, which is what makes a
cancellation -- observed by `ink_export` at every turn -- leave nothing but
what `ink_export` itself removes.

**The spool is private and capped.** It lives in a folder under KOReader's
data directory that only this module writes to, named with a prefix only this
module uses, so the sweep at the next start can delete stale ones without
asking anybody. It is capped at `SPOOL_CAP` (256 MiB of XML): Xournal++ loads a
whole document into memory, a file several times that size is not a useful
export, and a spool that fills the internal storage is a device problem. Past
the cap the export stops with its own reason rather than with a full disk.
]]

local logger = require("logger")

local Codec = require("ink_canvas_codec")
local Xopp = require("ink_export_xopp")

local XoppJob = {}

--- Private and leading-dot. The prefix is what the sweep trusts.
XoppJob.SPOOL_PREFIX = ".justdraw-xopp-spool-"
--- The folder under KOReader's data directory that holds spools.
XoppJob.SPOOL_SUBDIR = "cache/justdraw-xopp"
--- Uncompressed XML, in bytes. See the header for why 256 MiB.
XoppJob.SPOOL_CAP = 256 * 1024 * 1024
--- One read of the spool and one call into libarchive.
XoppJob.BLOCK = 16384
--- A sweep walks at most this many directory entries.
XoppJob.SWEEP_MAX_ENTRIES = 2000

--[[--
Work per turn. Each is a count of *reads*, so a turn costs the same on a page
of dots as on a page of scribbles, give or take one stroke's formatting.

`chunks` bounds points: a chunk holds at most `Codec.MAX_POINTS` (1024), so a
turn decodes at most 32 768 points. `metas` bounds the metadata resident at
once. `pages` bounds the per-page revision queries in snapshot and verify.
`blocks` bounds compression: 2 x 16 KiB per turn. Deflate is the one cost here
that is not a read, and tests/xopp_archive_native.lua measured one 16 KiB
block at 3-4 ms worst case on a desktop x86 core (64 KiB: 9-16 ms);
an e-reader core is several times slower, so two blocks keep a turn short
enough that Cancel and page turns stay responsive.
]]
XoppJob.DEFAULT_LIMITS = { chunks = 32, metas = 64, pages = 32, blocks = 2 }

local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function positiveInteger(v)
    v = tonumber(v)
    if not finite(v) or v < 1 or v ~= floor(v) then return nil end
    return v
end

-- ------------------------------------------------------------- the reasons

--[[--
Sentences for the reasons only this export produces. `ink_export_dialog`
falls back to these after its own table, so a code here reaches a reader as a
sentence, never as a code. Built per call so the language is current.
]]
function XoppJob.messages()
    local _ = require("ink_i18n")
    return {
        notebook_changed = _("The notebook changed while it was being exported, so nothing was saved. Try again."),
        spool_failed = _("The export’s temporary file couldn’t be written. The device may be full; free some space and try again."),
        spool_too_large = _("This notebook is too large to export to Xournal++. Export fewer pages, or use PDF."),
        archive_unavailable = _("Xournal++ export isn’t available in this KOReader version."),
        archive_failed = _("The file couldn’t be compressed. The folder may be full."),
        archive_invalid = _("The compressed file didn’t check out, so it wasn’t saved. Try again."),
        destination_taken = _("A file with that name appeared while exporting. Nothing was replaced; export again to choose."),
    }
end

-- ------------------------------------------------------------- filesystem

local function defaultFs()
    local lfs = require("libs/libkoreader-lfs")
    return {
        attributes = function(path, what) return lfs.attributes(path, what) end,
        symlinkattributes = function(path, what)
            return lfs.symlinkattributes(path, what)
        end,
        open = io.open,
        remove = os.remove,
        rename = os.rename,
        dir = function(path) return lfs.dir(path) end,
        mkdir = function(path) return lfs.mkdir(path) end,
    }
end

--- What is at `path` itself, a link included, without following it.
local function lmode(fs, path)
    local lstat = fs.symlinkattributes or fs.attributes
    local ok, mode = pcall(lstat, path, "mode")
    if not ok then return nil end
    return mode
end
XoppJob.lmode = lmode

--[[--
The spool folder, created if needed, or nil and a reason.

A link is refused rather than followed: the folder is ours by construction,
and a link where it should be is somebody else's idea of where our temporary
bytes should go.
]]
function XoppJob.spoolDirectory(fs, root)
    fs = fs or defaultFs()
    if not root then
        local ok, DataStorage = pcall(require, "datastorage")
        root = ok and DataStorage:getDataDir() or nil
    end
    if type(root) ~= "string" or root == "" then return nil, "spool_failed" end
    local path = root
    for part in XoppJob.SPOOL_SUBDIR:gmatch("[^/]+") do
        path = path .. "/" .. part
        local mode = lmode(fs, path)
        if mode == nil and fs.mkdir then
            pcall(fs.mkdir, path)
            mode = lmode(fs, path)
        end
        if mode ~= "directory" then return nil, "spool_failed" end
    end
    return path
end

--[[--
Delete this plugin's spools from an earlier, interrupted export.

Automatic, unlike `Export.orphans` in the reader's folder: this folder is
private, the prefix is ours, and one export runs at a time, so any spool here
when a new export opens is stale. Only regular files are removed -- a link
with our prefix is left, since removing it would be acting on a name we did
not create. `except` is the spool about to be used. Bounded like the other
sweep. Answers the count removed.
]]
function XoppJob.sweep(dir, fs, except)
    fs = fs or defaultFs()
    if type(fs.dir) ~= "function" then return 0 end
    local prefix = XoppJob.SPOOL_PREFIX
    local ok, found = pcall(function()
        local out, seen = {}, 0
        for name in fs.dir(dir) do
            seen = seen + 1
            if seen > XoppJob.SWEEP_MAX_ENTRIES then break end
            if name:sub(1, #prefix) == prefix then
                local path = dir .. "/" .. name
                if path ~= except and lmode(fs, path) == "file" then
                    out[#out + 1] = path
                end
            end
        end
        return out
    end)
    if not ok then
        logger.warn("JustDraw xopp: could not sweep spools:", tostring(found))
        return 0
    end
    local removed = 0
    for i = 1, #found do
        if fs.remove(found[i]) then removed = removed + 1 end
    end
    return removed
end

-- ---------------------------------------------------------------- the job

local Job = {}
Job.__index = Job

--[[--
  opts.repository    notebook store: getPage, strokeRevision, listStrokesBatch,
                     readStrokeChunk, listPages (whole-notebook verify only)
  opts.pages         the pages to export, in order (ids are what is kept)
  opts.notebook_id   set when `pages` is the whole notebook: the verify then
                     also re-lists it, so an added or removed page is caught
  opts.output        the compressed temporary to create (from `ink_export`)
  opts.fs            filesystem calls (see defaultFs)
  opts.spool_dir     private folder; default `spoolDirectory()`
  opts.token         unique part of the spool name
  opts.title         document title; one XML cannot carry becomes "JustDraw"
  opts.archive       the archive adapter module (injectable for specs)
  opts.backend       passed to the adapter in place of KOReader's library
  opts.spool_cap     bytes; default SPOOL_CAP
  opts.limits        per-turn counts; see DEFAULT_LIMITS
  opts.units_per_mm  default the notebook layout's LOGICAL_UNITS_PER_MM (8),
                     required lazily: the layout module brings in Device
]]
function XoppJob.new(opts)
    opts = opts or {}
    local repository = opts.repository
    if type(repository) ~= "table" then return nil, "no_repository" end
    if type(opts.pages) ~= "table" or #opts.pages < 1 then return nil, "empty" end
    if #opts.pages > Xopp.MAX_PAGES then return nil, "too_many_pages" end
    if type(opts.output) ~= "string" or opts.output == "" then return nil, "bad_name" end

    local ids = {}
    for i = 1, #opts.pages do
        local id = type(opts.pages[i]) == "table" and positiveInteger(opts.pages[i].id)
        if not id then return nil, "bad_surface" end
        ids[i] = id
    end

    local limits = {}
    for key, default in pairs(XoppJob.DEFAULT_LIMITS) do
        limits[key] = positiveInteger(opts.limits and opts.limits[key]) or default
    end
    if limits.metas > 200 then limits.metas = 200 end

    local title = opts.title
    if type(title) ~= "string" or not Xopp.escapeText(title) then title = "JustDraw" end

    return setmetatable({
        repository = repository,
        ids = ids,
        notebook_id = positiveInteger(opts.notebook_id),
        output = opts.output,
        fs = opts.fs or defaultFs(),
        spool_dir = opts.spool_dir,
        token = tostring(opts.token or (os.time() .. "-" .. math.random(100000, 999999))),
        title = title,
        archive = opts.archive or require("ink_export_xopp_archive"),
        backend = opts.backend,
        spool_cap = tonumber(opts.spool_cap) or XoppJob.SPOOL_CAP,
        limits = limits,
        units_per_mm = opts.units_per_mm
            or require("ink_notebook_layout").LOGICAL_UNITS_PER_MM,
        mtime = opts.mtime,

        state = "open",
        closed = false,
        pages = {},        -- snapshot rows, by index
        revisions = {},    -- snapshot revisions, by index
        index = 0,         -- the page being snapshotted / written / verified
        pages_done = 0,
        spool_path = nil,
        spool = nil,       -- write handle
        spool_bytes = 0,
        reader = nil,      -- read handle during compression
        read_bytes = 0,
        writer = nil,      -- the XML writer
        packer = nil,      -- the archive writer
        page = nil,        -- the page being written
        stroke = nil,      -- the one resident stroke
        metas = nil,
        meta_at = 1,
        meta_n = 0,        -- the batch's length; its consumed slots are nil
        after = nil,       -- keyset cursor { paint_seq, seq }
        list_after = nil,  -- keyset cursor over pages during verify
        list_seen = 0,
    }, Job)
end

--[[--
A factory for `ink_export`'s `produce` seam: the export supplies the output
temporary, its filesystem, the token, the title and the pages; the caller
supplies the store and, for a whole notebook, its id.
]]
function XoppJob.producer(opts)
    return function(ctx)
        local merged = {}
        for k, v in pairs(opts or {}) do merged[k] = v end
        merged.output = ctx.output
        merged.fs = merged.fs or ctx.fs
        merged.token = ctx.token
        merged.title = merged.title or ctx.title
        merged.pages = merged.pages or ctx.items
        return XoppJob.new(merged)
    end
end

--[[--
What `ink_export_dialog` needs for a notebook export to Xournal++: the pages,
a producer instead of a renderer, and the progress modal even for one page --
compression can take a while after the last page is read, and Cancel has to
be reachable during it.
]]
function XoppJob.build(opts)
    return {
        items = opts.items,
        title = opts.title,
        flush = opts.flush,
        show_progress = true,
        -- Pages done, at most every two seconds: a notebook can take a while.
        progress_interval = 2,
        produce = XoppJob.producer{
            repository = opts.repository,
            notebook_id = opts.notebook_id,
            title = opts.title,
        },
    }
end

-- ----------------------------------------------------------------- sinking

--- The writer's sink: into the spool, counted and capped, every write checked.
function Job:_sink(chunk)
    local spool = self.spool
    if not spool then return nil, "spool_failed" end
    if self.spool_bytes + #chunk > self.spool_cap then
        self.over_cap = true
        return nil, "spool_too_large"
    end
    local ok, err = spool:write(chunk)
    if not ok then
        logger.warn("JustDraw xopp: spool write failed:", tostring(err))
        return nil, "spool_failed"
    end
    self.spool_bytes = self.spool_bytes + #chunk
    return true
end

--- A writer failure, in this module's vocabulary.
function Job:_writerFailure(err)
    if self.over_cap or err == "spool_too_large" then return "spool_too_large" end
    if err == "spool_failed" or self.writer and self.writer:failure() then
        return "spool_failed"
    end
    return "bad_surface"
end

-- ------------------------------------------------------------------ phases

function Job:_open()
    local fs = self.fs
    local dir = self.spool_dir
    if not dir then
        local err
        dir, err = XoppJob.spoolDirectory(fs)
        if not dir then return nil, err end
        self.spool_dir = dir
    end
    local path = dir .. "/" .. XoppJob.SPOOL_PREFIX .. self.token .. ".xml"
    XoppJob.sweep(dir, fs, path)
    -- Neither name may exist yet: the spool is unique by token and the output
    -- is `ink_export`'s own temporary. Anything there -- a link above all --
    -- is not ours to write through.
    if lmode(fs, path) ~= nil or lmode(fs, self.output) ~= nil then
        return nil, "spool_failed"
    end
    local handle, open_err = fs.open(path, "wb")
    if not handle then
        logger.warn("JustDraw xopp: cannot create spool:", tostring(open_err))
        return nil, "spool_failed"
    end
    self.spool, self.spool_path = handle, path

    local writer, err = Xopp.beginDocument(function(chunk) return self:_sink(chunk) end, {
        units_per_mm = self.units_per_mm,
        title = self.title,
        block_limit = XoppJob.BLOCK,
    })
    if not writer then return nil, self:_writerFailure(err) end
    self.writer = writer
    self.state = "snapshot"
    self.index = 0
    return true
end

--- One page's stroke revision, compared by value.
local function sameRevision(a, b)
    return a and b and a.count == b.count and a.max_seq == b.max_seq
        and a.max_id == b.max_id
end

--- The page row fields that change what is exported, compared by value.
--- `revision` is the page's transactional content revision (schema v3,
--- ADR-58): bumped in the same transaction as every committed edit, so it
--- catches what a stroke count and a one-second `updated_at` can miss --
--- an erase, a purge and a new stroke landing on the same numbers.
local function samePage(a, b)
    return a and b and a.id == b.id and a.logical_w == b.logical_w
        and a.logical_h == b.logical_h and a.template_kind == b.template_kind
        and a.updated_at == b.updated_at and a.revision == b.revision
end

--- A read that answered nothing: gone is a change, anything else a failure.
local function readFailure(err)
    if err == "not_found" then return "notebook_changed" end
    return "list_failed"
end

function Job:_snapshot()
    local repo = self.repository
    for _ = 1, self.limits.pages do
        local i = self.index + 1
        if i > #self.ids then
            self.state = "pages"
            self.index = 1
            return true
        end
        local page, err = repo:getPage(self.ids[i])
        if not page then return nil, readFailure(err) end
        local revision, rev_err = repo:strokeRevision(self.ids[i])
        if not revision then return nil, readFailure(rev_err) end
        self.pages[i], self.revisions[i] = page, revision
        self.index = i
    end
    return true
end

--- Whether the page's strokes still match the snapshot; for telling a
--- deleted stroke from a damaged one.
function Job:_pageChanged(i)
    local revision = self.repository:strokeRevision(self.ids[i])
    return not sameRevision(revision, self.revisions[i])
end

--- Start the next stroke from the resident metadata batch.
function Job:_openStroke(page, meta)
    if tonumber(meta.point_count) == nil or meta.point_count < 1 then
        return nil, "bad_surface"
    end
    local decoder, err = Codec.newDecoder(page.logical_w, page.logical_h, meta)
    if not decoder then
        logger.warn("JustDraw xopp: stroke", meta.id, "cannot be decoded:", err)
        return nil, "bad_surface"
    end
    self.stroke = {
        meta = meta, decoder = decoder, points = {}, n = 0,
        next_chunk = 0, chunk_count = Codec.chunkCount(meta.point_count),
    }
    return true
end

--- Read one chunk into the resident stroke; write the stroke when complete.
function Job:_readChunk()
    local stroke = self.stroke
    local meta = stroke.meta
    local row, err = self.repository:readStrokeChunk(meta.id, stroke.next_chunk)
    if not row then
        if err == "missing_chunk" and self:_pageChanged(self.index) then
            return nil, "notebook_changed"
        end
        if err == "missing_chunk" then return nil, "bad_surface" end
        return nil, "list_failed"
    end
    local points, n, from = stroke.decoder:push(row.chunk_no, row.point_count, row.points)
    if not points then
        logger.warn("JustDraw xopp: stroke", meta.id, "is damaged:", n)
        return nil, "bad_surface"
    end
    local out, count = stroke.points, stroke.n
    for k = from, n do
        count = count + 1
        out[count * 2 - 1] = points[k * 2 - 1]
        out[count * 2] = points[k * 2]
    end
    stroke.n = count
    stroke.next_chunk = stroke.next_chunk + 1
    if stroke.next_chunk < stroke.chunk_count then return true end

    local finished, finish_err = stroke.decoder:finish()
    if not finished then
        logger.warn("JustDraw xopp: stroke", meta.id, "is damaged:", finish_err)
        return nil, "bad_surface"
    end
    local ok, write_err = self.writer:writeStroke{
        points = out, n = count, width = meta.width, tool = meta.tool,
    }
    -- Dropped before anything else runs: this is the line that keeps one
    -- stroke, and only one, resident.
    self.stroke = nil
    if not ok then
        if self.writer:failure() then return nil, self:_writerFailure(write_err) end
        logger.warn("JustDraw xopp: stroke", meta.id, "refused:", write_err)
        return nil, "bad_surface"
    end
    self.page.strokes = self.page.strokes + 1
    return true
end

--- The next keyset batch of the current page's metadata.
function Job:_readMetas()
    local page = self.page
    local opts = { limit = self.limits.metas }
    if self.after then
        opts.after_paint_seq, opts.after_seq = self.after[1], self.after[2]
    end
    local batch, err = self.repository:listStrokesBatch(page.row.id, opts)
    if not batch then return nil, readFailure(err) end
    if #batch == 0 then
        page.exhausted = true
        self.metas = nil
        return true
    end
    if #batch > self.limits.metas then return nil, "list_failed" end
    local last = batch[#batch]
    local key, seq = last.paint_seq or last.seq, last.seq
    -- The cursor has to move strictly forward, or a repository that answered
    -- the same row twice would spin this page forever.
    if self.after and (key < self.after[1]
        or (key == self.after[1] and seq <= self.after[2])) then
        return nil, "list_failed"
    end
    self.after = { key, seq }
    self.metas, self.meta_at, self.meta_n = batch, 1, #batch
    return true
end

function Job:_pages()
    local budget = self.limits.chunks
    while budget > 0 do
        if not self.page then
            local i = self.index
            local row = self.pages[i]
            if not row then
                self.state = "xml_end"
                return true
            end
            local ok, err = self.writer:beginPage{
                width = row.logical_w, height = row.logical_h,
                paper = row.template_kind,
            }
            if not ok then return nil, self:_writerFailure(err) end
            self.page = { row = row, strokes = 0, exhausted = false }
            self.after, self.metas, self.meta_at = nil, nil, 1
        end

        if self.stroke then
            local ok, err = self:_readChunk()
            if not ok then return nil, err end
            budget = budget - 1
        elseif self.metas and self.meta_at <= self.meta_n then
            local meta = self.metas[self.meta_at]
            self.metas[self.meta_at] = nil
            self.meta_at = self.meta_at + 1
            local ok, err = self:_openStroke(self.page.row, meta)
            if not ok then return nil, err end
        elseif not self.page.exhausted then
            local ok, err = self:_readMetas()
            if not ok then return nil, err end
            budget = budget - 1
        else
            local ok, err = self.writer:endPage()
            if not ok then return nil, self:_writerFailure(err) end
            -- Fewer or more strokes than the snapshot counted: something was
            -- drawn or erased on this page since. Stop now rather than after
            -- compressing a file that will be refused anyway.
            if self.page.strokes ~= self.revisions[self.index].count then
                return nil, "notebook_changed"
            end
            self.page = nil
            self.pages_done = self.index
            self.index = self.index + 1
        end
    end
    return true
end

function Job:_closeSpool()
    local handle = self.spool
    self.spool = nil
    if not handle then return true end
    -- A buffered write fails here, if anywhere; `close` answers true or
    -- nil, message -- never false.
    local ok, err = handle:close()
    if not ok then
        logger.warn("JustDraw xopp: spool close failed:", tostring(err))
        return nil, "spool_failed"
    end
    return true
end

function Job:_xmlEnd()
    local ok, err = self.writer:endDocument()
    if not ok then return nil, self:_writerFailure(err) end
    local closed, close_err = self:_closeSpool()
    if not closed then return nil, close_err end
    -- The count is what the header will declare; the file has to agree.
    local size = self.fs.attributes(self.spool_path, "size")
    if size ~= nil and size ~= self.spool_bytes then return nil, "spool_failed" end
    self.writer = nil
    self.state = "compress_open"
    return true
end

function Job:_compressOpen()
    local reader, open_err = self.fs.open(self.spool_path, "rb")
    if not reader then
        logger.warn("JustDraw xopp: cannot reopen spool:", tostring(open_err))
        return nil, "spool_failed"
    end
    self.reader = reader
    if lmode(self.fs, self.output) ~= nil then return nil, "archive_failed" end
    local packer, err, detail = self.archive.open(self.output, {
        size = self.spool_bytes, backend = self.backend, mtime = self.mtime,
    })
    if not packer then
        logger.warn("JustDraw xopp: archive open failed:", tostring(err), tostring(detail))
        if err == "archive_unavailable" then return nil, err end
        return nil, "archive_failed"
    end
    self.packer = packer
    self.read_bytes = 0
    self.state = "compress"
    return true
end

function Job:_closeReader()
    local reader = self.reader
    self.reader = nil
    if reader then pcall(reader.close, reader) end
end

function Job:_compress()
    for _ = 1, self.limits.blocks do
        local block = self.reader:read(XoppJob.BLOCK)
        if block == nil or block == "" then
            self:_closeReader()
            -- A read error looks like an early end of file; the count is
            -- what tells the two apart.
            if self.read_bytes ~= self.spool_bytes then return nil, "spool_failed" end
            local packer = self.packer
            self.packer = nil
            local ok, err, detail = packer:close()
            if not ok then
                logger.warn("JustDraw xopp: archive close failed:", tostring(detail))
                return nil, err == "archive_unavailable" and err or "archive_failed"
            end
            self.state = "validate"
            return true
        end
        self.read_bytes = self.read_bytes + #block
        if self.read_bytes > self.spool_bytes then return nil, "spool_failed" end
        local ok, err, detail = self.packer:write(block)
        if not ok then
            logger.warn("JustDraw xopp: archive write failed:", tostring(detail))
            return nil, "archive_failed"
        end
    end
    return true
end

function Job:_validate()
    local size = self.fs.attributes(self.output, "size")
    if type(size) ~= "number" or size < self.archive.MIN_SIZE then
        return nil, "archive_invalid"
    end
    local ok, err, detail = self.archive.verify(self.output, self.spool_bytes, self.fs)
    if not ok then
        logger.warn("JustDraw xopp: output rejected:", tostring(detail))
        return nil, err or "archive_invalid"
    end
    self.state = self.notebook_id and "verify_list" or "verify"
    self.index = 0
    self.list_after, self.list_seen = nil, 0
    return true
end

--- Whole notebook only: the same pages, in the same order, and no others.
function Job:_verifyList()
    local batch, err = self.repository:listPages(self.notebook_id, {
        limit = 100,
        after_sort_key = self.list_after and self.list_after[1],
        after_id = self.list_after and self.list_after[2],
    })
    if not batch then return nil, "list_failed" end
    if #batch == 0 then
        if self.list_seen ~= #self.ids then return nil, "notebook_changed" end
        self.state = "verify"
        self.index = 0
        return true
    end
    for k = 1, #batch do
        local seen = self.list_seen + k
        if self.ids[seen] ~= batch[k].id then return nil, "notebook_changed" end
    end
    self.list_seen = self.list_seen + #batch
    local last = batch[#batch]
    if self.list_after and self.list_after[1] == last.sort_key
        and self.list_after[2] == last.id then
        return nil, "list_failed"
    end
    self.list_after = { last.sort_key, last.id }
    return true
end

--- Every exported page, and its strokes, exactly as at the snapshot.
function Job:_verify()
    local repo = self.repository
    for _ = 1, self.limits.pages do
        local i = self.index + 1
        if i > #self.ids then
            self.state = "cleanup"
            return true
        end
        local page, err = repo:getPage(self.ids[i])
        if not page then return nil, readFailure(err) end
        if not samePage(page, self.pages[i]) then return nil, "notebook_changed" end
        local revision, rev_err = repo:strokeRevision(self.ids[i])
        if not revision then return nil, readFailure(rev_err) end
        if not sameRevision(revision, self.revisions[i]) then
            return nil, "notebook_changed"
        end
        self.index = i
    end
    return true
end

--- The spool is not needed any more. A spool that will not go is left for
--- the next start's sweep: the export itself is finished and correct.
function Job:_removeSpool()
    local path = self.spool_path
    self.spool_path = nil
    if not path then return end
    local ok, removed, err = pcall(self.fs.remove, path)
    if not ok or not removed then
        logger.warn("JustDraw xopp: spool left for the next sweep:", tostring(err or removed))
    end
end

local PHASES = {
    open = "_open",
    snapshot = "_snapshot",
    pages = "_pages",
    xml_end = "_xmlEnd",
    compress_open = "_compressOpen",
    compress = "_compress",
    validate = "_validate",
    verify_list = "_verifyList",
    verify = "_verify",
}

--[[--
One bounded piece of work. Answers "more", "done", or nil and a reason; after
nil the job is closed. `ink_export` schedules the next call, and stops calling
on Cancel.
]]
function Job:step()
    if self.closed then return nil, self.failed or "cancelled" end
    if self.state == "cleanup" then
        self:_removeSpool()
        self.state = "done"
        return "done"
    end
    if self.state == "done" then return "done" end
    local name = PHASES[self.state]
    if not name then return nil, "internal_error" end
    local ran, ok, err = pcall(self[name], self)
    if not ran then
        logger.err("JustDraw xopp: unhandled error in", self.state, "--", tostring(ok))
        ok, err = nil, "internal_error"
    end
    if not ok then
        self.failed = err or "internal_error"
        self:close()
        return nil, self.failed
    end
    return "more"
end

--- Pages written so far, and pages in all.
function Job:progress()
    return self.pages_done, #self.ids
end

function Job:phase()
    return self.state
end

--- Instrumentation: how many points the job holds right now. By
--- construction at most one stroke's.
function Job:residentPoints()
    return self.stroke and self.stroke.n or 0
end

--- Instrumentation: how many stroke metadata rows are resident right now.
function Job:residentMetas()
    local metas = self.metas
    if not metas then return 0 end
    local count = 0
    for k = self.meta_at, self.meta_n do
        if metas[k] ~= nil then count = count + 1 end
    end
    return count
end

--[[--
Release everything this job holds, from any phase. Idempotent. The spool is
removed; the archive handle is freed; the output file is *not* removed --
it is `ink_export`'s temporary, and `ink_export` removes it after this.
]]
function Job:close()
    if self.closed then return true end
    self.closed = true
    self.stroke, self.metas, self.page = nil, nil, nil
    if self.packer then
        pcall(self.packer.abort, self.packer)
        self.packer = nil
    end
    self:_closeReader()
    if self.spool then
        pcall(self.spool.close, self.spool)
        self.spool = nil
    end
    self.writer = nil
    self:_removeSpool()
    if self.state ~= "done" and not self.failed then self.failed = "cancelled" end
    return true
end

XoppJob.Job = Job

return XoppJob
