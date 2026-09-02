--[[--
The page-ink session: one page of a fixed-layout document at a time.

This is a coordinating module, so nearly everything checked here is an
ordering or a refusal rather than a computation. Four of them carry the
feature:

The queue is flushed before the page turns, and a flush that fails refuses the
turn instead of warning about it -- otherwise the next page's surface frees
the raster and the metadata the pending stroke would have been written from.

Turning to a page creates nothing. A reader who never draws must not
accumulate a row for every page they walked past, so only `ensureSurface` --
Draw being pressed -- may insert one.

Exactly one SurfaceSession exists at a time, because exactly one raster does:
a page overlay is the whole page at zoom, which is the allocation the
transform's budget exists to refuse.

And a refused view locks the surface without closing it. Zooming past the
budget must be something a reader can undo by zooming back out, not something
that re-reads their ink -- so the same session has to still be there
afterwards.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Session = require("ink_document_ink_session")
    local Blitbuffer = require("ffi/blitbuffer")

    local IDENTITY = { partial_md5 = "abc123", file_size = 90210 }
    local SCREEN = { w = 1000, h = 1400 }

    --- A page-ink row as the repository hands it back. A4 in points, rounded
    --- up: `getNativePageDimensions` answers 595.276 x 841.89.
    local function pageRow(id, page, w, h)
        return {
            id = id,
            anchor_kind = "page",
            anchor_key = "page-ink:" .. page,
            fixed_page = page,
            surface_role = "page_ink",
            coordinate_space = "native_page",
            logical_w = w or 596,
            logical_h = h or 842,
        }
    end

    --- A sheet row, which every page-ink operation has to leave alone.
    local function sheetRow(id, xp)
        return {
            id = id,
            anchor_kind = "xpointer",
            anchor_key = "xp:" .. xp,
            anchor_raw = xp,
            logical_w = 1000,
            logical_h = 1400,
        }
    end

    local function bar()
        return { width = 4, tool = 1, n = 3,
                 points = { 100, 100, 200, 100, 300, 100 } }
    end

    local function fixture(opts)
        opts = opts or {}
        local store = support.newCanvasStore(opts.canvases or {})
        if opts.read_only then
            store.read_only = true
            function store:findBookId(partial_md5, file_size)
                if not partial_md5 or not file_size then return nil, "no_identity" end
                return 12
            end
        end
        if opts.no_identity then
            function store:bookId() return nil, "no_identity" end
        end
        for id, list in pairs(opts.strokes or {}) do
            for _, s in ipairs(list) do store:putStroke(id, s) end
        end

        local sched = support.newScheduler()
        local rv = support.newReaderView(opts.view or {})
        local notes = {}
        local events = {
            state = {}, ready = 0, will_rebuild = 0, save_recovered = 0,
            refused = {}, save_error = {}, load_error = {},
        }

        -- `x == false and false or store` collapses to `store`, which is how a
        -- "no database" case quietly tests the opposite of itself.
        local repository = store
        if opts.repository == false then repository = false end

        local session = Session.new{
            ui = rv.ui,
            view = rv.view,
            identity = IDENTITY,
            file = "/mnt/us/documents/book.pdf",
            repository = repository,
            screen = function() return SCREEN.w, SCREEN.h end,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end,
            notify = function(text) notes[#notes + 1] = text end,
            -- The fake buffer has no pixels, so the transparent clear an
            -- overlay erases through arrives injected (see canvas_cache_spec).
            cache_opts = { clear = support.recordingClear() },
            on_state_changed = function(name)
                events.state[#events.state + 1] = name
            end,
            on_ready = function() events.ready = events.ready + 1 end,
            on_will_rebuild = function()
                events.will_rebuild = events.will_rebuild + 1
            end,
            on_view_refused = function(reason)
                events.refused[#events.refused + 1] = reason
            end,
            on_save_error = function(reason)
                events.save_error[#events.save_error + 1] = reason
            end,
            on_save_recovered = function()
                events.save_recovered = events.save_recovered + 1
            end,
            on_load_error = function(reason)
                events.load_error[#events.load_error + 1] = reason
            end,
        }
        return session, store, sched, rv, events, notes
    end

    --- An open session, turned to `opts.page` (1 by default) and settled.
    local function openedPage(opts)
        opts = opts or {}
        local session, store, sched, rv, events, notes = fixture(opts)
        session:open()
        session:setPage(opts.page or 1)
        sched:drain()
        return session, store, sched, rv, events, notes
    end

    -- =================================================================
    t:describe("ink_document_ink_session / opening a book")

    t:case("the book is identified by checksum and size", function()
        local session, store = fixture()
        t:eq(session:open(), true, "opened")
        t:eq(store.identity[1], "abc123", "checksum")
        t:eq(store.identity[2], 90210, "size")
        t:eq(session:isAvailable(), true, "and page ink is on for this book")
        t:eq(session:stateName(), "idle", "with no page open yet")
    end)

    t:case("no database turns the feature off instead of crashing", function()
        local session, _, _, _, _, notes = fixture{ repository = false }
        local ok, err = session:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "no_repository", "with a reason")
        t:eq(#notes, 1, "the reader is told, once")
        t:eq(session:isAvailable(), false, "and every entry point checks this")
        t:eq(session:stateName(), "unavailable", "the state says so")
        local _, page_err = session:setPage(3)
        t:eq(page_err, "unavailable", "a page turn is a safe no-op")
        local _, ensure_err = session:ensureSurface()
        t:eq(ensure_err, "unavailable", "so is Draw")
        local _, view_err = session:refreshView()
        t:eq(view_err, "unavailable", "so is a view event")
        local _, delete_err = session:deleteCurrent()
        t:eq(delete_err, "unavailable", "so is deleting")
        local draws, draw_reason = session:canDraw()
        t:eq(draws, false, "nothing can be drawn")
        t:eq(draw_reason, "unavailable", "and the reason is the same one")
    end)

    t:case("two renamed databases fail closed instead of hiding ink", function()
        local session, _, _, _, _, notes = fixture()
        session.repository = nil
        session._databasePath = function()
            return nil, "database_conflict",
                "/settings/justdraw.sqlite3", "/settings/fingerink.sqlite3"
        end
        local ok, err = session:open()
        t:eq(ok, nil, "opening is refused")
        t:eq(err, "database_conflict", "the specific conflict is preserved")
        t:eq(session:isAvailable(), false, "page ink stays off")
        t:check(notes[1] and notes[1]:find("Both JustDraw and FingerInk", 1, true),
            "the reader gets an actionable explanation")
        t:check(notes[1]:find("notes databases", 1, true),
            "naming the one file honestly: it is not a sheet database")
    end)

    t:case("a book with no usable identity is unavailable", function()
        local session, store, _, _, _, notes = fixture{ no_identity = true }
        session.owns_repository = true
        local ok, err = session:open()
        t:eq(ok, nil, "refused")
        t:eq(err, "no_identity", "with a reason")
        t:eq(#notes, 1, "the reader is told")
        t:eq(store.closed, true, "and the connection this session opened is closed")
    end)

    t:case("a future schema paints its ink and refuses to add to it", function()
        local session, store, _, _, _, notes = openedPage{
            read_only = true,
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar() } },
        }
        t:eq(session:isWritable(), false, "the database is read-only")
        t:eq(session:stateName(), "ready", "the page's ink is still shown")
        t:check(session:cache() ~= nil, "there is a raster for it")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "but nothing may be added")
        t:eq(reason, "read_only", "and the reason says why")
        local _, ensure_err = session:ensureSurface()
        t:eq(ensure_err, "read_only", "Draw is refused the same way")
        local _, stroke_err = session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(stroke_err, "read_only", "so is a stroke that got through anyway")
        t:eq(#store.canvases, 1, "and nothing was written")
        t:check(notes[1] ~= nil, "the reader was told once, when the page opened")
    end)

    t:case("a newer schema that never registered this book stays empty", function()
        local session, store, sched = fixture{ read_only = true }
        function store:findBookId() return nil, "not_found" end
        function store:bookId() error("a read-only schema must not be written") end
        t:eq(session:open(), true, "the book opens read-only and empty")
        t:eq(session:setPage(1), true, "and a page turn is fine")
        sched:drain()
        t:eq(session:stateName(), "idle", "there is nothing to find")
        t:eq(session:surface(), nil, "so nothing is open")
        local _, err = session:ensureSurface()
        t:eq(err, "read_only", "and Draw may not insert a row this plugin cannot own")
        t:eq(#store.canvases, 0, "nothing was written")
    end)

    -- =================================================================
    t:describe("ink_document_ink_session / turning pages")

    t:case("a page with ink opens as a transparent overlay", function()
        local session, _, _, _, events = openedPage{
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar() } },
        }
        t:eq(session:stateName(), "ready", "the page is ready to draw on")
        t:eq(events.ready, 1, "the owner was told once")
        t:eq(session:surface().id, 1, "over the row for this page")
        local bb = session:cache():buffer()
        t:eq(bb.bbtype, Blitbuffer.TYPE_BB8A,
            "the raster carries alpha, transparent straight from calloc")
        t:eq(#bb.fills, 0,
            "and nothing filled it: a fill would hide the page under it")
        t:check(#bb.rects > 0, "the stroke is on it all the same")
    end)

    t:case("looking at a page creates nothing", function()
        local session, store = openedPage{ page = 7 }
        t:eq(session:stateName(), "idle", "no surface here")
        t:eq(session:surface(), nil, "and no row")
        t:eq(session:cache(), nil, "so no raster was allocated")
        t:eq(#store.canvases, 0, "nothing was written for a page turned past")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "there is nothing to draw on yet")
        t:eq(reason, "no_surface", "which is what Draw is for")
    end)

    t:case("turning to the page already open is a no-op", function()
        local session, store, sched = openedPage{ canvases = { pageRow(1, 1) } }
        local surface_session = session:surfaceSession()
        local looks = 0
        local find = store.findPageInkSurface
        store.findPageInkSurface = function(s, book, page)
            looks = looks + 1
            return find(s, book, page)
        end
        t:eq(session:setPage(1), true, "the same page is accepted")
        sched:drain()
        t:eq(looks, 0, "without a second lookup")
        t:eq(session:surfaceSession(), surface_session, "or a second session")
    end)

    t:case("only one raster exists at a time", function()
        local session, _, sched = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
            strokes = { [1] = { bar() }, [2] = { bar() } },
        }
        local first = session:cache()
        local first_bb = first:buffer()
        t:eq(session:setPage(2), true, "the reader turned the page")
        sched:drain()
        t:eq(session:surface().id, 2, "the next page's row is open")
        t:eq(first_bb.freed, true, "and the last page's raster was freed")
        t:check(session:cache() ~= first, "a different cache serves it")
    end)

    t:case("the queue is flushed before the next page is looked up", function()
        local session, store, sched = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
        }
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(session:pendingWrites(), 1, "a stroke is waiting")

        local log = {}
        local add, find = store.addStroke, store.findPageInkSurface
        store.addStroke = function(s, canvas, stroke)
            log[#log + 1] = "write"
            return add(s, canvas, stroke)
        end
        store.findPageInkSurface = function(s, book, page)
            log[#log + 1] = "find"
            return find(s, book, page)
        end
        t:eq(session:setPage(2), true, "the page turned")
        sched:drain()
        t:eq(table.concat(log, ","), "write,find",
            "the stroke was made durable before the next row was read")
        t:eq(#store.strokes[1], 1, "and it landed on the page it was drawn on")
    end)

    t:case("a page change is refused while a save has failed", function()
        local session, store, sched, _, events = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
        }
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        local surface_session = session:surfaceSession()
        store.fail_transaction = "commit"
        local ok, err = session:setPage(2)
        t:eq(ok, nil, "the turn is refused")
        t:eq(err, "flush_failed", "with the reason")
        t:eq(session:page(), 1, "the session stays on the page it could not leave")
        t:eq(session:stateName(), "save_failed", "and says why")
        t:eq(session:surfaceSession(), surface_session, "the session is untouched")
        t:eq(session:pendingWrites(), 1, "and still holds the stroke")
        t:eq(#events.save_error, 1, "the owner was told once")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "editing is refused until it is saved")
        t:eq(reason, "save_failed", "with that reason")

        store.fail_transaction = nil
        t:eq(session:retrySave(), true, "the same operations retry")
        sched:drain()
        t:eq(events.save_recovered, 1, "recovery is relayed")
        t:eq(session:page(), 2, "and the page change it was holding completes")
        t:eq(session:surface().id, 2, "over the next page's row")
        t:eq(#store.strokes[1], 1, "the stroke went to the page it was drawn on")
    end)

    t:case("a surface closing is never this session's own \"closed\"", function()
        -- "closed" is the token the reader wiring tears its UI down on, and
        -- `SurfaceSession:close` reports its own state unconditionally. Every
        -- page turn, every suspend and every delete closes a surface; none of
        -- them closes this session, so none of them may say so.
        local session, _, sched, _, events = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2) },
            strokes = { [1] = { bar() }, [2] = { bar() } },
        }
        session:setPage(2)
        sched:drain()
        session:suspend("scroll_mode")
        session:resume()
        sched:drain()
        session:deleteCurrent()
        sched:drain()

        t:eq(session:isClosed(), false, "the session was never closed")
        local said_closed = 0
        for _, name in ipairs(events.state) do
            if name == "closed" then said_closed = said_closed + 1 end
        end
        t:eq(said_closed, 0, "and it never once said it was")
        t:eq(events.state[#events.state], "idle",
            "the last thing it said is where it actually is")
        t:eq(session:stateName(), "idle", "which is true")

        t:eq(session:close(), true, "closing for real")
        t:eq(events.state[#events.state], "closed", "is the one time it says so")
        t:eq(session:isClosed(), true, "and it means it")
    end)

    -- =================================================================
    t:describe("ink_document_ink_session / the view")

    t:case("a pan moves the ink without rebuilding the raster", function()
        local session, _, sched, rv, events = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        local bb = session:cache():buffer()
        local before = session:transform().offset_x
        rv.view.visible_area.x = 100
        t:eq(session:refreshView(), true, "the view was remapped")
        sched:drain()
        t:check(session:transform().offset_x ~= before, "the page moved")
        t:eq(events.will_rebuild, 0, "no rebuild was announced")
        t:eq(session:cache():buffer(), bb, "and it is the same raster")
        t:eq(bb.freed, false, "nothing was freed for a pan")
    end)

    t:case("a zoom rebuilds the raster, announced first", function()
        local session, _, sched, rv, events = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        local bb = session:cache():buffer()
        rv.view.state.zoom = 1
        t:eq(session:refreshView(), true, "the view was remapped")
        t:eq(events.will_rebuild, 1, "the owner was warned before the buffer went")
        sched:drain()
        t:eq(bb.freed, true, "the old raster was freed")
        local w, h = session:transform():cacheSize()
        t:eq(w, 596, "the new one is the page at the new zoom, wide")
        t:eq(h, 842, "and high")
        t:eq(session:stateName(), "ready", "and it came back ready")
    end)

    t:case("a refused view locks the surface without closing it", function()
        local session, _, sched, rv, events = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        local surface_session = session:surfaceSession()
        rv.view.page_scroll = true
        local ok, err = session:refreshView()
        t:eq(ok, nil, "the view is refused")
        t:eq(err, "unsupported_mode", "by name")
        t:eq(session:stateName(), "view_refused", "the state says so")
        t:eq(session:viewReason(), "unsupported_mode", "and remembers which")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "drawing is off")
        t:eq(reason, "unsupported_mode", "for the same reason")
        t:eq(session:surfaceSession(), surface_session, "the session is still open")
        t:check(session:cache() ~= nil, "and not one stroke was let go")

        t:eq(#events.refused, 1, "the owner was told once")
        session:refreshView()
        t:eq(#events.refused, 1, "and not again for the same refusal")

        rv.view.page_scroll = false
        t:eq(session:refreshView(), true, "leaving scroll mode maps it again")
        sched:drain()
        t:eq(session:viewReason(), nil, "the refusal is gone")
        t:eq(session:surfaceSession(), surface_session,
            "and the same session continues")
        t:eq(session:canDraw(), true, "drawing is back on")
    end)

    t:case("a zoom past the raster budget is a refusal like the others", function()
        local session, _, _, rv, events = openedPage{
            canvases = { pageRow(1, 1) },
        }
        rv.view.state.zoom = 4
        local ok, err = session:refreshView()
        t:eq(ok, nil, "refused")
        t:eq(err, "zoom_too_large", "with the reason a reader can act on")
        t:eq(session:stateName(), "view_refused", "the same state as any refusal")
        t:eq(events.refused[1], "zoom_too_large", "relayed by name")
        local _, ensure_err = session:ensureSurface()
        t:eq(ensure_err, "zoom_too_large", "and Draw is refused with it too")
    end)

    t:case("the refusal is known before anything has been created", function()
        local session, store, _, rv = fixture{ view = { page_scroll = true } }
        session:open()
        t:eq(session:setPage(4), true, "there is no row on this page")
        local ok, err = session:refreshView()
        t:eq(ok, nil, "the view is still refused")
        t:eq(err, "unsupported_mode", "by probing the page's own geometry")
        t:eq(#store.canvases, 0, "and the probe created nothing")
        rv.view.page_scroll = false
        t:eq(session:refreshView(), true, "and it clears the same way")
    end)

    t:case("a page found under a refused view opens when the view returns",
    function()
        local session, _, sched, rv = fixture{
            view = { page_scroll = true },
            canvases = { pageRow(1, 1) },
            strokes = { [1] = { bar() } },
        }
        session:open()
        local ok, err = session:setPage(1)
        t:eq(ok, nil, "the page cannot be shown")
        t:eq(err, "unsupported_mode", "with the view's reason")
        t:eq(session:surface().id, 1, "but its row was found and kept")
        t:eq(session:surfaceSession(), nil, "with no raster allocated for it")
        rv.view.page_scroll = false
        t:eq(session:refreshView(), true, "the view can be mapped again")
        sched:drain()
        t:check(session:surfaceSession() ~= nil, "and now the surface opens")
        t:eq(session:stateName(), "ready", "with its ink")
    end)

    t:case("a page that cannot state its size says so, not \"bad geometry\"",
    function()
        local session, store = fixture{ view = { native = false } }
        session:open()
        t:eq(session:setPage(1), true, "there is no row on this page to open")
        local ok, err = session:refreshView()
        t:eq(ok, nil, "the view cannot be mapped")
        t:eq(err, "no_dimensions",
            "with the page's own reason, not the empty probe's bad_geometry")
        t:eq(session:viewReason(), "no_dimensions", "and it is remembered")
        local _, ensure_err = session:ensureSurface()
        t:eq(ensure_err, "no_dimensions", "Draw answers the same, in any order")
        t:eq(#store.canvases, 0, "and creates nothing for a page it cannot measure")
    end)

    -- =================================================================
    t:describe("ink_document_ink_session / drawing")

    t:case("Draw creates the page's surface at the page's own size", function()
        local session, store, sched = openedPage{}
        t:eq(session:ensureSurface(), true, "the surface was created")
        sched:drain()
        t:eq(#store.canvases, 1, "one row")
        local row = store.canvases[1]
        t:eq(row.surface_role, "page_ink", "as page ink")
        t:eq(row.coordinate_space, "native_page", "in the page's own units")
        t:eq(row.anchor_key, "page-ink:1", "keyed by the page")
        t:eq(row.fixed_page, 1, "which is also a column")
        t:eq(row.logical_w, 596, "595.276 points wide, rounded up")
        t:eq(row.logical_h, 842, "841.89 points high, rounded up")
        t:eq(row.units, nil, "and the unit is not a column: nothing stored it")
        t:eq(session:stateName(), "ready", "the surface is ready to draw on")
        t:eq(session:canDraw(), true, "and says so")

        t:eq(session:ensureSurface(), true, "pressing Draw again is idempotent")
        t:eq(#store.canvases, 1, "no second row for the same page")
    end)

    t:case("Draw remaps the view rather than trusting the last one", function()
        -- No view event has been delivered since the mode changed, so the
        -- remembered answer is still "this maps fine". Draw is a lifecycle
        -- entry point and asks again itself: a caller must not have to know
        -- the order to be told the truth.
        local session, store, _, rv = openedPage{}
        t:eq(session:viewReason(), nil, "nothing has refused yet")
        rv.view.page_scroll = true
        local ok, err = session:ensureSurface()
        t:eq(ok, nil, "Draw is refused")
        t:eq(err, "unsupported_mode", "with the reason as it is now")
        t:eq(#store.canvases, 0, "and nothing was created on an unmappable page")
        t:eq(session:viewReason(), "unsupported_mode", "the refusal was recorded")

        rv.view.page_scroll = false
        t:eq(session:ensureSurface(), true, "and it recovers with no view event")
        t:eq(#store.canvases, 1, "creating the surface it was asked for")
    end)

    t:case("a page whose size changed keeps its ink and loses editing", function()
        local session, store, _, _, _ = openedPage{
            canvases = { pageRow(1, 1, 300, 400) },
            strokes = { [1] = { bar() } },
        }
        t:eq(session:surface().id, 1, "the row is open")
        t:check(session:cache() ~= nil, "its ink is rasterised as before")
        t:eq(session:stateName(), "geometry_changed", "and the state says why")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "but nothing may be added to it")
        t:eq(reason, "page_geometry_changed", "with the reason")
        local _, ensure_err = session:ensureSurface()
        t:eq(ensure_err, "page_geometry_changed", "Draw says the same thing")
        t:eq(#store.canvases, 1, "and creates no second surface for the page")
        local _, stroke_err = session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(stroke_err, "page_geometry_changed", "no stroke gets through either")
    end)

    t:case("ink and erasing open no transaction of their own", function()
        -- Erasing a stroke that is still only queued withdraws its insert
        -- instead of writing anything, so the stroke cut here is the stored
        -- one: what has to reach the queue is a delete and its fragments.
        local session, store = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        local before = store.calls.transaction
        t:check(session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1) ~= nil,
            "a stroke is accepted")
        local ctx = session:beginErase()
        t:check(session:eraseAt(200, 100, 18, ctx) ~= nil,
            "and the eraser cuts the stored one")
        session:endErase(ctx)
        t:eq(store.calls.transaction, before,
            "not one transaction was opened from the input path")
        t:check(session:pendingWrites() > 0, "the work is in the queue instead")
        t:eq(session:flush(), true, "and the lifecycle gate is what writes it")
        t:eq(store.calls.transaction, before + 1, "in exactly one transaction")
    end)

    t:case("undo takes back the last stroke", function()
        local session, _, sched = openedPage{}
        session:ensureSurface()
        sched:drain()
        t:eq(session:canUndo(), false, "nothing to undo on an empty page")
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        t:eq(session:canUndo(), true, "now there is")
        t:check(session:undo() ~= nil, "and it comes back with a region to repaint")
        t:eq(session:canUndo(), false, "and there is nothing left")
    end)

    -- =================================================================
    t:describe("ink_document_ink_session / deleting, suspending, closing")

    t:case("deleting this page's ink leaves every other page alone", function()
        local session, store, sched = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2), sheetRow(3, "/p1") },
            strokes = { [1] = { bar() }, [2] = { bar() } },
        }
        t:eq(session:deleteCurrent(), true, "this page's ink is gone")
        sched:drain()
        t:eq(#store.canvases, 2, "two rows are left")
        t:eq(store.canvases[1].id, 2, "the other page's ink")
        t:eq(store.canvases[2].id, 3, "and the sheet")
        t:eq(session:surface(), nil, "nothing is open here now")
        t:eq(session:stateName(), "idle", "and the page is empty again")
        t:eq(session:cache(), nil, "with its raster released")
    end)

    t:case("deleting every page's ink leaves the sheets", function()
        local session, store, sched = openedPage{
            canvases = { pageRow(1, 1), pageRow(2, 2), sheetRow(3, "/p1") },
            strokes = { [1] = { bar() }, [2] = { bar() } },
        }
        t:eq(session:deleteAll(), true, "the book's page notes are gone")
        sched:drain()
        t:eq(#store.canvases, 1, "one row is left")
        t:eq(store.canvases[1].id, 3, "and it is the sheet")
        t:eq(session:surface(), nil, "nothing is open")
        t:eq(session:stateName(), "idle", "on a page with nothing on it")
    end)

    t:case("suspending flushes, frees the raster and keeps the row", function()
        local session, store, sched = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        local bb = session:cache():buffer()
        t:eq(session:suspend("scroll_mode"), true, "suspended")
        t:eq(session:stateName(), "suspended", "and it says so")
        t:eq(#store.strokes[1], 2, "the pending stroke was made durable first")
        t:eq(bb.freed, true, "the raster is gone")
        t:eq(session:surfaceSession(), nil, "with its session")
        t:eq(#store.canvases, 1, "but the row is untouched")
        local draws, reason = session:canDraw()
        t:eq(draws, false, "nothing can be drawn while suspended")
        t:eq(reason, "suspended", "with that reason")

        t:eq(session:resume(), true, "resuming reopens the page")
        sched:drain()
        t:eq(session:stateName(), "ready", "with its ink back")
        t:eq(session:surface().id, 1, "over the same row")
        t:eq(session:canDraw(), true, "and drawing is on again")
    end)

    t:case("closing flushes, frees everything and is idempotent", function()
        local session, store, sched = openedPage{
            canvases = { pageRow(1, 1) }, strokes = { [1] = { bar() } },
        }
        session.owns_repository = true
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        local bb = session:cache():buffer()
        t:eq(session:close(), true, "closed")
        t:eq(#store.strokes[1], 2, "the last stroke is durable")
        t:eq(bb.freed, true, "the raster is freed")
        t:eq(store.closed, true, "and the connection this session opened is closed")
        t:eq(session:isClosed(), true, "the session knows it is shut")
        t:eq(session:stateName(), "closed", "and says so")
        t:eq(sched:pending(), 0, "no scheduled work was left behind")
        t:eq(sched:drain(), 0, "so draining afterwards does nothing")
        t:eq(session:close(), true, "and closing again is a no-op")
    end)

    t:case("a close that cannot save refuses, and force lets go anyway", function()
        local session, store = openedPage{ canvases = { pageRow(1, 1) } }
        session:addStroke({ 10, 10, 20, 20 }, 2, 4, 1)
        store.fail_transaction = "commit"
        local ok, err = session:close()
        t:eq(ok, nil, "closing is a durable gate")
        t:check(err ~= nil, "with the write's own reason")
        t:eq(session:isClosed(), false, "and the session is still there to retry on")
        t:eq(session:pendingWrites(), 1, "holding the stroke")
        session:close{ force = true }
        t:eq(session:isClosed(), true, "a forced close lets go anyway")
        t:eq(session:cache(), nil, "and leaves no raster behind")
    end)

    -- =================================================================
    --[[--
    The seam both sessions reach their book row through.

    Sheets and page ink share one file and one way into it, and three of the
    four decisions on that way are invariants -- which filename, which of the
    two book lookups a read-only schema allows, and who may close the
    connection afterwards. Written twice they drift; these are the ones a
    second copy would have got wrong.
    ]]
    t:describe("ink_book_database / the shared way in")

    local BookDatabase = require("ink_book_database")

    t:case("a refused database is a reason, not a connection attempt", function()
        local handle, reason = BookDatabase.open{ repository = false }
        t:eq(handle, nil, "refused")
        t:eq(reason, "no_repository", "by name")
    end)

    t:case("two databases fail closed before anything is opened", function()
        local handle, reason = BookDatabase.open{
            path_provider = function()
                return nil, "database_conflict", "/a.sqlite3", "/b.sqlite3"
            end,
        }
        t:eq(handle, nil, "refused")
        t:eq(reason, "database_conflict", "with the conflict preserved")
    end)

    t:case("a connection handed in is used, owned by nobody here", function()
        local store = support.newCanvasStore({})
        local handle = BookDatabase.open{
            repository = store, identity = IDENTITY, file = "/book.pdf",
        }
        t:check(handle ~= nil, "resolved")
        t:eq(handle.repository, store, "over the connection it was given")
        t:eq(handle.owns_repository, false, "which it does not own")
        t:eq(handle.book_id, 12, "and the book was identified")
        t:eq(handle.read_only, false, "on a writable database")
        t:eq(BookDatabase.close(handle), false, "so closing it is refused")
        t:eq(store.closed, false, "and the caller's connection is still open")
    end)

    t:case("a book that cannot be identified closes nothing it was lent",
    function()
        local store = support.newCanvasStore({})
        function store:bookId() return nil, "no_identity" end
        local handle, reason = BookDatabase.open{
            repository = store, identity = IDENTITY, file = "/book.pdf",
        }
        t:eq(handle, nil, "refused")
        t:eq(reason, "no_identity", "by name")
        t:eq(store.closed, false,
            "and the connection it was handed stays the caller's to close")
    end)

    t:case("a newer schema with no row for this book is not a failure",
    function()
        local store = support.newCanvasStore({})
        store.read_only = true
        function store:findBookId() return nil, "not_found" end
        function store:bookId() error("a read-only schema must not be written") end
        local handle = BookDatabase.open{
            repository = store, identity = IDENTITY, file = "/book.pdf",
        }
        t:check(handle ~= nil, "the database opens")
        t:eq(handle.book_id, nil, "with no book row")
        t:eq(handle.empty_read_only, true, "which is stated, not guessed")
        t:eq(handle.read_only, true, "and the schema is known to be newer")
    end)
end
