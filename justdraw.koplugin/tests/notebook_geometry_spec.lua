return function(ctx)
    local t = ctx.t
    local Transform = require("ink_canvas_transform")

    t:describe("notebook geometry / fit and clip")

    t:case("a portrait page letterboxes without distortion", function()
        local tr = Transform.new{
            logical_w = 1000, logical_h = 2000,
            fit_rect = { x = 100, y = 200, w = 1600, h = 1800 },
            clip_rect = { x = 100, y = 200, w = 1600, h = 1800 },
            align_x = "center", align_y = "center",
        }
        t:eq(tr.scale, 0.9, "aspect-fit scale")
        local sx, sy = tr:toScreen(500, 1000)
        local cx, cy = tr:toCanvas(sx, sy)
        t:eq(cx, 500, "x round trip")
        t:eq(cy, 1000, "y round trip")
        t:eq(tr:contains(150, 300), false, "letterbox is not ink")
        t:eq(tr:contains(sx, sy), true, "drawn page is ink")
    end)

    t:case("clip excludes off-page coordinates and reports cache origin", function()
        local tr = Transform.new{
            logical_w = 1000, logical_h = 2000,
            fit_rect = { x = 0, y = 0, w = 1000, h = 2000 },
            clip_rect = { x = 0, y = 500, w = 1000, h = 1000 },
            align_x = "center", align_y = "top",
        }
        local r = tr:visibleCanvasRect()
        t:eq(r.y, 500, "visible origin")
        t:eq(r.cache_y, 500, "matching cache source")
        t:eq(tr:contains(10, 499), false, "above clip rejected")
        t:eq(tr:contains(10, 500), true, "clip edge accepted")
    end)

    t:case("non-finite notebook geometry is rejected", function()
        local bad = Transform.new{
            logical_w = 1000, logical_h = 2000,
            fit_rect = { x = 0, y = 0, w = math.huge, h = 1000 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1000 },
        }
        t:eq(bad, nil, "infinite rectangle")
    end)

    t:case("an explicit viewport must intersect the fitted page", function()
        local tr, err = Transform.new{
            logical_w = 1000, logical_h = 1400,
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 2000, y = 0, w = 1000, h = 1400 },
        }
        t:eq(tr, nil, "disjoint page cannot become an invisible surface")
        t:eq(err, "bad_geometry", "stable geometry reason")
    end)
end
