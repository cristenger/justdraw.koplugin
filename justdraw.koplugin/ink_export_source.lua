--[[--
What an export is *of*: which surfaces, in which order, at which scale.

Kept apart from the job because it is the part that differs per surface while
everything downstream is identical. A notebook page knows its millimetres and
carries a ruling; an EPUB sheet knows neither and is white. A notebook's pages
have an order of their own; a book's sheets only have one if the anchor index
has finished resolving them, and if it has not then there is no reading order
to be had and the export says so rather than inventing one.

Two enumeration rules are load-bearing.

**Walk the cursor to the end.** `listPages` is keyset-paginated and bounded;
a single call answers a batch, never "all of them". Treating the first batch
as the notebook is how a 300-page notebook exports its first 50 pages and
looks like it worked.

**Never order sheets by `updated_at`.** It is the only timestamp a canvas row
carries, and it is the order they were last *drawn on*, which has nothing to
do with where they sit in the book. Sheets are ordered by the page their
anchor resolves to, with unresolved ones after them and ties broken by id, so
the same book always exports in the same order.
]]

local Layout = require("ink_notebook_layout")
local Raster = require("ink_export_raster")

local Source = {}

--- One keyset page of rows. Small enough to stay bounded, large enough that a
--- long notebook is not a hundred round trips.
Source.PAGE_BATCH = 100
--- A refusal rather than an out-of-memory: an export of this many pages is a
--- mistake somewhere upstream.
Source.MAX_PAGES = 5000

--[[--
Every page of a notebook, in order.

Loops until a batch comes back empty rather than until a batch comes back
short, because "fewer rows than the limit" is not the repository's promise of
exhaustion. The cursor is also checked for progress: a repository that
answered the same last row twice would otherwise spin here forever.
]]
function Source.notebookPages(repository, notebook_id, opts)
    opts = opts or {}
    if not repository or type(repository.listPages) ~= "function" then
        return nil, "no_repository"
    end
    local limit = opts.limit or Source.PAGE_BATCH
    local max_pages = opts.max_pages or Source.MAX_PAGES
    local pages = {}
    local after_key, after_id
    while true do
        local batch, err = repository:listPages(notebook_id, {
            limit = limit, after_sort_key = after_key, after_id = after_id,
        })
        if not batch then return nil, err or "list_failed" end
        if #batch == 0 then break end
        for i = 1, #batch do
            pages[#pages + 1] = batch[i]
            if #pages > max_pages then return nil, "too_many_pages" end
        end
        local last = batch[#batch]
        if after_key == last.sort_key and after_id == last.id then
            return nil, "list_failed"
        end
        after_key, after_id = last.sort_key, last.id
    end
    if #pages == 0 then return nil, "empty" end
    return pages
end

--[[--
A book's sheets in reading order, or a refusal.

The index is the only thing that knows where a sheet hangs, and it resolves
asynchronously; asking before it is complete would order the sheets by
whatever had been resolved so far, which is neither reading order nor stable.
]]
function Source.orderedCanvases(canvases, index)
    if type(canvases) ~= "table" then return nil, "no_canvases" end
    if not index or type(index.isComplete) ~= "function"
        or not index:isComplete() then
        return nil, "index_incomplete"
    end
    local ordered = {}
    for i = 1, #canvases do ordered[i] = canvases[i] end
    table.sort(ordered, function(a, b)
        local page_a = index:pageOf(a.id)
        local page_b = index:pageOf(b.id)
        if page_a and page_b then
            if page_a ~= page_b then return page_a < page_b end
        elseif page_a then
            return true          -- placed sheets before orphans
        elseif page_b then
            return false
        end
        return a.id < b.id       -- stable, and total
    end)
    if #ordered == 0 then return nil, "empty" end
    return ordered
end

--- A notebook page keeps its physical size however far the raster is scaled
--- down, because it has one: its logical units are millimetres.
function Source.notebookGeometry(page)
    local units = Layout.LOGICAL_UNITS_PER_MM
    local target = Raster.physicalScale(units, Raster.TARGET_DPI)
    if not target then return nil, "bad_geometry" end
    local scale, err = Raster.boundedScale(page.logical_w, page.logical_h, target)
    if not scale then return nil, err end
    return scale,
        Raster.physicalPoints(units, page.logical_w),
        Raster.physicalPoints(units, page.logical_h)
end

--- A sheet's logical units are pixels of a screen nobody recorded, so it is
--- rasterised 1:1 and given a nominal DPI only to have a page size at all.
function Source.canvasGeometry(canvas)
    local scale, err = Raster.boundedScale(canvas.logical_w, canvas.logical_h, 1)
    if not scale then return nil, err end
    return scale,
        Raster.nominalPoints(canvas.logical_w, Raster.NOMINAL_DPI),
        Raster.nominalPoints(canvas.logical_h, Raster.NOMINAL_DPI)
end

--[[--
How many pixels this batch of surfaces will rasterise, at the scale it will
rasterise them.

Feeds the disk-space forecast, and nothing else. Answers nil rather than a
partial sum if any surface has no usable geometry: half a forecast would be
quoted to the reader as if it were the whole one, and a number that is wrong
in the reassuring direction is worse than no number at all.
]]
function Source.totalPixels(items, geometry)
    if type(items) ~= "table" or type(geometry) ~= "function" then return nil end
    local total = 0
    for i = 1, #items do
        local item = items[i]
        local ok, scale = pcall(geometry, item)
        if not ok or type(scale) ~= "number" then return nil end
        -- Both real geometry functions already refuse a surface without a
        -- size, but this is a public helper and the arithmetic below would
        -- raise rather than answer.
        if type(item.logical_w) ~= "number"
            or type(item.logical_h) ~= "number" then
            return nil
        end
        total = total + Raster.roundedPixels(item.logical_w, item.logical_h, scale)
    end
    return total
end

--[[--
A renderer for the export job: one surface in, one raster out, asynchronously.

`track` is handed every raster as it opens so the caller can close the one in
flight when the reader cancels. `release` is the job's handle on the same
thing, and closing twice is safe, so ownership never needs to be negotiated
between them.
]]
function Source.surfaceRenderer(opts)
    local repository = opts.repository
    local schedule = opts.schedule
    local geometry = opts.geometry
    local track = opts.track
    return function(item, index, done)
        local scale, width_pt, height_pt = geometry(item)
        if not scale then
            return done(nil, (type(width_pt) == "string" and width_pt)
                or "bad_geometry")
        end
        local delivered = false
        local job, err = Raster.open{
            repository = repository,
            surface = item,
            scale = scale,
            schedule = schedule,
            on_ready = function(raster)
                if delivered then return end
                delivered = true
                done({
                    bb = raster:buffer(),
                    width_pt = width_pt,
                    height_pt = height_pt,
                    release = function() raster:close() end,
                })
            end,
            on_error = function(reason, raster)
                if delivered then return end
                delivered = true
                if raster then raster:close() end
                done(nil, reason)
            end,
        }
        if not job then return done(nil, err) end
        if track then track(job) end
    end
end

return Source
