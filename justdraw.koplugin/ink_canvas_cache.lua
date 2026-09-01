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

Building is spread over `UIManager:nextTick` with point and chunk budgets. One
chunk is decoded, painted and released before the next. A dense canvas
therefore has bounded transient memory even when a single stroke is enormous.

Erasing and undoing are the other half. A spatial grid over the stroke bounding
boxes turns "what is near here" into a local question, so an erase clears its
own region and repaints only the strokes that overlap it -- into a
`BlitBuffer:viewport` of that region, so the repair physically cannot write
outside it. Clipping the refresh rectangle alone would not stop the pixels.

A second composition serves ink on a fixed-layout page, where the raster is not
a page of its own but a transparent layer over the book's. `overlay` allocates
a BB8A -- transparent straight out of `calloc` -- never fills it, rules no
paper on it, and puts it on screen with `alphablitFrom` rather than a copy.
Two facts about KOReader's C blitter shape the rest. `fill` and `paintRect`
force alpha to 0xFF whatever colour they are handed (`Y8_To_Y8A`), which is
exactly what the ink wants and exactly what the page under it does not: so
nothing built on them can make a pixel transparent again, and a region is
cleared by writing zero bytes over its pixel rows instead
(`Cache.clearTransparent`, injectable because the suite's fake buffer has no
pixels to write). And a transparent layer cannot un-paint the framebuffer --
clearing the overlay leaves whatever the erase covered still on screen -- so an
overlay's dirty box has to be repainted through the reader's view rather than
re-blitted from here. That belongs to the surface that owns the view, and
arrives with it in a later task (ADR-38).
]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
-- The one thing the blitter cannot do is write alpha 0 over a region, so the
-- transparent clear goes straight at the pixel bytes. Protected: the opaque
-- composition needs none of this, and the module still has to load wherever
-- the suite is run without LuaJIT's FFI.
local ffi_ok, ffi = pcall(require, "ffi")

local Grid = require("ink_spatial_grid")
local Paper = require("ink_paper")
local Render = require("ink_render")
local Codec = require("ink_canvas_codec")
local Split = require("ink_stroke_split")
local Style = require("ink_style")

local floor, ceil = math.floor, math.ceil

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function validMetadata(m)
    if type(m) ~= "table" or not finite(m.id) or m.id <= 0
        or m.id ~= floor(m.id) or not finite(m.seq) or m.seq ~= floor(m.seq)
        or not finite(m.width) or m.width < 0
        or not finite(m.point_count) or m.point_count < 1
        or m.point_count ~= floor(m.point_count)
        or not finite(m.min_x) or not finite(m.min_y)
        or not finite(m.max_x) or not finite(m.max_y)
        or m.min_x > m.max_x or m.min_y > m.max_y then
        return nil, "stroke_metadata"
    end
    return true
end

local Cache = {}
Cache.__index = Cache

--- Work per UI tick. A chunk is at most 1024 points, so the small permitted
--- overrun is fixed even when a single stroke is enormous.
local DEFAULT_POINT_BUDGET = 8 * Codec.MAX_POINTS
local DEFAULT_CHUNK_BUDGET = 32
--- Extra pixels around a repaired region, so a stroke's antialiasing-free but
--- half-open bounding box cannot leave a sliver behind.
local REPAIR_PAD = 4
local ERASER_LRU_CHUNKS = 8

--- The two ways a raster can meet what is behind it. `opaque` is a page in its
--- own right; `overlay` is a transparent layer composed onto one.
local OVERLAY = "overlay"

--[[--
Clear a region of a BB8A raster back to fully transparent.

Module-level and buffer-only on purpose: this is the one operation the blitter
cannot express -- `fill` and `paintRect` force alpha to 0xFF -- and it is
stated against a real BlitBuffer in `tests/conformance.lua`, which needs to
call it without a cache.

The rectangle is bounded to the buffer first, and then each row is zeroed from
`getPixelP`, which answers a pointer into *this* buffer's own data. That is
what makes it safe on a `viewport`: the pointer is the viewport's, so the write
stays inside it exactly as `paintRect` would.

Rotation and type are asserted rather than handled. A rotated buffer would make
`getPixelP`'s physical coordinates disagree with the caller's, and any other
type has a different pixel size; the cache's buffers are never rotated and an
overlay's is always BB8A, so either would be a programming error, not a
condition to recover from.
]]
function Cache.clearTransparent(bb, x, y, w, h)
    if not ffi_ok then error("JustDraw: transparent clear needs the FFI", 0) end
    assert(bb:getRotation() == 0, "JustDraw: transparent clear on a rotated buffer")
    assert(bb:getType() == Blitbuffer.TYPE_BB8A,
        "JustDraw: transparent clear on a buffer that carries no alpha")
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    local bw, bh = bb:getWidth(), bb:getHeight()
    if x + w > bw then w = bw - x end
    if y + h > bh then h = bh - y end
    if w <= 0 or h <= 0 then return false end
    local bytes = w * bb:getBytesPerPixel()
    for row = y, y + h - 1 do
        ffi.fill(bb:getPixelP(x, row), bytes, 0)
    end
    return true
end

