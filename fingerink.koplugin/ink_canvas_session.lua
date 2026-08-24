--[[--
One book's canvases: the database, the page index, and whichever sheet is open.

This is the coordinating object. It owns the pieces that have a lifetime tied
to the open document -- the repository connection, the anchor index, the active
canvas's raster cache, its write queue and its overlay window -- and it is the
only place that knows the order those have to be created and destroyed in.

Two orderings are load-bearing and both are covered as such:

  * a canvas is never created while the page index is still building. The index
    is what knows whether this position already has one, and creating before it
    has answered is how a reader ends up with two sheets on one paragraph.
  * a canvas is never swapped out before its queue is flushed. Loading the next
    one frees the raster and the metadata of the last, and a pending stroke
    would have nothing left to be written from.

The repository is opened on `ReaderReady` rather than in `init`, because
`ReaderUI` computes `partial_md5_checksum` on its way to emitting that event
and the checksum is half the book's identity. Without both halves the feature
turns itself off for this book: keying notes on a path loses them the first
time the book is renamed.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Anchor = require("ink_anchor")
local Cache = require("ink_canvas_cache")
local Index = require("ink_anchor_index")
local Overlay = require("ink_canvas_overlay")
local Queue = require("ink_canvas_queue")
local Repository = require("ink_canvas_repository")
local Transform = require("ink_canvas_transform")

local Screen = Device.screen

local Session = {}
Session.__index = Session

local MESSAGES = {
    no_identity = _("Drawing sheets are unavailable for this book"),
    no_repository = _("Drawing sheets need a database this KOReader cannot open"),
    save_failed = _("Could not save ink. It is still here: use Retry saving."),
    save_retried = _("Ink saved"),
    indexing = _("Still indexing this book's sheets"),
}

--[[--
  opts.document     the CreDocument
  opts.identity     { partial_md5 = , file_size = }
  opts.file         the book's path, for diagnosis only
  opts.dom_version  the book's cre_dom_version
  opts.repository   an open repository, or false to disable, or nil to open one
  opts.plugin       the FingerInk instance, for the overlay's toolbar
  opts.ui           ReaderUI, the widget under the overlay
  opts.schedule     UIManager:nextTick
  opts.scheduleIn   UIManager:scheduleIn
  opts.unschedule   UIManager:unschedule
  opts.notify       function(text) -- one line to the reader
]]
function Session.new(opts)
    return setmetatable({
        document = opts.document,
        identity = opts.identity or {},
        file = opts.file,
        dom_version = opts.dom_version,
        repository = opts.repository,
        plugin = opts.plugin,
        ui = opts.ui,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        unschedule = opts.unschedule,
        notify = opts.notify or function() end,
        batch = opts.batch,

        book_id = nil,
        index = nil,
        canvas = nil,
        cache_obj = nil,
        queue = nil,
        overlay_widget = nil,
        page = nil,
        marks_here = {},
        available = false,
        closed = false,
    }, Session)
end

-- ----------------------------------------------------------------- lifecycle

--- Open the database and start indexing. Returns true, or nil plus a reason
--- that has already been shown to the reader.
function Session:open()
    if self.repository == false then return self:_unavailable("no_repository") end

    if not self.repository then
        local repo, err = Repository.open{
            path = self:_databasePath(),
            wal = Device.canUseWAL and Device:canUseWAL() or false,
        }
        if not repo then
            logger.warn("FingerInk: canvas database unavailable:", err)
            return self:_unavailable("no_repository")
        end
        self.repository = repo
        self.owns_repository = true
    end

    local book_id, err = self.repository:bookId(
        self.identity.partial_md5, self.identity.file_size, self.file)
    if not book_id then
        logger.warn("FingerInk: no stable identity for this book:", err)
        return self:_unavailable("no_identity")
    end
    self.book_id = book_id
    self.available = true

    self.index = Index.new{
        repository = self.repository,
        document = self.document,
        book_id = book_id,
        batch = self.batch,
        schedule = self.schedule,
    }
    self.index:open()
    return true
end

function Session:_unavailable(reason)
    self.available = false
    self.notify(MESSAGES[reason])
    return nil, reason
end

--- Required here rather than at the top: datastorage pulls in a chunk of
--- KOReader that a session with an injected repository never needs.
function Session:_databasePath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/fingerink.sqlite3"
end

function Session:isAvailable()
    return self.available and not self.closed
end

function Session:isIndexing()
    return self.index ~= nil and not self.index:isComplete()
end

--- Close everything, innermost first: the canvas and its queue, then the
--- index, then the connection.
function Session:close()
    if self.closed then return end
    self:closeCanvas()
    if self.index then
        self.index:cancel()
        self.index = nil
    end
    -- The repository's lifetime is the document's, whether this session
    -- opened it or was handed one.
    if self.repository and self.repository.close then self.repository:close() end
    self.repository = nil
    self.available = false
    self.closed = true
end

--- A rerender moved the text. Only the page index is rebuilt; not one stroke
--- is read, written or moved.
function Session:invalidate()
    if not self:isAvailable() then return end
    self.index:invalidate()
    self.marks_here = {}
end

-- -------------------------------------------------------------------- pages

--- The canvases anchored on the pages currently displayed.
function Session:canvasesHere(page)
    if not self:isAvailable() then return {} end
    return self.index:visibleCanvases(page)
end

function Session:canvasById(id)
    if not self.index then return nil end
    return self.index:get(id)
end

--- Canvases whose anchor no longer resolves. Kept and reachable, never deleted.
function Session:orphans()
    if not self:isAvailable() then return {} end
    local out = {}
    for _, id in ipairs(self.index:orphanIds()) do
        local canvas = self.index:get(id)
        if canvas then out[#out + 1] = canvas end
    end
    return out
end

--[[--
Work out where this page's marks go, once per page turn.

Everything expensive happens here so that `marks()` -- which runs inside
`paintTo` -- is a table read: no query, no CREngine call, nothing that could
make turning a page in a heavily annotated book cost more than turning one in a
plain book.
]]
function Session:setPage(page)
    self.page = page
    self.marks_here = {}
    if not self:isAvailable() then return end

    for _, canvas in ipairs(self:canvasesHere(page)) do
        local xp = Anchor.resolve(self.document, canvas)
        if xp and self.document.getScreenPositionFromXPointer then
            -- y first, x second: the same order CreDocument returns them in.
            local y = self.document:getScreenPositionFromXPointer(xp)
            if y then
                self.marks_here[#self.marks_here + 1] = { canvas = canvas, y = y }
            end
        end
    end
end

--- What to paint in the margin for this view. Precomputed by setPage.
function Session:marks()
    return self.marks_here
end

-- ------------------------------------------------------------------ canvases

--[[--
Open the canvas at the reader's position, creating one if there is none.

Refused while the index is still building: the index is the only thing that
knows whether this paragraph already has a sheet, and a second sheet on one
paragraph is not something a reader can untangle afterwards.
]]
function Session:createHere(page)
    if not self:isAvailable() then return nil, "unavailable" end
    if self:isIndexing() then
        self.notify(MESSAGES.indexing)
        return nil, "indexing"
    end

    local spec, err = Anchor.forCurrentPosition(self.document, self.dom_version)
    if not spec then return nil, err end

    -- An existing sheet at this exact anchor is the one the reader means.
    for _, canvas in ipairs(self:canvasesHere(page or self.page or 1)) do
        if canvas.anchor_key == spec.anchor_key then
            self:openCanvas(canvas)
            return canvas
        end
    end

    spec.logical_w = Screen:getWidth()
    spec.logical_h = Screen:getHeight()
    local canvas, cerr = self.repository:createCanvas(self.book_id, spec)
    if not canvas then return nil, cerr end

    self.index:add(canvas, page or self.page)
    self:openCanvas(canvas)
    return canvas
end

--[[--
Make this canvas the open one.

The previous canvas is shut down completely first -- queue flushed, raster
freed -- because loading the next one takes the memory the last one was using.
]]
function Session:openCanvas(canvas)
    if not canvas or not self:isAvailable() then return nil end
    if self.canvas and self.canvas.id == canvas.id then return self.overlay_widget end
    self:closeCanvas()

    self.canvas = canvas
    self.queue = Queue.new{
        repository = self.repository,
        schedule = self.scheduleIn,
        unschedule = self.unschedule,
        on_error = function() self.notify(MESSAGES.save_failed) end,
    }
    self.cache_obj = Cache.new{
        repository = self.repository,
        canvas = canvas,
        transform = self:_transform(canvas, 0),
        schedule = self.schedule,
    }
    self.cache_obj:open()

    self.overlay_widget = Overlay:new{
        plugin = self.plugin,
        cache = self.cache_obj,
        canvas = canvas,
    }
    UIManager:show(self.overlay_widget)
    return self.overlay_widget
end

function Session:closeCanvas()
    if not self.canvas then return end
    if self.edited then
        -- `listCanvases` orders by updated_at, and that ordering is what puts
        -- the sheet the reader last wrote in at the top of the chooser.
        self.repository:touchCanvas(self.canvas.id)
        self.edited = false
    end
    if self.queue then
        self.queue:close()
        self.queue = nil
    end
    if self.overlay_widget then
        UIManager:close(self.overlay_widget)
        self.overlay_widget = nil
    end
    if self.cache_obj then
        self.cache_obj:close()
        self.cache_obj = nil
    end
    self.canvas = nil
end

--[[--
Delete a canvas and everything on it.

The queue goes first and is *discarded* rather than flushed: writing strokes to
a row that is about to be deleted is work for nothing, and a delete of a row
that never existed is an error waiting to be logged.
]]
function Session:deleteCanvas(canvas)
    if not canvas or not self:isAvailable() then return nil end
    if self.canvas and self.canvas.id == canvas.id then
        if self.queue then self.queue:discard() end
        self:closeCanvas()
    end
    local ok, err = self.repository:deleteCanvas(canvas.id)
    if not ok then return nil, err end
    if self.index then self.index:forget(canvas.id) end
    self.marks_here = {}
    return true
end

function Session:activeCanvas()
    return self.canvas
end

function Session:overlay()
    return self.overlay_widget
end

function Session:cache()
    return self.cache_obj
end

function Session:transform()
    return self.overlay_widget and self.overlay_widget.transform
end

-- --------------------------------------------------------------------- ink

--[[--
Record a finished stroke: into the raster, the spatial index and the queue.

Points are canvas coordinates. Nothing here touches the disk -- the queue
decides when that happens.
]]
function Session:addStroke(points, n, width, tool)
    if not self.canvas or not self.queue then return nil, "no_canvas" end
    if not self.cache_obj:isReady() then return nil, "loading" end

    local seq = (self.cache_obj:strokes()[#self.cache_obj:strokes()] or {}).seq
    seq = (seq or 0) + 1

    local local_id, err = self.queue:addStroke(self.canvas, {
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
    self.cache_obj:addStroke({
        id = local_id, seq = seq, width = width, tool = tool, point_count = n,
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
    }, points, n)
    self.edited = true
    return local_id
end

--- Remove the topmost stroke under a canvas point. Returns the dirty region.
function Session:eraseAt(cx, cy, radius)
    if not self.canvas or not self.cache_obj then return nil end
    local hit = self.cache_obj:hitTest(cx, cy, radius)
    if not hit then return nil end
    local box = self.cache_obj:removeStroke(hit.id)
    self.queue:removeStroke(self.canvas, hit.id)
    self.edited = true
    return box
end

--- Remove the last stroke drawn on this canvas. Returns the region to repaint,
--- or nil when there was nothing to undo.
function Session:undo()
    if not self.canvas or not self.cache_obj then return nil end
    local strokes = self.cache_obj:strokes()
    local last = strokes[#strokes]
    if not last then return nil end
    local box = self.cache_obj:removeStroke(last.id)
    self.queue:removeStroke(self.canvas, last.id)
    self.edited = true
    return box or true
end

--- Undo a stroke that was being drawn and never stored: the live segments are
--- already in the raster, so the region has to be rebuilt from what was under
--- them. Returns the region to repaint.
function Session:repair(min_x, min_y, max_x, max_y, width)
    if not self.cache_obj then return nil end
    return self.cache_obj:repair{
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y, width = width,
    }
end

function Session:pendingWrites()
    return self.queue and self.queue:pendingCount() or 0
end

--- The durable-save gate. Called from onSaveSettings, which KOReader runs
--- before suspending and before closing the document.
function Session:flush()
    if not self.queue then return true end
    return self.queue:flush()
end

--- True while a write has failed and the work is still in memory. Editing is
--- refused until a retry succeeds, so this has to be reachable from the menu.
function Session:saveFailed()
    return self.queue ~= nil and self.queue:isFailed()
end

--- Try the failed write again. The operations are unchanged, so this is simply
--- the same transaction a second time.
function Session:retrySave()
    if not self.queue then return true end
    local ok, err = self.queue:retry()
    if ok then self.notify(MESSAGES.save_retried) end
    return ok, err
end

function Session:_transform(canvas, sheet_top)
    return Transform.new{
        logical_w = canvas.logical_w,
        logical_h = canvas.logical_h,
        screen_w = Screen:getWidth(),
        screen_h = Screen:getHeight(),
        sheet_top = sheet_top,
    }
end

return Session
