--[[--
A Xournal++ document, written as XML text, one bounded block at a time.

The PDF export is a picture of the page: faithful to the pixel, and dead as
ink. Someone who wants to keep *editing* a notebook on a desktop needs the
strokes themselves, as vectors, in a format a free editor opens. Xournal++
(checked against 1.3.7) is that editor, and its `.xopp` file is gzip over a
small XML dialect: `<xournal>`, a `<title>`, then per page a `<page>` with a
`<background>` and a `<layer>` holding `<stroke>` elements whose text is the
point list. This module writes that XML and nothing else -- compression, the
temporary file and the rename belong to the caller, which is also why there is
no `require` here at all: the writer is pure, and every byte it can produce is
reachable from a test.

Four decisions are load-bearing:

**Nothing is ever the whole document.** A notebook of a few hundred pages is
megabytes of coordinates, and building it -- or even one dense page -- as a
Lua string on an e-reader is how an export becomes an out-of-memory crash
halfway through. Text is gathered into a small buffer and handed to the
injected sink whenever the buffer would pass `block_limit` (16 KiB), and at
the end of every call; no sink call is ever larger than that, even for a
20 000-point stroke. The sink answers true or nil plus a reason; the first
failure is returned from the call that met it, and the writer then refuses
everything, so a caller can never append to a file that already has a hole in
it.

**Validate first, then emit.** A stroke is checked in full -- count, every
coordinate, every width -- before its first byte leaves. A bad stroke is
refused with nothing written and the document still well formed, so the
caller decides whether to skip it or abandon the export. Only a sink failure
poisons the writer.

**Numbers do not go through the C locale.** `%f` answers "419,53" wherever
LC_NUMERIC says so, and KOReader does not pin it; Xournal++ would then read
"419" and a stray token. Every number here is integer arithmetic formatted
with `%d`, six decimals before trailing zeros are trimmed, and a positive
width is never allowed to round down to zero -- a zero-width stroke is
invisible in Xournal++ and silently loses what the reader wrote.

**XML is escaped, and what XML 1.0 cannot carry is refused.** Titles come from
a person, so they may hold `&`, `<` or quotes, which are escaped, and may hold
bytes no XML parser accepts (control characters, broken UTF-8), which are
refused rather than dropped: a file that opens with a quietly different title
is worse than an export that says why it stopped. No DTD, no entity beyond the
five predefined ones, ever.

Geometry is converted from the surface's *logical* units, not screen pixels:
`points = units / units_per_mm * 72 / 25.4`, where `units_per_mm` is the
surface's own factor (notebooks: 8). Using the screen DPI instead would make
the same notebook export at a different size on every device.

What Xournal++ cannot express is not hidden: `Xopp.limitations` lists every
approximation this mapping makes, for the export dialog to show before the
reader commits to a format.
]]

local Xopp = {}

local floor = math.floor
local byte, sub = string.byte, string.sub
local concat = table.concat

--- The largest single sink call. Small enough that a page never exists as one
--- string; large enough that a normal stroke is a single write.
Xopp.BLOCK_LIMIT = 16384
--- The smallest a caller (in practice, a test) may ask for. Anything smaller
--- only multiplies sink calls; the slicing below handles any size correctly.
local MIN_BLOCK_LIMIT = 64

--- Same cap as `ink_export_pdf`: a runaway caller cannot produce a file no
--- editor will open, and neither export refuses what the other accepts.
local MAX_PAGES = 5000
Xopp.MAX_PAGES = MAX_PAGES

--- The biggest magnitude, in points, the formatter will write. About 350 m:
--- far beyond any page, and small enough that six decimals stay exact in a
--- double (1e9 * 1e6 < 2^53). A coordinate past it is corrupt data.
local MAX_MAGNITUDE = 1e9

Xopp.FILE_VERSION = "4"

-- ------------------------------------------------------------------- styles

--[[--
JustDraw style ids, copied from `ink_style.lua` rather than required: this
module has no dependencies. tests/export_xopp_spec.lua compares them with the
real module, so a renumbering there fails loudly here.
]]
local PEN, MARKER, GRAPHITE, ROUND, HIGHLIGHTER, TEXTURED = 1, 3, 65, 66, 67, 68

