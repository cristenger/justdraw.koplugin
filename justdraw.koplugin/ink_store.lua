--[[--
Per-page stroke storage.

pages = { [page] = { stroke, stroke, ... } }
stroke = { n = <points>, w = <width>, x1, y1, x2, y2, ... }

This table goes straight into the document sidecar, so it must stay made of
plain numbers and plain tables.
]]

local Split = require("ink_stroke_split")

local Store = {}
Store.__index = Store

function Store.new(pages)
    return setmetatable({ pages = pages or {} }, Store)
end

function Store:get(page)
    return self.pages[page]
end

function Store:add(page, stroke)
    local list = self.pages[page]
    if not list then
        list = {}
        self.pages[page] = list
    end
    list[#list + 1] = stroke
end

--- Remove and return the last stroke on a page, or nil.
function Store:pop(page)
    local list = self.pages[page]
    if not list then return nil end
    local n = #list
    if n == 0 then return nil end
    local s = list[n]
    list[n] = nil
    if n == 1 then self.pages[page] = nil end
    return s
end

function Store:removeAt(page, idx)
    local list = self.pages[page]
    if not list or not list[idx] then return false end
    table.remove(list, idx)
    if #list == 0 then self.pages[page] = nil end
    return true
end

function Store:clearPage(page)
    if not self.pages[page] then return false end
    self.pages[page] = nil
    return true
end

function Store:clearAll()
    self.pages = {}
end

function Store:isEmpty()
    return next(self.pages) == nil
end

function Store:countPages()
    local n = 0
    for _ in pairs(self.pages) do n = n + 1 end
    return n
end

--- Topmost stroke within `r` of (x, y), measured against the drawn segments
--- rather than the sampled points, so a fast stroke's sparse samples leave
--- no gaps the eraser slides through (the fix ADR-7 left noted). Reach grows
--- with the stroke's own width, matching what the canvas engine counts as
--- touching.
function Store.hit(list, x, y, r)
    if not list then return nil end
    for i = #list, 1, -1 do
        local s = list[i]
        local reach = r + (s.w or 0) / 2
        if Split.capsuleHitsRange(s, 1, s.n, x, y, x, y, reach * reach) then
            return i
        end
    end
    return nil
end

--[[--
Sweep an eraser capsule across a page, cutting every stroke it touches.

Fragments keep their stroke's place in the list, so the z-order and what
`pop` means -- the newest thing drawn -- both survive a split. A surviving
run shorter than its stroke's own nib is dropped as dirt. Returns true when
anything changed; the caller owns the repaint.
]]
function Store:sweep(page, x0, y0, x1, y1, r)
    local list = self.pages[page]
    if not list then return false end
    local changed = false
    for i = #list, 1, -1 do
        local s = list[i]
        local reach = r + (s.w or 0) / 2
        local fragments = Split.splitByCapsule(s, s.n, x0, y0, x1, y1,
            reach, s.w or 0)
        if fragments then
            changed = true
            table.remove(list, i)
            for f = #fragments, 1, -1 do
                local range = fragments[f]
                local frag = { n = range.last - range.first + 1, w = s.w, t = s.t }
                local at = 0
                for p = range.first, range.last do
                    at = at + 1
                    frag[at * 2 - 1] = s[p * 2 - 1]
                    frag[at * 2] = s[p * 2]
                end
                table.insert(list, i, frag)
            end
        end
    end
    if changed and #list == 0 then self.pages[page] = nil end
    return changed
end

return Store
