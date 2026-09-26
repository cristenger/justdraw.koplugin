--[[--
One choice applies the pen's style and width on either drawing host.

The host owns preferences, contact safety and modal lifetime. Keeping those
outside this widget prevents a notebook chooser from changing reader capture.
Selection marks are text: older Buttons repaint checked_func after a callback
even when that callback has closed the dialog (ADR-35).
]]
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Style = require("ink_style")
local T = require("ffi/util").template
local _ = require("ink_i18n")

local Dialog = {}
local styles = { Style.PEN, Style.GRAPHITE, Style.MARKER, Style.ROUND, Style.HIGHLIGHTER, Style.TEXTURED }
local widths = { 2, 4, 7 }
local style_names = {
    [Style.PEN] = _("Ink pen"), [Style.GRAPHITE] = _("Graphite"),
    [Style.MARKER] = _("Marker"), [Style.ROUND] = _("Round ink"),
    [Style.HIGHLIGHTER] = _("Highlighter"), [Style.TEXTURED] = _("Textured graphite"),
}
local width_names = { [2] = _("Thin"), [4] = _("Medium"), [7] = _("Thick") }

function Dialog.label(style, width)
    return T(_("%1 · %2"), style_names[Style.normalize(style)],
        width_names[width] or T(_("Custom (%1)"), width))
end

-- Button's multiline fitting may still overflow or elide the last line.
-- Fit the actual label inside the host's existing height, without changing
-- its frame or hitbox. This runs only when controls are built or relabelled;
-- eight is Button's own fitting floor.
function Dialog.fitButton(button)
    while button.text_font_size > 8 do
        local label = button.label_widget
        if label:getSize().h <= button.height and not label.line_with_ellipsis
            and not (label.isTruncated and label:isTruncated()) then break end
        label:free()
        button.text_font_size = button.text_font_size - 1
        button:init()
    end
end

--[[--
One row per style: its name, then its three widths. Each width cell says only
"Thin", "Medium" or "Thick" -- the row already says whose -- so no label has
to shrink to fit, where eighteen "Style · Width" labels in three columns did.
The name is a disabled cell, the way the export form heads its groups. A hold
on a cell names both, the way a Button's `help_text` would -- ButtonTable does
not pass `help_text` through, and Button would not show it anyway -- so the
cell carries its own `hold_callback`, the toolbar icons' Notification.
]]
function Dialog.show(opts)
    local marker_allowed = opts.marker_allowed()
    local current_style = Style.resolve(opts.get_style(), nil, marker_allowed)
    local current_width = opts.get_width()
    local dialog
    local rows = {}
    for _, style in ipairs(styles) do
        local available = (style ~= Style.MARKER and not Style.isModern(style)) or marker_allowed
        local row = {{ text = style_names[style], enabled = false }}
        for _, width in ipairs(widths) do
            local selected = current_style == style and current_width == width
            local label = Dialog.label(style, width)
            row[#row + 1] = {
                text = width_names[width] .. (selected and Button.checkmark or ""),
                help_text = label,
                hold_callback = function()
                    UIManager:show(Notification:new{ text = label })
                end,
                enabled = available,
                no_refresh_checkmark = true,
                callback = function()
                    if (style == Style.MARKER or Style.isModern(style))
                        and not opts.marker_allowed() then return end
                    local ok = opts.set_choice(style, width)
                    if ok then opts.close_modal(dialog) end
                end,
            }
        end
        rows[#rows + 1] = row
    end
    rows[#rows + 1] = {{ text = _("Close"), id = "close",
        callback = function() opts.close_modal(dialog) end }}
    dialog = ButtonDialog:new{ title = _("Pen settings"), buttons = rows }
    return opts.show_modal(dialog)
end

return Dialog