--- Xournal++ writes a highlighter's alpha as 0x7f whatever the user picked.
local HIGHLIGHTER_ALPHA = "7f"

--[[--
Style id to Xournal++ tool and colour (`#rrggbbaa`). The grays are the ones
`ink_style.lua` paints: marker is Blitbuffer's LIGHT_GRAY (0xCC), graphite and
textured are GRAY_6 (0x66). Unknown ids export as pen, as `Style.normalize`
renders them.
]]
Xopp.STYLE_MAP = {
    [PEN] = { tool = "pen", color = "#000000ff" },
    [ROUND] = { tool = "pen", color = "#000000ff" },
    -- The legacy marker is an opaque gray on the device; a translucent
    -- highlighter would change what it looks like, so it stays a pen.
    [MARKER] = { tool = "pen", color = "#ccccccff", limitation = "marker_opaque" },
    [GRAPHITE] = { tool = "pen", color = "#666666ff" },
    [HIGHLIGHTER] = { tool = "highlighter", color = "#000000" .. HIGHLIGHTER_ALPHA,
        limitation = "highlighter_opacity" },
    [TEXTURED] = { tool = "pen", color = "#666666ff", limitation = "textured_grain" },
}
local DEFAULT_STYLE = Xopp.STYLE_MAP[PEN]

--- Tool and colour for a stroke's style; anything unknown is pen.
function Xopp.styleFor(style)
    local entry = Xopp.STYLE_MAP[style] or DEFAULT_STYLE
    return entry.tool, entry.color
end

-- -------------------------------------------------------------------- paper

--[[--
JustDraw paper kind (`ink_paper.lua`) to Xournal++ background style. Note that
Xournal++ "lined" has a red margin; plain horizontal lines are "ruled".
]]
Xopp.PAPER_STYLES = {
    blank = "plain",
    ruled = "ruled",
    grid = "graph",
    dots = "dotted",
}
--- What a kind with no Xournal++ equivalent (ruled_narrow, checklist, or one
--- a future build adds) becomes: lines are the closest thing to writing paper.
Xopp.FALLBACK_PAPER_STYLE = "ruled"

--- Background style for a paper kind, and whether the mapping is exact.
--- An absent kind is a page without paper, which is blank.
function Xopp.backgroundStyle(kind)
    if kind == nil then return "plain", true end
    local style = Xopp.PAPER_STYLES[kind]
    if style then return style, true end
    return Xopp.FALLBACK_PAPER_STYLE, false
end

--- Everything this export approximates. `id` is stable for code; `text` is
--- for people, and the dialog is expected to translate it.
--- Marks a string for extraction (tools/extract_strings) without translating
--- it here: this module is pure, and the dialog translates when it shows it.
local function gettext_noop(text) return text end

Xopp.limitations = {
    { id = "highlighter_opacity",
      text = gettext_noop("The highlighter paints black at 20% opacity in JustDraw; Xournal++ stores highlighters at 50% (alpha 0x7f), so they look darker.") },
    { id = "marker_opaque",
      text = gettext_noop("The legacy marker is exported as an opaque light-gray pen, not as a translucent highlighter.") },
    { id = "textured_grain",
      text = gettext_noop("Textured strokes lose their grain and become flat gray pen strokes. The PDF export remains the faithful picture.") },
    { id = "nib_shape",
      text = gettext_noop("Every stroke uses Xournal++'s round cap; JustDraw's original pen draws a square nib, so ends and corners may look slightly different.") },
    { id = "paper_fallback",
      text = gettext_noop("Paper without a Xournal++ equivalent (narrow ruled, checklist) is exported as ruled.") },
    { id = "paper_pitch",
      text = gettext_noop("Xournal++ draws ruled, squared and dotted backgrounds at its own spacing, not JustDraw's.") },
    { id = "single_point",
      text = gettext_noop("A dot is exported as a zero-length stroke of two identical points.") },
}

-- ------------------------------------------------------------------ numbers

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function positive(v)
    return finite(v) and v > 0
end

--- Logical units to PostScript points, or nil for anything not convertible.
function Xopp.toPoints(units, units_per_mm)
    if not finite(units) or not positive(units_per_mm) then return nil end
    return units / units_per_mm * 72 / 25.4
