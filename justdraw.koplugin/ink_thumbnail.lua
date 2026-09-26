--[[--
Thumbnails for the notebook gallery: one page, rendered small, cached as a PNG
under a name that says exactly what it shows (ADR-58).

Why the name carries everything. A thumbnail is stale when the page's ink or
paper changed, when a different page became the notebook's cover, when the
card asks for another size, when the renderer changes, or when a purged
notebook's row id is handed to a new one. Modification times in seconds miss
two edits in one second, and overwriting one file under a stable name keeps
KOReader's image cache showing the old picture. So the file name is the key:
database identity, notebook identity, page id, content revision, paper, page
geometry, requested size and renderer version. A new state is a new file; an
old file is simply never asked for again and is evicted by the LRU.

Why a queue with one job. Rasterising a page reuses the export's off-screen
raster (`ink_export_raster`), which builds in bounded batches on UI ticks;
running several at once multiplies memory, and running one for a card that
scrolled away wastes the device's time. Only cards the gallery says are
visible stay queued (`retain`), and cancelling a job closes its raster and
frees its buffers instead of merely ignoring the result.

Why a temporary and a check before publishing. The PNG is written under a
temporary name, checked to exist with a non-zero size, and renamed only if the
page is still at the revision it was rendered from and the queue's generation
has not moved on. A failure is retried a bounded number of times, later; then
the card shows a placeholder and offers a retry, and the failure is not
remembered past that.
]]

local logger = require("logger")

local Thumbs = {
    --- Bumped when what a thumbnail looks like changes, so old files miss.
    RENDERER_VERSION = 1,
    MAX_FILES = 300,
    MAX_ATTEMPTS = 3,
    RETRY_DELAY = 5,
}
Thumbs.__index = Thumbs

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function safe(part)
    return (tostring(part):gsub("[^%w_]", "_"))
end

--[[--
The cache key for one request, or nil when it lacks an identity field.
`req = {db_uid, notebook_uid, page_id, revision, template_kind, logical_w,
logical_h, w, h}`.
]]
function Thumbs.key(req)
    if type(req) ~= "table" or not req.db_uid or not req.notebook_uid
        or not finite(req.page_id) or not finite(req.revision)
        or not finite(req.logical_w) or not finite(req.logical_h)
        or not finite(req.w) or not finite(req.h) or req.w < 1 or req.h < 1 then
        return nil
    end
    return string.format("%s-%s-p%d-r%d-%s-%dx%d-%dx%d-v%d",
        safe(req.db_uid), safe(req.notebook_uid), req.page_id, req.revision,
        safe(req.template_kind or "blank"), req.logical_w, req.logical_h,
        req.w, req.h, Thumbs.RENDERER_VERSION)
end

--- The request for a notebook's cover page, drawn at `w` x `h`.
function Thumbs.request(db_uid, notebook, page, w, h)
    if type(notebook) ~= "table" or type(page) ~= "table" then return nil end
    return { db_uid = db_uid, notebook_uid = notebook.uid, page_id = page.id,
        revision = page.revision or 0, template_kind = page.template_kind,
        logical_w = page.logical_w, logical_h = page.logical_h, w = w, h = h }
end

--[[--
  opts.dir         where thumbnails live (created on demand)
  opts.repository  function() -> the notebook repository (getPage, readers)
  opts.schedule    function(delay, fn); opts.unschedule function(fn)
  opts.raster_open function(opts) -> job   (ink_export_raster.open)
  opts.scale       function(bb, w, h) -> bb (mupdf.scaleBlitBuffer)
  opts.write       function(bb, path) -> true | nil, err (bb:writePNG)
  opts.fs          { exists(path), size(path), rename(a, b), remove(path),
                     list(dir) -> names, mkdir(dir) }
  opts.max_files, opts.max_attempts, opts.retry_delay
]]
function Thumbs.new(opts)
    opts = opts or {}
    local self = setmetatable({
        dir = assert(opts.dir, "dir"),
        repository = assert(opts.repository, "repository"),
        schedule = assert(opts.schedule, "schedule"),
        unschedule = opts.unschedule or function() end,
        raster_open = assert(opts.raster_open, "raster_open"),
        scale = assert(opts.scale, "scale"),
        write = assert(opts.write, "write"),
        fs = assert(opts.fs, "fs"),
        max_files = opts.max_files or Thumbs.MAX_FILES,
        max_attempts = opts.max_attempts or Thumbs.MAX_ATTEMPTS,
        retry_delay = opts.retry_delay or Thumbs.RETRY_DELAY,
        queue = {},          -- pending requests, in the order asked
        queued = {},         -- key -> request
        attempts = {},       -- key -> failed attempts in this life
        failed = {},         -- key -> true once attempts ran out
        lru = {},            -- known files, least recently used first
        active = nil,
        generation = 0,
        closed = false,
        visible = nil,
    }, Thumbs)
    self:_scanDirectory()
    return self
