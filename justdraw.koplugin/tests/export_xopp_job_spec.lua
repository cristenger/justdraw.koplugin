--[[--
The Xournal++ export job: bounded reads, a checked archive, and a file that is
published only if it still describes the notebook.

What these cases defend, in the order the job meets them:

- **Memory.** One stroke's points resident at a time, whatever the page count
  or page size. Stated through an instrumented repository: at every chunk read
  the job may hold only the stroke being read, and every stroke already written
  must be collectable (a weak table and a full collection say so).
- **Turns.** Every scheduler turn does a bounded number of reads, and Cancel
  observed at any turn -- in every phase -- leaves nothing: no spool, no
  temporary beside the destination, no archive handle, and no read after it.
- **Checked I/O.** A failure in each call that can fail -- a read, the spool's
  open/write/close, the archive's open/header/write/close/free, the gzip
  check, the rename, the cleanup -- ends in the right reason and removes what
  the job created. The cleanup failure is the one that does not fail the
  export: the file is complete, and the next start sweeps the spool.
- **Consistency.** A stroke drawn or erased, a paper changed, a page added or
  removed while exporting: the file is refused before it is published.
- **Names.** The PDF's policy: never over an existing name without the
  reader's yes, including a name that appears during the export and a
  dangling link.

The archive is a fake libarchive that writes a pseudo-gzip (real magic and
real trailer length, stored payload) into the fake filesystem, so the XML can
be read back here and the adapter's verification runs on real bytes.
tests/xopp_archive_native.lua does the same against KOReader's own library.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Export = require("ink_export")
    local XoppJob = require("ink_export_xopp_job")
    local Archive = require("ink_export_xopp_archive")
    local Xopp = require("ink_export_xopp")
    local Codec = require("ink_canvas_codec")
    local Dialog = require("ink_export_dialog")

    local DIR = "/mnt/us/exports"
    local SPOOL = "/mnt/us/koreader/cache/justdraw-xopp"
    local TARGET = DIR .. "/Notebook.xopp"
    local TEMP = DIR .. "/" .. Export.TEMP_PREFIX .. "TOKEN-1.xopp"
    local SPOOL_FILE = SPOOL .. "/" .. XoppJob.SPOOL_PREFIX .. "TOKEN.xml"
    local W, H = 1184, 1680 -- A5 at 8 units per millimetre

    -- =============================================================== fakes

    local GZ_HEAD = string.char(0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3)

    local function le32(v)
        v = v % 4294967296
        local b = {}
        for i = 1, 4 do
            b[i] = string.char(v % 256)
            v = math.floor(v / 256)
        end
        return table.concat(b)
    end

    --[[--
    libarchive's write calls, over the fake filesystem. The file appears at
    open (as the real one does), grows as data is written, and gets its
    trailer at close. `fail` breaks one call: format, filter, open, header,
    write_at = k (answer -1), short_at = k (one byte short), close, free,
    bad_trailer (close "succeeds" but the length is wrong).
    ]]
    local function newBackend(fs, fail)
        fail = fail or {}
        local state = { live = 0, writes = 0, max_block = 0, entries_live = 0,
            headers = {}, calls = {} }
        local lib = { ARCHIVE_OK = 0, AE_IFREG = 32768 }
        local function call(name) state.calls[#state.calls + 1] = name end
        function lib.archive_write_new()
            call("new")
            state.live = state.live + 1
            return { parts = {}, written = 0 }
        end
        function lib.archive_write_set_format_by_name(a, name)
            call("format"); a.format = name
            return fail.format and -30 or 0
        end
        function lib.archive_write_add_filter_by_name(a, name)
            call("filter"); a.filter = name
            return fail.filter and -30 or 0
        end
        function lib.archive_write_open_filename(a, path)
            call("open")
            if fail.open then return -30 end
            a.path = path
            fs.files[path] = GZ_HEAD
            return 0
        end
        function lib.archive_entry_new()
            state.entries_live = state.entries_live + 1
            return {}
        end
        function lib.archive_entry_free(e)
            if not e.freed then state.entries_live = state.entries_live - 1 end
            e.freed = true
        end
        function lib.archive_entry_set_pathname(e, v) e.name = v end
        function lib.archive_entry_set_filetype(e, v) e.filetype = v end
        function lib.archive_entry_set_perm(e, v) e.perm = v end
        function lib.archive_entry_set_size(e, v) e.size = v end
        function lib.archive_entry_set_mtime(e, v) e.mtime = v end
        function lib.archive_write_header(a, e)
            call("header")
            state.headers[#state.headers + 1] = { size = e.size, filetype = e.filetype }
            a.size = e.size
            return fail.header and -30 or 0
        end
        function lib.archive_write_data(a, data, len)
            state.writes = state.writes + 1
            if len > state.max_block then state.max_block = len end
            if fail.write_at == state.writes then return -30 end
            if fail.short_at == state.writes then len = len - 1 end
            a.parts[#a.parts + 1] = data:sub(1, len)
            a.written = a.written + len
            if a.path then fs.files[a.path] = GZ_HEAD .. table.concat(a.parts) end
            return len
        end
        function lib.archive_write_close(a)
            call("close")
            if fail.close then return -30 end
            local size = fail.bad_trailer and a.written + 1 or a.written
            fs.files[a.path] = GZ_HEAD .. table.concat(a.parts) .. le32(0) .. le32(size)
            return 0
        end
        function lib.archive_write_free(a)
            call("free")
            if not a.freed then state.live = state.live - 1 end
            a.freed = true
            return fail.free and -30 or 0
        end
        function lib.archive_error_string() return "fake archive error" end
        return { lib = lib, cstring = function(s) return s end }, state
    end

    local function points(n, salt)
        local out = {}
        for k = 1, n do
            out[k * 2 - 1] = (k * 37 + salt * 11) % (W - 1)
            out[k * 2] = (k * 53 + salt * 7) % (H - 1)
        end
        return out
    end

    --[[--
    A notebook in memory with the store's read calls, counted and scriptable.
    `hooks.on_chunk(id, chunk_no)` runs before every chunk read; `fail.<call>`
    makes that call answer nil and the reason.
    ]]
    local function newRepo(spec)
        spec = spec or {}
        local repo = { rows = {}, metas = {}, chunks = {}, next_id = 1000,
            reads = { chunks = 0, batches = 0, pages = 0, revisions = 0, lists = 0 },
            fail = {}, hooks = {}, corrupt = {}, point_counts = {} }

        function repo:add(row, s)
            local list = self.metas[row.id]
            local seq = 0
            for i = 1, #list do if list[i].seq > seq then seq = list[i].seq end end
            seq = seq + 1
            self.next_id = self.next_id + 1
            local id = self.next_id
            local n = s.n or 3
            local pts = s.points or points(n, id)
            local chunks = {}
            assert(Codec.eachEncodedChunk(pts, n, row.logical_w, row.logical_h,
                function(chunk_no, count, blob)
                    chunks[chunk_no] = { chunk_no = chunk_no, point_count = count, points = blob }
                    return true
                end))
            self.chunks[id] = chunks
            self.point_counts[id] = n
            list[#list + 1] = { id = id, seq = seq, paint_seq = s.paint_seq or seq,
                width = s.width or 16, tool = s.tool or 1, codec = 1, point_count = n }
            row.updated_at = row.updated_at + 1
            return id
        end

        function repo:appendPage(p)
            p = p or {}
            local i = #self.rows + 1
            local row = { id = 10 + i, notebook_id = 1, sort_key = 1024 * i,
                logical_w = p.w or W, logical_h = p.h or H,
                template_kind = p.template or "blank", updated_at = 100 }
            self.rows[i] = row
            self.metas[row.id] = {}
            for k = 1, #(p.strokes or {}) do self:add(row, p.strokes[k]) end
            return row
        end

        for i = 1, #(spec.pages or {}) do repo:appendPage(spec.pages[i]) end

        local function copy(row)
            local out = {}
            for k, v in pairs(row) do out[k] = v end
            return out
        end
        local function rowById(id)
            for i = 1, #repo.rows do
                if repo.rows[i].id == id and not repo.rows[i].deleted then return repo.rows[i] end
            end
        end

        function repo:pages()
            local out = {}
            for i = 1, #self.rows do
                if not self.rows[i].deleted then out[#out + 1] = copy(self.rows[i]) end
            end
            return out
        end

        function repo:getPage(id)
            self.reads.pages = self.reads.pages + 1
            if self.fail.page then return nil, self.fail.page end
            local row = rowById(id)
            if not row then return nil, "not_found" end
            return copy(row)
        end

        function repo:strokeRevision(id)
            self.reads.revisions = self.reads.revisions + 1
            if self.fail.revision then return nil, self.fail.revision end
            local count, max_seq, max_id = 0, 0, 0
            for _, m in ipairs(self.metas[id] or {}) do
                if not m.deleted then
                    count = count + 1
                    if m.seq > max_seq then max_seq = m.seq end
                    if m.id > max_id then max_id = m.id end
                end
            end
            return { count = count, max_seq = max_seq, max_id = max_id }
        end

        function repo:listStrokesBatch(page_id, opts)
            self.reads.batches = self.reads.batches + 1
            if self.fail.batch then return nil, self.fail.batch end
            local live = {}
            for _, m in ipairs(self.metas[page_id] or {}) do
                if not m.deleted then live[#live + 1] = m end
            end
            table.sort(live, function(a, b)
                if a.paint_seq ~= b.paint_seq then return a.paint_seq < b.paint_seq end
                return a.seq < b.seq
            end)
            local out = {}
            for _, m in ipairs(live) do
                local after = opts.after_paint_seq == nil
                    or m.paint_seq > opts.after_paint_seq
                    or (m.paint_seq == opts.after_paint_seq and m.seq > opts.after_seq)
                if after and #out < opts.limit then out[#out + 1] = copy(m) end
            end
            return out
        end

        function repo:readStrokeChunk(id, chunk_no)
            self.reads.chunks = self.reads.chunks + 1
            if self.hooks.on_chunk then self.hooks.on_chunk(id, chunk_no) end
            if self.fail.chunk then return nil, self.fail.chunk end
            for _, list in pairs(self.metas) do
                for _, m in ipairs(list) do
                    if m.id == id and m.deleted then return nil, "missing_chunk" end
                end
            end
            if self.missing and self.missing[id] then return nil, "missing_chunk" end
            local chunk = self.chunks[id] and self.chunks[id][chunk_no]
            if not chunk then return nil, "missing_chunk" end
            if self.corrupt[id] then
                return { chunk_no = chunk_no, point_count = chunk.point_count,
                    points = chunk.points:sub(1, -2) }
            end
            return copy(chunk)
        end

        function repo:listPages(notebook_id, opts)
            self.reads.lists = self.reads.lists + 1
            if self.fail.list then return nil, self.fail.list end
            local out = {}
            for i = 1, #self.rows do
                local row = self.rows[i]
                local after = opts.after_sort_key == nil
                    or row.sort_key > opts.after_sort_key
                    or (row.sort_key == opts.after_sort_key and row.id > opts.after_id)
                if not row.deleted and after and #out < opts.limit then
                    out[#out + 1] = copy(row)
                end
            end
            return out
        end

        function repo:deleteStroke(page_index, k)
            local m = self.metas[self.rows[page_index].id][k]
            m.deleted = true
            self.rows[page_index].updated_at = self.rows[page_index].updated_at + 1
        end

        function repo:totalReads()
            local r = self.reads
            return r.chunks + r.batches + r.pages + r.revisions + r.lists
        end

        return repo
    end

    --- A notebook of `pages` pages with `strokes` strokes of `n` points each.
    local function notebook(pages, strokes, n, extra)
        local spec = { pages = {} }
        for i = 1, pages do
            local list = {}
            for k = 1, strokes do list[k] = { n = n, width = 8 + k, tool = 1 } end
            spec.pages[i] = { strokes = list, template = extra and extra.template }
        end
        return spec
    end

    --[[--
    One export, through `ink_export`, with every dependency a fake.
      opts.repo / opts.spec    the notebook
      opts.page_scope          export without the whole-notebook re-list
      opts.archive_fail        see newBackend
      opts.no_backend          use the real loader (absent in a bare LuaJIT)
      fs options pass through (files, fail_*, links)
    ]]
    local function run(opts)
        opts = opts or {}
        if Export.isRunning() then Export.cancelRunning() end
        local dirs = { [DIR] = true, [SPOOL] = true }
        for k, v in pairs(opts.dirs or {}) do dirs[k] = v end
        local fs = support.newExportFs{
            dirs = dirs, files = opts.files, links = opts.links,
            fail_open = opts.fail_open, fail_write = opts.fail_write,
            fail_close = opts.fail_close, fail_rename = opts.fail_rename,
            fail_remove = opts.fail_remove, fail_read = opts.fail_read,
        }
        local repo = opts.repo or newRepo(opts.spec or notebook(2, 3, 5))
        local backend, arch = newBackend(fs, opts.archive_fail)
        local sched = support.newScheduler()
        local log = { progress = {}, done = 0 }
        local job, err, extra = Export.start{
            format = "xopp", dir = DIR, stem = opts.stem or "Notebook",
            title = opts.title,
            items = opts.items or repo:pages(),
            overwrite = opts.overwrite, token = "TOKEN", fs = fs,
            schedule = function(fn) sched:schedule(fn) end,
            sanitize = function(name) return name end,
            flush = function() return true end,
            produce = XoppJob.producer{
                repository = repo,
                notebook_id = (not opts.page_scope) and 1 or nil,
                spool_dir = opts.spool_dir or SPOOL,
                backend = (not opts.no_backend) and backend or nil,
                limits = opts.limits,
                spool_cap = opts.spool_cap,
            },
            on_progress = function(done) log.progress[#log.progress + 1] = done end,
            on_done = function(result)
                log.done = log.done + 1
                log.result = result
            end,
        }
        return { job = job, err = err, extra = extra, fs = fs, repo = repo,
            arch = arch, sched = sched, log = log }
    end

    --- Nothing of the job's own survives: no temporary beside the target, no
    --- spool, no archive or entry handle.
    local function clean(r, label)
        t:eq(#r.fs.temporaries(Export.TEMP_PREFIX), 0, label .. ": no temporary")
        t:eq(#r.fs.temporaries(XoppJob.SPOOL_PREFIX), 0, label .. ": no spool")
        t:eq(r.arch.live, 0, label .. ": the archive was freed")
        t:eq(r.arch.entries_live, 0, label .. ": the entry was freed")
    end

    local function failedWith(r, code, label)
        r.sched:drain()
        t:eq(r.log.done, 1, label .. ": finished once")
        t:eq(r.log.result and r.log.result.status, "failed", label .. ": failed")
        t:eq(r.log.result and r.log.result.error, code, label .. ": reason")
        t:eq(r.fs.files[TARGET], nil, label .. ": nothing published")
        clean(r, label)
    end

    local function xmlOf(r)
        local data = r.fs.files[TARGET]
        if not data then return nil end
        return data:sub(11, -9)
    end

    local function count(s, pattern)
        local n = 0
        for _ in s:gmatch(pattern) do n = n + 1 end
        return n
    end

    --- Turn the scheduler until the producer is in `phase`, before that turn.
    local function reach(r, phase)
        for _ = 1, 100000 do
            local p = r.job and r.job.producer
            if p and p:phase() == phase then return true end
            if not r.sched:tick() then return false end
        end
        return false
    end

    -- =================================================================
    t:describe("export / xopp job / the file")

    t:case("a notebook becomes one gzip of well-formed Xournal++ XML", function()
        local r = run{ spec = notebook(3, 4, 7) }
        t:check(r.job ~= nil, "started: " .. tostring(r.err))
        r.sched:drain()
        t:eq(r.log.result.status, "done", "finished: " .. tostring(r.log.result.error))
        t:eq(r.log.result.written[1], TARGET, "under the chosen name")
        local xml = xmlOf(r)
        t:eq(xml:sub(1, 5), "<?xml", "the XML declaration first")
        t:check(xml:find("<xournal ", 1, true) ~= nil, "a xournal root")
        t:eq(count(xml, "<page "), 3, "three pages")
        t:eq(count(xml, "</page>"), 3, "all closed")
        t:eq(count(xml, "<stroke "), 12, "every stroke")
        t:eq(xml:sub(-11), "</xournal>\n", "and the root closed last")
        t:eq(r.arch.headers[1].size, #xml, "the header declared the measured size")
        t:eq(r.arch.headers[1].filetype, 32768, "a regular entry")
        t:eq(r.arch.max_block <= XoppJob.BLOCK, true, "no block past the limit")
        clean(r, "success")
        t:eq(r.log.progress[#r.log.progress], 3, "progress reached the last page")
    end)

    t:case("strokes come out in paint order, not insertion order", function()
        -- Inserted as seq 1, 2, 3 with paint order 3, 1, 2: a moved stroke
        -- keeps its seq and changes its paint_seq.
        local r = run{ spec = { pages = { { strokes = {
            { n = 2, width = 8, paint_seq = 3 },
            { n = 2, width = 16, paint_seq = 1 },
            { n = 2, width = 24, paint_seq = 2 },
        } } } } }
        r.sched:drain()
        local widths = {}
        for w in xmlOf(r):gmatch('<stroke [^>]- width="([^"]+)"') do
            widths[#widths + 1] = w
        end
        local function pt(units) return Xopp.formatNumber(units / 8 * 72 / 25.4, true) end
        t:eq(table.concat(widths, ","), table.concat({ pt(16), pt(24), pt(8) }, ","),
            "paint_seq 1, 2, 3")
    end)

    t:case("ties in paint order fall back to seq", function()
        local r = run{ spec = { pages = { { strokes = {
            { n = 2, width = 8, paint_seq = 5 },
            { n = 2, width = 16, paint_seq = 5 },
        } } } }, limits = { metas = 1 } }
        r.sched:drain()
        local first = xmlOf(r):match('<stroke [^>]- width="([^"]+)"')
        t:eq(first, Xopp.formatNumber(8 / 8 * 72 / 25.4, true), "the lower seq first")
        t:eq(count(xmlOf(r), "<stroke "), 2, "and a one-row batch skipped neither")
    end)

    t:case("paper and page size reach the page element", function()
        local r = run{ spec = { pages = { { template = "grid", strokes = {} },
            { template = "checklist", strokes = {} } } } }
        r.sched:drain()
        local xml = xmlOf(r)
        t:check(xml:find('style="graph"', 1, true) ~= nil, "grid is graph")
        t:check(xml:find('style="ruled"', 1, true) ~= nil, "checklist falls back to ruled")
        local width = xml:match('<page width="([^"]+)"')
        t:eq(width, Xopp.formatNumber(W / 8 * 72 / 25.4, true), "148 mm in points")
    end)

    t:case("an empty notebook is refused; empty pages are not", function()
        local repo = newRepo{ pages = {} }
        local r = run{ repo = repo, items = {} }
        t:eq(r.job, nil, "no job")
        t:eq(r.err, "no_items", "nothing to export")
        t:eq(select(2, XoppJob.new{ repository = repo, pages = {}, output = TEMP }),
            "empty", "the job refuses too")

        local blank = run{ spec = notebook(2, 0, 1) }
        blank.sched:drain()
        t:eq(blank.log.result.status, "done", "pages without ink export")
        t:eq(count(xmlOf(blank), "<page "), 2, "as two pages")
        t:eq(count(xmlOf(blank), "<stroke "), 0, "with nothing on them")
    end)

    t:case("a title XML cannot carry becomes JustDraw rather than a failure", function()
        local r = run{ title = "bad\1title" }
        r.sched:drain()
        t:eq(r.log.result.status, "done", "exported")
        t:check(xmlOf(r):find("<title>JustDraw</title>", 1, true) ~= nil, "the fallback")
        local ok = run{ title = "Maths & <Physics>" }
        ok.sched:drain()
        t:check(xmlOf(ok):find("<title>Maths &amp; &lt;Physics&gt;</title>", 1, true) ~= nil,
            "and a real one escaped")
    end)

    t:case("a format written by a producer needs one", function()
        if Export.isRunning() then Export.cancelRunning() end
        local _, err = Export.start{ format = "xopp", dir = DIR, stem = "N",
            items = { {} }, schedule = function() end,
            render = function() end, fs = support.newExportFs{ dirs = { [DIR] = true } } }
        t:eq(err, "no_renderer", "a renderer is not a producer")
        local plan = Export.plan{ format = "xopp", dir = DIR, stem = "N", total = 40,
            fs = support.newExportFs{}, sanitize = function(n) return n end }
        t:eq(plan.files, 1, "one file for forty pages")
        t:eq(plan.targets[1], DIR .. "/N.xopp", "with its own extension")
    end)

    -- =================================================================
    t:describe("export / xopp job / memory and turns")

    --[[--
    The claim, stated as an instrument rather than as a hope.

    The XML writer is wrapped so every points table handed to it is recorded
    in a weak table. At every chunk read the repository forces a full
    collection and asks two things: that none of those tables survived --
    a stroke written is a stroke dropped -- and that what the job holds is no
    more than the stroke being read. Run at 3 and at 30 pages, the peaks
    are the same: memory does not follow the page count.
    ]]
    local function instrumented(pages, strokes, n)
        local alive = setmetatable({}, { __mode = "k" })
        local real = Xopp.beginDocument
        local stats = { survivors = 0, over = 0, peak_points = 0, peak_metas = 0, reads = 0 }
        Xopp.beginDocument = function(sink, o)
            local w, e = real(sink, o)
            if not w then return w, e end
            local proxy = {}
            setmetatable(proxy, { __index = function(_, k)
                local v = w[k]
                if type(v) == "function" then
                    return function(_, ...) return v(w, ...) end
                end
                return v
            end })
            function proxy.writeStroke(_, stroke)
                alive[stroke.points] = true
                return w:writeStroke(stroke)
            end
            return proxy
        end
        local ok, err = pcall(function()
            local repo = newRepo(notebook(pages, strokes, n))
            local r
            repo.hooks.on_chunk = function(id)
                stats.reads = stats.reads + 1
                collectgarbage("collect")
                for _ in pairs(alive) do stats.survivors = stats.survivors + 1 end
                local p = r.job.producer
                local held = p:residentPoints()
                if held > repo.point_counts[id] then stats.over = stats.over + 1 end
                if held > stats.peak_points then stats.peak_points = held end
                if p:residentMetas() > stats.peak_metas then stats.peak_metas = p:residentMetas() end
            end
            r = run{ repo = repo, limits = { metas = 4, chunks = 3 } }
            r.sched:drain()
            stats.result = r.log.result
            stats.strokes = count(xmlOf(r) or "", "<stroke ")
        end)
        Xopp.beginDocument = real
        assert(ok, err)
        return stats
    end

    t:case("at most one stroke's points are resident, at any page count", function()
        local few = instrumented(3, 3, 1100)
        local many = instrumented(30, 3, 1100)
        for _, s in ipairs({ few, many }) do
            t:eq(s.result.status, "done", "exported")
            t:eq(s.survivors, 0, "no written stroke outlived its write")
            t:eq(s.over, 0, "never more than the stroke being read")
            t:check(s.peak_metas <= 4, "metadata bounded by the batch")
        end
        t:eq(many.strokes, 90, "every stroke of thirty pages")
        t:check(many.reads > few.reads * 5, "ten times the pages, ten times the reads")
        t:eq(many.peak_points, few.peak_points, "and the same peak")
        t:check(many.peak_points <= 1100, "which is one stroke")
    end)

    t:case("one very large page is walked in bounded turns", function()
        local repo = newRepo{ pages = { { strokes = (function()
            local list = {}
            for k = 1, 60 do list[k] = { n = 2500, width = 8 } end
            return list
        end)() } } }
        local peak = 0
        repo.hooks.on_chunk = function() end
        local r = run{ repo = repo, limits = { metas = 8, chunks = 4 } }
        local turns, worst = 0, 0
        while true do
            local before = repo.reads.chunks + repo.reads.batches
            if not r.sched:tick() then break end
            turns = turns + 1
            local delta = repo.reads.chunks + repo.reads.batches - before
            if delta > worst then worst = delta end
            local p = r.job.producer
            if p and p:residentPoints() > peak then peak = p:residentPoints() end
        end
        t:eq(r.log.result.status, "done", "exported")
        t:eq(count(xmlOf(r), "<stroke "), 60, "all sixty strokes")
        t:check(worst <= 4, "never more than four reads in a turn: " .. worst)
        t:check(turns > 60 * 3 / 4, "so the page took many turns: " .. turns)
        t:check(peak <= 2500, "and held at most one stroke: " .. peak)
    end)

    t:case("many pages: every turn is bounded, snapshot and verify included", function()
        local repo = newRepo(notebook(120, 1, 2))
        local r = run{ repo = repo, limits = { pages = 10, chunks = 5 } }
        local worst = 0
        while true do
            local before = repo:totalReads()
            if not r.sched:tick() then break end
            local delta = repo:totalReads() - before
            if delta > worst then worst = delta end
        end
        t:eq(r.log.result.status, "done", "exported")
        t:eq(count(xmlOf(r), "<page "), 120, "every page")
        -- getPage + strokeRevision per page, ten pages a turn.
        t:check(worst <= 20, "at most twenty reads in any turn: " .. worst)
        t:eq(#r.log.progress > 10, true, "progress reported as pages completed")
    end)

    -- =================================================================
    t:describe("export / xopp job / cancellation")

    local PHASES = { "open", "snapshot", "pages", "xml_end", "compress_open",
        "compress", "validate", "verify_list", "verify", "cleanup" }

    t:case("Cancel in every phase leaves nothing and reads nothing after", function()
        for _, phase in ipairs(PHASES) do
            local r = run{ spec = notebook(6, 3, 900),
                limits = { pages = 2, chunks = 2, metas = 2, blocks = 1 } }
            t:check(reach(r, phase), phase .. ": reached")
            local reads = r.repo:totalReads()
            t:check(r.job:cancel(), phase .. ": cancelled")
            r.sched:drain()
            t:eq(r.log.result.status, "cancelled", phase .. ": reported as cancelled")
            t:eq(r.log.done, 1, phase .. ": once")
            t:eq(r.repo:totalReads(), reads, phase .. ": no read after Cancel")
            t:eq(r.fs.files[TARGET], nil, phase .. ": nothing published")
            clean(r, phase)
        end
    end)

    t:case("cancelRunning, as a document close does, is the same Cancel", function()
        local r = run{ spec = notebook(3, 2, 900), limits = { chunks = 1 } }
        reach(r, "pages")
        r.sched:tick()
        t:check(Export.cancelRunning(), "stopped")
        r.sched:drain()
        t:eq(r.log.result.status, "cancelled", "cancelled")
        clean(r, "lifecycle")
    end)

    -- =================================================================
    t:describe("export / xopp job / checked failures")

    t:case("a read that fails ends the export with the store's reason", function()
        for _, which in ipairs({ "chunk", "batch", "revision", "page", "list" }) do
            local repo = newRepo(notebook(2, 2, 5))
            repo.fail[which] = "disk I/O error"
            local r = run{ repo = repo }
            failedWith(r, "list_failed", which)
        end
    end)

    t:case("the spool: open, write, close and the cap each have their reason", function()
        failedWith(run{ fail_open = { [SPOOL_FILE] = "Permission denied" } },
            "spool_failed", "spool open")
        failedWith(run{ fail_write = { [SPOOL_FILE] = "No space left on device" } },
            "spool_failed", "spool write")
        -- The buffered write that fails only at close: a full disk.
        failedWith(run{ fail_close = { [SPOOL_FILE] = "No space left on device" } },
            "spool_failed", "spool close")
        failedWith(run{ spec = notebook(2, 3, 400), spool_cap = 4096 },
            "spool_too_large", "spool cap")
        failedWith(run{ fail_read = { [SPOOL_FILE] = "Input/output error" } },
            "spool_failed", "spool read back")
    end)

    t:case("the archive: every call is checked", function()
        for _, case in ipairs({
            { fail = { format = true }, name = "format" },
            { fail = { filter = true }, name = "filter" },
            { fail = { open = true }, name = "open" },
            { fail = { header = true }, name = "header" },
            { fail = { write_at = 1 }, name = "write error" },
            { fail = { short_at = 1 }, name = "short write" },
            { fail = { close = true }, name = "gzip close" },
            { fail = { free = true }, name = "free" },
        }) do
            local r = run{ archive_fail = case.fail }
            failedWith(r, "archive_failed", case.name)
        end
    end)

    t:case("a gzip whose trailer disagrees is not published", function()
        failedWith(run{ archive_fail = { bad_trailer = true } }, "archive_invalid", "trailer")
    end)

    t:case("no libarchive in this build is its own reason", function()
        -- The bare LuaJIT running the suite has no `ffi/loadlib`.
        failedWith(run{ no_backend = true }, "archive_unavailable", "no library")
    end)

    t:case("a rename that fails removes the temporary and the spool", function()
        failedWith(run{ fail_rename = { [TEMP] = "Read-only file system" } },
            "rename_failed", "rename")
    end)

    t:case("damaged ink is refused rather than silently dropped", function()
        local repo = newRepo(notebook(1, 3, 5))
        repo.corrupt[repo.metas[11][2].id] = true
        failedWith(run{ repo = repo }, "bad_surface", "corrupt chunk")

        local missing = newRepo(notebook(1, 3, 5))
        missing.missing = { [missing.metas[11][1].id] = true }
        failedWith(run{ repo = missing }, "bad_surface", "a chunk gone, nothing changed")

        local zero = newRepo{ pages = { { strokes = { { n = 2, width = 0 } } } } }
        failedWith(run{ repo = zero }, "bad_surface", "a stroke the writer refuses")
    end)

    t:case("a spool that will not go does not fail a finished export", function()
        local r = run{ fail_remove = { [SPOOL_FILE] = "Device or resource busy" } }
        r.sched:drain()
        t:eq(r.log.result.status, "done", "the file is complete and published")
        t:check(r.fs.files[TARGET] ~= nil, "it is there")
        t:check(r.fs.files[SPOOL_FILE] ~= nil, "the spool stayed")
        -- The next start sweeps it before creating its own.
        local fs = r.fs
        fs.fail_remove[SPOOL_FILE] = nil
        local removed = XoppJob.sweep(SPOOL, fs, SPOOL .. "/" .. XoppJob.SPOOL_PREFIX .. "NEXT.xml")
        t:eq(removed, 1, "and the next sweep takes it")
        t:eq(fs.files[SPOOL_FILE], nil, "gone")
    end)

    -- =================================================================
    t:describe("export / xopp job / the notebook changes underneath")

    t:case("a stroke drawn on a page already written is caught before publishing", function()
        local r = run{ spec = notebook(3, 2, 5), limits = { chunks = 2 } }
        reach(r, "compress")
        r.repo:add(r.repo.rows[1], { n = 3 })
        failedWith(r, "notebook_changed", "drawn")
    end)

    t:case("a stroke erased on the page being read is caught at once", function()
        local r = run{ spec = notebook(2, 4, 5), limits = { chunks = 1, metas = 1 } }
        reach(r, "pages")
        r.sched:tick(); r.sched:tick()
        r.repo:deleteStroke(1, 4)
        failedWith(r, "notebook_changed", "erased")
        t:check(r.repo.reads.lists == 0, "without waiting for the verify")
    end)

    t:case("a stroke erased while its chunks are read is a change, not damage", function()
        local repo = newRepo{ pages = { { strokes = { { n = 3000 } } } } }
        local r
        repo.hooks.on_chunk = function(_, chunk_no)
            if chunk_no == 1 then repo:deleteStroke(1, 1) end
        end
        r = run{ repo = repo }
        failedWith(r, "notebook_changed", "erased mid-read")
    end)

    t:case("a new content revision is a change even when the stroke counts match", function()
        -- Erase the newest stroke, purge it, draw another: count, max seq and
        -- max id can come back the same. The page's revision cannot.
        local r = run{ spec = notebook(2, 1, 3) }
        reach(r, "compress")
        r.repo.rows[1].revision = (r.repo.rows[1].revision or 1) + 1
        failedWith(r, "notebook_changed", "revision")
    end)

    t:case("new paper, a new page, or a removed page are all changes", function()
        local paper = run{ spec = notebook(2, 1, 3) }
        reach(paper, "compress")
        paper.repo.rows[2].template_kind = "grid"
        paper.repo.rows[2].updated_at = paper.repo.rows[2].updated_at + 1
        failedWith(paper, "notebook_changed", "paper")

        local added = run{ spec = notebook(2, 1, 3) }
        reach(added, "compress")
        added.repo:appendPage{}
        failedWith(added, "notebook_changed", "page added")

        local removed = run{ spec = notebook(3, 1, 3) }
        reach(removed, "compress")
        removed.repo.rows[3].deleted = true
        failedWith(removed, "notebook_changed", "page removed")

        local vanished = run{ spec = notebook(3, 1, 3), page_scope = true }
        reach(vanished, "compress")
        vanished.repo.rows[1].deleted = true
        failedWith(vanished, "notebook_changed", "an exported page removed")
    end)

    t:case("a single page is compared with itself only", function()
        local repo = newRepo(notebook(3, 1, 3))
        local r = run{ repo = repo, items = { repo:pages()[2] }, page_scope = true }
        reach(r, "compress")
        repo:add(repo.rows[1], { n = 2 }) -- another page
        r.sched:drain()
        t:eq(r.log.result.status, "done", "an edit elsewhere is not this page's")
        t:eq(repo.reads.lists, 0, "and the notebook was not re-listed")
        t:eq(count(xmlOf(r), "<page "), 1, "one page")
    end)

    t:case("a stale copy of the page row does not look like a change", function()
        -- The editor's current page may be a row read long ago; the snapshot
        -- is taken from the store, not from the item.
        local repo = newRepo(notebook(1, 1, 3))
        local stale = repo:pages()[1]
        stale.updated_at = 1
        local r = run{ repo = repo, items = { stale }, page_scope = true }
        r.sched:drain()
        t:eq(r.log.result.status, "done", "exported")
    end)

    -- =================================================================
    t:describe("export / xopp job / names and private files")

    t:case("an existing destination is the PDF's question, and Replace replaces", function()
        local r = run{ files = { [TARGET] = "old" } }
        t:eq(r.job, nil, "no job")
        t:eq(r.err, "file_exists", "the collision question")
        t:eq(r.extra[1], TARGET, "about this file")
        t:eq(r.repo:totalReads(), 0, "nothing was read")

        local yes = run{ files = { [TARGET] = "old" }, overwrite = true }
        yes.sched:drain()
        t:eq(yes.log.result.status, "done", "the reader said yes")
        t:check(yes.fs.files[TARGET]:sub(1, 2) == string.char(0x1f, 0x8b), "and it was replaced")
    end)

    t:case("a name that appears during the export is not replaced", function()
        local r = run{}
        reach(r, "compress")
        r.fs.files[TARGET] = "somebody else's"
        r.sched:drain()
        t:eq(r.log.result.status, "failed", "refused")
        t:eq(r.log.result.error, "destination_taken", "because the name is taken now")
        t:eq(r.fs.files[TARGET], "somebody else's", "and the other file is untouched")
        t:eq(#r.fs.renames, 0, "nothing was renamed over it")
        clean(r, "appeared")
    end)

    t:case("a dangling link counts as taken, and is never written through", function()
        local r = run{ links = { [TARGET] = "/nowhere/else.xopp" } }
        t:eq(r.err, "file_exists", "the link is reported like a file")
        local busy = run{ links = { [SPOOL_FILE] = "/mnt/us/koreader/settings/justdraw.sqlite3" } }
        failedWith(busy, "spool_failed", "a link at the spool name")
    end)

    t:case("the spool folder is created, and a link there is refused", function()
        local fs = support.newExportFs{ dirs = { ["/data"] = true } }
        local dir = XoppJob.spoolDirectory(fs, "/data")
        t:eq(dir, "/data/cache/justdraw-xopp", "under the data directory")
        t:check(fs.dirs["/data/cache/justdraw-xopp"], "created")
        local linked = support.newExportFs{ dirs = { ["/data"] = true, ["/elsewhere"] = true },
            links = { ["/data/cache"] = "/elsewhere" } }
        t:eq(select(2, XoppJob.spoolDirectory(linked, "/data")), "spool_failed",
            "a link in the path is not followed")
    end)

    t:case("the sweep takes only this plugin's stale regular files", function()
        local stale = SPOOL .. "/" .. XoppJob.SPOOL_PREFIX .. "OLD.xml"
        local other = SPOOL .. "/notes.txt"
        local link = SPOOL .. "/" .. XoppJob.SPOOL_PREFIX .. "LINK.xml"
        local r = run{ files = { [stale] = "<xml", [other] = "keep" },
            links = { [link] = "/mnt/us/important.txt" } }
        t:eq(r.fs.files[stale], "<xml", "not before the export starts")
        r.sched:tick()
        t:eq(r.fs.files[stale], nil, "the stale spool went at the start")
        t:eq(r.fs.files[other], "keep", "an unrelated file stayed")
        t:check(r.fs.links[link] ~= nil, "and a link with our prefix was not touched")
        r.sched:drain()
        t:eq(r.log.result.status, "done", "and the export went ahead")
    end)

    -- =================================================================
    t:describe("export / xopp job / archive adapter")

    t:case("the adapter checks the size it promised in both directions", function()
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        local backend, state = newBackend(fs)
        local w = assert(Archive.open(TEMP, { size = 4, backend = backend }))
        t:eq(select(2, w:write("12345")), "archive_failed", "more than declared")
        t:eq(state.live, 0, "and freed at once")
        w = assert(Archive.open(TEMP, { size = 4, backend = backend }))
        assert(w:write("12"))
        t:eq(select(2, w:close()), "archive_failed", "less than declared")
        t:eq(state.live, 0, "freed")
        w = assert(Archive.open(TEMP, { size = 4, backend = backend }))
        assert(w:write("12")); assert(w:write("34"))
        t:check(w:close(), "exactly what was declared closes")
        t:check(Archive.verify(TEMP, 4, fs), "and verifies")
        t:eq(select(2, Archive.verify(TEMP, 5, fs)), "archive_invalid", "against its own length only")
        local calls = table.concat(state.calls, ",")
        t:check(calls:find("close,free", 1, true) ~= nil, "close, then free: " .. calls)
    end)

    t:case("the adapter's refusals before any C call", function()
        t:eq(select(2, Archive.open("", { size = 1 })), "bad_path", "no path")
        t:eq(select(2, Archive.open(TEMP, { size = -1 })), "bad_size", "no size")
        t:eq(select(2, Archive.open(TEMP, { size = 0.5 })), "bad_size", "a fraction")
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        local w = assert(Archive.open(TEMP, { size = 70000, backend = newBackend(fs) }))
        t:eq(select(2, w:write(string.rep("x", Archive.MAX_BLOCK + 1))), "bad_block",
            "a block past the bound")
        w:abort()
    end)

    t:case("verification: magic, length and trailer", function()
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        fs.files["/a"] = "PK\3\4" .. string.rep("x", 30)
        t:eq(select(2, Archive.verify("/a", 1, fs)), "archive_invalid", "not gzip")
        fs.files["/b"] = GZ_HEAD .. "abc"
        t:eq(select(2, Archive.verify("/b", 3, fs)), "archive_invalid", "no trailer")
        fs.files["/c"] = GZ_HEAD .. "abc" .. le32(0) .. le32(3)
        t:check(Archive.verify("/c", 3, fs), "a finished stream")
        t:eq(select(2, Archive.verify("/missing", 3, fs)), "archive_invalid", "absent")
    end)

    t:case("conformance: a library missing a symbol is unavailable", function()
        local fs = support.newExportFs{}
        local backend = newBackend(fs)
        t:check(Archive.available(backend), "the fake has them all")
        backend.lib.archive_write_free = nil
        local ok, err, name = Archive.available(backend)
        t:eq(ok, nil, "one gone")
        t:eq(err, "archive_unavailable", "is unavailable")
        t:eq(name, "archive_write_free", "and named")
    end)

    -- =================================================================
    t:describe("export / xopp job / repository queries")

    t:case("stroke batches are keyset pages in paint order", function()
        local Repository = require("ink_notebook_repository")
        local driver = support.newSqlDriver{ on_open = function(conn)
            conn:answer("PRAGMA user_version", { { Repository.SCHEMA_VERSION } })
            conn:answer("ORDER BY COALESCE%(paint_seq, seq%), seq LIMIT", {
                { 5, 2, 16, 1, 1, 3, 0, 0, 1, 1, 7 },
            })
            conn:answer("SELECT COUNT%(%*%), MAX%(seq%), MAX%(id%)", { { 4, 9, 55 } })
        end }
        local repo = assert(Repository.open{ path = "/tmp/x.sqlite3", driver = driver })
        local rows = assert(repo:listStrokesBatch(3, { limit = 10 }))
        t:eq(rows[1].paint_seq, 7, "paint_seq mapped")
        local conn = driver.last()
        local binds = conn:bindsFor("ORDER BY COALESCE")
        t:eq(binds[1], 3, "page bound")
        t:eq(binds[2], 10, "limit bound")
        t:eq(binds[3], nil, "no cursor on the first page")
        assert(repo:listStrokesBatch(3, { limit = 10, after_paint_seq = 7, after_seq = 2 }))
        local sql
        for i = #conn.log, 1, -1 do
            if conn.log[i].op == "step" and conn.log[i].sql:find("COALESCE%(paint_seq, seq%) > %?3") then
                sql = conn.log[i]
                break
            end
        end
        t:check(sql ~= nil, "the cursor is strictly after (paint_seq, seq)")
        t:eq(sql and sql.values[3], 7, "paint_seq bound")
        t:eq(sql and sql.values[4], 2, "seq bound")
        t:eq(select(2, repo:listStrokesBatch(3, { after_paint_seq = 1 })), "bad_cursor",
            "half a cursor is refused")
        t:eq(select(2, repo:listStrokesBatch(0, {})), "bad_id", "a bad page")
        local rev = assert(repo:strokeRevision(3))
        t:eq(rev.count, 4, "count"); t:eq(rev.max_seq, 9, "max seq"); t:eq(rev.max_id, 55, "max id")
        local statement = conn:statement("SELECT COUNT%(%*%), MAX%(seq%)")
        t:check(statement:find("deleted_at IS NULL", 1, true) ~= nil,
            "live strokes only, so a purge is not an edit")
    end)

    -- =================================================================
    t:describe("export / xopp job / dialog and notebook windows")

    t:case("Xournal++ is offered to notebooks only", function()
        local function labels(formats)
            local dialog = Dialog.show{
                title = "Export", stem = "N", formats = formats,
                settings = support.newSettings and support.newSettings() or nil,
                build = function() return { items = {} } end,
                show_modal = function(w) return w end,
                close_modal = function() end, notify = function() end,
            }
            local out, rows = {}, dialog.added_widgets[1].radio_buttons
            for _, row in ipairs(rows) do
                for _, b in ipairs(row) do out[#out + 1] = b.text end
            end
            return table.concat(out, ","), #rows
        end
        local reader = labels(nil)
        t:eq(reader, "File type,PDF,PNG,JPEG", "not for a book")
        local nb, rows = labels(Dialog.NOTEBOOK_FORMATS)
        t:eq(nb, "File type,PDF,PNG,JPEG,Xournal++ (.xopp)", "for a notebook")
        t:eq(rows, 3, "on a row of its own")
    end)

    t:case("a remembered xopp is kept for notebooks and ignored elsewhere", function()
        local store = {}
        local s = { readSetting = function(_, k) return store[k] end,
            saveSetting = function(_, k, v) store[k] = v end }
        s:saveSetting("justdraw_" .. Dialog.SETTING_FORMAT, "xopp")
        s:saveSetting(Dialog.SETTING_FORMAT, "xopp")
        t:eq(Dialog.rememberedFormat(s, Dialog.NOTEBOOK_FORMATS), "xopp", "notebook")
        t:eq(Dialog.rememberedFormat(s), Dialog.DEFAULT_FORMAT, "book")
    end)

    t:case("every reason this export can end with is a sentence", function()
        local generic = Dialog.reason("no such code")
        for code in pairs(XoppJob.messages()) do
            t:check(Dialog.reason(code) ~= generic, code .. " has its own sentence")
        end
        for _, code in ipairs({ "notebook_changed", "spool_failed", "spool_too_large",
            "archive_unavailable", "archive_failed", "archive_invalid",
            "destination_taken", "list_failed", "bad_surface", "internal_error",
            "rename_failed", "write_failed", "not_writable", "empty",
            "too_many_pages", "no_repository", "bad_name", "file_exists" }) do
            if code ~= "file_exists" then
                t:check(Dialog.reason(code) ~= generic, code .. " is explained")
            end
        end
    end)

    t:case("the limits are shown before anything is read, and Cancel reads nothing", function()
        local notice = Dialog.xoppNotice()
        t:eq(count(notice, "• "), #Xopp.limitations, "one line per limitation")
        t:check(notice:find("highlighter", 1, true) ~= nil, "the highlighter among them")
        t:check(not notice:find("PDF export remains", 1, true), "first sentences only")

        if Export.isRunning() then Export.cancelRunning() end
        local repo = newRepo(notebook(1, 2, 5))
        local fs = support.newExportFs{ dirs = { [DIR] = true, [SPOOL] = true } }
        local backend, arch = newBackend(fs)
        local sched = support.newScheduler()
        local modals, said, finished = {}, nil, 0
        local function start()
            modals = {}
            return Dialog.run{
                build = function(_, format)
                    t:eq(format, "xopp", "the build is told the format")
                    local built = XoppJob.build{ repository = repo, items = repo:pages(),
                        title = "Notebook", notebook_id = 1 }
                    built.produce = XoppJob.producer{ repository = repo, notebook_id = 1,
                        spool_dir = SPOOL, backend = backend }
                    built.finish = function() finished = finished + 1 end
                    return built
                end,
                notify = function(text) said = text end,
                show_modal = function(w) modals[#modals + 1] = w; return w end,
                close_modal = function() end,
                schedule = function(fn) sched:schedule(fn) end,
                format = "xopp", dir = DIR, stem = "Notebook", fs = fs,
                sanitize = function(n) return n end, token = "TOKEN",
                disk = function() return { available = 500 * 1024 * 1024 } end,
            }
        end
        local _, err = start()
        t:eq(err, "confirm_warning", "a question first")
        t:eq(modals[1].text, notice, "the limits")
        modals[1].cancel_callback()
        t:eq(repo:totalReads(), 0, "declining read nothing")
        t:eq(finished, 1, "and released the source")

        start()
        modals[1].ok_callback()
        t:eq(#modals, 2, "one page still gets the progress modal, for Cancel")
        sched:drain()
        t:check(fs.files[TARGET] ~= nil, "saying yes exports")
        t:check(said and said:find(TARGET, 1, true) ~= nil, "and says where: " .. tostring(said))
        t:eq(arch.live, 0, "archive freed")
    end)

    --- A host with just enough of an editor or library for `showExport`.
    local function captureShow(fn)
        local captured
        local real = Dialog.show
        Dialog.show = function(opts) captured = opts; return {} end
        local ok, err = pcall(fn)
        Dialog.show = real
        assert(ok, err)
        return captured
    end

    t:case("both notebook windows build a producer for Xournal++ and a renderer otherwise", function()
        local repo = newRepo(notebook(2, 1, 3))
        repo.listPages = repo.listPages
        local controller = {
            exportRepository = function() return repo end,
            onFlushSettings = function() return true end,
            activeSession = function() return nil end,
        }
        local Editor = require("ink_notebook_editor")
        local Library = require("ink_notebook_library")
        local host = { controller = controller, notebook = { id = 1, title = "Notes" },
            showModalSafely = function(_, w) return w end, _showModal = function(_, w) return w end,
            _closeModal = function() end, _showInfo = function() end }
        for name, show in pairs({
            editor = function() return Editor.showExport(host) end,
            library = function() return Library.showExport(host, { id = 1, title = "Notes" }) end,
        }) do
            local opts = captureShow(show)
            t:eq(opts.formats, Dialog.NOTEBOOK_FORMATS, name .. ": offers Xournal++")
            local built = opts.build("notebook", "xopp")
            t:check(type(built.produce) == "function", name .. ": a producer")
            t:eq(built.render, nil, name .. ": and no renderer")
            t:eq(#built.items, 2, name .. ": every page")
            t:check(built.show_progress, name .. ": with Cancel even for one page")
            local pdf = opts.build("notebook", "pdf")
            t:check(type(pdf.render) == "function", name .. ": PDF still renders")
            t:eq(pdf.produce, nil, name .. ": without a producer")
        end
    end)
end
