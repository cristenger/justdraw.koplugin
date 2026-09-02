--[[--
One page of a fixed-layout document, and the ink that lives on it.

Ink on a PDF page is stored per page, in the page's own units (ADR-37/38), so
something has to hold the moment-to-moment truth about which page is open,
where those units land on the screen at this zoom and this pan, and whether
the reader may add to them at all. That is this module, and it is deliberately
the only place that knows the order those questions have to be answered in.

Three orderings carry the feature, and each is a way ink is lost when it is
got wrong:

  * the queue is flushed before the page turns. Opening the next page's
    surface frees the raster and the metadata of the last one, so a stroke
    still pending would have nothing left to be written from. A flush that
    fails is therefore a refusal and not a warning: the session stays on the
    page it could not leave, keeping its queue, until `retrySave` succeeds --
    and then finishes the page change it was holding.
  * looking at a page creates nothing. Only `ensureSurface`, which is Draw
    being pressed, may insert a row; a reader who never draws must not
    accumulate one row per page they turned past.
  * exactly one `SurfaceSession` exists at a time, because exactly one raster
    does. A page's overlay is the whole page at zoom, two bytes a pixel, and
    two of them is precisely the allocation `ink_document_transform`'s budget
    exists to refuse.

The transform is built by `DocumentTransform.fromView` and by nothing else --
one copy of the coordinate math, as everywhere else in this plugin. When it
refuses (scroll mode, a reflow, a zoom whose raster would not fit) the surface
is locked and not painted, but it is never closed: the row and every stroke on
it stay exactly where they were, and the same session continues the moment the
view can be mapped again. Closing on a refusal would turn "zoom out and draw
again" into a full re-read of the page's ink, for something the reader undoes
in one gesture.

Everything visible is injected. There is no `Device` here, no `UIManager` and
no widget: the screen arrives as a function, the scheduler as three, and every
consequence a reader could see as a callback. That is what lets the whole
lifecycle be driven, and refused, in the suite with no reader at all -- and it
is why the reader wiring above this can be a thin translation of events.

Last, the rule that decides which of these methods may be called from where.
`open`, `setPage`, `ensureSurface`, `deleteCurrent`, `deleteAll`, `suspend`
and `flush` open SQLite transactions, so they are lifecycle and UI entry
points only and must never be reached from a stylus callback (ADR-26). What
the pen calls is `addStroke` and the erase pair, which go no further than the
SurfaceSession's queue and are written on the next tick.
]]

local logger = require("logger")
local _ = require("gettext")

local BookDatabase = require("ink_book_database")
local DocumentTransform = require("ink_document_transform")
local SurfaceSession = require("ink_surface_session")

local Session = {}
Session.__index = Session

--[[--
Every reason page ink can refuse, as a sentence a reader can act on.

One table for the whole feature, and it lives here because this is the module
both halves of it can see: the session says some of these itself, and the
reader wiring turns the rest into a message when a refusal reaches a menu or a
toolbar. Two tables meant two sentences for `read_only`, two msgids for a
translator to tell apart, and no way to know which one a reader had been shown.

Reasons come from three places and all three are answered here: this session
(`unavailable`, `read_only`, `flush_failed`, ...), `ink_document_transform`
(`unsupported_mode`, `zoom_too_large`, ...) and the surface underneath
(`loading`, `save_failed`). Several share a sentence on purpose -- `suspended`
is only ever entered from scroll mode, and a session with no usable database
answers `unavailable` to everything.
]]
Session.MESSAGES = {
    -- opening the book
    no_identity = _("Page notes are unavailable for this book"),
    no_repository = _("Page notes need a database this KOReader cannot open."),
    unavailable = _("Page notes need a database this KOReader cannot open."),
    closed = _("Page notes need a database this KOReader cannot open."),
    database_conflict = _("Both JustDraw and FingerInk notes databases exist. Close KOReader, then move one database together with its matching -wal and -shm files to another directory."),
    read_only = _("Page notes are read-only because this database was created by a newer JustDraw version."),
    -- the view the transform could not describe
    unsupported_mode = _("Turn off continuous scrolling to draw page notes."),
    suspended = _("Turn off continuous scrolling to draw page notes."),
    unsupported_reflow = _("Turn off reflow to draw page notes."),
    unsupported_optimizing = _("Turn off page optimisation to draw page notes."),
    unsupported_rotation = _("Page notes need the page unrotated."),
    zoom_too_large = _("Zoom out to see and draw page notes."),
    no_view = _("Page notes can't be placed on this view."),
    unsupported_document = _("Page notes can't be placed on this view."),
    no_page = _("Page notes can't be placed on this view."),
    bad_page = _("Page notes can't be placed on this view."),
    -- the page itself
    page_geometry_changed = _("This page's size changed. Its notes are kept but can't be edited."),
    bad_geometry = _("This page does not say how big it is, so notes cannot be placed on it."),
    no_dimensions = _("This page does not say how big it is, so notes cannot be placed on it."),
    no_surface = _("There are no page notes on this page yet."),
    -- the surface underneath
    loading = _("Page notes are still loading. Try again in a moment."),
    load_failed = _("This page's notes could not be read."),
    -- The sheet's bargain, word for word: the ink is not lost, it is not
    -- durable, and one menu entry is what finishes it.
    flush_failed = _("Could not save ink. It is still here: use Retry saving."),
    save_failed = _("Could not save ink. It is still here: use Retry saving."),
}

