--[[--
The one dialog the reader sees, and the choices it has to get right before
anything is read.

Everything destructive or slow is decided here and nowhere else: the format
(from a closed set, so a typo cannot become a JPEG), the destination folder
(remembered only once it has been proved to exist), the file name, and what to
do about names that are already taken. By the time `ink_export` starts, the
answer to every question that could stop the job is already known.

Two host seams keep this widget honest about where it is running. `show_modal`
and `close_modal` come from whoever owns the screen -- the notebook editor, the
library, or the reader -- because closing a modal is idempotent only if the
owner is tracking it, and a second close pushes stale pixels back at the panel
(ADR-28). And the editor's version refuses while the pen is down, which is the
same gate that stops an export from starting mid-stroke.

Progress is a static modal rather than a counter. Each page redraws it, and on
an e-ink panel a per-page redraw of a dialog is a visible flash per page for
no information the reader can act on; the total is shown once at the start and
the outcome once at the end. Cancel is a real button on that modal, and it
takes effect at the next page boundary or when the raster in flight settles.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Compat = require("ink_compat")
local Export = require("ink_export")

local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local Screen = Device.screen

local Dialog = {}

Dialog.SETTING_FORMAT = "export_format"
Dialog.SETTING_DIR = "export_dir"
Dialog.DEFAULT_FORMAT = "pdf"

--- Ordered, because this is also what the radio shows.
Dialog.FORMATS = {
    { value = "pdf", label = "PDF" },
    { value = "png", label = "PNG" },
    { value = "jpg", label = "JPEG" },
}

--[[--
Why an export could not run or did not finish, in words a reader can act on.

Every code the pipeline can produce is listed. An unknown one still gets a
sentence rather than a code, because a reader who is shown `bad_geometry` has
been told nothing.
]]
local function messages()
    -- Built per call rather than at load: `_()` resolves against whatever
    -- language is current, and a table frozen at require time would go stale
    -- the moment the reader changed it.
    return {
        bad_directory = _("That folder no longer exists. Choose another one."),
        not_writable = _("Nothing can be written to that folder. Choose another one."),
        bad_name = _("That file name can’t be used. Choose another one."),
        bad_format = _("That file type isn’t supported."),
        bad_quality = _("That image quality isn’t supported."),
        no_items = _("There’s nothing to export here."),
        empty = _("There’s nothing to export here."),
        index_incomplete = _("The sheets in this book are still being located. Try again in a moment."),
        unsupported_document = _("This document can’t be exported yet. Only fixed-layout documents, such as PDFs, can."),
        unsupported_mode = _("Turn off continuous scrolling to export the page you’re reading."),
        too_large = _("This page is too large to export."),
        too_many_pages = _("This notebook has too many pages to export at once."),
        bad_geometry = _("This page’s size can’t be used for an export."),
        contact_active = _("Lift the pen and try again."),
        rename_failed = _("The exported file couldn’t be put in place. Check the folder and try again."),
        encode_failed = _("The image couldn’t be written. The folder may be full."),
        pdf_failed = _("The PDF couldn’t be written. The folder may be full."),
        write_failed = _("The file couldn’t be written. The folder may be full."),
        render_failed = _("This page couldn’t be drawn for export."),
        bad_raster = _("This page couldn’t be drawn for export."),
        no_repository = _("The notebook store isn’t available right now."),
        list_failed = _("The pages couldn’t be read. Try again."),
        flush_failed = _("Some ink hasn’t been saved yet, so nothing was exported. Try again."),
        export_busy = _("An export is already running. Wait for it to finish, or cancel it."),
        sweep_failed = _("Some leftover files couldn’t be removed. They may be in use."),
        internal_error = _("The export stopped unexpectedly. Nothing incomplete was kept."),
        unavailable = _("Drawing sheets aren’t available for this document."),
    }
end

--- Exposed so a spec can state that every code this module defines is one the
--- spec covers. A list that drifts is a code that reaches a reader untested.
function Dialog.messages() return messages() end

function Dialog.reason(code)
    local known = messages()
    if code and known[code] then return known[code] end
    return _("The export didn’t finish. Nothing was changed.")
end

--- The default destination. Kept beside KOReader's own data rather than in the
--- book's folder, so exporting from the file browser -- where there is no book
--- -- lands somewhere predictable.
function Dialog.defaultDirectory()
    local DataStorage = require("datastorage")
    -- `getFullDataDir` answers nil unless the data directory is absolute or
    -- exactly "."; a relative KO_HOME -- which the project's own QA script
    -- uses -- reaches that hole, and concatenating nil here would raise
    -- straight out of a TouchMenu callback, which is not guarded.
    local root = DataStorage:getFullDataDir() or DataStorage:getDataDir() or "."
    return root .. "/justdraw-exports"
end

local function readSetting(settings, key, fallback)
    if not settings then return fallback end
    local value = Compat.readSetting(settings, key, fallback)
    if value == nil then return fallback end
    return value
end

local function isKnownFormat(value)
    for i = 1, #Dialog.FORMATS do
        if Dialog.FORMATS[i].value == value then return true end
    end
    return false
end

--- The remembered format, or the default when nothing sensible is stored. A
--- settings file edited by hand cannot make the export write an unknown type.
function Dialog.rememberedFormat(settings)
    local stored = readSetting(settings, Dialog.SETTING_FORMAT, nil)
    if type(stored) == "string" and isKnownFormat(stored) then return stored end
    return Dialog.DEFAULT_FORMAT
end

--[[--
The remembered folder, or the default -- and the default is created.

Only the default is created automatically. A folder the reader chose and then
deleted is a question for them, not something to silently recreate somewhere
they are no longer looking.
]]
function Dialog.rememberedDirectory(settings, fs)
    fs = fs or { attributes = function(path, what)
        return require("libs/libkoreader-lfs").attributes(path, what)
    end }
    local stored = readSetting(settings, Dialog.SETTING_DIR, nil)
    if type(stored) == "string" and stored ~= ""
        and fs.attributes(stored, "mode") == "directory" then
        return stored
    end
    local default = Dialog.defaultDirectory()
    if fs.attributes(default, "mode") ~= "directory" then
        local util = require("util")
        util.makePath(default)
    end
    return default
end

--[[--
The name proposed for one scope.

`opts.stem` may be a plain string -- a notebook's title does not depend on what
is being exported -- or a function of the scope, which is what lets the reader's
dialog offer a page number for "This page" and not for "All sheets in this
book". It runs under `pcall` because it is a call back into the host from
inside a widget callback, and there is no net there.
]]
local function stemFor(opts, scope)
    if type(opts.stem) ~= "function" then return opts.stem or "" end
    local ok, value = pcall(opts.stem, scope)
    if ok and type(value) == "string" and value ~= "" then return value end
    return ""
end

--[[--
Offer a new proposed name, unless the reader has made the field theirs.

`isTextEdited` is the whole difference between helping and overwriting: once
someone has typed in there the name is theirs, and changing the scope radio
must not take it away. `InputText:setText` repaints itself -- `initTextBox`
ends in `UIManager:setDirty` on its parent, which is this dialog -- so nothing
else is needed here.
]]
function Dialog.proposeStem(dialog, stem)
    if type(stem) ~= "string" or stem == "" then return false end
    local field = dialog and dialog.input_fields and dialog.input_fields[1]
    if type(field) ~= "table" or type(field.setText) ~= "function" then
        return false
    end
    if type(field.isTextEdited) == "function" and field:isTextEdited() then
        return false
    end
    field:setText(stem)
    return true
end

--- What to tell the reader once it is over.
function Dialog.outcome(result)
    if not result then return Dialog.reason(nil) end
    if result.status == "done" then
        if result.count == 1 then
            return T(_("Exported to:\n%1"), result.written[1])
        end
        return T(N_("Exported %1 file.", "Exported %1 files.", result.count),
            result.count)
    end
    if result.status == "cancelled" then
        if result.count == 0 then return _("Export cancelled. Nothing was written.") end
        return T(N_("Export cancelled. %1 file was already written.",
            "Export cancelled. %1 files were already written.", result.count),
            result.count)
    end
    return Dialog.reason(result.error)
end

-- ---------------------------------------------------------------- the run

--[[--
Run one export, with the progress modal and the collision question around it.

`build(scope)` is the caller's: it answers the items, the renderer and the
flush for whichever surface this is. It runs *before* the job starts, so a
notebook that cannot be enumerated or a sheet index that is still building
stops here with a sentence rather than halfway through a file.
]]
function Dialog.run(opts)
    local built, build_err = opts.build(opts.scope)
    if not built then
        opts.notify(Dialog.reason(build_err))
        return nil, build_err
    end

    local zlib_ok, zlib = pcall(require, "ffi/zlib")
    local progress
    local function closeProgress()
        if progress then
            opts.close_modal(progress)
            progress = nil
        end
    end

    --- Give up before a job existed: take down the progress modal, release
    --- anything the source opened, and say why when there is something to say.
    local function abandon(reason)
        closeProgress()
        if built.finish then pcall(built.finish, nil) end
        if reason then opts.notify(Dialog.reason(reason)) end
    end

    local function start(overwrite)
        local job, err, existing = Export.start{
            on_cancel = built.cancel,
            format = opts.format,
            dir = opts.dir,
            stem = opts.stem,
            title = built.title or opts.stem,
            items = built.items,
            render = built.render,
            flush = built.flush,
            overwrite = overwrite,
            quality = opts.quality,
            -- Injectable so the whole run is testable without a disk; nil in
            -- production, where `ink_export` uses the real ones.
            fs = opts.fs,
            sanitize = opts.sanitize,
            token = opts.token,
            schedule = opts.schedule or function(fn) UIManager:nextTick(fn) end,
            compress = zlib_ok and zlib.zlib_compress or nil,
            on_done = function(result)
                closeProgress()
                if built.finish then pcall(built.finish, result) end
                opts.notify(Dialog.outcome(result))
                if opts.on_finished then opts.on_finished(result) end
            end,
        }
        -- Recorded here rather than at the outer call site, so the retry
        -- after "Replace" is tracked too. Missing that left the progress
        -- modal's Cancel button reading a nil job -- inert for exactly the
        -- case a reader hits most often, re-exporting the same notebook.
        if job then
            if opts.active_job then opts.active_job.job = job end
            return job
        end

        if err == "file_exists" then
            local count = existing and #existing or 0
            local box
            box = ConfirmBox:new{
                text = T(N_("%1 file in that folder has the same name and will be replaced.",
                    "%1 files in that folder have the same name and will be replaced.",
                    count), count),
                ok_text = _("Replace"),
                ok_callback = function() start(true) end,
                -- A ConfirmBox closes *itself* on either button, so this must
                -- not close it again (ADR-28); it exists only to take down the
                -- progress modal the caller put up in anticipation.
                cancel_callback = function() abandon() end,
            }
            if not opts.show_modal(box) then abandon("contact_active") end
            return nil, err
        end

        abandon(err)
        return nil, err
    end

    local function proceed()
        local total = #built.items
        if total > 1 then
            progress = ButtonDialog:new{
                title = T(N_("Exporting %1 page…", "Exporting %1 pages…", total), total),
                title_align = "center",
                -- ButtonDialog dismisses itself on a tap outside by default.
                -- Here the button is the only way to stop a long export, so a
                -- stray tap must not take it away.
                dismissable = false,
                buttons = {{{ text = _("Cancel"), callback = function()
                    if opts.active_job and opts.active_job.job then
                        opts.active_job.job:cancel()
                    else
                        closeProgress()
                    end
                end }}},
            }
            if not opts.show_modal(progress) then progress = nil end
        end
        return start(opts.overwrite)
    end

    --[[--
    The question about room on the card, asked before anything is read.

    It goes in front of the progress modal, because two stacked modals leave
    the reader unable to tell which buttons belong to which; and in front of
    `start`, because a name collision has its own question and chaining two is
    already enough.

    It is a question and never a refusal. The estimate is an estimate, `df` can
    be wrong about an unusual mount, and being locked out of an export that
    would in fact have fitted is a worse failure than being asked.
    ]]
    local function askSpace()
        local available = Export.availableSpace(opts.dir, opts.disk)
        local needed
        if built.pixels then
            needed = Export.forecast{
                format = opts.format, pixels = built.pixels,
                files = (opts.format == "pdf") and 1 or #built.items,
            }
        end
        local tight = available ~= nil
            and ((needed ~= nil and available < needed) or available < Export.LOW_WATER)
        if not tight then return proceed() end

        local friendly = require("util").getFriendlySize
        local box = ConfirmBox:new{
            text = needed
                and T(_("This export may need about %1, and only %2 is free in that folder.\n\nExport anyway?"),
                    friendly(needed), friendly(available))
                or T(_("Only %1 is free in that folder.\n\nExport anyway?"),
                    friendly(available)),
            ok_text = _("Export"),
            -- The ConfirmBox closes itself (ADR-28); this only releases what
            -- the source opened, since no job exists yet to release it.
            ok_callback = function() proceed() end,
            cancel_callback = function() abandon() end,
        }
        if not opts.show_modal(box) then abandon("contact_active") end
        -- Not a failure: the run continues from the reader's answer. Callers
        -- use the return only to record the job, and there is no job yet.
        return nil, "space_question"
    end

    --[[--
    What the surface wants said before the export reads anything.

    Only `build` knows that a run will come out incomplete -- ink it cannot
    reach, a page it cannot place -- and a reader who finds that out from the
    file afterwards has been given a worse answer than one who was asked. So
    the warning is the surface's own sentence, shown here rather than composed
    here.

    It is asked *before* the space question and never beside it: the space
    box is only built from inside this one's `ok_callback`, so the two are
    never on the stack together. Declining costs nothing -- nothing has been
    read, no job exists, and there is no file to take back -- so it says
    nothing either, beyond releasing what the source opened.
    ]]
    local warning = built.confirm_warning
    if type(warning) ~= "string" or warning == "" then return askSpace() end
    local box = ConfirmBox:new{
        text = warning,
        ok_text = _("Export"),
        -- The ConfirmBox closes itself (ADR-28): neither answer may close it
        -- again, and neither one needs to.
        ok_callback = function() askSpace() end,
        cancel_callback = function() abandon() end,
    }
    if not opts.show_modal(box) then abandon("contact_active") end
    -- A question, not a failure, exactly as for the space question above.
    return nil, "confirm_warning"
end

-- ------------------------------------------------------------- the widget

--[[--
  opts.title        what is being exported, for the dialog's heading
  opts.stem         proposed file name; a string, or function(scope) -> string
  opts.scopes       { { value, label } } -- omitted or single means no choice
  opts.build        function(scope) -> { items, render, flush, title, finish,
                                        confirm_warning }
  opts.settings     where the format and folder are remembered
  opts.show_modal / opts.close_modal / opts.notify   host seams
]]
function Dialog.show(opts)
    local settings = opts.settings or _G.G_reader_settings
    local state = {
        format = Dialog.rememberedFormat(settings),
        -- The injected filesystem, when there is one: the folder this resolves
        -- to is the folder the sweep below reads and the job writes into, and
        -- three different answers to "where" would be three different bugs.
        dir = Dialog.rememberedDirectory(settings, opts.fs),
        scope = opts.scopes and opts.scopes[1] and opts.scopes[1].value or nil,
    }
    local active_job = {}
    local dialog

    local function folderLine()
        return T(_("Folder: %1"), state.dir)
    end

    local function chooseFolder()
        local filemanagerutil = require("apps/filemanager/filemanagerutil")
        filemanagerutil.showChooseDialog(_("Export folder:"), function(path)
            local lfs = require("libs/libkoreader-lfs")
            if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "directory" then
                opts.notify(Dialog.reason("bad_directory"))
                return
            end
            -- Persisted only now: a folder that could not be confirmed must
            -- not become the one the next export defaults to.
            state.dir = path
            Compat.saveSetting(settings, Dialog.SETTING_DIR, path)
            -- InputDialog has no `setTitle` (ButtonDialog does, which is
            -- where that assumption came from). The title lives on its
            -- TitleBar, and without this the dialog goes on showing the old
            -- folder while the export writes to the new one.
            if dialog and dialog.title_bar then
                dialog.title_bar:setTitle(opts.title .. "\n" .. folderLine())
                UIManager:setDirty(dialog, "ui")
            end
        end, state.dir, Dialog.defaultDirectory())
    end

    local function runExport()
        local fields = dialog:getFields()
        local stem = fields and fields[1] or stemFor(opts, state.scope)
        opts.close_modal(dialog)
        Compat.saveSetting(settings, Dialog.SETTING_FORMAT, state.format)
        Dialog.run{
            build = opts.build,
            scope = state.scope,
            format = state.format,
            dir = state.dir,
            stem = stem,
            notify = opts.notify,
            show_modal = opts.show_modal,
            close_modal = opts.close_modal,
            schedule = opts.schedule,
            fs = opts.fs,
            sanitize = opts.sanitize,
            disk = opts.disk,
            active_job = active_job,
            on_finished = opts.on_finished,
        }
    end

    --[[--
    What an interrupted export left here, and the offer to be rid of it.

    Swept when the dialog opens rather than at startup, because that is the
    only moment the folder is known -- an export goes wherever the reader last
    chose, and only this dialog knows which one that is -- and the only moment
    the reader can do anything about the answer. It costs one bounded directory
    walk, and only for someone who is already exporting.

    Its own button row: the row below already carries three, and a fourth does
    not fit on a narrow screen. The row exists only when there is something in
    it, so nothing changes for a clean folder. It is deliberately not
    recomputed when the reader picks a different folder with "Folder…" -- the
    sweep of a new folder arrives with the next dialog, which is cheaper than
    rebuilding a live button table for a housekeeping offer.
    ]]
    local orphans = Export.orphans(state.dir, { fs = opts.fs, now = opts.now })
    local button_rows = {}
    if orphans and #orphans > 0 then
        local total = 0
        for i = 1, #orphans do total = total + orphans[i].size end
        button_rows[#button_rows + 1] = {{
            text = T(N_("Clean up %1 leftover file", "Clean up %1 leftover files",
                #orphans), #orphans),
            callback = function()
                local friendly = require("util").getFriendlySize
                local box = ConfirmBox:new{
                    text = T(N_("Delete %1 leftover file from an interrupted export? This frees %2.",
                        "Delete %1 leftover files from an interrupted export? This frees %2.",
                        #orphans), #orphans, friendly(total)),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local removed, freed, failed =
                            Export.removeOrphans(orphans, { fs = opts.fs })
                        if not removed or (failed and failed > 0) then
                            opts.notify(Dialog.reason("sweep_failed"))
                        else
                            opts.notify(T(N_("Removed %1 leftover file, freeing %2.",
                                "Removed %1 leftover files, freeing %2.", removed),
                                removed, friendly(freed)))
                        end
                    end,
                }
                opts.show_modal(box)
            end,
        }}
    end
    button_rows[#button_rows + 1] = {
        { text = _("Folder…"), callback = chooseFolder },
        { text = _("Cancel"), id = "close",
            callback = function() opts.close_modal(dialog) end },
        { text = _("Export"), callback = runExport },
    }

    dialog = MultiInputDialog:new{
        title = opts.title .. "\n" .. folderLine(),
        fields = {{ description = _("File name"),
            text = stemFor(opts, state.scope) }},
        buttons = button_rows,
    }

    -- The dialog's own content width, not a fraction of the screen. An
    -- InputDialog sizes itself off the *shorter* screen edge, so in landscape
    -- a screen-derived width is wider than the frame and the CenterContainer
    -- paints the radio row outside the dialog on both sides.
    local width = dialog.getAddedWidgetAvailableWidth
        and dialog:getAddedWidgetAvailableWidth()
        or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.72)
    local format_buttons = {}
    for i = 1, #Dialog.FORMATS do
        local entry = Dialog.FORMATS[i]
        format_buttons[i] = { text = entry.label, value = entry.value,
            checked = entry.value == state.format or nil }
    end
    dialog:addWidget(RadioButtonTable:new{
        width = width, parent = dialog, show_parent = dialog,
        radio_buttons = {
            {{ text = _("File type"), enabled = false, checkable = false }},
            format_buttons,
        },
        button_select_callback = function(entry) state.format = entry.value end,
    })

    if opts.scopes and #opts.scopes > 1 then
        local scope_buttons = {}
        for i = 1, #opts.scopes do
            local entry = opts.scopes[i]
            scope_buttons[i] = { text = entry.label, value = entry.value,
                checked = i == 1 or nil }
        end
        -- Its own table, so it is its own radio group (RadioButtonTable keeps
        -- one checked button per widget, however many rows it holds).
        dialog:addWidget(RadioButtonTable:new{
            width = width, parent = dialog, show_parent = dialog,
            radio_buttons = {
                {{ text = _("What to export"), enabled = false, checkable = false }},
                scope_buttons,
            },
            button_select_callback = function(entry)
                state.scope = entry.value
                Dialog.proposeStem(dialog, stemFor(opts, entry.value))
            end,
        })
    end

    -- The host seams refuse: the editor's returns nil while the pen is down.
    -- Showing the keyboard anyway would put a VirtualKeyboard on the window
    -- stack with no dialog behind it and nothing that dismisses it.
    if not opts.show_modal(dialog) then
        if dialog.onCloseWidget then pcall(dialog.onCloseWidget, dialog) end
        opts.notify(Dialog.reason("contact_active"))
        return nil, "contact_active"
    end
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    logger.dbg("JustDraw export: dialog opened for", opts.title)
    return dialog, state
end

return Dialog
