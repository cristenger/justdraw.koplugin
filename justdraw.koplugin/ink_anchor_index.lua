--[[--
Where each canvas of this book currently is, without asking the book.

The naive version of this is a call to `isXPointerInCurrentPage` for every
canvas on every repaint. On a book with a few hundred notes that is a CREngine
call per note per page turn, and it is why this module exists.

Instead the mapping from canvas to page is built once per layout and then only
read. A resolved page is *derived data*, keyed by
`getDocumentRenderingHash(true)`: change the font, the margins or the line
spacing and every entry simply becomes a miss. Nothing about a stroke depends
on it, and a wrong entry costs one redundant confirmation, never a misplaced
canvas.

Building it is spread over `UIManager:nextTick` in small batches, so a reader
who opens a heavily annotated book can turn pages while it fills in. Three
things are therefore true of the read path and are covered as such: turning a
page resolves no xpointers, painting issues no query, and the document is only
ever asked to confirm the handful of candidates the map already produced.

A generation counter is what keeps a rerender from mixing two layouts: an
in-flight batch belonging to the previous generation returns without touching
the new in-memory map. Each completed batch may persist its safe derived rows,
but only the final batch prunes older layouts; abandoning a generation can
therefore cost cache misses, never ink or a completed cache.
]]

local logger = require("logger")

local Anchor = require("ink_anchor")

local Index = {}
Index.__index = Index

--[[--
  opts.repository  canvas store: listCanvases, layoutPages, saveLayoutPages
  opts.document    the CreDocument
  opts.book_id     row id from the repository
  opts.batch       anchors resolved per tick (default 8)
  opts.schedule    function(fn) -- UIManager:nextTick
  opts.on_complete function(), after the current generation is fully indexed
]]
function Index.new(opts)
    return setmetatable({
        repository = opts.repository,
        document = opts.document,
        book_id = opts.book_id,
        batch = opts.batch or 8,
        schedule = opts.schedule,
        on_complete = opts.on_complete,

        canvases = {},
        by_id = {},
        page_of = {},
        ids_by_page = {},
        orphans = {},
        pending = {},
        derived = {},

        hash = nil,
        complete = true,
        cancelled = false,
        --- Bumped by every rebuild. A batch from an older generation is stale
        --- and does nothing.
        generation = 0,
    }, Index)
end

--- Read the book's canvas metadata -- no points -- and start placing it.
function Index:open()
    local canvases, err = self.repository:listCanvases(self.book_id)
    if not canvases then
        logger.err("JustDraw: cannot list canvases:", err)
        return nil, err
    end
    -- Copied, not aliased: `add` and `forget` mutate this list, and doing that
    -- to a table the repository still owns would be a change at a distance.
    self.canvases = {}
    self.by_id = {}
    for i = 1, #canvases do
        self.canvases[i] = canvases[i]
        self.by_id[canvases[i].id] = canvases[i]
    end
    self:_rebuild()
    return true
end

function Index:openEmpty()
    self.canvases = {}
    self.by_id = {}
    self.page_of = {}
    self.ids_by_page = {}
    self.orphans = {}
    self.pending = {}
    self.derived = {}
    self.complete = true
    return true
end

--[[--
The layout changed: rebuild the page map.

Only the map. `strokes` is not read, not written and not consulted -- reflow
moves the sheet, never the ink on it.
]]
function Index:invalidate()
    if self.cancelled then return end
    self:_rebuild()
end

function Index:cancel()
    self.cancelled = true
    self.pending = {}
end

function Index:isComplete()
    return self.complete
end

function Index:get(canvas_id)
    return self.by_id[canvas_id]
end

function Index:pageOf(canvas_id)
    return self.page_of[canvas_id]
end