--- A reason with no line of its own still has to say something the reader can
--- read; a driver error is the usual way to get here.
Session.FALLBACK_MESSAGE = _("Page notes are not available here.")

local MESSAGES = Session.MESSAGES

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

--[[--
  opts.ui, opts.view   the live ReaderUI and ReaderView, read-only
  opts.identity        { partial_md5 = , file_size = }
  opts.file            the book's path, for the books row and diagnosis
  opts.repository      an open repository, false to disable, nil to open one
  opts.screen          function() -> w, h -- the raster budget's screen
  opts.schedule        UIManager:nextTick
  opts.scheduleIn      UIManager:scheduleIn
  opts.unschedule      UIManager:unschedule
  opts.notify          function(text) -- one line to the reader
  opts.cache_opts      forwarded to the raster cache; the composition is not
                       the caller's to choose and is overwritten
  opts.queue_opts      forwarded to the write queue

Every callback is optional and every one of them is invoked from a lifecycle
or view path -- never from inside a pcall-guarded input handler:

  on_state_changed(name)   any change of stateName()
  on_ready()               this page's raster is complete
  on_load_error(reason)    its ink could not be read
  on_save_error(reason)    a write failed; editing is refused until a retry
  on_save_recovered()      the retry succeeded
  on_will_rebuild()        the raster is about to be replaced (the scale moved)
  on_view_refused(reason)  the view cannot be mapped. Once per *change* of
                           reason: a pan in scroll mode would otherwise say
                           the same sentence for every event.
]]
function Session.new(opts)
    opts = opts or {}
    local cache_opts = {}
    for k, v in pairs(opts.cache_opts or {}) do cache_opts[k] = v end
    -- Not the owner's to pick and not the cache's to guess: page ink is a
    -- transparent layer over the book's own page, and an opaque raster would
    -- put a blank sheet over the text (ADR-38).
    cache_opts.composition = "overlay"
    cache_opts.paper_kind = "blank"

    return setmetatable({
        ui = opts.ui,
        view = opts.view,
        identity = opts.identity or {},
        file = opts.file,
        repository = opts.repository,
        owns_repository = false,
        screen = opts.screen,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        unschedule = opts.unschedule,
        notify = opts.notify or function() end,
        cache_opts = cache_opts,
        queue_opts = opts.queue_opts or {},
        on_state_changed = opts.on_state_changed,
        on_ready = opts.on_ready,
        on_load_error = opts.on_load_error,
        on_save_error = opts.on_save_error,
        on_save_recovered = opts.on_save_recovered,
        on_will_rebuild = opts.on_will_rebuild,
        on_view_refused = opts.on_view_refused,

        book_id = nil,
        page_no = nil,
        page_resolved = false,
        surface_obj = nil,
        surface_session = nil,
        transform_obj = nil,
        view_reason = nil,
        geometry_ok = false,
        load_error = nil,
        pending_page = nil,
        suspended = false,
        notified_read_only = false,
        holding_save_recovered = false,
        deferred_save_recovered = false,
        last_state = nil,
        muted = false,
        available = false,
        closed = false,
    }, Session)
