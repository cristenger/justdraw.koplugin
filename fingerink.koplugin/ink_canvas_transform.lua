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

local floor, max, min = math.floor, math.max, math.min

local Transform = {}
Transform.__index = Transform

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function rect(value)
    if type(value) ~= "table" then return nil end
    local x, y = tonumber(value.x), tonumber(value.y)
    local w, h = tonumber(value.w), tonumber(value.h)
    if not finite(x) or not finite(y) or not finite(w) or not finite(h)
        or w <= 0 or h <= 0 then
        return nil
    end
    return { x = x, y = y, w = w, h = h }
end

--[[--
  opts.logical_w, logical_h   the surface's persistent geometry
  opts.fit_rect               rectangle used to compute scale and alignment
  opts.clip_rect              visible and interactive rectangle
  opts.align_x, align_y       left|center|right and top|center|bottom

Legacy callers may still supply screen_w, screen_h and sheet_top.  That maps
to the exact historical EPUB behaviour: scale against a full screen starting
at sheet_top, then clip to the revealed portion of the sheet.

Returns the transform, or nil plus `bad_geometry` when any dimension is
missing or non-positive -- every formula here divides by one of them.
]]
function Transform.new(opts)
    local lw, lh = tonumber(opts.logical_w), tonumber(opts.logical_h)
    if not finite(lw) or not finite(lh) or lw <= 0 or lh <= 0 then
        return nil, "bad_geometry"
    end

    local fit, clip
    local sw, sh, sheet_top
    local explicit_rects = opts.fit_rect ~= nil or opts.clip_rect ~= nil
    if explicit_rects then
        fit = rect(opts.fit_rect)
        clip = rect(opts.clip_rect or opts.fit_rect)
        if not fit or not clip then return nil, "bad_geometry" end
    else
        sw, sh = tonumber(opts.screen_w), tonumber(opts.screen_h)
        if not finite(sw) or not finite(sh) or sw <= 0 or sh <= 0 then
            return nil, "bad_geometry"
        end
        sheet_top = tonumber(opts.sheet_top) or 0
        if not finite(sheet_top) then return nil, "bad_geometry" end
        if sheet_top < 0 then sheet_top = 0 end
        if sheet_top > sh then sheet_top = sh end
        fit = { x = 0, y = sheet_top, w = sw, h = sh }
        clip = { x = 0, y = sheet_top, w = sw, h = sh - sheet_top }
        -- A zero-height legacy sheet is valid and simply has no visible
        -- canvas. rect() deliberately rejects it only for new callers.
    end

    local scale_w, scale_h = fit.w / lw, fit.h / lh
    local scale = scale_w < scale_h and scale_w or scale_h
    local draw_w, draw_h = lw * scale, lh * scale

    local align_x = opts.align_x or "center"
    local align_y = opts.align_y or "top"
    if align_x ~= "left" and align_x ~= "center" and align_x ~= "right"
        or align_y ~= "top" and align_y ~= "center" and align_y ~= "bottom" then
        return nil, "bad_geometry"
    end
    local offset_x = fit.x
    if align_x == "center" then
        offset_x = fit.x + floor((fit.w - draw_w) / 2)
    elseif align_x == "right" then
        offset_x = fit.x + fit.w - draw_w
    end
    local offset_y = fit.y
    if align_y == "center" then
        offset_y = fit.y + floor((fit.h - draw_h) / 2)
    elseif align_y == "bottom" then
        offset_y = fit.y + fit.h - draw_h
    end

    -- Standalone notebook viewports are an explicit UI contract. A positive
    -- clip rectangle that does not intersect the fitted page would create an
    -- apparently valid but wholly invisible surface. Legacy EPUB sheets keep
    -- accepting zero revealed height for their closed/hidden state.
    if explicit_rects then
        local visible_w = min(offset_x + draw_w, clip.x + clip.w)
            - max(offset_x, clip.x)
        local visible_h = min(offset_y + draw_h, clip.y + clip.h)
            - max(offset_y, clip.y)
        if visible_w <= 0 or visible_h <= 0 then return nil, "bad_geometry" end
    end

    return setmetatable({
        logical_w = lw,
        logical_h = lh,
        screen_w = sw,
        screen_h = sh,
        sheet_top = sheet_top,
        fit_rect = fit,
        clip_rect = clip,
        align_x = align_x,
        align_y = align_y,
        scale = scale,
        draw_w = draw_w,
        draw_h = draw_h,
        offset_x = offset_x,
        offset_y = offset_y,
    }, Transform)
end

function Transform:toScreen(cx, cy)
    return self.offset_x + cx * self.scale, self.offset_y + cy * self.scale
end

function Transform:toCanvas(sx, sy)
    return (sx - self.offset_x) / self.scale, (sy - self.offset_y) / self.scale
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
    return self.offset_x + kx, self.offset_y + ky
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
    local r = self.clip_rect
    return { x = r.x, y = r.y, w = r.w, h = r.h }
end

--- The part of the canvas that is actually on screen. What ink is clipped to.
function Transform:canvasRect()
    local left = max(self.offset_x, self.clip_rect.x)
    local top = max(self.offset_y, self.clip_rect.y)
    local right = min(self.offset_x + self.draw_w,
        self.clip_rect.x + self.clip_rect.w)
    local bottom = min(self.offset_y + self.draw_h,
        self.clip_rect.y + self.clip_rect.h)
    local w, h = max(0, right - left), max(0, bottom - top)
    return {
        x = floor(left + 0.5),
        y = floor(top + 0.5),
        w = floor(w + 0.5),
        h = floor(h + 0.5),
        cache_x = floor(left - self.offset_x + 0.5),
        cache_y = floor(top - self.offset_y + 0.5),
    }
end

Transform.visibleCanvasRect = Transform.canvasRect

--- Whether a screen point is on the canvas -- not merely on the sheet. The
--- side margins are sheet, not canvas, and ink must not start in them.
function Transform:contains(sx, sy)
    local r = self:canvasRect()
    return sx >= r.x and sx < r.x + r.w and sy >= r.y and sy < r.y + r.h
end

return Transform
