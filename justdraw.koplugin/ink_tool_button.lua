--[[--
A plugin icon inside a native Button, for the persistent drawing controls.

KOReader's Button can show an icon, but only by name, looked up in the
frontend's own icon folders (iconwidget.lua `ICONS_DIRS`). A plugin never adds
files to KOReader, so its icons cannot be reached that way. The Button is
therefore built as a text button -- which gives it the frame, focus, enabled
state, tap range and callback KOReader lays out itself -- and its label is then
swapped for an IconWidget with an explicit `file`, inside the same
CenterContainer. With `text` cleared, Button's own enable, disable and tap
feedback take their icon branches, so nothing else has to know.

Selection is drawn apart from focus. Focus inverts the frame; the selected tool
keeps a bar under its glyph, because the tool also changes from outside the
button -- a menu, a bound gesture -- and a label can no longer carry the mark.
All of this happens when controls are built. Paint blits the cached glyph and,
for the selected tool, one rectangle: live ink reaches it through the chrome
repair once per segment.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local IconWidget = require("ui/widget/iconwidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

local floor = math.floor

--- The folder this file was loaded from. PluginLoader puts the plugin's own
--- directory on package.path, so the chunk name carries it; a bare name only
--- happens when the process already runs from inside the plugin folder.
local DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*/)") or ""

local ToolButton = {}

function ToolButton.iconPath(name)
    return DIRECTORY .. "icons/toolbar-" .. name .. ".svg"
end

local function paintTool(self, bb, x, y)
    Button.paintTo(self, bb, x, y)
    if not self.tool_selected then return end
    local d = self.dimen
    local inset = (self.bordersize or 0) + (self.padding_v or self.padding or 0)
    local thickness = math.max(2, 2 * Size.border.button)
    local color = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    -- Painted after the frame, so a focused (inverted) button needs the
    -- inverse or the mark disappears into its background.
    if self.frame and self.frame.invert then color = color:invert() end
    bb:paintRect(d.x + floor((d.w - self.tool_glyph) / 2),
        d.y + d.h - inset - thickness, self.tool_glyph, thickness, color)
end

--[[--
Replace a freshly built Button's text label with the named plugin icon.

`label` is the tool's full name; `selected` draws the selection bar. Call
before the button is first painted.

An icon has to be able to say what it is, and a KOReader Button does not show
its `help_text` on a hold. So a hold shows the current label as a
Notification: a toast, which never takes a place in the window stack that the
plugin's input rules read, and closes itself.
]]
function ToolButton.decorate(button, name, selected, label)
    local size = button:getSize()
    local glyph = math.max(1, floor(math.min(size.w, size.h) * 0.55))
    button.label_widget:free()
    button.label_widget = IconWidget:new{
        file = ToolButton.iconPath(name),
        width = glyph, height = glyph,
        dim = not button.enabled,
    }
    -- Rasterize now, into KOReader's image cache, rather than on the first
    -- paint -- which may be a chrome repair inside a live stroke.
    button.label_widget:getSize()
    button.label_container[1] = button.label_widget
    button.text, button.checked_func = nil, nil
    button.icon = name
    button.tool_glyph = glyph
    button.tool_label = label or button.help_text
    button.tool_selected = selected == true
    button.paintTo = paintTool
    if not button.hold_callback then
        -- A greyed icon is exactly the one somebody needs named.
        button.allow_hold_when_disabled = true
        button.hold_callback = function()
            if button.tool_label then
                UIManager:show(Notification:new{ text = button.tool_label })
            end
        end
    end
    return button
end

--- Follow a tool change without touching the glyph.
function ToolButton.setState(button, label, selected)
    button.tool_label, button.tool_selected = label, selected == true
    button.help_text = label
end

return ToolButton
