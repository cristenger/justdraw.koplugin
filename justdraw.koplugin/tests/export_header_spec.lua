--[[--
The band over every exported note, and the two things it must not cost.

A dossier of forty pages on white is unreadable without saying what each page
is; the band is the whole of that answer, and it is rendered into the raster
because the PDF this project writes has no text objects to put it in (ADR-31).

Two properties are stated here rather than trusted. The first is memory: the
ink raster is released *before* the band is painted, so the peak of a compose
is two buffers for one blit and never three. The second is the budget: it is
the composed page -- content plus band -- that gets allocated and encoded, so
the 8 Mpx cap has to be measured on that, not on the content that came in.

`paint_text` is injected. `TextWidget` does not exist in the suite and
`Font:getFace` scales by the device's screen, so a fake here would be a fake of
KOReader's text layout: what is stubbed is a recorder that answers a height,
and every claim about the real widget is in tests/conformance.lua.
]]

return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Header = require("ink_export_header")
    local Raster = require("ink_export_raster")

    --[[--
    A `paint_text` that records rather than paints.

    It is not a TextWidget and does not pretend to be one: it answers a height
    and remembers what it was asked to write, which is the whole of what
    `compose` depends on.
    ]]
    local function recorder(events, height)
        local rec = { calls = {} }
        rec.paint = function(bb, x, y, text, max_width)
            rec.calls[#rec.calls + 1] = { bb = bb, x = x, y = y,
                text = text, max_width = max_width }
            events[#events + 1] = "paint"
            return height or 60
        end
        return rec
    end

    --- One rendered note, as the surface renderer hands it over.
    local function inkResult(events, w, h)
        local bb = support.newBlitbuffer(w or 400, h or 300)
        return {
            bb = bb,
            width_pt = 100,
            height_pt = 200,
            release = function()
                events[#events + 1] = "release"
                bb:free()
            end,
        }, bb
    end

    local function separatorOf(bb)
        for i = 1, #bb.rects do
            local r = bb.rects[i]
            if r.h == 1 and r.y == Header.BAND_PX - 1 then return r end
        end
        return nil
    end

    -- =================================================================
    t:describe("export / header / the band")

    t:case("the band is reserved above the note, which is blitted below it", function()
        local events = {}
        local result, ink = inkResult(events, 400, 300)
        local rec = recorder(events)
        local composed, err = Header.compose{
            result = result, title = "Moby Dick", kind_label = "Page note",
            location_label = "Page 12", paint_text = rec.paint,
        }
        t:check(composed ~= nil, "composed: " .. tostring(err))
        t:eq(composed.bb:getWidth(), 400, "the note's width")
        t:eq(composed.bb:getHeight(), 300 + Header.BAND_PX,
            "and its height plus the band")
        t:eq(composed.bb.fills[1], "white", "the whole page starts white")
        local blit = composed.bb.blits[1]
        t:check(blit ~= nil, "the note was blitted")
        t:check(rawequal(blit.src, ink), "out of the raster that was rendered")
        t:eq(blit.dest_x, 0, "at the left edge")
        t:eq(blit.dest_y, Header.BAND_PX, "below the band")
        t:eq(blit.h, 300, "whole")
    end)

    t:case("10 mm at 300 dpi, and the same 10 mm on the page", function()
        t:eq(Header.BAND_PX, 118, "the band in pixels")
        t:eq(Header.PAD_PX, 47, "and the margin its text keeps")
        t:check(math.abs(Header.BAND_PT - 10 / 25.4 * 72) < 1e-9,
            "the band in points")
        local events = {}
        local composed = Header.compose{
            result = (inkResult(events)), title = "T", kind_label = "K",
            location_label = "L", paint_text = recorder(events).paint,
        }
        t:eq(composed.width_pt, 100, "the note's own width in points")
        t:check(math.abs(composed.height_pt - (200 + Header.BAND_PT)) < 1e-9,
            "and its height plus the band's")
    end)

    t:case("a separator sits on the band's last row", function()
        local events = {}
        local composed = Header.compose{
            result = (inkResult(events, 400, 300)), title = "T",
            kind_label = "K", location_label = "L",
            paint_text = recorder(events).paint,
        }
        local rule = separatorOf(composed.bb)
        t:check(rule ~= nil, "there is a one-pixel rule")
        t:eq(rule.w, 400, "across the page")
        t:eq(rule.c, "gray", "in gray, so it reads as a rule and not as ink")
    end)

    t:case("the ink raster is released before the band is painted", function()
        -- The whole reason the band is composed in this order: two buffers
        -- for one blit, never three for the encode.
        local events = {}
        local rec = recorder(events)
        Header.compose{
            result = (inkResult(events)), title = "T", kind_label = "K",
            location_label = "L", paint_text = rec.paint,
        }
        t:eq(table.concat(events, " "), "release paint",
            "released, then painted")
    end)

    t:case("the line says what this page is and where it came from", function()
        local events = {}
        local rec = recorder(events)
        local composed = Header.compose{
            result = (inkResult(events, 400, 300)), title = "Moby Dick",
            kind_label = "Legacy ink", location_label = "Stored page 12",
            paint_text = rec.paint,
        }
        t:eq(#rec.calls, 1, "one line")
        t:eq(rec.calls[1].text, "Moby Dick · Legacy ink · Stored page 12",
            "title, kind, location")
        t:eq(rec.calls[1].x, Header.PAD_PX, "inside the margin")
        t:eq(rec.calls[1].max_width, 400 - 2 * Header.PAD_PX,
            "and bounded by the other one")
        t:check(rec.calls[1].y >= 0
            and rec.calls[1].y + 60 <= Header.BAND_PX,
            "sitting inside the band")
        t:check(rawequal(rec.calls[1].bb, composed.bb),
            "painted into the composed page")
    end)

    t:case("an over-long title reaches the painter whole", function()
        -- Truncation is the painter's, because only the painter knows how wide
        -- the glyphs are. Cutting the string here would cut it in the wrong
        -- place and produce an ellipsis the widget would then add again.
        local events = {}
        local rec = recorder(events)
        local long = string.rep("Bartleby ", 60)
        Header.compose{
            result = (inkResult(events, 400, 300)), title = long,
            kind_label = "Page note", location_label = "Page 1",
            paint_text = rec.paint,
        }
        t:check(rec.calls[1].text:find(long, 1, true) == 1,
            "the whole title, unshortened")
    end)

    t:case("a painter that fails costs the line, not the page", function()
        local events = {}
        local result, ink = inkResult(events, 400, 300)
        local composed = Header.compose{
            result = result, title = "T", kind_label = "K",
            location_label = "L",
            paint_text = function() error("no font", 0) end,
        }
        t:check(composed ~= nil, "the note still comes back")
        t:eq(composed.bb:getHeight(), 300 + Header.BAND_PX, "with its band")
        t:eq(ink.freed, true, "and the ink raster was still released")
        composed.release()
    end)

    t:case("a result with no raster is refused, and stays the caller's", function()
        local events = {}
        local composed, err = Header.compose{
            result = { width_pt = 10, height_pt = 10 },
            title = "T", kind_label = "K", location_label = "L",
            paint_text = recorder(events).paint,
        }
        t:check(composed == nil, "refused")
        t:eq(err, "bad_raster", "with a reason")
        t:eq(#events, 0, "and nothing was released behind the caller's back")
    end)

    t:case("releasing the composed page frees it, once or twice", function()
        local events = {}
        local composed = Header.compose{
            result = (inkResult(events)), title = "T", kind_label = "K",
            location_label = "L", paint_text = recorder(events).paint,
        }
        local bb = composed.bb
        composed.release()
        t:eq(bb.freed, true, "freed")
        composed.release()
        t:eq(bb.freed, true, "and a second release is harmless")
    end)

    -- =================================================================
    t:describe("export / header / the budget the band shares")

    t:case("the budget is measured on the page the band made", function()
        -- 2000 x 4000 is exactly the budget at 1:1 -- and 2000 x 4118 is not.
        t:eq(Raster.boundedScale(2000, 4000, 1), 1,
            "the content alone fits at one to one")
        local scale, err = Header.budgetedScale(2000, 4000, 1)
        t:check(scale ~= nil, "bounded: " .. tostring(err))
        t:check(scale < 1, "so the band is what reduced it")
        local w = math.floor(2000 * scale + 0.5)
        local h = math.floor(4000 * scale + 0.5)
        t:check(w * (h + Header.BAND_PX) <= Raster.MAX_PIXELS,
            "and the composed page is inside the budget")
    end)

    t:case("a page with room to spare keeps the scale it asked for", function()
        t:eq(Header.budgetedScale(1000, 1000, 1), 1, "nothing to reduce")
        local target = Raster.physicalScale(8, Raster.TARGET_DPI)
        t:eq(Header.budgetedScale(1184, 1680, target), target,
            "an A5 notebook page is untouched by the band")
    end)

    t:case("a page with no size is refused rather than guessed", function()
        t:eq(select(2, Header.budgetedScale(0, 100, 1)), "bad_geometry",
            "no width")
        t:eq(select(2, Header.budgetedScale(100, 100, 0)), "bad_geometry",
            "no scale")
    end)

    t:case("the band's own pixels are counted the way they are allocated", function()
        -- The forecast has to add the same rows the compose reserves, rounded
        -- the same way, or it describes a different page than the one written.
        t:eq(Header.bandPixels(1000, 0.5), 500 * Header.BAND_PX,
            "the width at the scale, times the band")
        local pixels, w, h = Header.composedPixels(1000, 2000, 0.5)
        t:eq(w, 500, "the rounded width")
        t:eq(h, 1000 + Header.BAND_PX, "the rounded height plus the band")
        t:eq(pixels, 500 * (1000 + Header.BAND_PX), "and their product")
    end)
end