end

-- ----------------------------------------------------------------- lifecycle

--[[--
Open the database and resolve the book. True, or nil plus a reason the reader
has already been shown.

The identity is the checksum and the size, exactly as for sheets: keying a
book's notes on its path loses them the first time it is renamed.
]]
function Session:open()
    if self.closed then return nil, "closed" end
    -- Which file, whether this session opened it, and which of the two book
    -- lookups a read-only schema allows are the same decisions the sheet
    -- session makes, so both go through one seam (`ink_book_database`). What
    -- stays here is what differs: this feature's wording, and a connection
    -- that is closed only if this session opened it.
    local handle, reason = BookDatabase.open{
        repository = self.repository,
        identity = self.identity,
        file = self.file,
        path_provider = function() return self:_databasePath() end,
    }
    if not handle then return self:_unavailable(reason) end
    self.repository = handle.repository
    if handle.owns_repository then self.owns_repository = true end
    -- Nil together with `empty_read_only`: a newer plugin has not registered
    -- this book, so there is no page ink to find and this one must not
    -- insert the row.
    local book_id = handle.book_id
    self.book_id = book_id

    self.available = true
    self:_notifyState()
    logger.dbg("JustDraw: page ink session open for book", book_id)
    return true
end

function Session:_unavailable(reason)
    self.available = false
    self:_closeOwnedRepository()
    self.notify(MESSAGES[reason] or Session.FALLBACK_MESSAGE)
    self:_notifyState()
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

--- The file this book's ink lives in -- the same one the sheets use. A method
--- rather than a call, so a caller can put its own answer in front of the
--- seam's; `device` and `datastorage` stay inside the seam, which is what
--- keeps this module loadable with neither.
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

function Session:isClosed()
    return self.closed == true
end

--[[--
Shut everything down, innermost first.

`opts.force` is the same bargain `CanvasSession` makes: without it a queue
that cannot commit refuses the close, so the reader keeps a session to retry
on; with it the work is dropped, because the caller has decided the document
is going away regardless.
]]
function Session:close(opts)
    if self.closed then return true end
    opts = opts or {}
    local ok, err = true, nil
    if self.surface_session then
        ok, err = self:_closeSurfaceSession()
        if not ok and not opts.force then return nil, err end
        if not ok then
            self.muted = true
            self.surface_session:close{ discard = true }
            self.muted = false
            self.surface_session = nil
        end
    end
    self.surface_obj = nil
    self.transform_obj = nil
    self.pending_page = nil
    -- Only a connection this session opened: the caller may be sharing one
    -- whose lifetime is the document's, not this surface's.
    self:_closeOwnedRepository()
    self.repository = nil
    self.available = false
    self.closed = true
    self:_notifyState()
    return ok, err
end

-- --------------------------------------------------------------------- state

--[[--
Where this session is, from a closed vocabulary the reader wiring can switch
on. Ordered by what stops what: the three that mean there is no surface here
at all, then a failed save -- the only state where work is at risk -- then the
two that explain a page showing nothing, then whatever the surface is doing.
]]
function Session:stateName()
    if self.closed then return "closed" end
    if not self.available then return "unavailable" end
    if self.suspended then return "suspended" end
    local ss = self.surface_session
    if ss and ss:saveFailed() then return "save_failed" end
    if self.load_error then return "load_failed" end
    if self.view_reason then return "view_refused" end
    if self.surface_obj and not self.geometry_ok then return "geometry_changed" end
    if not ss then return "idle" end
    return ss:stateName()
end

--[[--
Say the state, once, when it changes.

Muted across a surface being closed. `SurfaceSession:close` reports its own
state unconditionally and that state is "closed" -- which here is the token
the reader wiring tears its UI down on, and which would otherwise be emitted
on every page turn that had a surface open, with `isClosed()` answering false
throughout. The surface closing is a step inside this session's work, not a
state this session is ever in, so the step is silent and whatever comes out
of it is announced by the caller that asked for it.
]]
function Session:_notifyState()
    if self.muted then return end
    local name = self:stateName()
    if name == self.last_state then return end
    self.last_state = name
    if self.on_state_changed then self.on_state_changed(name, self) end
end

--- Why the view was last refused, or nil while it maps.
function Session:viewReason()
    return self.view_reason
