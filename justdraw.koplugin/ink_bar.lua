--[[--
The always-reachable side toolbar.

A real KOReader widget, so the buttons render and behave natively. It sits
above ReaderUI in the UIManager stack, which means taps land on it before
anything else — including while the plugin is swallowing single-finger input,
because the capture handler passes through any contact that starts inside
`self.dimen`. See ADR-8.

Being the topmost window also means UIManager offers it *every* input event and
nothing else gets a look in, so input that misses the bar is forwarded to the
window underneath by hand. See ADR-10.

That same position is why the plugin's input suppression lives here: every
gesture passes through, already rotated and carrying a position, including the
ones GestureDetector produces from timers rather than from an input frame. See
`suppresses` and ADR-13.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("ink_i18n")

local Stack = require("ink_stack")
local PenDialog = require("ink_pen_dialog")
local ToolButton = require("ink_tool_button")

local Screen = Device.screen

local InkBar = WidgetContainer:extend{
    plugin = nil,   -- the JustDraw instance
    side = "right",
    --- True when this bar is a child of InkCanvasOverlay rather than a window
    --- of its own. An embedded bar answers for its buttons and nothing else:
    --- the overlay owns the stack, the forwarding and the suppression rule.
    embedded = false,
    --- The window this bar is painted inside, when embedded. What repaints.
    parent = nil,
}

function InkBar:mkButton(text, width, cb)
    return Button:new{
        text = text,
        width = width,
        radius = Size.radius.button,
        show_parent = self,
        callback = cb,
    }
end

--[[--
A control that is an icon rather than a word, `height` tall (see init for
why), named by a hold (see ink_tool_button).
]]
function InkBar:mkIconButton(icon, label, width, height, cb)
    local button = Button:new{
        text = label,
        help_text = label,
        width = width,
        height = height,
        radius = Size.radius.button,
        show_parent = self,
        callback = cb,
    }
    return ToolButton.decorate(button, icon, false, label)
end

-- Button:setText's same-width shortcut does not fit a newly longer label.
-- Context controls change from Draw to Loading/Read-only and Show to Go;
-- rebuild only the changed label, keeping the original frame height.
function InkBar:setContextText(button, text)
    if text == button.text then return end
    button.height = button.height or button.label_widget:getSize().h
    button.context_font_size = button.context_font_size or button.text_font_size
    button.label_widget:free()
    button.text, button.text_font_size = text, button.context_font_size
    button:init()
    PenDialog.fitButton(button)
end

function InkBar:init()
    local p = self.plugin
    local w = math.floor(Screen:getWidth() * 0.15)
    local controls = VerticalGroup:new{align="center"}
    if self.note_return then
        self.show_btn = self:mkButton(_("Show note"), w, function() p:showNote() end)
        local row_h = math.max(self.show_btn.label_widget:getSize().h, math.floor(w / 2))
        self.notes_btn = self:mkIconButton("notes", _("Document notes"), w, row_h,
            function() p:onShowDocumentNotes() end)
        self.dismiss_btn = self:mkIconButton("close", _("Dismiss"), w, row_h,
            function() p:dismissNoteReturnBar() end)
        controls[1], controls[2], controls[3] = self.show_btn, self.notes_btn, self.dismiss_btn
    else
        self.draw_btn = self:mkButton(_("Draw"), w, function()
            if p.canvas_open and p.session and p.session:loadFailed() then
                p:retryCanvasLoad()
            else
                p:setDrawing(not p.drawing)
            end
        end)
        -- Every other control is an icon: the words they used to carry -- a
        -- pen's full name among them -- only fitted a column this narrow at a
        -- font nobody could read. At least half as tall as the column is wide,
        -- so the glyph is not a speck and the target is not a sliver.
        local row_h = math.max(self.draw_btn.label_widget:getSize().h, math.floor(w / 2))
        self.pen_btn = self:mkIconButton("pen", _("Pen"), w, row_h, function()
            if not p.eraser and p.drawing then p:showPenSettingsDialog()
            else p:setEraser(false) end
        end)
        self.eraser_btn = self:mkIconButton("eraser", _("Eraser"), w, row_h,
            function() p:setEraser(true) end)
        self.undo_btn = self:mkIconButton("undo", _("Undo"), w, row_h,
            function() p:onJustDrawUndo() end)
        self.more_btn = self:mkIconButton("more", _("More"), w, row_h,
            function() p:showBarMenu() end)
        self.hide_btn = self:mkIconButton("close",
            self.embedded and _("Hide note") or _("Hide toolbar"), w, row_h,
            function() p:setBarShown(false) end)
        controls[1], controls[2], controls[3], controls[4] =
            self.draw_btn, self.pen_btn, self.eraser_btn, self.undo_btn
        if self.note_context then
            self.notes_btn = self:mkIconButton("notes", _("Document notes"), w, row_h,
                function() p:onShowDocumentNotes() end)
            controls[#controls + 1] = self.notes_btn
        end
        controls[#controls + 1], controls[#controls + 2] = self.more_btn, self.hide_btn
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.small,
        margin = 0,
        controls,
    }
    local size = self[1]:getSize()
    local pad = Size.padding.large
    local x = (self.side == "left") and pad or (Screen:getWidth() - size.w - pad)
    self.dimen = Geom:new{x=x, y=math.floor((Screen:getHeight() - size.h) / 2), w=size.w, h=size.h}
    self:update(false)
end

function InkBar:getSize()
    return self.dimen
end

function InkBar:paintTo(bb, x, y)
    self[1]:paintTo(bb, self.dimen.x, self.dimen.y)
end

--- Relabel the stateful buttons. Pass true to also repaint.
function InkBar:update(refresh)
    local p = self.plugin
    if self.note_return then
        local c = p.note_context
        self:setContextText(self.show_btn, c and c.placement == "away" and _("Go to note") or _("Show note"))
        self.show_btn:enableDisable(c ~= nil and (c.placement == "here" or c.placement == "away"))
        if refresh then UIManager:setDirty(self, "ui", self.dimen) end
        return
    end
    local draw_text = p.drawing and _("Stop") or _("Draw")
    local session = p.session
    local cache = session and session:cache()
    if cache and not p.drawing then
        local state = cache:stateName()
        if state == "loading" then draw_text = _("Loading")
        elseif state == "load_failed" then draw_text = _("Retry")
        elseif not session:isWritable() then draw_text = self.note_context and _("Read-only") or _("View") end
    end
    if self.note_context then self:setContextText(self.draw_btn, draw_text)
    else self.draw_btn:setText(draw_text, self.draw_btn.width) end
    -- The active tool is the bar under its icon, set here because the tool
    -- also flips from outside the bar -- the menu, or a bound eraser
    -- gesture. The pen's full name is what a hold on it shows.
    local pen_label = PenDialog.label(p:effectiveStyle(), p.pen_width)
    ToolButton.setState(self.pen_btn, pen_label .. "\n"
        .. _("Tap the selected pen to change its style and width."), not p.eraser)
    ToolButton.setState(self.eraser_btn, _("Eraser"), p.eraser)
    if self.note_context and session then
        local ready = cache and cache:isReady()
        self.draw_btn:enableDisable(p.drawing or session:loadFailed()
            or ready and session:isWritable() and not p.canvas_off_page and not session:saveFailed())
        local editing = p.drawing and ready and session:isWritable() and not p.canvas_off_page
        self.pen_btn:enableDisable(editing)
        self.eraser_btn:enableDisable(editing)
        self.undo_btn:enableDisable(editing)
    end
    if refresh then
        -- Embedded, the bar is not a window, and UIManager finds nothing to
        -- mark dirty when handed one that is not on the stack. The overlay is.
        UIManager:setDirty(self.parent or self, "ui", self.dimen)
    end
end

function InkBar:contains(x, y)
    local d = self.dimen
    return x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
end

-- --------------------------------------------------------------- forwarding

--- The window that would be taking input if the bar were not up. See ink_stack.
function InkBar:windowBelow()
    return Stack.below(self)
end

--[[--
Whether this gesture must not reach the application.

This is the plugin's suppression point. It sits here rather than in the capture
hook because UIManager offers *every* input event to the topmost non-toast
widget first and stops when it returns true — including `hold` and the deferred
single `tap`, which are produced by `Input:setTimeout` callbacks and dispatched
straight from `Input:waitEvent` without ever passing through
`GestureDetector:feedEvent`. A filter down there cannot see them at all.

Gestures arrive rotation-adjusted, so `pos` is already in screen coordinates and
no transform is needed here. The decision is per gesture, which is what lets a
palm's pan be swallowed in the same frame that carries the pen's tap on a
button. See ADR-13.

A gesture with no position cannot be attributed to a contact, and letting one
through mid-stroke is exactly the failure being closed, so it is suppressed too.
]]
function InkBar:suppresses(ges)
    local p = self.plugin
    if not (p.drawing and p.input_backend) then return false end
    if p.passthrough then return false end
    if ges.pos and self:contains(ges.pos.x, ges.pos.y) then return false end
    return true
end

--[[--
Swallow gestures that land on the bar but miss every button — the border, the
padding, the gaps between buttons. Without this they would be forwarded and
turn a page under the toolbar. Everything else defers to `suppresses`.
]]
function InkBar:onGesture(ges)
    if ges.pos and self:contains(ges.pos.x, ges.pos.y) then
        return true
    end
    -- Embedded, the bar is not the topmost window and has no business
    -- answering for gestures that missed it: the overlay decides.
    if self.embedded then return false end
    return self:suppresses(ges)
end

--[[--
Input nothing in the bar wanted goes to the window below.

UIManager:sendEvent only ever offers an input event to the topmost non-toast
window, so a bar that just returns false still leaves the reader — and any menu
opened underneath it — completely deaf.

Returning the callee's own result rather than a blanket true keeps UIManager's
follow-up pass over `is_always_active` and `active_widgets` windows intact.
]]
function InkBar:handleEvent(event)
    if WidgetContainer.handleEvent(self, event) then return true end
    if self.embedded then return end
    return Stack.forward(self, event)
end

return InkBar
