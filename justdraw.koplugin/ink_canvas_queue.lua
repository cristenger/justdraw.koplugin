--[[--
When a stroke reaches the disk.

Committing on every lift puts a database write in the middle of handwriting.
Committing only on close loses everything the reader wrote this session. So
strokes are held in memory and a commit is requested at the first of three
soft bounds: a quarter of a second, eight operations or sixty-four kilobytes.
Thresholds schedule the commit on the next UI tick; they never run SQLite from
the input callback, and -- since ADR-42's rule reached the queue -- never
while a contact is live either: a due flush that finds the pen down puts
itself back for a tenth of a second and asks again. A device session recorded
41 commits of 2.5 to 7.2 ms inside `BTN_TOUCH`, on a loop already losing
input. Lifecycle gates still flush synchronously.

`onSaveSettings` is the mandatory one, and it is not interchangeable with
`onSuspend`: `Device:_beforeSuspend` calls `UIManager:flushSettings()` and only
*then* emits `Suspend`, so a plugin that saved on suspend would already have
missed its chance. The normal close order emits `SaveSettings` too, before
DocSettings is flushed and the document closed.

Strokes start with a negative *local* id because the row id does not exist until
the insert commits. That lets an undo of a still-pending stroke withdraw its
queued insert. After COMMIT, `on_persisted` atomically teaches the cache the
positive SQLite id; reopened strokes already use that positive identity.

A failure loses nothing. The queue is kept exactly as it was, further editing
is refused, and the caller is told once so it can offer a retry. Nothing is
marked as written, and no fresh database is reached for.
]]

local logger = require("logger")
local time = require("ui/time")

local Queue = {}
Queue.__index = Queue

--- Bounds, grouped rather than exposed as preferences. They can be retuned
--- after measuring on hardware, but the window of work that a sudden power
--- loss would cost must never grow without one.
local FLUSH_DELAY = 0.25          -- seconds
local FLUSH_OPS = 8
local FLUSH_BYTES = 64 * 1024
--- A flush that found a contact live asks again this much later: the same
--- tick the sheet index yields on (ADR-42).
local YIELD_DELAY = 0.1
--- The refusal ceiling, sized for a queue that now waits for the lift. One
--- that drained on the next tick could refuse at nine operations; one that
--- holds a whole contact has to carry it, and a partial erase is three
--- operations per hit (ADR-32). The measured worst case is the 18-second
--- erase contact of crash.log 2026-09-02: 103 operations inside one
--- `BTN_TOUCH` bracket. The ceiling is sticky within a contact -- the urgent
--- timer it arms is deferred by the same gate -- so it is set an order of
--- magnitude above that rather than a factor of two, and `HARD_BYTES` stays
--- the bound that actually describes the memory.
local HARD_OPS = 1024
local HARD_BYTES = 1024 * 1024

local function monotonicSeconds()
    return time.now() / time.s(1)
end

--[[--
  opts.repository  canvas store: transaction, addStroke, deleteStroke
  opts.schedule    function(delay_seconds, fn) -- UIManager:scheduleIn
  opts.unschedule  function(fn)                -- UIManager:unschedule
  opts.estimate_insert_bytes function(point_count) -- exact codec footprint
  opts.max_single_op_bytes largest valid insert admitted by the input budget
  opts.on_error    function(reason), called once per failed flush
  opts.on_persisted function(local_id, row_id), after the transaction commits
  opts.can_work    function() -> boolean, false while a contact is live; a
                   due flush that finds one reschedules itself (ADR-42)
  opts.yield_delay seconds between those retries; tests only
]]
function Queue.new(opts)
    opts = opts or {}
    assert(type(opts.estimate_insert_bytes) == "function",
        "estimate_insert_bytes is required")
    local max_single = tonumber(opts.max_single_op_bytes)
    assert(max_single and max_single >= 0 and max_single < math.huge,
        "max_single_op_bytes is required")
    local max_ops = opts.max_ops or FLUSH_OPS
    local max_bytes = opts.max_bytes or FLUSH_BYTES
    --[[--
    The refusal ceiling. A queue that drained on the next tick could sit one
    operation above its soft bound; one that waits for the lift (see
    `flush_action`) has to hold a whole contact, and a partial erase is three
    operations per hit (ADR-32) -- so the defaults are the larger `HARD_*`.
    A caller that names its own soft bound is describing a regime of its own
    and keeps the tight derivation, which is what the specs measure.
    ]]
    local hard_ops = opts.hard_ops
    if hard_ops == nil then
        hard_ops = opts.max_ops and (max_ops + 1) or HARD_OPS
    end
    local hard_bytes = opts.hard_bytes
    if hard_bytes == nil then
        hard_bytes = opts.max_bytes and (max_bytes + max_single) or HARD_BYTES
    end
    local self = setmetatable({
        repository = opts.repository,
        schedule = opts.schedule,
        unschedule = opts.unschedule,
        estimate_insert_bytes = opts.estimate_insert_bytes,
        max_single_op_bytes = max_single,
        on_error = opts.on_error,
        on_persisted = opts.on_persisted,
        on_committed = opts.on_committed,
        max_ops = max_ops,
        max_bytes = max_bytes,
        hard_ops = hard_ops,
        hard_bytes = hard_bytes,
        delay = opts.delay or FLUSH_DELAY,
        clock = opts.clock or monotonicSeconds,
        can_work = opts.can_work,
        yield_delay = opts.yield_delay or YIELD_DELAY,
        deferred = 0,

        ops = {},
        bytes = 0,
        real = {},          -- local id -> row id, once written
        next_local = 0,
        --- The scheduled flush, kept as the function itself: UIManager:unschedule
        --- matches on the action it was given, and treating scheduleIn's return
        --- value as a handle cancels nothing at all.
        timer = nil,
        scheduled_kind = nil,
        scheduled_due = nil,
        failed = false,
        closed = false,
    }, Queue)
    self.flush_action = function()
        -- An action already extracted by the event loop may run after it was
        -- cancelled or after close. Only the currently armed generation owns
        -- the right to flush.
        if self.scheduled_kind == nil then return end
        if not self.closed and self.can_work and not self.can_work() then
            -- A contact is live. No transaction opens under one (ADR-42): a
            -- 5 ms commit is enough to tip an event loop the pen is already
            -- filling at 360 Hz. Keep the armed kind and come back.
            self.deferred = self.deferred + 1
            self.scheduled_due = self.clock() + self.yield_delay
            self.schedule(self.yield_delay, self.flush_action)
            return
        end
        self.timer = nil
        self.scheduled_kind = nil
        self.scheduled_due = nil
        if not self.closed then self:flush() end
    end
    return self