end

function Session:page()
    return self.page_no
end

function Session:surface()
    return self.surface_obj
end

function Session:surfaceSession()
    return self.surface_session
end

function Session:transform()
    return self.transform_obj
end

function Session:cache()
    return self.surface_session and self.surface_session:cache() or nil
end

--[[--
Whether ink may be added here, and if not, which one thing is in the way.

The order is the order a reader can act in: a book with no database, a
read-only one and a suspended session are all "not now"; a refused view is
"change the view"; no surface is "press Draw"; a changed page is permanent;
and a failed save is "retry saving" before anything else is accepted.
]]
function Session:canDraw()
    if self.closed then return false, "closed" end
    if not self:isAvailable() then return false, "unavailable" end
    if self.suspended then return false, "suspended" end
    if not self:isWritable() then return false, "read_only" end
    if self.view_reason then return false, self.view_reason end
    if not self.surface_obj then return false, "no_surface" end
    if not self.geometry_ok then return false, "page_geometry_changed" end
    local ss = self.surface_session
    if not ss then return false, "no_surface" end
    if ss:saveFailed() then return false, "save_failed" end
    if not ss:isReady() then return false, ss:stateName() end
    return true
end

-- --------------------------------------------------------------------- pages

--[[--
The reader turned to `page`.

Flush, close, look. Nothing is created by looking: a page with no row leaves
this session idle, holding no raster at all, which is what a book being read
rather than annotated costs.

A flush that fails keeps the old surface and its queue and refuses the turn,
because the alternative -- turning anyway -- frees the only copy of a stroke
that was never written. The page is remembered, and `retrySave` completes it.
]]
function Session:setPage(page)
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    local pageno = tonumber(page)
    if not finite(pageno) or pageno < 1 or pageno ~= math.floor(pageno) then
        return nil, "bad_page"
    end
    if self.page_resolved and self.page_no == pageno and not self.suspended then
        return true
    end

    if self.surface_session then
        local flushed, ferr = self.surface_session:flush()
        if not flushed then
            self.pending_page = pageno
            logger.warn("JustDraw: page ink not durable, page change refused:", ferr)
            self:_notifyState()
            return nil, "flush_failed"
        end
        local closed, cerr = self:_closeSurfaceSession()
        if not closed then return nil, cerr end
    end

    self.page_no = pageno
    self.page_resolved = false
    self.surface_obj = nil
    self.transform_obj = nil
    self.geometry_ok = false
    self.load_error = nil
    -- A page turn is not a reason to come back from scroll mode; the mode
    -- change is, and it arrives at `resume`.
    if self.suspended then
        self:_notifyState()
        return true
    end
    return self:_loadPage()
end

function Session:_loadPage()
    self.page_resolved = true
    -- No book row means a newer schema that has never heard of this book:
    -- there is nothing to find, and this plugin must not write one.
    if not self.book_id then
        self:_notifyState()
        return true
    end
    local row, err = self.repository:findPageInkSurface(self.book_id, self.page_no)
    if not row then
        if err ~= "not_found" then
            self.load_error = err or "load_failed"
            logger.warn("JustDraw: cannot look up this page's ink:", err)
            if self.on_load_error then self.on_load_error(self.load_error, self) end
            self:_notifyState()
            return nil, self.load_error
        end
        self:_notifyState()
        return true
    end
    return self:_openSurface(row)
end

function Session:_openSurface(row)
    self.surface_obj = row
    self.geometry_ok = self:_geometryMatches(row)
    return self:_openSurfaceSession()
end