end

--[[--
A decimal number, locale-independent, six decimals, trailing zeros trimmed.

`floor_positive` is for widths: a positive value that would round to "0"
becomes the smallest representable one instead, because zero width in
Xournal++ is an invisible stroke. Returns nil past MAX_MAGNITUDE.
]]
local function formatNumber(v, floor_positive)
    if not finite(v) then return nil end
    local sign = ""
    local magnitude = v
    if v < 0 then
        sign = "-"
        magnitude = -v
    end
    if magnitude >= MAX_MAGNITUDE then return nil end
    local scaled = floor(magnitude * 1000000 + 0.5)
    if scaled == 0 then
        if floor_positive and v > 0 then
            scaled = 1
        else
            return "0" -- never "-0"
        end
    end
    local whole = floor(scaled / 1000000)
    local frac = scaled - whole * 1000000
    if frac == 0 then return string.format("%s%d", sign, whole) end
    local digits = string.format("%06d", frac):gsub("0+$", "")
    return string.format("%s%d.%s", sign, whole, digits)
end
Xopp.formatNumber = formatNumber

-- --------------------------------------------------------------------- text

--[[--
Whether a string is UTF-8 that XML 1.0 can carry (section 2.2, Char).

Refuses malformed sequences (overlong, truncated, surrogates, past U+10FFFF),
C0 controls other than tab, LF and CR, and the noncharacters U+FFFE/U+FFFF.
One pass over the bytes, no tables.
]]
local function checkXmlText(s)
    if type(s) ~= "string" then return nil, "bad_text" end
    local i, n = 1, #s
    while i <= n do
        local b = byte(s, i)
        if b < 0x80 then
            if b < 0x20 and b ~= 0x09 and b ~= 0x0A and b ~= 0x0D then
                return nil, "invalid_char"
            end
            i = i + 1
        else
            local len, cp
            if b >= 0xC2 and b <= 0xDF then
                len, cp = 2, b - 0xC0
            elseif b >= 0xE0 and b <= 0xEF then
                len, cp = 3, b - 0xE0
            elseif b >= 0xF0 and b <= 0xF4 then
                len, cp = 4, b - 0xF0
            else
                return nil, "invalid_utf8"
            end
            if i + len - 1 > n then return nil, "invalid_utf8" end
            for k = 1, len - 1 do
                local c = byte(s, i + k)
                if c < 0x80 or c > 0xBF then return nil, "invalid_utf8" end
                cp = cp * 64 + (c - 0x80)
            end
            if (len == 3 and cp < 0x800) or (len == 4 and cp < 0x10000)
                or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
                return nil, "invalid_utf8"
            end
            if cp == 0xFFFE or cp == 0xFFFF then return nil, "invalid_char" end
            i = i + len
        end
    end
    return true
end
Xopp.checkText = checkXmlText

--- The five predefined entities, plus character references for the
--- whitespace an attribute value would otherwise normalise to a space, and
--- for CR, which a parser folds into LF even in text.
local ESCAPES = {
    ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
    ['"'] = "&quot;", ["'"] = "&apos;",
    ["\t"] = "&#9;", ["\n"] = "&#10;", ["\r"] = "&#13;",
}

--- Escaped text for element content: tab and LF survive as themselves.
function Xopp.escapeText(s)
    local ok, err = checkXmlText(s)
    if not ok then return nil, err end
    return (s:gsub("[&<>\"'\r]", ESCAPES))
end

--- Escaped text for a double- or single-quoted attribute value.
function Xopp.escapeAttribute(s)
    local ok, err = checkXmlText(s)
    if not ok then return nil, err end
    return (s:gsub("[&<>\"'\t\n\r]", ESCAPES))
end

-- ------------------------------------------------------------------- writer

local Writer = {}
Writer.__index = Writer

--- Hand one string to the sink. A sink that raises is a sink that failed.
function Writer:_send(chunk)
    local ok, res, err = pcall(self.sink, chunk)
    if not ok then
        self.failed = tostring(res or "write_failed")
    elseif not res then
        self.failed = err or "write_failed"
    end
end

