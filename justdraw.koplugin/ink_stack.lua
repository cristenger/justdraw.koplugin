--[[--
Being the topmost window, and what that obliges you to do about it.

UIManager offers an input event to the topmost non-toast widget and stops as
soon as one returns true. It does not carry on down the stack when that widget
returns false, so any window of ours that sits above the reader has to hand on
what it does not want, by hand.

Both windows this plugin ever puts up need that rule -- the standalone toolbar
over a PDF, and the canvas overlay -- and it is exactly the kind of rule that
rots when it exists in two copies.
]]

local UIManager = require("ui/uimanager")

local Stack = {}

--- Events UIManager:sendEvent delivers to one window only. Everything else
--- already reaches every window.
Stack.INPUT_HANDLERS = {
    onGesture = true,
    onKeyPress = true,
    onKeyRepeat = true,
    onKeyRelease = true,
}

--[[--
The window that would be taking input if `widget` were not up: the reader
normally, a menu or dialog when one is open on top of it.

Toasts are skipped because UIManager never lets them consume input either.
]]
function Stack.below(widget)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w ~= widget and not w.toast then return w end
    end
end

--- Return the topmost non-toast window above `widget`, if one exists.
function Stack.above(widget)
    local stack = UIManager._window_stack
    local above
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == widget then return above end
        if not above and not w.toast then above = w end
    end
end

--- Return the topmost window above `widget`, including toasts.
--- Toasts never own input, but they do own pixels while UIManager paints the
--- stack from bottom to top. Direct framebuffer blits must therefore treat a
--- toast as an occluder even though event routing deliberately ignores it.
function Stack.visualAbove(widget)
    local stack = UIManager._window_stack
    local above
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == widget then return above end
        if not above then above = w end
    end
end

--[[--
Pass an input event on to the window underneath, if this is one of the events
that would otherwise stop here.

Returns the callee's own answer rather than a blanket true, which is what keeps
UIManager's follow-up pass over `is_always_active` and `active_widgets` windows
intact.
]]
function Stack.forward(widget, event)
    if not Stack.INPUT_HANDLERS[event.handler] then return end
    local below = Stack.below(widget)
    if below then return below:handleEvent(event) end
end

return Stack
