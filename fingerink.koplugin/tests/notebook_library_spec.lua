return function(ctx)
    local t = ctx.t
    local Library = require("ink_notebook_library")

    t:describe("standalone notebooks / library window")

    local function rows(count)
        local out = {}
        for i = 1, count do
            out[i] = { id = i, title = "Notebook " .. i, page_count = i,
                updated_at = 1000 - i }
        end
        return out
    end

    t:case("loading paints before a bounded metadata query", function()
        ctx.reset()
        local calls = 0
        local controller = {}
        function controller:listNotebookBatch(_, limit)
            calls = calls + 1
            t:eq(limit, 50, "UI requests one bounded batch")
            return { items = rows(20), has_more = false, writable = true }
        end
        local opened
        local library = Library:new{
            controller = controller,
            on_open = function(item) opened = item.id end,
        }
        ctx.env.UIManager:show(library)
        library:markShown()
        library:startLoading()
        t:eq(calls, 0, "query waits for next tick")
        t:eq(library.loading, true, "loading state is visible first")
        ctx.env.UIManager:flush()
        t:eq(calls, 1, "one query ran")
        t:check(#library:_visibleItems() <= library.rows_per_screen,
            "only visible rows are built")
        local first_row = library.layout[1]
        first_row[2].callback()
        t:eq(opened, nil, "Actions never opens the notebook")
        first_row[1].callback()
        t:eq(opened, 1, "row body opens the notebook")
    end)

    t:case("covered library becomes stale without querying", function()
        ctx.reset()
        local calls = 0
        local controller = {}
        function controller:listNotebookBatch()
            calls = calls + 1
            return { items = rows(2), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        t:eq(calls, 1, "initial load")
        library:markStale()
        t:eq(calls, 1, "marking stale is side-effect free")
        library:refreshIfStale()
        t:eq(calls, 1, "reload is deferred")
        ctx.env.UIManager:flush()
        t:eq(calls, 2, "one reload on return")
    end)

    t:case("an explicit first-batch reload consumes the matching stale change", function()
        ctx.reset()
        local calls = 0
        local controller = {}
        function controller:listNotebookBatch()
            calls = calls + 1
            return { items = rows(2), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        library:markStale()
        library:_loadBatch(nil, 1, false, library.stale_generation)
        ctx.env.UIManager:flush()
        t:eq(calls, 2, "mutation reloads exactly once")
        t:eq(library.stale, false, "applied reload consumes its invalidation")
        library:refreshIfStale(); ctx.env.UIManager:flush()
        t:eq(calls, 2, "later editor close does not repeat the query")
    end)

    t:case("retrying a stale refresh consumes the original invalidation", function()
        ctx.reset()
        local calls = 0
        local controller = {}
        function controller:listNotebookBatch()
            calls = calls + 1
            if calls == 2 then return nil, "read failed" end
            return { items = rows(2), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        library:markStale()
        library:refreshIfStale(); ctx.env.UIManager:flush()
        t:eq(library.stale, true, "failed refresh retains its invalidation")
        local footer = library.layout[#library.layout]
        footer[3].callback()
        ctx.env.UIManager:flush()
        t:eq(calls, 3, "retry performs one replacement query")
        t:eq(library.stale, false, "successful retry consumes matching stale state")
        library:refreshIfStale(); ctx.env.UIManager:flush()
        t:eq(calls, 3, "later return performs no redundant query")
    end)

    t:case("title validation matches the repository byte limit", function()
        t:eq(Library.validTitle("  Notes  "), "Notes", "whitespace trimmed")
        local title, empty = Library.validTitle("   ")
        t:eq(title, nil, "empty rejected")
        t:eq(empty, "invalid_name", "empty code")
        local long, reason = Library.validTitle(string.rep("x", 256))
        t:eq(long, nil, "256 bytes rejected")
        t:eq(reason, "name_too_long", "length code")
    end)

    t:case("read-only mode keeps rows openable and disables mutations", function()
        ctx.reset()
        local opened
        local controller = {}
        function controller:listNotebookBatch()
            return { items = rows(3), has_more = false, writable = false,
                read_only_code = "schema_newer" }
        end
        local library = Library:new{
            controller = controller,
            on_open = function(item) opened = item.id end,
        }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        t:eq(#library:_visibleItems(), 3, "read-only rows remain visible")
        local first_row = library.layout[1]
        first_row[1].callback()
        t:eq(opened, 1, "read-only notebook opens")
        local footer = library.layout[#library.layout]
        footer[2]:paintTo()
        t:eq(footer[2].enabled, false, "New notebook disabled before callback")
    end)

    t:case("an empty future-schema library explains why creation is disabled", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = false,
                read_only_code = "schema_newer" }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local status = library.layout[1][1]
        t:check(status.text:find("Read-only", 1, true) ~= nil,
            "read-only state replaces the writable empty prompt")
        local footer = library.layout[#library.layout]
        footer[2]:paintTo()
        t:eq(footer[2].enabled, false, "creation stays disabled")
    end)

    t:case("failed continuation keeps the current batch and offers retry", function()
        ctx.reset()
        local calls = 0
        local controller = {}
        function controller:listNotebookBatch(cursor)
            calls = calls + 1
            if cursor then return nil, "read failed" end
            return { items = rows(50), has_more = true, writable = true,
                next_cursor = { updated_at = 950, id = 50 } }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local retained = library.batch
        while library.screen_in_batch < library:_screenCount() do library:nextScreen() end
        library:nextScreen(); ctx.env.UIManager:flush()
        t:eq(library.batch, retained, "visible batch retained")
        t:eq(library.cursor_index, 1, "cursor did not advance")
        local footer = library.layout[#library.layout]
        t:eq(footer[3].text, "Try again", "retry is explicit in footer")
    end)

    t:case("rotation replaces gesture ranges with the rebuilt screen geometry", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        local previous_range = library.ges_events.Tap[1].range
        library.selected = { x = 9, y = 99 }
        local old_w, old_h = ctx.env.Device.screen.w, ctx.env.Device.screen.h
        ctx.env.Device.screen.w = 800
        ctx.env.Device.screen.h = 600
        library:onSetDimensions()
        t:check(library.ges_events.Tap[1].range ~= previous_range,
            "gesture range was rebuilt")
        t:eq(library.ges_events.Tap[1].range.w, 800, "new width is active")
        t:eq(library.ges_events.Tap[1].range.h, 600, "new height is active")
        t:check(library.selected.y <= #library.layout,
            "focus remains inside the rebuilt rows")
        ctx.env.Device.screen.w, ctx.env.Device.screen.h = old_w, old_h
    end)

    t:case("create success followed by open failure refreshes the first batch", function()
        ctx.reset()
        local calls = 0
        local created = { id = 9, title = "Created", page_count = 1 }
        local controller = {}
        function controller:listNotebookBatch()
            calls = calls + 1
            return { items = calls == 1 and {} or { created },
                has_more = false, writable = true }
        end
        function controller:createNotebook() return created end
        local library = Library:new{
            controller = controller,
            on_open = function() return nil, "open_failed" end,
        }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local dialog = library:showCreateDialog()
        dialog._values[1] = "Created"
        dialog.buttons[1][2].callback()
        ctx.env.UIManager:flush()
        t:eq(calls, 2, "failed open reloads current ordering")
        t:eq(library.batch.items[1].id, 9, "created notebook remains visible")
    end)

    t:case("create controls repaint through the owning dialog", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local dialog = library:showCreateDialog()
        t:eq(dialog.added_widget.parent, dialog, "radio buttons inherit dialog parent")
        t:eq(dialog.added_widget.show_parent, dialog,
            "radio buttons dirty the top-level dialog")
        library:shutdown()
    end)

    t:case("shutdown closes every library-owned top-level dialog", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        ctx.env.UIManager:show(library)
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        library:showCreateDialog()
        library:_showInfo("Couldn’t create this notebook. Try again.")
        t:eq(#ctx.env.UIManager._window_stack, 3,
            "library and two owned dialogs are shown")
        library:shutdown()
        t:eq(#ctx.env.UIManager._window_stack, 1,
            "all owned dialogs are removed")
        t:eq(ctx.env.UIManager._window_stack[1].widget, library,
            "coordinator still owns closing the library itself")
        ctx.env.UIManager:close(library)
    end)
end
