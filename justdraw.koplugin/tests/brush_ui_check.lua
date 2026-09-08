-- Real ButtonDialog geometry. Run in the KOReader build with a fresh KO_HOME.
require("setupkoenv")
assert(os.getenv("KO_HOME"), "isolated KO_HOME required")
_G.G_defaults = require("luadefaults"):open()
_G.G_reader_settings = require("luasettings"):open(require("datastorage"):getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local here = debug.getinfo(1,"S").source:sub(2)
package.path = assert(here:match("^(.*)/tests/[^/]+$")) .. "/?.lua;" .. package.path
local Dialog = require("ink_pen_dialog")
local Style = require("ink_style")
local UI = require("ui/uimanager")
local BB = require("ffi/blitbuffer")
local Screen = Device.screen
local selected, width = Style.TEXTURED, 7
local dialog = Dialog.show{
    get_style=function() return selected end, get_width=function() return width end,
    marker_allowed=function() return true end,
    set_choice=function(s,w) selected,width=s,w;return true end,
    show_modal=function(d) UI:show(d);return d end,
    close_modal=function(d) UI:close(d) end,
}
Screen.bb:fill(BB.COLOR_WHITE);dialog:paintTo(Screen.bb,0,0)
local d=dialog.movable.dimen
assert(d.x>=0 and d.y>=0 and d.x+d.w<=Screen:getWidth()
    and d.y+d.h<=Screen:getHeight(), "pen selector exceeds screen")
for _,row in ipairs(dialog.buttontable.buttons_layout) do
    for _,button in ipairs(row) do
        local label=button.label_widget
        assert(not label.line_with_ellipsis and not (label.isTruncated and label:isTruncated()),
            "truncated brush label: " .. button.text)
    end
end
Screen.bb:writePNG(assert(arg[1],"PNG path required"))
dialog.buttons[5][2].callback()
assert(selected==Style.HIGHLIGHTER and width==4,"native selector applies the pair")
print(string.format("PASS brush UI: dialog %dx%d, screen %dx%d",d.w,d.h,Screen:getWidth(),Screen:getHeight()))
