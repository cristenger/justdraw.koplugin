--[[--
The page index: where a fixed layout's sheets are, read in batches.

What it promises is mostly what it does not do. A book with no sheet on its
pages -- nearly every PDF -- costs one COUNT and not a single listing (ADR-62).
No batch runs while a contact is live (ADR-42). And the cursor over
(fixed_page, id) never skips the second sheet of a page at a batch edge, which
a cursor over the page alone would.
]]
return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local PageIndex = require("ink_page_index")

    local function pageSheet(id, page)
        return { id = id, anchor_kind = "page", anchor_key = "page:" .. page,
            fixed_page = page, surface_role = "sheet", logical_w = 600, logical_h = 800 }
    end

    local function fixture(rows, opts)
        opts = opts or {}
        local store = support.newCanvasStore(rows)
        local sched = support.newScheduler()
        local done, failed = 0, nil
        local busy = false
        local index = PageIndex.new{
            repository = store,
            book_id = 12,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
            can_work = function() return not busy end,
            on_complete = function() done = done + 1 end,
            on_error = function(reason) failed = reason end,
        }
        return index, store, sched, {
            done = function() return done end,
            failed = function() return failed end,
            setBusy = function(v) busy = v end,
        }
    end

    t:describe("ink_page_index")

    t:case("a book with no sheet on its pages lists nothing at all", function()
        local index, store, sched, probe = fixture({})
        t:eq(index:open(), true, "opened")
        t:eq(index:isComplete(), true, "complete at once")
        sched:drain()
        t:eq(store.calls.list, 0, "not one listing query")
        t:eq(probe.done(), 1, "and completion is still announced, on a tick")
    end)

    t:case("sheets arrive in batches and are found by page", function()
        local rows = {}
        for i = 1, PageIndex.METADATA_BATCH + 5 do rows[i] = pageSheet(i, 1 + (i % 3)) end
        local index, store, sched, probe = fixture(rows)
        index:open()
        t:eq(index:isComplete(), false, "still reading")
        sched:drain()
        t:eq(store.calls.list, 2, "two batches")
        t:eq(index:count(), #rows, "every row")
        t:eq(probe.done(), 1, "completed once")
        t:eq(index:pageOf(4), 2, "a page from the row itself")
        for _, canvas in ipairs(index:visibleCanvases(2)) do
            t:eq(canvas.fixed_page, 2, "only that page's sheets")
        end
    end)

    t:case("the cursor keeps the second sheet of a page at a batch edge", function()
        local rows = {}
        for i = 1, PageIndex.METADATA_BATCH + 1 do rows[i] = pageSheet(i, 7) end
        local index, _, sched = fixture(rows)
        index:open()
        sched:drain()
        t:eq(index:count(), #rows, "none skipped, all on one page")
    end)

    t:case("a batch stands aside while a contact is live", function()
        local index, store, sched, probe = fixture({ pageSheet(1, 3) })
        probe.setBusy(true)
        index:open()
        sched:tick()
        t:eq(store.calls.list, 0, "no query with a pen down")
        sched:drain()
        t:eq(store.calls.list, 0, "nor on the next try while it stays down")
        probe.setBusy(false)
        sched:advance(PageIndex.YIELD_DELAY)
        t:eq(store.calls.list, 1, "read once the pen lifts")
        t:eq(index:count(), 1, "and the sheet is there")
    end)

    t:case("a failed listing is reported once and the index gives up", function()
        local index, store, sched, probe = fixture({ pageSheet(1, 3) })
        store.fail_list_canvases = "disk I/O error"
        index:open()
        sched:drain()
        t:eq(probe.failed(), "disk I/O error", "the reason")
        t:eq(index:phase(), "cancelled", "no longer building")
    end)

    t:case("add and forget keep the page map and the list together", function()
        local index, _, sched = fixture({})
        index:open()
        sched:drain()
        index:add(pageSheet(5, 2))
        index:add(pageSheet(6, 2))
        t:eq(#index:visibleCanvases(2), 2, "both on the page")
        index:forget(5)
        t:eq(#index:visibleCanvases(2), 1, "one left")
        t:eq(index:get(5), nil, "and gone by id")
        t:eq(index:count(), 1, "and from the list")
        index:forget(6)
        t:eq(#index:visibleCanvases(2), 0, "the page is empty")
        t:eq(#index:orphanIds(), 0, "a page number never orphans a sheet")
    end)
end
