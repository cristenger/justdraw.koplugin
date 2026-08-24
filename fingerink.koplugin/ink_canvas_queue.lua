--[[--
When a stroke reaches the disk.

Committing on every lift puts a database write in the middle of handwriting.
Committing only on close loses everything the reader wrote this session. So
strokes are held in memory and flushed at the first of four bounds: a quarter
of a second, eight operations, sixty-four kilobytes, or any point KOReader
tells us the session might be about to end.

`onSaveSettings` is the mandatory one, and it is not interchangeable with
`onSuspend`: `Device:_beforeSuspend` calls `UIManager:flushSettings()` and only
*then* emits `Suspend`, so a plugin that saved on suspend would already have
missed its chance. The normal close order emits `SaveSettings` too, before
DocSettings is flushed and the document closed.

Strokes are addressed by a *local* id from the moment they are drawn, because
the row id does not exist until the insert runs. That is what lets an undo of a
still-pending stroke delete its queued insert instead of writing the stroke and
then deleting it, and it means nothing in memory has to learn a new identity
half way through a session.

A failure loses nothing. The queue is kept exactly as it was, further editing
is refused, and the caller is told once so it can offer a retry. Nothing is
marked as written, and no fresh database is reached for.
]]

local logger = require("logger")

local Queue = {}
Queue.__index = Queue

--- Bounds, grouped rather than exposed as preferences. They can be retuned
--- after measuring on hardware, but the window of work that a sudden power
--- loss would cost must never grow without one.
local FLUSH_DELAY = 0.25          -- seconds
local FLUSH_OPS = 8
local FLUSH_BYTES = 64 * 1024

--- Codec header plus four bytes a point, close enough to bound the queue
--- without encoding a stroke twice.
local function estimateBytes(n)
    return 3 + 4 * (tonumber(n) or 0)
end

--[[--
  opts.repository  canvas store: transaction, addStroke, deleteStroke
  opts.schedule    function(delay_seconds, fn) -- UIManager:scheduleIn
  opts.unschedule  function(fn)                -- UIManager:unschedule
  opts.on_error    function(reason), called once per failed flush
]]
function Queue.new(opts)
    return setmetatable({
        repository = opts.repository,
        schedule = opts.schedule,
        unschedule = opts.unschedule,
        on_error = opts.on_error,
        max_ops = opts.max_ops or FLUSH_OPS,
        max_bytes = opts.max_bytes or FLUSH_BYTES,
        delay = opts.delay or FLUSH_DELAY,

        ops = {},
        bytes = 0,
        real = {},          -- local id -> row id, once written
        next_local = 0,
        --- The scheduled flush, kept as the function itself: UIManager:unschedule
        --- matches on the action it was given, and treating scheduleIn's return
        --- value as a handle cancels nothing at all.
        timer = nil,
        failed = false,
        closed = false,
    }, Queue)
end

function Queue:pendingCount()
    return #self.ops
end


function Queue:isFailed()
    return self.failed
end

--- The row id a local id ended up with, or nil while it is still pending.
function Queue:realId(local_id)
    return self.real[local_id]
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
    }
    self.bytes = self.bytes + estimateBytes(stroke.n)
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
function Queue:removeStroke(canvas, local_id)
    if self.closed then return nil, "closed" end
    if self.failed then return nil, "failed" end

    for i = #self.ops, 1, -1 do
        local op = self.ops[i]
        if op.kind == "insert" and op.local_id == local_id then
            table.remove(self.ops, i)
            self.bytes = self.bytes - estimateBytes(op.stroke.n)
            if self.bytes < 0 then self.bytes = 0 end
            if #self.ops == 0 then self:_cancelTimer() end
            return true
        end
    end

    if not self.real[local_id] then return true end
    self.ops[#self.ops + 1] = {
        kind = "delete",
        canvas = canvas,
        local_id = local_id,
    }
    self:_afterChange()
    return true
end

function Queue:_afterChange()
    if #self.ops >= self.max_ops or self.bytes >= self.max_bytes then
        self:flush()
        return
    end
    self:_armTimer()
end

function Queue:_armTimer()
    if self.timer then return end
    local fn
    fn = function()
        if self.timer == fn then self.timer = nil end
        self:flush()
    end
    self.timer = fn
    self.schedule(self.delay, fn)
end

function Queue:_cancelTimer()
    if not self.timer then return end
    self.unschedule(self.timer)
    self.timer = nil
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
    if #self.ops == 0 then return true end

    local ops = self.ops
    local assigned = {}

    local ok, err = self.repository:transaction(function()
        for i = 1, #ops do
            local op = ops[i]
            if op.kind == "insert" then
                local id, e = self.repository:addStroke(op.canvas, op.stroke)
                if not id then return nil, e or "insert failed" end
                assigned[#assigned + 1] = { op.local_id, id }
            else
                local row = self.real[op.local_id]
                if row then
                    local done, e = self.repository:deleteStroke(row)
                    if not done then return nil, e or "delete failed" end
                end
            end
        end
        return true
    end)

    if not ok then
        -- Everything stays exactly where it was. Marking work as durable that
        -- is not is the one outcome worse than losing it loudly.
        self.failed = true
        self.error = err
        logger.err("FingerInk: could not save canvas ink:", err)
        if self.on_error then self.on_error(err) end
        return nil, err
    end

    logger.dbg("FingerInk: canvas commit,", #ops, "operations,", self.bytes, "bytes")
    for i = 1, #assigned do
        self.real[assigned[i][1]] = assigned[i][2]
    end
    for i = #ops, 1, -1 do
        if ops[i].kind == "delete" then self.real[ops[i].local_id] = nil end
    end
    self.ops = {}
    self.bytes = 0
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
    self.closed = true
    if not ok then return nil, err end
    return true
end

return Queue
