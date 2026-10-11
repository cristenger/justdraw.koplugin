-- A bounded metadata index for drawing sheets anchored to fixed document pages.
-- It mirrors the read-side contract of ink_anchor_index without resolving
-- xpointers or persisting derived layout data: fixed_page is already durable.
local Index = {}
Index.__index = Index

Index.METADATA_BATCH = 200
Index.YIELD_DELAY = 0.1

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
        state = "ready", total = nil, after_page = nil, after_id = nil,
        cancelled = false, generation = 0,
    }, Index)
end

function Index:_defer(fn, yielded)
    if yielded and self.scheduleIn then
        self.scheduleIn(Index.YIELD_DELAY, fn)
    else
        self.schedule(fn)
    end
end

function Index:_canWork()
    return not self.can_work or self.can_work()
end

function Index:_fail(reason)
    if self.cancelled or self.state == "cancelled" then return end
    self.state = "cancelled"
    if self.on_error then self.on_error(reason or "list_failed") end
end

function Index:open()
    local total, err = self.repository:countPageSheets(self.book_id)
    if total == nil then return nil, err end
    self.canvases, self.by_id, self.page_of, self.ids_by_page = {}, {}, {}, {}
    self.total, self.after_page, self.after_id = total, nil, nil
    self.cancelled = false
    self.state = "metadata"
    self.generation = self.generation + 1
    self:_scheduleLoad(self.generation, false)
    return true
end

function Index:openEmpty()
    self.canvases, self.by_id, self.page_of, self.ids_by_page = {}, {}, {}, {}
    self.total, self.after_page, self.after_id = 0, nil, nil
    self.state, self.cancelled = "ready", false
    return true
end

function Index:_scheduleLoad(generation, yielded)
    self:_defer(function()
        if self.cancelled or generation ~= self.generation then return end
        if not self:_canWork() then
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

function Index:invalidate()
    -- A PDF page number is durable; display changes move no sheet anchor.
end

function Index:cancel()
    self.cancelled = true
    self.generation = self.generation + 1
    self.state = "cancelled"
end

function Index:isComplete() return self.state == "ready" end
function Index:phase() return self.state end
function Index:count() return #self.canvases end
function Index:get(id) return self.by_id[id] end
function Index:pageOf(id) return self.page_of[id] end
function Index:orphanIds() return {} end
function Index:progress()
    return { phase = self.state, loaded = #self.canvases,
        total = self.total, resolved = #self.canvases, pending = 0 }
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
    if not ids then ids = {}; self.ids_by_page[page] = ids end
    ids[#ids + 1] = canvas.id
end

function Index:forget(id)
    local page = self.page_of[id]
    self.page_of[id], self.by_id[id] = nil, nil
    local ids = page and self.ids_by_page[page]
    if ids then
        for i = #ids, 1, -1 do if ids[i] == id then table.remove(ids, i) end end
        if #ids == 0 then self.ids_by_page[page] = nil end
    end
    for i = #self.canvases, 1, -1 do
        if self.canvases[i].id == id then table.remove(self.canvases, i) end
    end
end

function Index:visibleCanvases(page)
    local out = {}
    for _, id in ipairs(self.ids_by_page[tonumber(page)] or {}) do
        local canvas = self.by_id[id]
        if canvas then out[#out + 1] = canvas end
    end
    return out
end

return Index
