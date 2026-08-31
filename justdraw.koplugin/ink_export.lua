--[[--
One export, from a validated destination to files on disk.

Everything that can produce bytes or touch the world is injected -- the
filesystem, the image encoder, the compressor, the clock, the scheduler, the
name saniser -- so the whole of this file is testable without a disk, and so
the parts that *are* KOReader stay in one place each.

The shape is a single-run state machine, `preflight -> flush -> render ->
encode -> commit -> done`, driven by callbacks rather than a coroutine. That
is not a stylistic preference. `InkCanvasCache` finishes by calling back from
a scheduled batch, and `Trapper` resumes its own coroutine from its own
scheduled work; wiring the two together would leave two owners of the same
continuation and no defined order between them. A job here advances only when
something tells it to, always through `schedule`, and every entry point checks
that it is still the phase and generation it was queued for. A late or
duplicated callback -- a raster that settles after the reader cancelled -- can
therefore do nothing but release its own buffer.

The file rules follow from one observation: a half-written export must never
be mistaken for a finished one. So nothing is ever written directly to its
destination. A page goes to a private temporary in the *same* directory (a
rename across filesystems is not atomic, and `/tmp` is a different filesystem
on these devices), and only a completed page is renamed into place.

PDF and image batches differ in what "completed" means, and the difference is
deliberate: a PDF is one file, so it commits once at the end and a cancellation
leaves nothing behind; a PNG or JPEG batch is many files, so it commits each
page as it finishes and a cancellation keeps -- and reports -- the pages that
were already whole. Pretending the second case were transactional would mean
throwing away work the reader can see is done.

The temporaries carry a private prefix so a power cut leaves something
identifiable rather than a plausible-looking export. Nothing here deletes a
file it did not create.
]]

local logger = require("logger")

local Pdf = require("ink_export_pdf")

local Export = {}

--[[--
The one export allowed to be running.

Two at once is exactly the peak the per-page budget exists to avoid -- two
8 Mpx rasters and their string copies -- and a reader shown two progress
modals has no way to know which one Cancel belongs to. Worse, two jobs racing
on the same destination would each pass their own collision check, because
both run before either renames.
]]
local running_job = nil

Export.EXTENSIONS = { pdf = ".pdf", png = ".png", jpg = ".jpg" }
Export.DEFAULT_JPEG_QUALITY = 90
--- Private, and leading-dot so a stray one is out of the reader's way. The
--- prefix is what makes an interrupted export identifiable afterwards.
Export.TEMP_PREFIX = ".justdraw-export-"
--- A name long enough to be recognisable and short enough for VFAT once the
--- suffix and extension are added.
Export.MAX_STEM = 120

--[[--
What an exported page tends to weigh, per megapixel of raster.

Measured rather than assumed. An A5 page at 300 dpi (1748x2480 = 4.34 Mpx)
covered in dense handwriting -- 21.7% of pixels carrying ink -- came to
22,281 B/Mpx through zlib at level 9 and 25,983 B/Mpx through PNG's per-line
encoding; the same page with sparse notes (6.1%) came to 6,306 and 7,939; blank,
to 977 and 1,630. The figure below sits above the dense case, which is the one
that can fill a card, and well above the ordinary case, which is the one that
must not pester anybody.

JPEG is on its own line because it is the only one of the three that does not
get cheaper as the page gets emptier: at quality 90 the noise around an
antialiased stroke costs more than it does in a lossless format.

This is an estimate and it is presented as one. It replaces no check: every
write, close and rename is still verified, because space can run out after the
question has been asked and `df` on an odd mount can say anything.
]]
Export.BYTES_PER_MPX = { pdf = 32768, png = 32768, jpg = 65536 }

--- Below this the reader is asked whatever the estimate says. A folder about
--- to fill up is a bad folder to write into, even when this export would fit.
Export.LOW_WATER = 8 * 1024 * 1024

--- Header, xref, trailer, PNG chunks: not content-dependent, but not zero.
Export.BYTES_PER_FILE = 4096

