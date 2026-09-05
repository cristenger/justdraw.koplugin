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
            visible = opts.visible,
        }
        local store = support.newCanvasStore(opts.canvases or {})
        if opts.read_only then
            store.read_only = true
            function store:findBookId(partial_md5, file_size)
                if not partial_md5 or not file_size then return nil, "no_identity" end
                if opts.read_only_empty then return nil, "not_found" end
                return 12
            end
        end
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
            plugin = { drawing = false, eraser = false, pen_width = 4,
                       effectiveStyle = function() return 1 end,
                       setDrawing = function() end, setEraser = function() end,
                       onJustDrawUndo = function() end, setBarShown = function() end },
            ui = below,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
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

    t:case("an owned repository is closed when identity lookup fails", function()
        local session, store = fixture{ identity = false }
        session.owns_repository = true
        local ok = session:open()
        t:eq(ok, nil, "opening is refused")
        t:eq(store.closed, true, "the connection opened for this session is closed")
        t:eq(session.repository, nil, "and no unreachable handle is retained")
    end)

    t:case("no database means the feature is off, not a crash", function()
        local session = fixture{ repository = false }
        local ok, err = session:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "no_repository", "reported")
        t:eq(session:isAvailable(), false, "and every entry point checks this")
    end)

    t:case("two renamed databases fail closed instead of hiding sheets", function()
        local session, _, _, _, notes = fixture()
        session.repository = nil
        session._databasePath = function()
            return nil, "database_conflict",
                "/settings/justdraw.sqlite3", "/settings/fingerink.sqlite3"
        end
        local ok, err = session:open()
        t:eq(ok, nil, "opening is refused")
        t:eq(err, "database_conflict", "specific conflict is preserved")
        t:eq(session:isAvailable(), false, "sheet entry points remain disabled")
        t:check(notes[1] and notes[1]:find("Both JustDraw and FingerInk", 1, true),
            "the reader gets an actionable explanation")
    end)

    t:case("nothing at all happens on a book with no canvases", function()
        local session, store = fixture()
        session:open()
        t:eq(#session:canvasesHere(1), 0, "none here")
        t:eq(store.calls.stroke_list, 0, "and no canvas was opened behind our back")
    end)

    t:case("a canvas listing failure is unavailable, not an empty book", function()
        -- The failure now arrives a tick later, through the index's on_error,
        -- and has to end in exactly the state the synchronous one did.
        local session, store, sched, _, notes = fixture{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session.owns_repository = true
        t:eq(session:open(), true, "opening returns before a row has been read")
        store.fail_list_canvases = "disk read failed"
        sched:drain()
        t:eq(session:isAvailable(), false, "the feature did not claim an empty index")
        t:eq(session:isIndexing(), false, "and it is not still pretending to build")
        t:eq(#notes, 1, "the reader was told, once")
        t:check(notes[1]:find("Could not list", 1, true), "which sheets are missing")
        t:eq(store.closed, true, "the connection this session opened is closed")
        sched:drain()
        t:eq(#notes, 1, "and nothing says it again")
    end)

    t:case("a count that fails is refused at the call site", function()
        -- The one query the index still makes synchronously.
        local session, store, _, _, notes = fixture()
        store.fail_count_canvases = "disk read failed"
        local ok = session:open()
        t:eq(ok, nil, "opening failed")
        t:eq(session:isAvailable(), false, "with the feature off for this book")
        t:check(#notes > 0, "and the reader told")
    end)

    t:case("opening returns before the index has read anything", function()
        local session, store, sched = fixture{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        t:eq(session:open(), true, "ReaderReady is not blocked on the listing")
        t:eq(store.calls.list, 0, "not one row read yet")
        t:eq(session:isIndexing(), true, "the work is still ahead")
        sched:drain()
        t:eq(session:isIndexing(), false, "and behind, a few ticks later")
    end)

    t:case("the session reports what the index has got through", function()
        local session, _, sched = fixture{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 }, batch = 1,
        }
        t:eq(session:indexProgress(), nil, "nothing to report before opening")
        session:open()
        local progress = session:indexProgress()
        t:eq(progress.phase, "metadata", "the phase")
        t:eq(progress.loaded, 0, "what is loaded")
        t:eq(progress.total, 1, "what there is to load")
        sched:drain()
        t:eq(session:indexProgress().phase, "ready", "and when it is done")
        t:eq(session:indexProgress().loaded, 1, "with everything loaded")
    end)

    t:case("a future schema can be browsed without creating a write queue", function()
        local session, _, sched = fixture{
            read_only = true,
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        t:eq(session:isWritable(), false, "session is read-only")
        local overlay = session:openCanvas(session:canvasById(1))
        sched:drain()
        t:check(overlay ~= nil, "existing sheet is visible")
        local _, err = session:addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        t:eq(err, "read_only", "no queue exists to accept writes")
        local _, undo_err = session:undo()
        t:eq(undo_err, "read_only", "undo is also refused")
    end)

    t:case("an unknown book in a future schema stays empty without an insert", function()
        local session, store = fixture{ read_only = true, read_only_empty = true }
        t:eq(session:open(), true, "read-only empty session opens")
        t:eq(session:isWritable(), false, "but cannot create")
        t:eq(store.calls.book, 0, "bookId was never called")
        t:eq(#session:canvasesHere(1), 0, "there is nothing to browse")
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

    t:case("index completion refreshes marks for the page already on screen", function()
        local session, _, sched, doc = fixture{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 }, batch = 1,
        }
        session:open()
        doc.current_page = 3
        session:setPage(3)
        t:eq(#session:marks(), 0, "the unfinished index has no candidate yet")
        sched:drain()
        t:eq(#session:marks(), 1, "completion recomputes the current page")
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

    t:case("creating leaves visible ownership to the caller", function()
        local session, _, sched, doc = fixture{
            here = "/p1", pages = { ["/p1"] = 3 },
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        local canvas = session:createHere(3)
        t:eq(session:activeCanvas(), nil, "data creation does not mutate visible UI")
        t:eq(session:openCanvas(canvas) ~= nil, true, "the coordinator can open it")
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

    --[[--
    A sheet with no strokes finishes its raster inside `SurfaceSession:open()`,
    which runs before `overlay_widget` is assigned -- so the `on_ready` that
    would otherwise ask for the panel is dropped by the guard that tests for
    the widget. The show is the only thing left that can ask, and a show with
    no refresh type enqueues none (pinned in tests/conformance.lua). On the
    device that left the reader looking at the page under a sheet the
    framebuffer already held (ADR-43).
    ]]
    t:case("an empty canvas is shown with a refresh, not only a repaint", function()
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        local before = #env.UIManager.dirty
        local overlay = session:openCanvas(session:canvasById(1))
        t:check(overlay ~= nil, "the canvas opened")
        t:eq(session:cache():isReady(), true,
            "and its raster was finished before the widget existed")
        local asked = nil
        for i = before + 1, #env.UIManager.dirty do
            local d = env.UIManager.dirty[i]
            if d[1] == overlay and d[2] ~= nil then asked = d end
        end
        t:check(asked ~= nil, "the overlay asked the panel for itself")
        t:eq(asked[2], "ui", "through the grayscale pass")
        t:eq(asked[3], nil, "over the whole widget, not a region of it")
        sched:drain()
    end)

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

    t:case("a sheet that was written to is marked as recently used", function()
        -- listCanvases orders by updated_at, which is what makes the chooser
        -- put the sheet the reader last wrote in at the top.
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        store.touched = nil
        store.touchCanvas = function(self, id) self.touched = id end
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        session:closeCanvas()
        t:eq(store.touched, 1, "touched on the way out")
    end)

    t:case("a sheet that was only looked at is left alone", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        store.touched = nil
        store.touchCanvas = function(self, id) self.touched = id end
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:closeCanvas()
        t:eq(store.touched, nil, "opening a sheet is not using it")
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

    t:case("a failed flush aborts a canvas switch and preserves the first sheet", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/p2") },
            pages = { ["/p1"] = 3, ["/p2"] = 9 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "begin"
        local overlay = session:overlay()
        local opened, err = session:openCanvas(session:canvasById(2))
        t:eq(opened, nil, "switch refused")
        t:check(err ~= nil, "with the write failure")
        t:eq(session:activeCanvas().id, 1, "the original canvas stays active")
        t:eq(session:overlay(), overlay, "and its window stays alive")
        t:eq(session:pendingWrites(), 1, "with its work recoverable")
    end)

    t:case("retry loading makes pending edits durable before rebuilding", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        t:check(session:addStroke({ 10, 10, 40, 10 }, 2, 4, 1) < 0,
            "the new stroke starts only in memory")
        t:eq(session:pendingWrites(), 1, "one pending insert")
        session:cache():_fail("injected repair read failure")
        t:eq(session:retryLoad(), true, "retry accepted")
        t:eq(session:pendingWrites(), 0, "the queue committed before the reload")
        sched:drain()
        t:eq(session:cache():isReady(), true, "the rebuilt raster is valid")
        t:eq(#store.strokes[1], 1, "the pending stroke survived on disk")
        t:eq(#session:cache():strokes(), 1, "and appears in cache exactly once")
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

    t:case("canvas addStroke propagates live token and fallback scalars", function()
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        local cache = session:cache()
        local _, raster_cache, raster_generation =
            cache:drawSegment(10, 10, 20, 20, 4)
        local before = #cache:buffer().writes
        local id, err, painted, left, top, right, bottom = session:addStroke(
            { 10, 10, 20, 20 }, 2, 4, 1, {
                raster_cache = raster_cache,
                raster_generation = raster_generation,
                live_raster_complete = true,
            })
        t:check(id ~= nil, "the compatible first return remains the id")
        t:eq(err, nil, "second return remains the error slot")
        t:eq(painted, false, "matching token reports no fallback paint")
        t:eq(left, nil, "no fallback left")
        t:eq(top, nil, "no fallback top")
        t:eq(right, nil, "no fallback right")
        t:eq(bottom, nil, "no fallback bottom")
        t:eq(#cache:buffer().writes, before, "registration did not repaint")
    end)

    t:case("draw flush erase flush cannot resurrect a session stroke", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        local local_id = session:addStroke({ 10, 10, 40, 10 }, 2, 4, 1)
        t:check(local_id < 0, "pending identity")
        session:flush()
        local durable = session:cache():strokes()[1].id
        t:check(durable > 0, "cache adopted the SQLite identity")
        t:check(session:eraseAt(25, 10, 2) ~= nil, "the flushed stroke is erasable")
        session:flush()
        t:eq(#store.strokes[1], 0, "and remains deleted on disk")
    end)

    t:case("a stroke loaded from disk can be undone without Queue.real", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        store:putStroke(1, { seq = 5, width = 4, tool = 1,
            points = { 10, 10, 40, 10 }, n = 2 })
        session:openCanvas(session:canvasById(1))
        sched:drain()
        t:check(session:undo() ~= nil, "undo accepted the positive row id")
        session:flush()
        t:eq(#store.strokes[1], 0, "the persisted row was deleted")
    end)

    t:case("undo then draw never reuses a sequence still present on disk", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        store:putStroke(1, { seq = 9, width = 4, tool = 1,
            points = { 10, 10, 40, 10 }, n = 2 })
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:undo()
        session:addStroke({ 50, 50, 80, 50 }, 2, 4, 1)
        session:flush()
        t:eq(store.strokes[1][1].seq, 10, "monotonic after the pending delete")
    end)

    t:case("undoing the last stroke removes it from the canvas", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:check(session:undo() ~= nil, "undone")
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
        t:eq(session:undo(), nil, "nothing happened")
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

    t:case("a failed active delete preserves the canvas and pending ink", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_delete_canvas = "disk full"
        local overlay = session:overlay()
        local ok = session:deleteCanvas(session:canvasById(1))
        t:eq(ok, nil, "delete refused")
        t:eq(session:activeCanvas().id, 1, "canvas remains active")
        t:eq(session:overlay(), overlay, "window remains")
        t:eq(session:pendingWrites(), 1, "pending stroke was not discarded")
    end)

    t:case("a stroke-list failure opens a fail-closed sheet that can retry", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        store.fail_stroke_list = "corrupt page"
        local overlay = session:openCanvas(session:canvasById(1))
        t:check(overlay ~= nil, "the recovery surface stays visible")
        t:eq(session:activeCanvas().id, 1, "the target remains active")
        t:eq(session:loadFailed(), true, "the blank surface is explicitly failed")
        store.fail_stroke_list = nil
        t:eq(session:retryLoad(), true, "retry starts a fresh read")
        sched:drain()
        t:eq(session:cache():isReady(), true, "and recovers the sheet")
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

    t:case("a failed interactive close keeps every retry resource alive", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "begin"
        local cache, overlay = session:cache(), session:overlay()
        local ok = session:closeCanvas()
        t:eq(ok, nil, "close refused")
        t:eq(session:cache(), cache, "cache retained")
        t:eq(session:overlay(), overlay, "overlay retained")
        t:eq(session:activeCanvas().id, 1, "canvas retained")
        t:eq(session:pendingWrites(), 1, "queue retained")
    end)

    t:case("a failed save can be retried, and says so when it works", function()
        local session, store, sched, _, notes = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "begin"
        session:flush()
        t:eq(session:saveFailed(), true, "stuck, and it knows")

        store.fail_transaction = nil
        local before = #notes
        t:eq(session:retrySave(), true, "the retry works")
        t:eq(session:saveFailed(), false, "and it is unstuck")
        t:eq(#store.strokes[1], 1, "the stroke is durable now")
        t:check(#notes > before, "and the reader is told it worked")
    end)

    t:case("a retry that fails again leaves the ink in hand", function()
        local session, store, sched = openedSession{
            canvases = { canvasAt(1, "/p1") }, pages = { ["/p1"] = 3 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "begin"
        session:flush()
        session:retrySave()
        t:eq(session:saveFailed(), true, "still stuck")
        t:eq(session:pendingWrites(), 1, "and still holding the work")
    end)

    t:case("turning a page does not change which sheet is open", function()
        -- Reading elsewhere while writing is the point of pinning the sheet.
        local session, _, sched = openedSession{
            canvases = { canvasAt(1, "/p1"), canvasAt(2, "/p2") },
            pages = { ["/p1"] = 3, ["/p2"] = 9 },
        }
        session:openCanvas(session:canvasById(1))
        sched:drain()
        session:setPage(9)
        t:eq(session:activeCanvas().id, 1, "the sheet stays put")
    end)

    t:case("closing twice is harmless", function()
        local session = openedSession()
        session:close()
        session:close()
        t:eq(session:isAvailable(), false, "still shut")
    end)

    -- =================================================================
    t:describe("canvas session / where the open sheet hangs")

    --- A session with one sheet anchored at `/p1`, which lives on page 3.
    local function placed(opts)
        opts = opts or {}
        local session, store, sched, doc, notes = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 3, ["/body/p[1]"] = 3 },
            visible = opts.visible,
        }
        session:open()
        sched:drain()
        doc.current_page = 3
        session:setPage(3)
        if not opts.closed then
            session:openCanvas(session:canvasById(1))
            sched:drain()
        end
        return session, store, sched, doc, notes
    end

    t:case("no sheet open, nothing placed", function()
        local session = placed{ closed = true }
        local placement, page = session:openCanvasPlacement()
        t:eq(placement, nil, "there is nothing to place")
        t:eq(page, nil, "and no page to name")
    end)

    t:case("an open sheet on the page being read is here", function()
        local session = placed()
        local placement, page = session:openCanvasPlacement()
        t:eq(placement, "here", "the anchor is on this page")
        t:eq(page, nil, "which needs no number")
    end)

    t:case("turning off its page makes it away, and names the page", function()
        local session, _, _, doc = placed()
        doc.current_page = 5
        session:setPage(5)
        local placement, page = session:openCanvasPlacement()
        t:eq(placement, "away", "the reader has left the anchor behind")
        t:eq(page, 3, "and the sheet says where it belongs")
    end)

    t:case("coming back makes it here again", function()
        local session, _, _, doc = placed()
        doc.current_page = 5
        session:setPage(5)
        doc.current_page = 3
        session:setPage(3)
        t:eq(session:openCanvasPlacement(), "here", "back where it hangs")
    end)

    t:case("either page of a visible spread counts as here", function()
        local session, _, _, doc = placed{ visible = 2 }
        doc.current_page = 2               -- pages 2 and 3 are visible
        session:setPage(2)
        t:eq(session:openCanvasPlacement(), "here",
            "the anchor on page 3 is inside the current viewport")
    end)

    t:case("an anchor the document no longer knows is lost, not away", function()
        local session, _, _, doc = placed()
        doc.pages["/p1"] = nil       -- the text it hung on is gone
        doc.current_page = 5
        session:setPage(5)
        local placement, page = session:openCanvasPlacement()
        t:eq(placement, "lost", "there is no page to go back to")
        t:eq(page, nil, "so there is no number to give")
    end)

    t:case("closing the sheet unplaces it", function()
        local session = placed()
        session:closeCanvas()
        t:eq(session:openCanvasPlacement(), nil, "nothing open, nothing placed")
    end)

    t:case("a forced session close also clears placement", function()
        local session = placed()
        session.closeCanvas = function() return nil, "cannot commit" end
        local ok = session:close{ force = true }
        t:eq(ok, nil, "the durable close still reports its failure")
        t:eq(session:openCanvasPlacement(), nil,
            "forced teardown cannot leave a placed canvas behind")
    end)

    t:case("an index failure clears placement", function()
        local session = placed()
        session:_indexFailed("probe")
        t:eq(session:openCanvasPlacement(), nil,
            "an unavailable session cannot report an authoritative place")
    end)

    t:case("the anchor is available for navigating back to", function()
        local session, _, _, doc = placed()
        doc.current_page = 5
        session:setPage(5)
        t:eq(session:openCanvasAnchor(), "/p1", "the pointer the sheet hangs on")
    end)

    t:case("a page turn with no sheet open asks the document nothing extra", function()
        -- The index's guarantee: turning a page in an annotated book costs
        -- what turning one in a plain book costs (ADR-42). Placing the open
        -- sheet must not be paid for by a reader who has none open.
        local session, _, _, doc = placed{ closed = true }
        doc.current_page = 9
        local checks, resolved = doc.in_page_checks, doc.resolutions
        session:setPage(9)
        t:eq(doc.in_page_checks, checks, "no in-page check")
        t:eq(doc.resolutions, resolved, "and no page resolution")
    end)

    t:case("placing the open sheet costs one in-page check and no resolution", function()
        local session, _, _, doc = placed()
        doc.current_page = 9
        local checks, resolved = doc.in_page_checks, doc.resolutions
        session:setPage(9)
        t:eq(doc.in_page_checks - checks, 1, "exactly one, for the open sheet")
        t:eq(doc.resolutions, resolved,
            "and the page number comes from the index, not from CREngine")
    end)

    t:case("an invalid destination does not close the active sheet", function()
        local session, _, sched = fixture{
            canvases = { canvasAt(1, "/p1") },
            pages = { ["/p1"] = 1 },
        }
        session:open()
        sched:drain()
        session:openCanvas(session:canvasById(1))
        sched:drain()
        local old_canvas = session:activeCanvas()
        local old_overlay = session:overlay()
        local bad = canvasAt(2, "/p2")
        bad.logical_w = 0
        local opened, err = session:openCanvas(bad)
        t:eq(opened, nil, "bad geometry was refused")
        t:eq(err, "bad_geometry", "with the specific reason")
        t:eq(session:activeCanvas(), old_canvas, "the source stayed active")
        t:eq(session:overlay(), old_overlay, "and its window stayed alive")
    end)
end
