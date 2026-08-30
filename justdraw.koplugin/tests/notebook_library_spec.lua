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

    --- What VerticalGroup does when it paints: each child starts where the
    --- running total of the ones above it ended. Measuring the same way is the
    --- only honest way to ask whether the last child is still on the screen.
    local function stackedHeights(group)
        local offsets, total = {}, 0
        for i = 1, #group do
            offsets[i] = total
            total = total + group[i]:getSize().h
        end
        return offsets, total
    end

    --[[--
    The footer sank one button's worth of chrome per notebook.

    `_rebuild` budgets the column in outer boxes, but KOReader's Button reads
    `height` as its label box and grows by padding and border on top. In a
    VerticalGroup those excesses stack, so the toolbar drifted down as rows were
    added: on a Kindle Scribe, half of it was gone at three notebooks and all of
    it at seven, taking Previous / New notebook / Next with it.
    ]]
    t:case("the footer stays on screen however many notebooks there are", function()
        ctx.reset()
        local count = 0
        local controller = {}
        function controller:listNotebookBatch()
            return { items = rows(count), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown()
        local screen_h = ctx.env.Device.screen:getHeight()
        for n = 0, library.rows_per_screen do
            count = n
            library:_loadBatch(nil, 1, false)
            ctx.env.UIManager:flush()
            local offsets, total = stackedHeights(library[1])
            local footer = #library[1]
            t:check(total <= screen_h, n .. " notebooks fit the screen ("
                .. total .. " <= " .. screen_h .. ")")
            t:check(offsets[footer] + library[1][footer]:getSize().h <= screen_h,
                "the whole footer is on screen with " .. n .. " notebooks")
            t:eq(#library:_visibleItems(), math.min(n, library.rows_per_screen),
                "every notebook that fits is drawn")
        end
    end)

    t:case("a button occupies the height the column budgeted for it", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = rows(3), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local row = library.layout[1][1]
        local chrome = require("ink_notebook_layout").buttonChrome()
        t:check(chrome > 0, "the fake models a chrome to be wrong about")
        t:eq(row:getSize().h, row.height + chrome,
            "the widget is taller than the label box it was given")
        local _, total = stackedHeights(library[1])
        t:eq(total, ctx.env.Device.screen:getHeight(),
            "and the column still lands exactly on the screen edge")
    end)

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

    t:case("a rename database conflict is explicit and not retryable", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch() return nil, "database_conflict" end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local status = library.layout[1][1]
        t:check(status.text:find("Both JustDraw and FingerInk", 1, true) ~= nil,
            "the two histories are named")
        status:paintTo()
        t:eq(status.enabled, false, "retry cannot resolve an on-disk conflict")
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
        t:check(#dialog.added_widgets >= 1, "the dialog carries added widgets")
        for i, widget in ipairs(dialog.added_widgets) do
            t:eq(widget.parent, dialog,
                "widget " .. i .. " inherits dialog parent")
            t:eq(widget.show_parent, dialog,
                "widget " .. i .. " dirties the top-level dialog")
        end
        library:shutdown()
    end)

    t:case("closing a library modal twice closes it once", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local dialog = library:showCreateDialog()
        local closes = 0
        local real_close = ctx.env.UIManager.close
        ctx.env.UIManager.close = function(self, w, ...)
            if w == dialog then closes = closes + 1 end
            return real_close(self, w, ...)
        end
        t:eq(library:_closeModal(dialog), true, "the first close did something")
        t:eq(library:_closeModal(dialog), false, "the second had nothing to close")
        ctx.env.UIManager.close = real_close
        t:eq(closes, 1, "and UIManager saw exactly one close")
        library:shutdown()
    end)

    --- Paper size and paper style are two questions, so they are two radio
    --- groups: RadioButtonTable keeps one checked button per widget, and one
    --- table holding both would make choosing Dotted un-choose A5.
    t:case("paper size and paper style are independent choices", function()
        ctx.reset()
        local controller = {}
        local spec
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        function controller:createNotebook(s)
            spec = s
            return { id = 3, title = s.title, page_count = 1 }
        end

        local function create(choose)
            local library = Library:new{ controller = controller }
            library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
            local dialog = library:showCreateDialog()
            local groups = {}
            for _, widget in ipairs(dialog.added_widgets) do
                groups[widget.radio_buttons[1][1].text] = widget
            end
            if choose then choose(groups) end
            dialog._values[1] = "Notes"
            dialog.buttons[1][2].callback()
            ctx.env.UIManager:flush()
            library:shutdown()
            return groups
        end

        local groups = create(nil)
        t:check(groups["Paper size"] ~= nil, "a paper size group")
        t:check(groups["Paper style"] ~= nil, "a paper style group")
        t:check(groups["Paper size"] ~= groups["Paper style"],
            "and they are separate widgets")
        t:eq(spec.template_kind, "blank", "a notebook is blank unless asked")
        t:eq(spec.logical_w, 1184, "on A5 portrait by default")

        create(function(g) g["Paper style"].button_select_callback{ value = "dots" } end)
        t:eq(spec.template_kind, "dots", "the chosen style is what gets created")
        t:eq(spec.logical_w, 1184, "and the size choice is untouched by it")

        create(function(g)
            g["Paper size"].button_select_callback{ value = "a5_landscape" }
            g["Paper style"].button_select_callback{ value = "ruled" }
        end)
        t:eq(spec.template_kind, "ruled", "both choices survive together")
        t:eq(spec.logical_w, 1680, "landscape")
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
