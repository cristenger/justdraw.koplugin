--[[--
The ruling on the paper, and why it belongs inside the raster.

A notebook page is not painted, it is *blitted*. Every visible update -- a live
segment, an erase repair, the repaint after a dialog closes -- copies a
rectangle of pixels out of the one BB8 raster `ink_canvas_cache.lua` owns.
Paper drawn anywhere but inside that raster therefore survives exactly until
the first blit lands on it, and the first thing a reader does with ruled paper
is write on it.

So the ruling is composed into the raster together with the ink, and the two
places that clear paper -- the initial fill and the erase repair -- both come
through here. That is what buys the feature: an erase clears its padded box and
puts the ruling back before replaying the neighbouring strokes, a rotation
rebuilds the raster and re-rules it at the new scale, and no hot path, no
refresh budget and no stored coordinate changes at all (ADR-27).

What makes the repair correct is that a mark's position is a pure function of
its index and the scale, never of the region being painted:

    row(k) = floor(k * pitch * scale + 0.5)

Painting any sub-rectangle therefore produces exactly the pixels that
rectangle would have received from a whole-page pass. `tests/paper_spec.lua`
states that as an equality, so a phase that started drifting with the box --
the way a tiled pattern would -- fails there rather than as a seam a reader
finds after erasing a word.

Indices start at 1, not 0: no rule is pinned to the very edge of the sheet,
where it would sit under the paper border the editor draws, and ruled paper
gets its top margin for free.

Pitches are logical units, of which there are `LOGICAL_UNITS_PER_MM` = 8, so
paper ruled at 6 mm is 6 mm on every screen the page is ever fitted to.

Numbers only, like `ink_render.lua`: no tables are created here, by anything,
ever.
]]

local floor = math.floor

local Paper = {}

--[[--
What `notebook_pages.template_kind` may hold.

The repository keeps the same list for a different reason -- it decides what
survives a round trip through SQLite, this decides what can be drawn -- and
`tests/paper_spec.lua` pins them equal, because a kind that persists but does
not draw is a page that silently comes back blank.
]]
Paper.KINDS = {
    blank = true, ruled = true, ruled_narrow = true, grid = true, dots = true,
    checklist = true,
}

--- Ruling pitch in logical units: ruled 6 mm, narrow ruled 5.5 mm, squared
--- and dotted 5 mm, which is what the paper notebooks this imitates use. A
--- checklist row is 8 mm because it has to hold a box and a line of writing
--- beside it. `blank` is absent on purpose; it is the whole of the "nothing
--- to draw" test below.
Paper.PITCH = { ruled = 48, ruled_narrow = 44, grid = 40, dots = 40, checklist = 64 }

--[[--
Below this the ruling stops being paper and becomes texture: at a five-pixel
pitch a one-pixel rule already covers a fifth of the page, and on e-ink that
reads as a dirty screen rather than as a notebook. Such a page is left blank.
The threshold only bites on small screens -- an A5 page fitted to a Kindle
Paperwhite is about 0.4 px per unit, so a 5 mm pitch is still 16 px.
]]
local MIN_PITCH_PX = 8

--- A dot is 0.25 mm of paper and a rule 0.125 mm, neither ever thinner than
--- the one pixel that keeps a hairline from vanishing at small scales, nor
--- thicker than a mark that would start competing with ink.
local DOT_UNITS = 2
local RULE_UNITS = 1
local MAX_MARK_PX = 4

--- A checklist box is 4 mm square, its left edge 6 mm in from the sheet's
--- edge, and it sits 1 mm above its row's rule: the rule is where the item is
--- written, the box is beside it, not on it.
local BOX_UNITS = 32
local BOX_LEFT_UNITS = 48
local BOX_GAP_UNITS = 8

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function markSize(units, scale)
    local size = floor(units * scale + 0.5)
    if size < 1 then return 1 end
    if size > MAX_MARK_PX then return MAX_MARK_PX end
    return size
end

--[[--
Paint one mark, clipped to the *region* and not merely to the buffer.

A repair must not be able to write outside the box it was handed: the caller
has already told the screen which rectangle it is about to refresh, and a
stray pixel beyond it stays on the glass until something unrelated repaints
that area. This is the same reason `ink_canvas_cache` repairs through a
viewport, expressed for a mark that straddles the edge of the box.
]]
local function paintMark(bb, mx, my, mw, mh, x, y, right, bottom, color)
    local left, top = mx, my
    local r, b = mx + mw, my + mh
    if left < x then left = x end
    if top < y then top = y end
    if r > right then r = right end
    if b > bottom then b = bottom end
    if r <= left or b <= top then return false end
    bb:paintRect(left, top, r - left, b - top, color)
    return true
end

--- Horizontal rules spanning the region. `thickness` is already in pixels.
local function paintRows(bb, pitch_px, thickness, x, y, right, bottom, color)
    local first = floor((y - thickness) / pitch_px)
    if first < 1 then first = 1 end
    local last = floor(bottom / pitch_px) + 1
    local painted = false
    for k = first, last do
        if paintMark(bb, x, floor(k * pitch_px + 0.5), right - x, thickness,
            x, y, right, bottom, color) then
            painted = true
        end
    end
    return painted
end

--- Vertical rules spanning the region.
local function paintColumns(bb, pitch_px, thickness, x, y, right, bottom, color)
    local first = floor((x - thickness) / pitch_px)
    if first < 1 then first = 1 end
    local last = floor(right / pitch_px) + 1
    local painted = false
    for j = first, last do
        if paintMark(bb, floor(j * pitch_px + 0.5), y, thickness, bottom - y,
            x, y, right, bottom, color) then
            painted = true
        end
    end
    return painted
end

