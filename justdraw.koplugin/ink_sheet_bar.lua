--[[--
The controls a document sheet carries across its top.

A sheet takes the bottom of the screen, and a hand writing on it rests on one
side and along the bottom edge -- exactly where the standalone toolbar's column
(ink_bar) sits, which embedded in a sheet also painted over the ink under it.
So a sheet gets its own bar: full width, directly under the grab strip and
above the paper. The overlay reserves this height before it fits the canvas,
so no control covers a stroke and no stroke starts under a control.

Only the geometry is new. Suppression and forwarding are InkBar's -- an
embedded bar answers for its own rectangle and nothing else -- and every action
is the same plugin call, so the standalone bar, and direct ink on a PDF, which
is aligned with the page rather than with a sheet, are unchanged.

Rows are sized in physical millimetres and never shrunk: a screen too narrow
for six 10 mm targets gets its tools in two rows of three instead.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local InkBar = require("ink_bar")
local Layout = require("ink_notebook_layout")
local PenDialog = require("ink_pen_dialog")
local ToolButton = require("ink_tool_button")

local Screen = Device.screen
local floor = math.floor

local TOOLS = 6

local SheetBar = InkBar:extend{
    embedded = true,
    --- Screen y of the bar's first row. The overlay puts it under the handle.
    top = 0,
}

--- Row height, tools per row and the bar's whole height for a screen this
--- wide. The overlay asks before any bar exists: the canvas is fitted under it.
function SheetBar.metrics(width)
    local target = math.max(Layout.physicalPixels(10) or 0, Size.item.height_large)
    local columns = width >= TOOLS * target and TOOLS or TOOLS / 2
    return target, columns, target * (1 + math.ceil(TOOLS / columns))
end

function SheetBar:init()
    local p = self.plugin
    local overlay = self.parent
    local width = Screen:getWidth()
    local target, columns, height = SheetBar.metrics(width)
    self.target = target
    self.dimen = Geom:new{ x = 0, y = self.top, w = width, h = height }
    self.entries = {}

    -- `rect` is where the control is painted and what it answers for. Button
    -- treats `width` as outer and `height` as the label box (ADR-23).
    local function place(text, row, column, count, callback, icon)
        local left = floor((column - 1) * width / count)
        local right = floor(column * width / count)
        local rect = Geom:new{
            x = left, y = self.top + row * target, w = right - left, h = target,
        }
        local button = Button:new{
            text = text,
            help_text = text,
            width = rect.w,
            height = Layout.buttonLabelHeight(rect.h),
            padding = Size.padding.button,
            margin = Layout.BUTTON_MARGIN,
            show_parent = overlay,
            callback = callback,
        }
        if icon then ToolButton.decorate(button, icon, false, text) end
        self.entries[#self.entries + 1] = { widget = button, rect = rect }
        self[#self + 1] = button
        return button
    end
    local function tool(text, index, callback, icon)
        return place(text, 1 + floor((index - 1) / columns),
            (index - 1) % columns + 1, columns, callback, icon)
    end

    -- First row: the state control, what the pen will do (painted between
    -- them by update), and the way out.
    self.draw_btn = place(_("Draw"), 0, 1, 3, function()
        if p.canvas_open and p.session and p.session:loadFailed() then
            p:retryCanvasLoad()
        else
            p:setDrawing(not p.drawing)
        end
    end)
    -- The way out is the cross every panel closes with; a hold names it,
    -- and the name differs between a sheet and a note.
    self.hide_btn = place(self.note_context and _("Hide note") or _("Close sheet"), 0, 3, 3,
        function() p:setBarShown(false) end, "close")

    self.pen_btn = tool(_("Pen"), 1, function()
        if not p.eraser and p.drawing then p:showPenSettingsDialog()
        else p:setEraser(false) end
    end, "pen")
    self.eraser_btn = tool(_("Eraser"), 2, function() p:setEraser(true) end, "eraser")
    self.undo_btn = tool(_("Undo"), 3, function() p:onJustDrawUndo() end, "undo")
    self.notes_btn = tool(_("Document notes"), 4, function() p:onShowDocumentNotes() end, "notes")
    self.more_btn = tool(_("More"), 5, function() p:showBarMenu() end, "more")
    self.height_btn = tool(T(_("%1 %"), overlay.height_pct), 6, function()
        -- A height change replaces this bar. Let the tap finish with the
        -- button first, and ignore a second tap on a bar already replaced.
        UIManager:nextTick(function()
            if overlay.bar == self then overlay:setHeight(overlay:nextStop()) end
        end)
    end)
    self:update(false)
end

--- Relabel the stateful controls. Pass true to also repaint.
function SheetBar:update(refresh)
    local p = self.plugin
    local session = p.session
    local cache = session and session:cache()
    local draw_text = p.drawing and _("Stop") or _("Draw")
    if cache and not p.drawing then
        local state = cache:stateName()
        if state == "loading" then draw_text = _("Loading")
        elseif state == "load_failed" then draw_text = _("Retry")
        elseif not session:isWritable() then
            draw_text = self.note_context and _("Read-only") or _("View")
        end
    end
    self:setContextText(self.draw_btn, draw_text)

    local label = PenDialog.label(p:effectiveStyle(), p.pen_width)
    ToolButton.setState(self.pen_btn, label .. "\n"
        .. _("Tap the selected pen to change its style and width."), not p.eraser)
    ToolButton.setState(self.eraser_btn, _("Eraser"), p.eraser)
    self:_setStatus(p.eraser and _("Eraser") or label)

    if self.note_context and session then
        local ready = cache and cache:isReady()
        self.draw_btn:enableDisable(p.drawing or session:loadFailed()
            or ready and session:isWritable() and not p.canvas_off_page and not session:saveFailed())
        local editing = p.drawing and ready and session:isWritable() and not p.canvas_off_page
        self.pen_btn:enableDisable(editing)
        self.eraser_btn:enableDisable(editing)
        self.undo_btn:enableDisable(editing)
    end
    if refresh then UIManager:setDirty(self.parent, "ui", self.dimen) end
end

--- The words between Draw and Hide. Shaped and measured here, when the tool
--- changes; paint only draws them.
function SheetBar:_setStatus(text)
    if text == self.status_text then return end
    if self.status_widget then self.status_widget:free() end
    self.status_widget = TextWidget:new{
        text = text,
        face = Font:getFace("smallinfofont", 18),
        max_width = floor(self.dimen.w / 3) - 2 * Size.padding.small,
    }
    local size = self.status_widget:getSize()
    self.status_text = text
    self.status_x = floor((self.dimen.w - size.w) / 2)
    self.status_y = self.top + math.max(0, floor((self.target - size.h) / 2))
end

function SheetBar:paintTo(bb)
    local d = self.dimen
    bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.COLOR_WHITE)
    for i = 1, #self.entries do
        local entry = self.entries[i]
        entry.widget:paintTo(bb, entry.rect.x, entry.rect.y)
    end
    if self.status_widget then
        self.status_widget:paintTo(bb, self.status_x, self.status_y)
    end
end

--- The overlay replaces its bar on every geometry change and frees the old
--- one a tick later. Idempotent: a close and a rebuild can both reach it.
function SheetBar:free()
    if self.status_widget then self.status_widget:free() end
    self.status_widget, self.status_text = nil, nil
    for i = 1, #self.entries do self.entries[i].widget:free() end
    self.entries = {}
end

return SheetBar