local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

-- ----------------------------------------------------------------- defaults

local function defaultFs()
    local lfs = require("libs/libkoreader-lfs")
    return {
        attributes = function(path, what) return lfs.attributes(path, what) end,
        rename = os.rename,
        remove = os.remove,
        open = io.open,
        dir = function(path) return lfs.dir(path) end,
    }
end

local function defaultSanitize(name, dir)
    local util = require("util")
    return util.getSafeFilename(name, dir, Export.MAX_STEM, 10)
end

--- `writeToFile` hands back the results of a `pcall`, so a failure is
--- `false, message` rather than a raise.
local function defaultWriteImage(bb, path, format, quality)
    local ok, err = bb:writeToFile(path, format, quality)
    if not ok then return nil, err or "encode_failed" end
    return true
end

--[[--
A BlitBuffer as `w * h` bytes of 8-bit grey.

`Blitbuffer.tostring` returns `stride * h`, which is only the same thing when
the buffer is compact. A fresh BB8 built with an explicit stride of `w` is
compact and unrotated by construction, and blitting into it converts whatever
the source was -- a colour screen included -- in one step. This mirrors what
`writePNG` does for the same reason.
]]
local function defaultGrayBytes(bb)
    local Blitbuffer = require("ffi/blitbuffer")
    local w, h = bb:getWidth(), bb:getHeight()
    if not finite(w) or not finite(h) or w < 1 or h < 1 then
        return nil, "bad_raster"
    end
    local dump = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8, nil, w, w)
    dump:blitFrom(bb)
    local bytes = Blitbuffer.tostring(dump)
    dump:free()
    if type(bytes) ~= "string" or #bytes ~= w * h then
        return nil, "bad_raster"
    end
    return bytes, w, h
end

Export.grayBytes = defaultGrayBytes
--- Exposed so a spec can state what reaches KOReader's encoder -- the format
--- string and the quality -- without going through a whole job.
Export.writeImage = defaultWriteImage

-- ------------------------------------------------------------ space policy

--- Roughly what this export will take on disk, in bytes. See
--- `Export.BYTES_PER_MPX` for where the numbers come from.
function Export.forecast(opts)
    opts = opts or {}
    local per = Export.BYTES_PER_MPX[opts.format]
    if not per then return nil, "bad_format" end
    local pixels = tonumber(opts.pixels)
    if not finite(pixels) or pixels < 0 then return nil, "no_estimate" end
    local files = tonumber(opts.files)
    if not finite(files) or files < 1 then files = 1 end
    return floor(pixels / 1000000 * per) + floor(files) * Export.BYTES_PER_FILE
end

--[[--
Free bytes in a folder, or nil for "not known".

`util.diskUsage` shells out to `df`, so this BLOCKS. It may only be called from
a path where no contact is live -- in practice from the dialog, whose
`show_modal` already refuses while the pen is down -- and never from the stylus
callback (ADR-26).

Not knowing never stops an export. A probe that fails, a mount that answers
nothing, a `df` that is not there: all of them mean the question is not asked,
not that the answer is no.
]]
function Export.availableSpace(dir, probe)
    probe = probe or function(d) return require("util").diskUsage(d) end
    local ok, usage = pcall(probe, dir)
    if not ok or type(usage) ~= "table" then return nil end
    local available = tonumber(usage.available)
    if not finite(available) or available < 0 then return nil end
    return available
end

-- -------------------------------------------------------------- name policy

