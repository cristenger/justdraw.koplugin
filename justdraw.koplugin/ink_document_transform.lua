--[[--
Where the live fixed-layout reader becomes a coordinate transform -- and where
it is refused.

Ink on a page of a PDF is stored in the page's own units (ADR-38), so
something has to say where those units land on the screen at this zoom and
this pan. KOReader already answers that question for its own highlights:
`ReaderView:getSinglePagePosition` is `(visible_area + screen - offset) / zoom`
-- a translate and a scale, and nothing else. So this module writes no formula
of its own. It composes the two rectangles that make `ink_canvas_transform`
compute exactly that one, and hands back an ordinary transform: the single
copy of the coordinate math stays single, and input, hit testing, erasing, the
raster cache and painting keep going through the one instance they already
share. The alternative -- a second formula set for fixed pages -- is how ink
ends up a few pixels from the pen after a pan, in one of the copies only.

The other half is the refusals, and they are why this is a module rather than
three lines in the reader wiring. That formula is a lie in every mode where a
page is not one rigid rectangle scaled onto the screen: CREngine, which has no
native page at all; scroll mode, where one screen can hold parts of two pages;
a page state that says it is rotated; a KOPT reflow (`text_wrap`), where what
is on the screen is a re-laid-out page; a KOPT-optimised page, whose tile is
not the page either; and a view whose `state.offset` does not exist yet
because `recalculate` has not run. Each refusal answers its own reason so the
caller can tell the reader which one it is -- "not supported" with no
explanation is what makes a reader try the same thing again. Auto-crop and the
footer need no refusal: both are already inside `visible_area`, which the
formula carries.

Last, a budget. The raster is the whole page at zoom, two bytes a pixel as an
overlay, so a reader who zooms far in would ask for a buffer the device cannot
hold -- and the allocation would happen inside a paint. Above
`MAX_CACHE_FACTOR` screens' worth of pixels the answer is `zoom_too_large`,
which is a sentence the reader can act on, rather than an allocation that
fails.

Nothing here is a hot path. `fromView` runs on the view events that can move
the page -- page turn, zoom, pan, scroll-mode change, resize -- never per
sample, so it allocates the rectangles and the transform it returns. It takes
the screen size as an argument rather than asking `Device`, so the whole thing
stays loadable, and testable, with no device at all.
]]

local Transform = require("ink_canvas_transform")

local ceil = math.ceil

local DocumentTransform = {}

--- Screens' worth of pixels a page raster may cost before it is refused.
DocumentTransform.MAX_CACHE_FACTOR = 2

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

--- The pixel budget for one page raster on this screen. A screen that cannot
--- say how big it is has no budget at all rather than an infinite one.
function DocumentTransform.maxCachePixels(screen_w, screen_h)
    local w, h = tonumber(screen_w), tonumber(screen_h)
    if not finite(w) or not finite(h) or w <= 0 or h <= 0 then return 0 end
    return DocumentTransform.MAX_CACHE_FACTOR * w * h
end

--[[--
What a page-ink surface stores for this page.

`logical_w/h` are the native page rounded *up*: MuPDF measures in points and
`fz_bound_page` does not round, so an A4 page is 595.276 x 841.89 and a
surface has to be whole units. Rounding up rather than down keeps every point
of the page inside the surface; the fraction of a unit at the far edge costs
nothing, because the codec normalises the axis either way.

`units` is what those numbers are, and only MuPDF's are points. DjVu and
images are pixels of a DPI nobody stated, which the export has to know before
it can put a page on paper.

Answers `no_dimensions` when the document cannot say, and `bad_geometry` when
what it said is not a page.
]]
function DocumentTransform.surfaceSpec(document, page)
    if type(document) ~= "table"
        or type(document.getNativePageDimensions) ~= "function" then
        return nil, "no_dimensions"
    end
    local pageno = tonumber(page)
    if not finite(pageno) or pageno < 1 then return nil, "no_dimensions" end
    -- A document that raises here has not answered; it must not take the
    -- caller down with it, because this is reached from a view event.
    local ok, native = pcall(document.getNativePageDimensions, document, pageno)
    if not ok or type(native) ~= "table" then return nil, "no_dimensions" end
    local w, h = tonumber(native.w), tonumber(native.h)
    if not finite(w) or not finite(h) or w <= 0 or h <= 0 then
        return nil, "bad_geometry"
    end
    return {
        logical_w = ceil(w),
        logical_h = ceil(h),
        units = document.provider == "mupdf" and "pt" or "px",
    }
end

--[[--
Whether a stored surface still describes this page.

Within one unit in both axes, because the rounding above and a document
re-opened by another MuPDF build can disagree by a fraction that means
nothing. Anything wider than that is a different page: the ink is kept and
editing is not (`page_geometry_changed`, ADR-38).
]]
function DocumentTransform.geometryMatches(surface, spec)
    if type(surface) ~= "table" or type(spec) ~= "table" then return false end
    local sw, sh = tonumber(surface.logical_w), tonumber(surface.logical_h)
    local pw, ph = tonumber(spec.logical_w), tonumber(spec.logical_h)
    if not finite(sw) or not finite(sh) or not finite(pw) or not finite(ph) then
        return false
    end
    return math.abs(sw - pw) <= 1 and math.abs(sh - ph) <= 1
