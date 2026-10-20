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
The window above `widget` that actually covers the screen box `x, y, w, h`.

`visualAbove` answers for the whole window, and that is right for a modal:
anything written to the framebuffer under it punches through. A toast is not a
modal. It sits in a corner, so treating it as an occluder hid every live stroke
on the sheet for as long as one was up -- the plugin's own backpressure and
budget notices included (audit P2-1). A toast covers only what its `dimen`
says; a toast that has not been laid out yet still covers everything, because
not knowing where it is is not the same as knowing it is elsewhere.
]]
function Stack.coveringAbove(widget, x, y, w, h)
    local stack = UIManager._window_stack
    local covering
    for i = #stack, 1, -1 do
        local above = stack[i].widget
        -- Only an answer once `widget` is found below it: a widget not on
        -- the stack at all is covered by nothing, as `visualAbove` says.
        if above == widget then return covering end
        if not covering then
            local d = above.toast and above.dimen
            local clear = d and d.x and d.y and d.w and d.h
                and (d.x + d.w <= x or x + w <= d.x or d.y + d.h <= y or y + h <= d.y)
            if not clear then covering = above end
        end
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
