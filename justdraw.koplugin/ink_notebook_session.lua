--[[--
One standalone notebook with one active page.

Navigation is a durability gate: the old page is never released until its
queue commits.  The new page becomes the persisted current page only after its
raster is complete, so a failed load cannot strand the next launch on a blank
or corrupt page.
]]

local InputController = require("ink_input_controller")
local Errors = require("ink_notebook_errors")
local SurfaceSession = require("ink_surface_session")
local Transform = require("ink_canvas_transform")
local logger = require("logger")

local Session = {}
Session.__index = Session

function Session.new(opts)
    opts = opts or {}
    return setmetatable({
        repository = opts.repository,
        schedule = opts.schedule,
        scheduleIn = opts.scheduleIn,
        unschedule = opts.unschedule,
        notify = opts.notify or function() end,
        input_controller = opts.input_controller or InputController,
        input_owner = opts.input_owner,
        capture_spec = opts.capture_spec,
        abort_contact = opts.abort_contact,
        transform_factory = opts.transform_factory,
        fit_rect = opts.fit_rect,
        clip_rect = opts.clip_rect,
        align_x = opts.align_x or "center",
        align_y = opts.align_y or "top",
        on_state_changed = opts.on_state_changed,
        on_page_ready = opts.on_page_ready,
        on_notebook_changed = opts.on_notebook_changed,
        on_durable_change = opts.on_durable_change,
        on_dirty_box = opts.on_dirty_box,
        on_maintenance_needed = opts.on_maintenance_needed,
        notebook_obj = nil,
        current_page = nil,
        surface_session = nil,
        input_lease = nil,
        pending_current = nil,
        pending_delete_page = nil,
        state_error = nil,
        state_error_reason = nil,
        input_error = nil,
        has_previous = false,
        has_next = false,
        navigation_status_error = nil,
        opened = false,
        closed = false,
    }, Session)
end

function Session:_notifyState()
    if self.on_state_changed then self.on_state_changed(self:stateName(), self) end
end

function Session:notebook()
    return self.notebook_obj
end

function Session:currentPage()
    return self.current_page
end

function Session:surface()
    return self.surface_session
end

function Session:stateName()
    if self.closed then return "closed" end
    if self.state_error then return self.state_error end
    if self.input_error then return "input_failed" end
    if self.surface_session then return self.surface_session:stateName() end
    return self.opened and "loading" or "closed"
end

function Session:_refreshNeighbours(page)
    self.has_previous = false
    self.has_next = false
    self.navigation_status_error = nil
    if not page or self.closed then return true end
    local previous, previous_err = self.repository:previousPage(page)
    local next_page, next_err = self.repository:nextPage(page)
    if previous_err or next_err then
        self.navigation_status_error = previous_err or next_err
        return nil, self.navigation_status_error
    end
    self.has_previous = previous ~= nil
    self.has_next = next_page ~= nil
    return true
end

function Session:uiSnapshot()
    local state = self:stateName()
    local surface = self.surface_session
    local contact = self:_hasActiveContact()
    local pending_metadata = self.pending_current ~= nil
        or self.pending_delete_page ~= nil
    local writable = self.repository ~= nil and self.repository.read_only ~= true
        and surface ~= nil and surface:isWritable() and not self.closed
    local transition_free = not pending_metadata
    local can_navigate = (state == "ready" or state == "input_failed")
        and transition_free and not contact
        and not (surface and surface:saveFailed())
    local can_close = not self.closed and not contact and state ~= "save_failed"
        and not pending_metadata
    -- Why navigation is refused, from a closed vocabulary, in the order the
    -- reader can act on it. A single can_navigate=false collapsed "your hand
    -- is still on the glass" into the same silence as "this page never
    -- loaded", and the editor had nothing to say when a button did nothing.
    local navigation_block_reason
    if not can_navigate then
        if contact then
            navigation_block_reason = "contact_active"
        elseif pending_metadata then
            navigation_block_reason = "transition_pending"
        elseif state == "save_failed" or (surface and surface:saveFailed()) then
            navigation_block_reason = "save_failed"
        elseif state == "load_failed" then
            navigation_block_reason = "load_failed"
        elseif state == "closed" then
            navigation_block_reason = "closed"
        else
            navigation_block_reason = "loading"
        end
    end
    local error_code
    if state == "load_failed" then
        error_code = Errors.normalize(surface and surface.load_error, "load")
    elseif state == "save_failed" then
        error_code = Errors.normalize(self.state_error_reason or "save_failed", "save")
    elseif state == "input_failed" then
        error_code = Errors.normalize(self.input_error, "input")
    end
    return {
        state = state,
        writable = writable,
        can_ink = state == "ready" and writable and transition_free and not contact,
        can_navigate = can_navigate,
        navigation_block_reason = navigation_block_reason,
        can_close = can_close,
        has_previous = can_navigate and self.has_previous or false,
        has_next = can_navigate and self.has_next or false,
        page_count = self.notebook_obj and self.notebook_obj.page_count or 0,
        -- The open page's ruling, so the chooser reads one public snapshot
        -- rather than reaching into the page row for a second opinion.
        template_kind = self.current_page and self.current_page.template_kind
            or "blank",
        can_undo = state == "ready" and surface ~= nil and surface:canUndo() or false,
        pending_writes = surface and surface:pendingWrites() or 0,
        error_code = error_code,
    }
