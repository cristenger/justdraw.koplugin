--[[--
One writable ink surface, independent of books and widgets.

The surface owns exactly one raster cache and one durability queue.  Book
anchors, notebook navigation and window lifetime stay in their respective
controllers; this module only knows an id and persistent logical geometry.
]]

local Cache = require("ink_canvas_cache")
local Codec = require("ink_canvas_codec")
local History = require("ink_edit_history")
local Limits = require("ink_limits")
local Queue = require("ink_canvas_queue")
local Style = require("ink_style")
local logger = require("logger")

local SurfaceSession = {}
SurfaceSession.__index = SurfaceSession

--- Union of two cache-coordinate boxes {x, y, w, h}; either may be nil.
local function unionBox(a, b)
    if not a then return b end
    if not b then return a end
    local x = a.x < b.x and a.x or b.x
    local y = a.y < b.y and a.y or b.y
    local ar, ab = a.x + a.w, a.y + a.h
    local br, bb = b.x + b.w, b.y + b.h
    return {
        x = x, y = y,
        w = (ar > br and ar or br) - x,
        h = (ab > bb and ab or bb) - y,
    }
end

local function encodedBytes(n)
    n = tonumber(n)
    if not n or n < 1 or n ~= math.floor(n) then return nil end
    local chunks = 1
    if n > 1 then
        chunks = math.ceil((n - 1) / (Codec.MAX_POINTS - 1))
    end
    return chunks * Codec.HEADER + 4 * (n + chunks - 1)
end

local function notifyState(self)
    if self.on_state_changed then
        self.on_state_changed(self:stateName(), self)
    end
end

function SurfaceSession.new(opts)
    opts = opts or {}
    return setmetatable({
        repository = opts.repository,
        surface_obj = opts.surface,
        transform_obj = opts.transform,
        writable = opts.writable ~= false,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        unschedule = opts.unschedule,
        notify = opts.notify or function() end,
        on_state_changed = opts.on_state_changed,
        on_ready = opts.on_ready,
        on_load_error = opts.on_load_error,
        on_save_error = opts.on_save_error,
        on_save_recovered = opts.on_save_recovered,
        on_durable_change = opts.on_durable_change,
        on_maintenance_needed = opts.on_maintenance_needed,
        on_will_rebuild = opts.on_will_rebuild,
        cache_opts = opts.cache_opts or {},
        queue_opts = opts.queue_opts or {},
        --- function() -> boolean, false while a contact is live. Handed to
        --- the write queue, which never opens a transaction under one
        --- (ADR-42).
        can_work = opts.can_work,
        max_open_points = opts.max_open_points or Limits.MAX_OPEN_POINTS,
        --- Optional (ADR-53). A surface with a history records every edit as
        --- a reversible replacement and gains redo; one without keeps the
        --- legacy undo exactly (page ink).
        history = opts.history,
        --- Something the owner should tell the reader about the history:
        --- `history_stale` after a failed re-attach, `erase_limit` when an
        --- erase contact stopped cutting at its budget.
        on_history_notice = opts.on_history_notice,
        by_key = {},
        cache_obj = nil,
        queue = nil,
        next_seq = nil,
        load_error = nil,
        edited = false,
        maintenance_pending = false,
        opened = false,
        closed = false,
    }, SurfaceSession)
end

function SurfaceSession:surface()
    return self.surface_obj
end

function SurfaceSession:cache()
    return self.cache_obj
end

function SurfaceSession:transform()
    return self.transform_obj
end

function SurfaceSession:isWritable()
    return self.writable and self.repository ~= nil
        and self.repository.read_only ~= true and not self.closed
end

function SurfaceSession:stateName()
    if self.closed then return "closed" end
    if self.queue and self.queue:isFailed() then return "save_failed" end
    if self.load_error then return "load_failed" end
    if self.cache_obj then return self.cache_obj:stateName() end
    return self.opened and "loading" or "closed"
end

function SurfaceSession:isReady()
    return self.cache_obj ~= nil and self.cache_obj:isReady()
        and not self.load_error and not self:saveFailed() and not self.closed
end