function Session:_openSurfaceSession()
    if self.surface_session then return true end
    local row = self.surface_obj
    if not row then return nil, "no_surface" end
    if not self.transform_obj then
        local transform, reason = self:_buildTransform(row)
        if not transform then
            -- The row and its ink stay exactly as they are. A view that
            -- cannot be mapped is a state to come back from, and coming back
            -- must not cost a re-read.
            self:_notifyState()
            return nil, reason
        end
        self.transform_obj = transform
    end

    local ss
    ss = SurfaceSession.new{
        repository = self.repository,
        surface = row,
        transform = self.transform_obj,
        writable = self:isWritable(),
        schedule = self.schedule,
        scheduleIn = self.scheduleIn,
        unschedule = self.unschedule,
        cache_opts = self.cache_opts,
        queue_opts = self.queue_opts,
        on_state_changed = function()
            if self.surface_session ~= ss then return end
            self:_notifyState()
        end,
        on_ready = function()
            if self.surface_session ~= ss then return end
            if self.on_ready then self.on_ready(self) end
        end,
        on_load_error = function(reason)
            if self.surface_session ~= ss then return end
            if self.on_load_error then self.on_load_error(reason, self) end
        end,
        on_save_error = function(reason)
            if self.surface_session ~= ss then return end
            if self.on_save_error then self.on_save_error(reason, self) end
        end,
        on_save_recovered = function()
            if self.surface_session ~= ss then return end
            -- Held back while `retrySave` still has a page change to apply:
            -- the owner reads this as "you may draw again", and until the
            -- held turn has been made that would be an answer about the page
            -- the reader has already left.
            if self.holding_save_recovered then
                self.deferred_save_recovered = true
                return
            end
            if self.on_save_recovered then self.on_save_recovered(self) end
        end,
        on_will_rebuild = function()
            if self.surface_session ~= ss then return end
            if self.on_will_rebuild then self.on_will_rebuild(self) end
        end,
    }
    self.surface_session = ss
    if not self:isWritable() and not self.notified_read_only then
        self.notified_read_only = true
        self.notify(MESSAGES.read_only)
    end
    local ok, err = ss:open()
    self:_notifyState()
    if not ok then return nil, err end
    return true
end

--[[--
Close the open surface. Nil plus the queue's reason when the last write could
not be made durable -- which is a state this session *is* in, and is therefore
announced; a clean close is not, because what replaces the surface has not
happened yet.

The row goes with it when nothing was ever drawn on it. Only `ensureSurface`
creates one, but Draw stays on across a page turn, so a reader who turns ten
pages with the pen in their hand would otherwise collect ten empty rows --
which `countSurfaces` would count as page notes, "Delete all page notes" would
offer to delete, and the dossier would print as ten blank pages with headers.
Every page turn, suspend, delete and teardown reaches the surface through
here, so this is the one place that has to know it.
]]
function Session:_closeSurfaceSession(opts)
    local ss = self.surface_session
    if not ss then return true end
    -- Asked before the close, while the queue and the raster are still there
    -- to answer it.
    local drop = self:_surfaceIsEmpty(ss)
    self.muted = true
    local ok, err = ss:close(opts)
    self.muted = false
    if not ok then
        self:_notifyState()
        return nil, err
    end
    self.surface_session = nil
    if drop then self:_dropEmptySurface() end
    return true
end

--[[--
Whether the open surface holds nothing at all.

Three things have to be true and each is a way to lose ink by getting it
wrong: nothing may still be waiting in the queue; the last write must not have
failed, because its strokes are then in memory and not in `strokes()`; and the
raster must have been able to read the row in the first place -- a listing
that failed leaves an empty metadata table that says nothing about what is
stored.
]]
function Session:_rasterIsEmpty(ss)
    if ss:saveFailed() or ss:pendingWrites() ~= 0 then return false end
    local cache = ss:cache()
    if not cache or cache:stateName() == "load_failed" then return false end
    local strokes = cache:strokes()
    return strokes ~= nil and #strokes == 0
end

--- Whether this surface may be forgotten: empty, and a row this session is
--- allowed to delete. A read-only database is somebody else's to tidy.
function Session:_surfaceIsEmpty(ss)
    if not self.surface_obj or not self:isWritable() then return false end
    return self:_rasterIsEmpty(ss)
end

--[[--
Whether this page carries ink a reader could delete.

Not the same question as "is there a row": Draw creates one before the first
stroke, and it is dropped again when the page is left, so between the two
there is a working surface with nothing on it. Offering to delete that would
be offering to delete nothing.
]]
function Session:hasInk()
    if not self.surface_obj then return false end
    local ss = self.surface_session
    if not ss then return true end
    return not self:_rasterIsEmpty(ss)
end