--[[--
Take in a canvas that has just been created.

Placed straight away rather than left for the next rebuild, so the reader's new
sheet is on the page it was made on immediately. It is deliberately not written
into the layout cache: that row will be included in the next bounded rebuild,
and a miss before then only costs one resolution.
]]
function Index:add(canvas, page)
    if self.by_id[canvas.id] then return end
    self.canvases[#self.canvases + 1] = canvas
    self.by_id[canvas.id] = canvas
    if not page then
        local xp = Anchor.resolve(self.document, canvas)
        page = xp and self.document:getPageFromXPointer(xp)
    end
    if page then self:_place(canvas.id, page) end
end

--- Forget a canvas that has been deleted. Every index it appears in, so a
--- stale id cannot come back out of a page lookup.
function Index:forget(canvas_id)
    local page = self.page_of[canvas_id]
    self.page_of[canvas_id] = nil
    self.by_id[canvas_id] = nil
    self.derived[canvas_id] = nil

    local ids = page and self.ids_by_page[page]
    if ids then
        for i = #ids, 1, -1 do
            if ids[i] == canvas_id then table.remove(ids, i) end
        end
        if #ids == 0 then self.ids_by_page[page] = nil end
    end
    for i = #self.canvases, 1, -1 do
        if self.canvases[i].id == canvas_id then table.remove(self.canvases, i) end
    end
    for i = #self.orphans, 1, -1 do
        if self.orphans[i] == canvas_id then table.remove(self.orphans, i) end
    end
end

--- Canvases whose anchor no longer resolves. Kept, never deleted: the text may
--- come back, and a reader's notes are not ours to discard.
function Index:orphanIds()
    local out = {}
    for i = 1, #self.orphans do out[i] = self.orphans[i] end
    return out
end

--[[--
The canvases on the pages currently displayed.

Two steps, and the split is the whole point: the map narrows the book to a
handful of candidates without touching CREngine, and only those candidates are
put to the document. A stale map entry is caught here, which is what lets the
map be a cache rather than a source of truth.
]]
function Index:visibleCanvases(page)
    local doc = self.document
    local span = 1
    if doc.getVisiblePageNumberCount then
        span = doc:getVisiblePageNumberCount() or 1
    end
    if span < 1 then span = 1 end

    local out = {}
    for p = page, page + span - 1 do
        local ids = self.ids_by_page[p]
        if ids then
            for i = 1, #ids do
                local canvas = self.by_id[ids[i]]
                local xp = canvas and Anchor.resolve(doc, canvas)
                if xp and doc:isXPointerInCurrentPage(xp) then
                    out[#out + 1] = canvas
                end
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------ private

function Index:_rebuild()
    self.generation = self.generation + 1
    local generation = self.generation

    self.page_of = {}
    self.ids_by_page = {}
    self.orphans = {}
    self.derived = {}
    self.pending = {}
    self.hash = tostring(self.document:getDocumentRenderingHash(true))

    local cached = self.repository:layoutPages(self.book_id, self.hash) or {}
    for i = 1, #self.canvases do
        local c = self.canvases[i]
        local page = cached[c.id]
        if page then
            self:_place(c.id, page)
        else
            self.pending[#self.pending + 1] = c.id
        end
    end

    if #self.pending == 0 then
        self.complete = true
        self:_notifyComplete()
        return
    end
    self.complete = false
    self:_scheduleBatch(generation)
end

function Index:_place(canvas_id, page)
    self.page_of[canvas_id] = page
    local ids = self.ids_by_page[page]
    if not ids then
        ids = {}
        self.ids_by_page[page] = ids
    end
    ids[#ids + 1] = canvas_id
end

function Index:_scheduleBatch(generation)
    self.schedule(function()
        if self.cancelled or generation ~= self.generation then return end
        self:_resolveBatch(generation)
    end)
end

function Index:_resolveBatch(generation)
    local doc = self.document
    local resolved = {}
    for _ = 1, self.batch do
        local id = table.remove(self.pending)
        if not id then break end
        local canvas = self.by_id[id]
        local xp = canvas and Anchor.resolve(doc, canvas)
        local page = xp and doc:getPageFromXPointer(xp)
        if page then
            self:_place(id, page)
            self.derived[id] = page
            resolved[id] = page
        else
            -- Deliberately not cached. Writing "nowhere" would turn a
            -- temporary miss into a permanent one.
            self.orphans[#self.orphans + 1] = id
        end
    end

    local final = #self.pending == 0
    if self.repository.read_only ~= true
        and (next(resolved) ~= nil or final) then
        -- Persist only this bounded resolution batch. Partial layout rows are
        -- safe derived data: a missing row is resolved again, while one that
        -- landed already belongs to this exact rendering hash. Pruning waits
        -- for the final batch so a half-built generation cannot evict one of
        -- the two useful completed layouts.
        local ok, err = self.repository:saveLayoutPages(
            self.book_id, self.hash, resolved, final)
        if not ok then
            logger.warn("JustDraw: could not cache a canvas page-index batch:", err)
        end
    end

    if not final then
        self:_scheduleBatch(generation)
        return
    end

    self.complete = true
    logger.info("JustDraw: canvas page index ready,", #self.canvases, "canvases,",
        #self.orphans, "orphaned")
    self:_notifyComplete()
end

function Index:_notifyComplete()
    if not self.on_complete then return end
    local ok, err = pcall(self.on_complete)
    if not ok then logger.warn("JustDraw: canvas index completion callback failed:", err) end
end

return Index
