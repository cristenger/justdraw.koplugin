--[[--
Physical layout helpers for the standalone notebook editor.

The notebook page keeps its logical dimensions. Screen rotation and handedness
only change the chrome and the rectangle into which that page is fitted.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local Size = require("ui/size")

local Layout = {}

Layout.LOGICAL_UNITS_PER_MM = 8
Layout.PRESETS = {
    a5_portrait = {
        title = "A5 portrait", logical_w = 1184, logical_h = 1680,
        template_kind = "blank",
    },
    letter_portrait = {
        title = "Letter portrait", logical_w = 1727, logical_h = 2235,
        template_kind = "blank",
    },
    a5_landscape = {
        title = "A5 landscape", logical_w = 1680, logical_h = 1184,
        template_kind = "blank",
    },
}

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

function Layout.preset(name)
    local value = Layout.PRESETS[name]
    if not value then return nil, "bad_geometry" end
    return {
        title = value.title,
        logical_w = value.logical_w,
        logical_h = value.logical_h,
        template_kind = value.template_kind,
    }
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
    local w = math.max(1, math.floor(page_w * scale))
    local h = math.max(1, math.floor(page_h * scale))
    return rect(paper.x + math.floor((paper.w - w) / 2),
        paper.y + math.floor((paper.h - h) / 2), w, h)
end

function Layout.compute(opts)
    opts = opts or {}
    local screen = opts.screen or Device.screen
    local screen_w = tonumber(opts.screen_w) or (screen and screen:getWidth())
    local screen_h = tonumber(opts.screen_h) or (screen and screen:getHeight())
    local page_w = tonumber(opts.logical_w)
    local page_h = tonumber(opts.logical_h)
    local side = opts.rail_side == "left" and "left" or "right"
    if not finite(screen_w) or not finite(screen_h) or screen_w <= 0 or screen_h <= 0 then
        return nil, "no_viewport"
    end

    local target = Layout.physicalPixels(10, screen)
    local rail_physical = Layout.physicalPixels(14, screen)
    local info_physical = Layout.physicalPixels(7, screen)
    local gap = Layout.physicalPixels(2, screen)
    if not target or not rail_physical or not info_physical or not gap then
        return nil, "bad_geometry"
    end
    local padding = (Size.padding and (Size.padding.default or Size.padding.small)) or 0
    local target_floor = Size.item and Size.item.height_large or target
    target = math.max(target, target_floor or 0)
    local rail_w = math.max(rail_physical, target + 2 * padding)
    local text_h = tonumber(opts.text_height) or target_floor or target
    local info_h = math.max(info_physical, text_h + 2 * padding)
    gap = math.max(gap, Size.span and Size.span.vertical_default or 0)

    local paper_w = screen_w - rail_w - gap
    local paper_h = screen_h - info_h - gap
    -- Eight rail controls need two groups with a usable gap. The error band
    -- also needs room for two two-target controls plus readable copy.
    if screen_h < target * 9 or paper_w < target * 5 or paper_h < target then
        return nil, "no_viewport"
    end

    local rail_x = side == "left" and 0 or screen_w - rail_w
    local content_x = side == "left" and rail_w + gap or 0
    local paper = rect(content_x, info_h + gap, paper_w, paper_h)
    local fit, fit_err = fitPage(page_w, page_h, paper)
    if not fit then return nil, fit_err end
    local rail = rect(rail_x, 0, rail_w, screen_h)
    local info = rect(content_x, 0, paper_w, info_h)

    return {
        screen_rect = rect(0, 0, screen_w, screen_h),
        rail_rect = rail,
        info_rect = info,
        paper_rect = paper,
        fit_rect = fit,
        clip_rect = fit:copy(),
        target_size = target,
        rail_side = side,
        gap = gap,
    }
end

return Layout
