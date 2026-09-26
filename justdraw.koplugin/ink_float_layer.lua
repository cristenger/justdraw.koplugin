--[[--
Ink that is being moved, pasted or placed, drawn above the page but not in it.

A selection being dragged, a clipboard payload following the pen and a shape
being positioned all need the same thing: their strokes, painted at an offset
that changes on every pen sample, without touching the page's raster or its
database until the reader lets go. Repainting the page raster for each sample
would cost a repair of two regions per frame; writing the strokes and moving
them would put SQLite under the pen (ADR-42).

So the payload is rasterised once, before the contact, into a small raster of
its own -- an `InkCanvasCache` in `overlay` composition, transparent where there
is no ink, exactly as big as the payload's box -- and each frame is one
`alphablitFrom` of it at the current offset. Moving changes two numbers.

The raster is built from snapshots the caller owns a copy of: the layer never
reads the repository, and nothing it holds is shared with the page's cache,
queue or history. Its memory is checked before anything else happens, so a
payload too large to preview is refused while the original ink is still
visible (§D.3).
]]

local Cache = require("ink_canvas_cache")
local Transform = require("ink_canvas_transform")

local floor, ceil = math.floor, math.ceil

local FloatLayer = {}
FloatLayer.__index = FloatLayer

--- BB8A (two bytes a pixel) plus the cache's one-byte coverage buffer.
FloatLayer.BYTES_PER_PIXEL = 3
--- Extra screen pixels around the payload, so a nib's rounding never touches
--- the raster's edge.
FloatLayer.PAD_PX = 2

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- An in-memory store the layer's cache opens from: nothing stored, nothing
--- to read. Every stroke arrives through `addStroke` with its points.
local EMPTY_STORE = {
    listStrokes = function() return {} end,
    readStrokeChunk = function() return nil, "not_stored" end,
}

--[[--
Measure a payload: its box in canvas units, padded by half the widest nib and
the fixed pixel margin. Returns nil and a reason for anything that is not a
finite, non-empty payload.
]]
function FloatLayer.measure(strokes, scale)
    if type(strokes) ~= "table" or #strokes == 0 then return nil, "empty_payload" end
    if not finite(scale) or scale <= 0 then return nil, "bad_geometry" end
    local min_x, min_y, max_x, max_y, width = math.huge, math.huge, -math.huge, -math.huge, 0
    for i = 1, #strokes do
        local s = strokes[i]
        if type(s) ~= "table" or type(s.points) ~= "table" or not finite(s.n)
            or s.n < 1 or not finite(s.width) or s.width < 0 then
            return nil, "bad_payload"
        end
        for p = 1, s.n do
            local x, y = s.points[p * 2 - 1], s.points[p * 2]
            if not finite(x) or not finite(y) then return nil, "bad_payload" end
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
        end
        if s.width > width then width = s.width end
    end
    local pad = width / 2 + FloatLayer.PAD_PX / scale
    return {
        min_x = min_x - pad, min_y = min_y - pad,
        max_x = max_x + pad, max_y = max_y + pad,
        pad = pad,
    }
end

--[[--
Build a layer. Nothing is allocated before every check passed.

  opts.transform  the page's transform: scale and screen placement
  opts.strokes    { {points, n, width, tool, paint_seq}, ... } in canvas units;
                  copied, never retained
  opts.max_pixels ceiling on the layer's raster, in pixels
  opts.budget     optional function(bytes) -> true | nil, reason: the owner's
                  view of the memory already in use (page cache, history...)
  opts.clear      transparent clear (Cache.clearTransparent by default)

Returns the layer or nil and `empty_payload`, `bad_payload`, `bad_geometry`,
`preview_too_large` or the budget's reason.
]]
function FloatLayer.new(opts)
    opts = opts or {}
    local page = opts.transform
    if type(page) ~= "table" or not finite(page.scale) or page.scale <= 0 then
        return nil, "bad_geometry"
    end
    local scale = page.scale
    local box, err = FloatLayer.measure(opts.strokes, scale)
    if not box then return nil, err end
    local lw, lh = box.max_x - box.min_x, box.max_y - box.min_y
    local pw, ph = ceil(lw * scale), ceil(lh * scale)
    if pw < 1 or ph < 1 then return nil, "bad_geometry" end
    local pixels = pw * ph
    local max_pixels = opts.max_pixels
    if max_pixels and pixels > max_pixels then return nil, "preview_too_large" end
    local bytes = pixels * FloatLayer.BYTES_PER_PIXEL
    if opts.budget then
        local ok, budget_err = opts.budget(bytes)
        if not ok then return nil, budget_err or "preview_too_large" end
    end

    local self = setmetatable({
        page = page,
        scale = scale,
        box = box,
        dx = 0, dy = 0,
        bytes = bytes,
        cache = nil,
        freed = false,
    }, FloatLayer)

    -- Everything the cache's callbacks reach exists before `open`, because an
    -- empty store completes the build synchronously, inside `open` itself.
    local transform = Transform.new{
        logical_w = lw, logical_h = lh,
        fit_rect = { x = 0, y = 0, w = lw * scale, h = lh * scale },
        clip_rect = { x = 0, y = 0, w = lw * scale, h = lh * scale },
        align_x = "left", align_y = "top",
    }
    if not transform then return nil, "bad_geometry" end
    local ready = false
    local ok, cache = pcall(Cache.new, {
        repository = EMPTY_STORE,
        surface = { id = 0, logical_w = lw, logical_h = lh },
        transform = transform,
        schedule = function(fn) fn() end,
        composition = "overlay",
        clear = opts.clear,
        on_ready = function() ready = true end,
    })
    if not ok or not cache then return nil, "preview_failed" end
    self.cache = cache
    local opened, open_ok, open_err = pcall(cache.open, cache)
    if not opened or not open_ok or not ready then
        self:free()
        return nil, (opened and open_err) or "preview_failed"
    end

    -- Register every stroke unpainted, then paint the whole raster once in
    -- visual order: a highlighter's fragments share one coverage, and adding
    -- them one by one would repair the same region once per fragment.
    local strokes = opts.strokes
    for i = 1, #strokes do
        local s = strokes[i]
        local points = {}
        local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
        for p = 1, s.n do
            local x = s.points[p * 2 - 1] - box.min_x
            local y = s.points[p * 2] - box.min_y
            points[p * 2 - 1], points[p * 2] = x, y
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
        end
        local added = cache:addStroke({
            id = -i, seq = i, paint_seq = s.paint_seq or i,
            width = s.width, tool = s.tool, point_count = s.n,
            min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
        }, points, s.n, { defer_paint = true })
        if not added then self:free(); return nil, "preview_failed" end
    end
    local painted_ok, painted = pcall(cache.repair, cache, {
        min_x = 0, min_y = 0, max_x = lw, max_y = lh, width = 0,
    })
    if not painted_ok or not painted then
        self:free()
        return nil, "preview_failed"
    end
    return self
