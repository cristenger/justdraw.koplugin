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
end
