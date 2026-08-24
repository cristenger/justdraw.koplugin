--[[--
One raster of the active canvas, and the two indexes that keep editing it
local.

Painting a canvas by replaying its vectors makes every repaint cost what the
reader has written. Instead the whole transformed canvas is rasterised once
into a BB8 buffer and afterwards painted with a single blit. On a Scribe that
buffer is 1860 x 2480 bytes, about 4.4 MiB, and exactly one exists: it belongs
to the canvas that is open, and it is released when that canvas is closed.

The buffer holds the *whole* canvas, not the visible part of it, which is why
dragging the sheet to a new height re-rasterises nothing -- only the blit's
source rectangle changes. A rotation does change the scale, and that does
rebuild, from the stored vectors.

Building is spread over `UIManager:nextTick` in bounded batches, one stroke
decoded at a time and released before the next. A dense canvas therefore costs
memory proportional to one stroke, not to the canvas.

Erasing and undoing are the other half. A spatial grid over the stroke bounding
boxes turns "what is near here" into a local question, so an erase clears its
own region and repaints only the strokes that overlap it -- into a
`BlitBuffer:viewport` of that region, so the repair physically cannot write
outside it. Clipping the refresh rectangle alone would not stop the pixels.
]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local Grid = require("ink_spatial_grid")
local Render = require("ink_render")

local floor, ceil = math.floor, math.ceil

local Cache = {}
Cache.__index = Cache

--- Strokes rasterised per tick while building.
local DEFAULT_BATCH = 32
--- Extra pixels around a repaired region, so a stroke's antialiasing-free but
--- half-open bounding box cannot leave a sliver behind.
local REPAIR_PAD = 4

--[[--
  opts.repository  canvas store: listStrokes, readStroke
  opts.canvas      the canvas row (id and logical geometry)
  opts.transform   an ink_canvas_transform
  opts.schedule    function(fn) -- UIManager:nextTick
  opts.batch       strokes per tick (default 32)
  opts.cell        grid cell size in canvas units (default derived)
  opts.ink         stroke colour
  opts.background  page colour
  opts.on_ready    called once the canvas is fully rasterised
]]
function Cache.new(opts)
    return setmetatable({
        repository = opts.repository,
        canvas = opts.canvas,
        transform = opts.transform,
        schedule = opts.schedule,
        batch = opts.batch or DEFAULT_BATCH,
        cell = opts.cell,
        ink = opts.ink or Blitbuffer.COLOR_BLACK,
        background = opts.background or Blitbuffer.COLOR_WHITE,
        on_ready = opts.on_ready,

        meta = {},        -- stroke metadata, in drawing order
        by_id = {},
        grid = nil,
        bb = nil,
        pending = {},
        ready = true,
        closed = false,
        --- Bumped by every rebuild and by close, so a batch in flight from an
        --- earlier geometry does nothing.
        generation = 0,
    }, Cache)
end

--- Read the canvas's stroke metadata -- no points -- and start rasterising.
function Cache:open()
    local list, err = self.repository:listStrokes(self.canvas.id)
    if not list then
        logger.err("FingerInk: cannot list canvas strokes:", err)
        list = {}
    end
    self.meta = list
    self.by_id = {}
    for i = 1, #list do self.by_id[list[i].id] = list[i] end
    self:_build()
end

function Cache:isReady()
    return self.ready and not self.closed
end

--- The stroke metadata, in drawing order. Never carries points.
function Cache:strokes()
    return self.meta
end

--- The raster buffer, for the overlay's regional blits. nil once closed.
function Cache:buffer()
    return self.bb
end

--[[--
Adopt a new transform.

The common case -- the reader dragged the sheet to a different height -- keeps
the same scale and therefore the same raster, so this is free. A rotation or a
screen resize changes the scale and rebuilds from the vectors; the stored
points are never rewritten.
]]
function Cache:setTransform(transform)
    if not transform or self.closed then return end
    local same = self.transform
        and math.abs(self.transform.scale - transform.scale) < 1e-9
    self.transform = transform
    if same and self.bb then return end
    self:_build()
end

--- Blit the visible part of the canvas into a destination buffer.
function Cache:paintTo(dest)
    if not self.bb then return end
    local r = self.transform:canvasRect()
    dest:blitFrom(self.bb, r.x, r.y, 0, 0, r.w, r.h)
end

-- ------------------------------------------------------------------ editing

--[[--
Register a stroke that has just been finished and paint it.

The points are already in hand, so nothing is read back -- which is what keeps
finishing a stroke proportional to that stroke rather than to the canvas.
]]
function Cache:addStroke(meta, points, n)
    if self.closed then return end
    self.meta[#self.meta + 1] = meta
    self.by_id[meta.id] = meta
    if self.grid then
        self.grid:insert(meta.id, meta.min_x, meta.min_y, meta.max_x, meta.max_y)
    end
    self:_paintStroke(meta, points, n)
end

--[[--
Remove a stroke and repair the hole it leaves, returning the dirty region in
cache coordinates, or nil when there was no such stroke.

The repair is the interesting part: clear the region, ask the grid which
strokes overlap it, and redraw only those, in drawing order, into a viewport of
the region. Everything outside is untouchable rather than merely untouched.
]]
function Cache:removeStroke(id)
    local m = self.by_id[id]
    if not m or self.closed or not self.bb then return nil end

    self.by_id[id] = nil
    for i = #self.meta, 1, -1 do
        if self.meta[i].id == id then table.remove(self.meta, i) end
    end
    self.grid:remove(id)

    local box = self:_regionFor(m)
    if box.w <= 0 or box.h <= 0 then return box end
    self.bb:paintRect(box.x, box.y, box.w, box.h, self.background)

    local scale = self.transform.scale
    local neighbours = self:_metaNear(
        box.x / scale, box.y / scale,
        (box.x + box.w) / scale, (box.y + box.h) / scale)
    if #neighbours > 0 then
        table.sort(neighbours, function(a, b) return a.seq < b.seq end)
        local view = self.bb:viewport(box.x, box.y, box.w, box.h)
        for i = 1, #neighbours do
            local nm = neighbours[i]
            local points, n = self.repository:readStroke(self.canvas, nm)
            if points then
                self:_paintStroke(nm, points, n, view, -box.x, -box.y)
            end
        end
    end
    return box
end

--[[--
The topmost stroke with a stored point within `radius` of (cx, cy), or nil.

Candidates come from the grid, so a dense canvas costs what is under the
eraser. They are walked newest first, and only a candidate's points are
decoded -- the ones the grid ruled out are never read.
]]
function Cache:hitTest(cx, cy, radius)
    if not self.grid then return nil end
    local candidates = self:_metaNear(cx - radius, cy - radius, cx + radius, cy + radius)
    table.sort(candidates, function(a, b) return a.seq > b.seq end)

    local r2 = radius * radius
    for i = 1, #candidates do
        local m = candidates[i]
        local points, n = self.repository:readStroke(self.canvas, m)
        if points then
            for j = 1, n do
                local dx = points[j * 2 - 1] - cx
                local dy = points[j * 2] - cy
                if dx * dx + dy * dy <= r2 then return m end
            end
        end
    end
    return nil
end

--[[--
Paint one live segment of the stroke in progress, in canvas coordinates.

Returns the dirty region in cache coordinates for the caller to blit and
refresh, or nil if there is no buffer. A segment outside the canvas paints
nothing at all: the buffer bounds the write, so it is dropped rather than
wrapped onto the far side.
]]
function Cache:drawSegment(x0, y0, x1, y1, width)
    if not self.bb then return nil end
    local tr = self.transform
    local w = tr:scaleWidth(width)
    local kx0, ky0 = tr:toCache(x0, y0)
    local kx1, ky1 = tr:toCache(x1, y1)
    Render.segment(self.bb, kx0, ky0, kx1, ky1, w, self.ink)

    local pad = w + 2
    local x = (kx0 < kx1 and kx0 or kx1) - pad
    local y = (ky0 < ky1 and ky0 or ky1) - pad
    local bw = (kx0 < kx1 and kx1 - kx0 or kx0 - kx1) + 2 * pad
    local bh = (ky0 < ky1 and ky1 - ky0 or ky0 - ky1) + 2 * pad
    return self:_clampBox({ x = floor(x), y = floor(y), w = ceil(bw), h = ceil(bh) })
end

function Cache:close()
    self.closed = true
    self.generation = self.generation + 1
    self.pending = {}
    self:_freeBuffer()
end

-- ------------------------------------------------------------------ private

function Cache:_cellSize()
    if self.cell then return self.cell end
    local shorter = self.canvas.logical_w
    if self.canvas.logical_h < shorter then shorter = self.canvas.logical_h end
    local cell = floor(shorter / 16)
    return cell < 64 and 64 or cell
end

function Cache:_freeBuffer()
    if self.bb then
        self.bb:free()
        self.bb = nil
    end
end

function Cache:_build()
    self.generation = self.generation + 1
    local generation = self.generation

    self:_freeBuffer()
    local w, h = self.transform:cacheSize()
    self.bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    self.bb:fill(self.background)

    self.grid = Grid.new{
        width = self.canvas.logical_w,
        height = self.canvas.logical_h,
        cell = self:_cellSize(),
    }
    for i = 1, #self.meta do
        local m = self.meta[i]
        self.grid:insert(m.id, m.min_x, m.min_y, m.max_x, m.max_y)
    end

    -- Reversed, so popping from the end walks the strokes in drawing order.
    self.pending = {}
    for i = #self.meta, 1, -1 do
        self.pending[#self.pending + 1] = self.meta[i]
    end

    if #self.pending == 0 then
        self:_finish()
        return
    end
    self.ready = false
    self:_scheduleBatch(generation)
end

function Cache:_scheduleBatch(generation)
    self.schedule(function()
        if self.closed or generation ~= self.generation then return end
        self:_rasteriseBatch(generation)
    end)
end

function Cache:_rasteriseBatch(generation)
    for _ = 1, self.batch do
        local m = table.remove(self.pending)
        if not m then break end
        -- One stroke decoded at a time, and released before the next: the peak
        -- cost of opening a canvas is its longest stroke, not its contents.
        local points, n = self.repository:readStroke(self.canvas, m)
        if points then
            self:_paintStroke(m, points, n)
        else
            logger.warn("FingerInk: canvas stroke", m.id, "could not be decoded")
        end
    end

    if #self.pending > 0 then
        self:_scheduleBatch(generation)
        return
    end
    self:_finish()
end

function Cache:_finish()
    self.ready = true
    if self.on_ready then self.on_ready() end
end

function Cache:_paintStroke(m, points, n, target, ox, oy)
    local tr = self.transform
    Render.points(target or self.bb, points, n, tr.scale,
        ox or 0, oy or 0, tr:scaleWidth(m.width), self.ink)
end

--- Metadata of every stroke whose bounding box could touch this canvas-space
--- rectangle, unordered.
function Cache:_metaNear(min_x, min_y, max_x, max_y)
    local ids = self.grid:candidates(min_x, min_y, max_x, max_y)
    local out = {}
    for i = 1, #ids do
        local m = self.by_id[ids[i]]
        if m then out[#out + 1] = m end
    end
    return out
end

--- A stroke's region in cache coordinates, padded by its own width.
function Cache:_regionFor(m)
    local tr = self.transform
    local pad = tr:scaleWidth(m.width) + REPAIR_PAD
    local x0, y0 = tr:toCache(m.min_x, m.min_y)
    local x1, y1 = tr:toCache(m.max_x, m.max_y)
    return self:_clampBox({
        x = floor(x0) - pad,
        y = floor(y0) - pad,
        w = ceil(x1 - x0) + 2 * pad,
        h = ceil(y1 - y0) + 2 * pad,
    })
end

function Cache:_clampBox(box)
    if not self.bb then return box end
    if box.x < 0 then box.w = box.w + box.x; box.x = 0 end
    if box.y < 0 then box.h = box.h + box.y; box.y = 0 end
    if box.x + box.w > self.bb.w then box.w = self.bb.w - box.x end
    if box.y + box.h > self.bb.h then box.h = self.bb.h - box.y end
    if box.w < 0 then box.w = 0 end
    if box.h < 0 then box.h = 0 end
    return box
end

return Cache
