--[[--
Which surfaces an export covers, and in what order.

Both halves have a failure mode that looks like success. A notebook enumerated
from one keyset batch exports its first hundred pages and reports "done". A
book's sheets ordered by the only timestamp on the row come out in the order
they were last drawn on, which reads as shuffled and is stable only by
accident. Neither raises, so both are stated here as counts and orderings.

The refusals matter as much: an anchor index that has not finished has no
reading order to offer, and the export says so rather than exporting the part
it happens to know.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Source = require("ink_export_source")
    local Raster = require("ink_export_raster")

    local function notebookWith(count)
        local pages = {}
        for i = 1, count do
            pages[i] = { id = i, notebook_id = 1, sort_key = i * 1024,
                logical_w = 1184, logical_h = 1680, template_kind = "blank" }
        end
        return support.newNotebookStore{ pages = pages }
    end

    --- An index that answers for the ids it was given and nothing else.
    local function newIndex(complete, placement)
        return {
            isComplete = function() return complete end,
            pageOf = function(_, id) return placement[id] end,
        }
    end

    -- =================================================================
    t:describe("export / enumeration / notebook pages")

    t:case("a long notebook is walked to the end, not read once", function()
        local store = notebookWith(250)
        local pages, err = Source.notebookPages(store, 1, { limit = 100 })
        t:check(pages ~= nil, "enumerated: " .. tostring(err))
        t:eq(#pages, 250, "every page")
        t:check(store.calls.list_pages > 1,
            "which took more than one keyset batch")
        t:eq(pages[1].id, 1, "in order, first")
        t:eq(pages[250].id, 250, "in order, last")
    end)

    t:case("the walk ends on an empty batch, not on a short one", function()
        -- A repository is allowed to answer fewer rows than the limit and
        -- still have more; stopping early there would silently truncate.
        local store = notebookWith(120)
        local real = store.listPages
        local short = true
        store.listPages = function(self, id, spec)
            local batch = real(self, id, spec)
            if short and #batch > 3 then
                short = false
                local trimmed = {}
                for i = 1, 3 do trimmed[i] = batch[i] end
                return trimmed
            end
            return batch
        end
        local pages = Source.notebookPages(store, 1, { limit = 100 })
        t:eq(#pages, 120, "the short batch did not end the walk")
    end)

    t:case("a cursor that does not advance is refused instead of looping", function()
        local store = notebookWith(10)
        store.listPages = function(_, _, _)
            return { { id = 1, sort_key = 1024, logical_w = 10, logical_h = 10 } }
        end
        local pages, err = Source.notebookPages(store, 1, { limit = 5 })
        t:check(pages == nil, "refused")
        t:eq(err, "list_failed", "reason")
    end)

    t:case("an empty or unreadable notebook is reported, not exported", function()
        local empty = support.newNotebookStore{ pages = {} }
        t:eq(select(2, Source.notebookPages(empty, 1)), "empty", "nothing to export")

        local broken = notebookWith(3)
        broken.listPages = function() return nil, "database is locked" end
        t:eq(select(2, Source.notebookPages(broken, 1)), "database is locked",
            "the repository's reason is passed through")

        t:eq(select(2, Source.notebookPages(nil, 1)), "no_repository", "no store")
    end)

    t:case("an absurd page count is refused before anything is rendered", function()
        local store = notebookWith(30)
        local pages, err = Source.notebookPages(store, 1,
            { limit = 10, max_pages = 12 })
        t:check(pages == nil, "refused")
        t:eq(err, "too_many_pages", "reason")
    end)

    -- =================================================================
    t:describe("export / enumeration / book sheets")

    t:case("sheets come out in reading order, whatever order they were drawn", function()
        local canvases = {
            { id = 7, logical_w = 10, logical_h = 10, updated_at = 900 },
            { id = 3, logical_w = 10, logical_h = 10, updated_at = 100 },
            { id = 5, logical_w = 10, logical_h = 10, updated_at = 500 },
        }
        local index = newIndex(true, { [7] = 2, [3] = 40, [5] = 11 })
        local ordered = Source.orderedCanvases(canvases, index)
        t:eq(ordered[1].id, 7, "page 2 first")
        t:eq(ordered[2].id, 5, "then page 11")
        t:eq(ordered[3].id, 3, "then page 40")
    end)

    t:case("sheets on the same page are ordered by id, so the order is total", function()
        local canvases = {
            { id = 9, logical_w = 10, logical_h = 10 },
            { id = 2, logical_w = 10, logical_h = 10 },
        }
        local ordered = Source.orderedCanvases(canvases, newIndex(true, { [9] = 5, [2] = 5 }))
        t:eq(ordered[1].id, 2, "lower id first")
        t:eq(ordered[2].id, 9, "then the other")
    end)

    t:case("sheets whose anchor is lost come after the ones that are placed", function()
        local canvases = {
            { id = 1, logical_w = 10, logical_h = 10 },
            { id = 2, logical_w = 10, logical_h = 10 },
            { id = 3, logical_w = 10, logical_h = 10 },
        }
        local ordered = Source.orderedCanvases(canvases,
            newIndex(true, { [2] = 30, [3] = 4 }))
        t:eq(ordered[1].id, 3, "placed, page 4")
        t:eq(ordered[2].id, 2, "placed, page 30")
        t:eq(ordered[3].id, 1, "orphan last")
    end)

    t:case("an index that is still building refuses rather than guesses", function()
        local canvases = { { id = 1, logical_w = 10, logical_h = 10 } }
        local ordered, err = Source.orderedCanvases(canvases, newIndex(false, {}))
        t:check(ordered == nil, "refused")
        t:eq(err, "index_incomplete", "reason")
        t:eq(select(2, Source.orderedCanvases(canvases, nil)), "index_incomplete",
            "and so does no index at all")
    end)

    t:case("a book with no sheets is reported as empty", function()
        t:eq(select(2, Source.orderedCanvases({}, newIndex(true, {}))), "empty",
            "nothing to export")
    end)

    -- =================================================================
    t:describe("export / enumeration / geometry per surface")

    t:case("a notebook page keeps its millimetres and asks for 300 dpi", function()
        local page = { logical_w = 1184, logical_h = 1680 }
        local scale, w_pt, h_pt = Source.notebookGeometry(page)
        t:check(math.abs(scale - Raster.physicalScale(8, 300)) < 1e-12,
            "the full target scale")
        t:check(math.abs(w_pt - 419.527) < 0.01, "A5 width in points")
        t:check(math.abs(h_pt - 595.276) < 0.01, "A5 height in points")
    end)

    t:case("a large notebook page loses resolution, never its page size", function()
        local page = { logical_w = 1727, logical_h = 2235 }
        local scale, w_pt, h_pt = Source.notebookGeometry(page)
        t:check(scale < Raster.physicalScale(8, 300), "the raster was reduced")
        t:check(math.abs(w_pt - 215.9 * 72 / 25.4) < 0.5,
            "but Letter is still 8.5 inches wide")
        t:check(math.abs(h_pt - 279.4 * 72 / 25.4) < 0.5, "and 11 inches tall")
    end)

    t:case("a sheet is rasterised one to one at the nominal resolution", function()
        local scale, w_pt, h_pt = Source.canvasGeometry{
            logical_w = 1860, logical_h = 2480 }
        t:eq(scale, 1, "no invented detail")
        t:check(math.abs(w_pt - 1860 * 72 / 300) < 1e-9, "width in points")
        t:check(math.abs(h_pt - 2480 * 72 / 300) < 1e-9, "height in points")
    end)

    t:case("a sheet too large to raster is still bounded", function()
        local scale = Source.canvasGeometry{ logical_w = 4000, logical_h = 4000 }
        t:check(scale < 1, "reduced below one to one")
        t:check(math.floor(4000 * scale + 0.5) ^ 2 <= Raster.MAX_PIXELS,
            "and inside the budget")
    end)

    -- =================================================================
    t:describe("export / enumeration / the surface renderer")

    t:case("a rendered surface arrives as a buffer with its page size", function()
        local page = { id = 11, logical_w = 100, logical_h = 200,
            template_kind = "blank" }
        local store = support.newCanvasStore({ page })
        local sched = support.newScheduler()
        local tracked = {}
        local render = Source.surfaceRenderer{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            geometry = function() return 2, 50, 100 end,
            track = function(job) tracked[#tracked + 1] = job end,
        }
        local delivered
        render(page, 1, function(result, err) delivered = result or err end)
        t:eq(#tracked, 1, "the raster was offered for tracking straight away")
        t:check(delivered == nil, "and nothing was delivered synchronously")
        sched:drain()
        t:check(type(delivered) == "table", "delivered")
        t:eq(delivered.width_pt, 50, "page width")
        t:eq(delivered.height_pt, 100, "page height")
        t:eq(delivered.bb:getWidth(), 200, "the raster is the surface at scale")
        local bb = delivered.bb
        delivered.release()
        t:eq(bb.freed, true, "and releasing it closes the raster")
    end)

    t:case("a surface that cannot be rastered reports why, once", function()
        local page = { id = 12, logical_w = 100, logical_h = 200 }
        local store = support.newCanvasStore({ page })
        store.fail_stroke_list = "database is locked"
        local sched = support.newScheduler()
        local calls, reason = 0, nil
        local render = Source.surfaceRenderer{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            geometry = function() return 1, 10, 20 end,
        }
        render(page, 1, function(result, err)
            calls = calls + 1
            reason = err
        end)
        sched:drain()
        t:eq(calls, 1, "answered once")
        t:eq(reason, "database is locked", "with the reason")
    end)

    t:case("geometry that cannot be computed fails the page, not the process", function()
        local sched = support.newScheduler()
        local render = Source.surfaceRenderer{
            repository = support.newCanvasStore({}),
            schedule = function(fn) sched:schedule(fn) end,
            geometry = function() return nil, "bad_geometry" end,
        }
        local reason
        render({ id = 1 }, 1, function(_, err) reason = err end)
        t:eq(reason, "bad_geometry", "reported immediately")
    end)
    -- =================================================================
    t:describe("export / enumeration / a book's notes")

    local DocumentSource = require("ink_document_export_source")
    local Legacy = require("ink_legacy_ink")
    local Store = require("ink_store")

    --- The real frozen sidecar view over a real store: the dossier reads its
    --- pages and its strokes through exactly the object `main.lua` holds.
    local function legacyWith(pages)
        return Legacy.new(Store.new(pages))
    end

    local function stroke(...)
        local s = { n = select("#", ...) / 2, w = 4 }
        for i = 1, select("#", ...) do s[i] = select(i, ...) end
        return s
    end

    local function pageInkRow(id, page)
        return { id = id, fixed_page = page, surface_role = "page_ink",
            anchor_kind = "page", anchor_key = "page-ink:" .. page,
            coordinate_space = "native_page",
            logical_w = 596, logical_h = 842 }
    end

    local function kinds(items)
        local out = {}
        for i = 1, #items do
            out[i] = items[i].kind .. ":" .. tostring(items[i].page)
        end
        return table.concat(out, " ")
    end

    t:case("an EPUB's notes come out in reading order, legacy first on a page", function()
        local canvases = {
            { id = 3, logical_w = 600, logical_h = 800 },
            { id = 7, logical_w = 600, logical_h = 800 },
            { id = 9, logical_w = 600, logical_h = 800 },
        }
        local items, err = DocumentSource.documentNotes{
            rolling = true,
            canvases = canvases,
            index = newIndex(true, { [3] = 5, [7] = 2 }),
            repository = support.newCanvasStore(canvases),
            legacy = legacyWith{ [5] = { stroke(1, 1, 2, 2) },
                                 [2] = { stroke(3, 3, 4, 4) } },
            screen = { w = 600, h = 800 },
        }
        t:check(items ~= nil, "enumerated: " .. tostring(err))
        t:eq(kinds(items),
            "legacy_page:2 sheet:2 legacy_page:5 sheet:5 sheet:nil",
            "legacy before the sheet on its page, and the orphan last")
        t:eq(items[2].surface.id, 7, "page 2's sheet")
        t:eq(items[4].surface.id, 3, "page 5's sheet")
        t:eq(items[1].location_label, "Stored page 2", "legacy says where it was stored")
        t:eq(items[2].location_label, "Page 2", "a placed sheet says its page")
        t:eq(items[5].location_label, "Location unavailable", "an orphan says so")
        t:eq(items[1].legacy, true, "legacy is marked")
        t:eq(items[2].legacy, false, "and a sheet is not")
        t:eq(items[2].units, "px", "a sheet's units are pixels of a lost screen")
        t:eq(items[1].logical_w, 600, "legacy ink is the size of this screen")
        t:eq(items[1].logical_h, 800, "in both axes")
    end)

    t:case("an incomplete index refuses the whole dossier", function()
        local canvases = { { id = 1, logical_w = 600, logical_h = 800 } }
        local items, err = DocumentSource.documentNotes{
            rolling = true, canvases = canvases,
            index = newIndex(false, {}),
            repository = support.newCanvasStore(canvases),
            legacy = legacyWith{ [1] = { stroke(1, 1, 2, 2) } },
            screen = { w = 600, h = 800 },
        }
        t:check(items == nil, "refused")
        t:eq(err, "index_incomplete", "with the reason the reader already knows")
    end)

    t:case("a fixed layout's notes come out by page and id, legacy first", function()
        local rows = { pageInkRow(2, 4), pageInkRow(8, 4), pageInkRow(5, 1) }
        local store = support.newCanvasStore(rows)
        local items, err = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "pt",
            legacy = legacyWith{ [4] = { stroke(1, 1, 2, 2) } },
            screen = { w = 600, h = 800 },
        }
        t:check(items ~= nil, "enumerated: " .. tostring(err))
        t:eq(kinds(items), "page_ink:1 legacy_page:4 page_ink:4 page_ink:4",
            "page 1, then page 4 with its legacy ink in front")
        t:eq(items[3].surface.id, 2, "the lower id of page 4 first")
        t:eq(items[4].surface.id, 8, "then the other")
        t:eq(items[1].units, "pt", "the document's units travel with the row")
        t:eq(items[2].units, "px", "legacy ink is screen pixels whatever the page is")
        t:eq(items[1].location_label, "Page 1", "a page note says its page")
        t:check(rawequal(items[1].repository, store),
            "and carries the repository it is read from")
    end)

    t:case("the page-ink cursor is walked to the end, one batch at a time", function()
        local rows = { pageInkRow(1, 1), pageInkRow(2, 2), pageInkRow(3, 3) }
        local store = support.newCanvasStore(rows)
        local calls = 0
        local real = store.listPageInkSurfaces
        store.listPageInkSurfaces = function(self, book, opts)
            calls = calls + 1
            return real(self, book, opts)
        end
        local items = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px", limit = 1,
            screen = { w = 600, h = 800 },
        }
        t:eq(#items, 3, "every page")
        t:check(calls >= 4, "three batches and the empty one that ends the walk")
    end)

    t:case("a page-ink cursor that does not advance is refused, not looped", function()
        local store = support.newCanvasStore{}
        store.listPageInkSurfaces = function()
            return { pageInkRow(1, 1) }
        end
        local items, err = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px", limit = 1,
            screen = { w = 600, h = 800 },
        }
        t:check(items == nil, "refused")
        t:eq(err, "list_failed", "reason")
    end)

    t:case("a repository that cannot list says so", function()
        local store = support.newCanvasStore{}
        store.fail_list_page_ink = "database is locked"
        t:eq(select(2, DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px",
            screen = { w = 600, h = 800 } }), "database is locked",
            "the repository's own reason")
    end)

    t:case("an absurd dossier is refused before a single raster", function()
        local count = 5001
        local store = { listPageInkSurfaces = function(_, _, opts)
            local after = tonumber(opts.after_page) or 0
            local out = {}
            for p = after + 1, math.min(after + opts.limit, count) do
                out[#out + 1] = pageInkRow(p, p)
            end
            return out
        end }
        local items, err = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "pt",
            screen = { w = 600, h = 800 },
        }
        t:check(items == nil, "refused")
        t:eq(err, "too_many_pages", "reason")
        count = 5000
        t:eq(#DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "pt",
            screen = { w = 600, h = 800 } }, 5000, "and the limit itself is fine")
    end)

    t:case("a book with no notes of any kind is empty, not an export", function()
        local store = support.newCanvasStore{}
        local items, err = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px",
            legacy = legacyWith{}, screen = { w = 600, h = 800 },
        }
        t:check(items == nil, "refused")
        t:eq(err, "empty", "reason")
    end)

    t:case("legacy ink alone is a dossier", function()
        local store = support.newCanvasStore{}
        local items = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px",
            legacy = legacyWith{ [3] = { stroke(1, 1, 2, 2) } },
            screen = { w = 600, h = 800 },
        }
        t:eq(#items, 1, "one page")
        t:eq(items[1].kind, "legacy_page", "the sidecar's own")
    end)

    -- =================================================================
    t:describe("export / enumeration / the notes' geometry")

    t:case("a page in points maps to a true 300 dpi and keeps its page size", function()
        local scale, w_pt, h_pt = Source.pageInkGeometry{
            logical_w = 300, logical_h = 400, units = "pt" }
        t:check(math.abs(scale - 300 / 72) < 1e-9, "300 dots per inch of page")
        t:check(math.abs(w_pt - 300) < 1e-9, "the MediaBox is the page itself")
        t:check(math.abs(h_pt - 400) < 1e-9, "in both axes")
    end)

    t:case("an A4 page loses resolution, never its page size", function()
        local scale, w_pt, h_pt = Source.pageInkGeometry{
            logical_w = 596, logical_h = 842, units = "pt" }
        t:check(scale < 300 / 72, "the raster was reduced to fit the budget")
        t:check(math.floor(596 * scale + 0.5) * math.floor(842 * scale + 0.5)
            <= Raster.MAX_PIXELS, "inside it")
        t:check(math.abs(w_pt - 596) < 1e-9, "and A4 is still A4")
        t:check(math.abs(h_pt - 842) < 1e-9, "in both axes")
    end)

    t:case("a page whose units are pixels gets the sheet's policy", function()
        local item = { logical_w = 1000, logical_h = 1200, units = "px" }
        local scale, w_pt, h_pt = Source.pageInkGeometry(item)
        local c_scale, c_w, c_h = Source.canvasGeometry(item)
        t:eq(scale, c_scale, "the same scale")
        t:eq(w_pt, c_w, "the same width")
        t:eq(h_pt, c_h, "the same height")
        t:eq(scale, 1, "which is one to one")
    end)

    t:case("legacy ink is this screen, one to one, at a nominal resolution", function()
        local scale, w_pt, h_pt = Source.legacyGeometry{
            logical_w = 600, logical_h = 800 }
        t:eq(scale, 1, "no invented detail")
        t:check(math.abs(w_pt - 600 * 72 / 300) < 1e-9, "width in points")
        t:check(math.abs(h_pt - 800 * 72 / 300) < 1e-9, "height in points")
    end)

    -- =================================================================
    t:describe("export / enumeration / the notes' renderer")

    t:case("legacy ink is drawn on white and delivered on a later tick", function()
        local sched = support.newScheduler()
        local render = DocumentSource.renderer{
            schedule = function(fn) sched:schedule(fn) end,
            legacy = legacyWith{ [3] = { stroke(100, 100, 200, 100) } },
            ink = "black",
        }
        local item = { kind = "legacy_page", page = 3, legacy = true,
            logical_w = 600, logical_h = 800, units = "px",
            location_label = "Stored page 3" }
        local delivered, reason
        render(item, 1, function(result, err) delivered, reason = result, err end)
        t:check(delivered == nil, "nothing arrives inside the renderer's own frame")
        sched:drain()
        t:check(delivered ~= nil, "delivered: " .. tostring(reason))
        t:eq(delivered.bb:getWidth(), 600, "the screen's width")
        t:eq(delivered.bb:getHeight(), 800, "and its height")
        t:eq(delivered.bb.fills[1], "white", "on white")
        t:check(#delivered.bb.rects > 1, "with the stroke on it")
        local bb = delivered.bb
        delivered.release()
        t:eq(bb.freed, true, "and releasing it frees the buffer")
        delivered.release()
        t:eq(bb.freed, true, "twice, harmlessly")
    end)

    t:case("legacy ink off the screen is clipped, not painted outside", function()
        local sched = support.newScheduler()
        local render = DocumentSource.renderer{
            schedule = function(fn) sched:schedule(fn) end,
            legacy = legacyWith{ [3] = { stroke(2000, 2000, 2400, 2000) } },
            ink = "black",
        }
        local item = { kind = "legacy_page", page = 3, legacy = true,
            logical_w = 600, logical_h = 800, units = "px",
            location_label = "Stored page 3" }
        local delivered
        render(item, 1, function(result) delivered = result end)
        sched:drain()
        t:eq(delivered.bb:writesOutside(0, 0, 600, 800), 0,
            "the buffer clipped it, and nothing invented a transform")
        delivered.release()
    end)

    t:case("a page with a row but no strokes rasters blank rather than failing", function()
        local rows = { pageInkRow(1, 1) }
        local store = support.newCanvasStore(rows)
        local sched = support.newScheduler()
        local render = DocumentSource.renderer{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
        }
        local items = DocumentSource.documentNotes{
            repository = store, book_id = 1, units = "px",
            screen = { w = 600, h = 800 },
        }
        local delivered, reason
        render(items[1], 1, function(result, err) delivered, reason = result, err end)
        sched:drain()
        t:check(delivered ~= nil, "delivered: " .. tostring(reason))
        delivered.release()
    end)
    -- =================================================================
    t:describe("export / enumeration / the notes under their band")

    local Header = require("ink_export_header")

    --- The injected painter, again as a recorder: see export_header_spec.
    local function recorder()
        local rec = { calls = {} }
        rec.paint = function(_, _, _, text, max_width)
            rec.calls[#rec.calls + 1] = { text = text, max_width = max_width }
            return 60
        end
        return rec
    end

    t:case("every kind is scaled so the page the band made fits the budget", function()
        local sheet = { kind = "sheet", logical_w = 2000, logical_h = 4000,
            units = "px" }
        t:eq(Source.canvasGeometry(sheet), 1,
            "the sheet alone is exactly the budget at one to one")
        local scale = DocumentSource.geometryFor(sheet)
        t:check(scale < 1, "and the dossier reduces it for the band")
        local w = math.floor(2000 * scale + 0.5)
        local h = math.floor(4000 * scale + 0.5)
        t:check(w * (h + Header.BAND_PX) <= Raster.MAX_PIXELS, "inside it")

        local legacy = { kind = "legacy_page", logical_w = 2000,
            logical_h = 4000, units = "px" }
        t:eq(DocumentSource.geometryFor(legacy), scale,
            "legacy ink is bounded by the same arithmetic")
        local page_ink = { kind = "page_ink", logical_w = 2000,
            logical_h = 4000, units = "pt" }
        local ink_scale = DocumentSource.geometryFor(page_ink)
        t:check(math.floor(2000 * ink_scale + 0.5)
            * (math.floor(4000 * ink_scale + 0.5) + Header.BAND_PX)
            <= Raster.MAX_PIXELS, "and so is a page note")
    end)

    t:case("the forecast counts the band it is going to write", function()
        local items = {
            { kind = "sheet", logical_w = 100, logical_h = 200, units = "px" },
            { kind = "legacy_page", logical_w = 300, logical_h = 400,
              units = "px" },
        }
        local total = DocumentSource.totalPixels(items)
        t:eq(total, 100 * (200 + Header.BAND_PX) + 300 * (400 + Header.BAND_PX),
            "content plus band, per page")
        t:check(total > Source.totalPixels(items, DocumentSource.geometryFor),
            "which is more than the content alone")
    end)

    t:case("a note that cannot be sized leaves no forecast at all", function()
        t:check(DocumentSource.totalPixels{
            { kind = "sheet", logical_w = 0, logical_h = 10, units = "px" },
        } == nil, "half a forecast is worse than none")
    end)

    t:case("every rendered note arrives under its band", function()
        local sched = support.newScheduler()
        local rec = recorder()
        local render = DocumentSource.renderer{
            schedule = function(fn) sched:schedule(fn) end,
            legacy = legacyWith{ [3] = { stroke(10, 10, 20, 20) } },
            ink = "black",
            header = { title = "Moby Dick", paint_text = rec.paint },
        }
        local item = { kind = "legacy_page", page = 3, legacy = true,
            logical_w = 600, logical_h = 800, units = "px",
            location_label = "Stored page 3" }
        local delivered, reason
        render(item, 1, function(result, err) delivered, reason = result, err end)
        sched:drain()
        t:check(delivered ~= nil, "delivered: " .. tostring(reason))
        t:eq(delivered.bb:getHeight(), 800 + Header.BAND_PX,
            "the note grew by the band")
        t:eq(rec.calls[1].text, "Moby Dick · Legacy ink · Stored page 3",
            "which says what this page is")
        delivered.release()
    end)

    t:case("a stored surface gets the same band, and its own words", function()
        local canvases = { { id = 4, logical_w = 100, logical_h = 200 } }
        local store = support.newCanvasStore(canvases)
        local sched = support.newScheduler()
        local rec = recorder()
        local render = DocumentSource.renderer{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            header = { title = "Moby Dick", paint_text = rec.paint },
        }
        local items = DocumentSource.documentNotes{
            rolling = true, canvases = canvases,
            index = newIndex(true, { [4] = 2 }),
            repository = store, screen = { w = 600, h = 800 },
        }
        local delivered, reason
        render(items[1], 1, function(result, err) delivered, reason = result, err end)
        sched:drain()
        t:check(delivered ~= nil, "delivered: " .. tostring(reason))
        t:eq(delivered.bb:getHeight(), 200 + Header.BAND_PX, "with its band")
        t:eq(rec.calls[1].text, "Moby Dick · Drawing sheet · Page 2",
            "named for what it is")
        -- The band adds points as well as pixels, or the PDF would squeeze
        -- the whole composed page into the note's own height.
        t:check(math.abs(delivered.height_pt
            - (Raster.nominalPoints(200, Raster.NOMINAL_DPI) + Header.BAND_PT))
            < 1e-9, "and the page grew by the same 10 mm")
        delivered.release()
    end)

    t:case("a surface that fails to raster never reaches the band", function()
        local canvases = { { id = 4, logical_w = 100, logical_h = 200 } }
        local store = support.newCanvasStore(canvases)
        store.fail_stroke_list = "database is locked"
        local sched = support.newScheduler()
        local rec = recorder()
        local render = DocumentSource.renderer{
            repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            header = { title = "T", paint_text = rec.paint },
        }
        local items = DocumentSource.documentNotes{
            rolling = true, canvases = canvases,
            index = newIndex(true, { [4] = 2 }),
            repository = store, screen = { w = 600, h = 800 },
        }
        local delivered, reason
        render(items[1], 1, function(result, err) delivered, reason = result, err end)
        sched:drain()
        t:check(delivered == nil, "nothing to compose")
        t:eq(reason, "database is locked", "and the reason is the store's")
        t:eq(#rec.calls, 0, "the band was never painted")
    end)
end
