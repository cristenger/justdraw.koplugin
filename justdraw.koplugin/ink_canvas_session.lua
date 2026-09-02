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
local BookDatabase = require("ink_book_database")
local Index = require("ink_anchor_index")
local Overlay = require("ink_canvas_overlay")
local SurfaceSession = require("ink_surface_session")
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
    read_failed = _("Could not read this sheet's ink. The database was left unchanged."),
    list_failed = _("Could not list this book's sheets."),
    read_only = _("This sheet is read-only because it was created by a newer JustDraw version."),
    database_conflict = _("Both JustDraw and FingerInk sheet databases exist. Close KOReader, then move one database together with its matching -wal and -shm files to another directory."),
}

--[[--
  opts.document     the CreDocument
  opts.identity     { partial_md5 = , file_size = }
  opts.file         the book's path, for diagnosis only
  opts.dom_version  the book's cre_dom_version
  opts.repository   an open repository, or false to disable, or nil to open one
  opts.plugin       the JustDraw instance, for the overlay's toolbar
  opts.ui           ReaderUI, the widget under the overlay
  opts.schedule     UIManager:nextTick
  opts.scheduleIn   UIManager:scheduleIn
  opts.unschedule   UIManager:unschedule
  opts.can_work     function() -> boolean, false while a contact is live; the
                    index asks it before every batch (ADR-42)
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
        can_work = opts.can_work,
        notify = opts.notify or function() end,
        batch = opts.batch,

        book_id = nil,
        index = nil,
        canvas = nil,
        cache_obj = nil,
        queue = nil,
        surface_session = nil,
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
    -- Which file, whether this session opened it, and which of the two book
    -- lookups a read-only schema allows are the same four decisions page ink
    -- makes, so they live in one place (`ink_book_database`). What stays here
    -- is what differs: the wording, the notification, and the fact that this
    -- session's connection lives as long as the document.
    local handle, reason = BookDatabase.open{
        repository = self.repository,
        identity = self.identity,
        file = self.file,
        path_provider = function() return self:_databasePath() end,
    }
    if not handle then return self:_unavailable(reason) end
    self.repository = handle.repository
    if handle.owns_repository then self.owns_repository = true end

    -- Nil together with `empty_read_only`: there can be no canvases to list
    -- and this older plugin must not insert the book row.
    local book_id = handle.book_id
    local empty_read_only = handle.empty_read_only
    self.book_id = book_id
    self.index = Index.new{
        repository = self.repository,
        document = self.document,
        book_id = book_id,
        batch = self.batch,
        schedule = self.schedule,
        scheduleIn = self.scheduleIn,
        can_work = self.can_work,
        on_error = function(reason) self:_indexFailed(reason) end,
        on_complete = function()
            if self.closed or not self.index then return end
            if self.page then self:setPage(self.page) end
            if self.plugin and self.plugin.onCanvasIndexReady then
                self.plugin:onCanvasIndexReady()
            end
        end,
    }
    -- The index answers before it has read a single row: what used to be a
    -- synchronous listing failure now arrives at `_indexFailed` a tick or more
    -- later (ADR-42). Only the sheet count is still asked for here, so this
    -- refusal is only ever that one query failing.
    local indexed, index_err
    if empty_read_only then indexed = self.index:openEmpty()
    else indexed, index_err = self.index:open() end
    if not indexed then
        self.index = nil
        self:_closeOwnedRepository()
        self.notify(MESSAGES.list_failed)
        return nil, index_err or "list_failed"
    end
    self.available = true
    logger.dbg("JustDraw: canvas session open for book", book_id)
    return true
end

--[[--
The index gave up part-way through.

Exactly what the synchronous listing failure used to do, and it has to stay
exactly that: the index is the only thing that knows which paragraph already
has a sheet, so a book whose sheets could not all be listed gets no sheets at
all rather than a `createHere` answering from a fraction of them.
]]
function Session:_indexFailed(reason)
    if self.closed or not self.index then return end
    logger.warn("JustDraw: canvas page index failed:", reason)
    self.index = nil
    self.available = false
    self:_closeOwnedRepository()
    self.notify(MESSAGES.list_failed)
end

function Session:_unavailable(reason)
    self.available = false
    self:_closeOwnedRepository()
    self.notify(MESSAGES[reason])
    return nil, reason
end

function Session:_closeOwnedRepository()
    if not self.owns_repository then return end
    BookDatabase.close{
        repository = self.repository,
        owns_repository = true,
    }
    self.repository = nil
    self.owns_repository = false
end

--- The file this book's canvases live in. A method rather than a call, so a
--- caller can put its own answer in front of the seam's.
function Session:_databasePath()
    return BookDatabase.path()
end

function Session:isAvailable()
    return self.available and not self.closed
end

function Session:isWritable()
    return self:isAvailable() and self.repository ~= nil
        and self.repository.read_only ~= true
end

function Session:isIndexing()
    return self.index ~= nil and not self.index:isComplete()
end

--- How far the index has got, for the menu entry that is refusing because of
--- it. Nil when there is no index to ask.
function Session:indexProgress()
    if not self.index then return nil end
    return self.index:progress()
end

--- Close everything, innermost first: the canvas and its queue, then the
--- index, then the connection.
function Session:close(opts)
    if self.closed then return end
    opts = opts or {}
    local canvas_ok, canvas_err = self:closeCanvas()
    if not canvas_ok and not opts.force then return nil, canvas_err end
    if not canvas_ok then
        if self.overlay_widget then UIManager:close(self.overlay_widget) end
        if self.cache_obj then self.cache_obj:close() end
        self.overlay_widget = nil
        self.cache_obj = nil
        self.queue = nil
        self.surface_session = nil
        self.canvas = nil
        self.next_seq = nil
        self.edited = false
    end
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
    return canvas_ok, canvas_err
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
Find or create the canvas at the reader's position. The caller opens it.

Refused while the index is still building: the index is the only thing that
knows whether this paragraph already has a sheet, and a second sheet on one
paragraph is not something a reader can untangle afterwards.
]]
function Session:createHere(page)
    if not self:isAvailable() then return nil, "unavailable" end
    if not self:isWritable() then return nil, "read_only" end
    if self:isIndexing() then
        self.notify(MESSAGES.indexing)
        return nil, "indexing"
    end

    local spec, err = Anchor.forCurrentPosition(self.document, self.dom_version)
    if not spec then return nil, err end

    -- An existing sheet at this exact anchor is the one the reader means.
    for _, canvas in ipairs(self:canvasesHere(page or self.page or 1)) do
        if canvas.anchor_key == spec.anchor_key then
            return canvas
        end
    end

    spec.logical_w = Screen:getWidth()
    spec.logical_h = Screen:getHeight()
    local canvas, cerr = self.repository:createCanvas(self.book_id, spec)
    if not canvas then return nil, cerr end

    self.index:add(canvas, page or self.page)
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
    local closed, close_err = self:closeCanvas()
    if not closed then return nil, close_err end

    local transform, transform_err = self:_transform(canvas, 0)
    if not transform then return nil, transform_err or "bad_geometry" end

    self.canvas = canvas
    if not self:isWritable() then self.notify(MESSAGES.read_only) end
    self.surface_session = SurfaceSession.new{
        repository = self.repository,
        surface = canvas,
        transform = transform,
        writable = self:isWritable(),
        schedule = self.schedule,
        scheduleIn = self.scheduleIn,
        unschedule = self.unschedule,
        on_ready = function()
            if self.canvas == canvas and self.overlay_widget
                and self.plugin and self.plugin.onCanvasReady then
                self.plugin:onCanvasReady(canvas)
            end
        end,
        on_load_error = function()
            self.notify(MESSAGES.read_failed)
            if self.canvas == canvas and self.overlay_widget
                and self.plugin and self.plugin.onCanvasLoadFailed then
                self.plugin:onCanvasLoadFailed(canvas)
            end
        end,
        on_save_error = function(reason)
            self.notify(MESSAGES.save_failed)
            if self.canvas == canvas and self.plugin
                and self.plugin.onCanvasSaveFailed then
                self.plugin:onCanvasSaveFailed(canvas, reason)
            end
        end,
        on_save_recovered = function()
            self.notify(MESSAGES.save_retried)
            if self.plugin and self.plugin.onCanvasSaveRecovered then
                self.plugin:onCanvasSaveRecovered(canvas)
            end
        end,
    }
    local cache_ok, cache_err = self.surface_session:open()
    self.cache_obj = self.surface_session:cache()
    self.queue = self.surface_session.queue

    self.overlay_widget = Overlay:new{
        plugin = self.plugin,
        cache = self.cache_obj,
        canvas = canvas,
        bar_side = self.plugin and self.plugin.bar_side or "right",
    }
    UIManager:show(self.overlay_widget)
    -- Synchronous list/metadata failures are represented by the same visible
    -- load_failed sheet as asynchronous chunk failures. Closing the objects
    -- here would remove the only Retry control and contradict fail-closed
    -- recovery.
    return self.overlay_widget, cache_ok and nil or cache_err