function SurfaceSession:_syncNextSeq()
    if not self.cache_obj then return nil, "no_cache" end
    if self.repository and type(self.repository.nextSeq) == "function" then
        local seq, err = self.repository:nextSeq(self.surface_obj.id)
        if not seq then return nil, err or "no_seq" end
        self.next_seq = seq
        return true
    end
    local strokes = self.cache_obj:strokes()
    local last = strokes[#strokes]
    self.next_seq = (last and last.seq or 0) + 1
    return true
end

function SurfaceSession:open()
    if self.closed then return nil, "closed" end
    if self.opened then return true end
    local s = self.surface_obj
    if type(s) ~= "table" or s.id == nil or s.logical_w == nil
        or s.logical_h == nil or not self.repository then
        return nil, "bad_surface"
    end
    self.opened = true

    if self:isWritable() then
        self.queue = Queue.new{
            repository = self.repository,
            schedule = self.scheduleIn,
            unschedule = self.unschedule,
            max_ops = self.queue_opts.max_ops,
            max_bytes = self.queue_opts.max_bytes,
            delay = self.queue_opts.delay,
            hard_ops = self.queue_opts.hard_ops,
            hard_bytes = self.queue_opts.hard_bytes,
            clock = self.queue_opts.clock,
            can_work = self.can_work,
            yield_delay = self.queue_opts.yield_delay,
            estimate_insert_bytes = encodedBytes,
            max_single_op_bytes = encodedBytes(self.max_open_points),
            on_error = function(reason)
                if self.on_save_error then self.on_save_error(reason, self) end
                notifyState(self)
            end,
            on_persisted = function(local_id, row_id)
                if not self.cache_obj then return nil, "no_cache" end
                return self.cache_obj:markPersisted(local_id, row_id)
            end,
            on_committed = function(count)
                if count > 0 and self.on_durable_change then
                    self.on_durable_change(self)
                end
                if self.maintenance_pending then
                    self.maintenance_pending = false
                    if self.on_maintenance_needed then
                        self.on_maintenance_needed(self)
                    end
                end
            end,
        }
    end

    self.cache_obj = Cache.new{
        repository = self.repository,
        surface = s,
        transform = self.transform_obj,
        schedule = self.schedule,
        point_budget = self.cache_opts.point_budget,
        chunk_budget = self.cache_opts.chunk_budget,
        cell = self.cache_opts.cell,
        ink = self.cache_opts.ink,
        background = self.cache_opts.background,
        -- Whether this surface is a page of its own or a transparent layer
        -- over one is the owner's to say; the cache cannot infer it.
        composition = self.cache_opts.composition,
        paper_kind = self.cache_opts.paper_kind,
        clear = self.cache_opts.clear,
        on_ready = function()
            local synced, sync_err = self:_syncNextSeq()
            if not synced then
                self.load_error = sync_err or "no_seq"
                if self.on_load_error then self.on_load_error(self.load_error, self) end
                notifyState(self)
                return
            end
            self.load_error = nil
            self:_bindKeys()
            if self.on_ready then self.on_ready(self) end
            notifyState(self)
        end,
        on_error = function(reason)
            if self.on_load_error then self.on_load_error(reason, self) end
            notifyState(self)
        end,
    }
    local ok, err = self.cache_obj:open()
    notifyState(self)
    if self.load_error then return nil, self.load_error end
    return ok, err
end

--[[--
Hear about a rebuild before it happens: a rotation, a new paper, a reload.
The selection has to put lifted strokes back while the old raster still
exists (§D.6.6) -- after `_build` there is nothing left to repair. Returns a
function that stops listening.
]]
function SurfaceSession:onBeforeRebuild(fn)
    self.rebuild_listeners = self.rebuild_listeners or {}
    local list = self.rebuild_listeners
    list[#list + 1] = fn
    return function()
        for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
    end
end

function SurfaceSession:_beforeRebuild(reason)
    local list = self.rebuild_listeners
    if not list then return end
    for i = #list, 1, -1 do
        local ok, err = pcall(list[i], reason, self)
        if not ok then logger.err("JustDraw: rebuild listener failed:", err) end
    end
end

function SurfaceSession:setTransform(transform)
    if not transform or self.closed then return nil, "closed" end
    local rebuild = self.cache_obj and self.cache_obj:needsRebuild(transform)
    if rebuild then self:_beforeRebuild("transform") end
    if rebuild and self.on_will_rebuild then self.on_will_rebuild(self) end
    self.transform_obj = transform
    if not self.cache_obj then return true end
    local ok, err = self.cache_obj:setTransform(transform)
    notifyState(self)
    if ok == nil and err then return nil, err end
    return true
end

--[[--
Adopt a new paper ruling.

The same shape as `setTransform`, and warned for the same reason: the owner
has to be able to retire an in-flight contact while the old ready raster is
still there to repair it, rather than after the buffer it drew into is gone.
]]
function SurfaceSession:setPaper(kind)
    if self.closed then return nil, "closed" end
    if not self.cache_obj then return true end
    if not self.cache_obj:needsPaperRebuild(kind) then return true end
    self:_beforeRebuild("paper")
    if self.on_will_rebuild then self.on_will_rebuild(self) end
    local ok, err = self.cache_obj:setPaper(kind)
    notifyState(self)
    if ok == nil and err then return nil, err end
    return true
end

function SurfaceSession:addStroke(points, n, width, tool, opts)
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    if type(points) ~= "table" or type(n) ~= "number" or n < 1 then
        return nil, "bad_stroke"
    end
    local valid, validation_err = Codec.validate(points, n,
        self.surface_obj.logical_w, self.surface_obj.logical_h)
    local width, tool = tonumber(width), tonumber(tool)
    if not valid then return nil, validation_err end
    if type(width) ~= "number" or width ~= width or width == math.huge
        or width == -math.huge or width < 0 or type(tool) ~= "number"
        or tool ~= tool or tool == math.huge or tool == -math.huge then
        return nil, "bad_stroke"
    end
    local seq = self.next_seq
    if not seq then return nil, "no_seq" end
    local paint_seq = opts and opts.paint_seq or seq
    if type(paint_seq) ~= "number" or paint_seq ~= paint_seq
        or paint_seq == math.huge or paint_seq < 1
        or paint_seq ~= math.floor(paint_seq) then return nil, "bad_stroke" end

    -- With a history, a drawn stroke is an entry of its own. Its snapshot is
    -- taken before anything is queued, so a stroke the history could not
    -- keep is refused rather than drawn without a way back.
    local snap, key
    local history = self.history
    if history and not (opts and opts.no_record) then
        key = history:newKey()
        local snap_err
        snap, snap_err = History.snapshot({
            key = key, version = 1, points = points, n = n,
            width = width, tool = tool, paint_seq = paint_seq,
        }, self.surface_obj.logical_w, self.surface_obj.logical_h, { clamp = true })
        if not snap then return nil, snap_err end
        local sp, sb = History.costOf({ snap })
        if not history:admits(sp, sb + History.ENTRY_OVERHEAD) then
            return nil, "history_budget"
        end
    elseif history then
        key = history:newKey()
    end

    local local_id, err = self.queue:addStroke(self.surface_obj, {
        seq = seq, paint_seq = paint_seq, width = width, tool = tool, points = points, n = n,
    })
    if not local_id then return nil, err end

    local min_x, min_y = points[1], points[2]
    local max_x, max_y = min_x, min_y
    for i = 2, n do
        local x, y = points[i * 2 - 1], points[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end
    local added, cache_err, painted, left, top, right, bottom =
        self.cache_obj:addStroke({
        id = local_id, seq = seq, paint_seq = paint_seq,
        -- Once COMMIT drops the points, a rebuild decodes this like a stored row.
        codec = Codec.VERSION,
        width = width, tool = tool, point_count = n,
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
    }, points, n, opts)
    if not added then
        self.queue:removeStroke(self.surface_obj, local_id)
        return nil, cache_err
    end

    local row_id = self.queue:realId(local_id)
    if row_id then
        local marked, mark_err = self.cache_obj:markPersisted(local_id, row_id)
        if not marked then return nil, mark_err end
        self.queue:forgetReal(local_id, row_id)
    end
    self.next_seq = seq + 1
    self.edited = true
    if key then
        local meta = self.cache_obj:metaById(row_id or local_id)
        if meta then
            meta.key, meta.version = key, 1
            self.by_key[key] = meta
        end
        if snap then
            local recorded, record_err = history:record{
                label = "draw", before = {}, after = { snap },
            }
            if not recorded then
                logger.warn("JustDraw: history could not keep a stroke:", record_err)
            end
        end
    end
    return local_id, nil, painted, left, top, right, bottom
end

function SurfaceSession:beginErase()
    if not self:isReady() then return nil end
    local ctx = self.cache_obj:beginErase()
    if ctx and self.history then
        -- One contact, one entry (D.1.5). `before` holds strokes that existed
        -- before the contact; `after` holds the fragments still alive. A
        -- fragment the same contact cuts again never existed before it, so it
        -- leaves `after` and never reaches `before`.
        ctx.group = {
            before = {}, before_at = {}, after = {}, after_at = {},
            before_points = 0, before_bytes = 0,
            after_points = 0, after_bytes = 0,
            limited = false,
        }
    end
    return ctx
end

local function groupList(list, at)
    local out = {}
    for i = 1, #list do
        if list[i] and at[list[i].key] == i then out[#out + 1] = list[i] end
    end
    return out
end

--[[--
Close an erase contact. With a history the accepted cuts become one entry --
also when the contact was aborted, since what it already changed is on the
page and must stay reversible. The reservation made while the contact grew
is handed to the entry, never counted twice.
]]
function SurfaceSession:endErase(ctx)
    if self.cache_obj then self.cache_obj:endErase(ctx) end
    local group = ctx and ctx.group
    if not group or group.closed then return end
    group.closed = true
    local history = self.history
    if not history then return end
    local before = groupList(group.before, group.before_at)
    local after = groupList(group.after, group.after_at)
    if #before > 0 or #after > 0 then
        local ok, err = history:record({ label = "erase", before = before, after = after },
            { reserved = true })
        if not ok then logger.warn("JustDraw: erase entry not kept:", err) end
    else
        history:releaseOpen()
    end
    if group.limited and self.on_history_notice then
        self.on_history_notice("erase_limit", self)
    end
end

--[[--
One eraser sample: cut every stroke the capsule from the previous sample
touched, replacing each with its surviving runs (ADR-32).

Per stroke the replacement is all-or-nothing, built from queue primitives
alone: fragments are registered without painting and inherit the original's
visual order (ADR-46). Only when
every one is queued does the original's delete join them. In the flush the
inserts therefore precede the delete inside one transaction, so no power
loss can keep the delete without the fragments. A refusal anywhere
withdraws the fragments and leaves the stroke exactly as it was; the
sample is skipped and the next one retries after the queue's tick.
]]
function SurfaceSession:eraseAt(cx, cy, radius, ctx)
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    local x0, y0 = cx, cy
    if ctx then
        x0 = ctx.sweep_x or cx
        y0 = ctx.sweep_y or cy
        ctx.sweep_x, ctx.sweep_y = cx, cy
    end
    local hits, sweep_err = self.cache_obj:eraseSweep(x0, y0, cx, cy, radius, ctx)
    if not hits then return nil, sweep_err end
    local union = nil
    for i = 1, #hits do
        local box, err
        if self.history and ctx and ctx.group then
            box, err = self:_applySplitRecorded(hits[i], ctx.group)
            if err == "erase_limit" then
                -- Stop cutting, keep what this contact already cut; the
                -- reader hears about it once, at the lift.
                if ctx then ctx.sweep_x, ctx.sweep_y = x0, y0 end
                return union
            end
        else
            box, err = self:_applySplit(hits[i])
        end
        if not box then
            if ctx then ctx.sweep_x, ctx.sweep_y = x0, y0 end
            return union, err
        end
        union = unionBox(union, box)
    end
    return union
end

function SurfaceSession:_applySplit(hit)
    local m = hit.meta
    local added = {}
    for f = 1, #hit.fragments do
        local range = hit.fragments[f]
        local count = range.n or (range.last - range.first + 1)
        local frag = range.points or {}
        if not range.points then
            local at = 0
            for p = range.first, range.last do
                at = at + 1
                frag[at * 2 - 1] = hit.points[p * 2 - 1]
                frag[at * 2] = hit.points[p * 2]
            end
        end
        local frag_id, err = self:addStroke(frag, count, m.width, m.tool, {
            paint_seq = m.paint_seq or m.seq, defer_paint = true,
        })
        if not frag_id then
            self:_withdrawFragments(added)
            return nil, err
        end
        added[#added + 1] = frag_id
        local frag_meta = self.cache_obj:metaById(frag_id)
        if frag_meta then frag_meta.from_erase = true end
    end
    local accepted, remove_err = self.queue:removeStroke(self.surface_obj, m.id)
    if not accepted then
        self:_withdrawFragments(added)
        return nil, remove_err
    end
    if m.id > 0 or self.queue:realId(m.id) then
        self.maintenance_pending = true
    end
    self.cache_obj:forgetStroke(m.id)
    self.edited = true
    -- Interpolated endpoints can change the historical DDA's sampling phase.
    -- Rebuild its full box so live cache and persisted replay cannot diverge.
    local repair = hit.exact and m or hit.removed
    return self.cache_obj:repair{
        min_x = repair.min_x, min_y = repair.min_y,
        max_x = repair.max_x, max_y = repair.max_y,
        width = m.width,
    }
end

--- Take back fragments whose stroke could not be replaced after all. Their
--- inserts are still pending and have never painted. The original remains
--- indexed, so withdrawing them must not touch the raster. Consumed seq
--- numbers are left as gaps: seq is ordered, never dense.
function SurfaceSession:_withdrawFragments(added)
    for i = #added, 1, -1 do
        self.queue:removeStroke(self.surface_obj, added[i])
        self.cache_obj:forgetStroke(added[i])
    end
end

function SurfaceSession:undo()
    if self.history then return self:_historyUndo() end
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    -- Skip erase debris: undo means "take back the last thing I drew",
    -- and a fragment of an older stroke is not that (ADR-32).
    local strokes = self.cache_obj:strokes()
    local last
    for i = #strokes, 1, -1 do
        if not strokes[i].from_erase then last = strokes[i]; break end
    end
    if not last then return nil end
    local was_maintenance = self.maintenance_pending
    if last.id > 0 or self.queue:realId(last.id) then
        self.maintenance_pending = true
    end
    local accepted, err = self.queue:removeStroke(self.surface_obj, last.id)
    if not accepted then self.maintenance_pending = was_maintenance; return nil, err end
    local box, remove_err = self.cache_obj:removeStroke(last.id)
    if not box then return nil, remove_err end
    self.edited = true
    return box or true
end

-- ------------------------------------------------------ replacements (ADR-53)

local function finiteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function boundsOf(points, n)
    local min_x, min_y = points[1], points[2]
    local max_x, max_y = min_x, min_y
    for i = 2, n do
        local x, y = points[i * 2 - 1], points[i * 2]
        if x < min_x then min_x = x elseif x > max_x then max_x = x end
        if y < min_y then min_y = y elseif y > max_y then max_y = y end
    end
    return min_x, min_y, max_x, max_y
end

--- Grow a stroke-shaped canvas box {min_x, min_y, max_x, max_y, width}.
local function growBox(box, min_x, min_y, max_x, max_y, width)
    if not box then
        return { min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
            width = width or 0 }
    end
    if min_x < box.min_x then box.min_x = min_x end
    if min_y < box.min_y then box.min_y = min_y end
    if max_x > box.max_x then box.max_x = max_x end
    if max_y > box.max_y then box.max_y = max_y end
    if (width or 0) > box.width then box.width = width end
    return box
end

--- The live meta that carries a logical key, or nil.
function SurfaceSession:metaByKey(key)
    local m = self.by_key[key]
    if m and self.cache_obj and self.cache_obj:metaById(m.id) == m then return m end
    return nil
end

--- The edit sequence the next stroke will take. Placements put pasted paint
--- orders at or above it, so pasted ink lands above everything on the page.
function SurfaceSession:nextSeq()
    return self.next_seq
end

function SurfaceSession:hasHistory()
    return self.history ~= nil
end

--[[--
Give every loaded stroke its logical key.

Runs after each completed build. A rebuild after a rotation keeps the same
meta tables, so their keys survive and nothing happens. A reopened page hands
its detached history's `row -> key` map back (`History:resolve`); if the page
no longer matches, the history is invalidated and told about -- it is never
resolved "mostly", since a half-mapped history could undo ink it never
recorded. A brand-new history records the loaded strokes as the pre-session
frontier (D.1.9).
]]
function SurfaceSession:_bindKeys()
    local history = self.history
    if not history or not self.cache_obj then return end
    local metas = self.cache_obj:strokes()
    if history.attached == false then
        local resolved = history:resolve(metas)
        if resolved then
            for m, v in pairs(resolved) do m.key, m.version = v.key, v.version end
        else
            history:invalidate("history_stale")
            for i = 1, #metas do metas[i].key = nil end
            if self.on_history_notice then
                self.on_history_notice("history_stale", self)
            end
        end
    end
    local fresh = {}
    self.by_key = {}
    for i = 1, #metas do
        local m = metas[i]
        if not m.key then
            m.key, m.version = history:newKey(), 1
            fresh[#fresh + 1] = m.key
        end
        self.by_key[m.key] = m
    end
    if not history.frontier_initialised then
        history.frontier_initialised = true
        if not history.invalid then history:setFrontier(fresh) end
    end
end

--[[--
Hand the history back to its owner, with the row each live key sits on.

Only a fully persisted surface can do this: a pending insert has no row the
reopened page could recognise it by. The owner flushes first and refuses to
leave the page when that fails (D.1.7).
]]
function SurfaceSession:detachHistory()
    local history = self.history
    if not history then return nil end
    if not self.cache_obj then return nil, "closed" end
    local live = {}
    local metas = self.cache_obj:strokes()
    for i = 1, #metas do
        local m = metas[i]
        local row_id = m.id > 0 and m.id or (self.queue and self.queue:realId(m.id))
        if not row_id or not m.key then return nil, "unsaved" end
        live[row_id] = { key = m.key, version = m.version or 1 }
    end
    history:detach(live)
    self.history = nil
    self.by_key = {}
    return history
end

--[[--
Lift the strokes carrying `keys` off the painted page, or put them back
(ADR-55). Metadata, index entries and pending ids are untouched, so the queue
can still commit and re-key them while they are lifted. Returns the dirty
cache box, true when nothing changed, or nil and a reason.
]]
function SurfaceSession:setStrokesHidden(keys, hidden)
    if not self.cache_obj or not self.cache_obj:isReady() then return nil, "not_ready" end
    local metas = {}
    for i = 1, #keys do
        local m = self:metaByKey(keys[i])
        if m then metas[#metas + 1] = m end
    end
    local box = self.cache_obj:setHidden(metas, hidden and true or false)
    if not box then return true end
    local painted, err = self.cache_obj:repair(box)
    if not painted then return nil, err end
    return painted
end

function SurfaceSession:hideStrokes(keys)
    return self:setStrokesHidden(keys, true)
end

function SurfaceSession:showStrokes(keys)
    return self:setStrokesHidden(keys, false)
end

--- Take a history back after a detach whose close then failed. The metas
--- still carry their keys; nothing has been reloaded.
function SurfaceSession:reattachHistory(history)
    history.live, history.live_count = nil, nil
    history.attached = true
    self.history = history
    self.by_key = {}
    if self.cache_obj then
        local metas = self.cache_obj:strokes()
        for i = 1, #metas do
            if metas[i].key then self.by_key[metas[i].key] = metas[i] end
        end
    end
end

--[[--
Validate one incoming stroke description. `trusted` specs come from the
history's own snapshots, whose points are already the stored quantised
values; everything else -- a move, a paste, a shape -- has to lie inside the
page before it is snapped, because the codec would otherwise clamp it
somewhere it was never painted.
]]
function SurfaceSession:_prepareSpec(spec)
    if type(spec) ~= "table" then return nil, "bad_stroke" end
    local n = spec.n
    if not finiteNumber(n) or n < 1 or n ~= math.floor(n)
        or n > self.max_open_points then return nil, "bad_stroke" end
    if type(spec.points) ~= "table" then return nil, "bad_stroke" end
    local width, tool = tonumber(spec.width), tonumber(spec.tool)
    if not finiteNumber(width) or width < 0 or not finiteNumber(tool)
        or Style.normalize(tool) ~= tool then return nil, "bad_stroke" end
    local w, h = self.surface_obj.logical_w, self.surface_obj.logical_h
    local points, err = Codec.snap(spec.points, n, w, h,
        spec.trusted and { clamp = true } or nil)
    if not points then return nil, err end
    if spec.paint_seq ~= nil and (not finiteNumber(spec.paint_seq)
        or spec.paint_seq < 1 or spec.paint_seq ~= math.floor(spec.paint_seq)) then
        return nil, "bad_stroke"
    end
    if spec.key ~= nil and (not finiteNumber(spec.key) or spec.key < 1) then
        return nil, "bad_stroke"
    end
    if spec.version ~= nil and (not finiteNumber(spec.version) or spec.version < 1) then
        return nil, "bad_stroke"
    end
    return {
        key = spec.key, version = spec.version, points = points, n = n,
        width = width, tool = tool, paint_seq = spec.paint_seq,
    }
end

--[[--
Prepare a replacement without changing anything (D.2 steps 1-2).

Returns a plan, or nil and a reason. Everything that can refuse runs here: the
surface's state, the keys, every point, the history's room for the entry and
the queue's exact cost. After this returns a plan, `_publishPlan` only does
table work.
]]
function SurfaceSession:_prepareReplace(remove_keys, add_specs, opts)
    opts = opts or {}
    if not self.history then return nil, "no_history" end
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    remove_keys, add_specs = remove_keys or {}, add_specs or {}
    if #remove_keys == 0 and #add_specs == 0 then return nil, "empty_edit" end
    local w, h = self.surface_obj.logical_w, self.surface_obj.logical_h

    local removed, removing, remove_ids = {}, {}, {}
    local expect = opts.expect_versions
    for i = 1, #remove_keys do
        local key = remove_keys[i]
        local m = self:metaByKey(key)
        if not m or removing[key] then return nil, "unknown_stroke" end
        if expect and expect[key] ~= nil and expect[key] ~= (m.version or 1) then
            return nil, "stale_version"
        end
        removing[key] = true
        removed[#removed + 1] = m
        remove_ids[#remove_ids + 1] = m.id
    end

    local specs, adding = {}, {}
    for i = 1, #add_specs do
        local spec, err = self:_prepareSpec(add_specs[i])
        if not spec then return nil, err end
        if spec.key then
            if adding[spec.key] or (self:metaByKey(spec.key) and not removing[spec.key]) then
                return nil, "duplicate_key"
            end
            adding[spec.key] = true
        end
        specs[i] = spec
    end

    local seq = self.next_seq
    if not seq then return nil, "no_seq" end
    local inserts = {}
    for i = 1, #specs do
        local spec = specs[i]
        inserts[i] = {
            seq = seq + i - 1, paint_seq = spec.paint_seq or (seq + i - 1),
            width = spec.width, tool = spec.tool, points = spec.points, n = spec.n,
        }
    end

    -- Snapshots of both sides, before anything moves: a stroke that cannot
    -- be read refuses the edit rather than vanishing from it (D.1.3).
    local entry
    if opts.record ~= false then
        local before, after = {}, {}
        for i = 1, #removed do
            local m = removed[i]
            local points, n = self.cache_obj:readPoints(m)
            if not points then return nil, n end
            local snap, err = History.snapshot({
                key = m.key, version = m.version or 1, points = points, n = n,
                width = m.width, tool = m.tool, paint_seq = m.paint_seq or m.seq,
            }, w, h, { clamp = true })
            if not snap then return nil, err end
            before[#before + 1] = snap
        end
        for i = 1, #specs do
            local spec = specs[i]
            local snap, err = History.snapshot({
                key = spec.key or 1, version = spec.version or 1,
                points = spec.points, n = spec.n, width = spec.width,
                tool = spec.tool, paint_seq = inserts[i].paint_seq,
            }, w, h, { clamp = true })
            if not snap then return nil, err end
            after[#after + 1] = snap
        end
        local bp, bb = History.costOf(before)
        local ap, ab = History.costOf(after)
        if not self.history:admits(bp + ap, bb + ab + History.ENTRY_OVERHEAD) then
            return nil, "history_budget"
        end
        entry = { label = opts.label or "edit", before = before, after = after }
    end

    local plan, plan_err = self.queue:prepareBatch(self.surface_obj, remove_ids, inserts)
    if not plan then return nil, plan_err end
    return {
        queue_plan = plan, removed = removed, specs = specs, inserts = inserts,
        entry = entry, repair = opts.repair,
    }
end

--[[--
Publish a prepared plan (D.2 step 3): queue, cache, keys, history and the
edited mark move together, and nothing in here refuses. Painting follows in
`_repaintPlan`, after the edit is accepted.
]]
function SurfaceSession:_publishPlan(plan)
    local ids, err = self.queue:publishBatch(plan.queue_plan)
    if not ids then return nil, err end
    local history = self.history
    for i = 1, #plan.removed do
        local m = plan.removed[i]
        if m.id > 0 or self.queue:realId(m.id) then self.maintenance_pending = true end
        self.cache_obj:forgetStroke(m.id)
        if m.key and self.by_key[m.key] == m then self.by_key[m.key] = nil end
    end
    local metas = {}
    for i = 1, #plan.specs do
        local spec, insert = plan.specs[i], plan.inserts[i]
        local min_x, min_y, max_x, max_y = boundsOf(insert.points, insert.n)
        local key = spec.key or history:newKey()
        local meta = {
            id = ids[i], seq = insert.seq, paint_seq = insert.paint_seq,
            codec = Codec.VERSION, width = insert.width, tool = insert.tool,
            point_count = insert.n,
            min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
            key = key, version = spec.version or 1,
        }
        self.cache_obj:addStroke(meta, insert.points, insert.n, { defer_paint = true })
        local row_id = self.queue:realId(ids[i])
        if row_id then
            self.cache_obj:markPersisted(ids[i], row_id)
            self.queue:forgetReal(ids[i], row_id)
        end
        self.by_key[key] = meta
        metas[i] = meta
        if plan.entry then
            -- The snapshot took a placeholder key; it is the allocated one.
            plan.entry.after[i].key = key
        end
    end
    self.next_seq = self.next_seq + #plan.specs
    self.edited = true
    if plan.entry then
        local recorded, record_err = history:record(plan.entry)
        if not recorded then logger.warn("JustDraw: history entry not kept:", record_err) end
    end
    return metas
end

--- Repaint what a published plan touched. Returns the union cache box, or
--- nil and the repaint error: the edit stays accepted either way (D.2 step 4).
function SurfaceSession:_repaintPlan(plan, metas)
    local removed_box, added_box = plan.repair, nil
    if not removed_box then
        for i = 1, #plan.removed do
            local m = plan.removed[i]
            removed_box = growBox(removed_box, m.min_x, m.min_y, m.max_x, m.max_y, m.width)
        end
    end
    for i = 1, #metas do
        local m = metas[i]
        added_box = growBox(added_box, m.min_x, m.min_y, m.max_x, m.max_y, m.width)
    end
    local union
    for _, box in ipairs({ removed_box or false, added_box or false }) do
        if box then
            local painted, err = self.cache_obj:repair(box)
            if not painted then return union, err or "repaint_failed" end
            union = unionBox(union, painted)
        end
    end
    return union
end

--[[--
Replace the strokes carrying `remove_keys` with `add_specs`, all or nothing.

  add_specs[i]  {points, n, width, tool, paint_seq?, key?, version?, trusted?}
  opts.label    history label ("move", "cut", "paste", "shape", ...)
  opts.record   false for undo/redo, which move existing entries instead
  opts.expect_versions  {[key] = version}; a stale one refuses the edit
  opts.repair   canvas box to repair instead of the removed strokes' boxes

Returns `{accepted = true, metas, box, repaint_error}` or nil and a reason.
A refusal leaves queue, cache, keys, counters and history exactly as they
were. A repaint failure after acceptance does not undo anything: the cache
is failed and blocks further edits until the owner rebuilds it from the
accepted model (D.2). Persistence is the later flush's business.
]]
function SurfaceSession:replaceStrokes(remove_keys, add_specs, opts)
    local plan, err = self:_prepareReplace(remove_keys, add_specs, opts)
    if not plan then return nil, err end
    local metas, publish_err = self:_publishPlan(plan)
    if not metas then return nil, publish_err end
    local box, repaint_err = self:_repaintPlan(plan, metas)
    notifyState(self)
    return { accepted = true, metas = metas, box = box, repaint_error = repaint_err }
end

--[[--
Whether a replacement of this shape fits, flushing first when it would only
fit an emptier queue. Only for deferred work that `can_work()` allows: this
may run a SQLite transaction, which never happens under a contact (ADR-42).
Shares `_prepareReplace` with the edit itself, so the two cannot disagree.
]]
function SurfaceSession:ensureCapacity(remove_keys, add_specs, opts)
    local probe = {}
    for k, v in pairs(opts or {}) do probe[k] = v end
    probe.record = false
    local plan, err = self:_prepareReplace(remove_keys, add_specs, probe)
    if plan then return true end
    if err ~= "queue_backpressure" then return nil, err end
    if self.can_work and not self.can_work() then return nil, "contact_active" end
    local flushed, flush_err = self:flush()
    if not flushed then return nil, flush_err end
    plan, err = self:_prepareReplace(remove_keys, add_specs, probe)
    if not plan then return nil, err end
    return true
end

--[[--
One cut of an erase contact on a surface with a history. The same split as
`_applySplit`, made through the replacement primitive so it is atomic and
recorded into the contact's group. Before each cut the group's final size is
checked in both directions -- undo re-inserts `before`, redo re-inserts
`after` -- against the history's budget and the queue's hard bounds; a cut
whose inverse could never be admitted is not made (D.1.5).
]]
function SurfaceSession:_applySplitRecorded(hit, group)
    if group.limited then return nil, "erase_limit" end
    local m = hit.meta
    local w, h = self.surface_obj.logical_w, self.surface_obj.logical_h
    local frags = {}
    for f = 1, #hit.fragments do
        local range = hit.fragments[f]
        local count = range.n or (range.last - range.first + 1)
        local frag = range.points
        if not frag then
            frag = {}
            local at = 0
            for p = range.first, range.last do
                at = at + 1
                frag[at * 2 - 1] = hit.points[p * 2 - 1]
                frag[at * 2] = hit.points[p * 2]
            end
        end
        frags[f] = {
            points = frag, n = count, width = m.width, tool = m.tool,
            paint_seq = m.paint_seq or m.seq, trusted = true,
        }
    end

    -- What this cut would add to the group.
    local intermediate = group.after_at[m.key] ~= nil
    local before_snap
    if not intermediate then
        local err
        before_snap, err = History.snapshot({
            key = m.key, version = m.version or 1, points = hit.points, n = hit.n,
            width = m.width, tool = m.tool, paint_seq = m.paint_seq or m.seq,
        }, w, h, { clamp = true })
        if not before_snap then return nil, err end
    end
    local frag_snaps, frag_points, frag_bytes = {}, 0, 0
    for f = 1, #frags do
        local snap, err = History.snapshot({
            key = 1, version = 1, points = frags[f].points, n = frags[f].n,
            width = m.width, tool = m.tool, paint_seq = frags[f].paint_seq,
        }, w, h, { clamp = true })
        if not snap then return nil, err end
        frag_snaps[f] = snap
    end
    frag_points, frag_bytes = History.costOf(frag_snaps)
    local bp, bb = 0, 0
    if before_snap then bp, bb = History.costOf({ before_snap }) end
    -- The inverse batches, as they would be after this cut.
    local before_count = #groupList(group.before, group.before_at) + (before_snap and 1 or 0)
    local after_count = #groupList(group.after, group.after_at) + #frags
        - (intermediate and 1 or 0)
    local before_bytes = group.before_bytes + bb
    local after_bytes = group.after_bytes + frag_bytes
    local q = self.queue
    if before_count + after_count > q.hard_ops
        or before_bytes > q.hard_bytes or after_bytes > q.hard_bytes then
        group.limited = true
        return nil, "erase_limit"
    end
    local reserved_bytes = bb + frag_bytes
        + ((group.before_points == 0 and group.after_points == 0)
            and History.ENTRY_OVERHEAD or 0)
    local reserved = self.history:reserveOpen(bp + frag_points, reserved_bytes)
    if not reserved then
        group.limited = true
        return nil, "erase_limit"
    end

    local repair = hit.exact and m or hit.removed
    local plan, err = self:_prepareReplace({ m.key }, frags, {
        record = false,
        repair = { min_x = repair.min_x, min_y = repair.min_y,
            max_x = repair.max_x, max_y = repair.max_y, width = m.width },
    })
    if not plan then
        -- Give the reservation of a cut that was never made back.
        self.history:unreserveOpen(bp + frag_points, reserved_bytes)
        return nil, err
    end
    local metas, publish_err = self:_publishPlan(plan)
    if not metas then return nil, publish_err end
    for i = 1, #metas do metas[i].from_erase = true end

    if intermediate then
        group.after_at[m.key] = nil
    else
        group.before[#group.before + 1] = before_snap
        group.before_at[m.key] = #group.before
        group.before_points = group.before_points + bp
        group.before_bytes = group.before_bytes + bb
    end
    for f = 1, #metas do
        local snap = frag_snaps[f]
        snap.key = metas[f].key
        group.after[#group.after + 1] = snap
        group.after_at[snap.key] = #group.after
    end
    group.after_points = group.after_points + frag_points
    group.after_bytes = group.after_bytes + frag_bytes

    local box, repaint_err = self:_repaintPlan(plan, {})
    if not box and repaint_err then return nil, repaint_err end
    return box
end

--- Take back the pre-session stroke at the frontier (D.1.9).
function SurfaceSession:_undoFrontier(key)
    local m = self:metaByKey(key)
    if not m then
        -- The page no longer matches what the frontier described.
        self.history.frontier = nil
        return nil
    end
    local points, n = self.cache_obj:readPoints(m)
    if not points then return nil, n end
    local snap, err = History.snapshot({
        key = m.key, version = m.version or 1, points = points, n = n,
        width = m.width, tool = m.tool, paint_seq = m.paint_seq or m.seq,
    }, self.surface_obj.logical_w, self.surface_obj.logical_h, { clamp = true })
    if not snap then return nil, err end
    local sp, sb = History.costOf({ snap })
    if not self.history:admits(sp, sb + History.ENTRY_OVERHEAD) then
        return nil, "history_budget"
    end
    -- Room for the redo entry first: once the stroke is gone, nothing may
    -- fail (§D.1.9). A reservation that trimmed the frontier refuses here,
    -- with the stroke still on the page.
    local reservation, reserve_err = self.history:reserveFrontierUndo(snap, key)
    if not reservation then return nil, reserve_err end
    local result, replace_err = self:replaceStrokes({ key }, {}, { record = false })
    if not result then
        self.history:cancelFrontierUndo(reservation)
        return nil, replace_err
    end
    self.history:commitFrontierUndo(reservation)
    return result.box or true
end

local function specsFrom(snaps, w, h)
    local specs = {}
    for i = 1, #snaps do
        local s = snaps[i]
        local points, n = History.points(s, w, h)
        if not points then return nil, n end
        specs[i] = {
            key = s.key, version = s.version, points = points, n = n,
            width = s.width, tool = s.tool, paint_seq = s.paint_seq, trusted = true,
        }
    end
    return specs
end

local function keysAndVersions(snaps)
    local keys, versions = {}, {}
    for i = 1, #snaps do
        keys[i] = snaps[i].key
        versions[snaps[i].key] = snaps[i].version
    end
    return keys, versions
end

--- Reverse one entry through the replacement primitive; `commit` moves the
--- entry across stacks only once the surface accepted the change.
function SurfaceSession:_applyEntry(entry, from, to, commit)
    local w, h = self.surface_obj.logical_w, self.surface_obj.logical_h
    local keys, versions = keysAndVersions(entry[from])
    local specs, err = specsFrom(entry[to], w, h)
    if not specs then return nil, err end
    local result, replace_err = self:replaceStrokes(keys, specs, {
        record = false, expect_versions = versions,
    })
    if not result then return nil, replace_err end
    commit(self.history)
    return result.box or true
end

function SurfaceSession:_historyUndo()
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    local entry = self.history:peekUndo()
    if entry then
        return self:_applyEntry(entry, "after", "before", function(h) h:commitUndo() end)
    end
    local key = self.history:frontierKey()
    if key then return self:_undoFrontier(key) end
    return nil
end

function SurfaceSession:redo()
    if not self.history then return nil end
    if not self:isWritable() then return nil, "read_only" end
    if self:saveFailed() then return nil, "save_failed" end
    if not self:isReady() then return nil, self:stateName() end
    local entry = self.history:peekRedo()
    if not entry then return nil end
    return self:_applyEntry(entry, "before", "after", function(h) h:commitRedo() end)
end

function SurfaceSession:canRedo()
    if not self.history or not self:isReady() or not self:isWritable()
        or self:saveFailed() then return false end
    return self.history:canRedo()
end

function SurfaceSession:repair(min_x, min_y, max_x, max_y, width)
    if not self.cache_obj then return nil end
    return self.cache_obj:repair{
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
        width = width,
    }
end

function SurfaceSession:pendingWrites()
    return self.queue and self.queue:pendingCount() or 0
end

function SurfaceSession:canUndo()
    if not self:isReady() or not self:isWritable() or self:saveFailed()
        or not self.cache_obj then return false end
    if self.history then
        if self.history:canUndo() then return true end
        local key = self.history:frontierKey()
        return key ~= nil and self:metaByKey(key) ~= nil
    end
    local strokes = self.cache_obj:strokes()
    for i = #strokes, 1, -1 do
        if not strokes[i].from_erase then return true end
    end
    return false
end

function SurfaceSession:flush()
    if not self.queue then return true end
    local ok, err = self.queue:flush()
    notifyState(self)
    return ok, err
end

function SurfaceSession:saveFailed()
    return self.queue ~= nil and self.queue:isFailed()
end

function SurfaceSession:retrySave()
    if not self.queue then return true end
    local ok, err = self.queue:retry()
    if ok and self.on_save_recovered then self.on_save_recovered(self) end
    notifyState(self)
    return ok, err
end

function SurfaceSession:retryLoad()
    if not self.cache_obj then return nil, "closed" end
    self:_beforeRebuild("reload")
    if self.queue and self.queue:pendingCount() > 0 then
        local saved, save_err = self.queue:flush()
        if not saved then notifyState(self); return nil, save_err end
    end
    local history = self.history
    if history and history.attached ~= false then
        -- Reopening reads fresh metas from the store. Hand the history the
        -- row each key sits on, so the reload can give the keys back; a
        -- surface that was never fully keyed cannot, and starts over.
        local live, complete = {}, true
        local metas = self.cache_obj:strokes()
        for i = 1, #metas do
            local m = metas[i]
            local row_id = m.id > 0 and m.id or (self.queue and self.queue:realId(m.id))
            if not row_id or not m.key then complete = false; break end
            live[row_id] = { key = m.key, version = m.version or 1 }
        end
        if complete then
            history:detach(live)
        else
            history:invalidate("history_stale")
        end
        self.by_key = {}
    end
    self.load_error = nil
    local ok, err = self.cache_obj:retryOpen()
    notifyState(self)
    if self.load_error then return nil, self.load_error end
    return ok, err
end

function SurfaceSession:close(opts)
    if self.closed then return true end
    opts = opts or {}
    if self.queue then
        if opts.discard then
            self.queue:discard()
        else
            local ok, err = self.queue:close()
            if not ok then notifyState(self); return nil, err end
        end
    end
    if self.cache_obj then self.cache_obj:close() end
    self.queue = nil
    self.cache_obj = nil
    self.next_seq = nil
    self.load_error = nil
    self.closed = true
    notifyState(self)
    return true
end

return SurfaceSession
