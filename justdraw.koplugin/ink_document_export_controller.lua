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

Nothing here reads a stroke or touches a file. `build` assembles a description
of the work and hands it to `ink_export_dialog`; an export is a read, and every
reason it cannot run -- an unsupported document, a sheet index still building,
a pen still on the panel -- is found before the reader has been shown a
progress dialog (ADR-30).
]]

local ExportDialog = require("ink_export_dialog")
local ExportReader = require("ink_export_reader")
local ExportSource = require("ink_export_source")

local _ = require("gettext")

local Controller = {}
Controller.__index = Controller

--[[--
  opts.ui / opts.view    the reader, for the renderer and the document's name
  opts.docless           true in the file manager, where there is no book
  opts.session           function() -> InkCanvasSession or nil
  opts.store             function() -> the direct-ink store or nil
  opts.lease             function() -> the input lease or nil
  opts.canvas_open       function() -> boolean
  opts.current_page      function() -> the page being read
  opts.ink               the colour direct ink is rendered in
  opts.settings          where the dialog remembers format and folder
  opts.show_modal / opts.close_modal / opts.notify / opts.schedule  host seams
]]
function Controller.new(opts)
    return setmetatable({
        ui = opts.ui,
        view = opts.view,
        docless = opts.docless or false,
        session = opts.session,
        store = opts.store,
        lease = opts.lease,
        canvas_open = opts.canvas_open,
        current_page = opts.current_page,
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
                    value = "sheets", label = _("All sheets in this book") }
            end
        end
    end
    return scopes
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
function Controller:stem(scope, stamp)
    local base = "JustDraw"
    local file = self.ui and self.ui.document and self.ui.document.file
    if type(file) == "string" then
        local name = file:match("([^/]+)$")
        if name then base = name:match("^(.+)%.[^.]*$") or name end
    end
    local page = self:scopePage(scope)
    if page then base = base .. " p" .. tostring(page) end
    return base .. " " .. (stamp or os.date("%Y-%m-%d-%H%M%S"))
end

--[[--
Assemble one export: what to render, how, and what has to be durable first.

Nothing here reads a stroke. The point of doing it up front is that every
reason an export cannot run -- an unsupported document, a sheet index still
building, a pen still on the panel -- is found before the reader has been shown
a progress dialog or a single byte has been written.
]]
function Controller:build(scope)
    local lease = self.lease()
    if lease and lease:hasActiveContact() then return nil, "contact_active" end

    if scope == "page" then
        local supported, reason = ExportReader.supports(self.ui, self.view)
        if not supported then return nil, reason end
        local page = self.current_page()
        -- Read once, here: the store must not be walked again while the job
        -- runs, and the ink of the page being exported is what was on screen
        -- when the reader asked.
        local store = self.store()
        local strokes = store and store:get(page) or {}
        return {
            items = { { page = page } },
            -- The same product `ExportReader.supports` measured against the
            -- pixel budget: the page is rasterised at its own screen size.
            pixels = math.floor(self.view.dimen.w) * math.floor(self.view.dimen.h),
            -- No `title`: `ExportDialog.run` falls back to the name the reader
            -- actually chose, which is a better `/Title` than a stem
            -- regenerated here -- and one that cannot disagree with the file
            -- name by a few seconds of clock.
            render = function(item, index, done)
                local result, render_err = ExportReader.render{
                    ui = self.ui, view = self.view,
                    strokes = strokes, ink = self.ink,
                }
                done(result, render_err)
            end,
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
        settings = self.settings,
        show_modal = function(widget) return self.show_modal(widget) end,
        close_modal = function(widget) return self.close_modal(widget) end,
        notify = function(text) self.notify(text) end,
    }
end

return Controller