function Writer:_flush()
    if self.failed or self.buf_n == 0 then return end
    local chunk = concat(self.buf, "", 1, self.buf_n)
    for i = 1, self.buf_n do self.buf[i] = nil end
    self.buf_n, self.buf_len = 0, 0
    self:_send(chunk)
end

--[[--
Append text to the pending block. Once the writer has failed this does
nothing, which is what lets the emitting code below read straight through
without checking every line: the call that met the failure reports it at
its end, and nothing reaches the sink after it.
]]
function Writer:_put(s)
    if self.failed then return end
    local len, limit = #s, self.limit
    if self.buf_len + len > limit then self:_flush() end
    if len > limit then
        -- Only a long title gets here; slice it rather than send it whole.
        local at = 1
        while at <= len and not self.failed do
            self:_send(sub(s, at, at + limit - 1))
            at = at + limit
        end
        return
    end
    if self.failed then return end
    self.buf_n = self.buf_n + 1
    self.buf[self.buf_n] = s
    self.buf_len = self.buf_len + len
end

--- Flush and report: the common tail of every public call.
function Writer:_finishCall()
    self:_flush()
    if self.failed then return nil, self.failed end
    return true
end

function Writer:_points(v)
    return formatNumber(v / self.units_per_mm * 72 / 25.4)
end

function Writer:_width(v)
    return formatNumber(v / self.units_per_mm * 72 / 25.4, true)
end

--[[--
  sink   function(string) -> true | nil, err
  opts.units_per_mm  logical units per millimetre of the surface (required)
  opts.title         document title, UTF-8 (default "JustDraw")
  opts.version       appended to the creator attribute, e.g. "1.4"
  opts.block_limit   largest sink call, 64 .. 16384 (default 16384)

Writes the XML declaration, the root element and the title. Returns the
writer, or nil plus a reason; a sink failure here also returns nil.
]]
function Xopp.beginDocument(sink, opts)
    opts = opts or {}
    if type(sink) ~= "function" then return nil, "bad_sink" end
    local units_per_mm = opts.units_per_mm
    if not positive(units_per_mm) then return nil, "bad_units" end
    local limit = opts.block_limit or Xopp.BLOCK_LIMIT
    if not finite(limit) or limit ~= floor(limit)
        or limit < MIN_BLOCK_LIMIT or limit > Xopp.BLOCK_LIMIT then
        return nil, "bad_block_limit"
    end

    local title, err = Xopp.escapeText(opts.title == nil and "JustDraw" or opts.title)
    if not title then return nil, err end
    local creator = "JustDraw"
    if opts.version ~= nil then creator = creator .. " " .. tostring(opts.version) end
    creator, err = Xopp.escapeAttribute(creator)
    if not creator then return nil, err end

    local self = setmetatable({
        sink = sink,
        units_per_mm = units_per_mm,
        limit = limit,
        buf = {}, buf_n = 0, buf_len = 0,
        state = "document", -- document -> page -> document ... -> finished
        pages = 0,
        failed = nil,
    }, Writer)

    self:_put('<?xml version="1.0" encoding="UTF-8"?>\n')
    self:_put('<xournal creator="' .. creator .. '" fileversion="'
        .. Xopp.FILE_VERSION .. '">\n')
    self:_put("<title>")
    self:_put(title)
    self:_put("</title>\n")
    local ok, sink_err = self:_finishCall()
    if not ok then return nil, sink_err end
    return self
end

--[[--
Open a page. `page.width`/`page.height` are logical units; `page.paper` is a
JustDraw paper kind (see `Xopp.backgroundStyle`). The page's one layer opens
with it.
]]
function Writer:beginPage(page)
    if self.failed then return nil, self.failed end
    if self.state ~= "document" then return nil, "bad_state" end
    if type(page) ~= "table" then return nil, "bad_page" end
    if not positive(page.width) or not positive(page.height) then
        return nil, "bad_page_size"
    end
    -- Positive after conversion too: a size that formats as "0" is a page no
    -- editor can lay out.
    local w, h = self:_width(page.width), self:_width(page.height)
    if not w or not h then return nil, "out_of_range" end
    if self.pages >= MAX_PAGES then return nil, "too_many_pages" end

    local style = Xopp.backgroundStyle(page.paper)
    self.state = "page"
    self.pages = self.pages + 1
    self:_put('<page width="' .. w .. '" height="' .. h .. '">\n')
    self:_put('<background type="solid" color="#ffffffff" style="' .. style .. '"/>\n')
    self:_put("<layer>\n")
    return self:_finishCall()