end

function Session:_transform(page)
    if self.transform_factory then return self.transform_factory(page, self) end
    local fit = self.fit_rect or {
        x = 0, y = 0, w = page.logical_w, h = page.logical_h,
    }
    return Transform.new{
        logical_w = page.logical_w,
        logical_h = page.logical_h,
        fit_rect = fit,
        clip_rect = self.clip_rect or fit,
        align_x = self.align_x,
        align_y = self.align_y,
    }
end

function Session:_hasActiveContact()
    return self.input_lease and self.input_lease:hasActiveContact() or false
end

function Session:_releaseCapture(deferred)
    local lease = self.input_lease
    if not lease then return true end
    local ok, err
    if deferred then ok, err = lease:releaseDeferred()
    else ok, err = lease:release() end
    if ok then self.input_lease = nil end
    return ok, err
end

--- Make a deterministic domain failure inert inside the callback, but leave
--- KOReader's stylus hook installed until the next safe UI tick. This mirrors
--- the capture guard's two-phase teardown without misclassifying a rejected
--- operation as a failed SQLite transaction.
function Session:failInputDeferred(reason)
    reason = reason or "input_failed"
    self.input_error = reason
    local lease = self.input_lease
    local function finish()
        if self.input_lease == lease then self.input_lease = nil end
        if self.abort_contact then
            local ok, abort_err = pcall(self.abort_contact, self)
            if not ok then
                logger.err("JustDraw notebooks: deferred input abort failed:",
                    abort_err)
            end
        end
        self:_notifyState()
    end
    if not lease then
        self.schedule(finish)
        return true
    end
    local ok, err = lease:releaseDeferred(finish)
    if not ok then return nil, err end
    return true
end

function Session:_acquireCapture(retry)
    if self.input_lease or not self.capture_spec
        or not self.surface_session or not self.surface_session:isReady()
        or not self.surface_session:isWritable()
        or self.state_error or self.pending_current or self.pending_delete_page then
        return true
    end
    if self.input_error and not retry then return nil, self.input_error end
    local built, spec = pcall(self.capture_spec, self, self.current_page,
        self.surface_session:transform())
    if not built then
        self.input_error = spec or "input_failed"
        self.notify(self.input_error)
        self:_notifyState()
        return nil, self.input_error
    end
    if not spec then return true end
    local caller_error = spec.on_error
    local lease
    spec.on_error = function(reason)
        if self.input_lease == lease then self.input_lease = nil end
        if self.abort_contact then pcall(self.abort_contact, self) end
        self.input_error = reason or "handler_error"
        local notified = caller_error and pcall(caller_error, reason)
        if not notified then self.notify(self.input_error) end
        self:_notifyState()
    end
    local owner = self.input_owner or self
    local err
    lease, err = self.input_controller:acquire(owner, spec)
    if not lease then
        self.input_error = err or "input_failed"
        self:_notifyState()
        return nil, self.input_error
    end
    self.input_error = nil
    self.input_lease = lease
    return true
end

function Session:_setMetadataError(reason)
    self.state_error = "save_failed"
    self.state_error_reason = reason or "save_failed"
    self.notify(self.state_error_reason)
    self:_notifyState()
