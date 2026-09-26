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
    if rows then self:_seedMaintenance() end
    return rows, list_err
end

--[[--
One batch of the gallery: folders first (at the root only), then notebooks in
`opts.sort`, `limit` items in all. Folders are paginated with the notebooks
rather than loaded whole, so the cursor says which list it is in:
`{ phase = "folders", after_name, after_id }` or
`{ phase = "notebooks", cursor = <the repository's cursor> }`.

A repository without folders (an older fake, a store that predates v3) is
listed the old way, by recency, with no folders.
]]
function Controller:listNotebookBatch(cursor, limit, opts)
    limit = tonumber(limit) or 50
    limit = math.max(1, math.min(199, math.floor(limit)))
    opts = opts or {}
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if not repo.listNotebookPage then return self:_legacyBatch(cursor, limit) end
    local folder_id = opts.folder_id
    local sort = opts.sort or "recent"
    local items, next_cursor = {}, nil
    local phase = cursor and cursor.phase or (folder_id and "notebooks" or "folders")
    if phase == "folders" and not folder_id then
        local folders, folder_err = repo:listFolders{
            after_name = cursor and cursor.after_name,
            after_id = cursor and cursor.after_id,
            limit = limit + 1,
        }
        if not folders then return nil, folder_err end
        for i = 1, math.min(limit, #folders) do
            folders[i].kind = "folder"
            items[#items + 1] = folders[i]
        end
        if #folders > limit then
            local last = items[#items]
            next_cursor = { phase = "folders", after_name = last.name, after_id = last.id }
        end
    end
    if not next_cursor then
        local room = limit - #items
        local repo_cursor = cursor and cursor.phase == "notebooks" and cursor.cursor or nil
        -- With no room left, one row is still asked for: it says whether a
        -- next screen exists, so Next is never offered onto an empty screen.
        local rows, rows_next = repo:listNotebookPage{
            scope = folder_id and "folder" or "root", folder_id = folder_id,
            sort = sort, cursor = repo_cursor, limit = math.max(1, room),
        }
        if not rows then return nil, rows_next end
        if room == 0 then
            if #rows > 0 then next_cursor = { phase = "notebooks" } end
        else
            for _, row in ipairs(rows) do
                row.kind = "notebook"
                items[#items + 1] = row
            end
            if rows_next then next_cursor = { phase = "notebooks", cursor = rows_next } end
        end
    end
    self:_seedMaintenance()
    return {
        items = items,
        input_cursor = cursor,
        next_cursor = next_cursor,
        has_more = next_cursor ~= nil,
        folder_id = folder_id,
        sort = sort,
        writable = self.repository and self.repository.read_only ~= true or false,
        read_only_code = self.repository and self.repository.read_only
            and "schema_newer" or nil,
    }
end

-- A library walk may request hundreds of keyset pages. Seed maintenance once
-- when the library first opens; subsequent tombstones explicitly schedule it
-- from delete/undo/erase paths.
function Controller:_seedMaintenance()
    if not self.maintenance_seeded then
        self.maintenance_seeded = true
        self:schedulePurge()
    end
end

function Controller:_legacyBatch(cursor, limit)
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

--- A repository call that changes the library, announced when it did.
function Controller:_mutate(method, ...)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if repo.read_only then return nil, "read_only" end
    if not repo[method] then return nil, "unsupported" end
    local a, b = repo[method](repo, ...)
    if a and self.on_library_changed then self.on_library_changed(self) end
    return a, b
end

function Controller:listFolders(opts)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if not repo.listFolders then return {} end
    return repo:listFolders(opts)
end

function Controller:createFolder(name) return self:_mutate("createFolder", name) end
function Controller:renameFolder(id, name) return self:_mutate("renameFolder", id, name) end
function Controller:deleteFolder(id) return self:_mutate("deleteFolder", id) end
function Controller:moveNotebook(id, folder_id) return self:_mutate("moveNotebook", id, folder_id) end

--[[--
What the gallery asks `ink_thumbnail` for to draw a notebook's card: its live
current page (or first page), identified by database, notebook, page and
content revision, at `w` x `h`.
]]
function Controller:thumbnailRequest(item, w, h)
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if not repo.thumbnailPage or not repo.dbUid then return nil, "unsupported" end
    local page, notebook = repo:thumbnailPage(item.id)
    if not page then return nil, notebook end
    local uid, uid_err = repo:dbUid()
    if not uid then return nil, uid_err end
    return require("ink_thumbnail").request(uid, notebook, page, w, h)
end

--[[--
Copy a notebook in bounded batches, one per scheduler tick, hidden until it is
complete (ADR-58). `opts.title` names the copy; `opts.on_done(new_id | nil,
reason)` runs once. Returns a job with `cancel()`, which abandons the copy --
the partial rows are purged later, in batches -- and never calls `on_done`.

The source is flushed first when it is the open notebook, so the copy has what
the reader sees; a later edit to the source makes the copy fail rather than
come out half old and half new (`source_changed`).
]]
Controller.COPY_LIMITS = { strokes = 32, chunks = 128, bytes = 512 * 1024 }

function Controller:duplicateNotebook(id, opts)
    opts = opts or {}
    local repo, err = self:_ensureRepository()
    if not repo then return nil, err end
    if repo.read_only then return nil, "read_only" end
    if not repo.beginCopy then return nil, "unsupported" end
    if self.active_session and self.active_session:notebook().id == id then
        self:onFlushSettings()
    end
    local state, begin_err = repo:beginCopy(id, opts.title)
    if not state then return nil, begin_err end
    local job = { done = false }
    local action
    local function settle(new_id, reason)
        if job.done then return end
        job.done = true
        if not new_id then
            repo:cancelCopy(state)
            self:schedulePurge()
        elseif self.on_library_changed then
            self.on_library_changed(self)
        end
        if opts.on_done then opts.on_done(new_id, reason) end
    end
    action = function()
        if job.done or self.closed then return end
        local finished, batch_err = repo:copyBatch(state, opts.limits or Controller.COPY_LIMITS)
        if finished == nil then return settle(nil, batch_err or "copy_failed") end
        if not finished then
            self.schedule(action)
            return
        end
        local new_id, finish_err = repo:finishCopy(state)
        settle(new_id, finish_err)
    end
    function job.cancel()
        if job.done then return false end
        job.done = true
        self.unschedule(action)
        repo:cancelCopy(state)
        self:schedulePurge()
        return true
    end
    self.schedule(action)
    return job
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

function Controller:redo()
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:redo()
end

function Controller:goToPagePosition(position)
    if not self.active_session then return nil, "no_notebook" end
    return self.active_session:goToPagePosition(position)
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
    local counts, purge_err = repo:purgeDeletedBatch(limits)
    -- Abandoned copies (cancelled here, or left by a process that died) go
    -- in the same bounded passes, once the tombstones are done.
    if counts and not (counts.changed and counts.changed > 0) and repo.purgeAbandonedCopies then
        local finished = repo:purgeAbandonedCopies(limits)
        if finished == false then counts.changed = 1 end
    end
    return counts, purge_err
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
