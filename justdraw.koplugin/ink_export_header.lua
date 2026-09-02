--[[--
The strip that says what an exported page is, painted into the page itself.

Forty pages of ink on white, in one PDF, with nothing on them: sheet, page
note and sidecar ink all look identical once they are off the device, and the
reader who exported them has no way back to which was which. The band is the
whole of the answer -- book, kind, location -- and it is *rendered*, not
written as text, because the PDF this project emits is one grey image per page
and has no text objects to put a caption in (ADR-31).

Three decisions here are about memory rather than looks.

**The ink raster is released before the band is painted.** A compose reserves
a second buffer and blits the note into it; if the note's raster were still
held while the band was drawn -- and then while the page was encoded -- the
peak would be two full pages plus the encoder's own string. Releasing between
the blit and the band makes the peak two buffers for the length of one blit.

**The budget is measured on the composed page.** The 8 Mpx cap exists because
memory runs out per page (ADR-30), and the page that gets allocated and
encoded is the content *plus* 118 rows. A scale that fitted the content alone
would put the finished page over the cap, which is why `budgetedScale` exists
and why every kind of note goes through it.

**The text is painted through an injected seam.** `TextWidget` cannot be built
in the test suite, and `Font:getFace` scales its size by the device's screen --
so a face chosen by arithmetic would be right on one device and unreadable on
the next. `textPainter` therefore *measures*: it steps a face down until the
widget it builds fits the band, once per export, and the suite injects a
recorder instead. Everything asserted about the real widget lives in
tests/conformance.lua.
]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local Raster = require("ink_export_raster")

local Header = {}

local floor = math.floor

--- 10 mm at 300 dpi (ADR-40). Deep enough for a line of text at a size a
--- reader can take in at a glance, shallow enough to cost nothing on a page.
Header.BAND_PX = 118

--- 4 mm at the same resolution: the margin the line keeps on both sides, so
--- the text is not against the paper's edge on a trimmed print.
Header.PAD_PX = 47

--- The same 10 mm, in points, for the PDF page that has to grow by it.
Header.BAND_PT = 10 / 25.4 * 72

--[[--
The box the line is painted in, and the tallest a face may be.

`textPainter` measures against this exact number, so centring the box is
centring the text: the painter promises not to exceed it, and the band's
remaining rows are what keep a descender off the ink below.
]]
Header.TEXT_BOX_PX = floor(Header.BAND_PX * 0.7)

--- Where the measurement starts: about 60% of the band, stepped down until it
--- fits. A starting point, not a claim -- what a size means in pixels is the
--- device's to say (`Screen:scaleBySize`).
Header.START_SIZE = floor(Header.BAND_PX * 0.6)

--- Below this a caption is not worth painting; the band comes out blank
--- rather than illegible.
Header.MIN_SIZE = 8

--- The pixels the band adds at a given scale: the width that will actually be
--- allocated, times the band. Rounded the way the raster rounds, because the
--- forecast has to count the buffer that gets made.
function Header.bandPixels(logical_w, scale)
    local _pixels, w = Raster.roundedPixels(logical_w, 1, scale)
    return w * Header.BAND_PX
end

--- The whole page a compose will reserve: content plus band.
function Header.composedPixels(logical_w, logical_h, scale)
    local _pixels, w, h = Raster.roundedPixels(logical_w, logical_h, scale)
    return w * (h + Header.BAND_PX), w, h + Header.BAND_PX
end

--[[--
A scale whose *composed* page fits the budget.

Two passes, because the band's cost depends on the width, which depends on the
scale. The first is the ordinary bound on the content; the second re-bounds
against a budget reduced by the band at that width. The answer is never over
budget: the second scale cannot be larger than the first, so the width -- and
with it the band's cost -- can only have shrunk, while the content was bounded
against a budget that had already paid for the wider band.
]]
function Header.budgetedScale(logical_w, logical_h, target, max_pixels)
    max_pixels = max_pixels or Raster.MAX_PIXELS
    local first, err = Raster.boundedScale(logical_w, logical_h, target,
        max_pixels)
    if not first then return nil, err end
    local band = Header.bandPixels(logical_w, first)
    -- A page so wide that its band alone fills the budget has no scale at all;
    -- `boundedScale` refuses a non-positive one, which is the same answer.
    return Raster.boundedScale(logical_w, logical_h, first, max_pixels - band)
end

--[[--
  opts.result          { bb, width_pt, height_pt, release } -- one note
  opts.title           the book, as the file is named
  opts.kind_label      "Page note" | "Drawing sheet" | "Legacy ink"
  opts.location_label  "Page 12" | "Stored page 12" | "Location unavailable"
  opts.paint_text      function(bb, x, y, text, max_width) -> painted height
  opts.Blitbuffer      injectable, for a spec that wants to watch it

Answers a new `{ bb, width_pt, height_pt, release }` -- the note under its
band -- or nil and a reason.

Ownership: on success `opts.result` has been released by the time this
returns, and the caller owns only what comes back. On a refusal nothing has
been released and the result is still the caller's; releasing twice is
harmless either way, because every release in this pipeline is idempotent.
]]
function Header.compose(opts)
    opts = opts or {}
    local result = opts.result
    if type(result) ~= "table" then return nil, "bad_raster" end
    local source = result.bb
    if type(source) ~= "table" and type(source) ~= "userdata"
        and type(source) ~= "cdata" then
        return nil, "bad_raster"
    end
    local BB = opts.Blitbuffer or Blitbuffer
    local w = tonumber(source:getWidth())
    local h = tonumber(source:getHeight())
    if not w or not h or w < 1 or h < 1 then return nil, "bad_raster" end

    -- `Blitbuffer.new` asserts when a page cannot be allocated rather than
    -- answering nil, and this one runs on the job's guarded transition -- but
    -- the ink raster is still the caller's here, and a raise that escaped
    -- would leak it. So the allocation is the one thing taken under pcall.
    local made, bb = pcall(BB.new, w, h + Header.BAND_PX, BB.TYPE_BB8)
    if not made or not bb then
        logger.warn("JustDraw export: no room for a header band:", tostring(bb))
        return nil, "bad_raster"
    end

    bb:fill(BB.COLOR_WHITE)
    bb:blitFrom(source, 0, Header.BAND_PX)
    -- Now, and not at the end: see the module header. Everything below this
    -- line paints into `bb` alone.
    if type(result.release) == "function" then pcall(result.release) end

    bb:paintRect(0, Header.BAND_PX - 1, w, 1, BB.COLOR_GRAY)

    local text = tostring(opts.title or "") .. " · "
        .. tostring(opts.kind_label or "") .. " · "
        .. tostring(opts.location_label or "")
    local max_width = w - 2 * Header.PAD_PX
    if type(opts.paint_text) == "function" and max_width > 0 then
        local y = floor((Header.BAND_PX - Header.TEXT_BOX_PX) / 2)
        -- A band without its line is a page the reader can still read; a raise
        -- out of here would be a page they never get. The ink is what matters.
        local painted, height = pcall(opts.paint_text, bb, Header.PAD_PX, y,
            text, max_width)
        if not painted then
            logger.warn("JustDraw export: header text failed:", tostring(height))
        elseif tonumber(height) and y + tonumber(height) > Header.BAND_PX then
            logger.warn("JustDraw export: header text is taller than its band:",
                tostring(height))
        end
    end

    local released = false
    return {
        bb = bb,
        width_pt = result.width_pt,
        height_pt = (tonumber(result.height_pt) or 0) + Header.BAND_PT,
        release = function()
            if released then return end
            released = true
            bb:free()
        end,
    }
end

--[[--
The production painter: one measured face for the whole export.

`Font:getFace("cfont", size)` runs its size through `Screen:scaleBySize`, so
the same number is a different number of pixels on every device -- and this
band is 118 pixels of a raster, not of the screen. The face is therefore
chosen by building a widget and asking how tall it came out, stepping down
until it fits `TEXT_BOX_PX`, once and then cached: a measurement per page
would cost a font lookup and a layout on every page of the dossier.

Truncation is the widget's: `truncate_with_ellipsis` cuts where the glyphs
actually stop fitting, which is not something the caller can compute.
]]
function Header.textPainter(opts)
    opts = opts or {}
    local box = tonumber(opts.box) or Header.TEXT_BOX_PX
    local TextWidget, Font, face

    -- Resolved at the first line painted rather than here: a painter is built
    -- for every dossier, including in a host that has no widget layer at all,
    -- and `compose` already treats a painter that cannot paint as a lost line
    -- rather than a lost page.
    local function widgets()
        TextWidget = opts.TextWidget or require("ui/widget/textwidget")
        Font = opts.Font or require("ui/font")
    end

    local function measuredFace()
        local size = tonumber(opts.start_size) or Header.START_SIZE
        while size > Header.MIN_SIZE do
            local candidate = Font:getFace("cfont", size)
            local probe = TextWidget:new{ text = "Hgy", face = candidate }
            local height = probe:getSize().h
            probe:free()
            if height <= box then return candidate end
            size = size - 1
        end
        return Font:getFace("cfont", Header.MIN_SIZE)
    end

    return function(bb, x, y, text, max_width)
        if not TextWidget then widgets() end
        if not face then face = measuredFace() end
        local widget = TextWidget:new{
            text = text, face = face, max_width = max_width,
            truncate_with_ellipsis = true,
        }
        local height = widget:getSize().h
        widget:paintTo(bb, x, y)
        widget:free()
        return height
    end
end

return Header