--[[--
  opts.repository  canvas store: listStrokes, readStrokeChunk
  opts.canvas      the canvas row (id and logical geometry)
  opts.transform   an ink_canvas_transform
  opts.schedule    function(fn) -- UIManager:nextTick
  opts.point_budget points per tick before yielding (default 8192)
  opts.chunk_budget hard chunk cap per tick (default 32; opts.batch is legacy)
  opts.cell        grid cell size in canvas units (default derived)
  opts.ink         stroke colour
  opts.background  page colour
  opts.paper_kind  ruling to compose under the ink (default: the surface's
                   own template_kind, so a canvas row without one is blank)
  opts.paper_mark  ruling colour
  opts.composition "opaque" (default) or "overlay"
  opts.clear       function(bb, x, y, w, h) clearing an overlay region to
                   transparent (default Cache.clearTransparent)
  opts.on_ready    called once the canvas is fully rasterised
]]
function Cache.new(opts)
    -- `canvas` remains as an internal compatibility name while the same
    -- cache starts serving standalone notebook pages.
    local surface = opts.surface or opts.canvas
    local overlay = opts.composition == OVERLAY
    -- An overlay has no paper to rule at all: whatever ruling was asked for,
    -- it is blank, because a mark here would land over the book's own page.
    local paper_kind = opts.paper_kind or (surface and surface.template_kind)
    if overlay then paper_kind = "blank" end
    return setmetatable({
        repository = opts.repository,
        canvas = surface,
        transform = opts.transform,
        schedule = opts.schedule,
        point_budget = opts.point_budget or DEFAULT_POINT_BUDGET,
        chunk_budget = opts.batch or opts.chunk_budget or DEFAULT_CHUNK_BUDGET,
        cell = opts.cell,
        ink = opts.ink or Blitbuffer.COLOR_BLACK,
        background = opts.background or Blitbuffer.COLOR_WHITE,
        -- The ruling is composed into this raster rather than painted under
        -- it, because everything the surface shows is a blit out of here and
        -- a background below would not survive the first one (ADR-27).
        paper_kind = paper_kind,
        paper_mark = opts.paper_mark or Blitbuffer.COLOR_GRAY,
        overlay = overlay,
        clear = opts.clear or Cache.clearTransparent,
        on_ready = opts.on_ready,
        on_error = opts.on_error,

        meta = {},        -- stroke metadata, in drawing order
        by_id = {},
        grid = nil,
        bb = nil,
        pending = {},
        current_job = nil,
        chunks_by_id = {},
        state = "ready",
        load_error = nil,
        closed = false,
        -- Session-unique meta tokens. A SQLite row id is NOT unique over
        -- time -- `id INTEGER PRIMARY KEY` without AUTOINCREMENT reassigns
        -- the deleted maximum -- so anything that outlives a stroke, like
        -- the erase context's chunk LRU, must key on this instead.
        meta_tokens = 0,
        -- Whether the raster holds any gray ink. The device's fast refresh is
        -- forced monochrome and drops gray, so box refreshes key on this to
        -- pick a grayscale pass instead (ADR-36). Monotone within a build --
        -- erasing the last gray stroke leaves it set, failing toward
        -- correctness -- and re-derived by every rebuild's replay.
        gray_ink = false,
        --- Bumped by every rebuild and by close, so a batch in flight from an
        --- earlier geometry does nothing.
        generation = 0,
    }, Cache)
end

--- Read the canvas's stroke metadata -- no points -- and start rasterising.
function Cache:open()
    local list, err = self.repository:listStrokes(self.canvas.id)
    if not list then
        logger.err("JustDraw: cannot list canvas strokes:", err)
        self:_fail(err or "stroke_list")
        return nil, err
    end
    self.meta = list
    self.by_id = {}
    local last_seq
    for i = 1, #list do
        local valid, validation_err = validMetadata(list[i])
        if not valid or self.by_id[list[i].id]
            or (last_seq ~= nil and list[i].seq <= last_seq) then
            self:_fail(validation_err or "stroke_metadata")
            return nil, validation_err or "stroke_metadata"
        end
        self.meta_tokens = self.meta_tokens + 1
        list[i].token = self.meta_tokens
        self.by_id[list[i].id] = list[i]
        last_seq = list[i].seq
    end
    local built, build_err = self:_build()
    if not built then return nil, build_err end
    return true
end

function Cache:isReady()
    return self.state == "ready" and not self.closed
end

--- Whether this raster is a transparent layer over something else rather than
--- a page of its own. What the owner asks before deciding how a box is
--- refreshed, and what `paintTo` composes with.
function Cache:isOverlay()
    return self.overlay == true
end

function Cache:stateName()
    return self.state
end

function Cache:loadError()
    return self.load_error
end

function Cache:retryOpen()
    if self.closed then return nil, "closed" end
    return self:open()
end

--- The stroke metadata, in drawing order. Never carries points.
function Cache:strokes()
    return self.meta
end

--- The live metadata table for one stroke id, or nil. The session uses it
--- to flag erase fragments; the table is the cache's own, not a copy.
function Cache:metaById(id)
    return self.by_id[id]
end