end

function Queue:pendingCount()
    return #self.ops
end

--- How many times a due flush stood aside for a live contact. Diagnostic
--- only; a growing number under the pen is the gate working, not a fault.
function Queue:deferredCount()
    return self.deferred
end


function Queue:isFailed()
    return self.failed
end

--- The row id a local id ended up with, or nil while it is still pending.
function Queue:realId(local_id)
    return self.real[local_id]
end

--- Release a fallback mapping after the cache reconciled an insert that was
--- flushed synchronously before `Session:addStroke` could register it.
function Queue:forgetReal(local_id, row_id)
    if self.real[local_id] == row_id then self.real[local_id] = nil end
end

-- ------------------------------------------------------------------ queuing

--[[--
Hold a finished stroke. Returns its local id, or nil plus a reason.

The points are taken as given; nothing is encoded here, so a lift costs a table
append.
]]
function Queue:addStroke(canvas, stroke)
    if self.closed then return nil, "closed" end
    if self.failed then return nil, "failed" end

    local estimated = self.estimate_insert_bytes(stroke and stroke.n)
    if type(estimated) ~= "number" or estimated ~= estimated
        or estimated < 0 or estimated == math.huge then
        return nil, "bad_stroke"
    end
    if estimated > self.max_single_op_bytes then
        if #self.ops > 0 then self:_armTimer("urgent", 0) end
        return nil, "operation_too_large"
    end
    if #self.ops + 1 > self.hard_ops
        or self.bytes + estimated > self.hard_bytes then
        if #self.ops > 0 then self:_armTimer("urgent", 0) end
        return nil, "queue_backpressure"
    end

    self.next_local = self.next_local + 1
    local local_id = -self.next_local   -- negative, so it can never collide
                                        -- with a SQLite row id
    self.ops[#self.ops + 1] = {
        kind = "insert",
        canvas = canvas,
        canvas_id = canvas.id,
        seq = stroke.seq,
        local_id = local_id,
        stroke = stroke,
        estimated_bytes = estimated,
    }
    self.bytes = self.bytes + estimated
    self:_afterChange()
    return local_id
end

--[[--
Forget a stroke.

A stroke still sitting in the queue has its insert removed outright: writing it
and deleting it again would be two round trips for nothing, and would leave a
row id in the log that never meant anything. One already written gets a delete
keyed by the row it actually created.
]]
function Queue:removeStroke(canvas, id)
    if self.closed then return nil, "closed" end
    if self.failed then return nil, "failed" end

    for i = #self.ops, 1, -1 do
        local op = self.ops[i]
        if op.kind == "insert" and op.local_id == id then
            table.remove(self.ops, i)
            self.bytes = self.bytes - op.estimated_bytes
            if self.bytes < 0 then self.bytes = 0 end
            if #self.ops == 0 then self:_cancelTimer() end
            return true
        end
    end

    local row_id
    if id > 0 then
        row_id = id
    else
        row_id = self.real[id]
    end
    if not row_id then return nil, "unknown_stroke" end
    if #self.ops + 1 > self.hard_ops then
        if #self.ops > 0 then self:_armTimer("urgent", 0) end
        return nil, "queue_backpressure"
    end
    self.ops[#self.ops + 1] = {
        kind = "delete",
        canvas = canvas,
        local_id = id < 0 and id or nil,
        row_id = row_id,
    }
    self:_afterChange()
    return true
end

