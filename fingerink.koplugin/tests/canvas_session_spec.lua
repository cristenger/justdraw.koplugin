--[[--
The canvas session: everything that has to be true for one book at a time.

This is the coordinating module, so most of what is checked here is ordering
and refusal rather than computation. The two that matter most:

A canvas is never created while the page index is still being built. The index
is what knows whether a canvas already exists at this position; creating one
before it has finished is how a reader ends up with two sheets on one paragraph
and no way to tell which holds their notes.

And a canvas is never swapped out without its queue being flushed first.
Loading the next canvas frees the raster and the metadata of the last one, so
anything still pending would have nowhere left to come from.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Session = require("ink_canvas_session")

    local Screen = env.Device.screen

    local IDENTITY = { partial_md5 = "abc123", file_size = 90210 }

    local function fixture(opts)
        opts = opts or {}
        env.UIManager._window_stack = {}
        env.UIManager.dirty = {}
        env.notifications = {}
        _G.G_reader_settings.data = {}

        local below = { handleEvent = function() return true end }
        env.UIManager:show(below)

        local pages = opts.pages or {}
        local doc = support.newDocument{
            pages = pages,
            here = opts.here or "/body/p[1]",
            hash = opts.hash,
        }
        local store = support.newCanvasStore(opts.canvases or {})
        local sched = support.newScheduler()
        local notes = {}

        -- `x == false and false or store` collapses to `store`, which is how
        -- a "no database" case quietly tests the opposite of itself.
        local repository = store
        if opts.repository == false then repository = false end

        local session = Session.new{
            document = doc,
            identity = opts.identity == false and {} or IDENTITY,
            file = "/mnt/us/documents/book.epub",
            dom_version = 20240114,
            repository = repository,
            plugin = { drawing = false, eraser = false,
                       setDrawing = function() end, setEraser = function() end,
                       onFingerInkUndo = function() end, setBarShown = function() end },
            ui = below,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(_, fn) sched:schedule(fn) end,
            unschedule = function() end,
            notify = function(text) notes[#notes + 1] = text end,
            batch = opts.batch or 32,
        }
        return session, store, sched, doc, notes
    end

    --- A canvas row anchored at `xp`, as the repository would return it.
    local function canvasAt(id, xp)
        return {
            id = id,
            anchor_kind = "xpointer",
            anchor_key = "xp:" .. xp,
            anchor_raw = xp,
            anchor_normalized = xp,
            anchor_dom_version = 20240114,
            logical_w = Screen.w,
            logical_h = Screen.h,
        }
    end

    -- =================================================================
    t:describe("ink_canvas_session / opening a book")

    t:case("the book is identified by checksum and size", function()
        local session, store = fixture()
        t:eq(session:open(), true, "opened")
        t:eq(store.identity[1], "abc123", "checksum")
        t:eq(store.identity[2], 90210, "size")
    end)

    t:case("opening loads anchors and no points", function()
        local session, store, sched = fixture{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/p2") },
            pages = { ["/p1"] = 3, ["/p2"] = 9 },
        }
        session:open()
        sched:drain()
        t:eq(store.calls.list, 1, "one metadata query")
        t:eq(store.calls.stroke_read, 0, "and not a point decoded")
    end)

    t:case("a book with no usable identity leaves canvases unavailable", function()
        local session, _, _, _, notes = fixture{ identity = false }
        local ok, err = session:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "no_identity", "with a reason")
        t:eq(session:isAvailable(), false, "and the feature is off for this book")
        t:eq(#notes, 1, "the reader is told, once")
    end)

    t:case("no database means the feature is off, not a crash", function()
        local session = fixture{ repository = false }
        local ok, err = session:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "no_repository", "reported")
        t:eq(session:isAvailable(), false, "and every entry point checks this")
    end)

    t:case("nothing at all happens on a book with no canvases", function()
        local session, store = fixture()
        session:open()
        t:eq(#session:canvasesHere(1), 0, "none here")
        t:eq(store.calls.stroke_list, 0, "and no canvas was opened behind our back")
    end)

    -- =================================================================
    t:describe("ink_canvas_session / finding canvases")

    t:case("the canvases on this page are the ones the document confirms", function()
        local session, _, sched, doc = fixture{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/p2") },
            pages = { ["/p1"] = 3, ["/p2"] = 9 },
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local here = session:canvasesHere(3)
        t:eq(#here, 1, "one")
        t:eq(here[1].id, 1, "the one anchored on this page")
    end)

    t:case("marks are precomputed, so painting costs nothing", function()
        local session, store, sched, doc = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        session:setPage(3)
        local queries = store.calls.list + store.calls.read
        local checks = doc.in_page_checks
        local marks = session:marks()
        t:eq(#marks, 1, "one mark to draw")
        t:check(marks[1].y ~= nil, "with a place to draw it")
        t:eq(store.calls.list + store.calls.read, queries, "reading it issues no query")
        t:eq(doc.in_page_checks, checks, "and asks the document nothing")
    end)

    t:case("a page with no canvases has no marks", function()
        local session, _, sched, doc = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        doc.current_page = 7
        session:setPage(7)
        t:eq(#session:marks(), 0, "nothing to draw")
    end)

    t:case("orphaned canvases are listed, not deleted", function()
        local session, store, sched = fixture{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/gone") },
            pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        t:eq(#session:orphans(), 1, "one orphan")
        t:eq(session:orphans()[1].id, 2, "the one whose anchor vanished")
        t:eq(#store.canvases, 2, "and both rows are still there")
    end)

    -- =================================================================
    t:describe("ink_canvas_session / creating")

    t:case("creating anchors a canvas at the current position", function()
        local session, store, sched, doc = fixture{
            here = "/body/p[7]", pages = { ["/body/p[7]"] = 3 },
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local canvas = session:createHere(3)
        t:check(canvas ~= nil, "created")
        t:eq(store.canvases[1].anchor_key, "xp:/body/p[7]", "at the position it was made")
        t:eq(store.canvases[1].logical_w, Screen.w, "with the geometry it was born with")
    end)

    t:case("creating opens the new canvas straight away", function()
        local session, _, sched, doc = fixture{
            here = "/p1", pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local canvas = session:createHere(3)
        t:eq(session:activeCanvas(), canvas, "it is the open one")
    end)

    t:case("creating is refused while the page index is still building", function()
        -- Otherwise a reader taps twice on a heavily annotated book and gets a
        -- second sheet on a paragraph that already had one.
        local session, store, _, doc = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 3 },
            here = "/p1",
        }
        session:open()
        doc.current_page = 3
        local canvas, err = session:createHere(3)
        t:eq(canvas, nil, "refused")
        t:eq(err, "indexing", "with something the UI can say")
        t:eq(#store.canvases, 1, "and nothing was created")
    end)

    t:case("creating where one already exists opens that one instead", function()
        local session, store, sched, doc = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 3 },
            here = "/p1",
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local canvas = session:createHere(3)
        t:eq(canvas.id, 1, "the existing one")
        t:eq(#store.canvases, 1, "no second sheet on the same paragraph")
    end)

    t:case("a position with no anchor does not become a canvas", function()
        local session, store, sched, doc = fixture{
            here = "/nowhere", pages = {},
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local canvas, err = session:createHere(3)
        t:eq(canvas, nil, "refused")
        t:eq(err, "not_in_document", "the document would not vouch for the position")
        t:eq(#store.canvases, 0, "nothing written")
    end)

    -- =================================================================
    t:describe("ink_canvas_session / opening and closing a canvas")

    local function openedSession(opts)
        local session, store, sched, doc, notes = fixture(opts)
        session:open()
        sched:drain()
        return session, store, sched, doc, notes
    end

    t:case("opening a canvas puts up exactly one window", function()
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        local ours = 0
        for _, e in ipairs(env.UIManager._window_stack) do
            if e.widget == session:overlay() then ours = ours + 1 end
        end
        t:eq(ours, 1, "one overlay, no separate toolbar window")
    end)

    t:case("closing a canvas releases its raster", function()
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        local bb = session:cache():buffer()
        session:closeCanvas()
        t:eq(bb.freed, true, "freed")
        t:eq(session:activeCanvas(), nil, "and nothing is open")
        t:eq(session:overlay(), nil, "with the window gone")
    end)

    t:case("switching canvases flushes the first one before loading the second", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/p2") },
            pages = { ["/p1"] = 3, ["/p2"] = 9 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(session:pendingWrites(), 1, "one stroke waiting")
        session:openCanvas(session:canvasById(2))
        sched:drain()
        t:eq(session:pendingWrites(), 0, "written before the swap")
        t:eq(#store.strokes[1], 1, "against the canvas it was drawn on")
    end)

    t:case("a stroke is written to the canvas it was drawn on", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        session:flush()
        t:eq(#store.strokes[1], 1, "one stroke")
        t:eq(store.strokes[1][1].width, 4, "with its width")
    end)

    t:case("undoing the last stroke removes it from the canvas", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(session:undo(), true, "undone")
        session:flush()
        t:eq(store.strokes[1] == nil or #store.strokes[1] == 0, true,
            "and it never reached the disk")
    end)

    t:case("undo with nothing to undo says so", function()
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        t:eq(session:undo(), false, "nothing happened")
    end)

    t:case("deleting a canvas closes it and takes its strokes with it", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        session:deleteCanvas(session:canvasById(1))
        t:eq(session:activeCanvas(), nil, "closed")
        t:eq(#store.canvases, 0, "and gone")
        t:eq(session:pendingWrites(), 0, "with nothing queued against a dead row")
    end)

    -- =================================================================
    t:describe("ink_canvas_session / relayout and shutdown")

    t:case("a rerender rebuilds the index and touches no stroke", function()
        local session, store, sched, doc = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        local reads = store.calls.stroke_read
        doc.hash = "layout-b"
        doc.pages["/p1"] = 40
        session:invalidate()
        sched:drain()
        t:eq(store.calls.stroke_read, reads, "no ink was re-read")
        doc.current_page = 40
        t:eq(#session:canvasesHere(40), 1, "and the canvas is where the text went")
    end)

    t:case("saving settings flushes whatever is pending", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        session:flush()
        t:eq(#store.strokes[1], 1, "durable before the process can go away")
    end)

    t:case("closing the book closes the canvas and the database", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        session:close()
        t:eq(#store.strokes[1], 1, "the last strokes were written")
        t:eq(store.closed, true, "the connection is closed")
        t:eq(session:activeCanvas(), nil, "and nothing is left open")
    end)

    t:case("a failed save is said out loud rather than swallowed", function()
        local session, store, sched, _, notes = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "begin"
        session:flush()
        t:check(#notes > 0, "the reader is told the ink is not saved")
        t:eq(session:pendingWrites(), 1, "and the work is still in hand")
    end)

    t:case("closing twice is harmless", function()
        local session = openedSession()
        session:close()
        session:close()
        t:eq(session:isAvailable(), false, "still shut")
    end)
end