--- Forget an empty row. Best effort by construction: a DELETE that fails
--- leaves an empty surface the reader will simply meet again, and refusing a
--- page turn over it would be the wrong trade entirely.
function Session:_dropEmptySurface()
    local row = self.surface_obj
    if not row then return false end
    local page = row.fixed_page or self.page_no
    local ok, err = self.repository:deletePageInkSurface(self.book_id, page)
    if not ok then
        logger.warn("JustDraw: an empty page-ink row could not be dropped:", err)
        return false
    end
    logger.dbg("JustDraw: dropped the empty page-ink row for page", page)
    self.surface_obj = nil
    self.transform_obj = nil
    self.geometry_ok = false
    return true
end

--- Whether the stored surface still describes the page under it. A document
--- that cannot say is not a match: editing a page whose size is unknown is
--- how ink ends up scaled against a geometry nobody checked (ADR-38).
function Session:_geometryMatches(row)
    local spec, reason = DocumentTransform.surfaceSpec(self:_document(), self.page_no)
    if not spec then
        logger.warn("JustDraw: this page cannot state its size:", reason)
        return false
    end
    return DocumentTransform.geometryMatches(row, spec)
end

function Session:_document()
    local view = self.view
    if type(view) == "table" and type(view.document) == "table" then
        return view.document
    end
    if type(self.ui) == "table" then return self.ui.document end
    return nil
end

-- ---------------------------------------------------------------- the view

--[[--
Rebuild the transform from the live view.

Called on every event that can move the page -- turn, zoom, pan, mode change,
resize -- and on nothing else: it is not a hot path, and it allocates.

With a surface open the new transform goes to it, where a changed scale
rebuilds the raster and a changed offset does not. With none open the *page's*
own geometry is probed instead, so that the reason a reader would be given for
refusing Draw is known before Draw creates anything.
]]
function Session:refreshView()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if self.suspended then return nil, "suspended" end
    if not self.page_no then return nil, "no_page" end

    local target, spec_err = self.surface_obj, nil
    if not target then
        target, spec_err = DocumentTransform.surfaceSpec(
            self:_document(), self.page_no)
    end
    local transform, reason = self:_buildTransform(target, spec_err)
    if not transform then
        self:_notifyState()
        return nil, reason
    end
    if not self.surface_obj then
        -- A probe answers the question and changes nothing: there is no
        -- surface for this transform to belong to.
        self:_notifyState()
        return true
    end
    self.transform_obj = transform
    if not self.surface_session then
        -- The row was found while the view was refused. Now it can be shown.
        return self:_openSurfaceSession()
    end
    local ok, err = self.surface_session:setTransform(transform)
    self:_notifyState()
    if not ok then return nil, err end
    return true
end

--[[--
The transform for `surface`, or nil plus the first thing wrong.

`spec_err` is how a probe keeps its own reason. With no row on this page the
surface handed in is the page's own geometry, and when the *page* could not
state a size there is no geometry to probe with: `fromView` would then answer
`bad_geometry`, which describes the probe rather than the page. Substituted
only for that one reason, and only after `fromView` has spoken, so the mode
refusals -- which come first and matter more -- still win.
]]
function Session:_buildTransform(surface, spec_err)
    local w, h
    if self.screen then w, h = self.screen() end
    local transform, reason = DocumentTransform.fromView(self.ui, self.view,
        surface, { screen = { w = w, h = h } })
    if not transform then
        if spec_err and reason == "bad_geometry" then reason = spec_err end
        self:_refuseView(reason)
        return nil, self.view_reason
    end
    self.view_reason = nil
    return transform
end

--- Record a refusal, and say it once. A pan in a mode this cannot map emits
--- an event per frame; the reader needs the sentence once, not per frame.
function Session:_refuseView(reason)
    reason = reason or "no_view"
    local changed = self.view_reason ~= reason
    self.view_reason = reason
    if changed and self.on_view_refused then self.on_view_refused(reason, self) end
end

-- ------------------------------------------------------------------ drawing

