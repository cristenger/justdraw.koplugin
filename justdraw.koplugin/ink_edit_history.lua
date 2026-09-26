--[[--
Reversible edits for one ink surface, and the memory they are allowed to keep.

Every edit on a surface that owns a history is a replacement: some strokes
leave, others arrive (ADR-53). Drawing has nothing before it, erasing has
nothing after it, a move keeps the stroke's logical key with a new version.
Undo puts the `before` side back in place of the `after` side, redo the
reverse, both through `SurfaceSession:replaceStrokes`.

Why snapshots and keys, not references to live metadata: restoring an erased
stroke creates a new cache meta and, after COMMIT, a new row id. SQLite even
reuses a deleted row id for the next insert (`INTEGER PRIMARY KEY` without
AUTOINCREMENT). An entry that pointed at a meta or a row id would therefore,
two undos later, take back the wrong stroke -- `draw A, erase A, undo, undo`
was exactly that failure. Keys are allocated here, never reused, and survive
every re-id; the session maps them to whatever meta is live now.

Why encoded strings: a snapshot holds the stroke's points as the codec's own
chunk blobs. Lua strings are immutable, so nothing the caller does to its
tables afterwards can reach an entry, and the bytes are exactly what the store
holds -- four bytes a point instead of the sixteen a flat Lua array costs.

Without a budget an erase contact on a dense page could retain the page
twice. Entries, points and bytes are bounded per history and, through a
shared pool, across every history the owner keeps alive: the least recently
used histories and oldest entries go first, and a history that lost entries
says so (`trimmed`), which also retires the pre-session undo frontier.
]]

local Codec = require("ink_canvas_codec")

local History = {
    MAX_ENTRIES = 100,
    --- Points retained across every resident history of one pool.
    MAX_POINTS = 65536,
    --- Estimated resident bytes across the pool: 4 bytes a point in the blobs
    --- plus the per-snapshot and per-entry tables (see `costOf`). Measured in
    --- LuaJIT by tests/edit_history_spec.lua's residency case.
    MAX_BYTES = 1024 * 1024,
    MAX_HISTORIES = 8,
    --- Measured in LuaJIT 2.1 (x86_64, GC64): a snapshot's table, its chunk
    --- list and string headers; an entry's own tables. See the residency case.
    SNAPSHOT_OVERHEAD = 600,
    ENTRY_OVERHEAD = 900,
}
History.__index = History

local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- ------------------------------------------------------------------ pool

local Pool = {}
Pool.__index = Pool

--[[--
The memory every history of one owner shares.

Reserving evicts the oldest entries of the least recently used histories
before touching the requester's own, and refuses only what cannot fit even
into an empty pool.
]]
function History.newPool(opts)
    opts = opts or {}
    return setmetatable({
        max_points = opts.max_points or History.MAX_POINTS,
        max_bytes = opts.max_bytes or History.MAX_BYTES,
        max_histories = opts.max_histories or History.MAX_HISTORIES,
        members = {},       -- least recently used first
        points = 0,
        bytes = 0,
    }, Pool)
end

