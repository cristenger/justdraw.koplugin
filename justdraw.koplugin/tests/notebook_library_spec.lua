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
    The footer sank one button's worth of chrome per notebook, once.

    `_rebuild` budgets the column in outer boxes, but KOReader's Button reads
    `height` as its label box and grows by padding and border on top. In a
    VerticalGroup those excesses stack. The grid has one header row, one grid
    and one footer whatever the count, and this keeps it that way.
    ]]
    t:case("the header, grid and footer stay on screen however many notebooks there are", function()
        ctx.reset()
        local count = 0
        local controller = {}
        function controller:listNotebookBatch()
            return { items = rows(count), has_more = false, writable = true }
        end
        local library = Library:new{ controller = controller }
        library:markShown()
        local screen_h = ctx.env.Device.screen:getHeight()
        for n = 0, library.metrics.per_screen + 1 do
            count = n
            library:_loadBatch(nil, 1, false)
            ctx.env.UIManager:flush()
            local offsets, total = stackedHeights(library[1])
            local footer = #library[1]
            t:check(total <= screen_h, n .. " notebooks fit the screen ("
                .. total .. " <= " .. screen_h .. ")")
            t:check(offsets[footer] + library[1][footer]:getSize().h <= screen_h,
                "the whole footer is on screen with " .. n .. " notebooks")
            t:eq(#library.cards, math.min(n, library.metrics.per_screen),
                "every notebook that fits gets a card")
            for _, card in ipairs(library.cards) do
                t:check(card.dimen.y + card.dimen.h <= offsets[footer],
                    "no card reaches into the footer")
            end
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
        local row = library.header_buttons[1]
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
        local library_per
        local controller = {}
        function controller:listNotebookBatch(_, limit)
            calls = calls + 1
            t:check(limit <= 50, "UI requests one bounded batch")
            t:eq(limit % library_per, 0, "a whole number of screens")
            return { items = rows(20), has_more = false, writable = true }
        end
        local opened
        local library = Library:new{
            controller = controller,
            on_open = function(item) opened = item.id end,
        }
        library_per = library:_itemsPerScreen()
        ctx.env.UIManager:show(library)
        library:markShown()
        library:startLoading()
        t:eq(calls, 0, "query waits for next tick")
        t:eq(library.loading, true, "loading state is visible first")
        ctx.env.UIManager:flush()
        t:eq(calls, 1, "one query ran")
        t:eq(#library.cards, library.metrics.per_screen, "only the visible cards are built")
        library:holdCard(library.cards[1])
        t:eq(opened, nil, "holding a card never opens the notebook")
        local d = library.cards[1].dimen
        library:onTap(nil, { pos = { x = d.x + 2, y = d.y + 2 } })
        t:eq(opened, 1, "tapping the card opens the notebook")
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
        library.footer_buttons[3].callback()
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
        t:eq(#library.cards, 3, "read-only cards remain visible")
        library:activateCard(library.cards[1])
        t:eq(opened, 1, "read-only notebook opens")
        local create = library.header_buttons[1]
        t:eq(create.text, "New notebook", "the first header action")
        create:paintTo()
        t:eq(create.enabled, false, "New notebook disabled before callback")
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
        local status = library.status_button
        t:check(status.text:find("Read-only", 1, true) ~= nil,
            "read-only state replaces the writable empty prompt")
        library.header_buttons[1]:paintTo()
        t:eq(library.header_buttons[1].enabled, false, "creation stays disabled")
    end)

    t:case("a rename database conflict is explicit and not retryable", function()
        ctx.reset()
        local controller = {}
        function controller:listNotebookBatch() return nil, "database_conflict" end
        local library = Library:new{ controller = controller }
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        local status = library.status_button
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
        t:eq(library.footer_buttons[3].text, "Try again", "retry is explicit in footer")
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

    t:describe("standalone notebooks / gallery grid")

    local function metrics(o)
        local base = { width = 600, height = 600, min_card = 189, gap = 13, pad = 9,
            text_h = 52, landscape = false, aspect = 4 / 3 }
        for k, v in pairs(o or {}) do base[k] = v end
        return Library.gridMetrics(base), base
    end

    local function noOverlap(m, o)
        for i = 1, m.per_screen do
            local a = m.rect(i)
            if a.x < 0 or a.y < 0 or a.x + a.w > o.width or a.y + a.h > o.height then
                return false, "card " .. i .. " leaves the grid"
            end
            for j = i + 1, m.per_screen do
                local b = m.rect(j)
                if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                    return false, "cards " .. i .. " and " .. j .. " overlap"
                end
            end
        end
        return true
    end

    t:case("three columns upright, four on its side, two when 30 mm do not fit", function()
        -- A Scribe: 1860 x 2480 at 300 dpi, 30 mm = 354 px.
        local scribe, so = metrics{ width = 1860, height = 2100, min_card = 354, gap = 24, pad = 18, text_h = 98 }
        t:eq(scribe.cols, 3, "three across on a Scribe")
        t:check(scribe.card_w >= 354, "each at least 30 mm")
        t:check(noOverlap(scribe, so))
        local side, sideo = metrics{ width = 2480, height = 1500, min_card = 354, gap = 24, pad = 18,
            text_h = 98, landscape = true }
        t:eq(side.cols, 4, "four across on its side")
        t:check(noOverlap(side, sideo))
        -- A 6" Kindle: 1072 wide at 300 dpi. Three cards would be 325 px.
        local kindle, ko = metrics{ width = 1072, height = 1100, min_card = 354, gap = 24, pad = 18, text_h = 98 }
        t:eq(kindle.cols, 2, "two when three would be under 30 mm")
        t:eq(kindle.rows, 2, "and two rows of cards still 30 mm tall")
        t:check(kindle.card_h >= 354, "tall enough to hit")
        t:check(noOverlap(kindle, ko))
        local tiny = metrics{ width = 300, height = 200, min_card = 354 }
        t:eq(tiny.cols, 1, "one column only when two cannot fit")
        t:eq(tiny.rows, 1, "at least one row")
        t:check(tiny.thumb_h >= 1, "a picture box, however small")
    end)

    t:case("header actions fold into More instead of shrinking, and Done never folds", function()
        local row = Library.headerButtons(1000, 120, false)
        t:eq(table.concat(row, ","), "new_notebook,new_folder,sort,select", "all four fit")
        local narrow, more = Library.headerButtons(400, 120, false)
        t:eq(table.concat(narrow, ","), "new_notebook,more,select", "narrow: folded")
        t:eq(table.concat(more, ","), "new_folder,sort", "the folded ones, in order")
        local sel, sel_more = Library.headerButtons(500, 120, true)
        t:eq(sel[#sel], "done", "Done stays on the row")
        t:eq(table.concat(sel, ","), "move,duplicate,more,done", "as many as fit")
        t:eq(table.concat(sel_more, ","), "export,delete", "the rest in More")
        local wide = Library.headerButtons(2000, 120, true, { "send" })
        t:eq(table.concat(wide, ","), "move,duplicate,export,delete,send,done", "Send joins the bulk actions")
    end)

    t:case("long Spanish titles are cut on a character, not a byte", function()
        local title = "Cuaderno de física cuántica — apuntes del año académico"
        local short = Library.shortTitle(title, 20)
        t:eq(short, "Cuaderno de física c…", "twenty characters and an ellipsis")
        t:eq(Library.shortTitle("Ñandú", 20), "Ñandú", "short titles untouched")
        t:check(Library.shortTitle(string.rep("é", 50), 10):match("^[\1-\127\194-\244][\128-\191]*") ~= nil,
            "still valid UTF-8 at the start")
    end)

    local function mixed(folders, notebooks)
        local items = {}
        for i = 1, folders do
            items[#items + 1] = { kind = "folder", id = i, name = "Folder " .. i, notebook_count = i }
        end
        for i = 1, notebooks do
            items[#items + 1] = { kind = "notebook", id = i, title = "Notebook " .. i, page_count = 1 }
        end
        return items
    end

    local function galleryController(items_for)
        local controller = { calls = {} }
        function controller:listNotebookBatch(cursor, limit, opts)
            self.calls[#self.calls + 1] = { cursor = cursor, limit = limit, opts = opts }
            return { items = items_for(opts or {}), has_more = false, writable = true }
        end
        return controller
    end

    local function open(controller, extra)
        local o = { controller = controller }
        for k, v in pairs(extra or {}) do o[k] = v end
        local library = Library:new(o)
        library:markShown(); library:startLoading(); ctx.env.UIManager:flush()
        return library
    end

    t:case("folders come first, open with a tap, and Back takes a card's place", function()
        ctx.reset()
        local controller = galleryController(function(opts)
            if opts.folder_id then return mixed(0, 5) end
            return mixed(2, 1)
        end)
        local opened
        local library = open(controller, { on_open = function(item) opened = item end })
        t:eq(library.cards[1].kind, "folder", "a folder first")
        t:eq(library.cards[3].kind, "notebook", "then notebooks")
        t:eq(controller.calls[1].opts.folder_id, nil, "the root")
        t:eq(controller.calls[1].opts.sort, "recent", "recent by default")
        library:activateCard(library.cards[1])
        ctx.env.UIManager:flush()
        t:eq(opened, nil, "a folder is not a notebook to open")
        t:eq(library.folder.id, 1, "inside the folder")
        t:eq(controller.calls[#controller.calls].opts.folder_id, 1, "listing the folder")
        t:eq(library.cards[1].kind, "back", "Back is the first card")
        t:eq(library:_itemsPerScreen(), library.metrics.per_screen - 1, "and costs one card")
        t:eq(#library.cards, math.min(library.metrics.per_screen, 6), "Back plus what fits")
        t:check(library.header_buttons[2].action_id == "new_folder", "the New folder action")
        library.header_buttons[2]:paintTo()
        t:eq(library.header_buttons[2].enabled, false, "no folder inside a folder")
        library:activateCard(library.cards[1])
        ctx.env.UIManager:flush()
        t:eq(library.folder, nil, "Back returns to the root")
        t:eq(library.cards[1].kind, "folder", "folders again")
        library:openFolder({ id = 2, name = "Two" })
        ctx.env.UIManager:flush()
        library:onClose()
        ctx.env.UIManager:flush()
        t:eq(library.folder, nil, "the Back key leaves the folder, not the library")
    end)

    t:case("paging in a folder keeps Back on every screen", function()
        ctx.reset()
        local controller = galleryController(function(opts)
            if opts.folder_id then return mixed(0, 9) end
            return {}
        end)
        local library = open(controller)
        library:openFolder({ id = 3, name = "Big" })
        ctx.env.UIManager:flush()
        local per = library:_itemsPerScreen()
        t:eq(controller.calls[#controller.calls].limit % per, 0, "batches of whole screens")
        local seen = {}
        repeat
            t:eq(library.cards[1].kind, "back", "Back on screen " .. library.screen_number)
            for i = 2, #library.cards do seen[#seen + 1] = library.cards[i].item.id end
        until not library:nextScreen()
        t:eq(#seen, 9, "every notebook shown once")
    end)

    t:case("a folder and a notebook with the same id are two choices", function()
        ctx.reset()
        local library = open(galleryController(function() return mixed(3, 3) end))
        library:setSelecting(true)
        local folder7, notebook7
        for _, card in ipairs(library.cards) do
            if card.kind == "folder" and card.item.id == 1 then folder7 = card end
            if card.kind == "notebook" and card.item.id == 1 then notebook7 = card end
        end
        t:check(folder7 and notebook7, "both on screen")
        library:activateCard(folder7)
        library:activateCard(notebook7)
        t:eq(library.selection_count, 2, "two selected")
        t:eq(#library:selectedItems("notebook"), 1, "one notebook")
        t:eq(#library:selectedItems("folder"), 1, "one folder")
        t:eq(Library.itemKey(folder7.item) ~= Library.itemKey(notebook7.item), true, "typed keys")
        library:activateCard(library.cards[1])
        t:eq(library.selection_count, 1, "a second tap unselects")
        t:check(library:_titleText():find("1 selected", 1, true) ~= nil, "the title counts")
        library:onClose()
        t:eq(library.selecting, false, "Back ends selection first")
        t:eq(library.selection_count, 0, "and forgets it")
    end)

    t:case("the chosen order is remembered and reloads from the start", function()
        ctx.reset()
        local controller = galleryController(function() return mixed(0, 3) end)
        local library = open(controller)
        local dialog = library:showSortMenu()
        local rows = dialog.buttons
        t:eq(#rows, 5, "four orders and Close")
        t:eq(rows[1][1].checked_func(), true, "recent is checked")
        t:eq(rows[3][1].no_refresh_checkmark, true, "a row that closes its dialog does not repaint a check")
        rows[3][1].callback()
        ctx.env.UIManager:flush()
        t:eq(library.sort, "title_asc", "title order")
        t:eq(_G.G_reader_settings.data.justdraw_library_sort, "title_asc", "saved")
        t:eq(controller.calls[#controller.calls].opts.sort, "title_asc", "the list asks for it")
        t:eq(controller.calls[#controller.calls].cursor, nil, "from the first batch")
        t:eq(library.modal_widgets[dialog], nil, "the menu closed")
        library:shutdown()
        local again = open(controller)
        t:eq(again.sort, "title_asc", "a new window starts in the remembered order")
        _G.G_reader_settings.data.justdraw_library_sort = "sideways"
        local bad = open(controller)
        t:eq(bad.sort, "recent", "an unknown saved order is not trusted")
    end)

    t:case("delete names exactly what is chosen and reports each failure", function()
        ctx.reset()
        local deleted = {}
        local controller = galleryController(function() return mixed(1, 3) end)
        function controller:deleteNotebook(id)
            if id == 2 then return nil, "busy" end
            deleted[#deleted + 1] = "notebook:" .. id
            return true
        end
        function controller:deleteFolder(id)
            deleted[#deleted + 1] = "folder:" .. id
            return true
        end
        local library = open(controller)
        library:setSelecting(true)
        for _, card in ipairs(library.cards) do library:activateCard(card) end
        t:eq(library.selection_count, 4, "all four chosen")
        local box = library:confirmDeleteItems(library:selectedItems())
        t:check(box.text:find("Folder “Folder 1”", 1, true) ~= nil, "the folder by name")
        for i = 1, 3 do
            t:check(box.text:find("• Notebook " .. i, 1, true) ~= nil, "notebook " .. i .. " by name")
        end
        t:check(box.text:find("go back to Notebooks", 1, true) ~= nil,
            "a folder's notebooks are said to survive it")
        box.ok_callback()
        ctx.env.UIManager:flush()
        t:eq(table.concat(deleted, ","), "folder:1,notebook:1,notebook:3", "each deleted once, in order")
        local info = ctx.env.UIManager._window_stack[#ctx.env.UIManager._window_stack].widget
        t:check(info.text:find("Deleted 3 items.", 1, true) ~= nil, "three deleted")
        t:check(info.text:find("1 failed:", 1, true) ~= nil, "one failed")
        t:check(info.text:find("Notebook 2", 1, true) ~= nil, "by name")
        t:eq(library.selection_count, 0, "nothing stays chosen after deleting")
        t:eq(library.selecting, false, "and selection mode ends")
    end)

    t:case("a single folder delete explains its notebooks survive", function()
        ctx.reset()
        local library = open(galleryController(function() return mixed(1, 0) end))
        local box = library:confirmDeleteItems({ library.cards[1].item })
        t:check(box.text:find("are not deleted", 1, true) ~= nil, "said plainly")
    end)

    t:case("move goes notebook by notebook and says which failed", function()
        ctx.reset()
        local moved = {}
        local controller = galleryController(function() return mixed(0, 3) end)
        function controller:listFolders(o)
            t:eq(o.limit, 21, "one page of folders, and one to know there is more")
            return { { id = 5, name = "Archive" } }
        end
        function controller:moveNotebook(id, folder_id)
            if id == 3 then return nil, "not_found" end
            moved[#moved + 1] = id .. ">" .. tostring(folder_id)
            return true
        end
        local library = open(controller)
        library:setSelecting(true)
        for _, card in ipairs(library.cards) do library:activateCard(card) end
        local dialog = library:showMoveDialog(library:selectedItems("notebook"))
        t:eq(dialog.buttons[1][1].text, "No folder", "the root first")
        t:eq(dialog.buttons[2][1].text, "Archive", "then the folders")
        dialog.buttons[2][1].callback()
        ctx.env.UIManager:flush()
        t:eq(table.concat(moved, ","), "1>5,2>5", "the two that could move")
        local info = ctx.env.UIManager._window_stack[#ctx.env.UIManager._window_stack].widget
        t:check(info.text:find("Moved 2 notebooks.", 1, true) ~= nil, "two moved")
        t:check(info.text:find("Notebook 3", 1, true) ~= nil, "the failure is named")
    end)

    t:case("Send appears in selection only while LocalSend is there, for notebooks", function()
        ctx.reset()
        local present, sent = false, nil
        local library = open(galleryController(function() return mixed(1, 2) end), {
            can_send = function() return present end,
            send_items = function(items, host) sent = { items = items, host = host } end,
        })
        library:setSelecting(true)
        local function has(id)
            for _, b in ipairs(library.header_buttons) do if b.action_id == id then return b end end
            for _, m in ipairs(library.header_more or {}) do if m == id then return true end end
        end
        t:eq(has("send"), nil, "no Send without LocalSend")
        present = true
        library:_rebuild()
        t:check(has("send") ~= nil, "Send with LocalSend")
        for _, card in ipairs(library.cards) do library:activateCard(card) end
        library:_headerAction("send")[3]()
        t:eq(#sent.items, 2, "only the notebooks")
        t:eq(sent.host, library, "asked from the library")
        t:eq(library.selecting, false, "selection ends")
    end)

    t:case("summaries never call a partial run done", function()
        local text, ok, failed, cancelled = Library.summarize("duplicate", {
            { item = { title = "A" }, status = "ok" },
            { item = { title = "B" }, status = "failed" },
            { item = { title = "C" }, status = "cancelled" },
        })
        t:eq(ok, 1, "one done"); t:eq(failed, 1, "one failed"); t:eq(cancelled, 1, "one cancelled")
        t:check(text:find("Duplicated 1 notebook.", 1, true) ~= nil, "the success counted")
        t:check(text:find("• B", 1, true) ~= nil, "the failure named")
        t:check(text:find("1 cancelled.", 1, true) ~= nil, "the cancellation counted")
        t:eq(Library.summarize("move", {}), "Nothing was changed.", "an empty run says so")
    end)

    t:case("duplicates run one at a time and Cancel stops the rest", function()
        ctx.reset()
        local jobs = {}
        local controller = galleryController(function() return mixed(0, 3) end)
        function controller:duplicateNotebook(id, o)
            local job = { id = id, title = o.title, on_done = o.on_done }
            function job.cancel() job.cancelled = true end
            jobs[#jobs + 1] = job
            return job
        end
        local library = open(controller)
        local bulk = library:duplicateItems({ library.cards[1].item, library.cards[2].item,
            library.cards[3].item })
        t:eq(#jobs, 1, "one copy at a time")
        t:eq(jobs[1].title, "Notebook 1 (copy)", "named as a copy")
        jobs[1].on_done(10)
        ctx.env.UIManager:flush()
        t:eq(#jobs, 2, "the next starts when the first is done")
        local progress
        for widget in pairs(library.modal_widgets) do
            if widget.title and widget.title:find("Duplicating", 1, true) then progress = widget end
        end
        t:check(progress ~= nil, "a progress box with Cancel")
        t:check(progress.title:find("2 of 3", 1, true) ~= nil, "counting")
        ctx.env.UIManager:close(progress)
        t:eq(jobs[2].cancelled, true, "closing the box cancels the copy in flight")
        t:eq(#jobs, 2, "and none after it starts")
        t:eq(library.bulk, nil, "the run is over")
        t:eq(bulk.results[1].status, "ok", "the first was copied")
        t:eq(bulk.results[3].status, "cancelled", "the last never ran")
        local info = ctx.env.UIManager._window_stack[#ctx.env.UIManager._window_stack].widget
        t:check(info.text:find("2 cancelled.", 1, true) ~= nil, "and the reader is told")
    end)

    t:case("suspending or closing cancels a copy in flight", function()
        ctx.reset()
        local jobs = {}
        local controller = galleryController(function() return mixed(0, 2) end)
        function controller:duplicateNotebook(id)
            local job = { id = id }
            function job.cancel() job.cancelled = true end
            jobs[#jobs + 1] = job
            return job
        end
        local library = open(controller)
        library:duplicateItems({ library.cards[1].item })
        library:onSuspend()
        t:eq(jobs[1].cancelled, true, "suspend cancels")
        ctx.env.UIManager:flush()
        library:duplicateItems({ library.cards[2].item })
        library:shutdown()
        t:eq(jobs[2].cancelled, true, "shutdown cancels")
    end)

    --- A queue that records what the gallery asks of it and answers when the
    --- test says so.
    local function fakeThumbs()
        local q = { wanted = {}, retained = nil, closed = false, cancelled = 0, retried = 0 }
        function q:want(req, cb)
            self.wanted[#self.wanted + 1] = { req = req, cb = cb }
            if self.ready and self.ready[req.page_id] then return "/t/" .. req.page_id .. ".png" end
            return nil, "pending"
        end
        function q:retain(keys) self.retained = keys end
        function q:retry() self.retried = self.retried + 1 end
        function q:cancelAll() self.cancelled = self.cancelled + 1 end
        function q:close() self.closed = true end
        return q
    end

    local function thumbController(count)
        local controller = galleryController(function() return mixed(1, count) end)
        function controller:thumbnailRequest(item, w, h)
            return { db_uid = "db", notebook_uid = "nb" .. item.id, page_id = 100 + item.id,
                revision = 1, template_kind = "blank", logical_w = 1000, logical_h = 1400,
                w = w, h = h }
        end
        return controller
    end

    t:case("thumbnails are asked for after the grid, only for visible notebooks", function()
        ctx.reset()
        local thumbs = fakeThumbs()
        local controller = thumbController(20)
        local library = Library:new{ controller = controller, thumbnails = thumbs }
        library:markShown(); library:startLoading()
        ctx.env.UIManager:flush()
        t:eq(#thumbs.wanted, 0, "nothing asked for while the grid is built")
        ctx.env.UIManager:flush()
        local notebooks = 0
        for _, card in ipairs(library.cards) do
            if card.kind == "notebook" then notebooks = notebooks + 1 end
        end
        t:eq(#thumbs.wanted, notebooks, "one request per visible notebook, none for folders")
        local keys = 0
        for _ in pairs(thumbs.retained) do keys = keys + 1 end
        t:eq(keys, notebooks, "the queue keeps exactly those")
        t:eq(thumbs.wanted[1].req.w, library.metrics.thumb_w, "at the card's picture size")
        local card = library.cards[2]
        thumbs.wanted[1].cb("/t/one.png", card.thumb_key)
        t:eq(card.image_path, "/t/one.png", "the card shows its picture")
        library:nextScreen()
        ctx.env.UIManager:flush()
        local fresh = library.cards[1]
        t:eq(fresh.kind, "notebook", "the next screen")
        thumbs.wanted[2].cb("/t/old.png", thumbs.wanted[2].req and require("ink_thumbnail").key(thumbs.wanted[2].req))
        t:check(fresh.image_path ~= "/t/old.png", "a late result does not land on a reused card")
        library:shutdown()
        t:eq(thumbs.closed, true, "closing the library closes the queue")
    end)

    t:case("a failed picture shows a placeholder and Retry", function()
        ctx.reset()
        local thumbs = fakeThumbs()
        local library = Library:new{ controller = thumbController(1), thumbnails = thumbs }
        library:markShown(); library:startLoading()
        ctx.env.UIManager:flush(); ctx.env.UIManager:flush()
        local card = library.cards[2]
        thumbs.wanted[1].cb(nil, card.thumb_key, "disk_full")
        t:eq(card.image_state, "failed", "failed")
        -- Painted, not just flagged: the placeholder is drawn inside
        -- KOReader's repaint loop, where an error is a crash.
        local ok, err = pcall(card.paintTo, card, ctx.env.Device.screen.bb, 0, 0)
        t:check(ok, "a failed card paints its placeholder: " .. tostring(err))
        local dialog = library:showActions(card.item, card)
        local retry
        for _, row in ipairs(dialog.buttons) do
            if row[1].text == "Retry preview" then retry = row[1] end
        end
        t:check(retry ~= nil, "Retry is offered")
        retry.callback()
        ctx.env.UIManager:flush()
        t:eq(thumbs.retried, 1, "the queue forgets the failure")
        t:eq(#thumbs.wanted, 2, "and is asked again")
        library:onSuspend()
        t:eq(thumbs.cancelled, 1, "suspending cancels the render in flight")
        library:shutdown()
    end)

    t:describe("standalone notebooks / gallery controller")

    local Controller = require("ink_notebook_controller")

    local function galleryStore(folders, notebooks)
        local support = require("support")
        local nbs = {}
        for i = 1, notebooks do
            nbs[i] = { id = i, title = "N" .. i, page_count = 1, updated_at = i,
                current_page_id = 11 }
        end
        local fs = {}
        for i = 1, folders do fs[i] = { id = i, name = "F" .. i } end
        return support.newNotebookStore{ notebooks = nbs, folders = fs }
    end

    local function controllerFor(store)
        local sched = require("support").newScheduler()
        local c = Controller.new{ repository = store,
            schedule = function(fn) sched:schedule(fn) end,
            scheduleIn = function(d, fn) sched:schedule(d, fn) end,
            unschedule = function(fn) sched:unschedule(fn) end }
        return c, sched
    end

    t:case("folders are paginated with the notebooks, never loaded whole", function()
        local store = galleryStore(3, 4)
        local c = controllerFor(store)
        local b1 = assert(c:listNotebookBatch(nil, 2))
        t:eq(#b1.items, 2, "two folders")
        t:eq(b1.items[1].kind, "folder", "typed")
        t:eq(b1.next_cursor.phase, "folders", "still in the folders")
        local b2 = assert(c:listNotebookBatch(b1.next_cursor, 2))
        t:eq(b2.items[1].kind, "folder", "the third folder")
        t:eq(b2.items[2].kind, "notebook", "then the newest notebook")
        t:eq(b2.items[2].id, 4, "recent first")
        local b3 = assert(c:listNotebookBatch(b2.next_cursor, 2))
        t:eq(b3.items[1].id, 3, "continuing")
        local b4 = assert(c:listNotebookBatch(b3.next_cursor, 2))
        t:eq(#b4.items, 1, "the last one")
        t:eq(b4.has_more, false, "and the end")
    end)

    t:case("a page that ends exactly on the last folder still knows notebooks follow", function()
        local store = galleryStore(2, 1)
        local c = controllerFor(store)
        local b1 = assert(c:listNotebookBatch(nil, 2))
        t:eq(#b1.items, 2, "the two folders")
        t:eq(b1.has_more, true, "Next leads to the notebook")
        local b2 = assert(c:listNotebookBatch(b1.next_cursor, 2))
        t:eq(b2.items[1].kind, "notebook", "the notebook")
        local empty = galleryStore(2, 0)
        local b = assert(controllerFor(empty):listNotebookBatch(nil, 2))
        t:eq(b.has_more, false, "no empty next screen")
    end)

    t:case("inside a folder, only its notebooks, in the chosen order", function()
        local store = galleryStore(1, 3)
        store.notebooks[1].folder_id = 1
        store.notebooks[3].folder_id = 1
        local c = controllerFor(store)
        local b = assert(c:listNotebookBatch(nil, 10, { folder_id = 1, sort = "oldest" }))
        t:eq(#b.items, 2, "two inside")
        t:eq(b.items[1].id, 1, "oldest first")
        local root = assert(c:listNotebookBatch(nil, 10))
        t:eq(#root.items, 2, "the folder and the one notebook at the root")
    end)

    t:case("a duplicate copies in batches on later ticks and appears when done", function()
        local store = galleryStore(0, 1)
        store.copy_batches_needed = 3
        local c, sched = controllerFor(store)
        local changed = 0
        c.on_library_changed = function() changed = changed + 1 end
        local done
        local job = assert(c:duplicateNotebook(1, { title = "N1 (copy)",
            on_done = function(id, err) done = { id = id, err = err } end }))
        t:eq(store.calls.copy_batches, 0, "nothing copied under the tap")
        local listed = assert(c:listNotebookBatch(nil, 10))
        t:eq(#listed.items, 1, "the copy is hidden while it runs")
        sched:tick()
        t:check(store.calls.copy_batches <= 1, "at most one batch per tick")
        sched:drain()
        t:eq(store.calls.copy_batches, 3, "three batches in all")
        t:eq(done and done.id, 2, "the copy's id")
        t:eq(changed, 1, "the library is told once")
        t:eq(#assert(c:listNotebookBatch(nil, 10)).items, 2, "and now it is listed")
        t:eq(job.cancel(), false, "a finished job cannot be cancelled")
    end)

    t:case("a cancelled or failed duplicate is abandoned, not half-listed", function()
        local store = galleryStore(0, 1)
        local c, sched = controllerFor(store)
        local called = false
        local job = assert(c:duplicateNotebook(1, { on_done = function() called = true end }))
        t:eq(job.cancel(), true, "cancelled")
        sched:drain()
        t:eq(called, false, "a cancel is not reported as done")
        t:eq(store.copies[1].cancelled, true, "the partial copy is marked for the purge")
        store.fail_copy_batch = "source_changed"
        local result
        assert(c:duplicateNotebook(1, { on_done = function(id, err) result = { id = id, err = err } end }))
        sched:drain()
        t:eq(result and result.err, "source_changed", "the reason")
        t:eq(store.copies[2].cancelled, true, "abandoned too")
        t:eq(#assert(c:listNotebookBatch(nil, 10)).items, 1, "only the original is listed")
    end)
end