end

function Session:closeCanvas()
    if not self.canvas then return true end
    if self.surface_session then
        local ok, err = self.surface_session:close()
        if not ok then return nil, err end
    end
    if self.edited or (self.surface_session and self.surface_session.edited) then
        -- This is ordering metadata, not ink durability. Do it only after the
        -- queue committed, and never keep a safely written canvas open merely
        -- because its recency marker could not be updated.
        local touched, terr = self.repository:touchCanvas(self.canvas.id)
        if not touched then
            logger.warn("JustDraw: could not update canvas recency:", terr)
        end
        self.edited = false
    end
    if self.queue then
        self.queue = nil
    end
    if self.overlay_widget then
        UIManager:close(self.overlay_widget)
        self.overlay_widget = nil
    end
    self.cache_obj = nil
    self.surface_session = nil
    self.canvas = nil
    self.next_seq = nil
    return true
end

--[[--
Delete a canvas and everything on it.

The queue goes first and is *discarded* rather than flushed: writing strokes to
a row that is about to be deleted is work for nothing, and a delete of a row
that never existed is an error waiting to be logged.
]]
function Session:deleteCanvas(canvas)
    if not canvas or not self:isAvailable() then return nil end
    if not self:isWritable() then return nil, "read_only" end
    local ok, err = self.repository:deleteCanvas(canvas.id)
    if not ok then return nil, err end
    if self.canvas and self.canvas.id == canvas.id then
        if self.surface_session then self.surface_session:close{ discard = true } end
        if self.overlay_widget then
            UIManager:close(self.overlay_widget)
            self.overlay_widget = nil
        end
        self.cache_obj = nil
        self.queue = nil
        self.surface_session = nil
        self.canvas = nil
        self.next_seq = nil
        self.edited = false
    end
    if self.index then self.index:forget(canvas.id) end
    self.marks_here = {}
    return true