--- Dots on the intersections, centred on them the way `ink_render` centres a
--- nib, so a dotted page and a ruled page agree about where a line would run.
local function paintDots(bb, pitch_px, size, x, y, right, bottom, color)
    local half = floor(size / 2)
    local first_col = floor((x - size) / pitch_px)
    if first_col < 1 then first_col = 1 end
    local last_col = floor(right / pitch_px) + 1
    local first_row = floor((y - size) / pitch_px)
    if first_row < 1 then first_row = 1 end
    local last_row = floor(bottom / pitch_px) + 1
    local painted = false
    for k = first_row, last_row do
        local top = floor(k * pitch_px + 0.5) - half
        for j = first_col, last_col do
            if paintMark(bb, floor(j * pitch_px + 0.5) - half, top, size, size,
                x, y, right, bottom, color) then
                painted = true
            end
        end
    end
    return painted
end

--[[--
One outlined box per checklist row, drawn with the rules' own thickness.

Every edge is a function of the row index and the scale alone, exactly as the
rules are: the bottom is rounded from its own logical position, never from the
rule's already rounded pixel row, and the side is one rounded length shared by
all four edges so the box stays square in pixels. The vertical edges stop short
of the horizontal ones, so no pixel is written twice.

Rows are bounded from the region the same way `paintRows` bounds them, widened
by the box's reach above its rule, because a box belongs to the rule below it
and a region can hold the box without the rule.

For the same reason a box whose rule would fall off the sheet is not drawn: a
tick box with no line to write on is not a row, it is a stray square at the
foot of the page. `sheet_h` is the buffer's height, which is the page's, so the
cut is a property of the sheet and not of the region -- a repair near the
bottom agrees with the whole-page pass about which is the last row.
]]
local function paintBoxes(bb, pitch, scale, thickness, sheet_h,
                          x, y, right, bottom, color)
    local pitch_px = pitch * scale
    local size = floor(BOX_UNITS * scale + 0.5)
    local left = floor(BOX_LEFT_UNITS * scale + 0.5)
    -- The column of boxes is narrow and most of the page is to its right, so
    -- a region that misses it visits no row at all.
    if left >= right or left + size <= x then return false end
    local reach = (BOX_GAP_UNITS + BOX_UNITS) * scale + 1
    local first = floor(y / pitch_px)
    if first < 1 then first = 1 end
    local last = floor((bottom + reach) / pitch_px) + 1
    local painted = false
    for k = first, last do
        -- Rows only move down the sheet, so the first that is off it ends
        -- the column.
        if floor(k * pitch_px + 0.5) >= sheet_h then break end
        local box_bottom = floor((k * pitch - BOX_GAP_UNITS) * scale + 0.5)
        local top = box_bottom - size
        if paintMark(bb, left, top, size, thickness,
            x, y, right, bottom, color) then painted = true end
        if paintMark(bb, left, box_bottom - thickness, size, thickness,
            x, y, right, bottom, color) then painted = true end
        if paintMark(bb, left, top + thickness, thickness, size - 2 * thickness,
            x, y, right, bottom, color) then painted = true end
        if paintMark(bb, left + size - thickness, top + thickness,
            thickness, size - 2 * thickness,
            x, y, right, bottom, color) then painted = true end
    end
    return painted
end

--[[--
Paint `kind`'s marks over a region the caller has already cleared.

The paper colour stays the caller's business: `_build` fills the whole buffer
and `repair` clears one box, both exactly as they did when every page was
blank, so nothing about a blank page changes by a single write. This adds the
marks and only the marks, in cache coordinates, strictly inside
`[x, x+w) x [y, y+h)`.

Returns whether anything was painted -- false for a blank, unknown or absent
kind, for a pitch too fine to be paper at this scale, and for a region that
does not meet the buffer.
]]
function Paper.paint(bb, kind, scale, x, y, w, h, color)
    -- `color == nil` would be a bug here, not a tidier spelling: a real colour
    -- is cdata whose `__eq` reads `color:getColorRGB32()` off its argument,
    -- and LuaJIT calls that metamethod even against nil. `tests/support.lua`
    -- uses strings for colours and so cannot show it; tests/conformance.lua
    -- states it against a real BlitBuffer.
    if not bb or rawequal(color, nil) then return false end
    local pitch = Paper.PITCH[kind]
    if not pitch then return false end
    if not finite(scale) or scale <= 0 then return false end
    if not finite(x) or not finite(y) or not finite(w) or not finite(h)
        or w <= 0 or h <= 0 then
        return false
    end
    local pitch_px = pitch * scale
    if not finite(pitch_px) or pitch_px < MIN_PITCH_PX then return false end

    -- Bound the region by the buffer before any loop is derived from it, so
    -- the mark count is proportional to the raster and never to a corrupt
    -- rectangle. paintMark stays the authoritative per-write clip.
    local bw, bh = bb:getWidth(), bb:getHeight()
    if not finite(bw) or not finite(bh) or bw < 1 or bh < 1 then return false end
    local right, bottom = x + w, y + h
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if right > bw then right = bw end
    if bottom > bh then bottom = bh end
    if right <= x or bottom <= y then return false end

    if kind == "dots" then
        return paintDots(bb, pitch_px, markSize(DOT_UNITS, scale),
            x, y, right, bottom, color)
    end
    local thickness = markSize(RULE_UNITS, scale)
    local painted = paintRows(bb, pitch_px, thickness, x, y, right, bottom, color)
    if kind == "grid" then
        local columns = paintColumns(bb, pitch_px, thickness,
            x, y, right, bottom, color)
        painted = painted or columns
    elseif kind == "checklist" then
        local boxes = paintBoxes(bb, pitch, scale, thickness, bh,
            x, y, right, bottom, color)
        painted = painted or boxes
    end
    return painted
end

return Paper
