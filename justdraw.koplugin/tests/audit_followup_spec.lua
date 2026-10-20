--[[--
What the review of the 2026-10-20 audit found untested, stated as cases.

Each one names the behaviour and the decision it comes from; together they are
the parts of ADR-62..66 that only a whole plugin over the suite's fakes can
show -- which sentence a reader gets, what a tool choice may create, what the
toolbar shows -- rather than any one module.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local JustDraw = ctx.JustDraw
    local Style = require("ink_style")
    local Capture = require("ink_capture")

    --- A reflowable book on the runtime with sheets, its index settled.
    local function openEpub(opts)
        opts = opts or {}
        ctx.reset{ wacom_protocol = true, stylus_api = opts.stylus_api }
        local store = opts.store or support.newCanvasStore({})
        local p = support.newPlugin(JustDraw, env, {
            document = support.newDocument{
                here = "/body/p[7]", pages = { ["/body/p[7]"] = 1 },
            },
        })
        p.canvas_repository = store
        env.UIManager:flush()
        p:onReaderReady()
        for _ = 1, 200 do
            if not (p.session and p.session:isIndexing()) then break end
            env.UIManager:flush()
        end
        return p, store
    end

    t:describe("audit follow-up / what the reader is told")

    t:case("the evdev desync line the log audit counts is still written", function()
        local spec = Capture:sequenceSpec(nil, {})
        local before = #env.logs.info
        spec.on_desync(true)
        local line = env.logs.info[before + 1]
        t:check(line ~= nil and tostring(line[1]):find("JustDraw: evdev desync,", 1, true) ~= nil,
            "one info line per overflow, in the form tests/scribe_log_audit.lua reads")
    end)

    t:case("after the sheet index fails, Draw names that failure", function()
        local p = openEpub()
        p.session:_indexFailed("probe")
        p:setDrawing(true)
        local said = env.notifications[#env.notifications]
        t:check(said and said:find("Could not list", 1, true) ~= nil,
            "the index's own reason, not a menu path that is greyed: " .. tostring(said))
        t:check(p:canvasRefusalMessage() ~= nil, "and the menu's hold says the same")
    end)

    t:case("a sheet that cannot get its book row says why, not 'cannot anchor'", function()
        local store = support.newCanvasStore({})
        store.book_known = false
        function store:bookId() return nil, "no_identity" end
        local p = openEpub{ store = store }
        p:openCanvasHere()
        local said = env.notifications[#env.notifications]
        t:check(said and said:find("unavailable for this book", 1, true) ~= nil,
            "the book-row failure has its own sentence: " .. tostring(said))
        t:eq(#store.canvases, 0, "and nothing was created")
    end)

    t:case("a book row made by another process meanwhile is found, not refused", function()
        local BookDatabase = require("ink_book_database")
        local store = support.newCanvasStore({})
        function store:bookId() return nil, "UNIQUE constraint failed: books.partial_md5" end
        function store:findBookId() return 33 end
        t:eq(BookDatabase.ensureBook(store, { partial_md5 = "x", file_size = 1 }, "/b"), 33,
            "the row the other writer inserted")
    end)

    t:case("Draw while the sheets are still indexing says so", function()
        local p = openEpub()
        p.session.isIndexing = function() return true end
        p:setDrawing(true)
        local said = env.notifications[#env.notifications]
        t:check(said and said:find("still being indexed", 1, true) ~= nil,
            "not silence: " .. tostring(said))
        t:eq(p.canvas_open, false, "and no sheet was opened")
    end)

    t:case("page notes keep their refusal for whoever asks later", function()
        ctx.reset{ wacom_protocol = true }
        local p = support.newPlugin(JustDraw, env, { paging = true })
        p.canvas_repository = false
        env.UIManager:flush()
        local before = #env.notifications
        p:onReaderReady()
        t:eq(#env.notifications, before, "nothing is said as the book opens")
        t:check(p.document_open_error ~= nil, "the reason is kept")
        t:check(p:documentRefusalMessage() ~= nil, "and the menu's hold can say it")
    end)

    t:describe("audit follow-up / what a choice may create")

    t:case("choosing the eraser in a book with no sheet creates no sheet", function()
        local p, store = openEpub()
        p:setTool("eraser")
        env.UIManager:flush()
        t:eq(#store.canvases, 0, "a tool choice is not a request for a sheet (ADR-62)")
        t:eq(p.canvas_open, false, "none is open")
        t:eq(p.drawing, false, "and drawing did not start")
        t:eq(p.eraser, true, "the eraser is still the chosen tool")
    end)

    t:describe("audit follow-up / what the menu and the toolbar show")

    t:case("the pen style menu marks the style the pen will draw with", function()
        ctx.reset{ stylus_api = false }
        local p = support.newPlugin(JustDraw, env, { paging = true })
        env.UIManager:flush()
        t:eq(p.pen_style, Style.ROUND, "round ink is the stored default")
        t:eq(p:effectiveStyle(), Style.PEN, "which the direct-ink route resolves to the pen")
        t:eq(p:styleItem("Ink pen", Style.PEN).checked_func(), true, "so the pen row is marked")
        t:eq(p:styleItem("Round ink", Style.ROUND).checked_func(), false,
            "and not the round row it cannot draw with")
    end)

    t:case("the reader's toolbar shows Undo only when there is something to undo", function()
        ctx.reset{ stylus_api = false }
        local p = support.newPlugin(JustDraw, env, { paging = true })
        env.UIManager:flush()
        p:setBarShown(true)
        local bar = p.bar
        t:eq(bar.undo_btn.enabled, false, "nothing on this page yet")
        p.store:add(p:currentPage(), { n = 2, w = 4, 10, 10, 20, 20 })
        p:refreshHistoryButtons()
        t:eq(bar.undo_btn.enabled, true, "a stroke on this page can be taken back")
        p:onJustDrawUndo()
        t:eq(bar.undo_btn.enabled, false, "and once it is, Undo is off again")
    end)

    t:describe("audit follow-up / nothing allocated per sample")

    t:case("a live segment's dirty box is one table the cache reuses", function()
        local store = support.newCanvasStore({ { id = 5, logical_w = 1000, logical_h = 1400 } })
        local Cache = require("ink_canvas_cache")
        local Transform = require("ink_canvas_transform")
        local cache = Cache.new{
            repository = store,
            surface = { id = 5, logical_w = 1000, logical_h = 1400 },
            transform = Transform.new{ logical_w = 1000, logical_h = 1400,
                fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
                clip_rect = { x = 0, y = 0, w = 1000, h = 1400 } },
            schedule = function(fn) fn() end,
        }
        cache:open()
        local a = cache:drawSegment(100, 100, 120, 100, 4)
        local ax = a and a.x
        local b = cache:drawSegment(300, 300, 320, 300, 4)
        t:check(a ~= nil and rawequal(a, b), "the same table both times")
        t:check(ax ~= b.x, "refilled, not stale")
    end)
end
