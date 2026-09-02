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

*Reading* the list is batched for the same reason the resolution is. A book
with a thousand sheets used to put the whole result set in memory in one
synchronous `SELECT` at `ReaderReady`, which is a stall on the one event the
reader is waiting for; instead the rows arrive `METADATA_BATCH` at a time by
id, and `open` returns as soon as the first batch is queued (ADR-42). Until
the list is whole there is nothing worth rebuilding from, so a rerender in the
middle of it is not a second generation -- it is simply the layout the rebuild
after the last batch will read.

Every batch, metadata or resolution, first asks `can_work`. While a contact is
live the answer is no and the batch stands aside for `YIELD_DELAY` without
touching SQLite or CREngine: a blocking query with the pen reporting overflows
evdev and costs the next pen-down (ADR-26).

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

--- Sheet rows per metadata tick. The repository clamps a batch at 500; 200 is
--- a query a slow eMMC answers well inside one tick.
Index.METADATA_BATCH = 200
--- How long a batch stands aside for when the glass is busy. Long enough that
--- a stroke is not interrupted by a query, short enough that a reader who has
--- lifted the pen does not watch the count sit still (ADR-42).
Index.YIELD_DELAY = 0.1

--[[--
  opts.repository  canvas store: countCanvases, listCanvasesBatch,
                   layoutPages, saveLayoutPages
  opts.document    the CreDocument
  opts.book_id     row id from the repository
  opts.batch       anchors resolved per tick (default 8)
  opts.schedule    function(fn) -- UIManager:nextTick
  opts.scheduleIn  function(seconds, fn) -- UIManager:scheduleIn; without one a
                   refused batch simply comes back on the next tick
  opts.can_work    function() -> boolean, false while a contact is live
  opts.on_complete function(), after the current generation is fully indexed
  opts.on_error    function(reason), once, when a batch could not be completed
]]
function Index.new(opts)
    return setmetatable({
        repository = opts.repository,
        document = opts.document,
        book_id = opts.book_id,
        batch = opts.batch or 8,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        can_work = opts.can_work,
        on_complete = opts.on_complete,
        on_error = opts.on_error,

        canvases = {},
        by_id = {},
        page_of = {},
        ids_by_page = {},
        orphans = {},
        pending = {},
        derived = {},

        hash = nil,
        --- "metadata" | "resolving" | "ready" | "cancelled". A fresh index
        --- holds an empty book it has finished with, which is what makes
        --- `isComplete` true before anything opened it.
        state = "ready",
        --- What `countCanvases` answered at open, for progress only. The end
        --- of the listing is an empty or short batch, never this number.
        total = nil,
        --- Cursor into the listing: the last id already loaded.
        after_id = nil,
        --- Canvases placed in this generation, for progress.
        placed = 0,
        cancelled = false,
        --- Bumped by every rebuild. A batch from an older generation is stale
        --- and does nothing.
        generation = 0,
        --- The same idea for the metadata phase, which has no layout of its
        --- own: a second `open` supersedes the batches of the first.
        load_generation = 0,
    }, Index)
end

--[[--
Start reading the book's canvas metadata -- no points -- and return.

The count is the one query that stays synchronous: it is a single aggregate,
it is what progress is reported against, and a book whose sheets cannot even
be counted has nothing to index. Everything after it is a batch on a tick, so
`ReaderReady` costs the same on a book with a thousand sheets as on one with
a single sheet (ADR-42).
]]
function Index:open()
    local total, err = self.repository:countCanvases(self.book_id)
    if not total then
        logger.err("JustDraw: cannot count canvases:", err)
        return nil, err
    end
    -- Copied, not aliased: `add` and `forget` mutate this list, and doing that
    -- to a table the repository still owns would be a change at a distance.
    -- The map goes with it: until the rebuild that follows the last batch,
    -- this index knows where nothing is, and answering from a previous open's
    -- placements would be answering about a book it is no longer holding.
    self.canvases = {}
    self.by_id = {}
    self.page_of = {}
    self.ids_by_page = {}
    self.orphans = {}
    self.pending = {}
    self.derived = {}
    self.total = total
    self.after_id = nil
    self.placed = 0
    self.state = "metadata"
    -- This also retires the resolve batches of the previous open: they carry
    -- the load generation they were built under, and the list they were
    -- resolving is the one the lines above have just emptied.
    self.load_generation = self.load_generation + 1
    self:_scheduleLoad(self.load_generation, false)
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
    self.total = 0
    self.after_id = nil
    self.placed = 0
    self.state = "ready"
    return true
end

--[[--
The layout changed: rebuild the page map.

Only the map. `strokes` is not read, not written and not consulted -- reflow
moves the sheet, never the ink on it.

While the list is still loading there is nothing to rebuild *from*. Resolving
the half of the book that has arrived would put those anchors to CREngine and
then put them to it again as soon as the rest lands, so this is deliberately
not a second generation: the rebuild that always follows the last metadata
batch reads the rendering hash when it runs, which is by then the new layout's
(ADR-42).
]]
function Index:invalidate()
    if self.cancelled then return end
    if self.state == "metadata" then return end
    self:_rebuild()
end

function Index:cancel()
    self.cancelled = true
    self.state = "cancelled"
    self.pending = {}
end

function Index:isComplete()
    return self.state == "ready"
