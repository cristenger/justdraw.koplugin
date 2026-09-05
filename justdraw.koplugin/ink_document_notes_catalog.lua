-- A cooperative metadata catalogue. It never opens a surface or reads a point.
local Note = require("ink_document_note")
local Catalog = {}
Catalog.__index = Catalog
Catalog.BATCH = 100

function Catalog.new(opts)
    return setmetatable({
        opts = opts,
        items = {},
        by_id = {},
        state = "loading",
        generation = 0,
        selected = {},
        result = {},
        filter = {},
        order = "document",
    }, Catalog)
end

function Catalog:_defer(fn, delay)
    local generation = self.generation
    local run = function()
        if self.closed or generation ~= self.generation then
            return
        end
        local ok, err = pcall(fn)
        if not ok then
            self:_fail(err)
        end
    end
    if delay and self.opts.schedule_in then
        self.opts.schedule_in(delay, run)
    else
        self.opts.schedule(run)
    end
end

function Catalog:_changed()
    if self.opts.changed then
        self.opts.changed(self)
    end
end

function Catalog:_fail(reason)
    self.state, self.error = "error", reason or "list_failed"
    self:_changed()
end

function Catalog:_append(row, kind)
    local note = Note.new {
        kind = kind,
        surface = row,
        repository = self.opts.repository,
        page = kind == "page_ink" and tonumber(row.fixed_page) or nil,
        logical_w = row.logical_w,
        logical_h = row.logical_h,
        units = kind == "page_ink" and self.opts.units or "px",
    }
    if self.by_id[note.id] then
        return
    end
    note.locating = kind == "sheet"
    self.items[#self.items + 1] = note
    self.by_id[note.id] = note
end

function Catalog:start()
    self.generation = self.generation + 1
    self.items, self.by_id, self.result, self.selected = {}, {}, {}, {}
    self.closed, self.state, self.error = false, "loading", nil
    self.busy = false
    self.offset, self.cursor = 0, nil
    self:_changed()
    self:_defer(function()
        self:_load()
    end)
end

function Catalog:_load()
    local opts = self.opts
    if opts.can_work and not opts.can_work() then
        return self:_defer(function()
            self:_load()
        end, 0.1)
    end
    if opts.rolling and opts.index then
        if opts.index:phase() == "cancelled" then
            return self:_fail("index_incomplete")
        end
        local rows, complete = opts.index:metadataBatch(self.offset, Catalog.BATCH)
        for _, row in ipairs(rows) do
            self:_append(row, "sheet")
        end
        self.offset = self.offset + #rows
        self.result = self.items
        self:_changed()
        if not complete or #rows == Catalog.BATCH then
            self.state = #rows == 0 and "locating" or "loading"
            return self:_defer(function()
                self:_load()
            end, #rows == 0 and 0.2 or nil)
        end
    elseif not opts.rolling and opts.repository and opts.book_id then
        local cursor = self.cursor or {}
        local rows, err = opts.repository:listPageInkSurfaces(opts.book_id, {
            limit = Catalog.BATCH,
            after_page = cursor.page,
            after_id = cursor.id,
        })
        if not rows then
            return self:_fail(err)
        end
        for _, row in ipairs(rows) do
            self:_append(row, "page_ink")
        end
        self.result = self.items
        self:_changed()
        if #rows > 0 then
            local last = rows[#rows]
            if cursor.page == last.fixed_page and cursor.id == last.id then
                return self:_fail("list_failed")
            end
            self.cursor = { page = last.fixed_page, id = last.id }
            return self:_defer(function()
                self:_load()
            end)
        end
    end
    self.legacy_pages = opts.legacy and opts.legacy:pages() or {}
    self.legacy_offset = 0
    self:_defer(function()
        self:_legacy()
    end)
end

function Catalog:_legacy()
    local last = math.min(#self.legacy_pages, self.legacy_offset + Catalog.BATCH)
    for i = self.legacy_offset + 1, last do
        local note = Note.new {
            kind = "legacy_page",
            page = self.legacy_pages[i],
            logical_w = self.opts.screen.w,
            logical_h = self.opts.screen.h,
            units = "px",
        }
        self.items[#self.items + 1], self.by_id[note.id] = note, note
    end
    self.legacy_offset = last
    if last < #self.legacy_pages then
        return self:_defer(function()
            self:_legacy()
        end)
    end
    self.legacy_pages = nil
    for _, item in ipairs(self.opts.native or {}) do
        self.items[#self.items + 1], self.by_id[item.id] = item, item
    end
    self.native_offset = 0
    self:_defer(function()
        self:_native()
    end)
end

function Catalog:_native()
    if self.opts.native_batch then
        local rows, total = self.opts.native_batch(self.native_offset, Catalog.BATCH)
        for _, item in ipairs(rows) do
            self.items[#self.items + 1], self.by_id[item.id] = item, item
        end
        self.native_offset = self.native_offset + #rows
        self.result = self.items
        self:_changed()
        if self.native_offset < total then
            return self:_defer(function()
                self:_native()
            end)
        end
    end
    self.enrich_offset = 0
    self:_defer(function()
        self:_enrich()
    end)
end

function Catalog:_enrich()
    local last = math.min(#self.items, self.enrich_offset + Catalog.BATCH)
    for i = self.enrich_offset + 1, last do
        local item = self.items[i]
        if item.kind == "sheet" then
            item.page = self.opts.index:pageOf(item.surface.id)
        end
        item.locating = nil
        item.location_label = Note.locationLabel(item.kind, item.page)
        if item.page and self.opts.chapter then
            local chapter, key, page = self.opts.chapter(item.page)
            item.chapter, item.chapter_key, item.chapter_page = chapter or item.chapter, key, page
        end
    end
    self.enrich_offset = last
    if last < #self.items then
        return self:_defer(function()
            self:_enrich()
        end)
    end
    if self.opts.source_error then
        self.result = self.items
        return self:_fail(self.opts.source_error)
    end
    if self.opts.memberships then
        local memberships, err = self.opts.memberships()
        if not memberships then
            return self:_fail(err)
        end
        self.items = Note.group(self.items, memberships, self.by_id)
        -- A selected independent sheet may have gained a second sheet since
        -- this browser was last open. Transfer selection to its logical note.
        for _, item in ipairs(self.items) do
            for _, sheet in ipairs(item.sheets or {}) do
                if self.selected[sheet.id] then
                    self.selected[item.id] = true
                end
                self.selected[sheet.id] = nil
            end
        end
    end
    self.state = "ready"
    for id in pairs(self.selected) do
        if not self.by_id[id] then
            self.selected[id] = nil
        end
    end
    self:query(self.filter, self.order)
end

function Catalog:query(filter, order)
    if self.state ~= "ready" then
        return nil, "index_incomplete"
    end
    self.filter, self.order = filter or {}, order or "document"
    self.query_generation = (self.query_generation or 0) + 1
    local generation = self.query_generation
    local out, offset = {}, 0
    self.busy = true
    local function filterBatch()
        if generation ~= self.query_generation then
            return
        end
        local last = math.min(#self.items, offset + Catalog.BATCH)
        for i = offset + 1, last do
            local item, f = self.items[i], self.filter
            if
                (not f.kind or f.kind == item.kind)
                and (not f.unlocated or not item.page)
                and (not f.chapter or f.chapter == item.chapter)
                and (not f.chapter_key or f.chapter_key == item.chapter_key)
                and (not f.native or item.native)
                and (not f.search or item.native and require("ink_native_annotations").matches(item, f.search))
                and (not f.first or item.page and item.page >= f.first)
                and (not f.last or item.page and item.page <= f.last)
            then
                out[#out + 1] = item
            end
        end
        offset = last
        if offset < #self.items then
            return self:_defer(filterBatch)
        end
        self:_sort(out, generation)
    end
    self:_changed()
    self:_defer(filterBatch)
    return true
end

-- Bottom-up merge sort yields after BATCH moves, including the final pass.
function Catalog:_sort(items, generation)
    local width, start, dest, left, right, left_end, right_end = 1, 1, {}
    local function before(a, b)
        if self.order == "recent" and (a.updated_at or 0) ~= (b.updated_at or 0) then
            return (a.updated_at or 0) > (b.updated_at or 0)
        end
        return Note.before(a, b)
    end
    local function step()
        if generation ~= self.query_generation then
            return
        end
        local used = 0
        while width < #items and used < Catalog.BATCH do
            if not left then
                left, right = start, start + width
                left_end, right_end =
                    math.min(start + width - 1, #items), math.min(start + width * 2 - 1, #items)
            end
            if left <= left_end or right <= right_end then
                if right > right_end or left <= left_end and before(items[left], items[right]) then
                    dest[#dest + 1], left = items[left], left + 1
                else
                    dest[#dest + 1], right = items[right], right + 1
                end
                used = used + 1
            else
                start, left = start + width * 2, nil
                if start > #items then
                    items, dest, width, start = dest, {}, width * 2, 1
                end
            end
        end
        if width < #items then
            return self:_defer(step)
        end
        self.result, self.busy = items, false
        self:_changed()
    end
    self:_defer(step)
end

function Catalog:toggle(id)
    if self.state ~= "ready" or self.busy or not self.by_id[id] then
        return false
    end
    self.selected[id] = not self.selected[id] or nil
    self:_changed()
    return true
end

function Catalog:selectionCount()
    local n = 0
    for _ in pairs(self.selected) do
        n = n + 1
    end
    return n
end

function Catalog:exportItems(scope)
    if self.state ~= "ready" or self.busy then
        return nil, "index_incomplete"
    end
    local out = {}
    local source = scope == "results" and self.result or self.items
    for _, item in ipairs(source) do
        if scope ~= "selected" or self.selected[item.id] then
            out[#out + 1] = item
        end
    end
    table.sort(out, Note.before)
    if #out == 0 then
        return nil, "empty"
    end
    return out
end

function Catalog:close()
    self.closed, self.generation = true, self.generation + 1
    self.items, self.result, self.by_id, self.selected, self.opts = {}, {}, {}, {}, {}
end

return Catalog