function Queue:_afterChange()
    if #self.ops >= self.max_ops or self.bytes >= self.max_bytes then
        return self:_armTimer("urgent", 0)
    end
    self:_armTimer("delayed", self.delay)
end

function Queue:_armTimer(kind, delay)
    if self.closed or #self.ops == 0 then return end
    if self.scheduled_kind == "urgent" then return end
    if self.scheduled_kind == "delayed" and kind == "delayed" then return end
    if self.scheduled_kind then self:_cancelTimer() end
    self.timer = self.flush_action
    self.scheduled_kind = kind
    self.scheduled_due = self.clock() + delay
    self.schedule(delay, self.flush_action)
end

function Queue:_cancelTimer()
    if self.timer then self.unschedule(self.timer) end
    self.timer = nil
    self.scheduled_kind = nil
    self.scheduled_due = nil
end

-- ----------------------------------------------------------------- flushing

--[[--
Write everything pending, in one transaction.

Either the whole batch lands or none of it does, which is what makes a retry
safe: there is no half-applied state to reconcile, so retrying is simply
running the same operations again.
]]
function Queue:flush()
    self:_cancelTimer()
    if #self.ops == 0 then
        self.failed = false
        self.error = nil
        return true
    end

    local ops = self.ops
    local assigned = {}
    local touched = {}

    local started = self.clock()
    local ok, err = self.repository:transaction(function()
        for i = 1, #ops do
            local op = ops[i]
            if op.kind == "insert" then
                local id, e = self.repository:addStroke(op.canvas, op.stroke)
                if not id then return nil, e or "insert failed" end
                assigned[#assigned + 1] = { op.local_id, id }
            else
                local done, e = self.repository:deleteStroke(op.row_id)
                if not done then return nil, e or "delete failed" end
            end
            if op.canvas and op.canvas.id ~= nil then
                touched[op.canvas.id] = op.canvas
            end
        end
        if type(self.repository.touchSurface) == "function" then
            for _, surface in pairs(touched) do
                local touched_ok, touch_err = self.repository:touchSurface(surface)
                if not touched_ok then return nil, touch_err or "touch failed" end
            end
        end
        return true
    end)

    local elapsed_ms = (self.clock() - started) * 1000
    if not ok then
        -- Everything stays exactly where it was. Marking work as durable that
        -- is not is the one outcome worse than losing it loudly.
        self.failed = true
        self.error = err
        logger.dbg("JustDraw: canvas commit,", #ops, "operations,",
            self.bytes, "bytes,", elapsed_ms, "ms, failed")
        logger.err("JustDraw: could not save canvas ink:", err)
        if self.on_error then self.on_error(err) end
        return nil, err
    end

    logger.dbg("JustDraw: canvas commit,", #ops, "operations,",
        self.bytes, "bytes,", elapsed_ms, "ms, success")
    for i = 1, #assigned do
        local local_id, row_id = assigned[i][1], assigned[i][2]
        -- Keep the map only when the insert committed before the cache knew
        -- the temporary id. In the normal path the callback rekeys the cache
        -- immediately and retaining one entry per stroke would leak for the
        -- whole document session.
        local reconciled = false
        if self.on_persisted then
            local notified, result, nerr = pcall(self.on_persisted,
                local_id, row_id)
            if not notified then
                logger.err("JustDraw: could not reconcile a persisted canvas stroke:", result)
            elseif result then
                reconciled = true
            elseif nerr and nerr ~= "unknown_stroke" then
                logger.err("JustDraw: could not reconcile a persisted canvas stroke:", nerr)
            end
        end
        if not reconciled then self.real[local_id] = row_id end
    end
    for i = #ops, 1, -1 do
        if ops[i].kind == "delete" and ops[i].local_id then
            self.real[ops[i].local_id] = nil
        end
    end
    self.ops = {}
    self.bytes = 0
    self.failed = false
    self.error = nil
    if self.on_committed then
        local notified, notify_err = pcall(self.on_committed, #ops)
        if not notified then
            logger.err("JustDraw: post-commit callback failed:", notify_err)
        end
    end
    return true
end

--[[--
Throw away everything pending, without writing it.

For one case only: the canvas these operations belong to is being deleted.
Writing strokes into a row that is about to disappear is work for nothing, and
the deletes among them would then target rows that never existed.
]]
function Queue:discard()
    self:_cancelTimer()
    self.ops = {}
    self.bytes = 0
    self.real = {}
    self.failed = false
end

--- Try the same operations again after a failure.
function Queue:retry()
    if #self.ops == 0 then
        self.failed = false
        return true
    end
    self.failed = false
    local ok, err = self:flush()
    if not ok then return nil, err end
    return true
end

--[[--
Last chance: flush, cancel the timer and refuse further work.

Returns nil when the final flush failed, so the caller can tell the reader that
the last few strokes are not durable rather than closing in silence. Nothing
here can promise recovery once the process is gone.
]]
function Queue:close()
    if self.closed then return true end
    local ok, err = self:flush()
    self:_cancelTimer()
    if not ok then return nil, err end
    self.closed = true
    return true
end

return Queue
