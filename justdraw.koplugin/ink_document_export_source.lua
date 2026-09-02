--[[--
Every note in one book, as one ordered list, before anything is read.

A book can carry notes on three surfaces that share nothing: drawing sheets
hang off an xpointer in a reflowable book, page ink belongs to a fixed page in
its own units, and the frozen sidecar holds screen pixels of a screen nobody
recorded (ADR-39). They live in two different stores, they are keyed three
different ways, and only one of them can say where it belongs without being
asked. The reader does not care about any of that: what leaves the device is
"my notes on this book", in the order they would be met while reading.

So this module does the one thing that cannot be done anywhere else -- decide
what the list *is* -- and hands the rest to the pipeline the notebooks already
proved. Every entry is a descriptor, and the descriptor is the contract: the
ordering reads it, the header reads it, the geometry dispatches on it and the
renderer switches on it. Nothing downstream has to know which store a page
came out of.

Three rules are load-bearing, and each one is silent when it breaks.

**Legacy first within a page.** Sidecar ink predates every other surface on
that page, and a dossier that put it after the page's own notes would read as
though the reader had drawn it last. It is also the entry whose position on
the paper is a guess, so meeting it first is meeting the caveat first.

**Orphans after everything.** A sheet whose anchor no longer resolves has no
page, and inventing one for it is worse than admitting it. It goes last, by
id, so the same book exports in the same order twice running.

**The page-ink cursor is walked to the end.** `listPageInkSurfaces` is
keyset-paginated and bounded; treating the first batch as the book is how a
long book exports its first hundred pages and reports success. The cursor is
checked for progress too, because a repository that answered the same last row
twice would otherwise spin here forever.

What this is not: a reconstruction of the book. The pages of the document
itself are not here and cannot be (ADR-40) -- a CREngine page cannot be
rendered without emitting `PageUpdate`, and an export is a read.
]]

local Blitbuffer = require("ffi/blitbuffer")

local ExportSource = require("ink_export_source")
local Raster = require("ink_export_raster")
local Render = require("ink_render")
local Style = require("ink_style")

local T = require("ffi/util").template
local _ = require("gettext")

local DocumentSource = {}

--- What each kind is called in the header band. Short, because it shares one
--- line with the book's name and the location.
function DocumentSource.kindLabel(kind)
    if kind == "page_ink" then return _("Page note") end
    if kind == "legacy_page" then return _("Legacy ink") end
    return _("Drawing sheet")
end

--[[--
Where a note sits, in words.

Three answers rather than two: a page number, a page number that is only what
the sidecar recorded, and an admission. "Stored page" is not pedantry -- the
sidecar's page number is the only thing about legacy ink that survived, and
the geometry around it did not (ADR-40).
]]
function DocumentSource.locationLabel(kind, page)
    if not page then return _("Location unavailable") end
    if kind == "legacy_page" then return T(_("Stored page %1"), page) end
    return T(_("Page %1"), page)
end

local function descriptor(spec)
    return {
        kind = spec.kind,
        page = spec.page,
        surface = spec.surface,
        repository = spec.repository,
        logical_w = spec.logical_w,
        logical_h = spec.logical_h,
        units = spec.units,
        location_label = DocumentSource.locationLabel(spec.kind, spec.page),
        legacy = spec.kind == "legacy_page",
    }
end

--- The tie-break inside one page, and the whole order among orphans. A row id
--- for a surface, the page itself for legacy ink -- which is unique, because
--- the sidecar is keyed by page.
local function idOf(item)
    if item.surface and tonumber(item.surface.id) then
        return tonumber(item.surface.id)
    end
    return tonumber(item.page) or 0
end

--[[--
The dossier's order: page, then legacy first, then id.

`table.sort` is not stable in Lua, so this has to be a total order or the
answer depends on the sort's internals. Every branch ends in a comparison that
cannot tie except for an item with itself.
]]
local function byLocation(a, b)
    if a.page and b.page then
        if a.page ~= b.page then return a.page < b.page end
        if a.legacy ~= b.legacy then return a.legacy end
        return idOf(a) < idOf(b)
    end
    if a.page then return true end      -- placed before orphaned
    if b.page then return false end
    return idOf(a) < idOf(b)
end

local function positive(v)
    return type(v) == "number" and v == v and v > 0 and v ~= math.huge
end

