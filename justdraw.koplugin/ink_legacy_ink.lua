--[[--
A read-only view of the direct-ink sidecar store.

On KOReader 2026.07 and newer the sidecar stroke table is frozen (ADR-39).
Every new point in a reflowable book goes on a drawing sheet and every new
point on a fixed layout goes into that page's own ink surface; what is already
in the sidecar stays visible, exportable and deletable, and nothing else.

The freeze could have been a flag on `InkStore`, and that is exactly what this
module exists not to be. A flag has to be consulted, which means every future
caller has to remember it -- and the one that forgets writes screen pixels
into a table nobody can ever map back to a page, silently, on every
`DocSettings:flush` for the life of the book. A wrapper cannot be forgotten:
there is no `add`, no `pop`, no `sweep` and no `hit` to call. Whoever holds an
`InkLegacyInk` can read the ink, count it and delete it on the reader's
explicit instruction, and there is no fourth thing they can do.

Deletion stays here because deleting is not adding: the two "Clear legacy ink"
entries are the only way the frozen table is allowed to change, and keeping
them on the same object is what makes "this is everything that may touch the
sidecar" one sentence rather than two.

`strokes(page)` hands back the store's own list rather than a copy: it is read
on every paint of the page, and this plugin does not allocate on a paint path.
]]

local Legacy = {}
Legacy.__index = Legacy

function Legacy.new(store)
    return setmetatable({ store = store }, Legacy)
end

--- The page's stroke list, or nil. The list is the store's own; callers read
--- it and never hold it past the paint that asked for it.
function Legacy:strokes(page)
    return self.store:get(page)
end

--- Every page that carries ink, in ascending page order.
---
--- Sorted because the two things that read it -- the export's page walk and a
--- reader looking at a list -- both mean "in book order", and `pairs` over the
--- store's sparse table means nothing of the sort.
function Legacy:pages()
    local out = {}
    for page in pairs(self.store.pages) do out[#out + 1] = page end
    table.sort(out)
    return out
end

function Legacy:hasInk(page)
    local list = self.store:get(page)
    return list ~= nil and #list > 0
end

function Legacy:isEmpty()
    return self.store:isEmpty()
end

--- Delete one stored page's ink. Answers whether anything changed, so the
--- caller knows whether a repaint is owed.
function Legacy:clearPage(page)
    return self.store:clearPage(page) and true or false
end

--- Delete the whole book's legacy ink. Answers whether anything changed; the
--- caller is what makes the deletion durable (see `onSaveSettings`, which has
--- to remove both compatibility identities or the ink reappears on reopen).
function Legacy:clearAll()
    if self.store:isEmpty() then return false end
    self.store:clearAll()
    return true
end

return Legacy