end

function Session:_retryMetadata()
    if not (self.pending_current or self.pending_delete_page) then
        self.state_error = nil
        self.state_error_reason = nil
        return true
    end
    -- `pending_current` is also the marker for a destination that has not yet
    -- completed first paint. SaveSettings must never turn a load failure into
    -- the durable current page (or tombstone the last readable page).
    if not self.surface_session or not self.surface_session:isReady() then
        return nil, self.surface_session and self.surface_session:stateName()
            or "load_failed"
    end
    if self.pending_current then
        local ok, err = self.repository:selectCurrentPage(
            self.notebook_obj.id, self.pending_current)
        if not ok then self:_setMetadataError(err); return nil, err end
        self.notebook_obj.current_page_id = self.pending_current
        self.pending_current = nil
    end
    if self.pending_delete_page then
        local deleted, delete_err = self.repository:softDeletePage(
            self.notebook_obj.id, self.pending_delete_page)
        if not deleted then
            self:_setMetadataError(delete_err)
            return nil, delete_err
        end
        self.pending_delete_page = nil
        self.notebook_obj.page_count = self.notebook_obj.page_count - 1
        if self.on_notebook_changed then self.on_notebook_changed(self) end
    end
    self.state_error = nil
    self.state_error_reason = nil
    return true
end

function Session:_pageReady(page, surface)
    if self.closed or self.current_page ~= page or self.surface_session ~= surface then return end
    if self.pending_current == page.id then
        local selected, select_err = self.repository:selectCurrentPage(
            self.notebook_obj.id, page.id)
        if not selected then
            self:_setMetadataError(select_err)
            return
        end
        self.notebook_obj.current_page_id = page.id
        self.pending_current = nil
    end
    if self.pending_delete_page then
        local deleted, delete_err = self.repository:softDeletePage(
            self.notebook_obj.id, self.pending_delete_page)
        if not deleted then
            self:_setMetadataError(delete_err)
            return
        end
        self.pending_delete_page = nil
        self.notebook_obj.page_count = self.notebook_obj.page_count - 1
        if self.on_notebook_changed then self.on_notebook_changed(self) end
    end
    self.state_error = nil
    self.state_error_reason = nil
    self:_refreshNeighbours(page)
    local acquired, acquire_err = self:_acquireCapture()
    if not acquired then self.notify(acquire_err) end
    if self.on_page_ready then self.on_page_ready(page, self) end
    self:_notifyState()
end

function Session:_openPage(page, persist_current, transform)
    local transform_err
    if not transform then transform, transform_err = self:_transform(page) end
    if not transform then return nil, transform_err or "bad_geometry" end
    local surface
    surface = SurfaceSession.new{
        repository = self.repository,
        surface = page,
        transform = transform,
        writable = self.repository.read_only ~= true,
        schedule = self.schedule,
        scheduleIn = self.scheduleIn,
        unschedule = self.unschedule,
        -- The notebook route owns its own lease, so it can answer this
        -- itself: no commit runs under a contact (ADR-42).
        can_work = function() return not self:_hasActiveContact() end,
        on_ready = function() self:_pageReady(page, surface) end,
        on_load_error = function(reason)
            if self.surface_session == surface then
                self:_releaseCapture(true)
                self.notify(reason or "load_failed")
                self:_notifyState()
            end
        end,
        on_save_error = function(reason)
            if self.surface_session == surface then
                -- A previous debounced commit may fail while a newer contact
                -- is still only live-raster ink. Repair and retire that contact
                -- before making the capture callback inert.
                if self.abort_contact then pcall(self.abort_contact, self) end
                self:_releaseCapture(true)
                self.notify(reason or "save_failed")
                self:_notifyState()
            end
        end,
        on_save_recovered = function()
            if self.surface_session == surface then
                local acquired, acquire_err = self:_acquireCapture()
                if not acquired then self.notify(acquire_err) end
                self:_notifyState()
            end
        end,
        on_will_rebuild = function()
            if self.surface_session == surface then self:_releaseCapture() end
        end,
        on_durable_change = function()
            if self.surface_session == surface and self.on_durable_change then
                self.on_durable_change(self)
            end
        end,
        on_maintenance_needed = function()
            if self.surface_session == surface and self.on_maintenance_needed then
                self.on_maintenance_needed(self)
            end
        end,
    }
    self.current_page = page
    self.surface_session = surface
    self.has_previous = false
    self.has_next = false
    self.navigation_status_error = nil
    self.pending_current = persist_current and page.id or nil
    self.state_error = nil
    self.state_error_reason = nil
    local ok, err = surface:open()
    self:_notifyState()
    return ok, err
