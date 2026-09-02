--[[--
Anchors and the page index.

The anchor is the only thing that ties a canvas to the book, and it is the only
thing reflow is allowed to disturb: the ink itself lives in canvas coordinates
and never moves. So the questions here are what makes a valid anchor, what
happens to one the document no longer contains, and -- the part that decides
whether the feature is usable on a book with hundreds of notes -- what the
index refuses to do while a page is being turned or painted.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Anchor = require("ink_anchor")
    local Index = require("ink_anchor_index")

    -- =================================================================
    t:describe("ink_anchor / creating an anchor")

    t:case("an anchor keeps both the raw and the normalised xpointer", function()
        local doc = support.newDocument{
            here = "/body/p[7]",
            pages = { ["/body/p[7]"] = 41 },
            normalized = { ["/body/p[7]"] = "/body/DocFragment[3]/p[7]" },
        }
        local spec = Anchor.forCurrentPosition(doc, 20240114)
        t:eq(spec.anchor_raw, "/body/p[7]", "raw")
        t:eq(spec.anchor_normalized, "/body/DocFragment[3]/p[7]", "normalised")
        t:eq(spec.anchor_dom_version, 20240114, "and the DOM it was born under")
    end)

    t:case("the key is built from the normalised form when there is one", function()
        local doc = support.newDocument{
            here = "/body/p[7]",
            pages = { ["/body/p[7]"] = 41 },
            normalized = { ["/body/p[7]"] = "/body/DocFragment[3]/p[7]" },
        }
        t:eq(Anchor.forCurrentPosition(doc, 1).anchor_key,
            "xp:/body/DocFragment[3]/p[7]",
            "so two anchors at one position collide in the database")
    end)

    t:case("the key falls back to the raw form when normalisation is unavailable", function()
        local doc = support.newDocument{ here = "/body/p[7]", pages = { ["/body/p[7]"] = 41 } }
        -- getNormalizedXPointer returns the xpointer unchanged on a DOM that
        -- already normalises; the key is the same either way.
        t:eq(Anchor.forCurrentPosition(doc, 1).anchor_key, "xp:/body/p[7]", "raw key")
    end)

    t:case("a position with no xpointer does not become a canvas", function()
        local doc = support.newDocument{ here = nil }
        doc.getXPointer = function() return nil end
        local spec, err = Anchor.forCurrentPosition(doc, 1)
        t:eq(spec, nil, "refused")
        t:eq(err, "no_position", "a canvas that cannot be found again is not worth creating")
    end)

    t:case("an xpointer the document does not contain is refused", function()
        local doc = support.newDocument{ here = "/body/p[7]", pages = {} }
        local spec, err = Anchor.forCurrentPosition(doc, 1)
        t:eq(spec, nil, "refused")
        t:eq(err, "not_in_document", "born orphaned is not a state worth having")
    end)

    t:case("a fixed-layout anchor is a page number", function()
        local spec = Anchor.forPage(41)
        t:eq(spec.anchor_kind, "page", "kind")
        t:eq(spec.anchor_key, "page:41", "key")
        t:eq(spec.fixed_page, 41, "and the page itself")
        t:eq(spec.anchor_raw, nil, "with no xpointer to keep")
    end)

    -- =================================================================
    t:describe("ink_anchor / resolving an anchor")

    local function canvasFor(raw, normalized, dom)
        return {
            id = 1,
            anchor_kind = "xpointer",
            anchor_raw = raw,
            anchor_normalized = normalized,
            anchor_dom_version = dom,
        }
    end

    t:case("a DOM that normalises tries the normalised pointer first", function()
        local doc = support.newDocument{
            pages = { ["/norm"] = 41, ["/raw"] = 99 },
            normalized_dom_version = 20200824,
        }
        local canvas = canvasFor("/raw", "/norm", 20240114)
        t:eq(Anchor.resolve(doc, canvas), "/norm", "the canonical form wins")
    end)

    t:case("an older DOM tries the raw pointer first", function()
        local doc = support.newDocument{
            pages = { ["/norm"] = 41, ["/raw"] = 99 },
            normalized_dom_version = 20200824,
        }
        local canvas = canvasFor("/raw", "/norm", 20180000)
        t:eq(Anchor.resolve(doc, canvas), "/raw", "which is what that DOM understands")
    end)

    t:case("the other form is tried when the preferred one is gone", function()
        local doc = support.newDocument{ pages = { ["/raw"] = 99 } }
        local canvas = canvasFor("/raw", "/norm", 20240114)
        t:eq(Anchor.resolve(doc, canvas), "/raw", "the fallback saves the canvas")
    end)

    t:case("an anchor neither form resolves is nil, not an error", function()
        local doc = support.newDocument{ pages = {} }
        t:eq(Anchor.resolve(doc, canvasFor("/raw", "/norm", 1)), nil,
            "the caller turns this into an orphan, and never into a delete")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / building")

    --- Canvases 1..n, each anchored at "/p<i>" and living on page i.
    local function fixture(n, opts)
        opts = opts or {}
        local canvases, pages = {}, {}
        for i = 1, n do
            canvases[i] = {
                id = i,
                anchor_kind = "xpointer",
                anchor_raw = "/p" .. i,
                anchor_normalized = "/p" .. i,
                anchor_dom_version = 20240114,
                logical_w = 1860, logical_h = 2480,
            }
            pages["/p" .. i] = i
        end
        local doc = support.newDocument{ pages = pages, visible = opts.visible }
        local store = support.newCanvasStore(canvases)
        local sched = support.newScheduler()
        -- Every delay the index stood aside for, in order. A yield is only
        -- observable as "it came back later instead of now", so the delay it
        -- asked for is the thing worth recording.
        local yields = {}
        local index = Index.new{
            repository = store,
            document = doc,
            book_id = 12,
            batch = opts.batch or 8,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn)
                yields[#yields + 1] = delay
                sched:scheduleIn(delay, fn)
            end,
            can_work = opts.can_work,
            on_error = opts.on_error,
        }
        return index, doc, store, sched, yields
    end

    --[[--
    Open, and let the metadata phase finish -- and only that.

    The tick that loads the last batch is also the one that consults the
    layout cache, so this returns with the list whole and not one anchor put
    to the document.
    ]]
    local function loadMetadata(index, sched)
        index:open()
        local ticks = 0
        while index:phase() == "metadata" do
            sched:tick()
            ticks = ticks + 1
            if ticks > 100 then error("the metadata phase did not settle", 0) end
        end
        return ticks
    end

    t:case("a cached layout is used and nothing is resolved", function()
        local index, doc, store, sched = fixture(20)
        store.layouts["layout-a"] = {}
        for i = 1, 20 do store.layouts["layout-a"][i] = i end

        index:open()
        sched:drain()
        t:eq(doc.resolutions, 0, "not one xpointer resolved")
        t:eq(index:isComplete(), true, "and the index is ready immediately")
        t:eq(index:pageOf(7), 7, "with every canvas placed")
    end)

    t:case("with no cache, anchors resolve in bounded batches", function()
        local index, doc, _, sched = fixture(20, { batch = 5 })
        loadMetadata(index, sched)
        t:eq(doc.resolutions, 0, "loading the list resolves nothing by itself")
        sched:tick()
        t:eq(doc.resolutions, 5, "one batch")
        sched:tick()
        t:eq(doc.resolutions, 10, "then another")
        t:eq(index:isComplete(), false, "still building")
        sched:drain()
        t:eq(doc.resolutions, 20, "until every anchor is placed")
        t:eq(index:isComplete(), true, "and then it is done")
    end)

    t:case("a page turn while indexing resolves nothing extra", function()
        local index, doc, _, sched = fixture(500, { batch = 8 })
        index:open()
        sched:tick()
        local after_one_batch = doc.resolutions
        for page = 1, 20 do
            doc.current_page = page
            index:visibleCanvases(page)
        end
        t:eq(doc.resolutions, after_one_batch,
            "turning pages never triggers a scan of the book")
        t:eq(index:isComplete(), false, "and the index is still only started")
    end)

    t:case("derived pages are persisted in bounded batches", function()
        local index, _, store, sched = fixture(20, { batch = 5 })
        loadMetadata(index, sched)
        sched:tick()
        t:eq(store.calls.save, 1, "the first tick writes only its own batch")
        local first_count = 0
        for _ in pairs(store.saves[1].pages) do first_count = first_count + 1 end
        t:check(first_count <= 5, "the write is bounded by the resolve budget")
        sched:drain()
        t:eq(store.calls.save, 4, "twenty anchors make four small transactions")
        t:eq(store.saves[4].hash, "layout-a", "against the layout it describes")
        t:eq(store.saves[4].finalize, true, "only the last batch prunes old layouts")
        t:eq(store.layouts["layout-a"][7], 7, "the batches merge into one cache")
    end)

    t:case("an anchor that no longer resolves becomes an orphan", function()
        local index, doc, store, sched = fixture(3)
        doc.pages["/p2"] = nil
        index:open()
        sched:drain()
        t:eq(#index:orphanIds(), 1, "one orphan")
        t:eq(index:orphanIds()[1], 2, "the one that vanished")
        t:eq(#store.canvases, 3, "and nothing was deleted")
        t:eq(index:pageOf(2), nil, "it is simply on no page")
    end)

    t:case("an orphan is not written into the layout cache", function()
        local index, doc, store, sched = fixture(3)
        doc.pages["/p2"] = nil
        index:open()
        sched:drain()
        t:eq(store.saves[1].pages[2], nil,
            "caching 'nowhere' would make the miss permanent")
    end)

    t:case("a book with no canvases is complete after one empty batch", function()
        local index, _, store, sched = fixture(0)
        t:eq(loadMetadata(index, sched), 1, "one tick to find there is nothing")
        t:eq(index:isComplete(), true, "and nothing to do")
        sched:drain()
        t:eq(store.calls.save, 0, "so nothing was written")
        t:eq(index:progress().total, 0, "the count said so before the listing did")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / loading the list")

    t:case("opening queues the first batch and returns", function()
        local index, _, store, sched = fixture(450)
        t:eq(index:open(), true, "the caller is not blocked")
        t:eq(store.calls.list, 0, "not one row has been read")
        t:eq(index:phase(), "metadata", "it says what it is doing")
        t:eq(index:isComplete(), false, "and it is not ready")
        t:eq(sched:pending(), 1, "one batch is waiting for a tick")
    end)

    t:case("450 sheets arrive in three batches, a tick apart", function()
        local index, _, store, sched = fixture(450)
        local whole_book = 0
        store.listCanvases = function() whole_book = whole_book + 1; return {} end

        index:open()
        sched:tick()
        t:eq(index:count(), 200, "one batch")
        t:eq(index:progress().loaded, 200, "and progress says so")
        t:eq(index:progress().total, 450, "against the count taken at open")
        t:eq(index:progress().phase, "metadata", "still loading")
        sched:tick()
        t:eq(index:count(), 400, "then another")
        sched:tick()
        t:eq(index:count(), 450, "and the short one ends the listing")
        t:eq(store.calls.list, 3, "three queries, never a whole-book one")
        t:eq(whole_book, 0, "listCanvases is not what the index reads")
        t:eq(index:phase(), "resolving", "which is where the anchors start")
    end)

    t:case("loading the list opens no stroke", function()
        local index, _, store, sched = fixture(450)
        index:open()
        sched:drain()
        t:eq(store.calls.stroke_list, 0, "no canvas was opened")
        t:eq(store.calls.stroke_read, 0, "not a stroke read")
        t:eq(store.calls.stroke_chunk, 0, "and not a point decoded")
        t:eq(index:isComplete(), true, "while the index finished")
    end)

    t:case("a count that fails is the one refusal left at the call site", function()
        local index, _, store = fixture(3)
        store.fail_count_canvases = "disk read failed"
        local ok, err = index:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "disk read failed", "with the repository's reason")
        t:eq(store.calls.list, 0, "and nothing was listed")
    end)

    t:case("a batch that fails stops the index and says so once", function()
        local reasons = {}
        local index, doc, store, sched = fixture(450, {
            on_error = function(reason) reasons[#reasons + 1] = reason end,
        })
        index:open()
        sched:tick()
        store.fail_list_canvases = "disk read failed"
        sched:tick()
        t:eq(#reasons, 1, "the session is told once")
        t:eq(reasons[1], "list_failed", "in the words it already translates")
        t:eq(index:phase(), "cancelled", "and the generation is dead")
        t:eq(index:isComplete(), false, "a half-loaded index is not a ready one")
        t:eq(sched:pending(), 0, "nothing is left scheduled")
        sched:drain()
        t:eq(#reasons, 1, "still once")
        t:eq(doc.resolutions, 0, "and the partial list was never resolved")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / yielding to the pen")

    t:case("a metadata batch asks the database nothing while a contact is live", function()
        local live = true
        local index, doc, store, sched, yields = fixture(450, {
            can_work = function() return not live end,
        })
        index:open()
        sched:drain()
        t:eq(store.calls.list, 0, "no query")
        t:eq(doc.resolutions, 0, "and nothing put to the document")
        t:eq(#yields, 1, "it stood aside once")
        t:eq(yields[1], 0.1, "and comes back a tenth of a second later")

        live = false
        sched:advance(0.1)
        t:eq(index:isComplete(), true, "the same build finishes when the pen lifts")
        t:eq(index.generation, 1, "without starting a second one")
        t:eq(index:pageOf(7), 7, "with every anchor placed")
    end)

    t:case("a resolve batch makes no CREngine call while a contact is live", function()
        local live = false
        local index, doc, _, sched, yields = fixture(20, {
            batch = 5,
            can_work = function() return not live end,
        })
        loadMetadata(index, sched)
        t:eq(index:phase(), "resolving", "the list is whole")
        live = true
        sched:drain()
        t:eq(doc.resolutions, 0, "the pen owns the process, so nothing is resolved")
        t:eq(yields[#yields], 0.1, "the batch put itself back on the queue")

        live = false
        sched:advance(0.1)
        t:eq(index:isComplete(), true, "and finishes afterwards")
        t:eq(doc.resolutions, 20, "having resolved each anchor exactly once")
    end)

    t:case("with no scheduleIn a refused batch simply tries again", function()
        local live = true
        local doc, store, sched
        local canvases, pages = {}, {}
        for i = 1, 3 do
            canvases[i] = { id = i, anchor_kind = "xpointer",
                anchor_raw = "/p" .. i, anchor_normalized = "/p" .. i }
            pages["/p" .. i] = i
        end
        doc = support.newDocument{ pages = pages }
        store = support.newCanvasStore(canvases)
        sched = support.newScheduler()
        local index = Index.new{
            repository = store, document = doc, book_id = 12, batch = 8,
            schedule = function(fn) sched:schedule(fn) end,
            can_work = function() return not live end,
        }
        index:open()
        sched:tick()
        t:eq(store.calls.list, 0, "refused")
        t:eq(sched:pending(), 1, "but still queued")
        live = false
        sched:drain()
        t:eq(index:isComplete(), true, "and it gets there on the next tick")
    end)

    t:case("cancelling a stood-aside batch ends it for good", function()
        local index, _, store, sched = fixture(450, {
            can_work = function() return false end,
        })
        index:open()
        sched:drain()
        index:cancel()
        sched:advance(1)
        t:eq(store.calls.list, 0, "the rescheduled batch checks again before working")
        t:eq(index:phase(), "cancelled", "and says what it is")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / reading")

    t:case("only canvases the document confirms on this page come back", function()
        local index, doc, _, sched = fixture(5)
        index:open()
        sched:drain()
        doc.current_page = 3
        local here = index:visibleCanvases(3)
        t:eq(#here, 1, "one canvas")
        t:eq(here[1].id, 3, "the right one")
    end)

    t:case("a stale placement is not returned just because the map says so", function()
        -- The map is a cache. The document is the authority, and it is asked
        -- about the handful of candidates the map produced -- never about the
        -- book.
        local index, doc, _, sched = fixture(5)
        index:open()
        sched:drain()
        doc.pages["/p3"] = 99      -- the text moved without a rerender event
        doc.current_page = 3
        t:eq(#index:visibleCanvases(3), 0, "the confirmation catches it")
    end)

    t:case("the confirmation is asked about candidates, not about the book", function()
        local index, doc, _, sched = fixture(500)
        index:open()
        sched:drain()
        doc.in_page_checks = 0
        doc.current_page = 3
        index:visibleCanvases(3)
        t:check(doc.in_page_checks <= 2,
            "one page's worth of candidates, not 500 (" .. doc.in_page_checks .. ")")
    end)

    t:case("a two-page spread returns the canvases of both pages", function()
        local index, doc, _, sched = fixture(6, { visible = 2 })
        index:open()
        sched:drain()
        doc.current_page = 3
        local here = index:visibleCanvases(3)
        t:eq(#here, 2, "both pages")
        t:eq(here[1].id + here[2].id, 7, "canvases 3 and 4")
    end)

    t:case("reading the index issues no query at all", function()
        local index, doc, store, sched = fixture(20)
        index:open()
        sched:drain()
        local before = store.calls.list + store.calls.read + store.calls.save
        for page = 1, 20 do
            doc.current_page = page
            index:visibleCanvases(page)
        end
        t:eq(store.calls.list + store.calls.read + store.calls.save, before,
            "painting a view does not touch the database")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / adding and forgetting")

    --[[--
    `count` is read on every paint of the export menu, so it answers from the
    list rather than walking the map (ADR-42). That is only correct while the
    list and the map hold the same ids, which is what this states across every
    path that changes either.
    ]]
    t:case("count is the number of known canvases through batches, add and forget", function()
        local index, doc, _, sched = fixture(20, { batch = 3 })
        local function mapped()
            local n = 0
            for _ in pairs(index.by_id) do n = n + 1 end
            return n
        end
        index:open()
        t:eq(index:count(), mapped(), "during the metadata phase")
        sched:drain()
        t:eq(index:count(), mapped(), "after the load")
        t:eq(index:count(), 20, "which is every row of the book")
        doc.pages["/p99"] = 9
        index:add({ id = 99, anchor_kind = "xpointer",
                    anchor_raw = "/p99", anchor_normalized = "/p99" }, 9)
        t:eq(index:count(), mapped(), "after an add")
        t:eq(index:count(), 21, "one more")
        index:add({ id = 99, anchor_kind = "xpointer",
                    anchor_raw = "/p99", anchor_normalized = "/p99" }, 9)
        t:eq(index:count(), 21, "and a repeat of it adds nothing")
        index:forget(99)
        t:eq(index:count(), mapped(), "after a forget")
        t:eq(index:count(), 20, "back to the book's own rows")
    end)

    --[[--
    A second `open` empties the list and the map, and the resolve batches of
    the first are still in the scheduler. They check the generation they were
    built under -- but a reopen is not a rebuild, so `generation` is unchanged
    and only the load generation tells them their list is gone.
    ]]
    t:case("reopening retires the resolve batches of the previous open", function()
        local index, doc, _, sched = fixture(20, { batch = 2 })
        index:open()
        sched:drain()
        t:eq(index:isComplete(), true, "the first build finished")
        local resolutions = doc.resolutions

        -- Reopen and let it run to the end: nothing from the first build may
        -- finalise against the list this one is rereading.
        index:open()
        sched:drain()
        t:eq(index:isComplete(), true, "the second build finished too")
        t:eq(index:count(), 20, "with every row of the book, once")
        for id = 1, 20 do
            t:eq(index:pageOf(id), id, "canvas " .. id .. " placed once, on its own page")
        end
        t:check(doc.resolutions >= resolutions, "and it did its own resolving")
    end)

    t:case("a new canvas is placed straight away", function()
        local index, doc, _, sched = fixture(3)
        index:open()
        sched:drain()
        doc.pages["/p9"] = 9
        index:add({ id = 9, anchor_kind = "xpointer",
                    anchor_raw = "/p9", anchor_normalized = "/p9" }, 9)
        t:eq(index:pageOf(9), 9, "on the page it was made on")
        doc.current_page = 9
        t:eq(#index:visibleCanvases(9), 1, "and it shows up there")
    end)

    t:case("a new canvas with no page given is resolved once", function()
        local index, doc, _, sched = fixture(3)
        index:open()
        sched:drain()
        doc.pages["/p9"] = 9
        local before = doc.resolutions
        index:add({ id = 9, anchor_kind = "xpointer",
                    anchor_raw = "/p9", anchor_normalized = "/p9" })
        t:eq(doc.resolutions, before + 1, "exactly one resolution, not a rebuild")
        t:eq(index:pageOf(9), 9, "and it lands in the right place")
    end)

    t:case("adding the same canvas twice does not duplicate it", function()
        local index, _, _, sched = fixture(3)
        index:open()
        sched:drain()
        local canvas = { id = 1, anchor_raw = "/p1", anchor_normalized = "/p1" }
        index:add(canvas, 1)
        t:eq(#index:visibleCanvases(1), 1, "still one")
    end)

    t:case("a deleted canvas is gone from every index", function()
        local index, doc, _, sched = fixture(3)
        index:open()
        sched:drain()
        index:forget(2)
        t:eq(index:pageOf(2), nil, "no page")
        t:eq(index:get(2), nil, "no metadata")
        doc.current_page = 2
        t:eq(#index:visibleCanvases(2), 0, "and it cannot come back out of a lookup")
    end)

    t:case("forgetting an orphan takes it off the orphan list too", function()
        local index, doc, _, sched = fixture(3)
        doc.pages["/p2"] = nil
        index:open()
        sched:drain()
        t:eq(#index:orphanIds(), 1, "one orphan to start with")
        index:forget(2)
        t:eq(#index:orphanIds(), 0, "and none after it is deleted")
    end)

    -- =================================================================
    t:describe("ink_anchor_index / relayout")

    t:case("a rerender rebuilds the index against the new layout", function()
        local index, doc, store, sched = fixture(10, { batch = 20 })
        index:open()
        sched:drain()
        t:eq(index:isComplete(), true, "built once")

        doc.hash = "layout-b"
        for i = 1, 10 do doc.pages["/p" .. i] = i + 100 end
        index:invalidate()
        t:eq(index:isComplete(), false, "and immediately out of date")
        sched:drain()
        t:eq(index:pageOf(3), 103, "rebuilt against where the text is now")
        t:eq(store.saves[#store.saves].hash, "layout-b", "cached under the new layout")
    end)

    t:case("the old layout's cache is still there to come back to", function()
        local index, doc, store, sched = fixture(5, { batch = 20 })
        index:open()
        sched:drain()
        doc.hash = "layout-b"
        index:invalidate()
        sched:drain()
        t:check(store.layouts["layout-a"] ~= nil,
            "going back to the previous font size does not mean rebuilding")
    end)

    t:case("a rerender in the middle of a build does not mix the two", function()
        local index, doc, store, sched = fixture(20, { batch = 5 })
        index:open()
        sched:tick()
        doc.hash = "layout-b"
        for i = 1, 20 do doc.pages["/p" .. i] = i + 100 end
        index:invalidate()
        sched:drain()
        t:eq(index:pageOf(3), 103, "every placement is from the new layout")
        local old_finalized = false
        for _, save in ipairs(store.saves) do
            if save.hash == "layout-a" and save.finalize then old_finalized = true end
        end
        t:eq(old_finalized, false,
            "the abandoned generation may leave safe partial rows but never prunes")
        t:eq(store.layouts["layout-b"][3], 103,
            "the new generation still completes independently")
    end)

    t:case("a rerender while the list is loading waits for the list", function()
        -- Resolving the half that has arrived would put those anchors to
        -- CREngine and then put them to it again with the rest.
        local index, doc, store, sched = fixture(450)
        index:open()
        sched:tick()
        doc.hash = "layout-b"
        for i = 1, 450 do doc.pages["/p" .. i] = i + 100 end
        index:invalidate()
        t:eq(doc.resolutions, 0, "nothing is resolved from a partial list")
        t:eq(index:phase(), "metadata", "and loading carries on")

        sched:drain()
        t:eq(index.generation, 1, "one rebuild, not one per invalidation")
        t:eq(index:pageOf(3), 103, "against the layout that is current when it runs")
        t:eq(store.layouts["layout-a"], nil, "and nothing was cached under the old one")
    end)

    t:case("cancelling stops the build", function()
        local index, doc, _, sched = fixture(50, { batch = 5 })
        loadMetadata(index, sched)
        sched:tick()
        local resolved = doc.resolutions
        t:eq(resolved, 5, "one batch got through first")
        index:cancel()
        sched:drain()
        t:eq(doc.resolutions, resolved, "no further work after teardown")
    end)

    t:case("a cancelled index never finalizes its partial layout", function()
        local index, _, store, sched = fixture(50, { batch = 5 })
        loadMetadata(index, sched)
        sched:tick()
        index:cancel()
        sched:drain()
        t:eq(store.calls.save, 1, "the completed first batch is safe derived data")
        t:eq(store.saves[1].finalize, false, "but it cannot prune completed layouts")
    end)
end
