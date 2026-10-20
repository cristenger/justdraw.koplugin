--[[--
The toolbar is something the reader asks for, never something a book opening
does to them (ADR-61).

A reader selecting a word wants KOReader's own menu -- highlight, dictionary,
translate -- and a JustDraw toolbar already on screen beside it is the plugin
in the way of a reader who never opened it. So nothing mounts on open, and the
selection menu carries one entry that shows the toolbar when it is not already
up. These cases state both halves against a fake ReaderHighlight that keeps
its buttons the way the real one does; `tests/conformance.lua` checks that
shape against the installed KOReader.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local JustDraw = ctx.JustDraw

    --- A reader opening a book, with nothing between init and the first tick
    --- that a test could have done for it.
    local function openBook(opts)
        local p = support.newPlugin(JustDraw, env, opts)
        env.UIManager:flush()
        return p
    end

    local function entry(p)
        local highlight = p.ui.highlight
        local fn = highlight and highlight._highlight_buttons[JustDraw.HIGHLIGHT_BUTTON]
        return fn and fn(highlight) or nil
    end

    local function shown(button)
        if not button then return false end
        local fn = button.show_in_highlight_dialog_func
        return fn == nil or fn() and true or false
    end

    t:describe("selection activation (ADR-61)")

    t:case("a book opens with no toolbar", function()
        ctx.reset()
        local p = openBook()
        t:eq(p.bar, nil, "nothing mounted on open")
        t:eq(p.drawing, false, "drawing off")
        p:teardown()
    end)

    t:case("a stored 'shown' preference does not bring it back", function()
        for _, key in ipairs({ "justdraw_bar_shown", "fingerink_bar_shown" }) do
            ctx.reset()
            _G.G_reader_settings.data[key] = true
            local p = openBook()
            t:eq(p.bar, nil, key .. " = true no longer mounts on open")
            p:teardown()
        end
    end)

    t:case("showing and hiding no longer persist anything", function()
        ctx.reset()
        local p = openBook()
        p:setBarShown(true)
        t:check(p.bar ~= nil, "Show toolbar still shows it")
        t:eq(_G.G_reader_settings.data.justdraw_bar_shown, nil, "show wrote nothing")
        p:setBarShown(false)
        t:eq(p.bar, nil, "Hide still hides it")
        t:eq(_G.G_reader_settings.data.justdraw_bar_shown, nil, "hide wrote nothing")
        p:teardown()
    end)

    t:case("the selection menu offers JustDraw while the toolbar is down", function()
        ctx.reset()
        local p = openBook()
        local button = entry(p)
        t:check(button ~= nil, "an entry is registered with ReaderHighlight")
        t:eq(button and button.text, "JustDraw", "named after the plugin")
        t:eq(shown(button), true, "visible with no toolbar")

        p:setBarShown(true)
        t:eq(shown(entry(p)), false, "hidden while the toolbar is up")
        p:setBarShown(false)
        t:eq(shown(entry(p)), true, "back once it is hidden again")
        p:teardown()
    end)

    t:case("pressing it closes the selection and shows the toolbar, Draw off", function()
        ctx.reset()
        local p = openBook()
        local highlight = p.ui.highlight
        entry(p).callback()
        t:eq(highlight.closed, 1, "the selection menu was closed the way KOReader's own entries close it")
        t:check(p.bar ~= nil, "the toolbar is up")
        t:eq(p.drawing, false, "Draw is a separate, deliberate press")
        t:eq(p.input_lease, nil, "no input captured")
        p:teardown()
    end)

    t:case("hidden while drawing or with a sheet open", function()
        ctx.reset()
        local p = openBook()
        p.drawing = true
        t:eq(shown(entry(p)), false, "not while drawing")
        p.drawing = false
        p.canvas_open = true
        t:eq(shown(entry(p)), false, "not with a sheet open: its controls are on screen")
        p.canvas_open = false
        p:teardown()
    end)

    --- A reflowable book on a runtime with sheets, its index settled.
    local function openEpub()
        ctx.reset{ wacom_protocol = true }
        local store = support.newCanvasStore({})
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

    --[[--
    In a reflowable book the toolbar alone is a detour: its Draw has nothing
    to draw on until a sheet exists. So the entry opens the sheet at the
    selection's page and starts drawing on it (audit P0-3).
    ]]
    t:case("in a reflowable book the entry opens the sheet here", function()
        local p, store = openEpub()
        local highlight = p.ui.highlight
        t:eq(shown(entry(p)), true, "offered while nothing is open")
        entry(p).callback()
        env.UIManager:flush()
        t:eq(highlight.closed, 1, "the selection menu was closed")
        t:eq(#store.canvases, 1, "a sheet was made here")
        t:eq(p.canvas_open, true, "and opened")
        t:eq(p.drawing, true, "ready to draw")
        t:eq(shown(entry(p)), false, "and the entry steps aside while the sheet is open")
        p:teardown()
    end)

    t:case("the reader can take the entry out of the selection menu", function()
        ctx.reset()
        local p = openBook()
        t:eq(p:selectionEntryWanted(), true, "offered by default")
        p:setSelectionEntryWanted(false)
        t:eq(shown(entry(p)), false, "gone once switched off")
        t:eq(_G.G_reader_settings.data.justdraw_selection_entry, false, "and remembered")
        p:setSelectionEntryWanted(true)
        t:eq(shown(entry(p)), true, "back when switched on")
        p:teardown()
    end)

    --[[--
    The menu is two levels (audit UX-3): what a reader does first at the top,
    every setting one level down, so the first page of the menu is the
    actions and nothing a reader who only draws has to read past.
    ]]
    t:case("the menu puts actions on top and settings one level down", function()
        ctx.reset()
        local p = openBook()
        local items = {}
        p:addToMainMenu(items)
        local top = {}
        for _, it in ipairs(items.justdraw.sub_item_table) do top[it.text] = it end
        t:check(top["Start drawing"] ~= nil, "Start drawing is on top")
        t:check(top["Settings"] ~= nil, "settings have one entry of their own")
        for _, name in ipairs({ "Input mode", "Stylus diagnostics", "Drawing refresh",
            "Fast refresh while drawing", "Pen style", "Toolbar side" }) do
            t:eq(top[name], nil, name .. " is not on the first level")
        end
        local settings = {}
        for _, it in ipairs(top["Settings"].sub_item_table) do settings[it.text] = it end
        for _, name in ipairs({ "Input mode", "Stylus diagnostics", "Pen style",
            "Show JustDraw when text is selected" }) do
            t:check(settings[name] ~= nil, name .. " is under Settings")
        end
        local toggle = settings["Show JustDraw when text is selected"]
        t:eq(toggle.checked_func(), true, "on by default")
        toggle.callback()
        t:eq(p:selectionEntryWanted(), false, "and the menu switches it off")
        p:teardown()
    end)

    t:case("teardown takes the entry away", function()
        ctx.reset()
        local p = openBook()
        local highlight = p.ui.highlight
        p:teardown()
        t:eq(highlight._highlight_buttons[JustDraw.HIGHLIGHT_BUTTON], nil, "removed on close")
    end)

    t:case("no ReaderHighlight API, no entry and no error", function()
        ctx.reset()
        local p = openBook{ highlight = false }
        t:eq(p.bar, nil, "still opens quietly")
        p:teardown()
        ctx.reset()
        local q = openBook{ highlight = { _highlight_buttons = {} } }
        t:eq(next(q.ui.highlight._highlight_buttons), nil, "a ReaderHighlight without the API is left alone")
        q:teardown()
    end)
end