end

--- "metadata" | "resolving" | "ready" | "cancelled".
function Index:phase()
    return self.state
end

--[[--
How far along this build is, for the menu entry the reader is looking at.

A table per call, deliberately: this is read when a menu is opened and never
from paint, from the draw path or from a hit test, and five accessors would be
five things to keep in step.
]]
function Index:progress()
    return {
        phase = self.state,
        loaded = #self.canvases,
        total = self.total,
        resolved = self.placed,
        pending = #self.pending,
    }
end

function Index:get(canvas_id)
    return self.by_id[canvas_id]
end

--- How many canvases this book has, from what the index already holds. The
--- export's menu gate asks on every menu paint, and a repository query there
--- would be a SELECT per frame -- so would a walk of the map, on a book with
--- a thousand sheets. `canvases` is kept equal to the set of known ids by
--- `open`, `openEmpty`, the metadata batches, `add` and `forget`, which makes
--- this a length rather than a count.
function Index:count()
    return #self.canvases
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

--[[--
Next tick, or `YIELD_DELAY` later when the batch stood aside.

The fallback is what keeps an index built without a `scheduleIn` working: it
retries on the next tick instead, which is busier but never wrong. A refused
batch must not run the work and must not drop it either -- an index that gave
up because a finger was on the glass would leave `createHere` refusing for the
rest of the session.
]]
function Index:_defer(run, yielded)
    if yielded and self.scheduleIn then
        self.scheduleIn(Index.YIELD_DELAY, run)
    else
        self.schedule(run)
    end
end

--- False while a contact is live. Asked before the query, not after it: the
--- point is that nothing blocks the process while the pen reports (ADR-26).
function Index:_canWork()
    if not self.can_work then return true end
    return self.can_work() and true or false
end

--[[--
A batch could not be completed.

The index is derived data, and a half-built one is worse than none: the
session turns sheets off for this book rather than let `createHere` answer
from a fraction of them. Said exactly once -- the generation is dead
afterwards, so no later batch can say it again.
]]
function Index:_fail(reason)
    if self.cancelled then return end
    self.cancelled = true
    self.state = "cancelled"
    self.pending = {}
    if not self.on_error then
        logger.err("JustDraw: canvas page index gave up:", reason)
        return
    end
    local ok, err = pcall(self.on_error, reason)
    if not ok then
        logger.warn("JustDraw: canvas index error callback failed:", err)
    end
end

function Index:_scheduleLoad(load_generation, yielded)
    local run
    run = function()
        if self.cancelled or load_generation ~= self.load_generation then return end
        if not self:_canWork() then
            self:_defer(run, true)
            return
        end
        self:_loadBatch(load_generation)
    end
    self:_defer(run, yielded)
end

--[[--
One page of sheet metadata, by id.

Loading ends on a batch shorter than the limit -- which covers the empty one,
and is the only thing an empty batch means. A full batch that did not move the
cursor is a repository answering the same rows forever, and is refused rather
than paged over: the same bargain `ink_export_source` makes with `listPages`.
]]
function Index:_loadBatch(load_generation)
    local rows, err = self.repository:listCanvasesBatch(self.book_id, {
        limit = Index.METADATA_BATCH,
        after_id = self.after_id,
    })
    if not rows then
        logger.err("JustDraw: cannot list canvases:", err)
        return self:_fail("list_failed")
    end
    for i = 1, #rows do
        local canvas = rows[i]
        if not self.by_id[canvas.id] then
            self.canvases[#self.canvases + 1] = canvas
            self.by_id[canvas.id] = canvas
        end
    end

    if #rows >= Index.METADATA_BATCH then
        local last = rows[#rows].id
        if self.after_id ~= nil and last <= self.after_id then
            logger.err("JustDraw: canvas listing did not advance past", last)
            return self:_fail("list_failed")
        end
        self.after_id = last
        self:_scheduleLoad(load_generation, false)
        return
    end
    self:_rebuild()
end

function Index:_rebuild()
    self.generation = self.generation + 1
    local generation = self.generation
    -- The list this rebuild reads belongs to one open. A later `open` empties
    -- it without touching `generation`, so a batch has to carry both.
    local load_generation = self.load_generation

    self.page_of = {}
    self.ids_by_page = {}
    self.orphans = {}
    self.derived = {}
    self.pending = {}
    self.placed = 0
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
        self.state = "ready"
        self:_notifyComplete()
        return
    end
    self.state = "resolving"
    self:_scheduleBatch(generation, load_generation)
end

function Index:_place(canvas_id, page)
    self.page_of[canvas_id] = page
    self.placed = self.placed + 1
    local ids = self.ids_by_page[page]
    if not ids then
        ids = {}
        self.ids_by_page[page] = ids
    end
    ids[#ids + 1] = canvas_id
end

function Index:_scheduleBatch(generation, load_generation)
    local run
    run = function()
        if self.cancelled or generation ~= self.generation
            or load_generation ~= self.load_generation then
            return
        end
        if not self:_canWork() then
            self:_defer(run, true)
            return
        end
        self:_resolveBatch(generation, load_generation)
    end
    self:_defer(run, false)
end

function Index:_resolveBatch(generation, load_generation)
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
        self:_scheduleBatch(generation, load_generation)
        return
    end

    self.state = "ready"
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
