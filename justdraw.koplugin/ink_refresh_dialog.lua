-- One chooser for document panels and standalone notebooks. Each host owns
-- modal safety and persistence; this module only builds the shared choices.
local ButtonDialog = require("ui/widget/buttondialog")
local LiveRefresh = require("ink_live_refresh")
local T = require("ffi/util").template
local _ = require("gettext")

local Dialog = {}

function Dialog.show(opts)
    local current = LiveRefresh.normalizeSlowIntervalMs(opts.get_interval())
    local dialog
    local rows = {}
    for i = 1, #LiveRefresh.SLOW_INTERVALS_MS do
        local ms = LiveRefresh.SLOW_INTERVALS_MS[i]
        rows[#rows + 1] = {{
            text = ms == LiveRefresh.SLOW_INTERVAL * 1000
                and T(_("%1 ms (default)"), ms) or T(_("%1 ms"), ms),
            checked_func = function() return current == ms end,
            no_refresh_checkmark = true,
            callback = function()
                opts.set_interval(ms)
                opts.close_modal(dialog)
            end,
        }}
    end
    rows[#rows + 1] = {{
        text = _("Close"),
        callback = function() opts.close_modal(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = _("Drawing refresh") .. "\n\n"
            .. _("For graphite, marker, and pages containing gray ink. Lower intervals update the screen more often."),
        buttons = rows,
    }
    return opts.show_modal(dialog)
end

return Dialog