end

function Session:activeCanvas()
    return self.canvas
end

--[[--
The read side of this book's canvases, for one export.

Borrowed rather than owned: the export reads strokes through the same
repository and orders sheets through the same index, and it writes to neither.
Handing both out together is deliberate -- an export that had the rows but not
the index would have no reading order and would fall back on `updated_at`,
which is when a sheet was last drawn on and not where it sits in the book.
]]
function Session:exportSources()
    if not self:isAvailable() then return nil, "unavailable" end
    return self.repository, self.index
end

--- Every canvas of this book, metadata only. `canvasesHere` answers for one
--- page; an export of the whole book needs all of them, orphans included.
function Session:allCanvases()
    if not self:isAvailable() then return nil, "unavailable" end
    return self.repository:listCanvases(self.book_id)
end

function Session:overlay()
    return self.overlay_widget
end

function Session:cache()
    return self.surface_session and self.surface_session:cache() or self.cache_obj
end

function Session:loadFailed()
    return self.surface_session ~= nil
        and self.surface_session:stateName() == "load_failed"
end

function Session:retryLoad()
    if not self.surface_session then return nil, "no_canvas" end
    return self.surface_session:retryLoad()
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
function Session:addStroke(points, n, width, tool, opts)
    if not self.surface_session then return nil, "no_canvas" end
    local id, err, painted, left, top, right, bottom =
        self.surface_session:addStroke(points, n, width, tool, opts)
    if id then self.edited = true end
    return id, err, painted, left, top, right, bottom
end

--- Remove the topmost stroke under a canvas point. Returns the dirty region.
function Session:beginErase()
    return self.surface_session and self.surface_session:beginErase() or nil
end

function Session:endErase(ctx)
    if self.surface_session then self.surface_session:endErase(ctx) end
end

function Session:eraseAt(cx, cy, radius, ctx)
    if not self.surface_session then return nil end
    local box, err = self.surface_session:eraseAt(cx, cy, radius, ctx)
    if box then self.edited = true end
    return box, err
end

--- Remove the last stroke drawn on this canvas. Returns the region to repaint,
--- or nil when there was nothing to undo.
function Session:undo()
    if not self.surface_session then return nil end
    local box, err = self.surface_session:undo()
    if box then self.edited = true end
    return box, err
end

--- Undo a stroke that was being drawn and never stored: the live segments are
--- already in the raster, so the region has to be rebuilt from what was under
--- them. Returns the region to repaint.
function Session:repair(min_x, min_y, max_x, max_y, width)
    if not self.surface_session then return nil end
    return self.surface_session:repair(min_x, min_y, max_x, max_y, width)
end

function Session:pendingWrites()
    return self.surface_session and self.surface_session:pendingWrites() or 0
end

--- The durable-save gate. Called from onSaveSettings, which KOReader runs
--- before suspending and before closing the document.
function Session:flush()
    if not self.surface_session then return true end
    return self.surface_session:flush()
end

--- True while a write has failed and the work is still in memory. Editing is
--- refused until a retry succeeds, so this has to be reachable from the menu.
function Session:saveFailed()
    return self.surface_session ~= nil and self.surface_session:saveFailed()
end

--- Try the failed write again. The operations are unchanged, so this is simply
--- the same transaction a second time.
function Session:retrySave()
    if not self.surface_session then return true end
    return self.surface_session:retrySave()
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