end

-- Read and validate the notebook's initial page without changing session or
-- input state. Controller uses this before handing ReaderUI's capture over,
-- so a missing/corrupt notebook cannot turn off drawing in the open book.
function Session:prepare(notebook_id)
    if self.closed then return nil, "closed" end
    if self.opened then return nil, "already_open" end
    local notebook, notebook_err = self.repository:getNotebook(notebook_id)
    if not notebook then return nil, notebook_err end
    local page, page_err
    if notebook.current_page_id then
        page, page_err = self.repository:getPage(notebook.current_page_id)
        if page and page.notebook_id ~= notebook.id then page = nil end
    end
    if not page then
        local pages
        pages, page_err = self.repository:listPages(notebook.id, { limit = 1 })
        page = pages and pages[1]
    end
    if not page then return nil, page_err or "no_page" end
    local transform, transform_err = self:_transform(page)
    if not transform then return nil, transform_err or "bad_geometry" end
    return {
        notebook = notebook,
        page = page,
        transform = transform,
        persist_current = self.repository.read_only ~= true
            and notebook.current_page_id ~= page.id,
    }
end

function Session:open(notebook_id, prepared)
    if self.closed then return nil, "closed" end
    if self.opened then return true end
    if not prepared then
        local prepare_err
        prepared, prepare_err = self:prepare(notebook_id)
        if not prepared then return nil, prepare_err end
    end
    local notebook, page, transform = prepared.notebook, prepared.page,
        prepared.transform
    if not notebook or not page or not transform or notebook.id ~= notebook_id
        or page.notebook_id ~= notebook.id then
        return nil, "bad_preflight"
    end
    self.notebook_obj = notebook
    self.opened = true
    return self:_openPage(page, prepared.persist_current, transform)
end

function Session:_beforeSwitch()
    if self:_hasActiveContact() then return nil, "contact_active" end
    local released, release_err = self:_releaseCapture()
    if not released then return nil, release_err end
    if self.abort_contact then self.abort_contact(self) end
    local saved, save_err = self:flush()
    if not saved then
        self:_acquireCapture()
        return nil, save_err
    end
    return true
end

function Session:goToPage(page_id)
    if self.closed or not self.opened then return nil, "closed" end
    if self.current_page and self.current_page.id == page_id
        and self.surface_session then return true end
    local page, page_err = self.repository:getPage(page_id)
    if not page or page.notebook_id ~= self.notebook_obj.id then
        return nil, page_err or "not_found"
    end
    local transform, transform_err = self:_transform(page)
    if not transform then return nil, transform_err or "bad_geometry" end
    local prepared, prepare_err = self:_beforeSwitch()
    if not prepared then return nil, prepare_err end
    local old_surface = self.surface_session
    if old_surface then
        local closed, close_err = old_surface:close()
        if not closed then self:_acquireCapture(); return nil, close_err end
    end
    self.surface_session = nil
    return self:_openPage(page, self.repository.read_only ~= true, transform)
end

function Session:goPrevious()
    if not self.has_previous then return nil, "boundary" end
    if not self.current_page then return nil, "no_page" end
    local page, err = self.repository:previousPage(self.current_page)
    if not page then return nil, err or "boundary" end
    return self:goToPage(page.id)
end

function Session:goNext()
    if not self.has_next then return nil, "boundary" end
    if not self.current_page then return nil, "no_page" end
    local page, err = self.repository:nextPage(self.current_page)
    if not page then return nil, err or "boundary" end
    return self:goToPage(page.id)
end

