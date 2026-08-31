--[[--
Headless application controller for standalone notebooks.

It owns the repository connection lazily and at most one NotebookSession. The
FileManager/ReaderUI windows consume this API without knowing SQL, stroke
chunks or input hooks.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")

local Compat = require("ink_compat")
local Repository = require("ink_notebook_repository")
local NotebookSession = require("ink_notebook_session")

local Controller = {}
Controller.__index = Controller

function Controller.new(opts)
    opts = opts or {}
    return setmetatable({
        repository = opts.repository,
        owns_repository = false,
        repository_factory = opts.repository_factory,
        path = opts.path,
        schedule = opts.schedule or function(fn) UIManager:nextTick(fn) end,
        scheduleIn = opts.scheduleIn
            or function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = opts.unschedule or function(fn) UIManager:unschedule(fn) end,
        notify = opts.notify or function() end,
        session_opts = opts.session_opts or {},
        before_open = opts.before_open,
        viewport_provider = opts.viewport_provider,
        require_viewport = opts.require_viewport == true,
        on_state_changed = opts.on_state_changed,
        on_durable_change = opts.on_durable_change,
        on_library_changed = opts.on_library_changed,
        active_session = nil,
        purge_requested = false,
        purge_action = nil,
        purge_limits = nil,
        maintenance_seeded = false,
        closed = false,
    }, Controller)
end

function Controller:_databasePath()
    if self.path then return self.path end
    local DataStorage = require("datastorage")
    return Compat.databasePath(DataStorage:getSettingsDir(),
        "justdraw-notebooks.sqlite3", "fingerink-notebooks.sqlite3")
end

function Controller:_ensureRepository()
    if self.closed then return nil, "closed" end
    if self.repository then return self.repository end
    local repo, err
    if self.repository_factory then
        repo, err = self.repository_factory(self)
    else
        local path, path_err = self:_databasePath()
        if not path then return nil, path_err end
        repo, err = Repository.open{
            path = path,
            wal = Device.canUseWAL and Device:canUseWAL() or false,
        }
    end
    if not repo then return nil, err end
    self.repository = repo
    self.owns_repository = true
    return repo
end

--[[--
The read side of the notebook store, for one export.

The controller stays the owner of the connection's lifetime; what an export
borrows is the ability to read pages and strokes for as long as its job runs.
It never writes, which is what lets this be a plain accessor rather than a
second write path with its own ordering rules.
]]
function Controller:exportRepository()
    return self:_ensureRepository()
end

function Controller:listNotebooks(cursor, limit)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    local opts = { limit = limit }
    if cursor then
        opts.after_updated_at = cursor.updated_at
        opts.after_id = cursor.id
    end
    local rows, list_err = repo:listNotebooks(opts)
    -- A library walk may request hundreds of keyset pages. Seed maintenance
    -- once when the library first opens; subsequent tombstones explicitly
    -- schedule it from delete/undo/erase paths.
    if rows and not self.maintenance_seeded then
        self.maintenance_seeded = true
        self:schedulePurge()
    end
    return rows, list_err
end

function Controller:listNotebookBatch(cursor, limit)
    limit = tonumber(limit) or 50
    limit = math.max(1, math.min(199, math.floor(limit)))
    local rows, err = self:listNotebooks(cursor, limit + 1)
    if not rows then return nil, err end
    local has_more = #rows > limit
    if has_more then table.remove(rows) end
    local last = rows[#rows]
    return {
        items = rows,
        input_cursor = cursor and {
            updated_at = cursor.updated_at, id = cursor.id,
        } or nil,
        next_cursor = has_more and last and {
            updated_at = last.updated_at, id = last.id,
        } or nil,
        has_more = has_more,
        writable = self.repository and self.repository.read_only ~= true or false,
        read_only_code = self.repository and self.repository.read_only
            and "schema_newer" or nil,
    }
end

-- Configure the non-visual interaction seam before a notebook is opened.
-- NotebookWindow may provide viewport and repaint callbacks later without
-- reaching into Controller.session_opts or any SQL object.
function Controller:configureInteraction(opts)
    if self.active_session then return nil, "notebook_open" end
    opts = opts or {}
    local allowed = {
        input_controller = true, capture_spec = true, abort_contact = true,
        transform_factory = true, fit_rect = true, clip_rect = true,
        align_x = true, align_y = true, on_page_ready = true,
        on_dirty_box = true,
    }
    for key in pairs(allowed) do
        if opts[key] ~= nil then self.session_opts[key] = opts[key] end
    end
    if opts.viewport_provider ~= nil then
        self.viewport_provider = opts.viewport_provider
    end
    if opts.on_state_changed ~= nil then
        self.on_state_changed = opts.on_state_changed
    end
    if opts.on_durable_change ~= nil then
        self.on_durable_change = opts.on_durable_change
    end
    if opts.on_library_changed ~= nil then
        self.on_library_changed = opts.on_library_changed
    end
    return true
end

function Controller:createNotebook(spec)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    local notebook, page = repo:createNotebook(spec)
    if notebook and self.on_library_changed then self.on_library_changed(self) end
    return notebook, page
end

function Controller:renameNotebook(id, title)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    local ok, rename_err = repo:renameNotebook(id, title)
    if ok and self.on_library_changed then self.on_library_changed(self) end
    return ok, rename_err
end

function Controller:deleteNotebook(id)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if repo.read_only then return nil, "read_only" end
    if self.active_session and self.active_session:notebook().id == id then
        local closed, close_err = self:closeNotebook()
        if not closed then return nil, close_err end
    end
    local ok, delete_err = repo:softDeleteNotebook(id)
    if ok then
        if self.on_library_changed then self.on_library_changed(self) end
        self:schedulePurge()
    end
    return ok, delete_err
end

function Controller:openNotebook(id)
    if self.require_viewport and not self.viewport_provider
        and not self.session_opts.fit_rect
        and not self.session_opts.transform_factory then
        return nil, "no_viewport"
    end
    local initial_fit, initial_clip
    if self.viewport_provider then
        local provided, fit, clip = pcall(self.viewport_provider, nil, self, id)
        if not provided then return nil, "no_viewport" end
        if not fit then return nil, clip or "no_viewport" end
        initial_fit, initial_clip = fit, clip or fit
    end
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    local extra = self.session_opts
    local session = NotebookSession.new{
        repository = repo,
        schedule = self.schedule,
        scheduleIn = self.scheduleIn,
        unschedule = self.unschedule,
        notify = self.notify,
        input_controller = extra.input_controller,
        input_owner = self,
        capture_spec = extra.capture_spec,
        abort_contact = extra.abort_contact,
        transform_factory = extra.transform_factory,
        fit_rect = initial_fit or extra.fit_rect,
        clip_rect = initial_clip or extra.clip_rect,
        align_x = extra.align_x,
        align_y = extra.align_y,
        on_page_ready = extra.on_page_ready,
        on_dirty_box = extra.on_dirty_box,
        on_notebook_changed = function()
            if self.on_library_changed then self.on_library_changed(self) end
            self:schedulePurge()
        end,
        on_durable_change = function()
            if self.on_library_changed then self.on_library_changed(self) end
            if self.on_durable_change and self.active_session == session then
                self.on_durable_change(session, self)
            end
        end,
        on_maintenance_needed = function() self:schedulePurge() end,
        on_state_changed = function(state, active)
            if self.active_session == active then
                if self.on_state_changed then self.on_state_changed(state, self) end
                if self.purge_requested
                    and (state == "ready" or state == "input_failed"
                        or state == "load_failed") then
                    self:_schedulePurgeTick()
                end
            end
        end,
    }
    local prepared, prepare_err = session:prepare(id)
    if not prepared then return nil, prepare_err end
    if self.active_session then
        local closed, close_err = self:closeNotebook()
        if not closed then return nil, close_err end
        -- Closing can durably advance current_page_id when the same notebook
        -- is reopened, so do not consume the pre-close snapshot.
        prepared, prepare_err = session:prepare(id)
        if not prepared then return nil, prepare_err end
    end
    if self.before_open then
        local ready, ready_err = self.before_open(id, self)
        if not ready then return nil, ready_err or "input_busy" end
    end
    self.active_session = session
    local opened, open_err = session:open(id, prepared)
    if not opened and session:stateName() == "closed" then
        self.active_session = nil
        return nil, open_err
    end
    return session, open_err
end

function Controller:activeSession()
    return self.active_session
end

function Controller:closeNotebook()
    if not self.active_session then return true end
    local session = self.active_session
    local ok, err = session:close()
    if not ok then return nil, err end
    if self.active_session == session then self.active_session = nil end
    if self.purge_requested then self:_schedulePurgeTick() end
    return true
end

function Controller:retryLoad()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:retryLoad()
end

function Controller:retrySave()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:retrySave()
end

function Controller:retryInput()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:retryInput()
end

function Controller:uiSnapshot()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:uiSnapshot()
end

function Controller:undo()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:undo()
end

function Controller:goPrevious()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:goPrevious()
end

function Controller:goNext()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:goNext()
end

function Controller:appendPage(spec)
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:appendPage(spec)
end

function Controller:deleteCurrentPage()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:softDeleteCurrentPage()
end

function Controller:setPageTemplate(kind)
    if not self.active_session then return nil, "no_notebook" end
    local ok, err = self.active_session:setPageTemplate(kind)
    if ok and self.on_library_changed then self.on_library_changed(self) end
    return ok, err
end

function Controller:reconfigureInput(apply)
    if not self.active_session then
        if apply then apply() end
        return true
    end
    return self.active_session:reconfigureInput(apply)
end

function Controller:onFlushSettings()
    if not self.active_session then return true end
    return self.active_session:flush()
end

function Controller:onSuspend()
    if not self.active_session then return true end
    return self.active_session:onSuspend()
end

function Controller:onResume()
    if not self.active_session then return true end
    return self.active_session:onResume()
end

function Controller:onScreenResize(fit_rect, clip_rect)
    if not self.active_session then return true end
    if not fit_rect and self.viewport_provider then
        local provided
        provided, fit_rect, clip_rect = pcall(
            self.viewport_provider, self.active_session, self)
        if not provided then return nil, "no_viewport" end
    end
    if not fit_rect then return nil, "no_viewport" end
    return self.active_session:onScreenResize(fit_rect, clip_rect)
end

function Controller:runOnePurgeBatch(limits)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    local session = self.active_session
    if session and session.input_lease and session.input_lease:hasActiveContact() then
        return nil, "contact_active"
    end
    if session and session:stateName() == "loading" then return nil, "loading" end
    if session and session:stateName() == "save_failed" then return nil, "save_failed" end
    return repo:purgeDeletedBatch(limits)
end

function Controller:_schedulePurgeTick(delay)
    if self.closed or self.purge_action or not self.purge_requested then return true end
    local action
    action = function()
        if self.purge_action == action then self.purge_action = nil end
        if self.closed or not self.purge_requested then return end
        local counts, err = self:runOnePurgeBatch(self.purge_limits)
        if not counts then
            if err == "contact_active" then
                self:_schedulePurgeTick(0.25)
            elseif err ~= "loading" and err ~= "save_failed" then
                self.purge_requested = false
                self.notify(err or "purge_failed")
            end
            return
        end
        if counts.changed and counts.changed > 0 then
            self:_schedulePurgeTick()
        else
            self.purge_requested = false
            self.purge_limits = nil
        end
    end
    self.purge_action = action
    if delay then self.scheduleIn(delay, action) else self.schedule(action) end
    return true
end

function Controller:schedulePurge(limits)
    if self.closed then return nil, "closed" end
    if self.repository and self.repository.read_only then return nil, "read_only" end
    self.purge_requested = true
    if limits then self.purge_limits = limits end
    return self:_schedulePurgeTick()
end

function Controller:close()
    if self.closed then return true end
    local closed, close_err = self:closeNotebook()
    if not closed then return nil, close_err end
    if self.purge_action then self.unschedule(self.purge_action) end
    self.purge_action = nil
    self.purge_requested = false
    if self.owns_repository and self.repository and self.repository.close then
        self.repository:close()
    end
    self.repository = nil
    self.owns_repository = false
    self.closed = true
    return true
end

function Controller:shutdown()
    if self.closed then return true end
    local first_error
    if self.purge_action then self.unschedule(self.purge_action) end
    self.purge_action = nil
    self.purge_requested = false
    if self.active_session then
        local session = self.active_session
        local input_controller = session.input_controller
        local stopped, stop_err = session:shutdown()
        if not stopped then first_error = stop_err end
        -- A handler error may already have detached the lease from Session
        -- while InputController still owns its deferred next-tick removal.
        -- Host teardown cannot wait for that tick, so finish only this
        -- controller's lease synchronously before allowing a successor.
        if input_controller and input_controller.forceRelease then
            local forced, force_err = input_controller:forceRelease(self, "shutdown")
            if not forced and force_err ~= "not_owner" then
                first_error = first_error or force_err
            end
        end
        self.active_session = nil
    end
    if self.owns_repository and self.repository and self.repository.close then
        self.repository:close()
    end
    self.repository = nil
    self.owns_repository = false
    self.closed = true
    if first_error then return nil, first_error end
    return true
end

return Controller
