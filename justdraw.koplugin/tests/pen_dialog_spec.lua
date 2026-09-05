return function(ctx)
    local t = ctx.t
    local Dialog = require("ink_pen_dialog")
    local Style = require("ink_style")
    local Button = require("ui/widget/button")

    local function fixture(opts)
        opts = opts or {}
        local state = { style = opts.style or Style.PEN, width = opts.width or 4,
            marker = opts.marker ~= false, writes = 0, closes = 0 }
        local dialog = Dialog.show{
            get_style = function() return state.style end,
            get_width = function() return state.width end,
            marker_allowed = function() return state.marker end,
            set_choice = function(style, width)
                if opts.refuse then return nil, "contact_active" end
                state.style, state.width = style, width
                state.writes = state.writes + 1
                return true
            end,
            show_modal = function(widget) return widget end,
            close_modal = function() state.closes = state.closes + 1 end,
        }
        return dialog, state
    end

    t:describe("pen dialog / shared choices")
    t:case("each of nine cells applies its own style and width", function()
        for i, style in ipairs({ Style.PEN, Style.GRAPHITE, Style.MARKER }) do
            for j, width in ipairs({ 2, 4, 7 }) do
                local dialog, state = fixture()
                local marks = 0
                for row = 1, 3 do
                    for column = 1, 3 do
                        local cell = dialog.buttons[row][column]
                        t:eq(cell.checked_func, nil, "no post-close check refresh on legacy Button")
                        t:eq(cell.no_refresh_checkmark, true, "newer Button opt-out retained")
                        if cell.text:find(Button.checkmark, 1, true) then marks = marks + 1 end
                    end
                end
                t:eq(marks, 1, "only the current combination is marked")
                dialog.buttons[i][j].callback()
                t:eq(state.style, style, "style belongs to this cell")
                t:eq(state.width, width, "width belongs to this cell")
                t:eq(state.writes, 1, "one pair applied")
                t:eq(state.closes, 1, "one close")
            end
        end
    end)

    t:case("close, refusal and unavailable marker cannot write preferences", function()
        local dialog, state = fixture()
        dialog.buttons[4][1].callback()
        t:eq(state.writes, 0, "Close does not select")
        dialog, state = fixture{ refuse = true }
        dialog.buttons[2][1].callback()
        t:eq(state.writes, 0, "refused choice does not write")
        t:eq(state.closes, 0, "refused choice keeps the panel")
        dialog, state = fixture{ marker = false, style = Style.MARKER }
        for _, cell in ipairs(dialog.buttons[3]) do
            t:eq(cell.enabled, false, "legacy marker disabled")
            cell.callback()
        end
        t:eq(state.writes, 0, "disabled callbacks cannot bypass host capability")
        t:eq(state.style, Style.MARKER, "opening preserves the global preference")
        t:eq(dialog.buttons[1][2].text, Dialog.label(Style.PEN, 4) .. Button.checkmark,
            "effective fallback marked without persisting it")
        dialog, state = fixture()
        state.marker = false
        dialog.buttons[3][1].callback()
        t:eq(state.writes, 0, "capability rechecked when selecting")
    end)

    t:case("non-preset widths stay custom until explicitly replaced", function()
        local dialog, state = fixture{ width = 5.5 }
        t:eq(Dialog.label(Style.GRAPHITE, 5.5), "Graphite · Custom (5.5)", "custom indicator")
        for row = 1, 3 do
            for _, cell in ipairs(dialog.buttons[row]) do
                t:eq(cell.text:find(Button.checkmark, 1, true), nil, "no false preset mark")
            end
        end
        t:eq(state.width, 5.5, "opening does not normalize preferences")
        dialog.buttons[2][2].callback()
        t:eq(state.width, 4, "explicit choice replaces custom width")
    end)
end