function Session:appendPage(spec)
    if self.repository.read_only then return nil, "read_only" end
    spec = spec or {}
    spec.logical_w = spec.logical_w or self.current_page.logical_w
    spec.logical_h = spec.logical_h or self.current_page.logical_h
    spec.template_kind = spec.template_kind or self.current_page.template_kind
    -- Geometry is independent of the row id. Validate it before releasing the
    -- old capture or inserting a page, so a bad future viewport cannot turn a
    -- failed UI action into a durable but invisible blank page.
    local transform, transform_err = self:_transform{
        notebook_id = self.notebook_obj.id,
        logical_w = spec.logical_w,
        logical_h = spec.logical_h,
        template_kind = spec.template_kind,
    }
    if not transform then return nil, transform_err or "bad_geometry" end
    local prepared, prepare_err = self:_beforeSwitch()
    if not prepared then return nil, prepare_err end
    local page, page_err = self.repository:appendPage(self.notebook_obj.id, spec)
    if not page then self:_acquireCapture(); return nil, page_err end
    self.notebook_obj.page_count = self.notebook_obj.page_count + 1
    if self.on_notebook_changed then self.on_notebook_changed(self) end
    local old_surface = self.surface_session
    if old_surface then
        local closed, close_err = old_surface:close()
        if not closed then self:_acquireCapture(); return nil, close_err end
    end
    self.surface_session = nil
    return self:_openPage(page, true, transform)
end

function Session:undo()
    if self:_hasActiveContact() then return nil, "contact_active" end
    if not self.surface_session then return nil, "no_page" end
    local box, err = self.surface_session:undo()
    if not box then return nil, err end
    if self.on_dirty_box then self.on_dirty_box(box, "undo", self) end
    self:_notifyState()
    return box
end

--[[--
Change the ruling of the page that is open.

The ruling lives in the raster (ADR-27), so this is a rebuild, and it is
refused for the reasons a rotation is refused: not under a live contact, not
while a commit is broken, not on a database this build may only read.

The row is written before the raster. A raster that disagrees with the row
would come back wrong on the next open with nothing to signal it, whereas a
row whose rebuild failed surfaces as the load failure the editor already
publishes a Retry for. Capture is released and reacquired by the rebuild's own
`on_will_rebuild`/`on_ready` pair, exactly as on a rotation.
]]
function Session:setPageTemplate(kind)
    if self.closed then return nil, "closed" end
    if self.repository.read_only then return nil, "read_only" end
    if not self.current_page or not self.surface_session then
        return nil, "no_page"
    end
    if self:_hasActiveContact() then return nil, "contact_active" end
    if self.surface_session:saveFailed() then return nil, "save_failed" end
    if kind == self.current_page.template_kind then return true end
    local ok, err = self.repository:setPageTemplate(
        self.notebook_obj.id, self.current_page.id, kind)
    if not ok then return nil, err end
    self.current_page.template_kind = kind
    -- Not `on_notebook_changed`: nothing was tombstoned, so the library only
    -- needs to know its recency order moved. The Controller says so, the way
    -- it does for a rename.
    local applied, apply_err = self.surface_session:setPaper(kind)
    self:_notifyState()
    if not applied then return nil, apply_err end
    return true
end

function Session:softDeleteCurrentPage()
    if not self.current_page then return nil, "no_page" end
    if self.repository.read_only then return nil, "read_only" end
    if self.notebook_obj.page_count <= 1 then return nil, "last_page" end
    local prepared, prepare_err = self:_beforeSwitch()
    if not prepared then return nil, prepare_err end
    local old_page = self.current_page
    local selected, neighbour_err = self.repository:previousPage(old_page)
    if not selected and neighbour_err then
        self:_acquireCapture()
        return nil, neighbour_err
    end
    if not selected then
        selected, neighbour_err = self.repository:nextPage(old_page)
        if not selected and neighbour_err then
            self:_acquireCapture()
            return nil, neighbour_err
        end
    end
    if not selected then self:_acquireCapture(); return nil, "last_page" end
    local transform, transform_err = self:_transform(selected)
    if not transform then
        self:_acquireCapture()
        return nil, transform_err or "bad_geometry"
    end
    local old_surface = self.surface_session
    local closed, close_err = old_surface:close()
    if not closed then self:_acquireCapture(); return nil, close_err end
    self.surface_session = nil
    self.pending_delete_page = old_page.id
    local opened, open_err = self:_openPage(selected, true, transform)
    if not opened and not self.surface_session then
        self.pending_delete_page = nil
        self:_openPage(old_page, false)
    end
    return opened, open_err
