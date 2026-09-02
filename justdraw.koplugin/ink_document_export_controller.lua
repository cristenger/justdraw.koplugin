--[[--
Everything the reader's "Export…" has to decide before a byte is written.

Six decisions live here -- which scopes this book offers, whether the menu
entry is live at all, which page a file name may claim, what that name is,
what one run will read, and the dialog that asks the rest. Every one of them
reaches across surfaces that do not share a lifetime: the direct-ink store is
built in `init`, the sheet session appears in `onReaderReady` and is gone again
at `teardown`, and the input lease exists only while drawing is on. Written as
methods on the plugin they read those fields straight off `self`, which is why
the export section was the part of `main.lua` that grew every time a surface
was added.

So the state arrives as accessors, not as values. Nothing here holds a session,
a store or a lease between calls: all three change identity during a document's
life, and a controller that had cached one would happily export from a surface
that has since been closed. The host seams -- `show_modal`, `close_modal`,
`notify`, `schedule` -- are injected for the same reason the dialog takes them:
closing a modal is idempotent only if the owner is tracking it (ADR-28), and
the owner is the plugin. Injecting all of it is also what lets a test build one
of these with no `main.lua` behind it.

Nothing here writes, and nothing here touches a file. It does read: the page
scope reads the sidecar's strokes for the page being exported, and the dossier
reads the rows -- never the strokes -- that say what a book's notes are. That
is the whole of it. `build` assembles a description of the work and hands it to
`ink_export_dialog`; an export is a read (ADR-30), and every reason it cannot
run -- an unsupported document, a sheet index still building, a pen still on
the panel -- is found before the reader has been shown a progress dialog.
]]

local DocumentSource = require("ink_document_export_source")
local DocumentTransform = require("ink_document_transform")
local ExportDialog = require("ink_export_dialog")
local ExportHeader = require("ink_export_header")
local ExportRaster = require("ink_export_raster")
local ExportReader = require("ink_export_reader")
local ExportSource = require("ink_export_source")

local _ = require("gettext")

local Controller = {}
Controller.__index = Controller

--[[--
  opts.ui / opts.view    the reader, for the renderer and the document's name
  opts.docless           true in the file manager, where there is no book
  opts.session           function() -> InkCanvasSession or nil
  opts.document_session  function() -> InkDocumentInkSession or nil
  opts.legacy            function() -> the frozen sidecar view or nil
  opts.lease             function() -> the input lease or nil
  opts.canvas_open       function() -> boolean
  opts.current_page      function() -> the page being read
  opts.screen            function() -> w, h
  opts.ink               the colour direct ink is rendered in
  opts.settings          function() -> where format and folder are remembered
  opts.show_modal / opts.close_modal / opts.notify / opts.schedule  host seams
]]
function Controller.new(opts)
    return setmetatable({
        ui = opts.ui,
        view = opts.view,
        docless = opts.docless or false,
        session = opts.session,
        document_session = opts.document_session,
        legacy = opts.legacy,
        lease = opts.lease,
        canvas_open = opts.canvas_open,
        current_page = opts.current_page,
        screen = opts.screen,
        ink = opts.ink,
        settings = opts.settings,
        show_modal = opts.show_modal,
        close_modal = opts.close_modal,
        notify = opts.notify,
        schedule = opts.schedule,
    }, Controller)
end

