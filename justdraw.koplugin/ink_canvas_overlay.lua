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

The sheet occupies the bottom 40, 70 or 100 per cent of the screen. Its top is a
header -- the grab strip, then the toolbar (ink_sheet_bar) -- and the canvas is
revealed downwards from its first row beneath that, never under a control; see
`geometry`. Anything the overlay does not
want -- a tap above the sheet, a page-turn key -- is handed to the window below
by hand, which is what keeps touch navigation alive while the canvas is open.
Under the plugin's older rule, drawing swallowed every gesture on the screen
and Stop was the only way back to the book.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local logger = require("logger")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local SheetBar = require("ink_sheet_bar")
local Compat = require("ink_compat")
local Stack = require("ink_stack")
local Transform = require("ink_canvas_transform")

local Screen = Device.screen
local floor = math.floor

--- Magnetic heights, as a percentage of the screen. Three, because the sheet
--- cannot be repainted while it is being dragged -- see `_dragging` below --
--- and a continuous height the reader cannot see themselves choosing is worse
--- than three they can feel.
local HEIGHT_STOPS = { 40, 70, 100 }
local InkCanvasOverlay = WidgetContainer:extend{
    plugin = nil,      -- the JustDraw instance
    cache = nil,       -- ink_canvas_cache for the open canvas
    canvas = nil,      -- the canvas row
    height_pct = nil,
    bar_side = "right",
    --- "here" | "away" | "lost" | nil, and the page an "away" sheet belongs
    --- to. Pushed in by the plugin; see InkCanvasOverlay:setPlacement.
    placement = nil,
    placement_page = nil,
    placement_text = nil,
    placement_label_bb = nil,
    placement_label_w = 0,
    placement_label_h = 0,
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

local function intersects(a, b)
    return a and b and a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + a.h
end

--- The grab strip's thickness: enough to hit with a thumb, bounded so it does
--- not eat the sheet on a small screen.
local function handleHeight()
    local h = floor(Screen:getHeight() * 0.03)
    if h < 16 then return 16 end
    if h > 48 then return 48 end
    return h
end

--- The header above a sheet's paper: the grab strip, then the toolbar.
local function headerHeight(sw)
    return handleHeight() + select(3, SheetBar.metrics(sw))
end

function InkCanvasOverlay:init()
    if not isStop(self.height_pct) then
        local saved = Compat.readSetting(G_reader_settings, "canvas_height")
        self.height_pct = isStop(saved) and saved or HEIGHT_STOPS[2]
    end
    self.dragging = false
    self:_rebuild()
end

--[[--
Where a sheet goes at a height, and the one transform that puts a canvas in it.

The sheet is the grab strip, then the toolbar, then paper. The canvas is fitted
to the paper as if the sheet were at 100%, so its scale is the same at every
stop and a height change only moves and clips it: the raster keeps its buffer,
because `Cache:needsRebuild` compares scale. The session asks this before the
overlay exists, so the raster a canvas opens with is already the one the
overlay shows.

A stop that would leave no paper under the header gives way to the next larger
one; the controls are never shrunk to make room. Returns the transform, the
sheet rectangle and the stop actually used, or nil and `bad_geometry`.
]]
function InkCanvasOverlay.geometry(canvas, height_pct)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local header_h = headerHeight(sw)
    local pct = isStop(height_pct) and height_pct or 100
    local top = floor(sh * (100 - pct) / 100)
    for i = 1, #HEIGHT_STOPS do
        if sh - top > header_h then break end
        if HEIGHT_STOPS[i] > pct then
            pct = HEIGHT_STOPS[i]
            top = floor(sh * (100 - pct) / 100)
        end
    end
    local content_top = top + header_h
    local transform, err = Transform.new{
        logical_w = canvas.logical_w,
        logical_h = canvas.logical_h,
        fit_rect = { x = 0, y = content_top, w = sw, h = sh - header_h },
        clip_rect = { x = 0, y = content_top, w = sw, h = sh - content_top },
        align_x = "center",
        align_y = "top",
    }
    if not transform then return nil, err end
    return transform, Geom:new{ x = 0, y = top, w = sw, h = sh - top }, pct
end

--[[--
The shape a new sheet is born with: the paper under the header at 100%.

A canvas keeps the logical size it was created with, and `geometry` fits it
beneath the header. Born with the screen's shape it is taller than that paper,
so it comes out narrower than the screen with a strip on each side the pen
cannot use -- 134 px a side on a Scribe. Born with this shape it is drawn 1:1
from edge to edge at every stop. A rotation, or a header that has changed
height since, letterboxes it again, as it would any stored shape.
]]
function InkCanvasOverlay.paperSize()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return sw, sh - headerHeight(sw)
end

--- Rebuild everything that depends on the screen or the height: the
--- transform, the toolbar's fixed position, and the dirty region.
function InkCanvasOverlay:_rebuild()
    local transform, sheet, pct = InkCanvasOverlay.geometry(self.canvas, self.height_pct)
    if not transform then
        -- The session validated this canvas against the screen before the
        -- overlay was built, so only a later screen change can get here.
        -- Keep the last geometry: a sheet in the wrong place can still close.
        assert(self.transform, "JustDraw: sheet geometry refused before the overlay existed")
        logger.warn("JustDraw: no sheet geometry for this screen:", sheet)
        return
    end
    self.height_pct = pct
    self.sheet_rect = sheet

    -- Rotation changes the raster scale. Stop capture while the old ready
    -- transform still exists, so an in-flight stroke can be repaired before
    -- Cache frees its buffer and enters loading.
    if self.cache and self.cache:needsRebuild(transform)
        and self.plugin and self.plugin.onCanvasCacheWillRebuild then
        self.plugin:onCanvasCacheWillRebuild(self.canvas)
    end
    self.transform = transform

    if self.bar then
        -- Freed after this event, not now: the rebuild may have been asked
        -- for by one of the old bar's own buttons.
        local previous = self.bar
        UIManager:nextTick(function() previous:free() end)
    end
    self.bar = SheetBar:new{
        top = sheet.y + handleHeight(),
        plugin = self.plugin,
        embedded = true,
        parent = self,
        note_context = self.note_context,
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

    -- The bar lies inside the sheet now, so the sheet is the whole window.
    self.dimen = Geom:new{ x = sheet.x, y = sheet.y, w = sheet.w, h = sheet.h }
    -- The handle's width or height may have changed; both constrain the label.
    self:_rebuildPlacementLabel()
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
    local sheet = self.sheet_rect
    return { x = sheet.x, y = sheet.y, w = sheet.w, h = handleHeight() }
end

--[[--
Say which page this sheet belongs to, when it is not this one.

The overlay declines the region above the sheet on purpose, so reading on with
a sheet open is a supported thing to do -- but a sheet gives no other sign of
where it hangs. Its margin mark is painted for the page being read and
disappears the moment the anchor leaves it, so a reader who turns the page is
left looking at a note with nothing at all to say it is not this page's
(ADR-45).

Returns whether the state actually changed, so a caller that runs on every
page turn does not refresh the panel for nothing.
]]
function InkCanvasOverlay:setPlacement(kind, page)
    if kind == self.placement and page == self.placement_page then
        return false
    end
    self.placement, self.placement_page = kind, page
    self:_rebuildPlacementLabel()
    local h = self:handleRect()
    UIManager:setDirty(self, "ui",
        Geom:new{ x = h.x, y = h.y, w = h.w, h = h.h })
    return true
end

function InkCanvasOverlay:_freePlacementLabel()
    if self.placement_label_bb then
        self.placement_label_bb:free()
        self.placement_label_bb = nil
    end
    self.placement_text = nil
    self.placement_label_w, self.placement_label_h = 0, 0
end

--[[--
Build the handle's label, or clear it.

Built, measured and rasterized here rather than in `paintChromeTo` because that
is reached from `restoreChromeIfIntersecting`, which live ink calls once per
segment, and nothing in the draw path may allocate or shape text. Width and
height come from the handle, so a geometry rebuild has to rebuild it too.

Fallible on purpose: a face that cannot be loaded or a buffer that cannot be
allocated is a cosmetic failure, and it arrives inside a page-turn event. It
must cost the reader the words and nothing else -- the refusal itself is the
plugin's cached placement, not this raster.
]]
function InkCanvasOverlay:_rebuildPlacementLabel()
    self:_freePlacementLabel()
    local text
    if self.placement == "away" then
        text = self.placement_page
            and T(_("Sheet from page %1"), self.placement_page)
            or _("Sheet from elsewhere in this book")
    elseif self.placement == "lost" then
        text = _("This sheet's place in the book is missing")
    end
    if not text then return end
    local h = self:handleRect()
    local room = h.h - Size.border.window
    local widget, label
    local ok, w, height_or_err = pcall(function()
        -- Padding zero on both the fit and the widget. The strip centres the
        -- raster in whatever room is left, so the widget's own vertical
        -- padding would be the same gap counted twice -- and counted twice it
        -- takes more than half of a short strip's budget, which walks
        -- KOReader's fitter all the way down to its floor and leaves a line
        -- of one-pixel glyphs where the words should be.
        local font_size = math.min(16,
            TextWidget:getFontSizeToFitHeight("smallinfofont", room, 0))
        -- The fitter counts down and stops at 1 when nothing fits at all.
        -- A strip that cannot hold a line of text keeps its grip: the pen's
        -- refusal still says the sentence, and a smear says less than the
        -- grip did.
        if font_size < 2 then return nil end
        widget = TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont", font_size),
            padding = 0,
            max_width = h.w - 2 * Size.padding.small,
        }
        local size = widget:getSize()
        if size.h > room then return nil end
        -- TextWidget blends glyphs without making a fresh BB8A opaque. Give
        -- the label the handle's white backing or alpha-blit hides its text.
        -- Retain no TextWidget on the live chrome path.
        label = Blitbuffer.new(size.w, size.h, Blitbuffer.TYPE_BB8A)
        label:fill(Blitbuffer.COLOR_WHITE)
        widget:paintTo(label, 0, 0)
        return size.w, size.h
    end)
    if widget then widget:free() end
    if not ok or not w then
        if label then label:free() end
        if not ok then
            logger.warn("JustDraw: could not render sheet placement label:", w)
        end
        return
    end
    self.placement_text = text
    self.placement_label_bb = label
    self.placement_label_w, self.placement_label_h = w, height_or_err
end

function InkCanvasOverlay:inSheet(x, y)
    local r = self.sheet_rect
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
    -- A live stroke is mapped through this transform. Moving the paper under
    -- a pen still on the glass would put the rest of it somewhere else.
    local lease = self.plugin and self.plugin.input_lease
    if lease and lease:hasActiveContact() then return nil, "contact_active" end
    pct = snap(pct)
    if pct == self.height_pct then return end
    local was = self.dimen
    self.height_pct = pct
    if self.remember_height ~= false then
        Compat.saveSetting(G_reader_settings, "canvas_height", pct)
    end
    if self.note_context then self.note_context.height_pct = pct end
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

function InkCanvasOverlay:paintChromeTo(bb, x, y)
    -- The handle doubles as the sheet's top edge, so there is one line rather
    -- than a border and a grip.
    local h = self:handleRect()
    local rule = Size.border.window
    bb:paintRect(h.x, h.y, h.w, h.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(h.x, h.y, h.w, rule, Blitbuffer.COLOR_BLACK)
    local label = self.placement_label_bb
    if label then
        -- The label takes the grip's place rather than sharing the strip.
        -- A strip with words on it is no less obviously grabbable, and a
        -- sheet that is not on this page has something to say that a mark in
        -- the middle of a line does not (ADR-45).
        local top = h.y + rule
        local slack = h.h - rule - self.placement_label_h
        if slack < 0 then slack = 0 end
        bb:alphablitFrom(label,
            h.x + floor((h.w - self.placement_label_w) / 2),
            top + floor(slack / 2), 0, 0,
            self.placement_label_w, self.placement_label_h)
    else
        local grip_w = floor(h.w / 6)
        bb:paintRect(h.x + floor((h.w - grip_w) / 2), h.y + floor(h.h / 2),
            grip_w, rule, Blitbuffer.COLOR_BLACK)
    end

    -- Last, so it is on top of everything the canvas painted.
    self.bar:paintTo(bb, x or 0, y or 0)
end

--- Restore only chrome after a direct live-ink framebuffer blit. A wide nib or
--- repair box may geometrically overlap controls even though its centre was
--- accepted inside the canvas.
function InkCanvasOverlay:restoreChromeIfIntersecting(bb, rect, x, y)
    if not rect or not (intersects(rect, self:handleRect())
        or intersects(rect, self.bar and self.bar.dimen)) then
        return false
    end
    self:paintChromeTo(bb, x, y)
    return true
end

function InkCanvasOverlay:paintTo(bb, x, y)
    local sheet = self.sheet_rect
    -- The whole sheet, letterbox margins included: a stroke left behind in a
    -- margin after a rotation would otherwise never be cleared.
    bb:paintRect(sheet.x, sheet.y, sheet.w, sheet.h, Blitbuffer.COLOR_WHITE)

    if self.cache then self.cache:paintTo(bb) end

    self:paintChromeTo(bb, x, y)
    if self.plugin and self.plugin.onCanvasOverlayPainted then
        self.plugin:onCanvasOverlayPainted(self)
    end
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

--- The prerendered label owns a BB8A allocation. `UIManager:close` broadcasts
--- CloseWidget before removing the window, so this is where it is released.
--- Deliberately returns nothing: `WidgetContainer` must go on propagating.
function InkCanvasOverlay:onCloseWidget()
    -- The bar's rendered status and glyph references go with it, a tick later
    -- for the same reason as in _rebuild: Hide note closes from inside a tap.
    -- It stays referenced, and a freed bar paints nothing.
    local bar = self.bar
    if bar then UIManager:nextTick(function() bar:free() end) end
    self:_freePlacementLabel()
end

return InkCanvasOverlay
