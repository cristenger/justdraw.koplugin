--[[--
The Shapes menu: kind, size and, for lines and arrows, direction (ADR-56).

A native ButtonDialog, built from the stored options. Every choice closes the
menu -- idempotently, with no checkmark repaint behind it (ADR-35) -- stores
the options and selects the shape tool; the editor prepares the floating
preview afterwards, outside any contact. Nothing here draws or places ink.

Kept apart from the editor so its rows can be tested as data: which rows
exist, which one is marked, and what each one stores.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Shapes = require("ink_shapes")
local _ = require("ink_i18n")

local ShapeDialog = {}

local LABELS = {
    line = _("Line"), arrow = _("Arrow"), square = _("Square"),
    rectangle = _("Rectangle"), circle = _("Circle"), ellipse = _("Ellipse"),
    triangle = _("Triangle"),
}
local SIZE_LABELS = { S = _("Small"), M = _("Medium"), L = _("Large") }
--- Directions as arrows, counter-clockwise from "right".
local ANGLE_GLYPHS = {
    [0] = "→", [45] = "↗", [90] = "↑", [135] = "↖",
    [180] = "←", [225] = "↙", [270] = "↓", [315] = "↘",
}
ShapeDialog.LABELS = LABELS

--[[--
The dialog's rows for these options.

  opts.options   current {kind, size, angle} (normalized here)
  opts.choose    function(new_options) -- store, select the tool, prepare
  opts.close     function(dialog)      -- idempotent close
  opts.checkmark the marker appended to the selected entries
]]
function ShapeDialog.rows(opts)
    local current = Shapes.normalize(opts.options)
    local mark = opts.checkmark or " ✓"
    local rows = {}
    local dialog_ref = opts.dialog_ref or {}
    local function pick(change)
        return function()
            opts.close(dialog_ref.dialog)
            local next_opts = { kind = current.kind, size = current.size, angle = current.angle }
            for k, v in pairs(change) do next_opts[k] = v end
            opts.choose(Shapes.normalize(next_opts))
        end
    end
    local row = {}
    for i, kind in ipairs(Shapes.KINDS) do
        row[#row + 1] = {
            text = LABELS[kind] .. (kind == current.kind and mark or ""),
            no_refresh_checkmark = true,
            callback = pick{ kind = kind, angle = 0 },
        }
        if #row == 2 or i == #Shapes.KINDS then
            rows[#rows + 1] = row
            row = {}
        end
    end
    local sizes = {}
    for _, size in ipairs(Shapes.SIZE_ORDER) do
        sizes[#sizes + 1] = {
            text = SIZE_LABELS[size] .. (size == current.size and mark or ""),
            no_refresh_checkmark = true,
            callback = pick{ size = size },
        }
    end
    rows[#rows + 1] = sizes
    local angles = Shapes.allowedAngles(current.kind)
    if angles then
        local line = {}
        for _, angle in ipairs(angles) do
            line[#line + 1] = {
                text = ANGLE_GLYPHS[angle] .. (angle == current.angle and mark or ""),
                no_refresh_checkmark = true,
                callback = pick{ angle = angle },
            }
            if #line == 4 then rows[#rows + 1] = line; line = {} end
        end
        if #line > 0 then rows[#rows + 1] = line end
    end
    rows[#rows + 1] = {{ text = _("Close"), no_refresh_checkmark = true,
        callback = function() opts.close(dialog_ref.dialog) end }}
    return rows
end

--- Build the dialog. The caller shows it through its modal gate.
function ShapeDialog.new(opts)
    local ref = {}
    local dialog = ButtonDialog:new{
        title = _("Shapes"),
        buttons = ShapeDialog.rows{
            options = opts.options, choose = opts.choose, close = opts.close,
            checkmark = opts.checkmark, dialog_ref = ref,
        },
    }
    ref.dialog = dialog
    return dialog
end

return ShapeDialog