end

--- Move the payload by (dx, dy) canvas units from where it was built.
function FloatLayer:setOffset(dx, dy)
    self.dx, self.dy = dx, dy
end

function FloatLayer:offset()
    return self.dx, self.dy
end

--- The payload's box in canvas units at the current offset.
function FloatLayer:canvasBox(out)
    out = out or {}
    local b = self.box
    out.min_x, out.min_y = b.min_x + self.dx, b.min_y + self.dy
    out.max_x, out.max_y = b.max_x + self.dx, b.max_y + self.dy
    return out
end

--[[--
Where the layer lands on screen now, in whole pixels, written into `out`
(reused by the caller across samples, so dragging allocates nothing).
]]
function FloatLayer:screenRect(out)
    out = out or {}
    if self.freed then out.x, out.y, out.w, out.h = 0, 0, 0, 0; return out end
    local sx, sy = self.page:toScreen(self.box.min_x + self.dx, self.box.min_y + self.dy)
    local bb = self.cache:buffer()
    out.x, out.y = floor(sx + 0.5), floor(sy + 0.5)
    out.w, out.h = bb and bb:getWidth() or 0, bb and bb:getHeight() or 0
    return out
end

--[[--
Compose the layer onto `dest` (screen coordinates), inside `clip` when given.
Alpha 0 leaves what is under it; ink covers it. Returns whether anything was
painted.
]]
function FloatLayer:paintInto(dest, clip, rect)
    if self.freed then return false end
    local bb = self.cache:buffer()
    if not bb then return false end
    rect = self:screenRect(rect or self._rect or {})
    self._rect = rect
    local x0, y0 = rect.x, rect.y
    local x1, y1 = x0 + rect.w, y0 + rect.h
    if clip then
        if clip.x > x0 then x0 = clip.x end
        if clip.y > y0 then y0 = clip.y end
        if clip.x + clip.w < x1 then x1 = clip.x + clip.w end
        if clip.y + clip.h < y1 then y1 = clip.y + clip.h end
    end
    if x1 <= x0 or y1 <= y0 then return false end
    dest:alphablitFrom(bb, x0, y0, x0 - rect.x, y0 - rect.y, x1 - x0, y1 - y0)
    return true
end

function FloatLayer:hasGrayInk()
    return not self.freed and self.cache ~= nil
        and (self.cache:hasGrayInk() or self.cache:hasTranslucentInk())
end

--- Release the raster. Safe to call any number of times.
function FloatLayer:free()
    if self.freed then return end
    self.freed = true
    if self.cache then self.cache:close() end
    self.cache = nil
end

--[[--
The editing budget shared by every preview (§D.3): what a new preview may
cost on top of what is already resident -- the page's raster and its
coverage mask, the process's edit histories and the clipboard. One number
for all of them, so a large history leaves less room for a large preview
rather than both being allowed their own ceiling.
]]
FloatLayer.EDIT_BUDGET = 48 * 1024 * 1024
FloatLayer.MAX_PREVIEW_PIXELS = 8 * 1024 * 1024

function FloatLayer.editingBudget(bytes, cache)
    local resident = 0
    local buffer = cache and cache.buffer and cache:buffer()
    if buffer and buffer.getWidth then
        -- The page raster and its reusable coverage mask: two bytes a pixel.
        resident = resident + buffer:getWidth() * buffer:getHeight() * 2
    end
    local History = require("ink_edit_history")
    resident = resident + (History.sharedPool().bytes or 0)
    resident = resident + require("ink_clipboard").retainedBytes()
    if bytes + resident > FloatLayer.EDIT_BUDGET then return nil, "preview_too_large" end
    return true
end

return FloatLayer