--[[--
Draw was pressed: make sure this page has a surface to draw on.

The one entry point that may insert a row, and a lifecycle one -- it opens a
transaction, so it is never reachable from a physical callback (ADR-26).

A row whose geometry no longer matches the page is kept and refused rather
than replaced: the ink is still the reader's, and a second surface for the
same page would be a duplicate the schema does not allow anyway (ADR-38).
]]
function Session:ensureSurface()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if self.suspended then return nil, "suspended" end
    if not self:isWritable() then return nil, "read_only" end
    if not self.page_no then return nil, "no_page" end
    -- Remapped here rather than trusted: `view_reason` is as old as the last
    -- view event, and a caller should not have to know the order to get a
    -- current answer. This is a lifecycle entry point and never an input
    -- path, so the cost is one transform on a key press.
    local mapped, view_err = self:refreshView()
    if not mapped then return nil, view_err end

    if self.surface_obj then
        if not self.geometry_ok then return nil, "page_geometry_changed" end
        if self.surface_session then return true end
        return self:_openSurfaceSession()
    end

    local spec, spec_err = DocumentTransform.surfaceSpec(self:_document(), self.page_no)
    if not spec then return nil, spec_err end
    -- `units` is not written: what the numbers mean is a property of the
    -- document, re-derived wherever it matters, and a stored copy could only
    -- ever go stale (ADR-38).
    local row, err = self.repository:createPageInkSurface(
        self.book_id, self.page_no, spec.logical_w, spec.logical_h)
    if not row then return nil, err end
    return self:_openSurface(row)
end

--- Record a finished stroke. Points are the page's own units; nothing here
--- reaches the disk, because the queue decides when that happens.
function Session:addStroke(points, n, width, tool, opts)
    local ok, reason = self:canDraw()
    if not ok then return nil, reason end
    return self.surface_session:addStroke(points, n, width, tool, opts)
end

function Session:beginErase()
    return self.surface_session and self.surface_session:beginErase() or nil
end

function Session:endErase(ctx)
    if self.surface_session then self.surface_session:endErase(ctx) end
end

function Session:eraseAt(cx, cy, radius, ctx)
    local ok, reason = self:canDraw()
    if not ok then return nil, reason end
    return self.surface_session:eraseAt(cx, cy, radius, ctx)
end

function Session:undo()
    local ok, reason = self:canDraw()
    if not ok then return nil, reason end
    return self.surface_session:undo()
end

function Session:canUndo()
    if not self:canDraw() then return false end
    return self.surface_session:canUndo()
end

--- Rebuild a region from what is underneath: how a stroke that was being
--- drawn and never stored is taken back off the raster.
function Session:repair(min_x, min_y, max_x, max_y, width)
    if not self.surface_session then return nil end
    return self.surface_session:repair(min_x, min_y, max_x, max_y, width)
end

function Session:pendingWrites()
    return self.surface_session and self.surface_session:pendingWrites() or 0
end

-- --------------------------------------------------------------- durability

--- The durable-save gate, for `onSaveSettings` and every lifecycle boundary.
--- `nil, "unavailable"` means there was never anything here to save -- not
--- that ink was lost.
function Session:flush()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if not self.surface_session then return true end
    local ok, err = self.surface_session:flush()
    self:_notifyState()
    return ok, err
end

function Session:saveFailed()
    return self.surface_session ~= nil and self.surface_session:saveFailed()
end

--[[--
Try the failed write again.

The operations are unchanged, so this is the same transaction a second time --
and, if a page change was refused while it was failing, the page change too.
Completing it here is what keeps the refusal honest: the reader asked to turn
the page, and nothing else is going to ask again on their behalf.
]]
function Session:retrySave()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if not self.surface_session then return true end
    -- The relay is withheld across the write and the page change it was
    -- holding, and let out at the end: an owner that turns drawing back on
    -- when it hears this has to hear it about the page it ends up on, not the
    -- one the failure stranded it against.
    self.holding_save_recovered = true
    self.deferred_save_recovered = false
    local ok, err = self.surface_session:retrySave()
    self:_notifyState()
    if not ok then
        self.holding_save_recovered = false
        self.deferred_save_recovered = false
        return nil, err
    end
    local applied, apply_err = true, nil
    local pending = self.pending_page
    if pending then
        self.pending_page = nil
        applied, apply_err = self:setPage(pending)
    end
    self.holding_save_recovered = false
    -- Only when the page change it was holding actually happened. Told
    -- otherwise, the owner turns drawing back on for a page it cannot have,
    -- and the reader gets two sentences for one press: the failure, and then
    -- the refusal that follows from acting on the recovery.
    local relay = self.deferred_save_recovered and applied
    self.deferred_save_recovered = false
    if relay and self.on_save_recovered then self.on_save_recovered(self) end
    return applied, apply_err
