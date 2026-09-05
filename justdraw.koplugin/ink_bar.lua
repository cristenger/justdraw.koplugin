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
local _ = require("gettext")

local Stack = require("ink_stack")
local PenDialog = require("ink_pen_dialog")

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

function InkBar:init()
    local p = self.plugin
    local w = math.floor(Screen:getWidth() * 0.15)

    self.draw_btn = self:mkButton(_("Draw"), w, function()
        if p.canvas_open and p.session and p.session:loadFailed() then
            p:retryCanvasLoad()
        else
            p:setDrawing(not p.drawing)
        end
    end)
    self.pen_btn = self:mkButton(_("Pen"), w, function()
        if not p.eraser and p.drawing then p:showPenSettingsDialog()
        else p:setEraser(false) end
    end)
    -- Keep the existing outer geometry when the longer state label is fitted.
    self.pen_btn.height = self.draw_btn.label_widget:getSize().h
    self.pen_font_size = self.pen_btn.text_font_size
    self.pen_btn.avoid_text_truncation = true
    self.pen_btn.help_text = _("Tap the selected pen to change its style and width.")
    self.eraser_btn = self:mkButton(_("Eraser"), w, function()
        p:setEraser(true)
    end)
    self.undo_btn = self:mkButton(_("Undo"), w, function()
        p:onJustDrawUndo()
    end)
    self.more_btn = self:mkButton(_("More"), w, function()
        p:showBarMenu()
    end)
    self.hide_btn = self:mkButton(_("Hide"), w, function()
        p:setBarShown(false)
    end)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.small,
        margin = 0,
        VerticalGroup:new{
            align = "center",
            self.draw_btn,
            self.pen_btn,
            self.eraser_btn,
            self.undo_btn,
            self.more_btn,
            self.hide_btn,
        },
    }

    local size = self[1]:getSize()
    local pad = Size.padding.large
    local x = (self.side == "left") and pad
        or (Screen:getWidth() - size.w - pad)
    self.dimen = Geom:new{
        x = x,
        y = math.floor((Screen:getHeight() - size.h) / 2),
        w = size.w,
        h = size.h,
    }
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
    local draw_text = p.drawing and _("Stop") or _("Draw")
    local session = p.session
    local cache = session and session:cache()
    if cache and not p.drawing then
        local state = cache:stateName()
        if state == "loading" then draw_text = _("Loading")
        elseif state == "load_failed" then draw_text = _("Retry")
        elseif not session:isWritable() then draw_text = _("View") end
    end
    self.draw_btn:setText(draw_text, self.draw_btn.width)
    -- The active-tool check rides in the label, not in `checked_func`: a
    -- Button refreshes that checkmark only after its own tap, and the tool
    -- also flips from outside the bar -- the menu, or a bound eraser gesture.
    -- setText is the relabel path every other state change here already uses.
    local mark = Button.checkmark
    local pen_text = PenDialog.label(p:effectiveStyle(), p.pen_width)
        .. (p.eraser and "" or mark)
    if pen_text ~= self.pen_btn.text then
        -- setText's same-width shortcut skips fitting a newly long label.
        self.pen_btn.label_widget:free()
        self.pen_btn.text = pen_text
        self.pen_btn.text_font_size = self.pen_font_size
        self.pen_btn:init()
        PenDialog.fitButton(self.pen_btn)
    end
    self.eraser_btn:setText(p.eraser and _("Eraser") .. mark or _("Eraser"),
        self.eraser_btn.width)
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