--[[--
What this reader could export right now, in the order the dialog offers them.

Each entry is a claim that the work is actually possible: the page scope is
gated on the renderer accepting this document and view mode, and the whole-book
scope on the anchor index having finished, because without it the sheets have
no reading order (ADR-15).
]]
function Controller:scopes()
    local scopes = {}
    if self.docless then return scopes end
    if ExportReader.supports(self.ui, self.view) then
        scopes[#scopes + 1] = { value = "page", label = _("This page") }
    end
    local session = self.session()
    if self.canvas_open() and session and session:activeCanvas() then
        scopes[#scopes + 1] = { value = "sheet", label = _("This sheet") }
    end
    if session and session:isAvailable() then
        local repository, index = session:exportSources()
        if repository and index and index:isComplete() then
            local canvases = session:allCanvases()
            if canvases and #canvases > 0 then
                scopes[#scopes + 1] = {
                    value = "sheets", label = _("All drawing sheets") }
            end
        end
    end
    local notes = self:notesScope()
    if notes then scopes[#scopes + 1] = notes end
    return scopes
end

--[[--
Whether this book has any notes at all, and whether they can be gathered yet.

Cheap on purpose: counts and one `next` over a table, never an enumeration.
`scopes` runs whenever the dialog is opened and the answer decides whether a
radio button is drawn, which is not the moment to walk a keyset cursor -- the
walk happens in `build`, once, when the reader has actually chosen this.

A reflowable book's entry is offered and *disabled* while the anchor index is
still building, rather than withheld: the reader whose book plainly has notes
in it is owed "not yet" (ADR-42) rather than a missing option.
]]
function Controller:notesScope()
    local legacy = self.legacy and self.legacy()
    local has_legacy = legacy ~= nil and not legacy:isEmpty()
    local session = self.session()
    if session and session:isAvailable() then
        local _repository, index = session:exportSources()
        local sheets = (index and index:count()) or 0
        if sheets == 0 and not has_legacy then return nil end
        if not index or not index:isComplete() then
            return { value = "notes", label = _("Document notes"),
                enabled = false, reason = "index_incomplete" }
        end
        return { value = "notes", label = _("Document notes") }
    end
    local document = self.document_session and self.document_session()
    local notes = 0
    if document and document:isAvailable() then
        notes = document:countSurfaces()
    end
    if notes == 0 and not has_legacy then return nil end
    return { value = "notes", label = _("Document notes") }
end

--[[--
Whether the menu entry is live. Deliberately cheap.

`enabled_func` runs while every menu item is built, on every tap and on every
hold, so this asks the anchor index -- which already holds every canvas row --
rather than the repository. `scopes` does the full work once, when the entry is
actually chosen.
]]
function Controller:canExport()
    if self.docless then return false end
    if ExportReader.supports(self.ui, self.view) then return true end
    -- The sidecar is a note like any other now (ADR-40), and asking it is one
    -- `next` over a table. Without this the dossier would be unreachable in
    -- the one case that has nothing else in it: an older book whose only ink
    -- is the frozen sidecar's.
    local legacy = self.legacy and self.legacy()
    if legacy and not legacy:isEmpty() then return true end
    local session = self.session()
    if not session or not session:isAvailable() then return false end
    if self.canvas_open() and session:activeCanvas() then return true end
    local _repository, index = session:exportSources()
    return index ~= nil and index:isComplete() and index:count() > 0
end

--[[--
The page an exported file's name should carry, or nil.

Nil for "all sheets in this book", because one page number in the name of a
file that holds twenty would be a lie; and nil for a sheet the anchor index has
not placed, because inventing a page for an orphan is worse than leaving it
out. Only a scope that is exactly one page of the book gets one.
]]
function Controller:scopePage(scope)
    if scope == "page" then return self.current_page() end
    if scope ~= "sheet" then return nil end
    local session = self.session()
    local canvas = session and session:activeCanvas()
    if not canvas then return nil end
    local _repository, index = session:exportSources()
    if type(index) ~= "table" or type(index.pageOf) ~= "function" then
        return nil
    end
    return index:pageOf(canvas.id)
end

--[[--
A file name that says which book it came from, which page, and when.

The stamp is passed in rather than read here so that every scope of one dialog
shares it: recomputing it per scope would make tapping a radio button move the
time, which is not what the reader asked for. It stays inside what a VFAT
volume will hold once the suffix and extension are added.
]]
function Controller:bookName()
    local file = self.ui and self.ui.document and self.ui.document.file
    if type(file) ~= "string" then return "JustDraw" end
    local name = file:match("([^/]+)$")
    if not name then return "JustDraw" end
    return name:match("^(.+)%.[^.]*$") or name
end

function Controller:stem(scope, stamp)
    local base = self:bookName()
    -- A dossier is not a page and not a sheet; it says what it is instead,
    -- because "Moby Dick 2026-09-01" beside "Moby Dick p12 2026-09-01" reads
    -- like a second copy of the page rather than the whole book's notes.
    if scope == "notes" then base = base .. " " .. _("Notes") end
    local page = self:scopePage(scope)
    if page then base = base .. " p" .. tostring(page) end
    return base .. " " .. (stamp or os.date("%Y-%m-%d-%H%M%S"))
end

--[[--
The sentence a dossier owes the reader before it reads anything.

Legacy ink is screen pixels of a screen whose size, zoom and rotation were
never stored (ADR-39), so where it lands on an exported page is the current
screen's answer to a question the ink cannot answer. That is worth a question
rather than a surprise, and it is asked once, in front of the space question
and never beside it (ADR-40).
]]
Controller.LEGACY_WARNING = _("This export includes legacy ink whose original zoom, rotation and screen geometry were not stored. Its layout cannot be guaranteed.")

--- Make every surface that could still be holding a write durable, so the
--- export can read the database instead of the session. A surface that is not
--- there has nothing to flush and is not a failure.
function Controller:flushSurfaces()
    local session = self.session()
    if session and session:isAvailable() then
        local ok, err = session:flush()
        if not ok then return nil, err or "flush_failed" end
    end
    local document = self.document_session and self.document_session()
    if document and document:isAvailable() then
        local ok, err = document:flush()
        if not ok then return nil, err or "flush_failed" end
    end
    return true
end

--- The screen the legacy ink was measured against -- this one, because the
--- one it was drawn on was never recorded.
function Controller:screenSize()
    if type(self.screen) ~= "function" then return nil end
    local w, h = self.screen()
    if not tonumber(w) or not tonumber(h) then return nil end
    return { w = tonumber(w), h = tonumber(h) }
end

--[[--
Everything `documentNotes` needs to enumerate this book, or a refusal.

The two halves of a book's notes are keyed differently and the reader is on
one side or the other, never both: a reflowable book has sheets and an anchor
index, a fixed layout has page-ink rows and a book id. Legacy ink is on both.
]]
function Controller:notesSource()
    local spec = {
        legacy = self.legacy and self.legacy(),
        screen = self:screenSize(),
    }
    if self.ui and self.ui.rolling then
        spec.rolling = true
        local session = self.session()
        if not session or not session:isAvailable() then
            -- No sheet session: an unidentified book, or a runtime without
            -- the new surfaces. Whatever it has is in the sidecar.
            spec.canvases = {}
            return spec
        end
        local repository, index = session:exportSources()
        if not repository then return nil, index or "unavailable" end
        if not index or not index:isComplete() then
            return nil, "index_incomplete"
        end
        local canvases, list_err = session:allCanvases()
        if not canvases then return nil, list_err or "list_failed" end
        spec.repository, spec.index, spec.canvases = repository, index, canvases
        return spec
    end
    local document = self.document_session and self.document_session()
    if document and document:isAvailable() then
        local repository, book_id = document:exportSources()
        if not repository then return nil, book_id or "unavailable" end
        -- Without a book row there is nothing to walk: every page-ink row is
        -- keyed on one, and a book that could not be registered -- a read-only
        -- database a newer plugin has not written yet -- has none. Its notes
        -- are whatever is in the sidecar.
        if book_id then
            spec.repository, spec.book_id = repository, book_id
            -- The rule `DocumentTransform.surfaceSpec` applies, without asking
            -- the document to measure a page nothing is going to draw: only
            -- MuPDF measures in points (ADR-38).
            local document_obj = self.ui and self.ui.document
            local provider = document_obj and document_obj.provider
            spec.units = provider == "mupdf" and "pt" or "px"
        end
    end
    return spec
end

--[[--
The page-ink layer of the page being exported, composed onto the reader's own
raster -- or the page unchanged, when it has none.

Composed and not copied: the layer is BB8A and mostly transparent, so a
`blitFrom` would land every untouched pixel as black and put a rectangle over
the book's text (ADR-38). The rectangle is the transform's own -- the same one
the screen is painted from -- shifted by the view's origin, exactly as the
reader's strokes are.

A page that *has* notes and a view that cannot place them is a refusal, not a
quiet omission: a file that silently left the reader's notes out is worse than
one that was not written.
]]
function Controller:composePageInk(page, result, tracker, done)
    local document = self.document_session and self.document_session()
    if not document or not document:isAvailable() then return done(result) end
    local repository, book_id = document:exportSources()
    if not repository or not book_id
        or type(repository.findPageInkSurface) ~= "function" then
        return done(result)
    end
    local surface, find_err = repository:findPageInkSurface(book_id, page)
    if not surface then
        -- A page with no notes is the ordinary case and exports exactly as it
        -- did before. A store that could not answer is not the same thing:
        -- exporting the page as though it had none would be the silent
        -- omission this whole branch exists to avoid.
        if find_err and find_err ~= "not_found" then
            if type(result.release) == "function" then pcall(result.release) end
            return done(nil, find_err)
        end
        return done(result)
    end

    local function fail(reason)
        if type(result.release) == "function" then pcall(result.release) end
        return done(nil, reason)
    end

    local transform, reason = DocumentTransform.fromView(self.ui, self.view,
        surface, { screen = self:screenSize() })
    if not transform then return fail(reason or "bad_geometry") end
    local rect = transform:canvasRect()
    if rect.w < 1 or rect.h < 1 then return done(result) end

    local origin_x = tonumber(self.view.dimen.x) or 0
    local origin_y = tonumber(self.view.dimen.y) or 0
    local delivered = false
    local job, err = ExportRaster.open{
        repository = repository,
        surface = surface,
        scale = tonumber(self.view.state.zoom),
        schedule = self.schedule,
        -- The composition is the whole of it: the cache allocates BB8A for an
        -- overlay and BB8 otherwise, so there is no buffer type to state
        -- separately -- and stating one would be a second place to get it
        -- wrong.
        composition = "overlay",
        on_ready = function(raster)
            if delivered then return raster:close() end
            delivered = true
            local layer = raster:buffer()
            if layer then
                result.bb:alphablitFrom(layer, rect.x - origin_x,
                    rect.y - origin_y, rect.cache_x or 0, rect.cache_y or 0,
                    rect.w, rect.h)
            end
            raster:close()
            done(result)
        end,
        on_error = function(raster_err, raster)
            if raster then raster:close() end
            if delivered then return end
            delivered = true
            fail(raster_err)
        end,
    }
    if not job then return fail(err or "raster_failed") end
    tracker.job = job
end

--[[--
Assemble one export: what to render, how, and what has to be durable first.

The point of doing it up front is that every reason an export cannot run -- an
unsupported document, a sheet index still building, a pen still on the panel --
is found before the reader has been shown a progress dialog or a single byte
has been written.
]]
function Controller:build(scope)
    local lease = self.lease()
    if lease and lease:hasActiveContact() then return nil, "contact_active" end

    if scope == "page" then
        local supported, reason = ExportReader.supports(self.ui, self.view)
        if not supported then return nil, reason end
        local page = self.current_page()
        -- Read once, here: the sidecar must not be walked again while the job
        -- runs, and the ink of the page being exported is what was on screen
        -- when the reader asked.
        local legacy = self.legacy and self.legacy()
        local strokes = legacy and legacy:strokes(page) or {}
        local tracker = {}
        return {
            items = { { page = page } },
            -- The same product `ExportReader.supports` measured against the
            -- pixel budget: the page is rasterised at its own screen size.
            pixels = math.floor(self.view.dimen.w) * math.floor(self.view.dimen.h),
            -- No `title`: `ExportDialog.run` falls back to the name the reader
            -- actually chose, which is a better `/Title` than a stem
            -- regenerated here -- and one that cannot disagree with the file
            -- name by a few seconds of clock.
            --
            -- The page's own notes are read out of the database, so they have
            -- to be durable first -- and the raster that reads them is closed
            -- however the run ends.
            flush = function() return self:flushSurfaces() end,
            render = function(item, index, done)
                local result, render_err = ExportReader.render{
                    ui = self.ui, view = self.view,
                    strokes = strokes, ink = self.ink,
                }
                if not result then return done(nil, render_err) end
                return self:composePageInk(page, result, tracker, done)
            end,
            finish = function()
                if tracker.job then tracker.job:close() end
            end,
            cancel = function()
                if tracker.job then tracker.job:close() end
            end,
        }
    end

    if scope == "notes" then
        local spec, spec_err = self:notesSource()
        if not spec then return nil, spec_err end
        local items, items_err = DocumentSource.documentNotes(spec)
        if not items then return nil, items_err end
        local tracker = {}
        return {
            items = items,
            pixels = DocumentSource.totalPixels(items),
            flush = function() return self:flushSurfaces() end,
            render = DocumentSource.renderer{
                schedule = self.schedule,
                legacy = spec.legacy,
                ink = self.ink,
                track = function(job) tracker.job = job end,
                header = {
                    -- The book, not the file name: the name is the reader's
                    -- and carries a timestamp, and a timestamp on every page
                    -- of forty says nothing about which page this is.
                    title = self:bookName(),
                    paint_text = ExportHeader.textPainter(),
                },
            },
            finish = function()
                if tracker.job then tracker.job:close() end
            end,
            cancel = function()
                if tracker.job then tracker.job:close() end
            end,
            confirm_warning = DocumentSource.includesLegacy(items)
                and Controller.LEGACY_WARNING or nil,
        }
    end

    local session = self.session()
    if not session or not session:isAvailable() then return nil, "unavailable" end
    local repository, index = session:exportSources()
    if not repository then return nil, index or "unavailable" end

    local items
    if scope == "sheet" then
        local canvas = session:activeCanvas()
        if not canvas then return nil, "no_items" end
        items = { canvas }
    else
        local canvases, list_err = session:allCanvases()
        if not canvases then return nil, list_err or "list_failed" end
        local ordered, order_err = ExportSource.orderedCanvases(canvases, index)
        if not ordered then return nil, order_err end
        items = ordered
    end

    local tracker = {}
    return {
        items = items,
        pixels = ExportSource.totalPixels(items, ExportSource.canvasGeometry),
        -- No `title` here either; see the page scope above.
        -- The ink has to be durable before it is read back out of the
        -- database; the queue may still be holding the last stroke.
        flush = function() return session:flush() end,
        render = ExportSource.surfaceRenderer{
            repository = repository,
            schedule = self.schedule,
            geometry = ExportSource.canvasGeometry,
            track = function(job) tracker.job = job end,
        },
        finish = function()
            if tracker.job then tracker.job:close() end
        end,
        -- Closing the raster in flight is what makes Cancel land between
        -- batches instead of after the page being replayed finishes.
        cancel = function()
            if tracker.job then tracker.job:close() end
        end,
    }
end

function Controller:showDialog()
    local scopes = self:scopes()
    if #scopes == 0 then
        local _supported, reason = ExportReader.supports(self.ui, self.view)
        self.notify(ExportDialog.reason(reason or "no_items"))
        return nil, reason
    end
    -- One stamp for the whole dialog. Reading the clock per scope would make
    -- tapping a radio button move the time in the proposed name.
    local stamp = os.date("%Y-%m-%d-%H%M%S")
    return ExportDialog.show{
        title = _("Export"),
        stem = function(scope) return self:stem(scope, stamp) end,
        scopes = scopes,
        build = function(scope) return self:build(scope) end,
        settings = self.settings(),
        show_modal = function(widget) return self.show_modal(widget) end,
        close_modal = function(widget) return self.close_modal(widget) end,
        notify = function(text) self.notify(text) end,
    }
end

return Controller
