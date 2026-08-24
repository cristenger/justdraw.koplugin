--[[--
The one place canvas coordinates become screen coordinates.

A canvas is born with a geometry -- the screen it was first drawn on -- and it
keeps it. Every screen it is later shown on gets an aspect-fit rectangle: the
largest copy of the canvas that fits, never distorted, letterboxed at the sides
if the shape no longer matches. Rotating the device or opening the book on
another reader changes the transform, never the stored points.

The vertical alignment is to the *top* of the sheet rather than to its centre,
because the sheet reveals the canvas downwards: dragging it up shows more of
the page, starting from the first line.

Input, hit testing, erasing, the raster cache and painting all go through one
instance of this. The alternative -- the same four formulas copied into
main.lua and into the widget -- is how ink ends up landing a few pixels away
from the pen after a rotation, in one of the copies only.
]]

local floor = math.floor

local Transform = {}
Transform.__index = Transform

--[[--
  opts.logical_w, logical_h   the canvas's own geometry
  opts.screen_w, screen_h     the screen as it is right now
  opts.sheet_top              y of the top edge of the sheet

Returns the transform, or nil plus `bad_geometry` when any dimension is
missing or non-positive -- every formula here divides by one of them.
]]
function Transform.new(opts)
    local lw, lh = tonumber(opts.logical_w), tonumber(opts.logical_h)
    local sw, sh = tonumber(opts.screen_w), tonumber(opts.screen_h)
    if not lw or not lh or not sw or not sh
        or lw <= 0 or lh <= 0 or sw <= 0 or sh <= 0 then
        return nil, "bad_geometry"
    end

    local sheet_top = tonumber(opts.sheet_top) or 0
    if sheet_top < 0 then sheet_top = 0 end
    if sheet_top > sh then sheet_top = sh end

    local scale_w, scale_h = sw / lw, sh / lh
    local scale = scale_w < scale_h and scale_w or scale_h
    local draw_w, draw_h = lw * scale, lh * scale

    return setmetatable({
        logical_w = lw,
        logical_h = lh,
        screen_w = sw,
        screen_h = sh,
        sheet_top = sheet_top,
        scale = scale,
        draw_w = draw_w,
        draw_h = draw_h,
        offset_x = floor((sw - draw_w) / 2),
    }, Transform)
end

function Transform:toScreen(cx, cy)
    return self.offset_x + cx * self.scale, self.sheet_top + cy * self.scale
end

function Transform:toCanvas(sx, sy)
    return (sx - self.offset_x) / self.scale, (sy - self.sheet_top) / self.scale
end

--[[--
Canvas coordinates to raster-cache coordinates, and back out to the screen.

The cache holds the whole transformed canvas, not just the visible part, so its
origin is the canvas's own origin and its only relationship to the screen is a
translation. That is what lets the sheet be dragged to a new height without
re-rasterising a single stroke.
]]
function Transform:toCache(cx, cy)
    return cx * self.scale, cy * self.scale
end

function Transform:fromCache(kx, ky)
    return self.offset_x + kx, self.sheet_top + ky
end

--- The cache buffer's size for this transform, in whole pixels.
function Transform:cacheSize()
    local floor_ = math.floor
    local w = floor_(self.draw_w + 0.5)
    local h = floor_(self.draw_h + 0.5)
    return (w < 1 and 1 or w), (h < 1 and 1 or h)
end

--- A stroke width in screen pixels. Never rounds away to nothing: a hairline
--- that disappears at 40% height and comes back at 100% reads as data loss.
function Transform:scaleWidth(w)
    local scaled = floor(w * self.scale + 0.5)
    return scaled < 1 and 1 or scaled
end

--- The whole sheet, letterbox margins included. What the background is painted
--- over, so a stroke cannot be left behind in a margin.
function Transform:sheetRect()
    return {
        x = 0,
        y = self.sheet_top,
        w = self.screen_w,
        h = self.screen_h - self.sheet_top,
    }
end

--- The part of the canvas that is actually on screen. What ink is clipped to.
function Transform:canvasRect()
    local h = self.draw_h
    local available = self.screen_h - self.sheet_top
    if h > available then h = available end
    return {
        x = self.offset_x,
        y = self.sheet_top,
        w = floor(self.draw_w + 0.5),
        h = floor(h + 0.5),
    }
end

--- Whether a screen point is on the canvas -- not merely on the sheet. The
--- side margins are sheet, not canvas, and ink must not start in them.
function Transform:contains(sx, sy)
    local r = self:canvasRect()
    return sx >= r.x and sx < r.x + r.w and sy >= r.y and sy < r.y + r.h
end

return Transform