end

--- Read this page's ink again after a failure -- either the raster's own
--- read, or the lookup that never found the row.
function Session:retryLoad()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if self.surface_session then return self.surface_session:retryLoad() end
    if self.load_error then
        self.load_error = nil
        return self:_loadPage()
    end
    return true
end

-- ------------------------------------------------------- deleting, suspending

--- Flush and close the open surface, keeping the row. The flush is what makes
--- the queue safe to drop; a failure refuses, because a database that will
--- not take a write will not take a delete either.
function Session:_flushAndClose()
    if not self.surface_session then return true end
    local flushed, ferr = self.surface_session:flush()
    if not flushed then
        logger.warn("JustDraw: page ink not durable:", ferr)
        self:_notifyState()
        return nil, "flush_failed"
    end
    return self:_closeSurfaceSession()
end

--- Delete this page's ink, and only this page's.
function Session:deleteCurrent()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if not self:isWritable() then return nil, "read_only" end
    if not self.page_no then return nil, "no_page" end
    local closed, cerr = self:_flushAndClose()
    if not closed then return nil, cerr end
    local ok, err = self.repository:deletePageInkSurface(self.book_id, self.page_no)
    if not ok then
        -- The surface is closed either way, which is a state change of its
        -- own even though the row is still there.
        self:_notifyState()
        return nil, err
    end
    self.surface_obj = nil
    self.transform_obj = nil
    self.geometry_ok = false
    self:_notifyState()
    return true
end

--[[--
How many pages of this book carry ink.

One indexed COUNT, for the entry that offers to delete them all: it has to
know whether there is anything to delete before it can grey itself out, and
"page ink exists somewhere in this book" is not a question any other state
here answers. A book this session could never identify has none, by
construction -- there is no row to count against.
]]
function Session:countSurfaces()
    if self.closed or not self:isAvailable() then return 0 end
    if not self.book_id or not self.repository
        or type(self.repository.countPageInkSurfaces) ~= "function" then
        return 0
    end
    local n, err = self.repository:countPageInkSurfaces(self.book_id)
    if not n then
        logger.warn("JustDraw: cannot count this book's page ink:", err)
        return 0
    end
    n = tonumber(n) or 0
    -- The database has counted the open surface since `ensureSurface`
    -- inserted it, and it will be dropped again when the page is left. Until
    -- something is drawn on it, it is a working surface and not a page note.
    if self.surface_session and self:_surfaceIsEmpty(self.surface_session) then
        n = n - 1
    end
    return n > 0 and n or 0
end

--- Delete every page's ink in this book, and no sheet: three different things
--- are deletable and each is confirmed by its own name (ADR-39).
function Session:deleteAll()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if not self:isWritable() then return nil, "read_only" end
    local closed, cerr = self:_flushAndClose()
    if not closed then return nil, cerr end
    local ok, err = self.repository:deleteAllPageInkSurfaces(self.book_id)
    if not ok then
        self:_notifyState()
        return nil, err
    end
    self.surface_obj = nil
    self.transform_obj = nil
    self.geometry_ok = false
    self:_notifyState()
    return true
end

--[[--
Put the surface away without forgetting the page.

Scroll mode and anything else the transform cannot describe: the raster is the
expensive part and there is no point holding one that cannot be painted, but
the row stays and `resume` brings it back exactly where it was -- unless
nothing was ever drawn on it, in which case closing the surface forgets it and
there is nothing to bring back.
]]
function Session:suspend(reason)
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if self.suspended then return true end
    local closed, cerr = self:_flushAndClose()
    if not closed then return nil, cerr end
    self.suspended = true
    logger.dbg("JustDraw: page ink suspended:", reason)
    self.transform_obj = nil
    self:_notifyState()
    return true
end

function Session:resume()
    if self.closed then return nil, "closed" end
    if not self:isAvailable() then return nil, "unavailable" end
    if not self.suspended then return true end
    self.suspended = false
    if not self.page_no then
        self:_notifyState()
        return true
    end
    -- Re-found rather than remembered: the row may have been deleted, and the
    -- lookup is one query against an indexed key.
    self.page_resolved = false
    self.surface_obj = nil
    return self:setPage(self.page_no)
end

return Session
