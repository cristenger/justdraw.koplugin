return function(ctx)
    local t = ctx.t
    local support = ctx.support

    local Controller = require("ink_notebook_controller")
    local Errors = require("ink_notebook_errors")
    local Layout = require("ink_notebook_layout")
    local NotebookUI = require("ink_notebook_ui")

    t:describe("standalone notebooks / UI contracts")

    t:case("physical layout preserves targets and paper separation", function()
        local screen = support.newScreen{ w = 1860, h = 2480, dpi = 300 }
        local right = Layout.compute{
            screen = screen, screen_w = 1860, screen_h = 2480,
            logical_w = 1184, logical_h = 1680, rail_side = "right",
        }
        local left = Layout.compute{
            screen = screen, screen_w = 1860, screen_h = 2480,
            logical_w = 1680, logical_h = 1184, rail_side = "left",
        }
        t:check(right.target_size >= 118, "10 mm target is DPI-scaled")
        t:eq(right.rail_rect.w, 1860, "toolbar uses the whole width")
        t:eq(left.rail_rect.x, 0, "old side preferences keep the toolbar at the top")
        t:check(right.paper_rect.y >= right.rail_rect.y + right.rail_rect.h,
            "paper starts below the toolbar")
        t:eq(left.paper_rect.w, 1860, "landscape paper also has no side rail")
        local compact = Layout.compute{
            screen = support.newScreen{ w = 600, h = 800, dpi = 160 },
            screen_w = 600, screen_h = 800,
            logical_w = 1184, logical_h = 1680, rail_side = "right",
        }
        t:check(compact ~= nil, "a compact 160-DPI profile still preserves targets")
        local too_small, reason = Layout.compute{
            screen = support.newScreen{ w = 600, h = 800, dpi = 300 },
            screen_w = 600, screen_h = 800,
            logical_w = 1184, logical_h = 1680, rail_side = "right",
        }
        t:eq(too_small, nil, "physically cramped profile is refused")
        t:eq(reason, "no_viewport", "failure is explicit")
    end)

    t:case("error normalization never exposes raw persistence reasons", function()
        t:eq(Errors.normalize("cannot commit", "save"), "page_save_failed", "commit normalized")
        t:eq(Errors.normalize("SQLITE_CORRUPT", "library"), "library_open_failed", "SQL normalized")
        t:eq(Errors.normalize("handler_error", "input"), "pen_input_failed", "input normalized")
        t:eq(Errors.normalize("database_conflict", "library"), "database_conflict",
            "rename conflict remains actionable")
    end)

    t:case("controller batches 50 rows with a keyset continuation", function()
        local requested
        local repo = { read_only = false }
        function repo:listNotebooks(opts)
            requested = opts.limit
            local rows = {}
            for i = 1, 51 do rows[i] = { id = i, updated_at = 1000 - i } end
            return rows
        end
        local controller = Controller.new{ repository = repo, schedule = function() end }
        local batch = controller:listNotebookBatch(nil, 50)
        t:eq(requested, 51, "one lookahead row requested")
        t:eq(#batch.items, 50, "lookahead row is not retained")
        t:eq(batch.has_more, true, "continuation advertised")
        t:eq(batch.next_cursor.id, 50, "cursor is last visible row")
        t:eq(batch.writable, true, "repository capability exposed")
    end)

    t:case("opening the library does not configure or hand off input", function()
        ctx.reset()
        local calls = {}
        local controller = {
            shutdown = function() calls[#calls + 1] = "shutdown"; return true end,
        }
        local library_factory = {}
        function library_factory:new(opts)
            return {
                opts = opts,
                markShown = function() end,
                startLoading = function() calls[#calls + 1] = "load" end,
                shutdown = function() return true end,
            }
        end
        local editor_factory = {}
        function editor_factory:new(opts) return opts end
        local plugin = {
            configureNotebookInteraction = function()
                calls[#calls + 1] = "configure"
                return true
            end,
        }
        local ui = NotebookUI.new{
            plugin = plugin, controller = controller,
            library_factory = library_factory, editor_factory = editor_factory,
        }
        t:check(ui:openLibrary() ~= nil, "library opens")
        t:eq(calls[1], "load", "only metadata loading starts")
        t:eq(calls[2], nil, "no capture configuration happened")
        ui:shutdown()
    end)

    t:case("editor diagnostics uses the shared notebook trace source", function()
        ctx.reset()
        local source
        local refresh_ms = 50
        local controller = {
            openNotebook = function() return {} end,
            shutdown = function() return true end,
        }
        local editor_factory = {}
        function editor_factory:new(opts)
            opts.onStateChanged = function() end
            opts.markShown = function() end
            opts.shutdown = function() end
            return opts
        end
        local plugin = {
            eraser = false, input_mode = "stylus", pen_width = 4,
            live_fast = true, notebook_rail_side = "right",
            configureNotebookInteraction = function() return true end,
            showDiagnostics = function(_, value) source = value end,
            setInputMode = function() return true end,
            setPenWidth = function() return true end,
            getDrawingRefreshInterval = function() return refresh_ms end,
            setDrawingRefreshInterval = function(_, ms) refresh_ms = ms; return ms end,
            setNotebookRailSide = function() end,
        }
        local ui = NotebookUI.new{
            plugin = plugin, controller = controller,
            editor_factory = editor_factory,
        }
        local editor = ui:openNotebook{ id = 1, title = "Private title" }
        editor.show_stylus_diagnostics()
        t:eq(source, "notebook", "notebook editor arms the shared trace session")
        t:eq(editor.get_drawing_refresh_ms(), 50, "the notebook reads the host's refresh setting")
        editor.set_drawing_refresh_ms(33)
        t:eq(refresh_ms, 33, "the notebook writes through the host's shared setter")
        ui:shutdown()
    end)

    t:case("recoverable input notices are deferred and generation safe", function()
        ctx.reset()
        local states = 0
        local editor = { onStateChanged = function() states = states + 1 end }
        local ui = NotebookUI.new{
            plugin = { configureNotebookInteraction = function() return true end },
            controller = { shutdown = function() return true end },
        }
        local callbacks = ui:_editorCallbacks(editor, ui.editor_generation)
        callbacks.on_error("queue_backpressure")
        t:eq(states, 1, "state refresh remains synchronous")
        t:eq(#ctx.env.notifications, 0, "notification is outside the input callback")
        ctx.env.UIManager:flush()
        t:eq(#ctx.env.notifications, 1, "recoverable rejection is visible")
        t:check(ctx.env.notifications[1]:find("write queue is busy", 1, true) ~= nil,
            "message is actionable and in English")

        callbacks.on_error("point_budget")
        ui.editor_generation = ui.editor_generation + 1
        ctx.env.UIManager:flush()
        t:eq(#ctx.env.notifications, 1,
            "a callback from the previous editor generation is discarded")
        ui:shutdown()
    end)

    t:case("a failed editor configuration destroys the unopened window", function()
        ctx.reset()
        local shutdowns = 0
        local controller = { shutdown = function() return true end }
        local editor_factory = {}
        function editor_factory:new()
            return { shutdown = function() shutdowns = shutdowns + 1 end }
        end
        local ui = NotebookUI.new{
            plugin = {
                configureNotebookInteraction = function()
                    return nil, "notebook_open"
                end,
            },
            controller = controller,
            editor_factory = editor_factory,
        }
        local editor, err = ui:openNotebook{ id = 1, title = "Blocked" }
        t:eq(editor, nil, "editor is not published")
        t:eq(err, "notebook_open", "configuration error is preserved")
        t:eq(shutdowns, 1, "unopened widget is destroyed")
        t:eq(ui.editor, nil, "coordinator remains in library state")
        ui:shutdown()
    end)

    t:case("all visible notebook copy is authored in English", function()
        local files = {
            "ink_notebook_library.lua", "ink_notebook_editor.lua", "ink_notebook_ui.lua",
        }
        local combined = ""
        for i = 1, #files do
            local file = assert(io.open(ctx.plugin_dir .. "/" .. files[i], "rb"))
            combined = combined .. file:read("*a")
            file:close()
        end
        for _, required in ipairs({
            "Notebooks", "New notebook", "Loading page…", "Retry saving",
            "Exit notebook", "Delete notebook", "Read-only",
            "Paper style", "Blank", "Ruled", "Squared", "Dotted",
        }) do
            t:check(combined:find(required, 1, true) ~= nil, required .. " is present")
        end
        for _, forbidden in ipairs({ "Cuadernos", "Nuevo cuaderno", "Borrar página",
            "Paper size", "A5 portrait", "Letter portrait" }) do
            t:eq(combined:find(forbidden, 1, true), nil, forbidden .. " is absent")
        end
    end)
    --- A notebook page is born with the shape of the paper under the header,
    --- in millimetres at this screen's density, so it fills the paper's width
    --- on the screen it was made on. The numbers are pinned: the header's
    --- height is part of the shape, and a header that changes height would
    --- otherwise letterbox every notebook created afterwards in silence.
    --- Under the suite's fakes Size.* does not scale with DPI, so the 300 dpi
    --- rows differ from tests/top_toolbar_native.lua, which pins the runtime.
    ---
    --- The strips are asserted on a real Transform built the way the session
    --- builds one -- `Editor:viewport()` hands it `paper_rect`, never the
    --- layout's own `fit_rect`, which no production code reads -- so this
    --- fails if the paper the reader actually writes on grows a margin.
    t:case("a new page takes the shape of the paper and fills its width at every profile", function()
        local Transform = require("ink_canvas_transform")
        local PINNED = {
            { w = 600, h = 800, dpi = 160, page_w = 762, page_h = 843 },
            { w = 800, h = 600, dpi = 160, page_w = 1016, page_h = 589 },
            { w = 1860, h = 2480, dpi = 300, page_w = 1260, page_h = 1527 },
            { w = 2480, h = 1860, dpi = 300, page_w = 1680, page_h = 1107 },
            -- reMarkable-class, and the one profile here where height is the
            -- limiting axis and the width does not divide exactly: without
            -- fitPage rounding the advisory fit is a pixel short of the paper.
            { w = 1404, h = 1872, dpi = 227, page_w = 1257, page_h = 1524 },
        }
        for _, p in ipairs(PINNED) do
            local screen = support.newScreen{ w = p.w, h = p.h, dpi = p.dpi }
            local where = p.w .. "x" .. p.h .. "@" .. p.dpi
            local page = assert(Layout.screenPage{ screen = screen, screen_w = p.w, screen_h = p.h })
            t:eq(page.logical_w, p.page_w, where .. " page width in units")
            t:eq(page.logical_h, p.page_h, where .. " page height in units")
            t:eq(page.template_kind, nil, where .. " shape carries no ruling")
            local layout = assert(Layout.compute{
                screen = screen, screen_w = p.w, screen_h = p.h,
                logical_w = page.logical_w, logical_h = page.logical_h,
            })
            local paper = layout.paper_rect
            t:check(math.floor(layout.rail_rect.w / 8) >= layout.target_size,
                where .. " each button keeps its physical target")

            -- What the reader writes on: the page fitted into the paper the
            -- editor publishes as its viewport.
            local transform = assert(Transform.new{
                logical_w = page.logical_w, logical_h = page.logical_h,
                fit_rect = paper, clip_rect = paper,
            })
            -- Sub-pixel tolerance: the drawn size is `logical * scale` in
            -- floating point, so an exactly-fitting axis lands an ULP either
            -- side of the paper's integer edge.
            local EPS = 0.001
            t:eq(transform.offset_x, paper.x, where .. " no strip on the left")
            t:check(paper.w - transform.draw_w > -EPS and paper.w - transform.draw_w < 1,
                where .. " no strip on the right, got "
                    .. tostring(paper.w - transform.draw_w))
            t:eq(transform.offset_y, paper.y, where .. " the page starts where the paper starts")
            t:check(paper.h - transform.draw_h > -EPS,
                where .. " and never reaches past the paper's bottom")

            local fit = layout.fit_rect
            t:eq(fit.x, 0, where .. " the advisory fit has no strip either")
            t:eq(fit.w, p.w, where .. " across the whole paper")
            t:check(paper.h - fit.h >= 0 and paper.h - fit.h <= 1,
                where .. " at most one pixel row of paper is left under it")
            t:check(math.abs(fit.w / page.logical_w - fit.h / page.logical_h) < 0.002,
                where .. " aspect fit is preserved to pixel rounding")
        end
    end)

    t:case("a screen too small for the controls refuses a page shape too", function()
        local page, reason = Layout.screenPage{
            screen = support.newScreen{ w = 600, h = 800, dpi = 300 },
            screen_w = 600, screen_h = 800,
        }
        t:eq(page, nil, "no shape without a viewport")
        t:eq(reason, "no_viewport", "for the same reason compute refuses")
    end)


    t:case("a screen too narrow for nine controls refuses to open, with the reason", function()
        ctx.reset()
        local NotebookLayout = require("ink_notebook_layout")
        local real = NotebookLayout.screenPage
        NotebookLayout.screenPage = function() return nil, "no_viewport" end
        local configured, opened = 0, 0
        local controller = {
            openNotebook = function() opened = opened + 1; return {} end,
            shutdown = function() return true end,
        }
        local built = 0
        local editor_factory = {}
        function editor_factory:new(opts) built = built + 1; return opts end
        local plugin = {
            configureNotebookInteraction = function() configured = configured + 1; return true end,
        }
        local ui = NotebookUI.new{ plugin = plugin, controller = controller,
            editor_factory = editor_factory }
        local shown = #ctx.env.UIManager._window_stack
        local editor, err = ui:openNotebook{ id = 1 }
        NotebookLayout.screenPage = real
        t:eq(editor, nil, "no editor")
        t:eq(err, "no_viewport", "the reason")
        t:eq(built, 0, "no editor was even built")
        t:eq(configured, 0, "capture never changed hands")
        t:eq(opened, 0, "the notebook was not opened")
        t:eq(#ctx.env.UIManager._window_stack, shown + 1, "the reader is told why")
        ui:shutdown()
    end)
end
