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
        for i, widget in ipairs(dialog.paper_options) do
            t:eq(widget.parent, dialog,
                "widget " .. i .. " inherits dialog parent")
            t:eq(widget.show_parent, dialog,
                "widget " .. i .. " dirties the top-level dialog")
        end
        library:shutdown()
    end)

    t:case("creation options use the dialog width, with a short-side fallback", function()
        ctx.reset()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local original = MultiInputDialog.new
        local screen = ctx.env.Device.screen
        local old_w, old_h = screen.w, screen.h
        screen.w, screen.h = 1448, 1072
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        for _, available in ipairs({ 371, false }) do
            MultiInputDialog.new = function(class, opts)
                local dialog = original(class, opts)
                dialog.getAddedWidgetAvailableWidth = available
                    and function() return available end or nil
                return dialog
            end
            local dialog = library:showCreateDialog()
            t:eq(#dialog.paper_options, 1, "the style group remains")
            for _, widget in ipairs(dialog.paper_options) do
                t:eq(widget.width, (available or math.floor(1072 * 0.72)) - 18,
                    "option group fits the dialog in landscape")
            end
            library:_closeModal(dialog)
        end
        MultiInputDialog.new = original
        screen.w, screen.h = old_w, old_h
        library:shutdown()
    end)

    t:case("create options shrink for the keyboard and survive rotation without an extra creation", function()
        ctx.reset()
        local screen = ctx.env.Device.screen
        local old_w, old_h, old_keyboard = screen.w, screen.h, screen.keyboard_height
        screen.w, screen.h = 1448, 1072
        screen.keyboard_height = screen.h - 150
        local writes = 0
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        function controller:createNotebook()
            writes = writes + 1
            return { id = 1 }
        end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local dialog = library:showCreateDialog()
        dialog._values[1] = "A long unsaved notebook name"
        dialog.paper_options[1]:select("dots")
        local viewport = dialog.cropping_widget
        local full_h = viewport[1]:getSize().h
        t:check(viewport:getSize().h < full_h, "options scroll above the keyboard")
        t:eq(viewport.show_parent, dialog, "scroll feedback uses the modal owner")
        dialog:onCloseKeyboard()
        t:eq(viewport:getSize().h, full_h, "hiding keyboard reveals all options")
        dialog:onShowKeyboard()
        t:check(viewport:getSize().h < full_h, "showing it again recomputes the budget")
        screen.keyboard_height = 0
        dialog:onKeyboardHeightChanged()
        t:eq(viewport:getSize().h, full_h, "a new keyboard layout recomputes the budget")
        dialog:onCloseKeyboard()
        screen.w, screen.h = 1072, 1448
        library:onSetDimensions()
        local rotated = library.create_dialog
        t:check(rotated ~= dialog, "rotation rebuilds the form at the new screen size")
        t:eq(library.modal_widgets[dialog], nil, "old form was closed")
        local state = rotated:creationState()
        t:eq(state.title, "A long unsaved notebook name")
        t:eq(state.paper, "dots")
        t:eq(state.keyboard_visible, false, "rotation keeps keyboard hidden")
        t:eq(writes, 0, "rotation does not create a notebook")
        dialog.buttons[1][2].callback()
        t:eq(writes, 0, "a late callback from the old form cannot create")
        rotated.buttons[1][1].callback()
        t:eq(library.create_dialog, nil, "Cancel releases the tracked form")
        t:eq(writes, 0, "Cancel does not create")
        library:shutdown()
        screen.w, screen.h, screen.keyboard_height = old_w, old_h, old_keyboard
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

    --- The dialog asks one question about the paper, its style. The shape is
    --- not a choice: a notebook is born with the shape of the paper under the
    --- header on this screen (Layout.screenPage), computed when Create is
    --- pressed so a form that survived a rotation stores the current screen's.
    t:case("a new notebook takes the screen's page shape and the chosen style", function()
        ctx.reset()
        local Layout = require("ink_notebook_layout")
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
            for _, widget in ipairs(dialog.paper_options) do
                groups[widget.radio_buttons[1][1].text] = widget
            end
            if choose then choose(groups) end
            dialog._values[1] = "Notes"
            dialog.buttons[1][2].callback()
            ctx.env.UIManager:flush()
            library:shutdown()
            return groups
        end

        local expected = assert(Layout.screenPage{ screen = ctx.env.Device.screen })
        local groups = create(nil)
        t:eq(groups["Paper size"], nil, "no paper size question")
        t:check(groups["Paper style"] ~= nil, "a paper style group")
        t:eq(spec.template_kind, "blank", "a notebook is blank unless asked")
        t:eq(spec.logical_w, expected.logical_w, "as wide as the paper under the header")
        t:eq(spec.logical_h, expected.logical_h, "and as tall")
        t:eq(spec.title, "Notes", "with its name")

        create(function(g) g["Paper style"].button_select_callback{ value = "dots" } end)
        t:eq(spec.template_kind, "dots", "the chosen style is what gets created")
        t:eq(spec.logical_w, expected.logical_w, "and the shape is untouched by it")

        -- Every kind the renderer can draw is offered, once, and none else.
        local Paper = require("ink_paper")
        local offered, labels = {}, {}
        for _, row in ipairs(groups["Paper style"].radio_buttons) do
            for _, button in ipairs(row) do
                if button.value then
                    offered[button.value] = (offered[button.value] or 0) + 1
                    labels[button.value] = button.text
                end
            end
        end
        for kind in pairs(Paper.KINDS) do
            t:eq(offered[kind], 1, kind .. " is offered once")
        end
        for kind in pairs(offered) do
            t:eq(Paper.KINDS[kind], true, kind .. " is a kind that draws")
        end
        t:eq(labels.ruled_narrow, "Narrow ruled", "narrow ruled, in English")
        t:eq(labels.checklist, "Checklist", "checklist, in English")
        for _, kind in ipairs({ "ruled_narrow", "checklist" }) do
            create(function(g) g["Paper style"].button_select_callback{ value = kind } end)
            t:eq(spec.template_kind, kind, kind .. " is what gets created")
        end
    end)

    t:case("a dialog rebuilt after rotation stores the shape of the screen it creates on", function()
        ctx.reset()
        local Layout = require("ink_notebook_layout")
        local screen = ctx.env.Device.screen
        local old_w, old_h = screen.w, screen.h
        local spec
        local controller = {}
        function controller:listNotebookBatch()
            return { items = {}, has_more = false, writable = true }
        end
        function controller:createNotebook(s) spec = s; return { id = 4 } end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local dialog = library:showCreateDialog()
        dialog._values[1] = "Rotated"
        -- Everything that runs transposed runs inside this pcall, so a raise
        -- cannot leave the shared fake screen rotated for every later case.
        local rebuilt, expected
        screen.w, screen.h = old_h, old_w
        local ok, err = pcall(function()
            library:onSetDimensions()
            rebuilt = library.create_dialog
            rebuilt._values[1] = "Rotated"
            rebuilt.buttons[1][2].callback()
            ctx.env.UIManager:flush()
            expected = assert(Layout.screenPage{ screen = screen })
        end)
        screen.w, screen.h = old_w, old_h
        t:check(ok, "the rotated form was driven without raising: " .. tostring(err))
        t:check(rebuilt ~= nil and rebuilt ~= dialog, "rotation rebuilt the form")
        t:eq(spec and spec.logical_w, expected and expected.logical_w,
            "the landscape paper's width")
        t:eq(spec and spec.logical_h, expected and expected.logical_h,
            "and height")
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
