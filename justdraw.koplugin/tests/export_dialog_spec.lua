--[[--
The dialog, and the decisions it has to make before anything is written.

Two of these are worth stating as tests rather than trusting. A folder is
remembered only after it has been proved to exist, because a remembered folder
that has since been deleted would make every later export fail at preflight
with no obvious cause. And every failure code the pipeline can produce has a
sentence: a reader shown `index_incomplete` has been told nothing, and the
generic fallback exists for codes that do not exist yet, not for the ones that
do.

The rest is the wiring. The menu entry has to be absent exactly when there is
nothing it could do, and the scopes offered have to be the ones that would
actually succeed -- an entry that opens a dialog which then refuses is worse
than no entry.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local env = ctx.env
    local newPlugin = ctx.newPlugin
    local menuItem = ctx.menuItem
    local Dialog = require("ink_export_dialog")
    local Export = require("ink_export")

    local function settings()
        return {
            data = {},
            readSetting = function(self, k) return self.data[k] end,
            saveSetting = function(self, k, v) self.data[k] = v end,
            delSetting = function(self, k) self.data[k] = nil end,
        }
    end

    -- =================================================================
    t:describe("export / dialog / what the reader is told")

    t:case("every code the pipeline produces has its own sentence", function()
        local generic = Dialog.reason("a code that does not exist")
        local codes = {
            "bad_directory", "not_writable", "bad_name", "bad_format",
            "bad_quality", "no_items", "empty", "index_incomplete",
            "unsupported_document", "unsupported_mode", "too_large",
            "too_many_pages", "bad_geometry", "contact_active",
            "rename_failed", "encode_failed", "pdf_failed", "write_failed",
            "render_failed", "bad_raster", "no_repository", "list_failed",
            "flush_failed", "export_busy", "internal_error", "unavailable",
            "sweep_failed",
        }
        -- The list is the claim, so it has to be the whole of `Dialog.reason`.
        -- Anything the module defines and this misses is a code that could
        -- reach a reader untested.
        for code in pairs(Dialog.messages()) do
            local listed = false
            for _, known in ipairs(codes) do
                if known == code then listed = true break end
            end
            t:check(listed, code .. " is covered by this case")
        end
        for _, code in ipairs(codes) do
            local message = Dialog.reason(code)
            t:check(message ~= generic and message ~= "",
                code .. " has a message of its own")
        end
        t:check(generic ~= "", "and an unknown code still says something")
        t:check(Dialog.reason(nil) ~= "", "so does no code at all")
    end)

    t:case("the outcome names the file when there is exactly one", function()
        local message = Dialog.outcome{ status = "done", count = 1,
            written = { "/mnt/us/exports/Notebook.pdf" } }
        t:check(message:find("/mnt/us/exports/Notebook.pdf", 1, true) ~= nil,
            "the reader is told where it went")
    end)

    t:case("a cancelled batch reports what it kept", function()
        local none = Dialog.outcome{ status = "cancelled", count = 0, written = {} }
        t:check(none ~= "", "nothing written is still explained")
        local some = Dialog.outcome{ status = "cancelled", count = 2,
            written = { "a", "b" } }
        t:check(some:find("2", 1, true) ~= nil,
            "and a partial batch says how many survived")
    end)

    t:case("a failure explains itself rather than reporting a code", function()
        t:eq(Dialog.outcome{ status = "failed", count = 0, written = {},
            error = "not_writable" }, Dialog.reason("not_writable"),
            "the failure reason is the message")
    end)

    -- =================================================================
    t:describe("export / dialog / remembered choices")

    t:case("a stored format is used, and an impossible one is not", function()
        local s = settings()
        t:eq(Dialog.rememberedFormat(s), Dialog.DEFAULT_FORMAT, "the default")
        s:saveSetting("justdraw_export_format", "png")
        t:eq(Dialog.rememberedFormat(s), "png", "a stored one")
        -- A settings file edited by hand must not be able to reach the
        -- encoder with a format the job never validated.
        s:saveSetting("justdraw_export_format", "tiff")
        t:eq(Dialog.rememberedFormat(s), Dialog.DEFAULT_FORMAT, "an unknown one")
        s:saveSetting("justdraw_export_format", 7)
        t:eq(Dialog.rememberedFormat(s), Dialog.DEFAULT_FORMAT, "a nonsense one")
    end)

    t:case("a remembered folder is used only while it still exists", function()
        local s = settings()
        local fs = support.newExportFs{ dirs = { ["/mnt/us/mine"] = true } }
        s:saveSetting("justdraw_export_dir", "/mnt/us/mine")
        t:eq(Dialog.rememberedDirectory(s, fs), "/mnt/us/mine", "it is used")
        -- The reader deleted it since. Silently recreating it would put the
        -- files somewhere they are no longer looking.
        fs.dirs["/mnt/us/mine"] = nil
        t:eq(Dialog.rememberedDirectory(s, fs), Dialog.defaultDirectory(),
            "the default takes over")
    end)

    t:case("the default folder is created, and lives beside KOReader's data", function()
        local s = settings()
        local fs = support.newExportFs{}
        local dir = Dialog.rememberedDirectory(s, fs)
        t:eq(dir, "/mnt/us/koreader/justdraw-exports", "where it is")
        t:eq(env.file_modes[dir], "directory", "and it was created")
    end)

    -- =================================================================
    t:describe("export / dialog / the widget")

    t:case("opening it offers the file types and remembers the chosen one", function()
        local s = settings()
        local shown = {}
        local dialog = Dialog.show{
            title = "Export", stem = "Notebook", settings = s,
            build = function() return { items = {}, render = function() end } end,
            show_modal = function(w) shown[#shown + 1] = w; return w end,
            close_modal = function() end,
            notify = function() end,
        }
        t:eq(#shown, 1, "one modal was shown")
        t:eq(shown[1], dialog, "and it is the dialog")
        t:eq(#dialog.added_widgets, 1,
            "with a file type chooser and, with one scope, no scope chooser")
        local labels = {}
        for _, row in ipairs(dialog.added_widgets[1].radio_buttons) do
            for _, button in ipairs(row) do labels[#labels + 1] = button.text end
        end
        t:eq(table.concat(labels, ","), "File type,PDF,PNG,JPEG", "the closed set")
    end)

    t:case("two scopes get their own chooser, one does not", function()
        local function widgets(scopes)
            local dialog = Dialog.show{
                title = "Export", stem = "N", settings = settings(),
                scopes = scopes,
                build = function() return { items = {}, render = function() end } end,
                show_modal = function(w) return w end,
                close_modal = function() end, notify = function() end,
            }
            return #dialog.added_widgets
        end
        t:eq(widgets({ { value = "a", label = "A" } }), 1, "one scope, no chooser")
        t:eq(widgets({ { value = "a", label = "A" }, { value = "b", label = "B" } }),
            2, "two scopes, a chooser")
    end)

    -- =================================================================
    t:describe("export / dialog / the name follows the scope")

    --[[--
    Two scopes, two names, and a reader who can overrule both.

    The proposed name only means anything if it describes what is about to be
    written: "p12" is right for one page and false for twenty. What makes this
    safe rather than annoying is the second half -- the moment the reader types
    in the field, the name is theirs and the radio stops touching it.
    ]]
    local SCOPES = { { value = "page", label = "This page" },
                     { value = "sheets", label = "All sheets" } }

    local function showWithStems(stem)
        local dialog = Dialog.show{
            title = "Export", stem = stem, settings = settings(),
            scopes = SCOPES,
            build = function() return { items = {}, render = function() end } end,
            show_modal = function(w) return w end,
            close_modal = function() end, notify = function() end,
        }
        -- The scope chooser is the second widget the dialog adds; the first
        -- is the file type.
        return dialog, dialog.added_widgets[2]
    end

    t:case("a stem function is asked about the scope the dialog opens on", function()
        local asked = {}
        local dialog = showWithStems(function(scope)
            asked[#asked + 1] = scope
            return "Book " .. tostring(scope)
        end)
        t:eq(asked[1], "page", "asked about the first scope")
        t:eq(dialog:getFields()[1], "Book page", "and its answer is in the field")
    end)

    t:case("choosing another scope proposes another name", function()
        local dialog, scope_radio = showWithStems(function(scope)
            return "Book " .. tostring(scope)
        end)
        t:check(scope_radio:select("sheets"), "the radio moved")
        t:eq(dialog:getFields()[1], "Book sheets", "and the name followed it")
        t:check(scope_radio:select("page"), "and back")
        t:eq(dialog:getFields()[1], "Book page", "and so did the name")
    end)

    t:case("a name the reader typed survives a change of scope", function()
        local dialog, scope_radio = showWithStems(function(scope)
            return "Book " .. tostring(scope)
        end)
        dialog.input_fields[1]:typeText("my notes")
        scope_radio:select("sheets")
        t:eq(dialog:getFields()[1], "my notes",
            "the reader's name is not taken away")
    end)

    t:case("a stem function that raises leaves the field alone", function()
        local dialog, scope_radio = showWithStems(function(scope)
            if scope == "sheets" then error("no") end
            return "Book page"
        end)
        t:check(scope_radio:select("sheets"), "the radio still moves")
        t:eq(dialog:getFields()[1], "Book page", "and the field is untouched")
    end)

    t:case("a plain string stem still works, for the surfaces that use one", function()
        local dialog, scope_radio = showWithStems("Notebook")
        t:eq(dialog:getFields()[1], "Notebook", "it is the field's text")
        scope_radio:select("sheets")
        t:eq(dialog:getFields()[1], "Notebook", "and it does not move")
    end)

    t:case("the export uses the name in the field, not the one proposed", function()
        -- The proposal is a suggestion all the way to the last moment: what
        -- reaches the plan is whatever the field says when Export is tapped.
        local fs = support.newExportFs{ dirs = { ["/mnt/us/exports"] = true } }
        local s = settings()
        s:saveSetting("justdraw_export_dir", "/mnt/us/exports")
        local sched = support.newScheduler()
        local dialog
        dialog = Dialog.show{
            title = "Export", stem = function() return "proposed" end,
            settings = s, scopes = SCOPES,
            build = function()
                return { items = { {} }, render = function(item, index, done)
                    local bb = support.newBlitbuffer(2, 2)
                    done({ bb = bb, width_pt = 10, height_pt = 10,
                        release = function() bb:free() end })
                end }
            end,
            show_modal = function(w) return w end,
            close_modal = function() end, notify = function() end,
            schedule = function(fn) sched:schedule(fn) end,
            fs = fs,
        }
        dialog.input_fields[1]:typeText("what I called it")
        -- The Export button is the last one of the last row.
        local row = dialog.buttons[#dialog.buttons]
        row[#row].callback()
        sched:drain()
        t:check(fs.files["/mnt/us/exports/what I called it.pdf"] ~= nil,
            "written under the reader's name")
        t:eq(fs.files["/mnt/us/exports/proposed.pdf"], nil,
            "and not under the proposal")
    end)

    t:case("proposeStem refuses what it cannot or should not write", function()
        local dialog = showWithStems("Notebook")
        t:eq(Dialog.proposeStem(dialog, ""), false, "an empty name is not a name")
        t:eq(Dialog.proposeStem(dialog, nil), false, "nor is nothing")
        t:eq(Dialog.proposeStem({}, "x"), false, "a dialog with no fields refuses")
        t:eq(Dialog.proposeStem(dialog, "Other"), true, "a real one is taken")
        t:eq(dialog:getFields()[1], "Other", "and lands")
    end)

    -- =================================================================
    t:describe("export / dialog / running a job")

    t:case("a build that refuses stops before the job and says why", function()
        local said
        local job, err = Dialog.run{
            build = function() return nil, "index_incomplete" end,
            notify = function(text) said = text end,
            show_modal = function(w) return w end,
            close_modal = function() end,
            format = "pdf", dir = "/mnt/us", stem = "x",
        }
        t:check(job == nil, "no job")
        t:eq(err, "index_incomplete", "reason")
        t:eq(said, Dialog.reason("index_incomplete"), "explained")
    end)

    t:case("a name collision asks before it replaces anything", function()
        local target = "/mnt/us/exports/Notebook.pdf"
        local fs = support.newExportFs{
            dirs = { ["/mnt/us/exports"] = true },
            files = { [target] = "an earlier export" },
        }
        local sched = support.newScheduler()
        local modals, closed, said = {}, {}, nil
        local progress_modal
        local rendered = 0
        local built = {
            items = { {} },
            render = function(item, index, done)
                rendered = rendered + 1
                local bb = support.newBlitbuffer(2, 2)
                done({ bb = bb, width_pt = 10, height_pt = 10,
                    release = function() bb:free() end })
            end,
        }
        Dialog.run{
            build = function() return built end,
            notify = function(text) said = text end,
            show_modal = function(w)
                modals[#modals + 1] = w
                if w.buttons then progress_modal = w end
                return w
            end,
            close_modal = function(w) closed[#closed + 1] = w end,
            schedule = function(fn) sched:schedule(fn) end,
            format = "pdf", dir = "/mnt/us/exports", stem = "Notebook",
            fs = fs,
        }
        t:eq(rendered, 0, "nothing was rendered while the question stood")
        t:eq(#modals, 1, "a confirmation was shown")
        t:check(modals[1].ok_callback ~= nil, "with a way to say yes")
        t:eq(fs.files[target], "an earlier export", "and nothing was touched yet")

        -- ADR-28 forbids a cancel_callback that *closes the ConfirmBox* --
        -- it closes itself, and a second close refreshes stale pixels. One
        -- that takes down a different widget is not only allowed, it is what
        -- stops the progress modal being orphaned when the reader declines.
        t:check(modals[1].cancel_callback ~= nil,
            "declining has somewhere to clean up")
        modals[1].cancel_callback()
        t:eq(closed[1], progress_modal,
            "and it takes down the progress modal, not the ConfirmBox")
        t:eq(rendered, 0, "still nothing rendered")
    end)

    t:case("confirming the replacement records the job Cancel needs", function()
        local target = "/mnt/us/exports/Notebook-01.png"
        local fs = support.newExportFs{
            dirs = { ["/mnt/us/exports"] = true },
            files = { [target] = "an earlier export" },
        }
        local sched = support.newScheduler()
        local modals, tracker, said = {}, {}, nil
        local built = {
            items = { {}, {} },
            render = function(item, index, done) end,   -- never answers
        }
        Dialog.run{
            build = function() return built end,
            notify = function(text) said = text end,
            show_modal = function(w) modals[#modals + 1] = w; return w end,
            close_modal = function() end,
            schedule = function(fn) sched:schedule(fn) end,
            active_job = tracker,
            format = "png", dir = "/mnt/us/exports", stem = "Notebook",
            fs = fs,
        }
        t:check(tracker.job == nil, "no job while the question stands")
        modals[#modals].ok_callback()
        -- The retry used to discard the job it produced, leaving the progress
        -- modal's Cancel button reading nil -- inert for the case a reader
        -- hits most often, re-exporting the same notebook.
        t:check(tracker.job ~= nil, "the retried job is recorded")
        t:check(tracker.job:cancel(), "so Cancel reaches a real job")
        t:check(tracker.job:isFinished(), "and stops it")
    end)

    -- =================================================================
    t:describe("export / dialog / clearing up after a power cut")

    --[[--
    The offer, and the two things it must never do.

    It must not appear for a folder that has nothing in it -- an export dialog
    that always shows a housekeeping button teaches the reader to ignore it --
    and it must not delete without asking, because a button that removes files
    on the first tap is the one thing the narrow definition of an orphan cannot
    protect anybody from.
    ]]

    local SWEEP_DIR = "/mnt/us/exports"
    local SWEEP_PREFIX = Export.TEMP_PREFIX

    local function showWithFolder(files, mtimes)
        local fs = support.newExportFs{
            dirs = { [SWEEP_DIR] = true }, files = files, mtimes = mtimes,
        }
        local s = settings()
        s:saveSetting("justdraw_export_dir", SWEEP_DIR)
        local modals, said = {}, nil
        local dialog = Dialog.show{
            title = "Export", stem = "Notebook", settings = s,
            build = function() return { items = {}, render = function() end } end,
            show_modal = function(w) modals[#modals + 1] = w; return w end,
            close_modal = function() end,
            notify = function(text) said = text end,
            fs = fs, now = 1000000,
        }
        return dialog, fs, modals, function() return said end
    end

    t:case("a clean folder gets no clean-up row", function()
        local dialog = showWithFolder({}, {})
        t:eq(#dialog.buttons, 1, "one row: the dialog's own three buttons")
        t:eq(#dialog.buttons[1], 3, "Folder, Cancel, Export")
    end)

    t:case("leftovers get their own row, counted", function()
        local old = 1000000 - Export.SWEEP_MIN_AGE - 1
        local a = SWEEP_DIR .. "/" .. SWEEP_PREFIX .. "a-1.pdf"
        local b = SWEEP_DIR .. "/" .. SWEEP_PREFIX .. "b-1.pdf"
        local dialog = showWithFolder({ [a] = "xx", [b] = "yyy" },
            { [a] = old, [b] = old })
        t:eq(#dialog.buttons, 2, "a row of its own, above the usual three")
        t:eq(#dialog.buttons[1], 1, "holding one button")
        t:check(dialog.buttons[1][1].text:find("2", 1, true) ~= nil,
            "which says how many")
    end)

    t:case("the clean-up asks before it deletes, and deletes only ours", function()
        local old = 1000000 - Export.SWEEP_MIN_AGE - 1
        local ours = SWEEP_DIR .. "/" .. SWEEP_PREFIX .. "a-1.pdf"
        local theirs = SWEEP_DIR .. "/Notebook.pdf"
        local dialog, fs, modals, said =
            showWithFolder({ [ours] = "xx", [theirs] = "a real export" },
                { [ours] = old, [theirs] = old })
        dialog.buttons[1][1].callback()
        t:eq(#modals, 2, "the dialog, then the question")
        t:check(modals[2].ok_callback ~= nil, "which has a way to say yes")
        t:eq(fs.files[ours], "xx", "and nothing has gone yet")
        modals[2].ok_callback()
        t:eq(fs.files[ours], nil, "now the leftover has")
        t:eq(fs.files[theirs], "a real export", "and the real export has not")
        t:check(said() ~= nil and said():find("1", 1, true) ~= nil,
            "and the reader is told what happened")
    end)

    t:case("a removal that fails says so rather than claiming success", function()
        local old = 1000000 - Export.SWEEP_MIN_AGE - 1
        local stuck = SWEEP_DIR .. "/" .. SWEEP_PREFIX .. "a-1.pdf"
        local fs = support.newExportFs{
            dirs = { [SWEEP_DIR] = true },
            files = { [stuck] = "xx" }, mtimes = { [stuck] = old },
            fail_remove = { [stuck] = "device or resource busy" },
        }
        local s = settings()
        s:saveSetting("justdraw_export_dir", SWEEP_DIR)
        local modals, said = {}, nil
        local dialog = Dialog.show{
            title = "Export", stem = "Notebook", settings = s,
            build = function() return { items = {}, render = function() end } end,
            show_modal = function(w) modals[#modals + 1] = w; return w end,
            close_modal = function() end,
            notify = function(text) said = text end,
            fs = fs, now = 1000000,
        }
        dialog.buttons[1][1].callback()
        modals[2].ok_callback()
        t:eq(said, Dialog.reason("sweep_failed"), "the truth, not a tally")
        t:eq(fs.files[stuck], "xx", "and the file is still there")
    end)

    -- =================================================================
    t:describe("export / dialog / room on the card")

    --[[--
    A question, asked once, that never turns into a refusal.

    The estimate can only be right to within the ink on the page, so the two
    things that matter are the edges: a probe that says nothing must produce
    silence rather than a guess, and a reader who says "export anyway" must get
    the export. Everything in between is the nicety.
    ]]

    local DIR = "/mnt/us/exports"

    --- One run with a controllable amount of free space.
    local function runWithSpace(space, extra)
        extra = extra or {}
        -- One export at a time is a production guarantee, and a case above
        -- deliberately leaves its job running to prove Cancel reaches it. End
        -- it here, exactly as closing a document does, or the next run is
        -- refused with `export_busy` and proves nothing about the question.
        if Export.isRunning() then Export.cancelRunning() end
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        local sched = support.newScheduler()
        local modals, closed, said = {}, {}, nil
        local rendered, finished = 0, {}
        local built = {
            items = extra.items or { {} },
            pixels = extra.pixels,
            confirm_warning = extra.confirm_warning,
            render = function(item, index, done)
                rendered = rendered + 1
                local bb = support.newBlitbuffer(2, 2)
                done({ bb = bb, width_pt = 10, height_pt = 10,
                    release = function() bb:free() end })
            end,
            finish = function(result) finished[#finished + 1] = result or false end,
        }
        local job, err = Dialog.run{
            build = function() return built end,
            notify = function(text) said = text end,
            show_modal = function(w)
                modals[#modals + 1] = w
                if extra.refuse_modal then return nil end
                return w
            end,
            close_modal = function(w) closed[#closed + 1] = w end,
            schedule = function(fn) sched:schedule(fn) end,
            format = extra.format or "pdf", dir = DIR, stem = "Notebook",
            fs = fs,
            disk = function() return space end,
        }
        return { fs = fs, sched = sched, modals = modals, closed = closed,
            finished = finished, said = function() return said end,
            rendered = function() return rendered end,
            job = job, err = err }
    end

    t:case("plenty of room asks nothing and exports", function()
        local r = runWithSpace({ available = 500 * 1024 * 1024 },
            { pixels = 1000000 })
        t:eq(#r.modals, 0, "no question, and no progress modal for one page")
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil, "the file was written")
    end)

    t:case("a probe that knows nothing asks nothing", function()
        -- `util.diskUsage` answers a table of nils for a path it cannot stat.
        -- Not knowing must never stop an export.
        local r = runWithSpace({ available = nil }, { pixels = 4000000000 })
        t:eq(#r.modals, 0, "silence, not a guess")
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil, "and it exported")
    end)

    t:case("no estimate and room to spare asks nothing", function()
        -- `pixels` is optional: a surface that cannot say how big it is must
        -- not start producing questions.
        local r = runWithSpace({ available = 500 * 1024 * 1024 }, {})
        t:eq(#r.modals, 0, "nothing to ask about")
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil, "and it exported")
    end)

    t:case("too little room asks, and nothing is read until it is answered", function()
        local r = runWithSpace({ available = 200 * 1024 },
            { pixels = 200 * 1000000 })
        t:eq(#r.modals, 1, "one question")
        t:check(r.modals[1].ok_callback ~= nil, "with a way to go ahead")
        t:eq(r.rendered(), 0, "and nothing was rendered while it stood")
        t:eq(r.fs.files[DIR .. "/Notebook.pdf"], nil, "nor written")
    end)

    t:case("saying yes exports anyway -- the estimate is never a refusal", function()
        local r = runWithSpace({ available = 200 * 1024 },
            { pixels = 200 * 1000000 })
        r.modals[1].ok_callback()
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil,
            "the reader's decision wins")
    end)

    t:case("saying no writes nothing and releases what the source opened", function()
        local r = runWithSpace({ available = 200 * 1024 },
            { pixels = 200 * 1000000 })
        r.modals[1].cancel_callback()
        r.sched:drain()
        t:eq(r.rendered(), 0, "nothing rendered")
        t:eq(r.fs.files[DIR .. "/Notebook.pdf"], nil, "nothing written")
        t:eq(#r.fs.temporaries(Export.TEMP_PREFIX), 0, "nothing left behind")
        t:eq(#r.finished, 1, "and the source was told to let go")
    end)

    t:case("a nearly full folder asks even when this export would fit", function()
        local r = runWithSpace({ available = Export.LOW_WATER - 1 },
            { pixels = 1 })
        t:eq(#r.modals, 1, "asked about the folder, not about this file")
        t:check(Export.forecast{ format = "pdf", pixels = 1, files = 1 }
            < Export.LOW_WATER - 1, "even though the estimate fits")
    end)

    t:case("the question comes before the progress modal, never beside it", function()
        -- Two stacked modals leave the reader unable to tell which buttons
        -- belong to which.
        local r = runWithSpace({ available = 200 * 1024 },
            { pixels = 200 * 1000000, items = { {}, {}, {} } })
        t:eq(#r.modals, 1, "only the question is up")
        t:check(r.modals[1].ok_text ~= nil, "and it is the question")
        r.modals[1].ok_callback()
        t:eq(#r.modals, 2, "the progress modal follows the answer")
        t:check(r.modals[2].buttons ~= nil, "and it is the one with Cancel")
    end)

    t:case("a host that refuses the question exports nothing and says why", function()
        -- The editor's `show_modal` refuses while the pen is down. A question
        -- that never reached the screen must not become a silent export.
        local r = runWithSpace({ available = 200 * 1024 },
            { pixels = 200 * 1000000, refuse_modal = true })
        t:eq(r.rendered(), 0, "nothing rendered")
        t:eq(r.said(), Dialog.reason("contact_active"), "and it says why")
    end)

    -- =================================================================
    t:describe("export / dialog / a warning before the read")

    --[[--
    A surface that knows its export will be incomplete says so first.

    The question exists because the answer changes what the reader gets, not
    because it is polite: a run that will silently leave something out is worse
    than one that never started. So the same three properties hold as for the
    space question -- nothing is read while it stands, declining releases what
    the source opened and writes nothing, and a host that refuses to show it
    must not turn the silence into an export.

    The fourth property is the one that only exists once there are two
    questions: they are asked one after the other. Two stacked ConfirmBoxes
    leave the reader unable to tell which buttons belong to which.
    ]]

    local WARNING = "Some ink on this page cannot be exported."

    local PLENTY = { available = 500 * 1024 * 1024 }
    local TIGHT = { available = 200 * 1024 }

    t:case("the warning is shown, and nothing is read while it stands", function()
        local r = runWithSpace(PLENTY, { confirm_warning = WARNING })
        t:eq(#r.modals, 1, "one question")
        t:eq(r.modals[1].text, WARNING, "in the surface's own words")
        t:check(r.modals[1].ok_callback ~= nil, "with a way to go ahead")
        t:eq(r.err, "confirm_warning", "and the run says a question is standing")
        t:eq(r.rendered(), 0, "nothing was rendered")
        t:eq(r.fs.files[DIR .. "/Notebook.pdf"], nil, "nor written")
        t:eq(#r.finished, 0, "and the source has not been let go of")
    end)

    t:case("saying yes exports, warning and all", function()
        local r = runWithSpace(PLENTY, { confirm_warning = WARNING })
        r.modals[1].ok_callback()
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil,
            "the reader was warned and went ahead")
    end)

    t:case("saying no writes nothing and releases what the source opened", function()
        local r = runWithSpace(PLENTY, { confirm_warning = WARNING })
        r.modals[1].cancel_callback()
        r.sched:drain()
        t:eq(r.rendered(), 0, "nothing rendered")
        t:eq(r.fs.files[DIR .. "/Notebook.pdf"], nil, "nothing written")
        t:eq(#r.fs.temporaries(Export.TEMP_PREFIX), 0, "nothing left behind")
        t:eq(#r.finished, 1, "the source was told to let go")
        t:eq(r.finished[1], false, "with no result, because there was no job")
        t:check(r.said() == nil, "and the reader is not told off for declining")
        -- ADR-28: a ConfirmBox closes itself, and a second close pushes stale
        -- pixels back at the panel. There is no progress modal here, so this
        -- says the callback closed nothing at all.
        t:eq(#r.closed, 0, "and nothing was closed on its behalf")
    end)

    t:case("a host that refuses the warning exports nothing and says why", function()
        -- The editor's `show_modal` refuses while the pen is down. A warning
        -- that never reached the screen must not become a silent export.
        local r = runWithSpace(PLENTY,
            { confirm_warning = WARNING, refuse_modal = true })
        t:eq(r.rendered(), 0, "nothing rendered")
        t:eq(r.fs.files[DIR .. "/Notebook.pdf"], nil, "nothing written")
        t:eq(r.said(), Dialog.reason("contact_active"), "and it says why")
        t:eq(#r.finished, 1, "the source was released")
    end)

    t:case("the warning and the space question are asked one at a time", function()
        local r = runWithSpace(TIGHT,
            { confirm_warning = WARNING, pixels = 200 * 1000000 })
        t:eq(#r.modals, 1, "only the warning is up")
        t:eq(r.modals[1].text, WARNING, "and it is the warning, not the space")
        r.modals[1].ok_callback()
        t:eq(#r.modals, 2, "the space question follows the answer")
        t:check(r.modals[2].text ~= WARNING, "and it is the other question")
        t:eq(r.rendered(), 0, "still nothing read")
        r.modals[2].ok_callback()
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil,
            "and both answers together produce the export")
    end)

    t:case("no warning, or an empty one, changes nothing", function()
        local r = runWithSpace(PLENTY, { confirm_warning = "" })
        t:eq(#r.modals, 0, "an empty string is not something to say")
        t:check(r.err == nil, "and the run took the old path")
        r.sched:drain()
        t:check(r.fs.files[DIR .. "/Notebook.pdf"] ~= nil, "straight to the export")
    end)

    -- =================================================================
    t:describe("export / dialog / the reader's entry point")

    t:case("the menu entry exists and is disabled when nothing can be exported", function()
        local plugin = newPlugin{}
        local item = menuItem(plugin, "Export…")
        t:check(item ~= nil, "the entry is in the menu")
        t:check(item.help_text ~= nil, "and explains itself")
        t:check(type(item.enabled_func) == "function", "with a live enabled state")
        -- The fake document is not a paging document and there is no canvas
        -- session, so there is nothing this reader could export.
        t:eq(item.enabled_func(), false, "disabled with nothing to export")
        t:eq(#plugin:exportScopes(), 0, "because no scope is available")
    end)

    t:case("a fixed-layout page in page mode offers itself", function()
        local plugin = newPlugin{}
        plugin.ui.paging = true
        plugin.view.page_scroll = false
        plugin.view.document = { drawPage = function() end }
        plugin.view.dimen = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.visible_area = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.state = { page = 3, zoom = 1, rotation = 0, gamma = 1,
            saturation = 1, offset = { x = 0, y = 0 } }
        local scopes = plugin:exportScopes()
        t:eq(#scopes, 1, "one scope")
        t:eq(scopes[1].value, "page", "the current page")
        t:check(menuItem(plugin, "Export…").enabled_func(), "and the entry is live")
    end)

    t:case("the page export renders the document and this page's ink", function()
        local plugin = newPlugin{}
        plugin.ui.paging = true
        local drawn = 0
        plugin.view.document = { drawPage = function(_, bb)
            drawn = drawn + 1
            bb:paintRect(0, 0, 2, 2, "page")
        end }
        plugin.view.dimen = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.visible_area = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.state = { page = 3, zoom = 1, rotation = 0, gamma = 1,
            saturation = 1, offset = { x = 0, y = 0 } }
        plugin.store:add(3, { n = 2, w = 4, 10, 10, 30, 10 })

        local built, err = plugin:buildExport("page")
        t:check(built ~= nil, "built: " .. tostring(err))
        t:eq(#built.items, 1, "one page")
        local delivered
        built.render(built.items[1], 1, function(result) delivered = result end)
        t:eq(drawn, 1, "the document was drawn once")
        t:check(delivered ~= nil, "a raster came back")
        t:check(#delivered.bb.rects > 2, "with the page and the ink on it")
        delivered.release()
    end)

    t:case("an export is refused outright while the pen is still down", function()
        local plugin = newPlugin{}
        plugin.ui.paging = true
        plugin.input_lease = { hasActiveContact = function() return true end }
        local built, err = plugin:buildExport("page")
        t:check(built == nil, "refused")
        t:eq(err, "contact_active", "with the reason the reader can act on")
        t:check(Dialog.reason(err):find("pen", 1, true) ~= nil,
            "which becomes a sentence about the pen")
    end)

    t:case("the reader's proposed name carries a page, but only when it is one", function()
        local plugin = newPlugin{}
        plugin.ui.paging = true
        plugin.ui.document = { file = "/mnt/us/books/Moby Dick.pdf",
            drawPage = function() end }
        plugin.view.document = plugin.ui.document
        plugin.view.dimen = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.visible_area = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.state = { page = 12, zoom = 1, rotation = 0, gamma = 1,
            saturation = 1, offset = { x = 0, y = 0 } }

        local stamp = "2026-08-30-120000"
        local page_stem = plugin:exportStem("page", stamp)
        local all_stem = plugin:exportStem("sheets", stamp)
        t:eq(page_stem, "Moby Dick p12 " .. stamp, "one page names its page")
        t:eq(all_stem, "Moby Dick " .. stamp,
            "and a scope covering many names none")
        -- One clock read for the whole dialog: tapping a radio button must not
        -- move the time.
        t:check(page_stem:find(stamp, 1, true) ~= nil
            and all_stem:find(stamp, 1, true) ~= nil,
            "both scopes share the one stamp")
    end)

    t:case("a sheet is named by the page the index resolved, or by none", function()
        local plugin = newPlugin{}
        plugin.ui.document = { file = "/mnt/us/books/Moby Dick.epub" }
        local placed = 7
        plugin.session = {
            activeCanvas = function() return { id = 4 } end,
            exportSources = function()
                return {}, { pageOf = function(_, id)
                    return id == 4 and placed or nil
                end }
            end,
        }
        t:eq(plugin:exportScopePage("sheet"), 7, "the resolved page")
        placed = nil
        t:check(plugin:exportScopePage("sheet") == nil,
            "an orphan sheet gets no invented page")
        t:eq(plugin:exportStem("sheet", "S"), "Moby Dick S",
            "and its name says nothing about a page")
    end)

    t:case("the built export leaves /Title to the name the reader chose", function()
        local plugin = newPlugin{}
        plugin.ui.paging = true
        plugin.view.document = { drawPage = function() end }
        plugin.view.dimen = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.visible_area = { x = 0, y = 0, w = 100, h = 200 }
        plugin.view.state = { page = 3, zoom = 1, rotation = 0, gamma = 1,
            saturation = 1, offset = { x = 0, y = 0 } }
        local built = plugin:buildExport("page")
        t:check(built ~= nil, "built")
        -- `Dialog.run` uses `built.title or opts.stem`, so an absent title is
        -- what makes the typed name reach the PDF instead of a regenerated
        -- stem that can differ from the file name by a few seconds.
        t:check(built.title == nil, "no title of its own")
    end)

    t:case("the notebook windows both offer an export", function()
        local plugin = newPlugin{}
        local Editor = require("ink_notebook_editor")
        local Library = require("ink_notebook_library")
        t:check(type(Editor.showExport) == "function",
            "the editor can open one")
        t:check(type(Library.showExport) == "function",
            "and so can the library, with no book open")
    end)
    t:case("a reader's own dossier asks about its legacy ink first", function()
        -- The generic cases above build the warning by hand. This is the one
        -- that goes through the controller, so the sentence a reader actually
        -- sees is the one the source composed (ADR-40).
        if Export.isRunning() then Export.cancelRunning() end
        local plugin = newPlugin{}
        plugin.ui.paging = true
        plugin.store:add(7, { n = 2, w = 4, 10, 10, 30, 10 })
        local fs = support.newExportFs{ dirs = { [DIR] = true } }
        local sched = support.newScheduler()
        local modals, said = {}, nil
        local job, err = Dialog.run{
            build = function(scope) return plugin:buildExport(scope) end,
            scope = "notes",
            notify = function(text) said = text end,
            show_modal = function(w) modals[#modals + 1] = w; return w end,
            close_modal = function() end,
            schedule = function(fn) sched:schedule(fn) end,
            format = "pdf", dir = DIR, stem = "Notes",
            fs = fs,
            disk = function() return { available = 500 * 1024 * 1024 } end,
        }
        t:check(job == nil, "no job while a question is standing")
        t:eq(err, "confirm_warning", "and the run says which question")
        t:eq(#modals, 1, "one question")
        t:check(modals[1].text:find("legacy ink", 1, true) ~= nil,
            "about the legacy ink: " .. tostring(modals[1].text))
        modals[1].ok_callback()
        -- Two queues: the job advances on the dialog's scheduler, and the
        -- renderer delivers on the plugin's own (both `UIManager:nextTick` in
        -- production). Pump them together until the run settles.
        for _ = 1, 20 do
            if said then break end
            sched:drain()
            env.UIManager:flush()
        end
        t:check(fs.files[DIR .. "/Notes.pdf"] ~= nil,
            "and saying yes exports the dossier: " .. tostring(said))
        t:check(said ~= nil and said:find("Exported", 1, true) ~= nil,
            "and the reader is told where it went")
        if Export.isRunning() then Export.cancelRunning() end
    end)
end