--- The raster buffer, for the overlay's regional blits. nil once closed.
--- Whether any gray ink has reached the raster since the last rebuild. Box
--- refreshes over this cache must ride a grayscale pass while true (ADR-36).
function Cache:hasGrayInk()
    return self.gray_ink == true
end

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
    local same = not self:needsRebuild(transform)
    self.transform = transform
    if same and self.bb then return end
    if self.state == "load_failed" then return end
    return self:_build()
end

--[[--
Adopt a new paper ruling.

Structurally a rotation: the raster is rebuilt from the stored vectors and no
stored point moves. What differs is that this also changes what lies *under*
them, which is why it cannot be a regional repaint -- a page ruled after the
fact would have its ruling only where nothing had been erased.
]]
function Cache:setPaper(kind)
    if self.closed then return nil, "closed" end
    if not self:needsPaperRebuild(kind) then return true end
    self.paper_kind = kind
    -- Not open yet, or holding a partial raster behind a Retry: the field is
    -- enough, and the build that eventually runs picks it up.
    if not self.bb or self.state == "load_failed" then return true end
    return self:_build()
end

--- Whether adopting this ruling would replay the raster. The owner asks
--- before mutating anything, for the same reason it asks about a transform.
--- An overlay answers no to every ruling: it has no paper of its own, and a
--- mark on it would land over the page it is composed onto.
function Cache:needsPaperRebuild(kind)
    if self.closed or self.overlay then return false end
    return kind ~= self.paper_kind
end

--- Rule the paper over a region the caller has just cleared to `background`.
--- Bounded by that region, in cache coordinates, and allocating nothing.
function Cache:_rulePaper(x, y, w, h, target)
    local bb = target or self.bb
    if not bb or not self.transform then return false end
    return Paper.paint(bb, self.paper_kind, self.transform.scale,
        x, y, w, h, self.paper_mark)
end

--[[--
Clear a region back to nothing -- in whichever sense this composition has one.

An opaque raster is a page: it is cleared to the page colour and immediately
re-ruled, because the ruling lives inside the raster and stopping at the flat
colour is how erasing a word leaves a white hole in the lines (ADR-27).

An overlay is a layer over the book's own page, so "nothing" means transparent,
and there is no paper to put back. It cannot go through `paintRect`: the C
blitter forces alpha to 0xFF whatever colour it is handed, so clearing that way
would replace the erased ink with an opaque patch hiding the page underneath.
]]
local function clearRegion(self, bb, x, y, w, h)
    if self.overlay then
        return self.clear(bb, x, y, w, h)
    end
    bb:paintRect(x, y, w, h, self.background)
    return self:_rulePaper(x, y, w, h, bb)
end

--- Whether adopting this transform would allocate and replay the raster.
--- Overlay asks before mutating anything so capture can stop while the old
--- ready transform is still available to repair an in-flight stroke.
function Cache:needsRebuild(transform)
    if not transform or self.closed then return false end
    return not (self.transform and self.bb
        and math.abs(self.transform.scale - transform.scale) < 1e-9)
end

--- Blit the visible part of the canvas into a destination buffer.
function Cache:paintTo(dest)
    -- A partial raster after corruption looks exactly like lost ink. Keep the
    -- sheet blank with its visible Retry control until a complete generation
    -- validates; the database and metadata remain untouched underneath.
    if not self.bb or self.state == "load_failed" then return end
    local r = self.transform:canvasRect()
    if self.overlay then
        -- The same rectangle, composed rather than copied: alpha 0 leaves the
        -- book's page exactly as it was, 0xFF puts the ink over it.
        dest:alphablitFrom(self.bb, r.x, r.y,
            r.cache_x or 0, r.cache_y or 0, r.w, r.h)
        return
    end
    dest:blitFrom(self.bb, r.x, r.y, r.cache_x or 0, r.cache_y or 0, r.w, r.h)
end

-- ------------------------------------------------------------------ editing

