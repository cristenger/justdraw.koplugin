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
        t:eq(right.rail_rect.x + right.rail_rect.w, 1860, "right rail is on edge")
        t:eq(left.rail_rect.x, 0, "left rail is on edge")
        t:check(right.paper_rect.x + right.paper_rect.w <= right.rail_rect.x,
            "paper never overlaps right rail")
        t:check(left.paper_rect.x >= left.rail_rect.w,
            "paper never overlaps left rail")
        t:eq(Layout.preset("a5_portrait").logical_w, 1184, "A5 preset exact")
        t:eq(Layout.preset("letter_portrait").logical_h, 2235, "Letter preset exact")
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
            "Exit notebook", "Delete notebook", "Read-only", "Paper size",
        }) do
            t:check(combined:find(required, 1, true) ~= nil, required .. " is present")
        end
        for _, forbidden in ipairs({ "Cuadernos", "Nuevo cuaderno", "Borrar página" }) do
            t:eq(combined:find(forbidden, 1, true), nil, forbidden .. " is absent")
        end
    end)
end
