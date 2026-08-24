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
        local index = Index.new{
            repository = store,
            document = doc,
            book_id = 12,
            batch = opts.batch or 8,
            schedule = function(fn) sched:schedule(fn) end,
        }
        return index, doc, store, sched
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
        index:open()
        t:eq(doc.resolutions, 0, "opening resolves nothing by itself")
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

    t:case("the derived pages are written once, when the index completes", function()
        local index, _, store, sched = fixture(20, { batch = 5 })
        index:open()
        sched:tick()
        t:eq(store.calls.save, 0, "nothing is written halfway")
        sched:drain()
        t:eq(store.calls.save, 1, "one write at the end")
        t:eq(store.saves[1].hash, "layout-a", "against the layout it describes")
        t:eq(store.saves[1].pages[7], 7, "carrying the resolved pages")
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

    t:case("a book with no canvases is complete straight away", function()
        local index, _, store, sched = fixture(0)
        index:open()
        t:eq(index:isComplete(), true, "nothing to do")
        sched:drain()
        t:eq(store.calls.save, 0, "and nothing written")
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
        for _, save in ipairs(store.saves) do
            if save.hash == "layout-a" then
                t:check(false, "a half-built old index was written")
                return
            end
        end
        t:check(true, "and the abandoned index was never written")
    end)

    t:case("cancelling stops the build", function()
        local index, doc, _, sched = fixture(50, { batch = 5 })
        index:open()
        sched:tick()
        local resolved = doc.resolutions
        index:cancel()
        sched:drain()
        t:eq(doc.resolutions, resolved, "no further work after teardown")
    end)

    t:case("a cancelled index does not write a partial layout", function()
        local index, _, store, sched = fixture(50, { batch = 5 })
        index:open()
        sched:tick()
        index:cancel()
        sched:drain()
        t:eq(store.calls.save, 0, "half an index is worse than none")
    end)
end
