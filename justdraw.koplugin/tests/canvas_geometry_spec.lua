--[[--
The two pure pieces of the canvas's geometry: the coordinate transform every
other part shares, and the spatial index that keeps erasing and repainting
proportional to what is nearby rather than to the whole canvas.

The transform is the reason there is no second copy of these formulas in the
widget or in main.lua. Its round trip is the property that matters: a point
that goes out to the screen and comes back has to land where it started, in
every rotation and at every sheet height, or ink drifts away from the pen.
]]

return function(ctx)
    local t = ctx.t
    local Transform = require("ink_canvas_transform")
    local Grid = require("ink_spatial_grid")

    local SCRIBE_W, SCRIBE_H = 1860, 2480

    local function portrait(sheet_top)
        return Transform.new{
            logical_w = SCRIBE_W, logical_h = SCRIBE_H,
            screen_w = SCRIBE_W, screen_h = SCRIBE_H,
            sheet_top = sheet_top or 0,
        }
    end

    local function landscape(sheet_top)
        return Transform.new{
            logical_w = SCRIBE_W, logical_h = SCRIBE_H,
            screen_w = SCRIBE_H, screen_h = SCRIBE_W,   -- rotated
            sheet_top = sheet_top or 0,
        }
    end

    local function roundTrips(tr, cx, cy)
        local sx, sy = tr:toScreen(cx, cy)
        local bx, by = tr:toCanvas(sx, sy)
        return math.abs(bx - cx) < 1e-6 and math.abs(by - cy) < 1e-6
    end

    -- =================================================================
    t:describe("ink_canvas_transform / round trip")

    t:case("a point survives the trip in portrait", function()
        local tr = portrait()
        t:check(roundTrips(tr, 0, 0), "origin")
        t:check(roundTrips(tr, 930, 1240), "centre")
        t:check(roundTrips(tr, SCRIBE_W, SCRIBE_H), "far corner")
    end)

    t:case("a point survives the trip in landscape, letterboxing and all", function()
        local tr = landscape()
        t:check(roundTrips(tr, 0, 0), "origin")
        t:check(roundTrips(tr, 930, 1240), "centre")
        t:check(roundTrips(tr, SCRIBE_W, SCRIBE_H), "far corner")
    end)

    t:case("a point survives the trip with the sheet part-way up", function()
        local tr = portrait(math.floor(SCRIBE_H * 0.6))
        t:check(roundTrips(tr, 0, 0), "origin")
        t:check(roundTrips(tr, 400, 700), "somewhere in the middle")
    end)

    -- =================================================================
    t:describe("ink_canvas_transform / fitting")

    t:case("the whole canvas fits, and is never magnified past fitting", function()
        for _, tr in ipairs({ portrait(), landscape() }) do
            t:check(tr.draw_w <= tr.screen_w + 1e-9, "width fits")
            t:check(tr.draw_h <= tr.screen_h + 1e-9, "height fits")
        end
    end)

    t:case("a canvas the shape of the screen uses the whole width", function()
        local tr = portrait()
        t:eq(tr.offset_x, 0, "no side margin")
        t:check(math.abs(tr.draw_w - SCRIBE_W) < 1e-9, "full width")
    end)

    t:case("a rotated screen letterboxes the sides rather than distorting", function()
        local tr = landscape()
        t:check(tr.offset_x > 0, "there is a margin")
        t:check(math.abs(tr.draw_w / tr.draw_h - SCRIBE_W / SCRIBE_H) < 1e-9,
            "and the aspect ratio is untouched")
    end)

    t:case("the canvas is aligned to the top of the sheet, not centred in it", function()
        -- The sheet reveals the canvas downwards, so the first thing to appear
        -- has to be the top of the page.
        local tr = portrait(1000)
        local _, sy = tr:toScreen(0, 0)
        t:eq(sy, 1000, "canvas row zero sits at the top edge of the sheet")
    end)

    t:case("stroke width scales with the canvas", function()
        local tr = landscape()
        t:check(tr:scaleWidth(10) < 10, "a shrunken canvas draws thinner")
        t:check(tr:scaleWidth(1) >= 1, "but never thinner than a pixel")
    end)

    -- =================================================================
    t:describe("ink_canvas_transform / the raster cache's coordinates")

    t:case("cache coordinates do not move when the sheet does", function()
        local low, high = portrait(1500), portrait(0)
        local ax, ay = low:toCache(100, 200)
        local bx, by = high:toCache(100, 200)
        t:eq(ax, bx, "x is the same")
        t:eq(ay, by, "y is the same -- dragging the sheet re-rasterises nothing")
    end)

    t:case("a cache point lands on screen where the canvas point does", function()
        local tr = landscape(300)
        local kx, ky = tr:toCache(500, 700)
        local sx, sy = tr:fromCache(kx, ky)
        local wx, wy = tr:toScreen(500, 700)
        t:check(math.abs(sx - wx) < 1e-9, "x agrees")
        t:check(math.abs(sy - wy) < 1e-9, "y agrees")
    end)

    t:case("the cache is the size of the whole transformed canvas", function()
        local tr = portrait(1500)
        local w, h = tr:cacheSize()
        t:eq(w, math.floor(tr.draw_w + 0.5), "full width")
        t:eq(h, math.floor(tr.draw_h + 0.5), "full height, not the sheet's")
    end)

    -- =================================================================
    t:describe("ink_canvas_transform / what counts as canvas")

    t:case("a point in the side margin is not on the canvas", function()
        local tr = landscape()
        t:eq(tr:contains(1, 100), false, "left margin")
        t:eq(tr:contains(tr.screen_w - 1, 100), false, "right margin")
        t:eq(tr:contains(tr.offset_x + 10, 100), true, "and just inside is")
    end)

    t:case("a point above the sheet is not on the canvas", function()
        local tr = portrait(1000)
        t:eq(tr:contains(500, 999), false, "above the sheet")
        t:eq(tr:contains(500, 1001), true, "and just below the edge is")
    end)

    t:case("contains answers the canvas rectangle, without building one", function()
        --[[--
        `contains` is asked once per accepted pen sample, so it computes the
        rectangle's four edges rather than allocating one -- which is only
        safe while the two round the same way. Every boundary of several
        shapes is checked from both sides, including a fixed page's transform,
        whose fit rectangle is the page at zoom rather than the screen.
        ]]
        local shapes = {
            landscape(), portrait(), portrait(1000),
            Transform.new{
                logical_w = 596, logical_h = 842,
                fit_rect = { x = 17, y = 9, w = 298, h = 421 },
                clip_rect = { x = 0, y = 0, w = 600, h = 800 },
                align_x = "left", align_y = "top",
            },
            Transform.new{
                logical_w = 596, logical_h = 842,
                fit_rect = { x = -40, y = -30, w = 894, h = 1263 },
                clip_rect = { x = 0, y = 0, w = 600, h = 800 },
                align_x = "left", align_y = "top",
            },
            -- A width whose fraction rounds *up*: MuPDF measures pages in
            -- points and does not round, so this is the ordinary case on a
            -- PDF and the one where truncating instead of rounding would put
            -- the last column of the page outside the canvas.
            Transform.new{
                logical_w = 596, logical_h = 842,
                fit_rect = { x = 0, y = 0, w = 298.7, h = 900 },
                clip_rect = { x = 0, y = 0, w = 600, h = 800 },
                align_x = "left", align_y = "top",
            },
            -- The same, panned by a fraction, so both edges round.
            Transform.new{
                logical_w = 596, logical_h = 842,
                fit_rect = { x = -20.6, y = -12.7, w = 641.9, h = 900 },
                clip_rect = { x = 0, y = 0, w = 600, h = 800 },
                align_x = "left", align_y = "top",
            },
        }
        for i = 1, #shapes do
            local tr = shapes[i]
            local r = tr:canvasRect()
            local label = " (shape " .. i .. ")"
            t:eq(tr:contains(r.x, r.y), true, "the top-left corner is in" .. label)
            t:eq(tr:contains(r.x + r.w - 1, r.y + r.h - 1), true,
                "and the last pixel inside is" .. label)
            t:eq(tr:contains(r.x - 1, r.y), false, "one left of it is out" .. label)
            t:eq(tr:contains(r.x, r.y - 1), false, "one above it is out" .. label)
            t:eq(tr:contains(r.x + r.w, r.y), false,
                "the half-open right edge is out" .. label)
            t:eq(tr:contains(r.x, r.y + r.h), false,
                "and so is the bottom one" .. label)
        end
    end)

    t:case("the visible canvas rectangle stops at the bottom of the screen", function()
        local tr = portrait(1000)
        local r = tr:canvasRect()
        t:eq(r.y, 1000, "starts at the sheet top")
        t:eq(r.y + r.h, tr.screen_h, "and ends at the screen edge, not past it")
    end)

    t:case("at full height the whole canvas is on screen", function()
        local tr = portrait(0)
        local r = tr:canvasRect()
        local _, bottom = tr:toScreen(0, SCRIBE_H)
        t:check(bottom <= r.y + r.h + 1, "the last row of the canvas is visible")
    end)

    t:case("the sheet rectangle covers the margins the canvas does not", function()
        local tr = landscape(200)
        local sheet, canvas = tr:sheetRect(), tr:canvasRect()
        t:eq(sheet.x, 0, "the sheet is full width")
        t:eq(sheet.w, tr.screen_w, "including the letterbox")
        t:check(canvas.w < sheet.w, "which the canvas itself is not")
    end)

    t:case("a canvas with no area is refused rather than dividing by zero", function()
        local tr, err = Transform.new{
            logical_w = 0, logical_h = 100, screen_w = 100, screen_h = 100, sheet_top = 0,
        }
        t:eq(tr, nil, "refused")
        t:eq(err, "bad_geometry", "with a reason")
        local infinite, ierr = Transform.new{
            logical_w = math.huge, logical_h = 100,
            screen_w = 100, screen_h = 100, sheet_top = 0,
        }
        t:eq(infinite, nil, "infinite geometry is refused too")
        t:eq(ierr, "bad_geometry", "before NaN reaches a raster size")
    end)

    -- =================================================================
    t:describe("ink_spatial_grid")

    local function grid()
        return Grid.new{ width = 1000, height = 1000, cell = 100 }
    end

    t:case("a box is found by a query that overlaps it", function()
        local g = grid()
        g:insert(7, 120, 120, 180, 180)
        local hits = g:candidates(150, 150, 150, 150)
        t:eq(#hits, 1, "one candidate")
        t:eq(hits[1], 7, "the right one")
    end)

    t:case("a box in another part of the canvas is not a candidate", function()
        local g = grid()
        g:insert(7, 120, 120, 180, 180)
        t:eq(#g:candidates(900, 900, 910, 910), 0, "locality is the whole point")
    end)

    t:case("a stroke spanning many cells comes back once, not once per cell", function()
        local g = grid()
        g:insert(7, 0, 0, 999, 999)
        local hits = g:candidates(0, 0, 999, 999)
        t:eq(#hits, 1, "deduplicated")
    end)

    t:case("a query returns every stroke that touches it", function()
        local g = grid()
        g:insert(1, 0, 0, 50, 50)
        g:insert(2, 40, 40, 90, 90)
        g:insert(3, 500, 500, 550, 550)
        local hits = g:candidates(45, 45, 45, 45)
        t:eq(#hits, 2, "the two that overlap")
        t:eq(hits[1], 1, "in ascending order")
        t:eq(hits[2], 2, "so the caller can walk it either way")
    end)

    t:case("removing a stroke takes it out of every cell it was in", function()
        local g = grid()
        g:insert(7, 0, 0, 999, 999)
        g:remove(7)
        t:eq(#g:candidates(0, 0, 10, 10), 0, "gone from the first cell")
        t:eq(#g:candidates(900, 900, 999, 999), 0, "and from the last")
    end)

    t:case("removing a stroke that was never there is harmless", function()
        local g = grid()
        g:remove(99)
        t:eq(#g:candidates(0, 0, 999, 999), 0, "no crash, nothing found")
    end)

    t:case("a box reaching outside the canvas is clamped, not dropped", function()
        local g = grid()
        g:insert(7, -50, -50, 20, 20)
        t:eq(#g:candidates(0, 0, 5, 5), 1, "still findable at the edge")
        g:insert(8, 980, 980, 5000, 5000)
        t:eq(#g:candidates(999, 999, 999, 999), 1, "and at the far edge")
    end)

    t:case("a query outside the canvas finds the strokes clamped to that edge", function()
        local g = grid()
        g:insert(7, 950, 950, 999, 999)
        t:eq(#g:candidates(5000, 5000, 6000, 6000), 1,
            "clamping keeps a stray coordinate from silently finding nothing")
    end)

    t:case("a dense canvas still answers a local query locally", function()
        local g = grid()
        -- One stroke per cell, the whole canvas covered.
        local id = 0
        for x = 0, 900, 100 do
            for y = 0, 900, 100 do
                id = id + 1
                g:insert(id, x + 10, y + 10, x + 20, y + 20)
            end
        end
        t:eq(id, 100, "a hundred strokes")
        local hits = g:candidates(15, 15, 15, 15)
        t:eq(#hits, 1, "and a point query sees exactly one of them")
    end)

    t:case("re-inserting the same id replaces its old box", function()
        local g = grid()
        g:insert(7, 0, 0, 50, 50)
        g:insert(7, 900, 900, 950, 950)
        t:eq(#g:candidates(10, 10, 10, 10), 0, "not where it was")
        t:eq(#g:candidates(910, 910, 910, 910), 1, "where it is now")
    end)

    t:case("a grid with no cell size is refused", function()
        local g, err = Grid.new{ width = 100, height = 100, cell = 0 }
        t:eq(g, nil, "refused")
        t:eq(err, "bad_geometry", "with a reason")
    end)
end
