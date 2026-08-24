--[[--
The canvas window: a sheet, a resize handle and the toolbar, in one widget.

Only one window, and that is the point. `UIManager:sendEvent` offers an input
event to the topmost non-toast widget and stops as soon as one returns true; it
does not carry on down the stack when that widget declines. A sheet and a
toolbar as two ordinary windows would be two things competing to be topmost,
with whichever lost deaf to everything. As children of one window they are hit
tested in one pass, in an order this file states.

Paint order and hit-test order are deliberately opposite. The toolbar is
painted last so it sits over the sheet, and is offered input first so a tap on
it never reaches the sheet underneath. `WidgetContainer` propagates to numeric
children before its own handler, so the toolbar is `self[1]` and `paintTo`
draws it at the end.

The sheet occupies the bottom 40, 70 or 100 per cent of the screen and the
canvas is revealed downwards from its first row. Anything the overlay does not
want -- a tap above the sheet, a page-turn key -- is handed to the window below
by hand, which is what keeps touch navigation alive while the canvas is open.
Under the plugin's older rule, drawing swallowed every gesture on the screen
and Stop was the only way back to the book.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local InkBar = require("ink_bar")
local Stack = require("ink_stack")
local Transform = require("ink_canvas_transform")

local Screen = Device.screen
local floor = math.floor

--- Magnetic heights, as a percentage of the screen. Three, because the sheet
--- cannot be repainted while it is being dragged -- see `_dragging` below --
--- and a continuous height the reader cannot see themselves choosing is worse
--- than three they can feel.
local HEIGHT_STOPS = { 40, 70, 100 }
local HEIGHT_KEY = "fingerink_canvas_height"

local InkCanvasOverlay = WidgetContainer:extend{
    plugin = nil,      -- the FingerInk instance
    cache = nil,       -- ink_canvas_cache for the open canvas
    canvas = nil,      -- the canvas row
    height_pct = nil,
    bar_side = "right",
}

-- ------------------------------------------------------------------ geometry

local function isStop(pct)
    for i = 1, #HEIGHT_STOPS do
        if HEIGHT_STOPS[i] == pct then return true end
    end
    return false
end

--- The nearest magnetic stop to a percentage.
local function snap(pct)
    local best, best_gap = HEIGHT_STOPS[1], math.huge
    for i = 1, #HEIGHT_STOPS do
        local gap = math.abs(HEIGHT_STOPS[i] - pct)
        if gap < best_gap then
            best, best_gap = HEIGHT_STOPS[i], gap
        end
    end
    return best
end

--- The grab strip's thickness: enough to hit with a thumb, bounded so it does
--- not eat the sheet on a small screen.
local function handleHeight()
    local h = floor(Screen:getHeight() * 0.03)
    if h < 16 then return 16 end
    if h > 48 then return 48 end
    return h
end

function InkCanvasOverlay:init()
    if not isStop(self.height_pct) then
        local saved = G_reader_settings:readSetting(HEIGHT_KEY)
        self.height_pct = isStop(saved) and saved or HEIGHT_STOPS[2]
    end
    self.dragging = false
    self:_rebuild()
end

--- Rebuild everything that depends on the screen or the height: the
--- transform, the toolbar's fixed position, and the dirty region.
function InkCanvasOverlay:_rebuild()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local transform = Transform.new{
        logical_w = self.canvas.logical_w,
        logical_h = self.canvas.logical_h,
        screen_w = sw,
        screen_h = sh,
        sheet_top = floor(sh * (100 - self.height_pct) / 100),
    }

    -- Rotation changes the raster scale. Stop capture while the old ready
    -- transform still exists, so an in-flight stroke can be repaired before
    -- Cache frees its buffer and enters loading.
    if self.cache and self.cache:needsRebuild(transform)
        and self.plugin and self.plugin.onCanvasCacheWillRebuild then
        self.plugin:onCanvasCacheWillRebuild(self.canvas)
    end
    self.transform = transform

    self.bar = InkBar:new{
        plugin = self.plugin,
        side = self.bar_side,
        embedded = true,
        parent = self,
    }
    -- Children before the container's own handler, so the toolbar gets first
    -- refusal on every gesture. paintTo draws it last, on purpose.
    self[1] = self.bar

    if self.plugin and self.plugin.onCanvasOverlayBarChanged then
        self.plugin:onCanvasOverlayBarChanged(self)
    end
    if self.cache then
        self.cache:setTransform(self.transform)
        self.bar:update(false)
    end

    local sheet = self.transform:sheetRect()
    local bar = self.bar.dimen
    local top = sheet.y < bar.y and sheet.y or bar.y
    local left = sheet.x < bar.x and sheet.x or bar.x
    local right = sheet.x + sheet.w
    if bar.x + bar.w > right then right = bar.x + bar.w end
    self.dimen = Geom:new{ x = left, y = top, w = right - left, h = sh - top }
end

function InkCanvasOverlay:setBarSide(side)
    if side ~= "left" and side ~= "right" then return nil, "bad_side" end
    if self.bar_side == side then return true end
    local was = self.dimen
    self.bar_side = side
    self:_rebuild()
    UIManager:setDirty(self.plugin and self.plugin.ui or self, "ui", was)
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

--- The grab strip at the top edge of the sheet.
function InkCanvasOverlay:handleRect()
    local sheet = self.transform:sheetRect()
    return { x = sheet.x, y = sheet.y, w = sheet.w, h = handleHeight() }
end

function InkCanvasOverlay:inSheet(x, y)
    local r = self.transform:sheetRect()
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

function InkCanvasOverlay:inHandle(x, y)
    local r = self:handleRect()
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

--- Screen coordinates to canvas coordinates, for ink and for hit testing.
--- nil when the point is not on the canvas -- the letterbox margins are sheet,
--- not page.
function InkCanvasOverlay:toCanvas(x, y)
    if not self.transform:contains(x, y) then return nil end
    return self.transform:toCanvas(x, y)
end

-- ------------------------------------------------------------------- height

function InkCanvasOverlay:setHeight(pct)
    pct = snap(pct)
    if pct == self.height_pct then return end
    local was = self.dimen
    self.height_pct = pct
    G_reader_settings:saveSetting(HEIGHT_KEY, pct)
    self:_rebuild()
    -- The sheet grew or shrank, so both the old and the new footprint are
    -- stale. One refresh over the union, at the end -- never during a drag.
    UIManager:setDirty(self.plugin and self.plugin.ui or self, "ui", was)
    UIManager:setDirty(self, "ui", self.dimen)
end

function InkCanvasOverlay:nextStop()
    for i = 1, #HEIGHT_STOPS do
        if HEIGHT_STOPS[i] == self.height_pct then
            return HEIGHT_STOPS[i % #HEIGHT_STOPS + 1]
        end
    end
    return HEIGHT_STOPS[1]
end

-- ------------------------------------------------------------------ painting

function InkCanvasOverlay:getSize()
    return self.dimen
end

function InkCanvasOverlay:paintTo(bb, x, y)
    local sheet = self.transform:sheetRect()
    -- The whole sheet, letterbox margins included: a stroke left behind in a
    -- margin after a rotation would otherwise never be cleared.
    bb:paintRect(sheet.x, sheet.y, sheet.w, sheet.h, Blitbuffer.COLOR_WHITE)

    if self.cache then self.cache:paintTo(bb) end

    -- The handle doubles as the sheet's top edge, so there is one line rather
    -- than a border and a grip.
    local h = self:handleRect()
    local rule = Size.border.window
    bb:paintRect(h.x, h.y, h.w, rule, Blitbuffer.COLOR_BLACK)
    local grip_w = floor(h.w / 6)
    bb:paintRect(h.x + floor((h.w - grip_w) / 2), h.y + floor(h.h / 2),
        grip_w, rule, Blitbuffer.COLOR_BLACK)

    -- Last, so it is on top of everything the canvas painted.
    self.bar:paintTo(bb, x, y)
end

-- --------------------------------------------------------------------- input

--[[--
Everything the toolbar did not want.

By the time this runs, `WidgetContainer:handleEvent` has already offered the
gesture to the toolbar, and the toolbar consumes anything inside its own
rectangle -- buttons, borders and the gaps between them alike. So a position
that reaches here is not on the toolbar.

Returning false is what hands the gesture to the reader, and it is deliberate
for exactly one region: the screen above the sheet. That is the difference
between a canvas you can read around and one that traps you.
]]
function InkCanvasOverlay:onGesture(ges)
    -- A gesture with no position cannot be attributed to a place, and letting
    -- one through while the canvas is open is how a page turns mid-stroke.
    if not ges.pos then return true end

    local x, y = ges.pos.x, ges.pos.y
    if self.dragging then return self:_drag(ges) end
    if self:inHandle(x, y) then return self:_handle(ges) end
    if self:inSheet(x, y) then return true end
    return false
end

function InkCanvasOverlay:_handle(ges)
    if ges.ges == "tap" then
        self:setHeight(self:nextStop())
    elseif ges.ges == "hold" then
        self.dragging = true
        self.drag_from = ges.pos.y
        self.drag_to = ges.pos.y
        self.drag_base = self.height_pct
    end
    return true
end

--[[--
A drag in progress.

Nothing is repainted until the release. KOReader's own `MovableContainer` works
the same way -- `hold_pan` only marks that a move is happening, and the widget
is moved and refreshed once in `hold_release` -- because continuous refreshes
on e-ink cost more than the feedback is worth. The magnetic stops are the
compensation: the reader cannot see the height they are choosing, so there are
only three to choose from.
]]
function InkCanvasOverlay:_drag(ges)
    local g = ges.ges
    if g == "hold_pan" or g == "pan" then
        self.drag_to = ges.pos.y
        return true
    end
    if g == "hold_release" or g == "pan_release" or g == "touch_release" then
        local y = ges.pos and ges.pos.y or self.drag_to
        self.dragging = false
        local moved = (self.drag_from - y) / Screen:getHeight() * 100
        self:setHeight(self.drag_base + moved)
    end
    return true
end

--- Input the overlay does not want goes to the window below: the reader, or a
--- dialog if one is open under us. See ink_stack.
function InkCanvasOverlay:handleEvent(event)
    if WidgetContainer.handleEvent(self, event) then return true end
    return Stack.forward(self, event)
end

function InkCanvasOverlay:onScreenResize()
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

InkCanvasOverlay.onSetRotationMode = InkCanvasOverlay.onScreenResize

return InkCanvasOverlay
