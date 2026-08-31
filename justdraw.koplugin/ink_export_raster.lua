--[[--
A whole surface, rasterised off screen, for one export and nobody else.

The obvious shortcut here is to reuse the raster the editor is already holding.
It is wrong twice: that buffer is at the scale the *screen* asked for, and it
belongs to a live session that may rebuild or free it while the file is still
being written. An export therefore builds its own, from the stored vectors,
and owns it until it has finished with it.

What it does not do is reimplement rasterisation. `InkCanvasCache` already
composes the paper ruling and replays strokes in bounded batches with one
chunk decoded at a time (ADR-27), which is the property that keeps a dense
page from costing its contents in transient memory. This module is the narrow
thing around it: a transform that makes the cache's buffer *be* the whole
surface at a chosen scale, a pixel budget, and an ownership boundary.

Two rules are worth stating because they are easy to break by accident:

**The scheduler stays asynchronous.** `Cache` reschedules itself between
batches, so a `schedule` that calls its argument immediately turns batching
into recursion -- one Lua frame per batch, with the depth set by how much the
reader drew. Callers pass `UIManager:nextTick`; tests pass a queue they drain.

**The terminal callbacks are handed back on a later tick.** `Cache` signals
readiness from inside its own batch loop, and continuing an export from there
would run file writes underneath the cache's stack frame -- and, if that job
then closed the cache, free the buffer the loop is about to touch. Settling
through `schedule` makes every continuation a fresh stack.

Scale is a policy, not a measurement. A notebook page knows its millimetres
(`LOGICAL_UNITS_PER_MM`), so it can be rendered at a real 300 dpi. An EPUB
sheet's logical units are pixels of whatever screen first drew it and carry no
DPI at all, so it is rasterised 1:1 and given a nominal DPI only when a
physical page size is finally needed. Either way the result is capped by area:
memory is what runs out on these devices, and it runs out per page.
]]

local Cache = require("ink_canvas_cache")
local Transform = require("ink_canvas_transform")

local Raster = {}

--[[--
The area budget for one exported page, in pixels.

A BB8 costs one byte per pixel, but that is only the floor of the peak: a PDF
page also holds the raw bytes as a Lua string and whatever zlib allocates on
top, and a colour source adds an RGB24 conversion. 8 Mpx keeps an A5 notebook
page above 300 dpi while leaving that peak inside what a Kindle-class device
can be asked for.
]]
Raster.MAX_PIXELS = 8000000

--- What a surface with no physical size is rendered at when a PDF finally
--- needs points. Nominal: it reproduces the aspect and is deterministic, and
--- it does not claim to recover a size that was never stored.
Raster.NOMINAL_DPI = 300

--- What a surface that *does* know its millimetres aims for.
Raster.TARGET_DPI = 300

local floor, sqrt, min = math.floor, math.sqrt, math.min

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function positive(v)
    return finite(v) and v > 0
end

--- Pixels per logical unit that puts `dpi` dots on every inch of a surface
--- whose logical units are `units_per_mm` to the millimetre. The caller
--- supplies the unit count so this file does not become a second place that
--- believes it knows how big a notebook page is.
function Raster.physicalScale(units_per_mm, dpi)
    if not positive(units_per_mm) or not positive(dpi) then return nil end
    return (dpi / 25.4) / units_per_mm
end

--- Points per logical unit, for a surface with a physical size.
function Raster.physicalPoints(units_per_mm, logical)
    if not positive(units_per_mm) or not finite(logical) then return nil end
    return logical / units_per_mm * 72 / 25.4
end

--- Points for a surface whose logical units are pixels at a nominal DPI.
function Raster.nominalPoints(pixels, dpi)
    if not finite(pixels) or not positive(dpi) then return nil end
    return pixels * 72 / dpi
end

--- The buffer `Transform:cacheSize` would ask for at this scale. Rounding to
--- the nearest whole pixel is copied from there rather than approximated: the
--- budget is about the allocation, so it has to be measured in the same units
--- the allocation is made in.
local function roundedPixels(logical_w, logical_h, scale)
    local w = floor(logical_w * scale + 0.5)
    local h = floor(logical_h * scale + 0.5)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    return w * h, w, h
end

--- Public because the disk-space forecast has to count the same pixels the
--- allocation reserves, with the same rounding. A forecast built on the
--- unrounded product would describe a different buffer than the one that gets
--- made.
Raster.roundedPixels = roundedPixels

