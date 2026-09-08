--[[--
The style domain: values, colors, widths, and the one resolution rule.
Small on purpose -- everything else about a style is ordinary stroke data.
]]
return function(ctx)
    local t = ctx.t
    local Style = require("ink_style")
    local Blitbuffer = require("ffi/blitbuffer")

    t:describe("ink_style / values and lookups")

    t:case("styles reuse the kernel tool numbers where one exists", function()
        t:eq(Style.PEN, 1, "pen is TOOL_TYPE_PEN")
        t:eq(Style.MARKER, 3, "marker is TOOL_TYPE_HIGHLIGHTER")
        t:eq(Style.GRAPHITE, 65, "graphite lives outside the kernel range")
    end)

    t:case("normalize maps anything unknown to pen", function()
        t:eq(Style.normalize(nil), Style.PEN, "absent")
        t:eq(Style.normalize(2), Style.PEN, "an eraser value never styles a stroke")
        t:eq(Style.normalize(999), Style.PEN, "future value degrades to ink")
        t:eq(Style.normalize(Style.MARKER), Style.MARKER, "known values survive")
    end)

    t:case("colorFor answers the caller's ink for pen and a gray otherwise", function()
        t:eq(Style.colorFor(Style.PEN, "ink"), "ink", "pen keeps the surface ink")
        t:eq(Style.colorFor(Style.GRAPHITE, "ink"), Blitbuffer.COLOR_GRAY_6, "graphite")
        t:eq(Style.colorFor(Style.MARKER, "ink"), Blitbuffer.COLOR_LIGHT_GRAY, "marker")
        t:eq(Style.colorFor(nil, "ink"), "ink", "legacy strokes render as before")
    end)

    t:case("isGray names exactly the styles DU cannot show", function()
        -- The fast refresh is forced monochrome on device; refresh decisions
        -- key on this predicate (ADR-36).
        t:eq(Style.isGray(Style.GRAPHITE), true, "graphite paints gray")
        t:eq(Style.isGray(Style.MARKER), true, "marker paints gray")
        t:eq(Style.isGray(Style.PEN), false, "pen rides the surface ink")
        t:eq(Style.isGray(nil), false, "legacy strokes ride the surface ink")
        t:eq(Style.isGray(999), false, "unknown styles degrade to ink")
    end)

    t:case("wide styles preserve the stored nib scale", function()
        t:eq(Style.widthScale(Style.MARKER), 3, "marker nib")
        t:eq(Style.widthScale(Style.PEN), 1, "pen")
        t:eq(Style.widthScale(Style.GRAPHITE), 1, "graphite")
        t:eq(Style.widthScale(nil), 1, "legacy")
    end)

    t:describe("ink_style / per-contact resolution")

    t:case("the barrel highlighter promotes to marker only where marker may draw", function()
        t:eq(Style.resolve(Style.PEN, 3, true), Style.MARKER, "hw button wins on a sheet")
        t:eq(Style.resolve(Style.PEN, 3, false), Style.PEN, "and falls back on the page")
        t:eq(Style.resolve(Style.GRAPHITE, 3, true), Style.MARKER, "over any manual style")
    end)

    t:case("a manual marker demotes to pen where it may not draw", function()
        t:eq(Style.resolve(Style.MARKER, 1, false), Style.PEN, "no sheet: plain ink")
        t:eq(Style.resolve(Style.MARKER, 1, true), Style.MARKER, "sheet: marker")
        t:eq(Style.resolve(Style.GRAPHITE, 1, false), Style.GRAPHITE, "graphite draws anywhere")
    end)
    t:case("modern identities survive preferences but cannot enter legacy rendering", function()
        t:eq(Style.ROUND, 66, "stored round identity")
        t:eq(Style.HIGHLIGHTER, 67, "stored alpha identity")
        t:eq(Style.TEXTURED, 68, "stored grain identity")
        for _,style in ipairs({66,67,68}) do
            t:eq(Style.normalize(style), style, "preference retained")
            t:eq(Style.resolve(style,1,true), style, "modern surface accepts choice")
            t:eq(Style.resolve(style,1,false), Style.PEN, "legacy receives plain ink")
            t:eq(Style.resolve(style,3,true), Style.MARKER, "hardware latch retains its original contract")
        end
        t:eq(Style.isGray(67), true, "alpha uses a grayscale update")
        t:eq(Style.isGray(68), true, "grain uses a grayscale update")
        t:eq(Style.isGray(66), false, "round black keeps fast updates")
        t:eq(Style.widthScale(67), 3, "highlighter has a wide nib")
    end)

end
