return function(ctx)
    local t = ctx.t
    local support = ctx.support

    local function configureViewport(plugin)
        return plugin:configureNotebookInteraction{
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
        }
    end

    t:describe("standalone notebooks / host seam")

    t:case("a FileManager-shaped host touches no document API", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        t:eq(plugin.is_docless, true, "host detected")
        t:eq(plugin.store, nil, "reader store was not built")
        t:eq(plugin.session, nil, "EPUB session absent")
        t:eq(plugin.notebooks, nil, "database remains lazy")
        t:eq(plugin:onSaveSettings(), nil, "SaveSettings is harmless")
        t:eq(plugin:onSuspend(), nil, "Suspend is harmless")
        t:eq(plugin:onScreenResize(), nil, "resize is harmless")
        t:eq(plugin:onCloseWidget(), nil, "close is harmless")
    end)

    t:case("asking for the controller still does not open SQLite", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        t:check(controller ~= nil, "headless controller exists")
        t:eq(controller.repository, nil, "repository unopened")
        t:eq(plugin:notebookController(), controller, "one controller per host")
        plugin:onCloseWidget()
    end)

    t:case("production activation includes FileManager", function()
        t:eq(ctx.JustDraw.is_doc_only, false, "notebooks are visible without a document")
    end)

    t:case("FileManager exposes only the document-free notebook entry", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local menu = {}
        plugin:addToMainMenu(menu)
        t:check(menu.justdraw_notebooks ~= nil, "Notebooks entry exists")
        t:eq(menu.justdraw_notebooks.text, "Notebooks", "entry is English")
        t:eq(menu.justdraw, nil, "reader-only drawing menu is absent")
        t:eq(plugin.notebooks, nil, "building the menu does not open SQLite")
    end)

    t:case("both hosts name the Tools tab, not the page below it", function()
        -- MenuSorter appends a hinted orphan to the end of whatever id the hint
        -- names, and it resolves the id anywhere in the tree -- a tab included.
        -- "more_tools", what KOReader's own plugin example uses, is therefore a
        -- page deeper than the entry needs to be.
        ctx.reset()
        local docless = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local fm_menu = {}
        docless:addToMainMenu(fm_menu)
        t:eq(fm_menu.justdraw_notebooks.sorting_hint, "tools",
            "file browser entry sits on the Tools tab")
        docless:teardown()

        ctx.reset()
        local reader = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        local reader_menu = {}
        reader:addToMainMenu(reader_menu)
        t:eq(reader_menu.justdraw.sorting_hint, "tools",
            "reader entry sits on the Tools tab")
        reader:teardown()
    end)

    t:case("the file browser publishes the actions a gesture can bind", function()
        -- Registration used to sit behind init's docless return, so a session
        -- that opened straight into the file browser and never touched a book
        -- offered the Gesture Manager nothing to bind at all.
        ctx.reset()
        ctx.env.dispatcher_actions = {}
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local actions = ctx.env.dispatcher_actions

        local notebooks = actions.justdraw_notebooks
        t:check(notebooks ~= nil, "the notebook action is registered")
        t:eq(notebooks.event, "JustDrawNotebooks", "and names its event")
        t:eq(notebooks.general, true,
            "general: assignable in the file browser as well as the reader")
        t:eq(notebooks.reader, nil, "not confined to the reader section")

        -- The ink actions are published here too and stay reader-only.
        -- Dispatcher lists an action only under the section it declares, so
        -- registering them in a docless host costs the file browser nothing.
        t:eq(actions.fingerink_toggle.reader, true, "toggle stays reader-only")
        t:eq(actions.fingerink_toggle.general, nil, "and is not promoted")
        t:eq(actions.fingerink_bar.reader, true, "toolbar stays reader-only")

        -- The sheet action postdates the rename, so like the notebook action
        -- it carries no legacy FingerInk identity -- but a sheet needs a
        -- reflowable document, so unlike it the action stays reader-only.
        local sheet = actions.justdraw_sheet
        t:check(sheet ~= nil, "the sheet action is registered")
        t:eq(sheet.event, "JustDrawSheet", "and names its event")
        t:eq(sheet.reader, true, "a sheet needs a document: reader-only")
        t:eq(sheet.general, nil, "and is not promoted to the file browser")
        plugin:teardown()
    end)

    t:case("the notebook action opens the library, once", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()

        t:eq(plugin:onJustDrawNotebooks(), true, "the event is consumed")
        local library = plugin.notebook_ui and plugin.notebook_ui.library
        t:check(library ~= nil, "the library is up")
        t:eq(controller:activeSession(), nil, "and owns no page session")

        t:eq(plugin:onJustDrawNotebooks(), true, "a second press is harmless")
        t:eq(plugin.notebook_ui.library, library, "and raises no second window")
        plugin:teardown()
    end)

    t:case("FileManager menu opens the real library without an input lease", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        local menu = {}
        plugin:addToMainMenu(menu)
        menu.justdraw_notebooks.callback()
        t:check(plugin.notebook_ui and plugin.notebook_ui.library,
            "library coordinator is active")
        t:eq(controller:activeSession(), nil, "library owns no page session")
        t:eq(require("ink_input_controller"):activeOwner(), nil,
            "library owns no input callback")
        ctx.env.UIManager:flush()
        t:check(plugin.notebook_ui.library.batch ~= nil, "metadata loaded lazily")
        plugin:teardown()
    end)

    t:case("ReaderUI library leaves direct drawing untouched until a row opens", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        local reader_lease = plugin.input_lease
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        t:eq(plugin.drawing, true, "opening metadata UI does not stop Draw")
        t:eq(plugin.input_lease, reader_lease, "reader retains the same lease")
        t:eq(controller:activeSession(), nil, "handoff has not started")
        plugin:teardown()
    end)

    t:case("FileManager can write, close and reopen a notebook through the UI stack", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        ctx.env.UIManager:flush()
        local library = plugin.notebook_ui.library
        library.layout[1][1].callback()
        local editor = plugin.notebook_ui.editor
        local session = controller:activeSession()
        t:check(editor ~= nil and session ~= nil, "editor and page session opened")
        local paper = session:surface():transform():canvasRect()
        local x, y = paper.x + math.floor(paper.w / 2), paper.y + math.floor(paper.h / 2)
        ctx.env.Device.input.gesture_detector:feedEvent{
            { slot = 0, id = 1, x = x, y = y, tool = 0 },
        }
        ctx.env.Device.input.gesture_detector:feedEvent{
            { slot = 0, id = -1, x = x, y = y, tool = 0 },
        }
        t:eq(session:surface():pendingWrites(), 1, "one stroke is queued")
        t:eq(editor.snapshot.can_undo, true, "Undo enabled after lift")
        t:eq(editor:requestClose(), true, "durable exit returns to library")
        for _ = 1, 4 do ctx.env.UIManager:flush() end
        t:eq(plugin.notebook_ui.editor, nil, "library is topmost again")
        t:eq(controller.viewport_provider, false,
            "closed editor viewport callback is released")
        t:eq(plugin.notebook_input.on_dirty, false,
            "closed editor repaint callback is released")
        local reopened_editor, reopen_err = plugin.notebook_ui:openNotebook(
            plugin.notebook_ui.library.batch.items[1])
        t:check(reopened_editor ~= nil,
            "editor reopened: " .. tostring(reopen_err))
        for _ = 1, 4 do ctx.env.UIManager:flush() end
        local reopened = controller:activeSession()
        t:check(reopened ~= nil, "reopened page session exists")
        if reopened then
            t:eq(#reopened:surface():cache():strokes(), 1, "stored ink reloads")
        end
        plugin:teardown()
    end)

    t:case("rotation waits for the host dimensions and coalesces ScreenResize", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local calls = 0
        plugin.notebook_ui = {
            onScreenResize = function() calls = calls + 1; return true end,
            shutdown = function() return true end,
        }
        t:eq(plugin:onSetRotationMode(), nil,
            "the observer never consumes the host rotation event")
        t:eq(calls, 0, "SetRotationMode does not use the old Screen geometry")
        ctx.env.UIManager:flush()
        t:eq(calls, 1, "deferred resize sees host-applied geometry")
        plugin:onSetRotationMode()
        plugin:onScreenResize()
        t:eq(calls, 2, "real ScreenResize applies immediately")
        ctx.env.UIManager:flush()
        t:eq(calls, 2, "superseded deferred resize is cancelled")
        plugin:teardown()
    end)

    t:case("a 180-degree rotation with stable dimensions still refreshes once", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        ctx.env.UIManager:flush()
        plugin.notebook_ui.library.layout[1][1].callback()
        local screen = ctx.env.Device.screen
        local before = #ctx.env.UIManager.dirty
        screen.rotation = screen.DEVICE_ROTATED_UPSIDE_DOWN
        t:eq(plugin:onSetRotationMode(), nil, "rotation propagates to FileManager")
        ctx.env.UIManager:flush()
        local full = 0
        for i = before + 1, #ctx.env.UIManager.dirty do
            if ctx.env.UIManager.dirty[i][2] == "full" then full = full + 1 end
        end
        t:eq(full, 1, "rotation mode participates in resize identity")
        screen.rotation = screen.DEVICE_ROTATED_UPRIGHT
        plugin:teardown()
    end)

    t:case("an uncovered library rebuilds once for the official resize pair", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        ctx.env.UIManager:flush()
        local library = plugin.notebook_ui.library
        local original_rebuild = library._rebuild
        local rebuilds = 0
        function library:_rebuild()
            rebuilds = rebuilds + 1
            return original_rebuild(self)
        end
        local screen = ctx.env.Device.screen
        local old_w, old_h = screen.w, screen.h
        screen.w, screen.h = old_h, old_w
        library:onSetDimensions()
        plugin:onScreenResize()
        t:eq(rebuilds, 1, "SetDimensions consumes the new geometry once")
        screen.w, screen.h = old_w, old_h
        plugin:teardown()
    end)

    t:case("the official SetDimensions and ScreenResize pair resizes once", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        ctx.env.UIManager:flush()
        local library = plugin.notebook_ui.library
        library.layout[1][1].callback()
        local editor = plugin.notebook_ui.editor
        local resize_calls = 0
        function controller:onScreenResize()
            resize_calls = resize_calls + 1
            return true
        end
        local covered_tree = library[1]
        t:eq(editor:onSetDimensions(), true, "editor handles SetDimensions")
        t:eq(library:onSetDimensions(), true, "covered library defers SetDimensions")
        t:eq(library[1], covered_tree, "covered library builds no hidden tree")
        plugin:onScreenResize()
        t:eq(resize_calls, 1, "the same geometry reaches the domain once")
        t:eq(editor:requestClose(), true, "editor returns to library")
        t:eq(library.layout_deferred, false, "one deferred library layout is applied")
        plugin:teardown()
    end)

    t:case("host teardown clears every editor callback reference", function()
        ctx.reset()
        local plugin = support.newFileManagerPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        plugin:openNotebookLibrary()
        ctx.env.UIManager:flush()
        plugin.notebook_ui.library.layout[1][1].callback()
        local adapter = plugin.notebook_input
        t:check(type(adapter.on_dirty) == "function", "editor callback is installed")
        plugin:teardown()
        t:eq(adapter.on_dirty, false, "adapter releases the destroyed editor")
        t:eq(controller.viewport_provider, false, "controller releases viewport closure")
        t:eq(controller.on_state_changed, false, "controller releases state closure")
    end)

    t:case("production host refuses capture until UI provides a viewport", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        local reader_lease = plugin.input_lease
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        local session, err = controller:openNotebook(1)
        t:eq(session, nil, "notebook was not opened")
        t:eq(err, "no_viewport", "missing UI geometry is explicit")
        t:eq(plugin.drawing, true, "reader drawing was not disturbed")
        t:eq(plugin.input_lease, reader_lease, "reader retained input")
        plugin:teardown()
    end)

    t:case("ReaderUI hands its one input lease to a notebook", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        t:eq(plugin.drawing, true, "reader drawing started")
        local reader_lease = plugin.input_lease
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        configureViewport(plugin)
        local session, err = controller:openNotebook(1)
        t:check(session ~= nil, "notebook opened: " .. tostring(err))
        t:eq(plugin.drawing, false, "reader destination stopped")
        t:eq(reader_lease.active, false, "reader lease released")
        t:eq(require("ink_input_controller"):activeOwner(), controller,
            "notebook became the sole owner")
        t:check(session.input_lease ~= nil, "notebook pen adapter is live")
        t:eq(controller:closeNotebook(), true, "notebook closed durably")
        t:eq(require("ink_input_controller"):activeOwner(), nil,
            "closing does not reactivate reader Draw")
        t:eq(plugin.drawing, false, "reader remains stopped by policy")
        plugin:teardown()
    end)

    t:case("host teardown releases notebook input even when final COMMIT fails", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        local controller = plugin:notebookController()
        local store = support.newNotebookStore()
        controller.repository = store
        configureViewport(plugin)
        local session = controller:openNotebook(1)
        t:check(session ~= nil, "notebook opened")
        session:surface():addStroke({ 1, 1, 2, 2 }, 2, 4, 1)
        store.fail_transaction = "commit"
        plugin:teardown()
        t:eq(plugin.notebooks, nil, "destroyed controller is forgotten")
        t:eq(plugin.notebook_input, nil, "destroyed adapter is forgotten")
        t:eq(require("ink_input_controller"):activeOwner(), nil,
            "global callback never points at the destroyed host")
        t:eq(session:stateName(), "closed", "retry-only page was force-closed")
    end)

    t:case("repository preflight failure preserves ReaderUI drawing", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        local reader_lease = plugin.input_lease
        local controller = plugin:notebookController()
        local store = support.newNotebookStore()
        store.fail_get_notebook = "db_read_failed"
        controller.repository = store
        configureViewport(plugin)
        local session, err = controller:openNotebook(1)
        t:eq(session, nil, "metadata failure stops before handoff")
        t:eq(err, "db_read_failed", "repository reason preserved")
        t:eq(plugin.drawing, true, "ReaderUI Draw remains active")
        t:eq(plugin.input_lease, reader_lease, "same reader lease remains installed")

        controller.repository = nil
        controller.repository_factory = function() return nil, "open_failed" end
        local unopened, open_err = controller:openNotebook(1)
        t:eq(unopened, nil, "database open failure stops before handoff")
        t:eq(open_err, "open_failed", "open reason preserved")
        t:eq(plugin.drawing, true, "database failure also preserves Draw")
        t:eq(plugin.input_lease, reader_lease, "capture still belongs to ReaderUI")
        plugin:teardown()
    end)

    t:case("ReaderUI sheet is durably freed before notebook raster opens", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        local old_surface = { closed = false }
        plugin.canvas_open = true
        plugin.session = {
            flush = function() return true end,
            cache = function() return nil end,
            closeCanvas = function()
                old_surface.closed = true
                return true
            end,
            close = function() return true end,
        }
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        configureViewport(plugin)
        local notebook = controller:openNotebook(1)
        t:check(notebook ~= nil, "notebook opened after durable handoff")
        t:eq(old_surface.closed, true, "EPUB raster was released first")
        t:eq(plugin.canvas_open, false, "old sheet is no longer active")
        controller:closeNotebook()
        plugin:teardown()
    end)

    t:case("failed sheet flush blocks notebook without dismantling ReaderUI", function()
        ctx.reset()
        local plugin = support.newPlugin(ctx.JustDraw, ctx.env)
        ctx.env.UIManager:flush()
        plugin:setDrawing(true)
        local reader_lease = plugin.input_lease
        local close_calls = 0
        plugin.canvas_open = true
        plugin.session = {
            flush = function() return nil, "commit_failed" end,
            cache = function() return nil end,
            closeCanvas = function() close_calls = close_calls + 1; return true end,
        }
        local controller = plugin:notebookController()
        controller.repository = support.newNotebookStore()
        configureViewport(plugin)
        local notebook, err = controller:openNotebook(1)
        t:eq(notebook, nil, "handoff refused")
        t:eq(err, "commit_failed", "durability reason preserved")
        t:eq(close_calls, 0, "retry surface was not closed")
        t:eq(plugin.canvas_open, true, "sheet remains visible")
        t:eq(plugin.drawing, true, "reader drawing remains active")
        t:eq(plugin.input_lease, reader_lease, "reader retains capture")
        plugin.canvas_open = false
        plugin.session = nil
        plugin:teardown()
    end)
end
