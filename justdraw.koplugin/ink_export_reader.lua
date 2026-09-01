--[[--
The page the reader is looking at, plus the ink on it, and nothing else.

The tempting implementation is `view:paintTo(buffer)`. It is wrong on both
counts. What it *adds* is everything else the view owns -- saved and temporary
highlights, the page-overlap dim or arrow, the dogear, the footer, the flipping
indicator and every registered view module, JustDraw's own sheet marks
included -- none of which the reader asked to export. What it *does* is not
free either: it clears the dialog's dither flag, and the CREngine branch can
re-enter itself after `handlePartialRerendering` repositions.

So this renders the narrow thing instead: the same `document:drawPage` call
`ReaderView:drawSinglePage` makes, with the same state, minus the
`emitHintPageEvent` it schedules afterwards -- a hint for the *next* page's
cache, which is a side effect an export has no business causing.

That call is copied deliberately, argument for argument including
`state.saturation`, and `tests/conformance.lua` measures the real
`drawSinglePage` against it. If KOReader changes what it passes, the probe
fails on the next run rather than the export quietly rendering with a stale
gamma.

**Only fixed-layout, only page mode.** `ui.paging` with `page_scroll` off is
the combination where one screen is one page and the ink's screen coordinates
(ADR-5) mean exactly one thing. CREngine is excluded because a draw can turn
into a partial rerender that emits `PageUpdate`, which is observable to
statistics and sync and would make an export a write. Continuous modes are
excluded because a screen can hold parts of two pages, and the per-page ink
store has no way to say which stroke belongs to which.

The result is greyscale by default: the destination is a monochrome panel, the
PDF path is `/DeviceGray`, and a BB8 costs a quarter of what an RGB32 screen
buffer would while the page is held in memory.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")

local Raster = require("ink_export_raster")
local Render = require("ink_render")
local Style = require("ink_style")

local Reader = {}

local Screen = Device.screen
local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

--[[--
Whether this document and view mode can be exported at all.

Answers a reason rather than a boolean so the caller can say *why* the entry
is unavailable; "not supported" with no explanation is the thing that makes a
reader retry the same action.
]]
function Reader.supports(ui, view)
    if type(ui) ~= "table" or type(view) ~= "table" then return nil, "no_view" end
    if not ui.paging then return nil, "unsupported_document" end
    if view.page_scroll then return nil, "unsupported_mode" end
    if type(view.document) ~= "table"
        or type(view.document.drawPage) ~= "function" then
        return nil, "no_view"
    end
    local state = view.state
    if type(state) ~= "table" or not finite(tonumber(state.page))
        or type(state.offset) ~= "table" then
        return nil, "no_view"
    end
    if type(view.visible_area) ~= "table" or type(view.dimen) ~= "table" then
        return nil, "no_view"
    end
    local w, h = tonumber(view.dimen.w), tonumber(view.dimen.h)
    if not finite(w) or not finite(h) or w < 1 or h < 1 then
        return nil, "bad_geometry"
    end
    if floor(w) * floor(h) > Raster.MAX_PIXELS then return nil, "too_large" end
    return true
end

--[[--
  opts.ui, opts.view   the live reader
  opts.strokes         this page's direct ink, in screen coordinates
  opts.ink             stroke colour
  opts.dpi             nominal DPI for the physical page size
  opts.buffer_type     defaults to BB8

Returns `{ bb, width_pt, height_pt, release }`. The caller owns the buffer
until it calls `release`, which is the only thing that frees it.
]]
function Reader.render(opts)
    opts = opts or {}
    local ui, view = opts.ui, opts.view
    local supported, reason = Reader.supports(ui, view)
    if not supported then return nil, reason end

    local w = floor(tonumber(view.dimen.w))
    local h = floor(tonumber(view.dimen.h))
    local dpi = tonumber(opts.dpi) or Raster.NOMINAL_DPI

    -- A colour is cdata whose `__eq` indexes its argument, so `c == nil`
    -- raises under LuaJIT. Every nil check on one of these is a rawequal.
    local background = opts.background
    if rawequal(background, nil) then background = view.outer_page_color end
    if rawequal(background, nil) then background = Blitbuffer.COLOR_WHITE end
    local ink = opts.ink
    if rawequal(ink, nil) then ink = Blitbuffer.COLOR_BLACK end

    -- `Blitbuffer.new` asserts rather than answering nil when calloc fails
    -- (koreader-base blitbuffer.lua), so there is no nil branch to write; the
    -- raise is caught by the export job's guarded transition and reported.
    local buffer_type = opts.buffer_type or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(w, h, buffer_type)
    local function release()
        if bb then
            bb:free()
            bb = nil
        end
    end
    bb:fill(background)

    local state = view.state
    --[[--
    Exactly ReaderView:drawSinglePage, minus the hint event. The origin is this
    buffer's own, so the view's paint x/y are zero here and only the page
    offset remains.

    Night mode is suspended across the call. `KoptInterface:drawPage` inverts
    the page when `nightmode_document` is set and `Screen.night_mode` is on,
    and it is right to do that for a screen the reader is looking at in the
    dark -- but an exported file is looked at somewhere else, and a white-on-
    black page would also swallow the ink, which is painted black afterwards.
    The flag is restored on every path, including a raise.
    ]]
    local night = Screen.night_mode
    if night then Screen.night_mode = false end
    local drawn, draw_err = pcall(view.document.drawPage, view.document, bb,
        state.offset.x, state.offset.y,
        view.visible_area, state.page, state.zoom,
        state.rotation, state.gamma, state.saturation)
    if night then Screen.night_mode = night end
    if not drawn then
        release()
        return nil, "render_failed", draw_err
    end

    -- Direct ink is stored in absolute screen pixels, so it is shifted by the
    -- view's own origin -- zero on a full-screen reader, and not assumed to be.
    local origin_x = tonumber(view.dimen.x) or 0
    local origin_y = tonumber(view.dimen.y) or 0
    local strokes = opts.strokes
    if type(strokes) == "table" then
        for i = 1, #strokes do
            Render.stroke(bb, strokes[i], -origin_x, -origin_y,
                Style.colorFor(strokes[i].t, ink))
        end
    end

    return {
        bb = bb,
        width_pt = Raster.nominalPoints(w, dpi),
        height_pt = Raster.nominalPoints(h, dpi),
        release = release,
    }
end

return Reader
