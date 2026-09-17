--[[--
Physical layout helpers for the standalone notebook editor.

A notebook page is born with the shape of the paper under the header, in
millimetres at the density of the screen it was made on (`screenPage`), and
keeps those logical dimensions for life. Screen rotation only changes the
chrome and the rectangle into which that page is fitted.

Handedness changes nothing any more. Every persistent control sits in one row
above the paper, where neither writing hand rests; a side rail was always in
the way of one of them, and its lower half sat under the heel of both. A stored
`rail_side` is accepted and ignored, so old settings stay valid.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local Size = require("ui/size")

local Layout = {}

Layout.LOGICAL_UNITS_PER_MM = 8

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function rounded(value)
    return math.floor(value + 0.5)
end

--[[--
KOReader's Button is asymmetric about the box it is handed.

`width` is the outer width: the frame subtracts its own chrome and gives the
label what is left, so the widget ends up exactly as wide as asked. `height` is
*not* the widget's height -- it is the label box, and the frame then adds
padding, border and margin around it (frontend/ui/widget/button.lua, identical
in v2026.07.1 and master). A column that budgets one row per
`Size.item.height_large` therefore spends `chrome` more per row than it planned,
and because a VerticalGroup stacks, the error accumulates downward: on a Kindle
Scribe the notebook library's footer sank 24px per notebook until, at seven, it
was off the bottom of the screen with no way to page or create.

These two helpers are the one place that difference is corrected, so callers can
keep thinking in outer boxes -- which is what a layout budget means. The
`margin = 0, padding = Size.padding.button` they assume is what both drawing
hosts pass; tests/conformance.lua measures a real Button and fails if the
arithmetic here stops describing it.
]]
Layout.BUTTON_MARGIN = 0

function Layout.buttonChrome()
    local padding = (Size.padding and Size.padding.button) or 0
    local border = (Size.border and Size.border.button) or 0
    return 2 * (padding + border + Layout.BUTTON_MARGIN)
end

--- The `height` to hand Button so the widget occupies `outer` pixels.
function Layout.buttonLabelHeight(outer)
    if not finite(outer) then return nil, "bad_geometry" end
    return math.max(1, rounded(outer) - Layout.buttonChrome())
end

function Layout.physicalPixels(mm, screen)
    screen = screen or Device.screen
    if not finite(mm) or mm <= 0 or not screen
        or type(screen.scaleByDPI) ~= "function" then
        return nil, "bad_geometry"
    end
    local pixels = screen:scaleByDPI(mm * 160 / 25.4)
    if not finite(pixels) or pixels <= 0 then return nil, "bad_geometry" end
    return math.max(1, rounded(pixels))
end

local function rect(x, y, w, h)
    return Geom:new{ x = rounded(x), y = rounded(y), w = rounded(w), h = rounded(h) }
end

local function fitPage(page_w, page_h, paper)
    if not finite(page_w) or not finite(page_h) or page_w <= 0 or page_h <= 0 then
        return nil, "bad_geometry"
    end
    local scale = math.min(paper.w / page_w, paper.h / page_h)
    if not finite(scale) or scale <= 0 then return nil, "no_viewport" end
    -- Rounded, not floored: a page shaped like the paper (Layout.screenPage)
    -- must land on the paper's edge, and flooring left a one-pixel strip on
    -- the limiting side. Rounding cannot overshoot the paper, because
    -- `scale` is the smaller of the two ratios, so each dimension is at most
    -- the paper's and rounding is monotonic over an integer bound.
    local w = math.max(1, rounded(page_w * scale))
    local h = math.max(1, rounded(page_h * scale))
    return rect(paper.x + math.floor((paper.w - w) / 2),
        paper.y + math.floor((paper.h - h) / 2), w, h)
end

--[[--
The rows above the paper, and the paper they leave, for one screen.

Shared by `compute` and `screenPage` so the shape a page is born with and the
rectangle that page is later fitted into come from one arithmetic rather than
two that can drift apart. The sharing is of the code, not of the inputs: hand
the two functions different `screen`, `screen_w/h` or `text_height` and they
will still describe different papers, so a caller that overrides any of them
must override it for both.
]]
local function chrome(opts, screen)
    local screen_w = tonumber(opts.screen_w) or (screen and screen:getWidth())
    local screen_h = tonumber(opts.screen_h) or (screen and screen:getHeight())
    if not finite(screen_w) or not finite(screen_h) or screen_w <= 0 or screen_h <= 0 then
        return nil, "no_viewport"
    end

    local target = Layout.physicalPixels(10, screen)
    local info_physical = Layout.physicalPixels(7, screen)
    local gap = Layout.physicalPixels(2, screen)
    if not target or not info_physical or not gap then return nil, "bad_geometry" end
    local padding = (Size.padding and (Size.padding.default or Size.padding.small)) or 0
    local target_floor = Size.item and Size.item.height_large or target
    target = math.max(target, target_floor or 0)
    local text_h = tonumber(opts.text_height) or target_floor or target
    local info_h = math.max(info_physical, text_h + 2 * padding)
    gap = math.max(gap, Size.span and Size.span.vertical_default or 0)

    local paper_w = screen_w
    local paper_h = screen_h - info_h - target - gap
    -- Eight controls retain the existing physical hit-target floor.
    if screen_w < target * 8 or paper_h < target * 3 then
        return nil, "no_viewport"
    end
    return {
        screen_w = screen_w, screen_h = screen_h,
        info_h = info_h, target = target, gap = gap,
        paper = rect(0, info_h + target + gap, paper_w, paper_h),
    }
end

function Layout.compute(opts)
    opts = opts or {}
    local screen = opts.screen or Device.screen
    local measured, chrome_err = chrome(opts, screen)
    if not measured then return nil, chrome_err end
    local fit, fit_err = fitPage(tonumber(opts.logical_w), tonumber(opts.logical_h),
        measured.paper)
    if not fit then return nil, fit_err end
    local rail = rect(0, measured.info_h, measured.screen_w, measured.target)
    local info = rect(0, 0, measured.screen_w, measured.info_h)

    return {
        screen_rect = rect(0, 0, measured.screen_w, measured.screen_h),
        rail_rect = rail,
        info_rect = info,
        paper_rect = measured.paper,
        fit_rect = fit,
        clip_rect = fit:copy(),
        target_size = measured.target,
        rail_side = "top",
        gap = measured.gap,
    }
end

--[[--
The page a notebook made on this screen is born with.

A notebook page has a physical size -- its units are millimetres, eight to
one -- because the ruling is pitched in millimetres and the export renders it
at a real 300 dpi. But which size was the plugin's to choose, and no size from
a paper catalogue has the proportion of the area under the header, so every
page was fitted with a strip down each side that the pen could not use: 185 px
a side for A5 on a Kindle Scribe in portrait, 714 in landscape.

This is that area instead, converted to millimetres at this screen's density,
so on the screen it was made on the page fills the paper's width. It is what
the create dialog stores, and every later page of the notebook inherits it
(`Session:appendPage`). The header's height is therefore part of the shape:
changing the header is a decision rather than a layout detail (ADR-52), and
`tests/notebook_ui_spec.lua` and `tests/top_toolbar_native.lua` pin the
resulting sizes so it cannot happen quietly.

`screen:scaleByDPI(160)` is this screen's density in dots per inch: KOReader
defines `scaleByDPI(dp)` as `ceil(dp * dpi / 160)`, and the editor already
uses the same expression as its density fingerprint.
]]
function Layout.screenPage(opts)
    opts = opts or {}
    local screen = opts.screen or Device.screen
    if not screen or type(screen.scaleByDPI) ~= "function" then
        return nil, "bad_geometry"
    end
    local measured, chrome_err = chrome(opts, screen)
    if not measured then return nil, chrome_err end
    local dpi = screen:scaleByDPI(160)
    if not finite(dpi) or dpi <= 0 then return nil, "bad_geometry" end
    local units_per_px = Layout.LOGICAL_UNITS_PER_MM * 25.4 / dpi
    -- Shape only. The ruling is the create dialog's question, and a default
    -- returned from here would be a second opinion on it.
    return {
        logical_w = math.max(1, rounded(measured.paper.w * units_per_px)),
        logical_h = math.max(1, rounded(measured.paper.h * units_per_px)),
    }
end

return Layout
