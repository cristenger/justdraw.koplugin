--[[--
The notebook gallery's cards and the grid that holds them (Task 9.3).

A card is not a Button: it shows a picture, and KOReader's Button shows text
or an icon. It is not an InputContainer either. The gallery decides what a tap
means -- open, enter a folder, go back, toggle a selection -- from one hit test
over rectangles it computed itself (`Library.gridMetrics`), so a card only has
to know how to paint itself and where it is. Keeping taps in one place is what
lets selection mode change every card's meaning without rebuilding a widget
per card.

Memory: a card owns at most one decoded thumbnail, loaded when it is first
painted and freed with the card. `file_do_cache = false` keeps KOReader's image
cache from holding a second copy of every page the reader has scrolled past;
the file name already changes with the content (`ink_thumbnail`), so the cache
would buy nothing but memory.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local Card = {}
Card.__index = Card

--[[--
  o.kind      "notebook", "folder" or "back"
  o.item      the row the card shows (nil for "back")
  o.rel       { x, y } inside the grid; o.w, o.h the card; o.pad
  o.thumb_w, o.thumb_h   the picture box (notebooks and folders)
  o.title, o.subtitle    the two lines of text
]]
function Card.new(o)
    local self = setmetatable(o, Card)
    self.dimen = Geom:new{ x = o.rel.x, y = o.rel.y, w = o.w, h = o.h }
    self.selected = o.selected or false
    self.focused = false
    self.image = nil
    self.image_path = nil
    self.image_state = o.image_state or "pending"
    return self
end

function Card:getSize() return { w = self.w, h = self.h } end

--- The picture: a path to show, or a state ("pending" / "failed") for the
--- placeholder. Returns true when something changed.
function Card:setImage(path, state)
    if path == self.image_path and (state or "ready") == self.image_state then return false end
    self:_freeImage()
    self.image_path = path
    self.image_state = state or (path and "ready" or "pending")
    return true
end

function Card:_freeImage()
    if self.image and self.image.free then self.image:free() end
    self.image = nil
end

local function faces()
    return Font:getFace("cfont", 18), Font:getFace("cfont", 14)
end

local function rect(bb, x, y, w, h, color)
    if w > 0 and h > 0 then bb:paintRect(x, y, w, h, color) end
end

--- A border drawn as four rectangles: the fake buffer has no paintBorder,
--- and this is what paintBorder does anyway.
local function border(bb, x, y, w, h, t, color)
    rect(bb, x, y, w, t, color)
    rect(bb, x, y + h - t, w, t, color)
    rect(bb, x, y, t, h, color)
    rect(bb, x + w - t, y, t, h, color)
end

local function text(bb, str, x, y, max_w, face, color)
    local widget = TextWidget:new{ text = str, face = face, max_width = max_w,
        fgcolor = color }
    widget:paintTo(bb, x, y)
    local h = widget:getSize().h
    widget:free()
    return h
end

function Card:_paintPicture(bb, x, y)
    local w, h = self.thumb_w, self.thumb_h
    if self.kind == "folder" then
        -- A folder, drawn: a tab and a body. No icon file to ship or scale.
        local tab_w, tab_h = math.floor(w * 0.4), math.max(2, math.floor(h * 0.1))
        local top = y + math.floor(h * 0.2)
        rect(bb, x + math.floor(w * 0.1), top, tab_w, tab_h, Blitbuffer.COLOR_GRAY)
        rect(bb, x + math.floor(w * 0.1), top + tab_h, math.floor(w * 0.8),
            math.floor(h * 0.55), Blitbuffer.COLOR_GRAY)
        return
    end
    if self.image_path and not self.image then
        local ok, widget = pcall(function()
            local ImageWidget = require("ui/widget/imagewidget")
            return ImageWidget:new{ file = self.image_path, width = w, height = h,
                scale_factor = 0, file_do_cache = false }
        end)
        if ok and widget then self.image = widget else self.image_state = "failed" end
    end
    if self.image then
        local size = self.image:getSize()
        local ix = x + math.floor((w - size.w) / 2)
        local iy = y + math.floor((h - size.h) / 2)
        self.image:paintTo(bb, ix, iy)
        border(bb, ix, iy, size.w, size.h, 1, Blitbuffer.COLOR_GRAY)
        return
    end
    rect(bb, x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY)
    if self.image_state == "failed" then
        local _, face = faces()
        text(bb, self.failed_text or "?", x + self.pad, y + math.floor(h / 2) - 10,
            w - 2 * self.pad, face)
    end
end

--- The height of the two lines under a card's picture, measured with the
--- faces they are painted in: a constant would be right at one density only.
function Card.textHeight()
    local title_face, sub_face = faces()
    local total = 0
    for _, face in ipairs({ title_face, sub_face }) do
        local widget = TextWidget:new{ text = "Ág", face = face }
        total = total + widget:getSize().h
        widget:free()
    end
    return total
end

function Card:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, pad = self.w, self.h, self.pad
    rect(bb, x, y, w, h, Blitbuffer.COLOR_WHITE)
    local title_face, sub_face = faces()
    if self.kind == "back" then
        local line = text(bb, self.title, x + pad, y + math.floor(h / 2) - 20, w - 2 * pad, title_face)
        if self.subtitle then
            text(bb, self.subtitle, x + pad, y + math.floor(h / 2) - 20 + line, w - 2 * pad, sub_face)
        end
    else
        self:_paintPicture(bb, x + pad, y + pad)
        local ty = y + pad + self.thumb_h + math.floor(pad / 2)
        local line = text(bb, self.title or "", x + pad, ty, w - 2 * pad, title_face)
        if self.subtitle then
            text(bb, self.subtitle, x + pad, ty + line, w - 2 * pad, sub_face)
        end
    end
    local t = (self.selected or self.focused) and math.max(3, math.floor(pad / 2)) or 1
    border(bb, x, y, w, h, t, Blitbuffer.COLOR_BLACK)
    if self.selecting and self.kind ~= "back" then
        -- The check box, top left, always drawn in selection mode so that an
        -- unselected card reads as "can be selected", not as "plain".
        local s = math.max(12, math.floor(pad * 2.5))
        rect(bb, x + pad, y + pad, s, s, Blitbuffer.COLOR_WHITE)
        border(bb, x + pad, y + pad, s, s, 2, Blitbuffer.COLOR_BLACK)
        if self.selected then
            rect(bb, x + pad + 4, y + pad + 4, s - 8, s - 8, Blitbuffer.COLOR_BLACK)
        end
    end
end

--- FocusManager tells a card it has the focus; the gallery repaints it.
function Card:handleEvent(event)
    local handler = event and event.handler
    if handler == "onFocus" or handler == "onUnfocus" then
        self.focused = handler == "onFocus"
        if self.on_focus_changed then self.on_focus_changed(self) end
        return true
    end
    return false
end

function Card:free()
    self:_freeImage()
end

-- ------------------------------------------------------------------ grid

local Grid = {}
Grid.__index = Grid

function Card.newGrid(o)
    local self = setmetatable(o, Grid)
    self.cards = o.cards or {}
    return self
end

function Grid:getSize() return { w = self.w, h = self.h } end

function Grid:paintTo(bb, x, y)
    self.x, self.y = x, y
    for _, card in ipairs(self.cards) do
        card:paintTo(bb, x + card.rel.x, y + card.rel.y)
    end
end

--- Taps are the gallery's (see the header): the grid declines every event.
function Grid:handleEvent() return false end

function Grid:free()
    for _, card in ipairs(self.cards) do card:free() end
end

Card.Grid = Grid

return Card
