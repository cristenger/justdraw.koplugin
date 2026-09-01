--[[--
Exporting the page in front of the reader, and everything that must not
happen while it is exported.

The claims split in two. What the render *contains* -- the document's own
pixels and JustDraw's ink, in that order, and nothing the view adds on top --
and what the render *costs*: it must be a read. `ReaderView:paintTo` fails the
second test as much as the first, because the highlights and the footer come
with a scheduled hint event and a dithering flag, and an export that turns
into a page-turn observable to statistics and sync is not an export.

So the argument list handed to `document:drawPage` is pinned here, argument by
argument, `state.saturation` included. Getting that list wrong is not a crash;
it is a page rendered at the wrong gamma or zoom, which looks like a bad
export rather than a bug. `tests/conformance.lua` states the other half --
that this list is still what KOReader's own `drawSinglePage` passes.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local env = ctx.env
    local Reader = require("ink_export_reader")
    local Raster = require("ink_export_raster")

    --- A reader that records what was asked of it and paints something
    --- identifiable, so ordering is observable in the buffer itself.
    local function newReader(opts)
        opts = opts or {}
        local log = { draws = {}, events = {}, hints = 0 }
        local document = {
            drawPage = function(_, bb, ...)
                local args = { ... }
                log.draws[#log.draws + 1] = {
                    bb = bb, argc = select("#", ...),
                    x = args[1], y = args[2], rect = args[3], page = args[4],
                    zoom = args[5], rotation = args[6], gamma = args[7],
                    saturation = args[8],
                }
                if opts.draw_raises then error("mupdf said no") end
                bb:paintRect(0, 0, 4, 4, "page")
            end,
        }
        local view = {
            document = document,
            page_scroll = opts.page_scroll,
            dimen = opts.dimen or { x = 0, y = 0, w = 60, h = 80 },
            visible_area = { x = 3, y = 7, w = 50, h = 70 },
            outer_page_color = opts.outer_page_color,
            state = {
                page = 12, zoom = 1.25, rotation = 90, gamma = 1.5,
                saturation = 0.75, offset = { x = 5, y = 9 },
            },
            handleEvent = function(_, event)
                log.events[#log.events + 1] = event
                return false
            end,
        }
        local ui = {
            paging = opts.paging ~= false,
            rolling = opts.rolling,
            handleEvent = function(_, event)
                log.events[#log.events + 1] = event
                return false
            end,
        }
        return ui, view, log
    end

    local function bar(x, y)
        return { n = 2, w = 4, x, y, x + 20, y }
    end

    -- =================================================================
    t:describe("export / reader / what can be exported")

    t:case("a fixed-layout page in page mode is exportable", function()
        local ui, view = newReader()
        t:check(Reader.supports(ui, view), "supported")
    end)

    t:case("a CREngine document is refused, and says so", function()
        local ui, view = newReader{ paging = false, rolling = true }
        local ok, reason = Reader.supports(ui, view)
        t:check(not ok, "refused")
        t:eq(reason, "unsupported_document",
            "the reason distinguishes the document from the mode")
    end)

    t:case("a continuous mode is refused separately", function()
        local ui, view = newReader{ page_scroll = true }
        local ok, reason = Reader.supports(ui, view)
        t:check(not ok, "refused")
        t:eq(reason, "unsupported_mode", "reason")
    end)

    t:case("a page larger than the budget is refused before allocating it", function()
        local ui, view = newReader{ dimen = { x = 0, y = 0, w = 4000, h = 4000 } }
        t:eq(select(2, Reader.supports(ui, view)), "too_large", "16 Mpx is refused")
        local result, reason = Reader.render{ ui = ui, view = view }
        t:check(result == nil, "and no buffer was made")
        t:eq(reason, "too_large", "with the same reason")
    end)

    t:case("a view that is missing its state is refused rather than indexed", function()
        local ui, view = newReader()
        view.state = nil
        t:eq(select(2, Reader.supports(ui, view)), "no_view", "no state")
        local ui2, view2 = newReader()
        view2.visible_area = nil
        t:eq(select(2, Reader.supports(ui2, view2)), "no_view", "no visible area")
        local ui3, view3 = newReader{ dimen = { x = 0, y = 0, w = 0, h = 10 } }
        t:eq(select(2, Reader.supports(ui3, view3)), "bad_geometry", "zero width")
    end)

    -- =================================================================
    t:describe("export / reader / the render is a read")

    t:case("the document is drawn with exactly the state the view holds", function()
        local ui, view, log = newReader()
        local result = Reader.render{ ui = ui, view = view }
        t:check(result ~= nil, "rendered")
        t:eq(#log.draws, 1, "drawn once")
        local call = log.draws[1]
        t:eq(call.argc, 8, "every argument after the buffer is passed")
        t:eq(call.x, 5, "the page offset, not the view's screen position")
        t:eq(call.y, 9, "offset y")
        t:eq(call.rect, view.visible_area, "the visible area")
        t:eq(call.page, 12, "the current page")
        t:eq(call.zoom, 1.25, "zoom")
        t:eq(call.rotation, 90, "rotation")
        t:eq(call.gamma, 1.5, "gamma")
        t:eq(call.saturation, 0.75,
            "saturation, which KOReader added and a stale copy would drop")
        result.release()
    end)

    t:case("nothing is scheduled and no event is sent", function()
        local ui, view, log = newReader()
        local queued = #env.UIManager._queue
        local result = Reader.render{ ui = ui, view = view }
        t:eq(#log.events, 0, "no event reached the reader")
        t:eq(#env.UIManager._queue, queued,
            "and nothing was scheduled -- no hint, no page turn")
        result.release()
    end)

    t:case("the buffer is the view, and the ink goes on after the page", function()
        local ui, view = newReader()
        local result = Reader.render{ ui = ui, view = view,
            strokes = { bar(10, 10) } }
        local bb = result.bb
        t:eq(bb:getWidth(), 60, "width")
        t:eq(bb:getHeight(), 80, "height")
        t:eq(bb.rects[1].c, "white", "the background is cleared first")
        t:eq(bb.rects[2].c, "page", "then the document's own pixels")
        t:check(#bb.rects > 2, "and then the ink")
        t:eq(bb.rects[3].c, "black", "which is drawn in the ink colour")
        result.release()
    end)

    t:case("a stroke's style picks its color in the export", function()
        local ui, view = newReader()
        local result = Reader.render{ ui = ui, view = view,
            strokes = { { n = 2, w = 4, t = 65, 10, 10, 30, 10 } } }
        t:eq(result.bb.rects[3].c, "gray_6", "graphite renders gray in the export")
        result.release()
    end)

    t:case("a page with no ink still exports its content", function()
        local ui, view = newReader()
        local result = Reader.render{ ui = ui, view = view, strokes = {} }
        t:eq(#result.bb.rects, 2, "background and page, nothing else")
        result.release()
    end)

    t:case("ink is shifted by the view's own origin, not assumed to be at zero", function()
        local ui, view = newReader{ dimen = { x = 10, y = 20, w = 60, h = 80 } }
        local result = Reader.render{ ui = ui, view = view,
            strokes = { bar(30, 40) } }
        -- A stroke at screen (30,40) is at (20,20) inside a view whose origin
        -- is (10,20); the nib is four wide, so its box starts two before that.
        t:eq(result.bb.rects[3].x, 18, "x is relative to the view")
        t:eq(result.bb.rects[3].y, 18, "and so is y")
        result.release()
    end)

    t:case("night mode does not invert the exported page", function()
        local Device = require("device")
        local Screen = Device.screen
        local ui, view = newReader()
        local seen_night
        view.document.drawPage = function(_, bb)
            seen_night = Screen.night_mode
            bb:paintRect(0, 0, 4, 4, "page")
        end
        Screen.night_mode = true
        local result = Reader.render{ ui = ui, view = view }
        -- KoptInterface:drawPage inverts the page when night mode is on. That
        -- is right for a screen being read in the dark and wrong for a file
        -- looked at somewhere else -- and a white-on-black page would swallow
        -- the ink, which is painted black afterwards.
        t:eq(seen_night, false, "the page was drawn with night mode off")
        t:eq(Screen.night_mode, true, "and the reader's own setting restored")
        result.release()
        Screen.night_mode = nil
    end)

    t:case("night mode is restored even when the draw raises", function()
        local Device = require("device")
        local Screen = Device.screen
        local ui, view = newReader{ draw_raises = true }
        Screen.night_mode = true
        Reader.render{ ui = ui, view = view }
        t:eq(Screen.night_mode, true, "restored on the failure path too")
        Screen.night_mode = nil
    end)

    t:case("the page size uses the documented nominal resolution", function()
        local ui, view = newReader()
        local result = Reader.render{ ui = ui, view = view }
        t:check(math.abs(result.width_pt - 60 * 72 / Raster.NOMINAL_DPI) < 1e-9,
            "width in points")
        t:check(math.abs(result.height_pt - 80 * 72 / Raster.NOMINAL_DPI) < 1e-9,
            "height in points")
        result.release()
    end)

    -- =================================================================
    t:describe("export / reader / buffers are released")

    t:case("release frees the buffer and is idempotent", function()
        local ui, view = newReader()
        local result = Reader.render{ ui = ui, view = view }
        local bb = result.bb
        t:eq(bb.freed, false, "held while the caller has it")
        result.release()
        t:eq(bb.freed, true, "freed on release")
        result.release()
        t:check(true, "a second release does not raise")
    end)

    t:case("a document that raises mid-draw leaves no buffer behind", function()
        local ui, view, log = newReader{ draw_raises = true }
        local result, reason = Reader.render{ ui = ui, view = view }
        t:check(result == nil, "no result")
        t:eq(reason, "render_failed", "reason")
        t:eq(#log.draws, 1, "the draw was attempted")
        t:eq(log.draws[1].bb.freed, true, "and its buffer was freed")
    end)
end
