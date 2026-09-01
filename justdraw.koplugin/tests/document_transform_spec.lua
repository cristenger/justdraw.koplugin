--[[--
The factory that turns the live fixed-layout reader into a coordinate
transform, and the six ways it refuses.

Two properties carry the whole feature. The first is that the transform it
builds computes KOReader's own single-page formula --
`(visible_area + screen - offset) / zoom` -- so ink lands where the pen was
after a zoom, a pan and a page turn; `tests/conformance.lua` states that same
equality against the real `ReaderView` methods, which is what keeps this file
from proving only that the module agrees with itself.

The second is that every mode where that formula is a lie is refused *by name*
and in a fixed order. The order matters because the reasons are what the
reader is told: a scrolling CREngine view has three things wrong with it, and
"this document has no pages" is the useful half.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local DocumentTransform = require("ink_document_transform")

    -- A4 in points, the way MuPDF measures it: not an integer in either axis.
    local SURFACE = { logical_w = 596, logical_h = 842, units = "pt" }
    local SCREEN = { w = 1000, h = 1400 }

    local BASE = {
        state = { offset = { x = 10, y = 20 } },
        visible_area = { x = 100, y = 50, w = 800, h = 1200 },
        dimen = { x = 0, y = 0, w = 800, h = 1200 },
    }

    --- A reader view on the base geometry, with `over` merged one level deep
    --- so a test states only the field it is about.
    local function reader(over)
        over = over or {}
        local opts = {}
        for k, v in pairs(over) do opts[k] = v end
        for _, key in ipairs({ "state", "visible_area", "dimen" }) do
            local given = over[key]
            if given == nil then
                opts[key] = BASE[key]
            elseif type(given) == "table" then
                local merged = {}
                for k, v in pairs(BASE[key]) do merged[k] = v end
                for k, v in pairs(given) do merged[k] = v end
                opts[key] = merged
            end
        end
        return support.newReaderView(opts)
    end

    local function from(rv, opts)
        opts = opts or {}
        local surface = opts.surface
        if surface == nil then surface = SURFACE end
        return DocumentTransform.fromView(rv.ui, rv.view, surface, {
            screen = opts.screen == nil and SCREEN or opts.screen,
            max_cache_pixels = opts.max_cache_pixels,
        })
    end

    --- A koptinterface that answers the given verdict for every document.
    local function kopt(optimizing)
        return { is_optimizing_page = function() return optimizing end }
    end

    local function near(a, b, tol)
        return math.abs(a - b) <= (tol or 1e-9)
    end

    -- =================================================================
    t:describe("ink_document_transform / the page under the pen")

    t:case("the scale is the view's zoom, exactly", function()
        local tr = from(reader())
        t:check(tr ~= nil, "a transform")
        t:eq(tr and tr.scale, 2, "scale is zoom")
    end)

    t:case("toCanvas is KOReader's own single-page formula", function()
        local rv = reader()
        local tr = from(rv)
        local va = rv.view.visible_area
        local off = rv.view.state.offset
        local zoom = rv.view.state.zoom
        -- The corners and the centre of what is on screen, in screen
        -- coordinates: the clip rectangle starts at dimen + offset.
        local x0, y0 = rv.view.dimen.x + off.x, rv.view.dimen.y + off.y
        local points = {
            { x0, y0 },
            { x0 + va.w, y0 },
            { x0, y0 + va.h },
            { x0 + va.w, y0 + va.h },
            { x0 + va.w / 2, y0 + va.h / 2 },
        }
        for i = 1, #points do
            local sx, sy = points[i][1], points[i][2]
            local cx, cy = tr:toCanvas(sx, sy)
            local want_x = (va.x + (sx - rv.view.dimen.x) - off.x) / zoom
            local want_y = (va.y + (sy - rv.view.dimen.y) - off.y) / zoom
            t:check(near(cx, want_x), "x of point " .. i)
            t:check(near(cy, want_y), "y of point " .. i)
            local bx, by = tr:toScreen(cx, cy)
            t:check(near(bx, sx), "x round trip of point " .. i)
            t:check(near(by, sy), "y round trip of point " .. i)
        end
    end)

    t:case("the cache is the whole page at zoom", function()
        local tr = from(reader())
        local w, h = tr:cacheSize()
        t:eq(w, SURFACE.logical_w * 2, "cache width")
        t:eq(h, SURFACE.logical_h * 2, "cache height")
    end)

    t:case("the canvas rectangle is the visible area, on screen", function()
        local rv = reader()
        local tr = from(rv)
        local r = tr:canvasRect()
        t:eq(r.x, rv.view.dimen.x + rv.view.state.offset.x, "x")
        t:eq(r.y, rv.view.dimen.y + rv.view.state.offset.y, "y")
        t:eq(r.w, rv.view.visible_area.w, "w")
        t:eq(r.h, rv.view.visible_area.h, "h")
    end)

    t:case("a point in the surround is not on the page", function()
        local rv = reader()
        local tr = from(rv)
        local x0 = rv.view.dimen.x + rv.view.state.offset.x
        local y0 = rv.view.dimen.y + rv.view.state.offset.y
        t:check(tr:contains(x0, y0), "the top left corner is on the page")
        t:check(not tr:contains(x0 - 1, y0), "one pixel left of it is not")
        t:check(not tr:contains(x0, y0 - 1), "one pixel above it is not")
        t:check(not tr:contains(x0 + rv.view.visible_area.w, y0),
            "the far edge is exclusive")
    end)

    t:case("the view's own origin shifts both maps", function()
        local at_origin = from(reader())
        local moved = from(reader{ dimen = { x = 37, y = 11 } })
        local cx, cy = at_origin:toCanvas(300, 400)
        local mx, my = moved:toCanvas(300 + 37, 400 + 11)
        t:check(near(cx, mx), "toCanvas follows the view origin")
        t:check(near(cy, my), "and in y")
        local sx, sy = at_origin:toScreen(100, 200)
        local msx, msy = moved:toScreen(100, 200)
        t:check(near(msx - sx, 37), "toScreen follows it too")
        t:check(near(msy - sy, 11), "and in y")
    end)

    t:case("a pan moves the offsets and leaves the scale alone", function()
        local before = from(reader())
        local after = from(reader{ visible_area = { x = 240, y = 610 } })
        t:eq(after.scale, before.scale, "the scale is the same zoom")
        t:check(after.offset_x ~= before.offset_x, "the x offset moved")
        t:check(after.offset_y ~= before.offset_y, "the y offset moved")
        t:check(near(before.offset_x - after.offset_x, 240 - 100), "by the pan")
        t:check(near(before.offset_y - after.offset_y, 610 - 50), "and in y")
    end)

    -- =================================================================
    t:describe("ink_document_transform / the refusals")

    t:case("a view that is not there", function()
        local rv = reader()
        local _, r1 = DocumentTransform.fromView(nil, rv.view, SURFACE,
            { screen = SCREEN })
        t:eq(r1, "no_view", "no ui")
        local _, r2 = DocumentTransform.fromView(rv.ui, nil, SURFACE,
            { screen = SCREEN })
        t:eq(r2, "no_view", "no view")
    end)

    t:case("a view before the first recalculate has no offset", function()
        local _, reason = from(reader{ state = { offset = false } })
        t:eq(reason, "no_view", "state.offset is nil until recalculate")
    end)

    t:case("the fields the formula reads must all be numbers", function()
        local _, no_area = from(reader{ visible_area = false })
        t:eq(no_area, "no_view", "no visible_area")
        local _, no_dimen = from(reader{ dimen = false })
        t:eq(no_dimen, "no_view", "no dimen")
        local _, no_zoom = from(reader{ state = { zoom = false } })
        t:eq(no_zoom, "no_view", "no zoom")
        local _, nan = from(reader{ state = { zoom = 0 / 0 } })
        t:eq(nan, "no_view", "a zoom that is not a number")
        local _, no_doc = from(reader{ document = false })
        t:eq(no_doc, "no_view", "no document")
    end)

    t:case("a caller that cannot say how big the screen is", function()
        local _, reason = from(reader(), { screen = false })
        t:eq(reason, "no_view", "the budget cannot be computed")
    end)

    t:case("CREngine has no native page to map", function()
        local _, reason = from(reader{ paging = false, rolling = true })
        t:eq(reason, "unsupported_document")
    end)

    t:case("scroll mode can hold two pages on one screen", function()
        local _, reason = from(reader{ page_scroll = true })
        t:eq(reason, "unsupported_mode")
    end)

    t:case("a rotated page state is not mapped, it is refused", function()
        local _, reason = from(reader{ state = { rotation = 90 } })
        t:eq(reason, "unsupported_rotation")
        t:check(from(reader{ state = { rotation = false } }) ~= nil,
            "an absent rotation reads as zero")
    end)

    t:case("KOPT reflow puts a different page on the screen", function()
        local _, reason = from(reader{ configurable = { text_wrap = 1 } })
        t:eq(reason, "unsupported_reflow")
        t:check(from(reader{ configurable = { text_wrap = 0 } }) ~= nil,
            "text_wrap 0 is the ordinary page")
    end)

    t:case("an optimised page is not the page either", function()
        local _, reason = from(reader{ koptinterface = kopt(true) })
        t:eq(reason, "unsupported_optimizing")
        t:check(from(reader{ koptinterface = kopt(false) }) ~= nil,
            "a koptinterface that says no is fine")
    end)

    t:case("a document with neither configurable nor koptinterface passes", function()
        local tr = from(reader{
            provider = "picdocument", configurable = false, koptinterface = false,
        })
        t:check(tr ~= nil, "a picdocument still has one rigid page")
    end)

    t:case("a geometry no transform can be built from", function()
        local _, no_surface = from(reader(), { surface = false })
        t:eq(no_surface, "bad_geometry", "no surface")
        local _, empty = from(reader(),
            { surface = { logical_w = 0, logical_h = 842 } })
        t:eq(empty, "bad_geometry", "a surface with no width")
        local _, no_zoom = from(reader{ state = { zoom = 0 } })
        t:eq(no_zoom, "bad_geometry", "a zoom of zero is a page with no size")
        local _, no_view_area = from(reader{ visible_area = { w = 0 } })
        t:eq(no_view_area, "bad_geometry", "nothing is visible")
    end)

    t:case("a zoom whose raster will not fit is refused, not allocated", function()
        local tr, reason = from(reader{ state = { zoom = 4 } })
        t:eq(tr, nil, "no transform")
        t:eq(reason, "zoom_too_large")
        t:check(from(reader{ state = { zoom = 4 } },
            { max_cache_pixels = 1e9 }) ~= nil, "a bigger budget takes it")
    end)

    t:case("the gates answer in the order the reasons are listed", function()
        local rv = reader{
            paging = false,
            page_scroll = true,
            state = { rotation = 90, offset = false },
            configurable = { text_wrap = 1 },
            koptinterface = kopt(true),
        }
        local function reason()
            local _, r = from(rv)
            return r
        end
        t:eq(reason(), "no_view", "a missing offset outranks every mode")
        rv.view.state.offset = { x = 10, y = 20 }
        t:eq(reason(), "unsupported_document", "then the document kind")
        rv.ui.paging = true
        t:eq(reason(), "unsupported_mode", "then the view mode")
        rv.view.page_scroll = false
        t:eq(reason(), "unsupported_rotation", "then the rotation")
        rv.view.state.rotation = 0
        t:eq(reason(), "unsupported_reflow", "then reflow")
        rv.view.document.configurable.text_wrap = 0
        t:eq(reason(), "unsupported_optimizing", "then optimisation")
        rv.view.document.koptinterface = nil
        rv.view.state.zoom = 0
        t:eq(reason(), "bad_geometry", "then the geometry")
        rv.view.state.zoom = 4
        t:eq(reason(), "zoom_too_large", "and only then the budget")
        rv.view.state.zoom = 2
        t:check(from(rv) ~= nil, "with nothing left wrong, a transform")
    end)

    -- =================================================================
    t:describe("ink_document_transform / the raster budget")

    t:case("the budget is two screens' worth of pixels", function()
        t:eq(DocumentTransform.MAX_CACHE_FACTOR, 2, "the factor")
        t:eq(DocumentTransform.maxCachePixels(1000, 1400), 2 * 1000 * 1400,
            "two bytes a pixel, as an overlay")
    end)

    t:case("a screen that is not a screen has no budget", function()
        t:eq(DocumentTransform.maxCachePixels(nil, 1400), 0, "no width")
        t:eq(DocumentTransform.maxCachePixels(1000, 0), 0, "no height")
        t:eq(DocumentTransform.maxCachePixels(1000, 0 / 0), 0, "not a number")
    end)

    -- =================================================================
    t:describe("ink_document_transform / what a page stores")

    t:case("the surface is the page rounded up, in the document's units", function()
        local rv = reader()
        local spec = DocumentTransform.surfaceSpec(rv.view.document, 1)
        t:eq(spec and spec.logical_w, 596, "595.276 pt rounds up")
        t:eq(spec and spec.logical_h, 842, "841.89 pt rounds up")
        t:eq(spec and spec.units, "pt", "MuPDF measures in points")
    end)

    t:case("only MuPDF answers in points", function()
        local djvu = reader{ provider = "djvulibre" }.view.document
        t:eq(DocumentTransform.surfaceSpec(djvu, 1).units, "px",
            "DjVu is pixels of unknown DPI")
        local pic = reader{ provider = "picdocument" }.view.document
        t:eq(DocumentTransform.surfaceSpec(pic, 1).units, "px",
            "an image is pixels")
    end)

    t:case("a document that cannot answer", function()
        local _, no_method = DocumentTransform.surfaceSpec({}, 1)
        t:eq(no_method, "no_dimensions", "no getNativePageDimensions")
        local silent = reader{ native = false }.view.document
        local _, no_answer = DocumentTransform.surfaceSpec(silent, 1)
        t:eq(no_answer, "no_dimensions", "the call answers nothing")
        local _, no_page = DocumentTransform.surfaceSpec(
            reader().view.document, nil)
        t:eq(no_page, "no_dimensions", "no page to ask about")
    end)

    t:case("a page with no size", function()
        local flat = reader{ native = { w = 0, h = 841.89 } }.view.document
        local _, reason = DocumentTransform.surfaceSpec(flat, 1)
        t:eq(reason, "bad_geometry", "a page of no width")
    end)

    t:case("a stored surface still describes this page, within a unit", function()
        local spec = { logical_w = 596, logical_h = 842 }
        t:check(DocumentTransform.geometryMatches(
            { logical_w = 596, logical_h = 842 }, spec), "the same page")
        t:check(DocumentTransform.geometryMatches(
            { logical_w = 597, logical_h = 841 }, spec), "off by one, either way")
        t:check(not DocumentTransform.geometryMatches(
            { logical_w = 598, logical_h = 842 }, spec), "off by two in width")
        t:check(not DocumentTransform.geometryMatches(
            { logical_w = 596, logical_h = 840 }, spec), "off by two in height")
        t:check(not DocumentTransform.geometryMatches(nil, spec), "no surface")
        t:check(not DocumentTransform.geometryMatches({ logical_w = 596 }, spec),
            "half a surface")
    end)
end
