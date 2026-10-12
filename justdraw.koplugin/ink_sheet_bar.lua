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
local Geom = require("ui/geometry")
local Size = require("ui/size")
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

    -- First row: append a real page to this logical note, current state in the
    -- centre, and the way out. Pen and Eraser below are explicit drawing-mode
    -- toggles, leaving a newly opened sheet safe to read or navigate.
    self.add_btn = place(_("Add page"), 0, 1, 5,
        function() p:addCanvasPage() end, "add")
    self.previous_btn = place(_("Previous page"), 0, 2, 5,
        function() p:navigateCanvasPage(-1) end, "previous")
    self.status_btn = place(_("Page status"), 0, 3, 5,
        function() p:showCanvasPageSelector() end)
    self.next_btn = place(_("Next page"), 0, 4, 5,
        function() p:navigateCanvasPage(1) end, "next")
    -- The way out is the cross every panel closes with; a hold names it,
    -- and the name differs between a sheet and a note.
    self.hide_btn = place(self.note_context and _("Hide note") or _("Close sheet"), 0, 5, 5,
        function() p:setBarShown(false) end, "close")

    self.pen_btn = tool(_("Pen"), 1, function()
        if not p.drawing then
            p:setEraser(false)
            p:setDrawing(true)
        elseif not p.eraser then
            p:setDrawing(false)
        else
            p:setEraser(false)
        end
    end, "pen")
    self.eraser_btn = tool(_("Eraser"), 2, function()
        if p.drawing and p.eraser then p:setDrawing(false)
        else p:setEraser(true) end
    end, "eraser")
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
    local label = PenDialog.label(p:effectiveStyle(), p.pen_width)
    ToolButton.setState(self.pen_btn, label .. "\n"
        .. _("Tap to start or stop drawing. Pen settings are in More."),
        p.drawing and not p.eraser)
    ToolButton.setState(self.eraser_btn, _("Eraser"), p.drawing and p.eraser)
    local status = p.eraser and _("Eraser") or label
    if cache then
        local state = cache:stateName()
        if state == "loading" then status = _("Loading")
        elseif state == "load_failed" then status = _("Load failed")
        elseif session:saveFailed() then status = _("Save failed")
        elseif not session:isWritable() then status = _("Read-only")
        elseif p.canvas_off_page then status = _("Off page")
        elseif not p.drawing then status = _("Drawing off") end
    end
    local pages = session and session:notePageState() or { position=1, total=1 }
    if pages.total and pages.total > 1 then
        status = T(_("Page %1 of %2 · %3"), pages.position, pages.total, status)
    end
    self:_setStatus(status)

    if session then
        local ready = cache and cache:isReady()
        self.add_btn:enableDisable(ready and session:isWritable()
            and not session:saveFailed())
        local can_navigate = ready and not session:saveFailed() and not pages.error
        self.previous_btn:enableDisable(can_navigate and pages.previous_id ~= nil)
        self.status_btn:enableDisable(can_navigate and pages.total > 1)
        self.next_btn:enableDisable(can_navigate and pages.next_id ~= nil)
        local editable = ready and session:isWritable() and not p.canvas_off_page
            and not session:saveFailed()
        self.pen_btn:enableDisable(editable)
        self.eraser_btn:enableDisable(editable)
        self.undo_btn:enableDisable(p.drawing and editable)
    end
    if refresh then UIManager:setDirty(self.parent, "ui", self.dimen) end
end

--- Keep the centre page/status button in sync with navigation and tool state.
function SheetBar:_setStatus(text)
    if text == self.status_text then return end
    self.status_text = text
    self.status_btn:setText(text, self.status_btn.width)
    self.status_btn.help_text = text .. "\n" .. _("Tap to choose a page in this note.")
end

function SheetBar:paintTo(bb)
    local d = self.dimen
    bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.COLOR_WHITE)
    for i = 1, #self.entries do
        local entry = self.entries[i]
        entry.widget:paintTo(bb, entry.rect.x, entry.rect.y)
    end
end

--- The overlay replaces its bar on every geometry change and frees the old
--- one a tick later. Idempotent: a close and a rebuild can both reach it.
function SheetBar:free()
    self.status_text = nil
    for i = 1, #self.entries do self.entries[i].widget:free() end
    self.entries = {}
end

return SheetBar
