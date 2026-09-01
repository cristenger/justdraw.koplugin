--[[--
What a stroke's style *is*, in one place.

A style is a small integer stored in the strokes' existing `tool` column and
in the sidecar's `t` field. Where the kernel already names the concept the
number is the kernel's -- TOOL_TYPE_PEN, TOOL_TYPE_HIGHLIGHTER -- so a
hardware latch and a manual choice cannot disagree about what "marker"
means. Graphite has no kernel tool, so it takes a value far outside the
MT_TOOL range; an old build reading it renders plain ink, which degrades a
note's look but never its data.

Everything here is a precomputed lookup: colorFor sits on the cache's
replay path, where allocation is forbidden.
]]

local Blitbuffer = require("ffi/blitbuffer")

local Style = {
    PEN = 1,       -- TOOL_TYPE_PEN
    MARKER = 3,    -- TOOL_TYPE_HIGHLIGHTER
    GRAPHITE = 65, -- private: outside the kernel MT_TOOL range
}

local COLORS = {
    [Style.MARKER] = Blitbuffer.COLOR_LIGHT_GRAY,
    [Style.GRAPHITE] = Blitbuffer.COLOR_GRAY_6,
}

local WIDTH_SCALE = {
    [Style.MARKER] = 3,
}

local KNOWN = {
    [Style.PEN] = true, [Style.MARKER] = true, [Style.GRAPHITE] = true,
}

function Style.normalize(v)
    if KNOWN[v] then return v end
    return Style.PEN
end

function Style.colorFor(style, fallback)
    return COLORS[style] or fallback
end

function Style.widthScale(style)
    return WIDTH_SCALE[style] or 1
end

--- Whether this style paints a colour the fast (forced-monochrome) refresh
--- cannot show. Refresh decisions key on it: a DU update over gray ink drops
--- the ink on device (ADR-36). rawequal, never `~= nil`: a gray style's
--- lookup answers a real colour cdata, whose __eq indexes its argument and
--- raises on nil — on the replay path that took the whole process down.
function Style.isGray(style)
    return not rawequal(COLORS[style], nil)
end

--- The one per-contact rule. Callers settle the eraser BEFORE this: an
--- erasing contact never has a style. `marker_allowed` is "this surface is
--- ours to fill" -- a sheet or a notebook page, never the book's own page.
function Style.resolve(manual_style, hw_tool, marker_allowed)
    if hw_tool == Style.MARKER and marker_allowed then return Style.MARKER end
    local style = Style.normalize(manual_style)
    if style == Style.MARKER and not marker_allowed then return Style.PEN end
    return style
end

return Style