--[[--
Reduce a target scale until the raster fits the pixel budget.

Area, not width: a page can be out of budget by being tall just as easily as
by being wide, and an export that only checked one axis would allocate the
other without limit.

The continuous bound -- `sqrt(budget / area)` -- is only the starting point.
Each axis is then *rounded* to whole pixels, and two roundings up can put the
product back over the budget that the unrounded scale satisfied; a 400 x 40000
page at the area bound lands on 283 x 28284, which is 8,004,372 for a budget
of 8,000,000. So the answer is searched for on the rounded product, which is
the number that will actually be allocated. Bisection rather than a shrinking
factor because the rounded product is a step function: a multiplicative nudge
can leave both dimensions unchanged and make no progress at all.
]]
function Raster.boundedScale(logical_w, logical_h, target, max_pixels)
    if not positive(logical_w) or not positive(logical_h)
        or not positive(target) then
        return nil, "bad_geometry"
    end
    max_pixels = max_pixels or Raster.MAX_PIXELS
    if not positive(max_pixels) then return nil, "bad_geometry" end

    local scale = min(target, sqrt(max_pixels / (logical_w * logical_h)))
    if not positive(scale) then return nil, "bad_geometry" end
    if roundedPixels(logical_w, logical_h, scale) <= max_pixels then
        return scale
    end

    -- A scale approaching zero clamps both axes to one pixel, so the low end
    -- is always feasible and the search is well defined.
    local low, high = 0, scale
    for _ = 1, 60 do
        local mid = (low + high) / 2
        if roundedPixels(logical_w, logical_h, mid) <= max_pixels then
            low = mid
        else
            high = mid
        end
    end
    if not positive(low) then return nil, "bad_geometry" end
    return low
end

local Job = {}
Job.__index = Job

--[[--
  opts.repository  read side of the surface's store
  opts.surface     the row: id, logical_w, logical_h, maybe template_kind
  opts.scale       pixels per logical unit (already bounded)
  opts.schedule    function(fn) -- must defer; never call fn inline
  opts.on_ready    function(job)
  opts.on_error    function(reason, job)
  opts.paper_kind  ruling; defaults to the surface's own, so a canvas is blank
]]
function Raster.open(opts)
    opts = opts or {}
    local surface = opts.surface
    if type(surface) ~= "table" or surface.id == nil
        or not positive(tonumber(surface.logical_w))
        or not positive(tonumber(surface.logical_h)) then
        return nil, "bad_surface"
    end
    if not opts.repository then return nil, "no_repository" end
    if type(opts.schedule) ~= "function" then return nil, "no_scheduler" end
    local scale = tonumber(opts.scale)
    if not positive(scale) then return nil, "bad_geometry" end

    local logical_w = tonumber(surface.logical_w)
    local logical_h = tonumber(surface.logical_h)
    local rect = {
        x = 0, y = 0,
        w = logical_w * scale,
        h = logical_h * scale,
    }
    local transform, transform_err = Transform.new{
        logical_w = logical_w,
        logical_h = logical_h,
        fit_rect = rect,
        clip_rect = rect,
        align_x = "left",
        align_y = "top",
    }
    if not transform then return nil, transform_err or "bad_geometry" end

    -- `boundedScale` is advice a caller may not have taken, and the transform
    -- recomputes its own scale from the rectangle it was handed. This is the
    -- claim that matters and the last place to make it: what `Cache` is about
    -- to allocate, measured after every rounding, against the budget.
    local max_pixels = tonumber(opts.max_pixels) or Raster.MAX_PIXELS
    local cache_w, cache_h = transform:cacheSize()
    if cache_w * cache_h > max_pixels then return nil, "too_large" end

    local job = setmetatable({
        schedule = opts.schedule,
        on_ready = opts.on_ready,
        on_error = opts.on_error,
        transform_obj = transform,
        surface = surface,
        settled = false,
        closed = false,
        error = nil,
    }, Job)

    job.cache_obj = Cache.new{
        repository = opts.repository,
        surface = surface,
        transform = transform,
        schedule = opts.schedule,
        paper_kind = opts.paper_kind or surface.template_kind,
        ink = opts.ink,
        background = opts.background,
        on_ready = function() job:_settle(nil) end,
        on_error = function(reason) job:_settle(reason or "raster_failed") end,
    }

    -- `Cache:open` reports a bad stroke list synchronously, before any batch
    -- runs. Settling covers both arrival routes, and the guard inside it keeps
    -- a synchronous failure from being delivered twice.
    local ok, err = job.cache_obj:open()
    if not ok then job:_settle(err or "raster_failed") end
    return job
end

--- Deliver the outcome, once, on a later tick. See the module header.
function Job:_settle(reason)
    if self.settled or self.closed then return false end
    self.settled = true
    self.error = reason
    self.schedule(function()
        if self.closed then return end
        if reason then
            if self.on_error then self.on_error(reason, self) end
        elseif self.on_ready then
            self.on_ready(self)
        end
    end)
    return true
end

--- The raster. Valid until `close`, and nil after it.
function Job:buffer()
    if self.closed or self.error then return nil end
    return self.cache_obj and self.cache_obj:buffer() or nil
end

function Job:size()
    return self.transform_obj:cacheSize()
end

function Job:transform()
    return self.transform_obj
end

function Job:isReady()
    return self.settled and not self.error and not self.closed
end

function Job:failure()
    return self.error
end

--- Idempotent, and the only thing that frees the buffer. A job that is closed
--- before it settles simply never delivers: the scheduled continuation checks.
function Job:close()
    if self.closed then return true end
    self.closed = true
    local cache = self.cache_obj
    self.cache_obj = nil
    if cache then cache:close() end
    return true
end

Raster.Job = Job

return Raster