end

--[[--
  ui, view                 the live ReaderUI and ReaderView
  surface                  the stored page-ink surface (logical_w, logical_h)
  opts.screen              { w, h } -- the caller's `Screen:getWidth/Height`
  opts.max_cache_pixels    overrides the budget derived from that screen

Returns an `ink_canvas_transform` for this page at this zoom and pan, or nil
plus one of `no_view`, `unsupported_document`, `unsupported_mode`,
`unsupported_rotation`, `unsupported_reflow`, `unsupported_optimizing`,
`bad_geometry`, `zoom_too_large` -- checked in that order, so the reason a
reader is shown is the first thing wrong rather than the last.

`fit_rect` is the whole page at zoom, placed where KOReader placed it: the
view's origin, plus the page offset, minus the part of the page scrolled off
the left and top. `clip_rect` is what is actually on screen. Aligned left and
top, because the fit rectangle is already the page's exact size at this zoom
-- which is also why the transform's `scale` comes out as `zoom` itself.
]]
function DocumentTransform.fromView(ui, view, surface, opts)
    opts = opts or {}
    if type(ui) ~= "table" or type(view) ~= "table" then return nil, "no_view" end

    local document = view.document or ui.document
    if type(document) ~= "table" then return nil, "no_view" end

    -- `state.offset` is nil until the first `recalculate`, and a view event
    -- can arrive before it -- so this is a refusal and not a crash. Every
    -- number the formula needs is read once, here, for the same reason: a
    -- missing one has to be a reason, not arithmetic on nil.
    local state = view.state
    if type(state) ~= "table" or type(state.offset) ~= "table"
        or type(view.visible_area) ~= "table" or type(view.dimen) ~= "table" then
        return nil, "no_view"
    end
    local zoom = tonumber(state.zoom)
    local off_x, off_y = tonumber(state.offset.x), tonumber(state.offset.y)
    local vis = view.visible_area
    local vis_x, vis_y = tonumber(vis.x), tonumber(vis.y)
    local vis_w, vis_h = tonumber(vis.w), tonumber(vis.h)
    local org_x, org_y = tonumber(view.dimen.x), tonumber(view.dimen.y)
    if not finite(zoom) or not finite(off_x) or not finite(off_y)
        or not finite(vis_x) or not finite(vis_y)
        or not finite(vis_w) or not finite(vis_h)
        or not finite(org_x) or not finite(org_y) then
        return nil, "no_view"
    end
    -- The budget belongs with them: a caller that cannot say how big the
    -- screen is has not described a view this can size a raster for, and
    -- guessing one is how the refusal below stops meaning anything.
    local budget = tonumber(opts.max_cache_pixels)
    if not finite(budget) then
        local screen = opts.screen
        budget = type(screen) == "table"
            and DocumentTransform.maxCachePixels(screen.w, screen.h) or 0
    end
    if budget <= 0 then return nil, "no_view" end

    if not ui.paging then return nil, "unsupported_document" end
    if view.page_scroll then return nil, "unsupported_mode" end
    if (tonumber(state.rotation) or 0) ~= 0 then return nil, "unsupported_rotation" end

    local configurable = document.configurable
    if type(configurable) == "table" and tonumber(configurable.text_wrap) == 1 then
        return nil, "unsupported_reflow"
    end
    local kopt = document.koptinterface
    if type(kopt) == "table" and type(kopt.is_optimizing_page) == "function" then
        -- `is_optimizing_page` reads three `configurable` fields and raises
        -- for a document that has none. Not being able to tell is not the
        -- same as a plain page, so it refuses the same way a yes does.
        local answered, optimizing = pcall(kopt.is_optimizing_page, kopt, document)
        if not answered or optimizing then return nil, "unsupported_optimizing" end
    end

    local logical_w = type(surface) == "table" and tonumber(surface.logical_w) or nil
    local logical_h = type(surface) == "table" and tonumber(surface.logical_h) or nil
    if not finite(logical_w) or not finite(logical_h)
        or logical_w <= 0 or logical_h <= 0 then
        return nil, "bad_geometry"
    end

    local transform, reason = Transform.new{
        logical_w = logical_w,
        logical_h = logical_h,
        fit_rect = {
            x = org_x + off_x - vis_x,
            y = org_y + off_y - vis_y,
            w = logical_w * zoom,
            h = logical_h * zoom,
        },
        clip_rect = {
            x = org_x + off_x,
            y = org_y + off_y,
            w = vis_w,
            h = vis_h,
        },
        align_x = "left",
        align_y = "top",
    }
    if not transform then return nil, reason end

    local cache_w, cache_h = transform:cacheSize()
    if cache_w * cache_h > budget then return nil, "zoom_too_large" end
    return transform
end

return DocumentTransform
