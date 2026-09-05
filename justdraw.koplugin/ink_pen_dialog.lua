--[[--
One choice applies the pen's style and width on either drawing host.

The host owns preferences, contact safety and modal lifetime. Keeping those
outside this widget prevents a notebook chooser from changing reader capture.
Selection marks are text: older Buttons repaint checked_func after a callback
even when that callback has closed the dialog (ADR-35).
]]
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Style = require("ink_style")
local T = require("ffi/util").template
local _ = require("gettext")

local Dialog = {}
local styles = { Style.PEN, Style.GRAPHITE, Style.MARKER }
local widths = { 2, 4, 7 }
local style_names = {
    [Style.PEN] = _("Ink pen"), [Style.GRAPHITE] = _("Graphite"),
    [Style.MARKER] = _("Marker"),
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

function Dialog.show(opts)
    local marker_allowed = opts.marker_allowed()
    local current_style = Style.resolve(opts.get_style(), nil, marker_allowed)
    local current_width = opts.get_width()
    local dialog
    local rows = {}
    for _, style in ipairs(styles) do
        local row = {}
        for _, width in ipairs(widths) do
            local selected = current_style == style and current_width == width
            row[#row + 1] = {
                text = Dialog.label(style, width) .. (selected and Button.checkmark or ""),
                enabled = style ~= Style.MARKER or marker_allowed,
                no_refresh_checkmark = true,
                callback = function()
                    if style == Style.MARKER and not opts.marker_allowed() then return end
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