end

function Session:flush()
    if self.surface_session then
        local saved, save_err = self.surface_session:flush()
        if not saved then return nil, save_err end
    end
    return self:_retryMetadata()
end

function Session:retryLoad()
    if not self.surface_session then return nil, "no_page" end
    return self.surface_session:retryLoad()
end

function Session:retrySave()
    if self.pending_current or self.pending_delete_page then
        local saved, save_err = self:_retryMetadata()
        if not saved then return nil, save_err end
        self:_acquireCapture(true)
        self:_notifyState()
        return true
    end
    if not self.surface_session then return true end
    return self.surface_session:retrySave()
end

function Session:onScreenResize(fit_rect, clip_rect)
    if not self.current_page or not self.surface_session then return true end
    if self:_hasActiveContact() then
        if not self.abort_contact then return nil, "contact_active" end
        self.abort_contact(self)
    end
    local released, release_err = self:_releaseCapture()
    if not released then return nil, release_err end
    local saved, save_err = self:flush()
    if not saved then return nil, save_err end
    local old_fit, old_clip = self.fit_rect, self.clip_rect
    self.fit_rect, self.clip_rect = fit_rect, clip_rect or fit_rect
    local transform, transform_err = self:_transform(self.current_page)
    if not transform then
        self.fit_rect, self.clip_rect = old_fit, old_clip
        self:_acquireCapture()
        return nil, transform_err
    end
    local changed, change_err = self.surface_session:setTransform(transform)
    if not changed then return nil, change_err end
    if self.surface_session:isReady() then self:_acquireCapture() end
    return true
end

function Session:onSuspend()
    if self.abort_contact then self.abort_contact(self) end
    return self:_releaseCapture()
end

function Session:onResume()
    if self.closed then return nil, "closed" end
    -- Resume restores only a healthy capture. A deterministic handler failure
    -- remains visible until the user invokes retryInput explicitly.
    return self:_acquireCapture()
end

function Session:retryInput()
    if self.closed then return nil, "closed" end
    self.input_error = nil
    local ok, err = self:_acquireCapture(true)
    self:_notifyState()
    return ok, err
end

function Session:reconfigureInput(apply)
    if self.closed then return nil, "closed" end
    if self:_hasActiveContact() then return nil, "contact_active" end
    local released, release_err = self:_releaseCapture()
    if not released then return nil, release_err end
    if apply then apply() end
    self.input_error = nil
    local acquired, acquire_err = self:_acquireCapture(true)
    self:_notifyState()
    return acquired, acquire_err
end

function Session:close()
    if self.closed then return true end
    if self:_hasActiveContact() then return nil, "contact_active" end
    local flushed, flush_err = self:flush()
    if not flushed then return nil, flush_err end
    local released, release_err = self:_releaseCapture()
    if not released then return nil, release_err end
    if self.surface_session then
        local saved, save_err = self.surface_session:close()
        if not saved then
            self:_acquireCapture()
            return nil, save_err
        end
    end
    self.surface_session = nil
    self.current_page = nil
    self.closed = true
    self:_notifyState()
    return true
end


-- KOReader cannot veto every host close.  This path gives up the final
-- retryable queue only after recording the error, but it never leaves the
-- process-wide input hook pointing at a destroyed plugin instance.
function Session:shutdown()
    if self.closed then return true end
    if self.abort_contact then pcall(self.abort_contact, self) end
    local first_error
    local released, release_err = self:_releaseCapture()
    if not released then
        first_error = release_err
        local owner = self.input_owner or self
        self.input_controller:forceRelease(owner, "shutdown")
        self.input_lease = nil
    end
    local durable, durable_err = self:flush()
    if not durable then first_error = first_error or durable_err or "save_failed" end
    if self.surface_session then
        if durable then
            local closed, close_err = self.surface_session:close()
            if not closed then
                first_error = first_error or close_err
                self.surface_session:close{ discard = true }
            end
        else
            self.surface_session:close{ discard = true }
        end
    end
    self.surface_session = nil
    self.current_page = nil
    self.pending_current = nil
    self.pending_delete_page = nil
    self.closed = true
    self:_notifyState()
    if first_error then return nil, first_error end
    return true
end

return Session