end

--[[--
Everything about a stroke that could stop it, checked before any of it is
written. Returns the point count, or nil plus a reason.
]]
function Writer:_validateStroke(stroke)
    if type(stroke) ~= "table" then return nil, "bad_stroke" end
    local points = stroke.points
    if type(points) ~= "table" then return nil, "bad_point" end
    local count = #points
    local n = stroke.n
    if n == nil then
        if count % 2 ~= 0 then return nil, "bad_count" end
        n = count / 2
    end
    if not finite(n) or n < 1 or n ~= floor(n) then return nil, "bad_count" end
    -- Exactly, not "at least": an `n` shorter than the array would silently
    -- truncate the stroke, and that is the kind of loss nobody notices.
    if count ~= n * 2 then return nil, "bad_count" end
    for i = 1, count do
        local v = points[i]
        if not finite(v) then return nil, "bad_point" end
        if not self:_points(v) then return nil, "out_of_range" end
    end
    if not positive(stroke.width) then return nil, "bad_width" end
    if not self:_width(stroke.width) then return nil, "out_of_range" end
    local widths = stroke.widths
    if widths ~= nil then
        if type(widths) ~= "table" or #widths ~= n - 1 then return nil, "bad_widths" end
        for i = 1, n - 1 do
            local v = widths[i]
            if not positive(v) then return nil, "bad_widths" end
            if not self:_width(v) then return nil, "out_of_range" end
        end
    end
    return n
end

--[[--
Write one stroke, in the order called -- which is the visual order, later on
top. `stroke.points` is flat `{ x1, y1, x2, y2, ... }` in logical units,
`stroke.n` its point count (optional; taken from the array otherwise),
`stroke.width` its nominal width, `stroke.tool` its JustDraw style, and
`stroke.widths` optional per-segment widths, exactly n - 1 of them.

A one-point stroke (a dot) is written as its point twice: Xournal++ discards
strokes with fewer than two points, and a repeated point with a round cap is
a dot of the right size with no invented length.
]]
function Writer:writeStroke(stroke)
    if self.failed then return nil, self.failed end
    if self.state ~= "page" then return nil, "bad_state" end
    local n, err = self:_validateStroke(stroke)
    if not n then return nil, err end

    local tool, color = Xopp.styleFor(stroke.tool)
    local points, widths = stroke.points, stroke.widths
    self:_put('<stroke tool="' .. tool .. '" color="' .. color .. '" width="')
    self:_put(self:_width(stroke.width))
    if widths then
        for i = 1, n - 1 do
            self:_put(" " .. self:_width(widths[i]))
        end
    end
    self:_put('" capStyle="round">')
    for i = 1, n do
        local x, y = self:_points(points[i * 2 - 1]), self:_points(points[i * 2])
        self:_put((i > 1 and " " or "") .. x .. " " .. y)
        if n == 1 then self:_put(" " .. x .. " " .. y) end
    end
    self:_put("</stroke>\n")
    return self:_finishCall()
end

function Writer:endPage()
    if self.failed then return nil, self.failed end
    if self.state ~= "page" then return nil, "bad_state" end
    self.state = "document"
    self:_put("</layer>\n</page>\n")
    return self:_finishCall()
end

--[[--
Close the root element. A document without pages is refused and the writer
marked failed, as `ink_export_pdf` does: the caller has an unfinished file
under a temporary name and must discard it, not rename it into place.
]]
function Writer:endDocument()
    if self.failed then return nil, self.failed end
    if self.state ~= "document" then return nil, "bad_state" end
    if self.pages == 0 then
        self.failed = "no_pages"
        return nil, self.failed
    end
    self:_put("</xournal>\n")
    local ok, err = self:_finishCall()
    if not ok then return nil, err end
    self.state = "finished"
    return true
end

function Writer:pageCount()
    return self.pages
end

function Writer:isFinished()
    return self.state == "finished"
end

function Writer:failure()
    return self.failed
end

return Xopp
