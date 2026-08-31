--[[--
The export job: what it writes, where, in what order, and what it leaves.

The interesting claims here are all negative. Nothing is read before the flush
that made it durable. Nothing is written outside the folder the reader chose.
No destination file is created until its content is complete. Nothing of the
job's own survives a failure or a cancellation. And a callback that arrives
after the job has moved on -- a raster settling after Cancel, a renderer
answering twice -- changes nothing except that it releases its own buffer.

Each of those is a way an export can appear to have worked while having
produced a truncated file, or can leave a reader's folder full of debris. The
filesystem fake models the awkward parts of the real calls (a `close` that is
where a buffered write finally fails, a `rename` that answers `nil, message`)
so the handling is exercised rather than assumed.

The PDF path runs through the real writer and the real greyscale conversion,
so these cases also state that the two fit together: what comes out of the
fake filesystem at the end is a file the PDF spec's parser would accept.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Export = require("ink_export")

    local DIR = "/mnt/us/exports"
    local PREFIX = Export.TEMP_PREFIX

    --- A job wired to fakes, with every dependency observable.
    local function fixture(opts)
        opts = opts or {}
        -- One export at a time is a production guarantee, so a spec that
        -- starts several has to end the previous one -- exactly as the UI
        -- does when the reader closes a document or cancels.
        if Export.isRunning() then Export.cancelRunning() end
        local fs = support.newExportFs{
            dirs = opts.dirs or { [DIR] = true },
            files = opts.files,
            fail_open = opts.fail_open,
            fail_write = opts.fail_write,
            fail_close = opts.fail_close,
            fail_rename = opts.fail_rename,
        }
        local sched = support.newScheduler()
        local log = { order = {}, render = 0, released = 0, encoded = {},
            progress = {}, done = 0, result = nil }
        local pending_done = {}
        local cancelled = 0

        local items = opts.items or { { page = 1 }, { page = 2 }, { page = 3 } }

        local function render(item, index, done)
            log.render = log.render + 1
            log.order[#log.order + 1] = "render:" .. index
            local bb = support.newBlitbuffer(4, 2)
            local result = {
                bb = bb, width_pt = 100, height_pt = 200,
                release = function()
                    log.released = log.released + 1
                    bb:free()
                end,
            }
            pending_done[index] = function(override)
                if opts.render_fail == index then
                    return done(nil, "render boom")
                end
                done(override or result)
            end
            if opts.manual_render then return end
            sched:schedule(function()
                if pending_done[index] then pending_done[index]() end
            end)
        end

        local job, err, extra = Export.start{
            render = render,
            format = opts.format or "png",
            dir = opts.dir or DIR,
            stem = opts.stem or "Notebook",
            title = opts.title,
            items = items,
            overwrite = opts.overwrite,
            quality = opts.quality,
            token = "TOKEN",
            fs = fs,
            schedule = function(fn) sched:schedule(fn) end,
            sanitize = opts.sanitize or function(name) return name end,
            compress = opts.compress,
            now = function()
                return { year = 2026, month = 8, day = 30, hour = 12, min = 0,
                    sec = 0, offset_minutes = 0 }
            end,
            gray_bytes = opts.gray_bytes,
            write_image = opts.write_image or function(bb, path, format, quality)
                log.encoded[#log.encoded + 1] =
                    { path = path, format = format, quality = quality }
                if opts.encode_fail == #log.encoded then
                    return nil, "encoder boom"
                end
                fs.files[path] = "IMAGE:" .. format
                return true
            end,
            flush = opts.no_flush and nil or function()
                log.order[#log.order + 1] = "flush"
                if opts.flush_fail then return nil, "ink not saved" end
                return true
            end,
            on_progress = function(done_count, total)
                log.progress[#log.progress + 1] = done_count .. "/" .. total
            end,
            on_cancel = function() cancelled = cancelled + 1 end,
            on_done = function(result)
                log.done = log.done + 1
                log.result = result
                log.order[#log.order + 1] = "done:" .. result.status
            end,
        }
        return { job = job, err = err, extra = extra, fs = fs, sched = sched,
            log = log, resume = pending_done, items = items,
            cancelled = function() return cancelled end }
    end

    -- =================================================================
    t:describe("export / job / naming and collisions")

    t:case("one file needs no number; several are numbered to their total", function()
        local single = Export.plan{ format = "png", dir = DIR, stem = "Sheet",
            total = 1, fs = support.newExportFs{}, sanitize = function(n) return n end }
        t:eq(single.targets[1], DIR .. "/Sheet.png", "a lone file is plain")

        local many = Export.plan{ format = "png", dir = DIR, stem = "Sheet",
            total = 3, fs = support.newExportFs{}, sanitize = function(n) return n end }
        t:eq(many.targets[1], DIR .. "/Sheet-01.png", "first")
        t:eq(many.targets[3], DIR .. "/Sheet-03.png", "last")

        local hundreds = Export.plan{ format = "png", dir = DIR, stem = "Sheet",
            total = 120, fs = support.newExportFs{}, sanitize = function(n) return n end }
        t:eq(hundreds.targets[1], DIR .. "/Sheet-001.png", "width follows the total")
    end)

    t:case("a PDF is one file however many pages it holds", function()
        local plan = Export.plan{ format = "pdf", dir = DIR, stem = "Notebook",
            total = 40, fs = support.newExportFs{}, sanitize = function(n) return n end }
        t:eq(plan.files, 1, "one file")
        t:eq(plan.total, 40, "forty pages")
        t:eq(plan.targets[1], DIR .. "/Notebook.pdf", "and no numbering")
    end)

    t:case("only the three known formats are planned at all", function()
        local function plan(format)
            return select(2, Export.plan{ format = format, dir = DIR,
                stem = "x", total = 1, fs = support.newExportFs{},
                sanitize = function(n) return n end })
        end
        t:eq(plan("jpeg"), "bad_format", "a near miss is not silently a JPEG")
        t:eq(plan("PNG"), "bad_format", "nor is a different case")
        t:eq(plan(""), "bad_format", "nor is nothing")
        t:eq(plan("tiff"), "bad_format", "nor is an unsupported one")
    end)

    t:case("a name that would escape the folder is refused", function()
        local function plan(stem, sanitize)
            return select(2, Export.plan{ format = "png", dir = DIR, stem = stem,
                total = 1, fs = support.newExportFs{},
                sanitize = sanitize or function(n) return n end })
        end
        t:eq(plan("../../etc/passwd"), "bad_name", "traversal")
        t:eq(plan("."), "bad_name", "the folder itself")
        t:eq(plan(".."), "bad_name", "its parent")
        t:eq(plan("   "), "bad_name", "whitespace only")
        t:eq(plan(""), "bad_name", "empty")
        -- Even if a saniser handed back something impossible, the join is
        -- checked rather than trusted.
        t:eq(plan("ok", function() return "../escape" end), "bad_name",
            "a saniser is not taken at its word")
    end)

    t:case("every planned path is a direct child of the chosen folder", function()
        local plan = Export.plan{ format = "png", dir = DIR .. "/", stem = "A/B:C",
            total = 2, fs = support.newExportFs{} }
        t:eq(plan.dir, DIR, "a trailing slash is normalised away")
        for i = 1, #plan.targets do
            t:eq(plan.targets[i]:match("^(.*)/[^/]+$"), DIR,
                "target " .. i .. " sits directly in the folder")
            t:eq(plan.temporaries[i]:match("^(.*)/[^/]+$"), DIR,
                "temporary " .. i .. " does too")
        end
    end)

    t:case("existing destinations are all reported before anything runs", function()
        local f = fixture{ files = {
            [DIR .. "/Notebook-01.png"] = "old",
            [DIR .. "/Notebook-03.png"] = "old",
        } }
        t:check(f.job == nil, "no job was started")
        t:eq(f.err, "file_exists", "the reason")
        t:eq(#f.extra, 2, "both collisions, not just the first")
        t:eq(f.log.render, 0, "nothing was rendered")
        t:eq(#f.fs.opened, 0, "and nothing was opened")
    end)

    t:case("overwrite proceeds and replaces only the planned names", function()
        local f = fixture{ overwrite = true, files = {
            [DIR .. "/Notebook-01.png"] = "old",
            [DIR .. "/keep.png"] = "mine",
        } }
        t:check(f.job ~= nil, "started")
        f.sched:drain()
        t:eq(f.log.result.status, "done", "finished")
        t:eq(f.fs.files[DIR .. "/Notebook-01.png"], "IMAGE:png", "replaced")
        t:eq(f.fs.files[DIR .. "/keep.png"], "mine", "an unrelated file is untouched")
    end)

    -- =================================================================
    t:describe("export / job / preflight")

    t:case("a folder that is not a folder stops the job before the flush", function()
        local f = fixture{ dirs = {} }
        t:check(f.job == nil, "no job")
        t:eq(f.err, "bad_directory", "reason")
        t:eq(#f.log.order, 0, "no flush, no render, no callback")
    end)

    t:case("a folder that cannot be written to is found by trying", function()
        local probe = DIR .. "/" .. PREFIX .. "TOKEN-probe"
        local f = fixture{ fail_open = { [probe] = "read-only file system" } }
        t:check(f.job == nil, "no job")
        t:eq(f.err, "not_writable", "reason")
        t:eq(f.log.render, 0, "nothing was rendered")
    end)

    t:case("the write probe removes itself", function()
        local f = fixture{}
        f.sched:drain()
        t:eq(f.fs.files[DIR .. "/" .. PREFIX .. "TOKEN-probe"], nil,
            "the probe is gone")
        t:eq(#f.fs.temporaries(PREFIX), 0, "and so is everything else private")
    end)

    t:case("the flush happens before the first read, and stops the job if it fails", function()
        local ok_job = fixture{}
        ok_job.sched:drain()
        t:eq(ok_job.log.order[1], "flush", "flush is first")
        t:eq(ok_job.log.order[2], "render:1", "and only then is anything read")

        local failed = fixture{ flush_fail = true }
        t:check(failed.job == nil, "no job when ink is not durable")
        t:eq(failed.err, "ink not saved", "the owner's reason is passed through")
        t:eq(failed.log.render, 0, "nothing was read")
    end)

    t:case("a preflight failure is not a finished job", function()
        local f = fixture{ dirs = {} }
        t:eq(f.log.done, 0, "on_done was never called")
    end)

    t:case("an impossible request is refused at the door", function()
        -- A table cannot carry `key = nil`, so removing a dependency needs a
        -- sentinel; without one these cases would all be testing the default.
        local NONE = {}
        local function start(overrides)
            local base = { format = "png", dir = DIR, stem = "x",
                items = { {} }, render = function() end,
                schedule = function() end, fs = support.newExportFs{ dirs = { [DIR] = true } },
                sanitize = function(n) return n end }
            for k, v in pairs(overrides) do
                base[k] = (v ~= NONE) and v or nil
            end
            return select(2, Export.start(base))
        end
        t:eq(start{ items = {} }, "no_items", "nothing to export")
        t:eq(start{ render = NONE }, "no_renderer", "no renderer")
        t:eq(start{ schedule = NONE }, "no_scheduler", "no scheduler")
        t:eq(start{ quality = 0 }, "bad_quality", "quality below the range")
        t:eq(start{ quality = 101 }, "bad_quality", "quality above it")
        t:eq(start{ quality = 1 / 0 }, "bad_quality", "infinite quality")
    end)

    -- =================================================================
    t:describe("export / job / images are incremental")

    t:case("each page is written to a private temporary and then renamed", function()
        local f = fixture{}
        f.sched:drain()
        t:eq(f.log.result.status, "done", "finished")
        t:eq(#f.log.encoded, 3, "three pages encoded")
        for i = 1, 3 do
            t:check(f.log.encoded[i].path:find(PREFIX, 1, true) ~= nil,
                "page " .. i .. " was encoded into a temporary")
            t:eq(f.fs.renames[i].to, DIR .. "/Notebook-0" .. i .. ".png",
                "and renamed into place")
        end
        t:eq(#f.fs.temporaries(PREFIX), 0, "nothing private is left behind")
    end)

    t:case("the destination never exists until its content is complete", function()
        local f = fixture{ manual_render = true }
        f.sched:drain()
        t:eq(f.fs.files[DIR .. "/Notebook-01.png"], nil,
            "the first page is not there while it is still being rendered")
        f.resume[1]()
        f.sched:drain()
        t:eq(f.fs.files[DIR .. "/Notebook-01.png"], "IMAGE:png", "and then it is")
    end)

    t:case("the format and quality that reach the encoder are the validated ones", function()
        local f = fixture{ format = "jpg", quality = 55 }
        f.sched:drain()
        t:eq(f.log.encoded[1].format, "jpg", "format")
        t:eq(f.log.encoded[1].quality, 55, "quality")
        local defaulted = fixture{ format = "jpg" }
        defaulted.sched:drain()
        t:eq(defaulted.log.encoded[1].quality, Export.DEFAULT_JPEG_QUALITY,
            "and a default when none was chosen")
    end)

    t:case("KOReader's encoder is called the way it actually answers", function()
        local bb = support.newBlitbuffer(3, 2)
        t:check(Export.writeImage(bb, "/tmp/x.png", "png", 90), "success is truthy")
        t:eq(bb.root.written[1].format, "png", "format forwarded")
        t:eq(bb.root.written[1].quality, 90, "quality forwarded")
        t:eq(bb.root.written[1].filename, "/tmp/x.png", "path forwarded")
        bb.root.write_failure = "no space left on device"
        local ok, err = Export.writeImage(bb, "/tmp/y.png", "png", 90)
        t:check(not ok, "a false return is a failure, not a success")
        t:eq(err, "no space left on device", "and the message survives")
    end)

    t:case("progress is reported per finished page", function()
        local f = fixture{}
        f.sched:drain()
        t:eq(#f.log.progress, 3, "three reports")
        t:eq(f.log.progress[1], "1/3", "first")
        t:eq(f.log.progress[3], "3/3", "last")
    end)

    -- =================================================================
    t:describe("export / job / a PDF commits once")

    t:case("a whole notebook becomes one file, written only at the end", function()
        local f = fixture{ format = "pdf", title = "Cuaderno" }
        f.sched:drain()
        t:eq(f.log.result.status, "done", "finished")
        t:eq(#f.log.result.written, 1, "one file")
        t:eq(f.log.result.written[1], DIR .. "/Notebook.pdf", "named for the stem")
        local doc = f.fs.files[DIR .. "/Notebook.pdf"]
        t:check(doc ~= nil, "the file exists")
        t:check(doc:sub(1, 8) == "%PDF-1.4", "and is a PDF")
        t:check(doc:find("/Count 3", 1, true) ~= nil, "with all three pages")
        t:check(doc:find("%%EOF", 1, true) ~= nil, "and an end marker")
        t:eq(#f.fs.temporaries(PREFIX), 0, "no temporary survives")
    end)

    t:case("the greyscale conversion produces exactly one byte per pixel", function()
        local bb = support.newBlitbuffer(7, 5)
        local bytes, w, h = Export.grayBytes(bb)
        t:eq(w, 7, "width")
        t:eq(h, 5, "height")
        t:eq(#bytes, 35, "one byte per pixel, which is what the PDF declares")
    end)

    t:case("a PDF that fails midway leaves no file at the destination", function()
        local temp = DIR .. "/" .. PREFIX .. "TOKEN-1.pdf"
        local f = fixture{ format = "pdf", fail_write = { [temp] = "disk full" } }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "reported as failed")
        t:eq(f.fs.files[DIR .. "/Notebook.pdf"], nil, "no destination file")
        t:eq(#f.fs.temporaries(PREFIX), 0, "and no temporary either")
    end)

    t:case("a close that fails is a failure, because that is where writes land", function()
        local temp = DIR .. "/" .. PREFIX .. "TOKEN-1.pdf"
        local f = fixture{ format = "pdf", fail_close = { [temp] = "disk full" } }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "not reported as a success")
        t:eq(f.fs.files[DIR .. "/Notebook.pdf"], nil, "and nothing was renamed")
    end)

    -- =================================================================
    t:describe("export / job / failures leave nothing")

    t:case("an encoder failure stops the batch and removes its temporary", function()
        local f = fixture{ encode_fail = 2 }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "failed")
        t:eq(f.log.result.error, "encoder boom", "with the encoder's reason")
        t:eq(f.log.result.count, 1, "the page that had finished is kept")
        t:eq(f.fs.files[DIR .. "/Notebook-01.png"], "IMAGE:png", "and is complete")
        t:eq(f.fs.files[DIR .. "/Notebook-02.png"], nil, "the failed one is absent")
        t:eq(#f.fs.temporaries(PREFIX), 0, "no debris")
    end)

    t:case("an encoder that claims success without writing is caught", function()
        -- Not hypothetical: KOReader's `writeToFile` answers true when
        -- lodepng or turbojpeg could not create the file at all, which
        -- tests/conformance.lua states against the real one. Trusting the
        -- return would rename a file that is not there and, worse, report a
        -- successful export of nothing.
        local f = fixture{ write_image = function() return true end }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "failed")
        t:eq(f.log.result.error, "encode_failed", "with the encoder's reason")
        t:eq(f.log.result.count, 0, "and nothing was reported as written")
        t:eq(#f.fs.renames, 0, "no rename was attempted on a missing file")
    end)

    t:case("an encoder that leaves an empty file is caught too", function()
        -- `writePNG` discards lodepng's error return and `ffi/jpeg` never
        -- inspects its `write`, so a disk that fills mid-encode leaves a
        -- created-but-empty file. Existence alone would pass it through.
        local g
        g = fixture{ write_image = function(bb, path)
            g.fs.files[path] = ""     -- created, and empty
            return true
        end }
        g.sched:drain()
        t:eq(g.log.result.status, "failed", "failed")
        t:eq(g.log.result.error, "encode_failed", "reason")
        t:eq(#g.fs.renames, 0, "and nothing was renamed")
    end)

    t:case("a raise inside the asynchronous path fails the job cleanly", function()
        -- The path every real surface takes: a raster answers from a later
        -- tick. `Blitbuffer.new` asserts when an 8 Mpx page cannot be
        -- allocated and `zlib_compress` asserts by contract, so an unguarded
        -- transition here escapes into UIManager's tick with the file handle
        -- open, the temporary on disk and `on_done` never called.
        local f = fixture{ format = "pdf",
            gray_bytes = function() error("cannot allocate memory") end }
        f.sched:drain()
        t:eq(f.log.done, 1, "the finaliser still ran")
        t:eq(f.log.result.status, "failed", "as a failure")
        t:eq(f.log.result.error, "internal_error", "with a reportable reason")
        t:eq(f.fs.files[DIR .. "/Notebook.pdf"], nil, "no destination file")
        t:eq(#f.fs.temporaries(PREFIX), 0, "and no temporary left behind")
    end)

    t:case("only one export runs at a time", function()
        local first = fixture{ manual_render = true }
        t:check(first.job ~= nil, "the first started")
        t:check(Export.isRunning(), "and is running")
        -- A second would double the peak the per-page budget exists to bound,
        -- and two jobs racing on one destination each pass their own
        -- collision check, because both run before either renames.
        local second = Export.start{
            format = "png", dir = DIR, stem = "Other", items = { {} },
            render = function() end, schedule = function() end,
            fs = first.fs, sanitize = function(n) return n end, token = "T2",
        }
        t:check(second == nil, "the second was refused")
        t:eq(select(2, Export.start{
            format = "png", dir = DIR, stem = "Other", items = { {} },
            render = function() end, schedule = function() end,
            fs = first.fs, sanitize = function(n) return n end, token = "T3",
        }), "export_busy", "with a reason the dialog can explain")
        t:check(Export.cancelRunning(), "cancelling the running one releases the slot")
        t:check(not Export.isRunning(), "nothing is running now")
    end)

    t:case("a rename failure is a failure, and its temporary goes", function()
        local temp = DIR .. "/" .. PREFIX .. "TOKEN-1.png"
        local f = fixture{ fail_rename = { [temp] = "cross-device link" } }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "failed")
        t:eq(f.log.result.error, "rename_failed", "reason")
        t:eq(#f.fs.temporaries(PREFIX), 0, "no debris")
    end)

    t:case("a renderer that cannot produce a page ends the job with its reason", function()
        local f = fixture{ render_fail = 2 }
        f.sched:drain()
        t:eq(f.log.result.status, "failed", "failed")
        t:eq(f.log.result.error, "render boom", "reason")
        t:eq(f.log.result.count, 1, "the finished page is kept")
    end)

    t:case("a renderer that raises does not take the job down with it", function()
        local sched = support.newScheduler()
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        local seen
        local job = Export.start{
            format = "png", dir = DIR, stem = "x", items = { {} },
            token = "T", fs = fs, sanitize = function(n) return n end,
            schedule = function(fn) sched:schedule(fn) end,
            render = function() error("renderer exploded") end,
            on_done = function(result) seen = result end,
        }
        t:check(job ~= nil, "started")
        sched:drain()
        t:eq(seen.status, "failed", "failed cleanly")
        t:eq(seen.error, "render_failed", "with a reason the caller can show")
    end)

    t:case("every rendered buffer is released, on every path", function()
        local ok = fixture{}
        ok.sched:drain()
        t:eq(ok.log.released, 3, "one release per page on success")

        local failed = fixture{ encode_fail = 2 }
        failed.sched:drain()
        t:eq(failed.log.released, 2, "including the page that failed to encode")
    end)

    -- =================================================================
    t:describe("export / job / cancellation and late callbacks")

    t:case("cancelling between pages keeps and reports what is already whole", function()
        local f = fixture{ manual_render = true }
        f.sched:drain()
        f.resume[1]()
        f.sched:drain()          -- page one is committed, page two requested
        f.job:cancel()
        f.resume[2]()
        f.sched:drain()
        t:eq(f.log.result.status, "cancelled", "reported as cancelled")
        t:eq(f.log.result.count, 1, "one page survived")
        t:eq(f.fs.files[DIR .. "/Notebook-01.png"], "IMAGE:png", "and it is complete")
        t:eq(f.fs.files[DIR .. "/Notebook-02.png"], nil, "the cancelled one was not written")
        t:eq(#f.fs.temporaries(PREFIX), 0, "nothing private is left")
    end)

    t:case("cancelling ends the job at once, and closes the raster in flight", function()
        local f = fixture{ manual_render = true }
        f.sched:drain()
        t:eq(f.log.render, 1, "one render outstanding")
        f.job:cancel()
        -- Finalising here rather than waiting is what lets the source close
        -- the raster: `InkCanvasCache` checks its generation between batches,
        -- so a closed cache stops replaying at the next one instead of
        -- finishing the page. Its callback then never arrives, which is
        -- exactly why the job must not be waiting for one.
        t:eq(f.log.done, 1, "the job finished immediately")
        t:eq(f.log.result.status, "cancelled", "as cancelled")
        t:eq(f.log.result.count, 0, "with nothing committed")
        t:eq(f.cancelled(), 1, "and the source was told to close its raster")
    end)

    t:case("a raster that answers anyway is ignored, and releases itself", function()
        local f = fixture{ manual_render = true }
        f.sched:drain()
        f.job:cancel()
        f.resume[1]()
        t:eq(f.log.released, 1, "the late buffer was released")
        t:eq(#f.log.encoded, 0, "and nothing was encoded")
        t:eq(f.log.done, 1, "the finaliser still ran only once")
    end)

    t:case("a renderer that answers twice is obeyed once", function()
        local f = fixture{ manual_render = true }
        f.sched:drain()
        f.resume[1]()
        local after_first = #f.log.encoded
        f.resume[1]()            -- the same page, answered again
        t:eq(#f.log.encoded, after_first, "the duplicate encoded nothing")
        t:eq(f.log.released, 2, "but its buffer was still released")
    end)

    t:case("the finaliser runs once however many ways it is reached", function()
        local f = fixture{}
        f.sched:drain()
        t:eq(f.log.done, 1, "one callback")
        t:check(not f.job:cancel(), "cancelling a finished job does nothing")
        t:eq(f.log.done, 1, "still one callback")
        t:check(f.job:isFinished(), "and it stays finished")
    end)

    t:case("a cancelled PDF leaves neither a file nor a temporary", function()
        local f = fixture{ format = "pdf", manual_render = true }
        f.sched:drain()
        f.job:cancel()
        f.resume[1]()
        f.sched:drain()
        t:eq(f.log.result.status, "cancelled", "cancelled")
        t:eq(f.log.result.count, 0, "nothing was committed")
        t:eq(f.fs.files[DIR .. "/Notebook.pdf"], nil, "no destination file")
        t:eq(#f.fs.temporaries(PREFIX), 0, "no temporary")
    end)

    -- =================================================================
    t:describe("export / job / how much room this will take")

    --[[--
    An estimate, and the honesty about it.

    The forecast exists to ask a question, never to answer one: it can only be
    right to within the ink on the page, and everything downstream still checks
    every write. What these cases pin is the part that must not drift -- that
    it counts the pixels the allocation will actually reserve, that JPEG is
    dearer than the lossless pair, and above all that not knowing produces
    silence rather than a guess.
    ]]

    t:case("the forecast scales with pixels and with the format", function()
        local mpx = 1000000
        local pdf = Export.forecast{ format = "pdf", pixels = mpx, files = 1 }
        local png = Export.forecast{ format = "png", pixels = mpx, files = 1 }
        local jpg = Export.forecast{ format = "jpg", pixels = mpx, files = 1 }
        t:eq(pdf, Export.BYTES_PER_MPX.pdf + Export.BYTES_PER_FILE,
            "one megapixel is one unit plus the per-file floor")
        t:eq(png, pdf, "PNG and a Flate PDF weigh the same per megapixel")
        t:check(jpg > pdf, "JPEG costs more for the same line art")
        t:eq(Export.forecast{ format = "pdf", pixels = 4 * mpx, files = 1 },
            4 * Export.BYTES_PER_MPX.pdf + Export.BYTES_PER_FILE,
            "and it is linear in the pixels")
    end)

    t:case("more files cost more, because each one has a floor", function()
        local one = Export.forecast{ format = "png", pixels = 1000000, files = 1 }
        local ten = Export.forecast{ format = "png", pixels = 1000000, files = 10 }
        t:eq(ten - one, 9 * Export.BYTES_PER_FILE, "nine more floors")
    end)

    t:case("the forecast refuses rather than guessing", function()
        local ok, why = Export.forecast{ format = "tiff", pixels = 1 }
        t:check(ok == nil and why == "bad_format", "an unknown format")
        ok, why = Export.forecast{ format = "pdf" }
        t:check(ok == nil and why == "no_estimate", "no pixel count")
        ok, why = Export.forecast{ format = "pdf", pixels = "lots" }
        t:check(ok == nil and why == "no_estimate", "nor a pixel count that is not one")
        ok, why = Export.forecast{ format = "pdf", pixels = 0 / 0 }
        t:check(ok == nil and why == "no_estimate", "nor a NaN")
    end)

    t:case("the space probe answers nil for everything it cannot trust", function()
        t:eq(Export.availableSpace("/mnt/us", function() error("df is gone") end),
            nil, "a probe that raises does not propagate")
        t:eq(Export.availableSpace("/mnt/us", function() return nil end),
            nil, "nor does one that answers nothing")
        -- What the real `util.diskUsage` returns for a path that is not a
        -- directory: a table whose three fields are all nil.
        t:eq(Export.availableSpace("/nope", function()
            return { total = nil, used = nil, available = nil }
        end), nil, "a table of nils is not a number")
        t:eq(Export.availableSpace("/mnt/us", function()
            return { available = -1 }
        end), nil, "and neither is a negative one")
        t:eq(Export.availableSpace("/mnt/us", function()
            return { available = 4096 }
        end), 4096, "a real answer comes through")
    end)

    t:case("the forecast counts the pixels the allocation will reserve", function()
        local Raster = require("ink_export_raster")
        local Source = require("ink_export_source")
        local pages = {
            { logical_w = 100, logical_h = 200 },
            { logical_w = 50, logical_h = 50 },
        }
        local total = Source.totalPixels(pages, function() return 2 end)
        t:eq(total, Raster.roundedPixels(100, 200, 2)
            + Raster.roundedPixels(50, 50, 2),
            "the same rounding the raster uses")
        -- Half a forecast quoted as a whole one is worse than none, so one
        -- unusable surface takes the whole answer with it.
        t:eq(Source.totalPixels(pages, function(page)
            if page.logical_w == 50 then return nil end
            return 2
        end), nil, "one surface without geometry, no estimate at all")
        t:eq(Source.totalPixels(pages, function() error("boom") end), nil,
            "and a geometry that raises is the same answer")
    end)

    -- =================================================================
    t:describe("export / job / what an interrupted export left behind")

    --[[--
    A sweep narrow enough to be safe, and honest enough to be useful.

    The whole risk here is deleting something that is not ours, so the
    definition of an orphan is deliberately narrow -- our prefix, a regular
    file, in exactly this folder, old enough that no running job could own it
    -- and it is checked twice, once when listing and again when removing.
    If any of these cases could not be written, the definition would be too
    wide.
    ]]

    local NOW = 1000000

    local function sweepFs(files, mtimes)
        return support.newExportFs{
            dirs = { [DIR] = true, [DIR .. "/" .. PREFIX .. "sub"] = true },
            files = files, mtimes = mtimes,
        }
    end

    t:case("only our own old temporaries are offered", function()
        local old = NOW - Export.SWEEP_MIN_AGE - 1
        local fs = sweepFs({
            [DIR .. "/" .. PREFIX .. "a-1.pdf"] = "half a pdf",
            [DIR .. "/" .. PREFIX .. "b-1.png"] = "half a png",
            [DIR .. "/Notebook.pdf"] = "a finished export",
            [DIR .. "/.hidden"] = "somebody else's dotfile",
            -- Another folder entirely: the walk does not recurse.
            [DIR .. "/" .. PREFIX .. "sub/" .. PREFIX .. "c-1.pdf"] = "nested",
        }, {
            [DIR .. "/" .. PREFIX .. "a-1.pdf"] = old,
            [DIR .. "/" .. PREFIX .. "b-1.png"] = old,
        })
        local found = Export.orphans(DIR, { fs = fs, now = NOW })
        t:check(found ~= nil, "the folder could be swept")
        t:eq(#found, 2, "two orphans")
        t:eq(found[1].path, DIR .. "/" .. PREFIX .. "a-1.pdf", "sorted, first")
        t:eq(found[2].path, DIR .. "/" .. PREFIX .. "b-1.png", "sorted, second")
        t:eq(found[1].size, #"half a pdf", "with its size, for the offer")
    end)

    t:case("a temporary too young to be sure about is left alone", function()
        local fs = sweepFs({
            [DIR .. "/" .. PREFIX .. "young-1.pdf"] = "in flight",
        }, {
            [DIR .. "/" .. PREFIX .. "young-1.pdf"] = NOW - 1,
        })
        t:eq(#Export.orphans(DIR, { fs = fs, now = NOW }), 0,
            "a job somewhere else may still own it")
    end)

    t:case("a temporary whose age cannot be read is left alone", function()
        -- The real `lfs` answers nil for a file that went away between the
        -- listing and the stat. Unknown age is not old age.
        local fs = sweepFs({ [DIR .. "/" .. PREFIX .. "x-1.pdf"] = "?" }, {})
        t:eq(#Export.orphans(DIR, { fs = fs, now = NOW }), 0, "not offered")
    end)

    t:case("a folder that is not there answers, it does not raise", function()
        -- `lfs.dir` raises rather than returning nil, and this runs straight
        -- out of a widget callback.
        local fs = sweepFs({}, {})
        local found, why = Export.orphans("/mnt/us/gone", { fs = fs, now = NOW })
        t:check(found == nil and why == "bad_directory", "refused by name")
        local raising = support.newExportFs{ dirs = { [DIR] = true } }
        raising.dir = function() error("cannot open") end
        found, why = Export.orphans(DIR, { fs = raising, now = NOW })
        t:check(found == nil and why == "list_failed",
            "and a walk that raises becomes an answer")
    end)

    t:case("the walk is bounded", function()
        local files, mtimes = {}, {}
        for i = 1, 50 do
            local path = string.format("%s/%s%02d-1.pdf", DIR, PREFIX, i)
            files[path] = "x"
            mtimes[path] = NOW - Export.SWEEP_MIN_AGE - 1
        end
        local fs = sweepFs(files, mtimes)
        -- "." and ".." are two of the three entries the cap allows.
        local found = Export.orphans(DIR, { fs = fs, now = NOW, max_entries = 3 })
        t:eq(#found, 1, "a folder of thousands cannot cost an unbounded wait")
    end)

    t:case("nothing is swept while an export is running", function()
        local f = fixture{ items = { {}, {} } }
        t:check(Export.isRunning(), "a job is in flight")
        local found, why = Export.orphans(DIR, { fs = f.fs, now = NOW })
        t:check(found == nil and why == "export_busy", "the sweep stands down")
        local removed, why2 = Export.removeOrphans({}, { fs = f.fs })
        t:check(removed == nil and why2 == "export_busy", "and so does the removal")
        f.job:cancel()
    end)

    t:case("removal checks the prefix again, and reports what would not go", function()
        local ours = DIR .. "/" .. PREFIX .. "a-1.pdf"
        local theirs = DIR .. "/Notebook.pdf"
        local stuck = DIR .. "/" .. PREFIX .. "b-1.pdf"
        local fs = support.newExportFs{
            dirs = { [DIR] = true },
            files = { [ours] = "1234", [theirs] = "not ours", [stuck] = "12" },
            fail_remove = { [stuck] = "device or resource busy" },
        }
        local removed, freed, failed = Export.removeOrphans({
            { path = ours, size = 4 },
            -- A path that reached the list but is not ours: the check lives
            -- where the deletion is, not where the list came from.
            { path = theirs, size = 8 },
            { path = stuck, size = 2 },
        }, { fs = fs })
        t:eq(removed, 1, "one went")
        t:eq(freed, 4, "and its size is what was freed")
        t:eq(failed, 2, "the foreign one and the stuck one both counted")
        t:eq(fs.files[theirs], "not ours", "and the foreign file is untouched")
        t:eq(fs.files[stuck], "12", "so is the one that could not go")
        t:eq(fs.files[ours], nil, "only ours was removed")
    end)

    t:case("a finished export needs no sweep", function()
        -- The sweep is for power cuts, not for the ordinary path. If this
        -- ever fails, the sweep is covering a leak instead of an accident.
        local f = fixture{ format = "png", items = { {}, {} } }
        f.sched:drain()
        t:eq(f.log.result.status, "done", "it finished")
        t:eq(#f.fs.temporaries(PREFIX), 0, "leaving nothing of its own")
    end)
end