function Pool:touch(h)
    for i = #self.members, 1, -1 do
        if self.members[i] == h then table.remove(self.members, i); break end
    end
    self.members[#self.members + 1] = h
end

function Pool:remove(h)
    for i = #self.members, 1, -1 do
        if self.members[i] == h then table.remove(self.members, i); break end
    end
end

function Pool:_add(points, bytes)
    self.points = self.points + points
    self.bytes = self.bytes + bytes
end

function Pool:_sub(points, bytes)
    self.points = self.points - points
    self.bytes = self.bytes - bytes
    if self.points < 0 then self.points = 0 end
    if self.bytes < 0 then self.bytes = 0 end
end

function Pool:fits(points, bytes)
    return self.points + points <= self.max_points
        and self.bytes + bytes <= self.max_bytes
end

--[[--
The one pool every owner in this process shares: notebook pages and document
sheets together. Eight resident histories and one memory budget for all of
them -- a pool per owner would multiply the budget by the number of owners.
]]
local shared_pool
function History.sharedPool()
    if not shared_pool then shared_pool = History.newPool() end
    return shared_pool
end

--- Tests only: forget the shared pool so a case starts from nothing.
function History.resetSharedPool()
    shared_pool = nil
end

--- Make room for `points`/`bytes` on behalf of `h`, evicting what it must.
--- Returns true, or nil and "entry_too_large" when not even an empty pool
--- could hold it -- the caller refuses the edit before changing anything.
function Pool:reserve(h, points, bytes)
    if points > self.max_points or bytes > self.max_bytes then
        return nil, "entry_too_large"
    end
    while not self:fits(points, bytes) do
        local evicted = false
        -- Other histories first, least recently used first.
        for i = 1, #self.members do
            local m = self.members[i]
            if m ~= h and m:_dropOldest() then evicted = true; break end
        end
        if not evicted and not h:_dropOldest() then
            return nil, "entry_too_large"
        end
    end
    self:_add(points, bytes)
    return true
end

--- Drop whole histories beyond the resident count. Returns the evicted ones
--- so the owner can forget their identities.
function Pool:enforceCount(keep)
    local evicted = {}
    while #self.members > self.max_histories do
        local victim
        for i = 1, #self.members do
            if self.members[i] ~= keep then victim = self.members[i]; break end
        end
        if not victim then break end
        victim:release()
        evicted[#evicted + 1] = victim
    end
    return evicted
end

-- ------------------------------------------------------------- snapshots

local function costOf(snaps)
    local points, bytes = 0, 0
    for i = 1, #snaps do
        local s = snaps[i]
        points = points + s.n
        bytes = bytes + History.SNAPSHOT_OVERHEAD
        for c = 1, #s.chunks do bytes = bytes + #s.chunks[c] end
    end
    return points, bytes
end
History.costOf = costOf

--[[--
An immutable picture of one stroke.

  spec.key, spec.version  logical identity (required)
  spec.points, spec.n     flat coordinates
  spec.width, spec.tool, spec.paint_seq
  logical_w, logical_h    the surface geometry the codec normalises to
  opts.clamp              record existing ink as stored (see Codec.snap)

Returns a snapshot or nil plus a reason; nothing is retained from `spec`.
]]
function History.snapshot(spec, logical_w, logical_h, opts)
    if type(spec) ~= "table" then return nil, "bad_snapshot" end
    local key, version = spec.key, spec.version or 1
    if not finite(key) or key < 1 or key ~= floor(key)
        or not finite(version) or version < 1 or version ~= floor(version) then
        return nil, "bad_snapshot"
    end
    local width, tool = tonumber(spec.width), tonumber(spec.tool)
    if not finite(width) or width < 0 or not finite(tool) then
        return nil, "bad_snapshot"
    end
    local paint_seq = spec.paint_seq
    if paint_seq ~= nil and (not finite(paint_seq) or paint_seq < 1
        or paint_seq ~= floor(paint_seq)) then return nil, "bad_snapshot" end
    local n = spec.n
    if not (opts and opts.clamp) then
        local snapped, snap_err = Codec.snap(spec.points, n, logical_w, logical_h)
        if not snapped then return nil, snap_err end
    end
    local encoded, err = Codec.encode(spec.points, n, logical_w, logical_h)
    if not encoded then return nil, err end
    local chunks = {}
    for i = 1, #encoded do chunks[i] = encoded[i].points end
    return {
        key = key, version = version, n = n,
        width = width, tool = tool, paint_seq = paint_seq,
        chunks = chunks,
    }
end

--- Fresh points for a snapshot, decoded from its blobs. A new table on every
--- call, so no two holders ever share one.
function History.points(snap, logical_w, logical_h)
    local chunks = {}
    for i = 1, #snap.chunks do chunks[i] = { points = snap.chunks[i] } end
    local points, n = Codec.join(chunks, logical_w, logical_h)
    if not points then return nil, n end
    if n ~= snap.n then return nil, "snapshot_count" end
    return points, n
end

--- A caller-owned copy of a snapshot's description. The chunk strings are
--- immutable and shared; the tables around them are not.
local function copySnap(s)
    local chunks = {}
    for i = 1, #s.chunks do chunks[i] = s.chunks[i] end
    return {
        key = s.key, version = s.version, n = s.n, width = s.width,
        tool = s.tool, paint_seq = s.paint_seq, chunks = chunks,
    }
end

local function copyEntry(e)
    local before, after = {}, {}
    for i = 1, #e.before do before[i] = copySnap(e.before[i]) end
    for i = 1, #e.after do after[i] = copySnap(e.after[i]) end
    return { label = e.label, before = before, after = after }
end

-- --------------------------------------------------------------- history

--[[--
  opts.pool         shared History.newPool (default: a private one)
  opts.max_entries  both stacks together (default 100)
  opts.identity     anything the owner uses to recognise the surface again
]]
function History.new(opts)
    opts = opts or {}
    local self = setmetatable({
        pool = opts.pool or History.newPool(),
        max_entries = opts.max_entries or History.MAX_ENTRIES,
        identity = opts.identity,
        undo_stack = {},
        redo_stack = {},
        next_key = 0,
        trimmed = false,
        invalid = nil,
        frontier = nil,
        -- A detached history remembers which live row carries which key.
        live = nil,
        attached = true,
        released = false,
        open_points = 0,
        open_bytes = 0,
    }, History)
    self.pool:touch(self)
    return self
end

function History:newKey()
    self.next_key = self.next_key + 1
    return self.next_key
end

function History:entryCount()
    return #self.undo_stack + #self.redo_stack
end

function History:isTrimmed()
    return self.trimmed
end

--- Cost of what this history holds, open group included.
function History:retained()
    local points, bytes = self.open_points, self.open_bytes
    for _, stack in ipairs({ self.undo_stack, self.redo_stack }) do
        for i = 1, #stack do
            points = points + stack[i].points
            bytes = bytes + stack[i].bytes
        end
    end
    return points, bytes
end

function History:_releaseEntry(e)
    self.pool:_sub(e.points, e.bytes)
end

--- Evict the oldest entry, redo side last. Returns whether one went.
function History:_dropOldest()
    local e
    if #self.undo_stack > 0 then
        e = table.remove(self.undo_stack, 1)
    elseif #self.redo_stack > 0 then
        -- The oldest redo is the deepest one, at the bottom of the stack.
        e = table.remove(self.redo_stack, 1)
    end
    if not e then return false end
    self:_releaseEntry(e)
    self.trimmed = true
    self.frontier = nil
    return true
end

local function clearStack(self, stack)
    for i = #stack, 1, -1 do
        self:_releaseEntry(stack[i])
        stack[i] = nil
    end
end

--- Whether an entry of this size could be recorded at all.
function History:admits(points, bytes)
    return points <= self.pool.max_points and bytes <= self.pool.max_bytes
end

--[[--
Reserve room for part of an entry that is still being built -- the growing
group of one erase contact. The reservation is counted immediately, so the
pool never promises the same bytes twice, and adopted by `record` with
`opts.reserved`.
]]
function History:reserveOpen(points, bytes)
    if self.open_points + points > self.pool.max_points
        or self.open_bytes + bytes > self.pool.max_bytes then
        return nil, "entry_too_large"
    end
    local ok, err = self.pool:reserve(self, points, bytes)
    if not ok then return nil, err end
    self.open_points = self.open_points + points
    self.open_bytes = self.open_bytes + bytes
    return true
end

--- Give back part of an open reservation for a cut that was never made.
function History:unreserveOpen(points, bytes)
    points = math.min(points, self.open_points)
    bytes = math.min(bytes, self.open_bytes)
    self.open_points = self.open_points - points
    self.open_bytes = self.open_bytes - bytes
    self.pool:_sub(points, bytes)
end

function History:releaseOpen()
    self.pool:_sub(self.open_points, self.open_bytes)
    self.open_points, self.open_bytes = 0, 0
end

--[[--
Push an accepted edit. `entry = {label, before = {snap...}, after = {snap...}}`.

Accepting an edit invalidates redo (D.1.8) -- the caller records only accepted
edits, so a refused or no-op action never gets here. Returns true, or nil and
a reason when the entry cannot be kept; the caller checks `admits` first, so
that is a refusal made before the surface changed.
]]
function History:record(entry, opts)
    if self.released then return nil, "released" end
    local points, bytes = 0, History.ENTRY_OVERHEAD
    local bp, bb = costOf(entry.before or {})
    local ap, ab = costOf(entry.after or {})
    points = bp + ap
    bytes = bytes + bb + ab
    local stored = {
        label = entry.label or "edit",
        before = entry.before or {},
        after = entry.after or {},
        points = points,
        bytes = bytes,
    }
    clearStack(self, self.redo_stack)
    if opts and opts.reserved then
        -- The open group already holds its reservation; settle the difference.
        self.pool:_sub(self.open_points, self.open_bytes)
        self.open_points, self.open_bytes = 0, 0
    end
    local ok, err = self.pool:reserve(self, points, bytes)
    if not ok then return nil, err end
    self.pool:touch(self)
    self.undo_stack[#self.undo_stack + 1] = stored
    while #self.undo_stack + #self.redo_stack > self.max_entries do
        self:_dropOldest()
    end
    return true
end

function History:canUndo()
    return #self.undo_stack > 0
end

function History:canRedo()
    return #self.redo_stack > 0
end

--- A caller-owned copy of the entry undo would reverse, or nil.
function History:peekUndo()
    local e = self.undo_stack[#self.undo_stack]
    return e and copyEntry(e) or nil
end

function History:peekRedo()
    local e = self.redo_stack[#self.redo_stack]
    return e and copyEntry(e) or nil
end

--- Move the top entry across only once the surface accepted the reversal.
function History:commitUndo()
    local e = table.remove(self.undo_stack)
    if e then self.redo_stack[#self.redo_stack + 1] = e end
    return e ~= nil
end

function History:commitRedo()
    local e = table.remove(self.redo_stack)
    if e then self.undo_stack[#self.undo_stack + 1] = e end
    return e ~= nil
end

-- ------------------------------------------------------ pre-session frontier

--[[--
Strokes that existed before this history started, in edit order.

Once the session's own edits are all undone, undo may keep taking back these,
newest first, exactly as the legacy undo did -- but only while the history is
whole: after trimming or invalidation the frontier is gone, because the state
it described may no longer be the one on the page (D.1.9).
]]
function History:setFrontier(keys)
    local copy = {}
    for i = 1, #keys do copy[i] = keys[i] end
    self.frontier = copy
end

function History:frontierKey()
    if self.trimmed or self.invalid or not self.frontier
        or #self.undo_stack > 0 then return nil end
    return self.frontier[#self.frontier]
end

--- Consume the newest frontier stroke: it has just been taken back, and its
--- snapshot becomes a redo entry so the reader can have it again.
function History:commitFrontierUndo(snap)
    if not self.frontier or #self.frontier == 0 then return nil, "no_frontier" end
    local points, bytes = costOf({ snap })
    bytes = bytes + History.ENTRY_OVERHEAD
    local ok, err = self.pool:reserve(self, points, bytes)
    if not ok then return nil, err end
    table.remove(self.frontier)
    self.redo_stack[#self.redo_stack + 1] = {
        label = "legacy", before = {}, after = { snap },
        points = points, bytes = bytes,
    }
    return true
end

-- ------------------------------------------------------------ lifetime

--[[--
Leave the surface: remember which stored row carries which live key, so the
same page can hand its strokes their identities back when it reopens.
`live[row_id] = {key = , version = }`; only live strokes, never history.
]]
function History:detach(live)
    local copy, count = {}, 0
    for row_id, v in pairs(live or {}) do
        copy[row_id] = { key = v.key, version = v.version }
        count = count + 1
    end
    self.live = copy
    self.live_count = count
    self.attached = false
end

--[[--
Re-bind to a freshly loaded page. Every loaded meta must be one the history
knew, and every known row must be loaded; anything else means the page
changed behind the history's back, and resolving it anyway could make a later
undo remove ink it never recorded. Returns `{[meta] = {key, version}}` or
nil, "history_stale".
]]
function History:resolve(metas)
    if not self.live then return nil, "history_stale" end
    if #metas ~= self.live_count then return nil, "history_stale" end
    local out = {}
    for i = 1, #metas do
        local v = self.live[metas[i].id]
        if not v then return nil, "history_stale" end
        out[metas[i]] = v
    end
    self.live = nil
    self.live_count = nil
    self.attached = true
    self.pool:touch(self)
    return out
end

--- Forget everything because the surface can no longer be trusted to match.
--- Later edits start a fresh history on the same object; nothing falls back
--- to the legacy frontier, and no ink is removed on the way.
function History:invalidate(reason)
    clearStack(self, self.undo_stack)
    clearStack(self, self.redo_stack)
    self:releaseOpen()
    self.frontier = nil
    self.live = nil
    self.live_count = nil
    self.invalid = reason or "history_stale"
    self.attached = true
end

function History:release()
    if self.released then return end
    clearStack(self, self.undo_stack)
    clearStack(self, self.redo_stack)
    self:releaseOpen()
    self.frontier = nil
    self.live = nil
    self.released = true
    self.pool:remove(self)
end

return History
