--[[--
The sidecar, frozen: what a 2026.07 runtime may still do to direct ink.

Direct ink is the compatibility floor, and on a runtime that has the new
surfaces it is also a dead end (ADR-39). What is already in the sidecar stays
visible and deletable; nothing may be added to it, because the coordinates are
screen pixels nobody can map back to a page once zoom, crop or reflow moved.

Three doors used to lead there and this file is about closing all three: the
EPUB "Start drawing" outside a sheet, the undo pop, and the write path itself.
The last one is closed structurally -- the paint and the menu hold an
`InkLegacyInk`, which has no `add`, no `pop` and no `sweep` -- and the first
two are closed by the gate, with the reader told what to do instead.

The gate is the runtime, not the hardware (ADR-41). With it false every case
below describes the plugin exactly as v2026.03 has it, which is the other half
of the promise: nothing on the old route changes.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Device = ctx.Device
    local Legacy = require("ink_legacy_ink")
    local Store = require("ink_store")

    local PAGE_W, PAGE_H = 596, 842
    local INK_XY = { x = 100, y = 100 }

    local function pageRow(id, page)
        return {
            id = id,
            anchor_kind = "page",
            anchor_key = "page-ink:" .. tostring(page),
            fixed_page = page,
            surface_role = "page_ink",
            coordinate_space = "native_page",
            logical_w = PAGE_W,
            logical_h = PAGE_H,
        }
    end

    local function stroke(x, y)
        return { n = 2, w = 4, t = 1, x, y, x + 40, y + 40 }
    end

    --- A plugin over a fixed layout, the way main_document_spec builds one.
    local function pdfPlugin(opts)
        opts = opts or {}
        local input = { wacom_protocol = true }
        if opts.stylus_api == false then input.stylus_api = false end
        ctx.reset(input)
        local store = support.newCanvasStore(opts.canvases or {})
        local p = support.newPlugin(ctx.JustDraw, env, {
            paging = true, page = opts.page, doc_settings = opts.doc_settings,
        })
        -- `false` is the way to say "this book has no database": BookDatabase
        -- answers `no_repository` for it, which is what a session that cannot
        -- open looks like from here.
        if opts.repository == false then
            p.canvas_repository = false
        else
            p.canvas_repository = store
        end
        p.document_cache_opts = { clear = support.recordingClear() }
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        return p, store
    end

    --- The sheet index reads a batch per tick (ADR-42); a fixture is ready
    --- when it says so, not after any fixed number of flushes.
    local function settleIndex(p)
        local ticks = 0
        while p.session and p.session:isIndexing() do
            env.UIManager:flush()
            ticks = ticks + 1
            if ticks > 200 then error("the sheet index did not settle", 0) end
        end
    end

    --- A plugin over a reflowable document: the EPUB half of the freeze.
    local function epubPlugin(opts)
        opts = opts or {}
        local input = { wacom_protocol = true }
        if opts.stylus_api == false then input.stylus_api = false end
        ctx.reset(input)
        local doc = support.newDocument{
            here = "/body/p[7]", pages = { ["/body/p[7]"] = 1 },
        }
        local store = support.newCanvasStore(opts.canvases or {})
        local p = support.newPlugin(ctx.JustDraw, env, {
            document = doc, doc_settings = opts.doc_settings,
        })
        p.canvas_repository = store
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        settleIndex(p)
        return p, store
    end

    local function penDown(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, tool = tool or 1 }
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penFrame(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end

    local function penLift(p, x, y)
        p:onStylusEvent{ slot = 4, id = -1, x = x, y = y }
    end

    local function seedPenBaseline(p)
        local geometry = p.stylus_geometry
        if not geometry then return end
        geometry:observe(-1, -1)
        geometry:reset(false)
    end

    --- One whole finger contact, which is the only route a gate-false runtime
    --- has: three frames, down, move, lift.
    local function fingerStroke(p, x, y)
        p:onTouchFrame{ { slot = 0, id = 1, x = x, y = y } }
        p:onTouchFrame{ { slot = 0, id = 1, x = x + 40, y = y + 40 } }
        p:onTouchFrame{ { slot = 0, id = -1 } }
    end

    local function lastShown()
        return env.UIManager.shown[#env.UIManager.shown]
    end

    --- The menu path as a reader walks it, not as a brief described it: the
    --- entry is "JustDraw", its sheet row is "Drawing sheet" and that row's
    --- child is "Open sheet here". main.lua builds the sentence out of the
    --- same three `_()` strings the menu is built from, so this literal is
    --- also the assertion that the three labels have not moved.
    local FROZEN_EPUB =
        "Open a drawing sheet to draw in this book: JustDraw ▸ Drawing sheet ▸ Open sheet here."

    -- =================================================================
    t:describe("main / legacy ink / the read-only view")

    t:case("the wrapper offers reads and deletions and nothing that writes", function()
        local store = Store.new{ [2] = { stroke(10, 10) } }
        local legacy = Legacy.new(store)
        t:eq(legacy.add, nil, "no add")
        t:eq(legacy.pop, nil, "no pop")
        t:eq(legacy.sweep, nil, "no sweep")
        t:eq(legacy.hit, nil, "no hit")
        t:eq(legacy.removeAt, nil, "no removeAt")
        t:eq(legacy:strokes(2), store.pages[2], "strokes hands back the page's list")
        t:eq(legacy:strokes(7), nil, "and nil for a page with none")
        t:eq(legacy:hasInk(2), true, "hasInk answers for a page that has some")
        t:eq(legacy:hasInk(7), false, "and for one that does not")
        t:eq(legacy:isEmpty(), false, "a store with ink is not empty")
    end)

    t:case("pages answers every inked page in order", function()
        local legacy = Legacy.new(Store.new{
            [7] = { stroke(1, 1) }, [2] = { stroke(2, 2) }, [11] = { stroke(3, 3) },
        })
        local pages = legacy:pages()
        t:eq(#pages, 3, "three pages carry ink")
        t:eq(pages[1], 2, "sorted, smallest first")
        t:eq(pages[2], 7, "then the next")
        t:eq(pages[3], 11, "and 11 after 7, not before it")
    end)

    t:case("the deletions report whether they changed anything", function()
        local legacy = Legacy.new(Store.new{ [1] = { stroke(1, 1) }, [2] = { stroke(2, 2) } })
        t:eq(legacy:clearPage(3), false, "a page with no ink changes nothing")
        t:eq(legacy:clearPage(1), true, "a page with ink is cleared")
        t:eq(legacy:strokes(1), nil, "and is gone")
        t:check(legacy:strokes(2) ~= nil, "while the other page is untouched")
        t:eq(legacy:isEmpty(), false, "and the store still holds something")
    end)

    t:case("clearAll empties the store once and then reports no change", function()
        local legacy = Legacy.new(Store.new{ [1] = { stroke(1, 1) } })
        t:eq(legacy:clearAll(), true, "there was something to delete")
        t:eq(legacy:isEmpty(), true, "and the store is empty")
        t:eq(legacy:clearAll(), false, "a second clear changes nothing")
    end)

    -- =================================================================
    t:describe("main / legacy ink / the gate is false")

    t:case("an EPUB with no sheet still inks into the sidecar", function()
        local p = epubPlugin{ stylus_api = false }
        t:eq(p:legacyInkFrozen(), false, "v2026.03 keeps the direct route")
        p:setDrawing(true)
        t:eq(p.drawing, true, "Draw was not refused")
        fingerStroke(p, INK_XY.x, INK_XY.y)
        local list = p.store:get(1)
        t:eq(list and #list, 1, "one stroke reached the sidecar")
    end)

    t:case("a fixed layout still inks into the sidecar", function()
        local p = pdfPlugin{ stylus_api = false }
        p:setDrawing(true)
        fingerStroke(p, INK_XY.x, INK_XY.y)
        local list = p.store:get(1)
        t:eq(list and #list, 1, "one stroke reached the sidecar")
    end)

    t:case("undo still pops the sidecar", function()
        local p = pdfPlugin{ stylus_api = false }
        p.store:add(1, stroke(10, 10))
        t:eq(p:onJustDrawUndo(), true, "the event is consumed")
        t:eq(p.store:get(1), nil, "and the stroke came off")
    end)

    t:case("the clear entries keep the names they always had", function()
        local p = pdfPlugin{ stylus_api = false }
        t:check(ctx.menuItem(p, "Clear this page") ~= nil, "Clear this page is there")
        t:check(ctx.menuItem(p, "Clear whole document") ~= nil,
            "Clear whole document is there")
        t:eq(ctx.menuItem(p, "Clear legacy ink on this stored page"), nil,
            "and neither frozen entry exists")
        t:eq(ctx.menuItem(p, "Clear all legacy ink"), nil, "nor the second")
    end)

    -- =================================================================
    t:describe("main / legacy ink / the gate is true")

    t:case("Draw in an EPUB with no sheet is refused and creates nothing", function()
        local p, store = epubPlugin()
        t:eq(p:legacyInkFrozen(), true, "the runtime has the new surfaces")
        p:setDrawing(true)
        t:eq(p.drawing, false, "drawing did not start")
        t:eq(env.notifications[#env.notifications], FROZEN_EPUB,
            "and the reader is told where the ink goes now")
        t:eq(#store.canvases, 0, "no sheet was created behind their back")
        t:eq(p.input_lease, nil, "and no capture was installed")
    end)

    t:case("the sentence walks the menu that is actually there", function()
        local p = epubPlugin()
        -- Every label in the sentence is a row a reader can find: the top
        -- entry, its sheet row, and the child that opens one here.
        t:check(ctx.menuItem(p, "Drawing sheet") ~= nil, "the sheet row is Drawing sheet")
        local opens
        for _, item in ipairs(p:canvasMenu()) do
            if item.text == "Open sheet here" then opens = item end
        end
        t:check(opens ~= nil, "and its child opens a sheet here")
        for _, label in ipairs({ "JustDraw", "Drawing sheet", "Open sheet here" }) do
            t:check(FROZEN_EPUB:find(label, 1, true) ~= nil,
                "the refusal names " .. label)
        end
    end)

    t:case("a whole contact in a frozen EPUB adds nothing to the sidecar", function()
        local p = epubPlugin()
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:applyPoint(INK_XY.x + 40, INK_XY.y + 40, nil)
        p:endStroke()
        t:eq(p.stroke, nil, "no direct-ink stroke was started")
        t:eq(p.store:countPages(), 0, "and the sidecar stayed empty (ADR-39)")
    end)

    t:case("the eraser cannot reach legacy ink either", function()
        local p = epubPlugin()
        p.store:add(1, stroke(INK_XY.x - 20, INK_XY.y - 20))
        p:setEraser(true)
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:endStroke()
        local list = p.store:get(1)
        t:eq(list and #list, 1, "the stored stroke is untouched")
    end)

    t:case("undo in a frozen EPUB never pops the sidecar", function()
        local p = epubPlugin()
        p.store:add(1, stroke(10, 10))
        t:eq(p:onJustDrawUndo(), true, "the event is still consumed")
        local list = p.store:get(1)
        t:eq(list and #list, 1, "and the stroke is still there")
    end)

    t:case("a sheet open is the route, and it behaves exactly as it did", function()
        local p, store = epubPlugin()
        p:openCanvasHere()
        env.UIManager:flush()
        t:eq(p.canvas_open, true, "the sheet is open")
        p:setDrawing(true)
        t:eq(p.drawing, true, "and Draw is not refused with a sheet open")
        seedPenBaseline(p)
        penDown(p, 100, 500)
        penFrame(p, 140, 540)
        penLift(p, 140, 540)
        env.UIManager:flush()
        local canvas = store.canvases[1]
        t:check(canvas ~= nil, "the sheet row exists")
        t:eq(#store:listStrokes(canvas.id), 1, "the ink went to the sheet")
        t:eq(p.store:countPages(), 0, "and never to the sidecar")
    end)

    t:case("a fixed layout inks the page surface and leaves the sidecar alone", function()
        local p, store = pdfPlugin{ canvases = { pageRow(1, 1) } }
        p:setDrawing(true)
        seedPenBaseline(p)
        penDown(p, INK_XY.x, INK_XY.y)
        penFrame(p, INK_XY.x + 40, INK_XY.y + 40)
        penLift(p, INK_XY.x + 40, INK_XY.y + 40)
        env.UIManager:flush()
        t:eq(#store:listStrokes(1), 1, "the page surface took the stroke")
        t:eq(p.store:countPages(), 0, "and the sidecar took nothing")
    end)

    t:case("undo on a fixed layout never pops the sidecar", function()
        local p = pdfPlugin{ canvases = { pageRow(1, 1) } }
        p.store:add(1, stroke(10, 10))
        p:onJustDrawUndo()
        local list = p.store:get(1)
        t:eq(list and #list, 1, "the legacy stroke survived the undo")
    end)

    t:case("a stroke that somehow started is still never persisted", function()
        -- `applyPoint` is what decides, but the one line in main.lua that grows
        -- the sidecar is in `endStroke`, and it has to refuse on its own: a
        -- stroke left over from before the freeze took effect -- a session
        -- that appeared mid-contact -- must not be committed on the lift.
        local p = pdfPlugin{ canvases = { pageRow(1, 1) } }
        p.stroke = { n = 2, w = 4, t = 1, 10, 10, 50, 50 }
        p:endStroke()
        t:eq(p.stroke, nil, "the stroke was given up")
        t:eq(p.store:countPages(), 0, "and never reached the sidecar")

        -- A one-point stroke is the case that used to paint itself onto the
        -- screen before the guard was reached: the reader saw a dot that was
        -- never stored and that the next refresh took away again.
        local painted = #Device.screen.bb.writes
        local refreshed = #Device.screen.refreshes
        p.stroke = { n = 1, w = 4, t = 1, 120, 120 }
        p:endStroke()
        t:eq(#Device.screen.bb.writes, painted, "the frozen dot was never drawn")
        t:eq(#Device.screen.refreshes, refreshed, "nor refreshed onto the panel")
        t:eq(p.store:countPages(), 0, "and it is not in the sidecar either")
    end)

    t:case("the freeze needs a runtime and a reader with somewhere else to draw", function()
        -- The suite's plain host is neither rolling nor paging, which no
        -- ReaderUI ever is: it registers one or the other before it loads a
        -- plugin. The predicate reads both halves so that host -- and the
        -- hundreds of direct-ink cases built on it -- keeps describing the
        -- route it always described, and so the freeze can never refuse ink
        -- while offering nowhere to put it.
        ctx.reset{ wacom_protocol = true }
        local p = ctx.newPlugin{ doc_settings = {} }
        t:eq(p.legacy_frozen, true, "the runtime has the new surfaces")
        t:eq(p.ui.rolling, nil, "but this host has no sheet route")
        t:eq(p.ui.paging, nil, "and no page-ink route either")
        t:eq(p:legacyInkFrozen(), false, "so direct ink is what it always was")
    end)

    t:case("a fixed layout whose database will not open refuses Draw and says why", function()
        -- `openDocumentSession` returns early when `session:open()` fails, so
        -- `document_session` is nil on a paging host: Draw used to arm, and
        -- every point was then swallowed by the freeze with nothing on screen.
        local p = pdfPlugin{ repository = false }
        t:eq(p.document_session, nil, "the session could not be opened")
        t:eq(p.ui.paging, true, "but this is still a fixed layout")
        env.notifications = {}
        p:setDrawing(true)
        t:eq(p.drawing, false, "Draw did not arm over nothing")
        t:eq(env.notifications[#env.notifications],
            "Page notes need a database this KOReader cannot open.",
            "and the reader is told the reason the session reported")
        t:eq(p.input_lease, nil, "no capture was installed")
        t:eq(p.store:countPages(), 0, "and nothing reached the sidecar")
    end)

    t:case("a fixed layout with no session refuses the point rather than storing it", function()
        -- The database could not be opened, so Task 7's session is nil and the
        -- old code would have fallen straight through into the sidecar.
        local p = pdfPlugin()
        p.document_session = nil
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:endStroke()
        t:eq(p.store:countPages(), 0, "nothing was written where nothing can read it")
    end)

    -- =================================================================
    t:describe("main / legacy ink / what is stored is still shown")

    t:case("paintTo paints the frozen sidecar in an EPUB", function()
        local p = epubPlugin()
        p.store:add(1, stroke(10, 10))
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:check(#bb.rects > 0, "the legacy stroke is on the page")
    end)

    t:case("paintTo paints the frozen sidecar on a fixed layout", function()
        local p = pdfPlugin{ canvases = { pageRow(1, 1) } }
        p.store:add(1, stroke(10, 10))
        local bb = support.newBlitbuffer(600, 800)
        p:paintTo(bb, 0, 0)
        t:check(#bb.rects > 0, "the legacy stroke is on the page")
    end)

    -- =================================================================
    t:describe("main / legacy ink / the two deletions")

    t:case("the frozen entries replace the old two and name what goes", function()
        local p = pdfPlugin{ canvases = { pageRow(1, 1) } }
        t:eq(ctx.menuItem(p, "Clear this page"), nil, "the old entry is gone")
        t:eq(ctx.menuItem(p, "Clear whole document"), nil, "and so is the other")
        t:check(ctx.menuItem(p, "Clear legacy ink on this stored page") ~= nil,
            "the page entry names the legacy ink")
        t:check(ctx.menuItem(p, "Clear all legacy ink") ~= nil,
            "and so does the book entry")
    end)

    t:case("both entries are grey with nothing stored", function()
        local p = pdfPlugin()
        local page = ctx.menuItem(p, "Clear legacy ink on this stored page")
        local all = ctx.menuItem(p, "Clear all legacy ink")
        t:eq(page.enabled_func(), false, "no ink on this page")
        t:eq(all.enabled_func(), false, "and none in the book")
        p.store:add(3, stroke(10, 10))
        t:eq(page.enabled_func(), false, "ink on another page does not enable this one")
        t:eq(all.enabled_func(), true, "but it does enable the book entry")
        p.store:add(1, stroke(10, 10))
        t:eq(page.enabled_func(), true, "ink on this page enables it")
    end)

    t:case("clearing this page names the page and leaves the others", function()
        local p = pdfPlugin()
        p.store:add(1, stroke(10, 10))
        p.store:add(4, stroke(20, 20))
        local item = ctx.menuItem(p, "Clear legacy ink on this stored page")
        local dirty_before = #env.UIManager.dirty
        item.callback()
        local box = lastShown()
        t:eq(box.text,
            "Delete the legacy ink stored for page 1? Drawing sheets and page notes are not affected.",
            "the confirmation names the stored page and what survives it")
        box.ok_callback()
        t:eq(p.store:get(1), nil, "this page's legacy ink is gone")
        t:check(p.store:get(4) ~= nil, "and page 4 kept its own")
        t:check(#env.UIManager.dirty > dirty_before, "the page was repainted")
    end)

    t:case("clearing the book deletes both compatibility identities", function()
        local p = pdfPlugin{
            doc_settings = { fingerink_strokes = { [1] = { stroke(10, 10) } } },
        }
        t:eq(p.stroke_storage_id, "fingerink", "the legacy key is the active store")
        local item = ctx.menuItem(p, "Clear all legacy ink")
        t:eq(item.enabled_func(), true, "there is something to delete")
        item.callback()
        local box = lastShown()
        t:eq(box.text,
            "Delete all legacy ink in this book? Drawing sheets and page notes are not affected.",
            "the confirmation names the book and what survives it")
        box.ok_callback()
        p:onSaveSettings()
        t:eq(p.ui.doc_settings.data.fingerink_strokes, nil, "the legacy key is gone")
        t:eq(p.ui.doc_settings.data.justdraw_strokes, nil,
            "and the current one cannot bring it back")
    end)

    t:case("a document nobody drew on is saved back exactly as it was read", function()
        local pages = { [2] = { stroke(10, 10) } }
        local p = pdfPlugin{ doc_settings = { justdraw_strokes = pages } }
        p:setDrawing(true)
        p:applyPoint(INK_XY.x, INK_XY.y, nil)
        p:endStroke()
        p:onSaveSettings()
        local saved = p.ui.doc_settings.data.justdraw_strokes
        t:eq(saved, pages, "the same table went back")
        t:eq(saved[1], nil, "with no page the reader never had")
        t:eq(#saved[2], 1, "and the one page it had did not grow")
    end)

    -- =================================================================
    t:describe("main / legacy ink / the capability report")

    t:case("the diagnostics name the runtime and the four capabilities", function()
        local p = pdfPlugin()
        local lines = table.concat(p:diagnosticLines(), "\n")
        t:check(lines:find("KOReader: v2025.08-test", 1, true) ~= nil,
            "the revision is reported")
        t:check(lines:find("stylus API: yes", 1, true) ~= nil,
            "the gate is reported as a capability")
        t:check(lines:find("page transform: yes", 1, true) ~= nil,
            "so is the view transform")
        t:check(lines:find("native page size: yes", 1, true) ~= nil,
            "so is the native page size")
        t:check(lines:find("alpha overlay: yes", 1, true) ~= nil,
            "and so is the alpha blit")
    end)

    t:case("the file manager answers the gate without loading the reader", function()
        -- `Compat.capabilities` resolves its dependencies by `require`, and
        -- two of them are the reader-view stack. A file-manager host reads
        -- only the gate, so probing the other two there would drag ReaderView
        -- and Document into file-manager start-up for an answer nobody asks.
        ctx.reset{ wacom_protocol = true }
        package.loaded["apps/reader/modules/readerview"] = nil
        package.loaded["document/document"] = nil
        local p = support.newFileManagerPlugin(ctx.JustDraw, env)
        t:eq(p.is_docless, true, "this is the file-manager host")
        t:eq(package.loaded["apps/reader/modules/readerview"], nil,
            "ReaderView was never required")
        t:eq(package.loaded["document/document"], nil,
            "and neither was Document")
        t:eq(p.capabilities.stylus_api, true, "the gate is still answered")
    end)

    t:case("a reader host does probe all four", function()
        local p = pdfPlugin()
        t:eq(p.capabilities.stylus_api, true, "the gate")
        t:eq(p.capabilities.view_transform, true, "the transform pair")
        t:eq(p.capabilities.native_dimensions, true, "the native page size")
        t:eq(p.capabilities.alpha_blit, true, "and the alpha blit")
    end)

    t:case("a runtime with no stylus API reports it as a missing capability", function()
        local p = pdfPlugin{ stylus_api = false }
        local lines = table.concat(p:diagnosticLines(), "\n")
        t:check(lines:find("stylus API: no", 1, true) ~= nil,
            "the one discriminator is reported as absent (ADR-41)")
    end)
end