local function trimmed(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- A directory without its trailing slash, so `dir .. "/" .. name` is never
--- `dir//name` -- which is a different string for a collision check that
--- compares paths.
local function normalizeDir(dir)
    dir = tostring(dir or "")
    if dir == "" then return nil end
    if dir ~= "/" then dir = dir:gsub("/+$", "") end
    if dir == "" then dir = "/" end
    return dir
end

--[[--
Whether a name may be joined to a directory as a direct child.

A saniser that maps the separator to an underscore already prevents traversal,
but this is the assertion rather than the assumption: the export refuses to
write anywhere but the folder the reader chose, whatever the saniser did.
]]
local function isDirectChild(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("/", 1, true) and not name:find("\0", 1, true)
end

--- `-01`, `-02`, ... wide enough for the total, and absent entirely when a
--- single file needs no disambiguation.
local function suffixFor(index, total)
    if total < 2 then return "" end
    local width = #tostring(total)
    if width < 2 then width = 2 end
    return "-" .. string.format("%0" .. width .. "d", index)
end

--[[--
Resolve every path this export would touch, before it touches any.

Returns `{ dir, format, extension, stem, targets, temporaries, existing }`.
Collisions are reported for the whole set rather than discovered halfway
through, because a reader asked to confirm an overwrite is entitled to know
what all of it is.
]]
function Export.plan(opts)
    opts = opts or {}
    local format = tostring(opts.format or "")
    local extension = Export.EXTENSIONS[format]
    if not extension then return nil, "bad_format" end

    local total = opts.total or (opts.items and #opts.items) or 0
    if type(total) ~= "number" or total < 1 or total ~= floor(total) then
        return nil, "no_items"
    end

    local dir = normalizeDir(opts.dir)
    if not dir then return nil, "bad_directory" end

    local fs = opts.fs or defaultFs()
    local sanitize = opts.sanitize or defaultSanitize

    local stem = trimmed(opts.stem)
    if stem == "" then return nil, "bad_name" end
    local ok, safe = pcall(sanitize, stem, dir)
    if ok and type(safe) == "string" then stem = trimmed(safe) end
    if stem == "" or not isDirectChild(stem) then return nil, "bad_name" end
    if #stem > Export.MAX_STEM then stem = stem:sub(1, Export.MAX_STEM) end

    local files = (format == "pdf") and 1 or total
    local token = opts.token or tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))

    local targets, temporaries, existing = {}, {}, {}
    for i = 1, files do
        local name = stem .. suffixFor(i, files) .. extension
        if not isDirectChild(name) then return nil, "bad_name" end
        local temp_name = Export.TEMP_PREFIX .. token .. "-" .. i .. extension
        if not isDirectChild(temp_name) then return nil, "bad_name" end
        targets[i] = dir .. "/" .. name
        temporaries[i] = dir .. "/" .. temp_name
        if fs.attributes(targets[i], "mode") ~= nil then
            existing[#existing + 1] = targets[i]
        end
    end

    return {
        dir = dir,
        format = format,
        extension = extension,
        stem = stem,
        token = token,
        files = files,
        total = total,
        targets = targets,
        temporaries = temporaries,
        existing = existing,
    }
end

-- --------------------------------------------------------------- the sweep

--- A folder with thousands of files may not cost a visible wait in a dialog.
--- The cap bounds the walk; what is inside it is what gets offered.
Export.SWEEP_MAX_ENTRIES = 2000
--- A temporary that was written moments ago may belong to a job still running
--- somewhere else. An age is cheaper than any lock and enough: nothing this
--- plugin writes is still a temporary five minutes later.
Export.SWEEP_MIN_AGE = 300

--[[--
The temporaries an earlier export left in this folder.

It never deletes. It answers what is there so that somebody can ask about it,
because the rule of this module is that nothing carries off a file it did not
create, and a sweep that decided on its own would look far too much like that.

`lfs.dir` *raises* for a directory that is not there -- it does not answer nil
-- which is why the pcall wraps the whole walk and not just the opening.
]]
function Export.orphans(dir, opts)
    opts = opts or {}
    if running_job and not running_job.finished then return nil, "export_busy" end
    local fs = opts.fs or defaultFs()
    if type(fs.dir) ~= "function" then return nil, "no_directory_reader" end
    dir = normalizeDir(dir)
    if not dir or fs.attributes(dir, "mode") ~= "directory" then
        return nil, "bad_directory"
    end

    local now = tonumber(opts.now) or os.time()
    local min_age = tonumber(opts.min_age) or Export.SWEEP_MIN_AGE
    local cap = tonumber(opts.max_entries) or Export.SWEEP_MAX_ENTRIES

    local ok, found = pcall(function()
        local out, seen = {}, 0
        for name in fs.dir(dir) do
            seen = seen + 1
            -- Breaking early leaves the directory handle to the collector,
            -- which is what `lfs` is built for; the cap is about the walk.
            if seen > cap then break end
            if name ~= "." and name ~= ".."
                and name:sub(1, #Export.TEMP_PREFIX) == Export.TEMP_PREFIX then
                local path = dir .. "/" .. name
                if fs.attributes(path, "mode") == "file" then
                    local mtime = tonumber(fs.attributes(path, "modification"))
                    if mtime and (now - mtime) >= min_age then
                        out[#out + 1] = { path = path,
                            size = tonumber(fs.attributes(path, "size")) or 0 }
                    end
                end
            end
        end
        table.sort(out, function(a, b) return a.path < b.path end)
        return out
    end)
    if not ok then
        logger.warn("JustDraw export: could not sweep", dir, "--", tostring(found))
        return nil, "list_failed"
    end
    return found
end

--[[--
Delete what `orphans` found, and be honest about what could not go.

The prefix is checked again on every path. The list may have been built a
while ago, and this is the only function here that removes anything: the check
belongs where the removal is, not where the list came from.
]]
function Export.removeOrphans(entries, opts)
    opts = opts or {}
    if running_job and not running_job.finished then return nil, "export_busy" end
    local fs = opts.fs or defaultFs()
    local removed, freed, failed = 0, 0, 0
    for i = 1, #(entries or {}) do
        local entry = entries[i]
        local path = type(entry) == "table" and entry.path or entry
        local name = type(path) == "string" and path:match("([^/]+)$") or nil
        if name and name:sub(1, #Export.TEMP_PREFIX) == Export.TEMP_PREFIX then
            if fs.remove(path) then
                removed = removed + 1
                freed = freed + (type(entry) == "table" and entry.size or 0)
            else
                failed = failed + 1
            end
        else
            failed = failed + 1
        end
    end
    return removed, freed, failed
end

-- ------------------------------------------------------------------ the job

local Job = {}
Job.__index = Job

--[[--
  opts.format, opts.dir, opts.stem, opts.title
  opts.items      ordered descriptors, already enumerated
  opts.render     function(item, index, done) ; done(result, err) later.
                  result = { bb, width_pt, height_pt, release }
  opts.flush      function() -> ok, err   run before the first read
  opts.overwrite  proceed over existing targets
  opts.quality    JPEG quality, 1..100
  opts.schedule   function(fn) -- must defer
  opts.on_progress function(done, total)
  opts.on_done    function(result)
]]
function Export.start(opts)
    opts = opts or {}
    if type(opts.render) ~= "function" then return nil, "no_renderer" end
    if type(opts.schedule) ~= "function" then return nil, "no_scheduler" end
    if type(opts.items) ~= "table" or #opts.items < 1 then return nil, "no_items" end

    local quality = opts.quality or Export.DEFAULT_JPEG_QUALITY
    if not finite(quality) or quality < 1 or quality > 100 then
        return nil, "bad_quality"
    end

    local plan, plan_err = Export.plan{
        format = opts.format, dir = opts.dir, stem = opts.stem,
        items = opts.items, fs = opts.fs, sanitize = opts.sanitize,
        token = opts.token,
    }
    if not plan then return nil, plan_err end
    if #plan.existing > 0 and not opts.overwrite then
        return nil, "file_exists", plan.existing
    end

    if running_job and not running_job.finished then
        return nil, "export_busy"
    end

    local job = setmetatable({
        plan = plan,
        items = opts.items,
        render_fn = opts.render,
        flush_fn = opts.flush,
        schedule = opts.schedule,
        fs = opts.fs or defaultFs(),
        write_image = opts.write_image or defaultWriteImage,
        gray_bytes = opts.gray_bytes or defaultGrayBytes,
        compress = opts.compress,
        now = opts.now,
        title = opts.title,
        quality = quality,
        on_progress = opts.on_progress,
        on_done = opts.on_done,
        on_cancel = opts.on_cancel,

        phase = "preflight",
        index = 0,
        generation = 0,
        written = {},
        active_temp = nil,
        pdf = nil,
        handle = nil,
        cancelled = false,
        finished = false,
        result = nil,
    }, Job)

    local ok, err = job:_preflight()
    if not ok then
        -- Nothing has been read or written yet, so this is not a finished job
        -- with a failure -- it is a job that never started. Callers get one
        -- shape for "could not start" and one for "started and then ended",
        -- and `on_done` belongs only to the second.
        job:_abandon()
        return nil, err
    end
    running_job = job
    job.phase = "render"
    job.schedule(function() job:_safely("_step") end)
    return job
end

--[[--
Prove the destination before anything is read or rendered.

The write probe is the part that cannot be replaced by asking `lfs` whether
the directory looks writable: a read-only mount, a full filesystem and a
permission bit all present differently, and the only portable question is
whether a file can actually be created here right now. It is still only
"right now" -- space can run out later, which is why every write is checked
too.
]]
function Job:_preflight()
    local fs, plan = self.fs, self.plan
    if fs.attributes(plan.dir, "mode") ~= "directory" then
        return nil, "bad_directory"
    end

    local probe_path = plan.dir .. "/" .. Export.TEMP_PREFIX
        .. plan.token .. "-probe"
    local handle, open_err = fs.open(probe_path, "wb")
    if not handle then
        logger.warn("JustDraw export: destination not writable:", open_err)
        return nil, "not_writable"
    end
    local wrote = handle:write("\0")
    handle:close()
    fs.remove(probe_path)
    if not wrote then return nil, "not_writable" end

    if self.flush_fn then
        self.phase = "flush"
        local flushed, flush_err = self.flush_fn()
        if not flushed then return nil, flush_err or "flush_failed" end
    end

    if plan.format == "pdf" then
        local pdf_handle, pdf_err = fs.open(plan.temporaries[1], "wb")
        if not pdf_handle then
            logger.warn("JustDraw export: cannot open temporary:", pdf_err)
            return nil, "not_writable"
        end
        self.handle = pdf_handle
        self.active_temp = plan.temporaries[1]
        local writer, writer_err = Pdf.new{
            write = function(s) return pdf_handle:write(s) end,
            tell = function() return pdf_handle:seek() end,
            compress = self.compress,
            title = self.title or plan.stem,
            now = self.now,
        }
        if not writer then return nil, writer_err or "pdf_failed" end
        self.pdf = writer
    end
    return true
end

--[[--
Run one transition, turning a raise into this job's own failure.

Only the synchronous call into the renderer was guarded before, while the path
every real surface takes -- a raster answering from a later tick -- was not. A
raise there escaped into `UIManager`'s tick with the PDF handle open, the
temporary on disk and the progress modal still up, and `on_done` never ran.
This is the ordinary failure rather than an exotic one: `Blitbuffer.new`
asserts when an 8 Mpx page cannot be allocated, and `zlib_compress` asserts by
contract.
]]
function Job:_safely(name, ...)
    local ok, err = pcall(self[name], self, ...)
    if ok then return err end
    logger.err("JustDraw export: unhandled error in", name, "--", tostring(err))
    self:_finish("failed", "internal_error")
    return nil
end

--- Ask for the next page. Every continuation from here is generation-checked,
--- so a cancellation between the request and its answer is decisive.
function Job:_step()
    if self.finished then return end
    if self.cancelled then return self:_finish("cancelled") end

    self.index = self.index + 1
    if self.index > #self.items then return self:_commit() end

    self.generation = self.generation + 1
    local generation = self.generation
    local index = self.index
    local ok, err = pcall(self.render_fn, self.items[index], index,
        function(result, render_err)
            self:_safely("_rendered", generation, index, result, render_err)
        end)
    if not ok then
        logger.err("JustDraw export: renderer raised:", err)
        return self:_finish("failed", "render_failed")
    end
end

--[[--
Take delivery of one rendered page.

The generation check is the whole defence against a raster that settles after
the reader pressed Cancel, or a renderer that answers twice. Either way the
buffer still has to be released, which is why that happens before the guard
returns.
]]
function Job:_rendered(generation, index, result, render_err)
    local stale = self.finished or generation ~= self.generation
        or index ~= self.index
    if stale or self.cancelled then
        if result and type(result.release) == "function" then
            pcall(result.release)
        end
        if not stale and self.cancelled then self:_finish("cancelled") end
        return
    end

    -- Consume the generation the moment the answer is accepted. The step that
    -- advances the index is only *scheduled* here, so until it runs a second
    -- answer for this same page would otherwise still look current -- and
    -- would encode the page twice.
    self.generation = self.generation + 1

    if not result then
        return self:_finish("failed", render_err or "render_failed")
    end

    -- Guarded separately from the transition, so the release below runs
    -- whatever `_encode` did. An unreleased raster is the one leak that costs
    -- a whole page of memory.
    local ran, encoded, encode_err = pcall(self._encode, self, result, index)
    if not ran then
        logger.err("JustDraw export: encode raised --", tostring(encoded))
        encoded, encode_err = nil, "internal_error"
    end
    if type(result.release) == "function" then pcall(result.release) end
    if not encoded then return self:_finish("failed", encode_err) end

    if self.on_progress then
        pcall(self.on_progress, index, #self.items)
    end
    self.schedule(function() self:_safely("_step") end)
end

function Job:_encode(result, index)
    local bb = result.bb
    if type(bb) ~= "table" and type(bb) ~= "userdata" and type(bb) ~= "cdata" then
        return nil, "bad_raster"
    end

    if self.plan.format == "pdf" then
        local bytes, w, h = self.gray_bytes(bb)
        if not bytes then
            return nil, (type(w) == "string" and w) or "bad_raster"
        end
        local ok, err = self.pdf:addImagePage{
            gray = bytes, w = w, h = h,
            width_pt = result.width_pt, height_pt = result.height_pt,
        }
        if not ok then return nil, err or "pdf_failed" end
        return true
    end

    local temp = self.plan.temporaries[index]
    self.active_temp = temp
    local ok, err = self.write_image(bb, temp, self.plan.format, self.quality)
    if not ok then
        self:_removeActiveTemp()
        return nil, err or "encode_failed"
    end
    -- KOReader's `writeToFile` answers true even when the encoder wrote
    -- nothing: lodepng and turbojpeg do not propagate a file error, so the
    -- `pcall` around them returns cleanly and a full disk or a vanished
    -- folder looks like success. tests/conformance.lua states that against
    -- the real one. Existence alone is not enough either: `writePNG`
    -- discards lodepng's error return and `ffi/jpeg` never inspects its
    -- `write`, so a full disk leaves a created-but-empty file. Both are
    -- checked.
    local mode = self.fs.attributes(temp, "mode")
    local size = self.fs.attributes(temp, "size")
    if mode ~= "file" or type(size) ~= "number" or size < 1 then
        self:_removeActiveTemp()
        return nil, "encode_failed"
    end
    local renamed = self.fs.rename(temp, self.plan.targets[index])
    if not renamed then
        self:_removeActiveTemp()
        return nil, "rename_failed"
    end
    self.active_temp = nil
    self.written[#self.written + 1] = self.plan.targets[index]
    return true
end

--- The single commit of a PDF. An image batch has already committed each page.
function Job:_commit()
    self.phase = "commit"
    if self.plan.format ~= "pdf" then return self:_finish("done") end

    local ok, err = self.pdf:finish()
    if not ok then
        self:_closeHandle()
        self:_removeActiveTemp()
        return self:_finish("failed", err or "pdf_failed")
    end
    local closed, close_err = self:_closeHandle()
    if not closed then
        self:_removeActiveTemp()
        return self:_finish("failed", close_err or "write_failed")
    end
    local renamed = self.fs.rename(self.active_temp, self.plan.targets[1])
    if not renamed then
        self:_removeActiveTemp()
        return self:_finish("failed", "rename_failed")
    end
    self.written[#self.written + 1] = self.plan.targets[1]
    self.active_temp = nil
    return self:_finish("done")
end

function Job:_closeHandle()
    local handle = self.handle
    self.handle = nil
    if not handle then return true end
    -- A buffered write can fail only here, which is why the close is checked
    -- rather than assumed and the rename waits for it.
    --
    -- `file:close()` answers `true`, or `nil, message, errno` -- it never
    -- answers `false` (LuaJIT `lib_io.c`, `io_file_close` via
    -- `luaL_fileresult`). Testing for `false` was therefore dead code, and a
    -- disk that filled while the PDF's trailer was still in the buffer would
    -- have been renamed into place and reported as a finished export.
    local ok, err = handle:close()
    if not ok then return nil, err or "write_failed" end
    return true
end

function Job:_removeActiveTemp()
    local temp = self.active_temp
    self.active_temp = nil
    if temp then pcall(self.fs.remove, temp) end
end

--[[--
End the job exactly once, leaving nothing of its own behind.

Idempotent because several paths can reach it: a failure, a cancellation
observed between phases, and a cancellation observed while a render was in
flight. Files already renamed into place are kept -- they are complete, and an
image batch is documented as incremental -- while the temporary this job still
owns is removed.
]]
function Job:_finish(status, reason)
    if self.finished then return self.result end
    self.finished = true
    if running_job == self then running_job = nil end
    self.phase = status
    self:_closeHandle()
    self:_removeActiveTemp()
    self.result = {
        status = status,
        ok = status == "done",
        written = self.written,
        count = #self.written,
        total = #self.items,
        format = self.plan and self.plan.format,
        targets = self.plan and self.plan.targets,
        error = reason,
    }
    if reason then
        logger.warn("JustDraw export:", status, reason)
    end
    if self.on_done then pcall(self.on_done, self.result) end
    return self.result
end

--[[--
Ask the job to stop, and have it stop now.

`on_cancel` is the source's hook, and it is what makes a cancellation land
*between raster batches* rather than after the page being replayed finishes:
`InkCanvasCache` checks its generation between batches, so closing it ends the
replay at the next one. That also means its callback will never arrive, which
is why the job finalises here instead of waiting for an answer that is no
longer coming.

A render that answers anyway finds the job finished and releases its buffer on
the way out.
]]
function Job:cancel()
    if self.finished then return false end
    self.cancelled = true
    if self.on_cancel then pcall(self.on_cancel) end
    self:_finish("cancelled")
    return true
end

--- Tear down a job that failed preflight: no callback, no result, nothing
--- of its own left on disk.
function Job:_abandon()
    self.finished = true
    if running_job == self then running_job = nil end
    self.phase = "failed"
    self:_closeHandle()
    self:_removeActiveTemp()
end

--- Whether an export is running, for a caller deciding whether to offer one.
function Export.isRunning()
    return running_job ~= nil and not running_job.finished
end

--[[--
Stop whatever is running, if anything is.

The lifecycle gates call this. A document closing takes its repository with
it, and a raster still reading through that connection would be reading a
closed one; a suspend has the same shape with a longer fuse.
]]
function Export.cancelRunning()
    if not Export.isRunning() then return false end
    return running_job:cancel()
end

function Job:isFinished()
    return self.finished == true
end

function Job:status()
    return self.phase
end

Export.Job = Job
Export.normalizeDir = normalizeDir
Export.isDirectChild = isDirectChild
Export.suffixFor = suffixFor

return Export
