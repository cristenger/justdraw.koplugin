--[[--
Where each drawing sheet of a fixed-layout book is: on the page it was made on.

A sheet on a PDF hangs from a page number, not from an xpointer (ADR-67). That
number is durable -- it is the row's own `fixed_page` -- so nothing here has
to be resolved against the document, nothing goes stale on a rerender, and
there is no derived layout cache to keep. What is left of `ink_anchor_index`
is its read contract, which `ink_canvas_session`, the Document notes catalogue
and the export already speak: `get`, `pageOf`, `visibleCanvases`, `add`,
`forget`, a phase and a progress. Giving the session a second class that
answers the same questions is what keeps every caller from growing a branch
on the anchor family.

The rows are still read in batches on a tick, for the reason the anchor index
reads them that way (ADR-42): a synchronous listing at `ReaderReady` is a
stall on the one event the reader is waiting for, and every batch first asks
`can_work`, standing aside for `YIELD_DELAY` while a contact is live. The one
synchronous query is the count, and a count of nothing is the common case --
most PDFs never get a sheet -- so it answers ready without scheduling a single
SELECT (ADR-62: a book costs nothing until it is drawn in).
]]

local Index = {}
Index.__index = Index

--- Rows per metadata tick, the same budget the anchor index uses.
Index.METADATA_BATCH = 200
--- How long a batch stands aside for while a contact is live (ADR-42).
Index.YIELD_DELAY = 0.1

--[[--
  opts.repository  canvas store: countPageSheets, listPageSheets
  opts.book_id     row id from the repository
  opts.schedule    function(fn) -- UIManager:nextTick
  opts.scheduleIn  function(seconds, fn) -- UIManager:scheduleIn
  opts.can_work    function() -> boolean, false while a contact is live
  opts.on_complete function(), once the list is whole
  opts.on_error    function(reason), once, when a batch could not be read
]]
function Index.new(opts)
    return setmetatable({
        repository = opts.repository,
        book_id = opts.book_id,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        can_work = opts.can_work,
        on_complete = opts.on_complete,
        on_error = opts.on_error,
        canvases = {}, by_id = {}, page_of = {}, ids_by_page = {},
        state = "ready", total = 0, after_page = nil, after_id = nil,
        cancelled = false, generation = 0,
    }, Index)
end

function Index:open()
    local total, err = self.repository:countPageSheets(self.book_id)
    if total == nil then return nil, err end
    self.canvases, self.by_id, self.page_of, self.ids_by_page = {}, {}, {}, {}
    self.total, self.after_page, self.after_id = total, nil, nil
    self.cancelled = false
    self.generation = self.generation + 1
    if total == 0 then
        -- Still announced on a tick, as a list that had rows would be: the
        -- session's completion hook places the open sheet and the marks.
        self.state = "ready"
        local generation = self.generation
        self.schedule(function()
            if self.cancelled or generation ~= self.generation then return end
            if self.on_complete then self.on_complete() end
        end)
        return true
    end
    self.state = "metadata"
    self:_scheduleLoad(self.generation, false)
    return true
end

function Index:openEmpty()
    self.canvases, self.by_id, self.page_of, self.ids_by_page = {}, {}, {}, {}
    self.total, self.after_page, self.after_id = 0, nil, nil
    self.state, self.cancelled = "ready", false
    return true
end

--- A rerender moves no page number; there is nothing to rebuild.
function Index:invalidate() end

function Index:cancel()
    self.cancelled = true
    self.generation = self.generation + 1
    self.state = "cancelled"
end

function Index:isComplete() return self.state == "ready" end
--- "metadata" | "ready" | "cancelled".
function Index:phase() return self.state end
function Index:count() return #self.canvases end
function Index:get(id) return self.by_id[id] end
function Index:pageOf(id) return self.page_of[id] end
--- A page number cannot stop resolving, so there are never orphans.
function Index:orphanIds() return {} end

function Index:progress()
    return { phase = self.state, loaded = #self.canvases, total = self.total,
        resolved = #self.canvases, pending = 0 }
end

function Index:metadataBatch(offset, limit)
    local rows = {}
    for i = offset + 1, math.min(#self.canvases, offset + limit) do
        rows[#rows + 1] = self.canvases[i]
    end
    return rows, self:isComplete()
end

function Index:add(canvas, page)
    if not canvas or self.by_id[canvas.id] then return end
    page = tonumber(page or canvas.fixed_page)
    if not page then return end
    self.canvases[#self.canvases + 1] = canvas
    self.by_id[canvas.id] = canvas
    self.page_of[canvas.id] = page
    local ids = self.ids_by_page[page]
    if not ids then
        ids = {}
        self.ids_by_page[page] = ids
    end
    ids[#ids + 1] = canvas.id
end

function Index:forget(id)
    local page = self.page_of[id]
    self.page_of[id], self.by_id[id] = nil, nil
    local ids = page and self.ids_by_page[page]
    if ids then
        for i = #ids, 1, -1 do
            if ids[i] == id then table.remove(ids, i) end
        end
        if #ids == 0 then self.ids_by_page[page] = nil end
    end
    for i = #self.canvases, 1, -1 do
        if self.canvases[i].id == id then table.remove(self.canvases, i) end
    end
end

--- The sheets of this page, in the order they were indexed. A paging reader
--- shows one page at a time (page ink refuses scroll mode for the same
--- reason), so there is no span to walk.
function Index:visibleCanvases(page)
    local out = {}
    for _, id in ipairs(self.ids_by_page[tonumber(page)] or {}) do
        local canvas = self.by_id[id]
        if canvas then out[#out + 1] = canvas end
    end
    return out
end

-- ------------------------------------------------------------------ private

function Index:_defer(fn, yielded)
    if yielded and self.scheduleIn then
        self.scheduleIn(Index.YIELD_DELAY, fn)
    else
        self.schedule(fn)
    end
end

function Index:_fail(reason)
    if self.cancelled or self.state == "cancelled" then return end
    self.state = "cancelled"
    if self.on_error then self.on_error(reason or "list_failed") end
end

function Index:_scheduleLoad(generation, yielded)
    self:_defer(function()
        if self.cancelled or generation ~= self.generation then return end
        if self.can_work and not self.can_work() then
            return self:_scheduleLoad(generation, true)
        end
        local rows, err = self.repository:listPageSheets(self.book_id, {
            after_page = self.after_page,
            after_id = self.after_id,
            limit = Index.METADATA_BATCH,
        })
        if not rows then return self:_fail(err) end
        for _, canvas in ipairs(rows) do self:add(canvas, canvas.fixed_page) end
        if #rows == Index.METADATA_BATCH then
            local last = rows[#rows]
            local page, id = tonumber(last.fixed_page), tonumber(last.id)
            -- A cursor that did not move would ask for the same batch forever.
            if page == self.after_page and id == self.after_id then
                return self:_fail("list_failed")
            end
            self.after_page, self.after_id = page, id
            return self:_scheduleLoad(generation, false)
        end
        self.state = "ready"
        if self.on_complete then self.on_complete() end
    end, yielded)
end

return Index