--[[--
Register a stroke that has just been finished and paint it.

The points are already in hand, so nothing is read back -- which is what keeps
finishing a stroke proportional to that stroke rather than to the canvas.
When opts proves that every live segment was painted into this exact ready
cache generation, registration skips the duplicate replay. Otherwise the
extra return values describe the effective half-open fallback coverage.
]]
function Cache:addStroke(meta, points, n, opts)
    if self.closed then return nil, "closed" end
    if meta.id < 0 then
        meta.points = points
        meta.n = n
    end
    self.meta_tokens = self.meta_tokens + 1
    meta.token = self.meta_tokens
    self.meta[#self.meta + 1] = meta
    self.by_id[meta.id] = meta
    if self.grid then self:_indexStroke(meta) end
    self:_indexLiveChunks(meta, points, n)
    local live_raster_valid = opts
        and opts.live_raster_complete == true
        and opts.raster_cache == self
        and opts.raster_generation == self.generation
        and self:isReady()
    if live_raster_valid then
        return true, nil, false
    end
    local painted, left, top, right, bottom =
        self:_paintStroke(meta, points, n)
    return true, nil, painted, left, top, right, bottom
end

--- Replace a temporary queue id with the SQLite row id assigned at COMMIT.
--- Points remain attached until this moment, so no pending stroke is ever read
--- back through the repository with a negative id.
function Cache:markPersisted(local_id, row_id)
    if self.closed then return nil, "closed" end
    if type(local_id) ~= "number" or local_id >= 0
        or type(row_id) ~= "number" or row_id <= 0 then
        return nil, "bad_id"
    end
    local m = self.by_id[local_id]
    if not m then return nil, "unknown_stroke" end
    if self.by_id[row_id] and self.by_id[row_id] ~= m then
        return nil, "duplicate_id"
    end

    if self.grid then self.grid:remove(local_id) end
    local chunks = self.chunks_by_id[local_id]
    self.chunks_by_id[local_id] = nil
    self.by_id[local_id] = nil
    m.id = row_id
    m.row_id = row_id
    m.points = nil
    m.n = nil
    self.by_id[row_id] = m
    self.chunks_by_id[row_id] = chunks
    if self.grid then self:_indexStroke(m) end
    return true
end

--- Drop a stroke from the metadata, grid and chunk index without touching
--- the raster. The split path paints the survivors before it repairs the
--- hole, so the pixels' turn comes later; `removeStroke` keeps the old
--- contract of doing both at once.
function Cache:forgetStroke(id)
    local m = self.by_id[id]
    if not m or self.closed or not self.bb then return nil end
    self.by_id[id] = nil
    for i = #self.meta, 1, -1 do
        if self.meta[i].id == id then table.remove(self.meta, i) end
    end
    self.grid:remove(id)
    self.chunks_by_id[id] = nil
    return m
end

--[[--
Remove a stroke and repair the hole it leaves, returning the dirty region in
cache coordinates, or nil when there was no such stroke.

The repair is the interesting part: clear the region, ask the grid which
strokes overlap it, and redraw only those, in drawing order, into a viewport of
the region. Everything outside is untouchable rather than merely untouched.
]]
function Cache:removeStroke(id)
    local m = self:forgetStroke(id)
    if not m then return nil end
    return self:repair(m)
end

--[[--
Clear a stroke-shaped region and put back whatever else was under it.

Takes the same shape a stroke's metadata has -- bounding box and width -- so it
serves both an erase and the abandonment of a stroke that was being drawn and
never got stored. Returns the region in cache coordinates.
]]
function Cache:repair(m)
    if not self.bb then return nil end
    local box = self:_regionFor(m)
    if box.w <= 0 or box.h <= 0 then return box end
    clearRegion(self, self.bb, box.x, box.y, box.w, box.h)

    local scale = self.transform.scale
    local neighbours = self:_metaNear(
        box.x / scale, box.y / scale,
        (box.x + box.w) / scale, (box.y + box.h) / scale)
    local stats = {
        candidates = #neighbours, chunks_consulted = 0,
        chunks_decoded = 0, pixels_repaired = box.w * box.h,
    }
    if #neighbours > 0 then
        table.sort(neighbours, function(a, b) return a.seq < b.seq end)
        -- A viewport of the region, so the repair cannot paint outside it even
        -- if a neighbour reaches far beyond.
        local view = self.bb:viewport(box.x, box.y, box.w, box.h)
        local canvas_box = {
            min_x = box.x / scale, min_y = box.y / scale,
            max_x = (box.x + box.w) / scale,
            max_y = (box.y + box.h) / scale,
        }
        for i = 1, #neighbours do
            local nm = neighbours[i]
            local ok, err = self:_paintMetaRegion(nm, canvas_box,
                view, -box.x, -box.y, stats)
            if not ok then self:_fail(err); return nil, err end
        end
    end
    logger.dbg("JustDraw: canvas repair,", stats.candidates, "candidates,",
        stats.chunks_consulted, "chunks consulted,", stats.chunks_decoded,
        "chunks decoded,", stats.pixels_repaired, "pixels repaired")
    return box
end

function Cache:beginErase()
    return {
        cache = {}, order = {}, limit = ERASER_LRU_CHUNKS,
        stats = {
            candidates = 0, chunks_consulted = 0,
            lru_hits = 0, chunks_decoded = 0,
        },
    }
end

function Cache:endErase(ctx)
    if not ctx then return end
    local s = ctx.stats or {}
    logger.dbg("JustDraw: canvas erase,", s.candidates or 0, "candidates,",
        s.chunks_consulted or 0, "chunks consulted,", s.lru_hits or 0,
        "LRU hits,", s.chunks_decoded or 0, "chunks decoded")
    ctx.cache = {}
    ctx.order = {}
end

--[[--
The topmost stroke with a stored point within `radius` of (cx, cy), or nil.

Candidates come from the grid, so a dense canvas costs what is under the
eraser. They are walked newest first, and only a candidate's points are
decoded -- the ones the grid ruled out are never read.
]]

function Cache:hitTest(cx, cy, radius, ctx)
    if not self.grid then return nil end
    local candidates = self:_metaNear(cx - radius, cy - radius, cx + radius, cy + radius)
    table.sort(candidates, function(a, b) return a.seq > b.seq end)
    if ctx and ctx.stats then
        ctx.stats.candidates = ctx.stats.candidates + #candidates
    end

    for i = 1, #candidates do
        local m = candidates[i]
        local reach = radius + (tonumber(m.width) or 0) / 2
        local r2 = reach * reach
        if m.points then
            local chunks = self.chunks_by_id[m.id] or {}
            for c = 1, #chunks do
                local cm = chunks[c]
                if self:_boxTouches(cm, cx - reach, cy - reach,
                    cx + reach, cy + reach, 0) then
                    if ctx and ctx.stats then
                        ctx.stats.chunks_consulted = ctx.stats.chunks_consulted + 1
                    end
                    local first, last = self:_liveChunkRange(m, cm.chunk_no)
                    if self:_pointsRangeHit(m.points, first, last, cx, cy, r2) then
                        return m
                    end
                end
            end
        else
            local chunks = self.chunks_by_id[m.id] or {}
            for c = 1, #chunks do
                local cm = chunks[c]
                if self:_boxTouches(cm, cx - reach, cy - reach,
                    cx + reach, cy + reach, 0) then
                    if ctx and ctx.stats then
                        ctx.stats.chunks_consulted = ctx.stats.chunks_consulted + 1
                    end
                    local points, n = self:_readChunk(m, cm.chunk_no, ctx)
                    if not points then self:_fail(n); return nil, n end
                    if self:_pointsHit(points, n, cx, cy, r2) then
                        return m
                    end
                end
            end
        end
    end
    return nil
end

--[[--
Every stroke the eraser capsule cut on its way from (x0,y0) to (x1,y1),
with its surviving runs and the region that stops being ink.

The capsule is what closes the gap between two eraser samples: each stroke
is tested against the swept segment, not against two circles, so a fast
pass cannot slide between them. Every candidate under the capsule is
processed -- with segment-level cutting, "everything under the rubber" is
the physical eraser's meaning, and it is what lets dense hatching go in one
pass. Candidates come from the grid; a candidate's nearby chunks gate the
full decode, so the whole stroke is read exactly once and only when it is
about to be cut. A chunk failure fails the cache, exactly as hitTest does:
half-read geometry must not decide what gets deleted.
]]
function Cache:eraseSweep(x0, y0, x1, y1, radius, ctx)
    if not self.grid then return nil end
    local min_x, max_x = x0, x1
    if min_x > max_x then min_x, max_x = max_x, min_x end
    local min_y, max_y = y0, y1
    if min_y > max_y then min_y, max_y = max_y, min_y end
    local candidates = self:_metaNear(min_x - radius, min_y - radius,
        max_x + radius, max_y + radius)
    if ctx and ctx.stats then
        ctx.stats.candidates = ctx.stats.candidates + #candidates
    end
    local hits = nil
    for i = 1, #candidates do
        local m = candidates[i]
        local reach = radius + (tonumber(m.width) or 0) / 2
        local r2 = reach * reach
        local touched = false
        local chunks = self.chunks_by_id[m.id] or {}
        for c = 1, #chunks do
            local cm = chunks[c]
            if self:_boxTouches(cm, min_x - reach, min_y - reach,
                max_x + reach, max_y + reach, 0) then
                if ctx and ctx.stats then
                    ctx.stats.chunks_consulted = ctx.stats.chunks_consulted + 1
                end
                if m.points then
                    local first, last = self:_liveChunkRange(m, cm.chunk_no)
                    touched = Split.capsuleHitsRange(m.points, first, last,
                        x0, y0, x1, y1, r2)
                else
                    local part, n = self:_readChunk(m, cm.chunk_no, ctx)
                    if not part then self:_fail(n); return nil, n end
                    touched = Split.capsuleHitsRange(part, 1, n,
                        x0, y0, x1, y1, r2)
                end
                if touched then break end
            end
        end
        if touched then
            local points, n = self:_readAllPoints(m, ctx)
            if not points then self:_fail(n); return nil, n end
            local fragments, removed = Split.splitByCapsule(points, n,
                x0, y0, x1, y1, reach, tonumber(m.width) or 0)
            if fragments then
                if not hits then hits = {} end
                hits[#hits + 1] = {
                    meta = m, points = points, n = n,
                    fragments = fragments, removed = removed,
                }
            end
        end
    end
    if hits and #hits > 1 then
        table.sort(hits, function(a, b) return a.meta.seq < b.meta.seq end)
    end
    return hits
end

function Cache:_pointsHit(points, n, cx, cy, r2)
    return self:_pointsRangeHit(points, 1, n, cx, cy, r2)
end

function Cache:_pointsRangeHit(points, first, last, cx, cy, r2)
    if first == last then
        local dx = points[first * 2 - 1] - cx
        local dy = points[first * 2] - cy
        return dx * dx + dy * dy <= r2
    end
    for j = first + 1, last do
        if Split.pointSegmentDistance2(cx, cy,
            points[j * 2 - 3], points[j * 2 - 2],
            points[j * 2 - 1], points[j * 2]) <= r2 then
            return true
        end
    end
    return false
end

function Cache:_liveChunkRange(m, chunk_no)
    local first
    if chunk_no == 0 then first = 1
    else first = chunk_no * (Codec.MAX_POINTS - 1) + 1 end
    local last = first + Codec.MAX_POINTS - 1
    local total = m.n or m.point_count
    if last > total then last = total end
    return first, last
end

--[[--
Paint one live segment of the stroke in progress, in canvas coordinates.

Returns the dirty region in cache coordinates plus the cache identity and
generation for a live-raster token, or nil if nothing was painted. A segment
outside the canvas paints nothing at all: the buffer bounds the write, so it
is dropped rather than wrapped onto the far side.
]]
function Cache:drawSegment(x0, y0, x1, y1, width, color)
    if not self.bb then return nil end
    local tr = self.transform
    local w = tr:scaleWidth(width)
    local kx0, ky0 = tr:toCache(x0, y0)
    local kx1, ky1 = tr:toCache(x1, y1)
    local painted, left, top, right, bottom =
        Render.segment(self.bb, kx0, ky0, kx1, ky1, w, color or self.ink)
    if not painted then return nil end
    -- An explicit colour is exactly a gray style's (colorFor hands nil for
    -- pen). rawequal: a real colour is cdata whose __eq indexes its argument.
    if not rawequal(color, nil) then self.gray_ink = true end
    return {
        x = left, y = top, w = right - left, h = bottom - top,
    }, self, self.generation
