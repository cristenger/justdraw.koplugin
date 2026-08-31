--[[--
One writable ink surface, independent of books and widgets.

The surface owns exactly one raster cache and one durability queue.  Book
anchors, notebook navigation and window lifetime stay in their respective
controllers; this module only knows an id and persistent logical geometry.
]]

local Cache = require("ink_canvas_cache")
local Codec = require("ink_canvas_codec")
local Limits = require("ink_limits")
local Queue = require("ink_canvas_queue")

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
        max_open_points = opts.max_open_points or Limits.MAX_OPEN_POINTS,
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
        on_ready = function()
            local synced, sync_err = self:_syncNextSeq()
            if not synced then
                self.load_error = sync_err or "no_seq"
                if self.on_load_error then self.on_load_error(self.load_error, self) end
                notifyState(self)
                return
            end
            self.load_error = nil
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

function SurfaceSession:setTransform(transform)
    if not transform or self.closed then return nil, "closed" end
    local rebuild = self.cache_obj and self.cache_obj:needsRebuild(transform)
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

    local local_id, err = self.queue:addStroke(self.surface_obj, {
        seq = seq, width = width, tool = tool, points = points, n = n,
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
        id = local_id, seq = seq, width = width, tool = tool, point_count = n,
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
    return local_id, nil, painted, left, top, right, bottom
end

function SurfaceSession:beginErase()
    if not self:isReady() then return nil end
    return self.cache_obj:beginErase()
end

function SurfaceSession:endErase(ctx)
    if self.cache_obj then self.cache_obj:endErase(ctx) end
end

--[[--
One eraser sample: cut every stroke the capsule from the previous sample
touched, replacing each with its surviving runs (ADR-32).

Per stroke the replacement is all-or-nothing, built from queue primitives
alone: the fragments are added first -- their pixels are already on the
raster, so painting them again changes nothing visible -- and only when
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
        local box, err = self:_applySplit(hits[i])
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
        local count = range.last - range.first + 1
        local frag = {}
        local at = 0
        for p = range.first, range.last do
            at = at + 1
            frag[at * 2 - 1] = hit.points[p * 2 - 1]
            frag[at * 2] = hit.points[p * 2]
        end
        local frag_id, err = self:addStroke(frag, count, m.width, m.tool)
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
    return self.cache_obj:repair{
        min_x = hit.removed.min_x, min_y = hit.removed.min_y,
        max_x = hit.removed.max_x, max_y = hit.removed.max_y,
        width = m.width,
    }
end

--- Take back fragments whose stroke could not be replaced after all. Their
--- inserts are still pending -- withdrawn without residue -- and their
--- pixels are a subset of the original's, which is still indexed, so the
--- removeStroke repaint restores nothing visibly different. Consumed seq
--- numbers are left as gaps: seq is ordered, never dense.
function SurfaceSession:_withdrawFragments(added)
    for i = #added, 1, -1 do
        self.queue:removeStroke(self.surface_obj, added[i])
        self.cache_obj:removeStroke(added[i])
    end
end

function SurfaceSession:undo()
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
    if self.queue and self.queue:pendingCount() > 0 then
        local saved, save_err = self.queue:flush()
        if not saved then notifyState(self); return nil, save_err end
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