end

function Thumbs:pathFor(key)
    return self.dir .. "/" .. key .. ".png"
end

function Thumbs:_scanDirectory()
    local names = self.fs.list(self.dir) or {}
    table.sort(names)
    for _, name in ipairs(names) do
        local key = name:match("^(.+)%.png$")
        if key then self.lru[#self.lru + 1] = key
        elseif name:match("%.png%.tmp$") then
            -- A temporary left by a previous process: never published.
            self.fs.remove(self.dir .. "/" .. name)
        end
    end
end

function Thumbs:_touch(key)
    for i = #self.lru, 1, -1 do
        if self.lru[i] == key then table.remove(self.lru, i); break end
    end
    self.lru[#self.lru + 1] = key
end

--- Evict least recently used files beyond the cap -- never one a visible
--- card is showing.
function Thumbs:_evict()
    local i = 1
    while #self.lru > self.max_files and i <= #self.lru do
        local key = self.lru[i]
        if self.visible and self.visible[key] then
            i = i + 1
        else
            table.remove(self.lru, i)
            self.fs.remove(self:pathFor(key))
        end
    end
end

--[[--
Ask for a thumbnail. Returns its path at once when the file exists; otherwise
queues the request and returns nil, "pending" -- `callback(path, key)` runs
when it is ready, or `callback(nil, key, reason)` when it failed for good.
]]
function Thumbs:want(req, callback)
    if self.closed then return nil, "closed" end
    local key = Thumbs.key(req)
    if not key then return nil, "bad_request" end
    local path = self:pathFor(key)
    if self.fs.exists(path) then
        self:_touch(key)
        return path, key
    end
    if self.failed[key] then return nil, "failed", key end
    local queued = self.queued[key]
    if queued then
        queued.callbacks[#queued.callbacks + 1] = callback
        return nil, "pending", key
    end
    local item = { key = key, req = req, callbacks = { callback } }
    self.queued[key] = item
    self.queue[#self.queue + 1] = item
    self:_pump()
    return nil, "pending", key
end

--- Whether the file for `key` is there now (an LRU may have removed it).
function Thumbs:has(key)
    return type(key) == "string" and self.fs.exists(self:pathFor(key)) or false
end

--- Forget a failure so the next `want` tries again (the card's Retry).
function Thumbs:retry(req)
    local key = Thumbs.key(req)
    if key then self.failed[key] = nil; self.attempts[key] = nil end
end

--[[--
Keep only the requests the gallery can still see (`keys` is a set). The
active job is cancelled -- raster closed, buffers freed -- if its card went
away.
]]
function Thumbs:retain(keys)
    self.visible = keys
    local kept = {}
    for _, item in ipairs(self.queue) do
        if keys[item.key] then kept[#kept + 1] = item else self.queued[item.key] = nil end
    end
    self.queue = kept
    -- A request waiting out its retry delay is queued too, in spirit: if its
    -- card went away, the retry is dropped rather than rendered for nobody.
    for key, item in pairs(self.queued) do
        if not keys[key] and item ~= self.active then
            if item.retry_action then self.unschedule(item.retry_action) end
            self.queued[key] = nil
        end
    end
    if self.active and not keys[self.active.key] then self:_cancelActive() end
end

function Thumbs:_cancelActive()
    local active = self.active
    if not active then return end
    self.active = nil
    self.generation = self.generation + 1
    if active.retry_action then self.unschedule(active.retry_action) end
    if active.job then active.job:close() end
    self.queued[active.key] = nil
    self:_pump()
end

function Thumbs:cancelAll()
    self.queue = {}
    self.queued = {}
    self:_cancelActive()
end

function Thumbs:close()
    if self.closed then return end
    self:cancelAll()
    self.closed = true
end

function Thumbs:_pump()
    if self.closed or self.active or #self.queue == 0 then return end
    local item = table.remove(self.queue, 1)
    self.active = item
    self.generation = self.generation + 1
    local generation = self.generation
    local req = item.req
    local surface = { id = req.page_id, logical_w = req.logical_w,
        logical_h = req.logical_h, template_kind = req.template_kind }
    -- At most twice the card in each direction, then reduced: enough detail
    -- for a sharp reduction, never a full-page raster for a small card.
    local scale = math.min(2 * req.w / req.logical_w, 2 * req.h / req.logical_h)
    local ok, job, err = pcall(self.raster_open, {
        repository = self.repository(), surface = surface, scale = scale,
        max_pixels = 4 * req.w * req.h + 4096,
        schedule = function(fn) self.schedule(0, fn) end,
        on_ready = function(j) self:_rendered(item, generation, j) end,
        on_error = function(reason, j) self:_failed(item, generation, reason or "raster_failed", j) end,
    })
    if not ok or not job then
        self:_failed(item, generation, ok and err or "raster_failed")
        return
    end
    item.job = job
end

local function deliver(item, path, reason)
    for _, cb in ipairs(item.callbacks) do
        if cb then
            local ok, err = pcall(cb, path, item.key, reason)
            if not ok then logger.warn("JustDraw: thumbnail callback failed:", err) end
        end
    end
end

function Thumbs:_finish(item)
    if self.active == item then self.active = nil end
    self.queued[item.key] = nil
    self:_pump()
end

function Thumbs:_rendered(item, generation, job)
    if self.active ~= item or generation ~= self.generation or self.closed then
        job:close()
        return
    end
    local bb = job:buffer()
    local reduced
    local published, reason = false, nil
    local tmp = self:pathFor(item.key) .. ".tmp"
    local final = self:pathFor(item.key)
    local ok, err = pcall(function()
        if not bb then error("no_buffer", 0) end
        reduced = self.scale(bb, item.req.w, item.req.h)
        if not reduced then error("scale_failed", 0) end
        self.fs.mkdir(self.dir)
        local written, write_err = self.write(reduced, tmp)
        if not written then error(write_err or "write_failed", 0) end
        local size = self.fs.size(tmp)
        if not size or size <= 0 then error("empty_file", 0) end
        -- Still the page it was rendered from? A revision that moved on is
        -- a thumbnail of the past: throw it away rather than publish it.
        local page = self.repository():getPage(item.req.page_id)
        if not page or (page.revision or 0) ~= item.req.revision then error("stale", 0) end
        if generation ~= self.generation then error("cancelled", 0) end
        local renamed, rename_err = self.fs.rename(tmp, final)
        if not renamed then error(rename_err or "rename_failed", 0) end
        published = true
    end)
    if not ok then reason = err end
    -- Free both buffers on every path, and the reduced one only if it is not
    -- the raster itself (a reduction to the same size may hand it back).
    if reduced and reduced ~= bb and reduced.free then reduced:free() end
    job:close()
    if not published then
        self.fs.remove(tmp)
        if reason == "stale" or reason == "cancelled" then
            self:_finish(item)
            deliver(item, nil, reason)
            return
        end
        return self:_failed(item, generation, reason)
    end
    self.attempts[item.key] = nil
    self:_touch(item.key)
    self:_evict()
    self:_finish(item)
    deliver(item, final)
end

function Thumbs:_failed(item, generation, reason, job)
    if job then job:close() end
    if self.active ~= item or generation ~= self.generation then return end
    logger.warn("JustDraw: thumbnail failed:", item.key, reason)
    local attempts = (self.attempts[item.key] or 0) + 1
    self.attempts[item.key] = attempts
    if attempts < self.max_attempts and not self.closed then
        -- Later, not now: a transient failure (disk busy, memory) deserves a
        -- pause, and the queue keeps serving other cards meanwhile.
        self.active = nil
        local action
        action = function()
            if self.closed or not self.queued[item.key] then return end
            item.job = nil
            self.queue[#self.queue + 1] = item
            self:_pump()
        end
        item.retry_action = action
        self.schedule(self.retry_delay, action)
        self:_pump()
        return
    end
    self.failed[item.key] = true
    self:_finish(item)
    deliver(item, nil, reason)
end

--[[--
The production collaborators, in one place so the gallery and the native test
use the same ones: MuPDF's reduction, KOReader's PNG writer (which answers
true even when nothing was written -- hence the size check above) and `lfs`.
]]
function Thumbs.nativeDeps()
    local lfs = require("libs/libkoreader-lfs")
    return {
        raster_open = function(o) return require("ink_export_raster").open(o) end,
        scale = function(bb, w, h) return require("ffi/mupdf").scaleBlitBuffer(bb, w, h) end,
        write = function(bb, path)
            local ok, err = bb:writeToFile(path, "png")
            if not ok then return nil, err or "encode_failed" end
            return true
        end,
        fs = {
            exists = function(p) return lfs.attributes(p, "mode") == "file" end,
            size = function(p) return lfs.attributes(p, "size") end,
            rename = function(a, b) return os.rename(a, b) end,
            remove = function(p) os.remove(p) end,
            list = function(dir)
                local names = {}
                if lfs.attributes(dir, "mode") ~= "directory" then return names end
                for name in lfs.dir(dir) do
                    if name ~= "." and name ~= ".." then names[#names + 1] = name end
                end
                return names
            end,
            mkdir = function(dir)
                if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
            end,
        },
    }
end

return Thumbs