end

function Cache:close()
    self.closed = true
    self.state = "closed"
    self.generation = self.generation + 1
    self.pending = {}
    self:_closeJob()
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
    self:_closeJob()
    self.load_error = nil
    self.state = "loading"
    self.chunks_by_id = {}
    self.gray_ink = false

    self:_freeBuffer()
    if not self.transform or type(self.transform.cacheSize) ~= "function" then
        self:_fail("bad_geometry")
        return nil, "bad_geometry"
    end
    local w, h = self.transform:cacheSize()
    if self.overlay then
        -- Transparent out of `calloc`, and it has to stay that way: `fill`
        -- forces alpha to 0xFF over every pixel, which would hide the whole
        -- page under an opaque sheet before a single stroke was painted.
        self.bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    else
        self.bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        self.bb:fill(self.background)
        self:_rulePaper(0, 0, w, h)
    end

    local grid, grid_err = Grid.new{
        width = self.canvas.logical_w,
        height = self.canvas.logical_h,
        cell = self:_cellSize(),
    }
    if not grid then
        self:_fail(grid_err or "bad_geometry")
        return nil, grid_err or "bad_geometry"
    end
    self.grid = grid
    for i = 1, #self.meta do
        local m = self.meta[i]
        self:_indexStroke(m)
    end

    -- Reversed, so popping from the end walks the strokes in drawing order.
    self.pending = {}
    for i = #self.meta, 1, -1 do
        self.pending[#self.pending + 1] = self.meta[i]
    end

    if #self.pending == 0 then
        self:_finish()
        return true
    end
    self:_scheduleBatch(generation)
    return true
end

function Cache:_scheduleBatch(generation)
    self.schedule(function()
        if self.closed or generation ~= self.generation then return end
        self:_rasteriseBatch(generation)
    end)
end

function Cache:_rasteriseBatch(generation)
    local used, chunks = 0, 0
    while chunks < self.chunk_budget
        and (used < self.point_budget or chunks == 0) do
        if not self.current_job then
            local m = table.remove(self.pending)
            if not m then break end
            local job, err = self:_openJob(m)
            if not job then self:_fail(err); return end
            self.current_job = job
        end

        local points, n, err, finished = self:_nextJobChunk(self.current_job)
        if err then self:_fail(err); return end
        if finished then
            self:_closeJob()
        else
            self:_paintStroke(self.current_job.meta, points, n)
            self:_recordChunk(self.current_job.meta,
                self.current_job.last_chunk_no, points, n)
            used = used + n
            chunks = chunks + 1
        end
    end

    if self.current_job or #self.pending > 0 then
        self:_scheduleBatch(generation)
        return
    end
    self:_finish()
end

function Cache:_finish()
    self.state = "ready"
    -- Per operation, at dbg level: off unless someone is looking, and never
    -- one line per pen sample.
    logger.dbg("JustDraw: canvas", self.canvas.id, "rasterised",
        #self.meta, "strokes into", self.bb and self.bb.w or 0,
        "x", self.bb and self.bb.h or 0)
    if self.on_ready then self.on_ready() end
end

function Cache:_fail(reason)
    self:_closeJob()
    self.pending = {}
    self.state = "load_failed"
    self.load_error = reason or "read_failed"
    logger.err("JustDraw: canvas could not be loaded:", self.load_error)
    if self.on_error then self.on_error(self.load_error) end
end

function Cache:_closeJob()
    self.current_job = nil
end

function Cache:_openJob(m)
    if m.points then
        return {
            meta = m,
            live = true,
            next_chunk = 0,
            chunk_count = Codec.chunkCount(m.n or m.point_count),
        }
    end
    if type(m.id) ~= "number" or m.id <= 0 then return nil, "unresolved_id" end
    local decoder, derr = Codec.newDecoder(self.canvas.logical_w,
        self.canvas.logical_h, m)
    if not decoder then return nil, derr end
    -- Never retain a SQLite statement across scheduler turns.  A keyed chunk
    -- lookup owns and closes its statement within one call; this avoids
    -- blocking writers on rollback-journal devices and holding old WAL
    -- snapshots open on devices such as the Scribe.
    return {
        meta = m,
        decoder = decoder,
        next_chunk = 0,
        chunk_count = Codec.chunkCount(m.point_count),
    }
end

function Cache:_nextJobChunk(job)
    if job.live then
        if job.next_chunk >= job.chunk_count then return nil, nil, nil, true end
        local first
        if job.next_chunk == 0 then
            first = 1
        else
            first = job.next_chunk * (Codec.MAX_POINTS - 1) + 1
        end
        local last = first + Codec.MAX_POINTS - 1
        local total = job.meta.n or job.meta.point_count
        if last > total then last = total end
        local points, n = {}, last - first + 1
        for i = first, last do
            points[#points + 1] = job.meta.points[i * 2 - 1]
            points[#points + 1] = job.meta.points[i * 2]
        end
        job.last_chunk_no = job.next_chunk
        job.next_chunk = job.next_chunk + 1
        return points, n
    end

    if job.next_chunk >= job.chunk_count then
        local ok, ferr = job.decoder:finish()
        if not ok then return nil, nil, ferr end
        return nil, nil, nil, true
    end
    local row, err = self.repository:readStrokeChunk(
        job.meta.id, job.next_chunk)
    if not row then return nil, nil, err or "missing_chunk" end
    local points, n = job.decoder:push(row.chunk_no, row.point_count, row.points)
    if not points then return nil, nil, n end
    job.last_chunk_no = row.chunk_no
    job.next_chunk = job.next_chunk + 1
    return points, n
end

function Cache:_recordChunk(m, chunk_no, points, n)
    local min_x, min_y = points[1], points[2]
    local max_x, max_y = min_x, min_y
    for i = 2, n do
        local x, y = points[i * 2 - 1], points[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end
    local list = self.chunks_by_id[m.id]
    if not list then list = {}; self.chunks_by_id[m.id] = list end
    list[#list + 1] = {
        chunk_no = chunk_no,
        point_count = n,
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
    }
end

function Cache:_indexLiveChunks(m, points, n)
    local first, chunk_no = 1, 0
    while first <= n do
        local last = first + Codec.MAX_POINTS - 1
        if last > n then last = n end
        local min_x, min_y = points[first * 2 - 1], points[first * 2]
        local max_x, max_y = min_x, min_y
        for i = first + 1, last do
            local x, y = points[i * 2 - 1], points[i * 2]
            if x < min_x then min_x = x elseif x > max_x then max_x = x end
            if y < min_y then min_y = y elseif y > max_y then max_y = y end
        end
        local list = self.chunks_by_id[m.id]
        if not list then list = {}; self.chunks_by_id[m.id] = list end
        list[#list + 1] = {
            chunk_no = chunk_no,
            point_count = last - first + 1,
            min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
        }
        if last == n then break end
        first = last
        chunk_no = chunk_no + 1
    end
end

function Cache:_paintStroke(m, points, n, target, ox, oy)
    local tr = self.transform
    -- Every persisted-stroke paint funnels through here -- build replay,
    -- repair, fragment repaint -- so this is where gray content is noticed.
    if Style.isGray(m.tool) then self.gray_ink = true end
    return Render.points(target or self.bb, points, n, tr.scale,
        ox or 0, oy or 0, tr:scaleWidth(m.width),
        Style.colorFor(m.tool, self.ink))
end

function Cache:_boxTouches(box, min_x, min_y, max_x, max_y, pad)
    -- Metadata drawn before the flush uses the original floating-point
    -- coordinates while a later read uses uint16-dequantised coordinates.
    -- Cover that sub-pixel difference so a segment exactly on a chunk-box
    -- edge cannot become unselectable after restart.
    local quantisation = math.max(self.canvas.logical_w, self.canvas.logical_h)
        / Codec.SCALE
    pad = (pad or 0) + quantisation
    return box.max_x + pad >= min_x and box.min_x - pad <= max_x
        and box.max_y + pad >= min_y and box.min_y - pad <= max_y
end

function Cache:_readChunk(m, chunk_no, ctx, stats)
    -- Keyed by the meta's session token, never by the row id: erasing the
    -- newest stroke frees its rowid for the very next insert, and a
    -- gesture-long LRU keyed by id would answer for the dead stroke --
    -- which is how a sweep used to blank the whole sheet (chunk_count_meta).
    local key = tostring(m.token or m.id) .. ":" .. tostring(chunk_no)
    if ctx and ctx.cache[key] then
        for i = #ctx.order, 1, -1 do
            if ctx.order[i] == key then table.remove(ctx.order, i); break end
        end
        ctx.order[#ctx.order + 1] = key
        local hit = ctx.cache[key]
        if ctx.stats then ctx.stats.lru_hits = ctx.stats.lru_hits + 1 end
        return hit.points, hit.n
    end

    local row, err = self.repository:readStrokeChunk(m.id, chunk_no)
    if not row then
        logger.warn("JustDraw: chunk read refused, stroke", m.id,
            "chunk", chunk_no, "err", err)
        return nil, err
    end
    if tonumber(row.chunk_no) ~= chunk_no then return nil, "chunk_order" end
    local points, n = Codec.decode(row.points,
        self.canvas.logical_w, self.canvas.logical_h)
    if not points then
        -- Name the decode's own reason: "chunk_count" used to swallow
        -- "count" and "bad_geometry" alike, which is not enough to
        -- diagnose a failure that only a device's data reproduces.
        logger.warn("JustDraw: chunk decode failed, stroke", m.id,
            "chunk", chunk_no, "reason", n,
            "blob_len", type(row.points) == "string" and #row.points or type(row.points),
            "row_count", tostring(row.point_count),
            "logical", tostring(self.canvas.logical_w),
            tostring(self.canvas.logical_h))
        if n == "version" then return nil, "unsupported_codec" end
        if n == "short" or n == "length" then return nil, "chunk_length" end
        return nil, "chunk_decode_" .. tostring(n)
    end
    if tonumber(row.point_count) ~= n then
        logger.warn("JustDraw: chunk row count mismatch, stroke", m.id,
            "chunk", chunk_no, "row_count", tostring(row.point_count),
            "decoded", n, "meta_count", tostring(m.point_count))
        return nil, "chunk_count_row"
    end
    if stats then stats.chunks_decoded = stats.chunks_decoded + 1 end
    if ctx and ctx.stats then
        ctx.stats.chunks_decoded = ctx.stats.chunks_decoded + 1
    end

    if ctx then
        ctx.cache[key] = { points = points, n = n }
        ctx.order[#ctx.order + 1] = key
        while #ctx.order > ctx.limit do
            local evicted = table.remove(ctx.order, 1)
            ctx.cache[evicted] = nil
        end
    end
    return points, n
end

--- The whole stroke as one flat array plus its count. Live metas hand back
--- their own table -- callers read, never mutate. Persisted metas are
--- assembled from chunks through the erase LRU, with the repeated seam
--- point dropped and checked the way Codec.join checks it.
function Cache:_readAllPoints(m, ctx)
    if m.points then return m.points, m.n end
    local total = m.point_count
    local chunk_count = Codec.chunkCount(total)
    if chunk_count == 1 then
        local points, n = self:_readChunk(m, 0, ctx)
        if not points then return nil, n end
        if n ~= total then
            logger.warn("JustDraw: single-chunk stroke disagrees with its meta,",
                "stroke", m.id, "decoded", n, "meta_count", tostring(total))
            return nil, "chunk_count_meta"
        end
        return points, n
    end
    local points, n = {}, 0
    for chunk_no = 0, chunk_count - 1 do
        local part, count = self:_readChunk(m, chunk_no, ctx)
        if not part then return nil, count end
        local from = 1
        if chunk_no > 0 then
            if part[1] ~= points[n * 2 - 1] or part[2] ~= points[n * 2] then
                logger.warn("JustDraw: chunk seam disagrees, stroke", m.id,
                    "chunk", chunk_no, "joined", n)
                return nil, "chunk_joint"
            end
            from = 2
        end
        for i = from, count do
            n = n + 1
            points[n * 2 - 1] = part[i * 2 - 1]
            points[n * 2] = part[i * 2]
        end
    end
    if n ~= total then
        logger.warn("JustDraw: joined chunks disagree with their meta,",
            "stroke", m.id, "joined", n, "meta_count", tostring(total),
            "chunks", chunk_count)
        return nil, "chunk_count_join"
    end
    return points, n
end

function Cache:_paintMetaRegion(m, canvas_box, target, ox, oy, stats)
    if m.points then
        local chunks = self.chunks_by_id[m.id] or {}
        local pad = (tonumber(m.width) or 0) / 2
        for i = 1, #chunks do
            local cm = chunks[i]
            if self:_boxTouches(cm, canvas_box.min_x, canvas_box.min_y,
                canvas_box.max_x, canvas_box.max_y, pad) then
                if stats then
                    stats.chunks_consulted = stats.chunks_consulted + 1
                end
                local first, last = self:_liveChunkRange(m, cm.chunk_no)
                local part = {}
                for p = first, last do
                    part[#part + 1] = m.points[p * 2 - 1]
                    part[#part + 1] = m.points[p * 2]
                end
                self:_paintStroke(m, part, last - first + 1, target, ox, oy)
            end
        end
        return true
    end
    local chunks = self.chunks_by_id[m.id] or {}
    local pad = (tonumber(m.width) or 0) / 2
    for i = 1, #chunks do
        local cm = chunks[i]
        if self:_boxTouches(cm, canvas_box.min_x, canvas_box.min_y,
            canvas_box.max_x, canvas_box.max_y, pad) then
            if stats then stats.chunks_consulted = stats.chunks_consulted + 1 end
            local points, n = self:_readChunk(m, cm.chunk_no, nil, stats)
            if not points then return nil, n end
            self:_paintStroke(m, points, n, target, ox, oy)
        end
    end
    return true
end

function Cache:_indexStroke(m)
    local pad = (tonumber(m.width) or 0) / 2
    self.grid:insert(m.id, m.min_x - pad, m.min_y - pad,
        m.max_x + pad, m.max_y + pad)
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