--[[--
Every page-ink surface of this book, in `(fixed_page, id)` order.

The pair and not the page alone: pages are unique today only because of the
anchor key, and a cursor that trusted that would skip rows the moment it
stopped being true.
]]
local function pageInkSurfaces(opts, items, max_pages)
    local repository = opts.repository
    if type(repository) ~= "table"
        or type(repository.listPageInkSurfaces) ~= "function" then
        return nil, "no_repository"
    end
    local units = opts.units == "pt" and "pt" or "px"
    local limit = opts.limit or ExportSource.PAGE_BATCH
    local after_page, after_id
    while true do
        local batch, err = repository:listPageInkSurfaces(opts.book_id, {
            limit = limit, after_page = after_page, after_id = after_id,
        })
        if not batch then return nil, err or "list_failed" end
        if #batch == 0 then break end
        for i = 1, #batch do
            local row = batch[i]
            items[#items + 1] = descriptor{
                kind = "page_ink",
                page = tonumber(row.fixed_page),
                surface = row,
                repository = repository,
                logical_w = tonumber(row.logical_w),
                logical_h = tonumber(row.logical_h),
                units = units,
            }
            if #items > max_pages then return nil, "too_many_pages" end
        end
        local last = batch[#batch]
        if after_page == tonumber(last.fixed_page)
            and after_id == tonumber(last.id) then
            return nil, "list_failed"
        end
        after_page, after_id = tonumber(last.fixed_page), tonumber(last.id)
    end
    return items
end

--- This book's sheets, in the reading order the anchor index resolved.
local function sheets(opts, items, max_pages)
    local canvases = opts.canvases
    if type(canvases) ~= "table" then return nil, "no_canvases" end
    if #canvases == 0 then return items end
    local ordered, err = ExportSource.orderedCanvases(canvases, opts.index)
    if not ordered then return nil, err end
    for i = 1, #ordered do
        local row = ordered[i]
        items[#items + 1] = descriptor{
            kind = "sheet",
            page = opts.index:pageOf(row.id),
            surface = row,
            repository = opts.repository,
            logical_w = tonumber(row.logical_w),
            logical_h = tonumber(row.logical_h),
            units = "px",
        }
        if #items > max_pages then return nil, "too_many_pages" end
    end
    return items
end

--- The frozen sidecar's pages, sized to the screen this reader is holding --
--- which is the whole of what `confirm_warning` warns about.
local function legacyPages(opts, items, max_pages)
    local legacy = opts.legacy
    if not legacy or type(legacy.pages) ~= "function" then return items end
    local pages = legacy:pages()
    if type(pages) ~= "table" or #pages == 0 then return items end
    local screen = opts.screen
    local w = type(screen) == "table" and tonumber(screen.w) or nil
    local h = type(screen) == "table" and tonumber(screen.h) or nil
    if not positive(w) or not positive(h) then return nil, "bad_geometry" end
    for i = 1, #pages do
        items[#items + 1] = descriptor{
            kind = "legacy_page",
            page = tonumber(pages[i]),
            logical_w = w,
            logical_h = h,
            units = "px",
        }
        if #items > max_pages then return nil, "too_many_pages" end
    end
    return items
end

--[[--
  opts.rolling      true for a reflowable book (sheets), else page ink
  opts.canvases     the sheet rows -- the session's `allCanvases()`
  opts.index        the anchor index, for the reading order
  opts.repository   the read side of whichever store holds the surfaces
  opts.book_id      this book, for the page-ink walk
  opts.units        "pt" | "px" -- what a page's own units are (ADR-38)
  opts.legacy       the frozen sidecar view, or nil
  opts.screen       { w, h } -- what legacy ink is rendered onto
  opts.limit        page-ink batch size
  opts.max_pages    refuse beyond this many notes

Answers the ordered descriptors, or nil and a reason the dialog can say.
]]
function DocumentSource.documentNotes(opts)
    opts = opts or {}
    local max_pages = opts.max_pages or ExportSource.MAX_PAGES
    local items = {}

    local ok, err
    if opts.rolling then
        ok, err = sheets(opts, items, max_pages)
    else
        ok, err = pageInkSurfaces(opts, items, max_pages)
    end
    if not ok then return nil, err end

    ok, err = legacyPages(opts, items, max_pages)
    if not ok then return nil, err end

    if #items == 0 then return nil, "empty" end
    if #items > max_pages then return nil, "too_many_pages" end
    table.sort(items, byLocation)
    return items
end

--- Whether this dossier carries anything whose layout cannot be guaranteed.
--- One sentence is owed to the reader before the read, and only if it is true.
function DocumentSource.includesLegacy(items)
    if type(items) ~= "table" then return false end
    for i = 1, #items do
        if items[i].legacy then return true end
    end
    return false
end

--[[--
The scale and page size of one note, dispatched by what it is.

Page ink knows its own units and may be a true 300 dpi; a sheet and legacy ink
are pixels of a screen nobody recorded and are rendered 1:1. Every kind goes
through one function because the forecast, the raster and the PDF page must
agree, and three call sites choosing for themselves is how they stop agreeing.
]]
function DocumentSource.geometryFor(item)
    if type(item) ~= "table" then return nil, "bad_geometry" end
    if item.kind == "page_ink" then return ExportSource.pageInkGeometry(item) end
    if item.kind == "legacy_page" then return ExportSource.legacyGeometry(item) end
    return ExportSource.canvasGeometry(item)
end

--- What this dossier will rasterise, for the space forecast and nothing else.
function DocumentSource.totalPixels(items, geometry)
    return ExportSource.totalPixels(items, geometry or DocumentSource.geometryFor)
end

--[[--
Legacy ink on white, at the size of the screen that is here now.

Nothing is transformed. The sidecar stores absolute screen pixels of a screen
whose size, zoom and rotation were never recorded, so the only honest thing to
do with them is put them where they say and let the buffer clip whatever falls
off (ADR-40) -- an invented transform would move ink to a position the reader
has no reason to expect and no way to check.

It is delivered through `schedule` rather than returned. `ink_export`'s job
batches through its scheduler, and a renderer that answered inline would turn
that batching into recursion whose depth is the number of pages (ADR-30).
]]
local function legacyRenderer(opts)
    local geometry = opts.geometry or DocumentSource.geometryFor
    local schedule = opts.schedule
    local legacy = opts.legacy
    return function(item, index, done)
        local scale, width_pt, height_pt = geometry(item)
        if not scale then
            return done(nil, (type(width_pt) == "string" and width_pt)
                or "bad_geometry")
        end
        -- Rounded exactly as the raster cache rounds, so a page that the
        -- budget did reduce is the buffer the forecast counted.
        local _pixels, w, h = Raster.roundedPixels(
            item.logical_w, item.logical_h, scale)
        -- `Blitbuffer.new` asserts rather than answering nil when a page
        -- cannot be allocated; the job's guarded transition reports the raise.
        local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        local function release()
            if bb then
                bb:free()
                bb = nil
            end
        end
        bb:fill(Blitbuffer.COLOR_WHITE)
        local ink = opts.ink
        if rawequal(ink, nil) then ink = Blitbuffer.COLOR_BLACK end
        local strokes = legacy and legacy:strokes(item.page)
        if type(strokes) == "table" then
            for i = 1, #strokes do
                Render.stroke(bb, strokes[i], 0, 0,
                    Style.colorFor(strokes[i].t, ink))
            end
        end
        schedule(function()
            done({ bb = bb, width_pt = width_pt, height_pt = height_pt,
                release = release })
        end)
    end
end

--[[--
  opts.schedule   function(fn) -- must defer; never call fn inline
  opts.geometry   the scale and page size per item
  opts.track      handed every raster as it opens, so Cancel can close it
  opts.legacy     the frozen sidecar view
  opts.ink        the colour ink is rendered in

One renderer for the whole dossier, switching on the descriptor. The stored
surfaces go through the same `ExportSource.surfaceRenderer` a notebook uses --
reading from the repository after the flush, never from the live cache -- with
each item's own repository, because a dossier can span two stores.
]]
function DocumentSource.renderer(opts)
    opts = opts or {}
    local geometry = opts.geometry or DocumentSource.geometryFor
    local legacy_render = legacyRenderer(opts)
    return function(item, index, done)
        if item.kind == "legacy_page" then
            return legacy_render(item, index, done)
        end
        -- The descriptor is not the row. The raster has to be opened over the
        -- row -- it is what carries the id the strokes hang off -- while the
        -- geometry is a property of the descriptor, which is the only thing
        -- that knows what kind of note this is and what its units are.
        local render = ExportSource.surfaceRenderer{
            repository = item.repository or opts.repository,
            schedule = opts.schedule,
            geometry = function() return geometry(item) end,
            track = opts.track,
        }
        return render(item.surface, index, done)
    end
end

return DocumentSource
