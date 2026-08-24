--[[--
Which strokes are near a place, without looking at all of them.

Erasing and repairing a region after an undo both need the same answer: given a
rectangle, which strokes could possibly touch it? Walking every stroke of the
canvas gives the right answer and makes the cost of one erase grow with the
size of the page.

A uniform grid of cells over the canvas is enough. Each stroke is registered in
every cell its bounding box overlaps, and a query collects the ids in the cells
its own box overlaps. Bounding boxes overlap more often than strokes do, so
this narrows rather than decides: the caller still has to check the candidates
properly. What it buys is that the number of candidates depends on what is
nearby instead of on what the reader has written elsewhere.

The worst case -- every stroke overlapping every other -- is still linear, and
no structure fixes that without more complexity than it is worth. What this
does fix is the ordinary case.

Coordinates are canvas coordinates. Boxes outside the canvas are clamped
rather than dropped: a coordinate a pixel past the edge is a rounding artefact,
and silently indexing it nowhere would make a stroke unerasable.
]]

local floor = math.floor

local Grid = {}
Grid.__index = Grid

--- opts.width, opts.height: canvas geometry. opts.cell: cell edge, in the same
--- units. Chosen once from the screen and kept for the session, so a stroke's
--- cells never have to be recomputed.
function Grid.new(opts)
    local w, h = tonumber(opts.width), tonumber(opts.height)
    local cell = tonumber(opts.cell)
    if not w or not h or not cell or w <= 0 or h <= 0 or cell <= 0 then
        return nil, "bad_geometry"
    end
    return setmetatable({
        width = w,
        height = h,
        cell = cell,
        cols = floor((w - 1) / cell) + 1,
        rows = floor((h - 1) / cell) + 1,
        cells = {},     -- [row * cols + col] = { id, id, ... }
        boxes = {},     -- [id] = { col0, row0, col1, row1 }
    }, Grid)
end

function Grid:_clampCol(x)
    local c = floor(x / self.cell)
    if c < 0 then return 0 end
    if c >= self.cols then return self.cols - 1 end
    return c
end

function Grid:_clampRow(y)
    local r = floor(y / self.cell)
    if r < 0 then return 0 end
    if r >= self.rows then return self.rows - 1 end
    return r
end

function Grid:_span(min_x, min_y, max_x, max_y)
    return self:_clampCol(min_x), self:_clampRow(min_y),
           self:_clampCol(max_x), self:_clampRow(max_y)
end

--- Register a stroke's bounding box. Re-inserting an id replaces its old box,
--- so a caller does not have to remember whether it has seen this stroke.
function Grid:insert(id, min_x, min_y, max_x, max_y)
    if self.boxes[id] then self:remove(id) end
    local c0, r0, c1, r1 = self:_span(min_x, min_y, max_x, max_y)
    self.boxes[id] = { c0, r0, c1, r1 }
    for r = r0, r1 do
        for c = c0, c1 do
            local key = r * self.cols + c
            local bucket = self.cells[key]
            if not bucket then
                bucket = {}
                self.cells[key] = bucket
            end
            bucket[#bucket + 1] = id
        end
    end
end

function Grid:remove(id)
    local box = self.boxes[id]
    if not box then return end
    self.boxes[id] = nil
    for r = box[2], box[4] do
        for c = box[1], box[3] do
            local key = r * self.cols + c
            local bucket = self.cells[key]
            if bucket then
                for i = #bucket, 1, -1 do
                    if bucket[i] == id then table.remove(bucket, i) end
                end
                if #bucket == 0 then self.cells[key] = nil end
            end
        end
    end
end

--[[--
Every stroke id whose bounding box could touch this rectangle, ascending.

Ascending because the two callers want opposite directions -- the eraser wants
the newest stroke first, a repaint wants the oldest -- and one stated order
they can each walk is less surprising than an order that depends on the grid.
]]
function Grid:candidates(min_x, min_y, max_x, max_y)
    local c0, r0, c1, r1 = self:_span(min_x, min_y, max_x, max_y)
    local seen, out = {}, {}
    for r = r0, r1 do
        for c = c0, c1 do
            local bucket = self.cells[r * self.cols + c]
            if bucket then
                for i = 1, #bucket do
                    local id = bucket[i]
                    if not seen[id] then
                        seen[id] = true
                        out[#out + 1] = id
                    end
                end
            end
        end
    end
    table.sort(out)
    return out
end


return Grid
