--[[-- Coordinate notebook windows without leaking widgets into the domain. ]]

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("ink_i18n")

local Clipboard = require("ink_clipboard")
local Errors = require("ink_notebook_errors")
local NotebookLayout = require("ink_notebook_layout")
local Editor = require("ink_notebook_editor")
local Library = require("ink_notebook_library")
local LocalSend = require("ink_localsend")

local NotebookUI = {}
NotebookUI.__index = NotebookUI

function NotebookUI.new(opts)
    opts = opts or {}
    return setmetatable({
        plugin = assert(opts.plugin),
        controller = assert(opts.controller),
        library_factory = opts.library_factory or Library,
        thumbnail_factory = opts.thumbnail_factory,
        find_localsend = opts.find_localsend,
        send_root = opts.send_root,
        send_fs = opts.send_fs,
        editor_factory = opts.editor_factory or Editor,
        library = nil,
        editor = nil,
        editor_generation = 0,
        library_needs_layout = false,
        closed = false,
    }, NotebookUI)
end

function NotebookUI:_showLibraryError(reason)
    logger.warn("JustDraw notebooks: operation failed:", reason)
    local code = Errors.normalize(reason, "library")
    local text = code == "contact_active" and _("Lift the pen and try again.")
        or code == "no_viewport"
            and _("This screen is too small for the notebook controls. Rotate the device or lower the screen DPI and try again.")
        or _("Couldn’t open the notebook library.")
    if self.library and not self.library.closed then
        self.library:_showInfo(text)
    else
        UIManager:show(InfoMessage:new{ text = text })
    end
end

function NotebookUI:openLibrary()
    if self.closed then return nil, "closed" end
    if self.library then return self.library end
    local library = self.library_factory:new{
        controller = self.controller,
        is_covered = function() return self.editor ~= nil end,
        on_open = function(item) self:openNotebook(item) end,
        on_close = function() self:closeLibrary() end,
        can_send = function() return self:findLocalSend() ~= nil end,
        send_items = function(items, host) return self:sendNotebooks(items, host) end,
        thumbnail_factory = self.thumbnail_factory ~= false
            and (self.thumbnail_factory or function() return self:_newThumbnails() end)
            or nil,
    }
    self.library = library
    UIManager:show(library, "ui")
    library:markShown()
    library:startLoading()
    return library
end

--[[--
The gallery's thumbnail queue: files under KOReader's cache directory, the
export's raster, MuPDF's reduction and KOReader's PNG writer (ADR-58). One per
library window; closing the window closes it and cancels its job.
]]
function NotebookUI:_newThumbnails()
    local DataStorage = require("datastorage")
    local Thumbs = require("ink_thumbnail")
    local deps = Thumbs.nativeDeps()
    local controller = self.controller
    local dir = DataStorage:getDataDir() .. "/cache/justdraw-thumbnails"
    deps.fs.mkdir(DataStorage:getDataDir() .. "/cache")
    deps.fs.mkdir(dir)
    return Thumbs.new{
        dir = dir,
        repository = function() return controller:exportRepository() end,
        schedule = function(delay, fn)
            if delay and delay > 0 then UIManager:scheduleIn(delay, fn)
            else UIManager:nextTick(fn) end
        end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        raster_open = deps.raster_open, scale = deps.scale, write = deps.write,
        fs = deps.fs,
    }
end

function NotebookUI:onSuspend()
    LocalSend.cancelActive()
    if self.library then self.library:onSuspend() end
    return true
end

--- LocalSend, looked up now: never kept, since it is recreated with the
--- reader (ADR-60). `opts.find_localsend` replaces the lookup in tests.
function NotebookUI:findLocalSend()
    if self.find_localsend then return self.find_localsend() end
    local ok, loader = pcall(require, "pluginloader")
    return LocalSend.find(self.plugin.ui, ok and loader or nil)
end

--- The staging area, made on first use; the first use in a process also
--- sweeps what earlier processes left (conservatively: see ink_localsend).
function NotebookUI:_sendStaging()
    if self.send_staging then return self.send_staging end
    local root = self.send_root
    if not root then
        local DataStorage = require("datastorage")
        local cache = DataStorage:getDataDir() .. "/cache"
        LocalSend.nativeFs().mkdir(cache)
        root = cache .. "/" .. LocalSend.ROOT_NAME
    end
    self.send_staging = LocalSend.staging{ root = root, fs = self.send_fs }
    local ok, report = pcall(self.send_staging.sweep, self.send_staging)
    if not ok then logger.warn("JustDraw: send sweep failed:", report) end
    return self.send_staging
end

--[[--
Export `notebooks` and open LocalSend on them. `host` is the window asking
(library or editor): its modals carry the questions and its messages the
answers.
]]
function NotebookUI:sendNotebooks(notebooks, host)
    local controller = self.controller
    local ExportDialog = require("ink_export_dialog")
    -- The editor's modals go through its contact-aware seam; the library's
    -- through its own.
    local function show(widget)
        if host.showModalSafely then return host:showModalSafely(widget) end
        return host:_showModal(widget)
    end
    local function close(widget) return host:_closeModal(widget) end
    return LocalSend.send{
        items = notebooks,
        find = function() return self:findLocalSend() end,
        staging = self:_sendStaging(),
        export_one = function(item, format, dir, stem, done)
            local repository, repo_err = controller:exportRepository()
            if not repository then
                logger.warn("JustDraw: send export has no repository:", repo_err)
                return done(nil)
            end
            local build = Library._exportBuild({ controller = controller }, item, repository, done)
            local built_once = false
            local active_job = {}
            ExportDialog.run{
                -- The progress box's Cancel, and the send's, reach this job.
                active_job = active_job,
                build = function(scope, fmt)
                    local built, err = build(scope, fmt or format)
                    built_once = built ~= nil
                    return built, err
                end,
                format = format, dir = dir, stem = stem,
                -- The send asked about Xournal++'s limits once, for all.
                xopp_notice_shown = true,
                notify = function(text) logger.info("JustDraw: send export:", text) end,
                show_modal = show,
                close_modal = close,
            }
            if not built_once then done(nil) end
            return { cancel = function()
                local job = active_job.job
                if job and job.cancel then job:cancel() end
            end }
        end,
        show_modal = show,
        close_modal = close,
        xopp_notice = function() return ExportDialog.xoppNotice() end,
        toast = function(text) UIManager:show(Notification:new{ text = text }) end,
        notify = function(text) return host:_showInfo(text) end,
        schedule = function(fn) UIManager:nextTick(fn) end,
    }
end

function NotebookUI:closeLibrary()
    if not self.library then return true end
    if self.editor then return nil, "notebook_open" end
    local library = self.library
    self.library = nil
    UIManager:close(library, "ui")
    library:shutdown()
    return true
end

function NotebookUI:_editorCallbacks(editor, generation)
    local function current()
        return not self.closed and self.editor_generation == generation
            and (self.editor == nil or self.editor == editor)
    end
    return {
        viewport_provider = function()
            if not current() then return nil, "no_viewport" end
            return editor:viewport()
        end,
        touch_passthrough = function(x, y)
            return current() and editor:touchPassthrough(x, y) or false
        end,
        stylus_passthrough = function(x, y)
            return current() and editor:stylusPassthrough(x, y) or false
        end,
        on_dirty = function(...)
            if current() then editor:onDirty(...) end
        end,
        on_edit_changed = function(session)
            if current() then editor:onEditChanged(session) end
        end,
        get_tool = function()
            if not current() then return "pen" end
            return editor.get_tool()
        end,
        get_edit_controller = function(tool)
            if current() and editor.editController then return editor:editController(tool) end
            return nil
        end,
        on_physical_contact_end = function(session, reason)
            if current() then editor:onPhysicalContactEnd(session, reason) end
        end,
        on_stylus_frame = function()
            if current() then editor:onStylusFrame() end
        end,
        on_page_ready = function(...)
            if current() then editor:onPageReady(...) end
        end,
        on_state_changed = function()
            if current() then editor:onStateChanged() end
        end,
        on_durable_change = function(session)
            if current() then editor:onDurableChanged(session) end
        end,
        on_library_changed = function()
            if current() then self:onLibraryChanged() end
        end,
        on_dirty_box = function(box, kind, session)
            if current() and self.plugin.notebook_input then
                self.plugin.notebook_input:presentDirtyBox(box, kind, session)
            end
        end,
        on_error = function(reason)
            logger.warn("JustDraw notebooks: input failed:", reason)
            if not current() then return end
            editor:onStateChanged()
            local message
            if reason == "queue_backpressure" then
                message = _("Stroke was not saved because the write queue is busy. Try again.")
            elseif reason == "point_budget" or reason == "sample_budget"
                or reason == "operation_too_large" then
                message = _("Stroke stopped because the pen contact did not end. Lift the pen and try again.")
            end
            if message then
                UIManager:nextTick(function()
                    if current() then
                        UIManager:show(Notification:new{ text = message })
                    end
                end)
            end
        end,
    }
end

-- Controller and input adapter outlive an editor window. Replace every
-- window-capturing callback when that editor is gone so a closed widget tree
-- is not retained until the next notebook opens.
function NotebookUI:_clearEditorCallbacks()
    local cleared, clear_err = self.plugin:configureNotebookInteraction{
        viewport_provider = false,
        touch_passthrough = false,
        stylus_passthrough = false,
        on_dirty = false,
        on_edit_changed = false,
        get_tool = false,
        get_edit_controller = false,
        on_physical_contact_end = false,
        on_page_ready = false,
        on_state_changed = false,
        on_durable_change = false,
        on_library_changed = false,
        on_dirty_box = false,
        on_error = false,
    }
    if not cleared then
        logger.warn("JustDraw notebooks: callback cleanup failed:", clear_err)
    end
    return cleared, clear_err
end

function NotebookUI:openNotebook(item)
    if self.closed then return nil, "closed" end
    if self.editor then return nil, "notebook_open" end
    if type(item) ~= "table" or item.id == nil then return nil, "bad_id" end
    -- Nine 10 mm controls must fit across (ADR-54). Refuse here, while the
    -- library is still up to say why, instead of opening an editor with a
    -- partial header -- or none, and no way back to Exit.
    local fits, fit_err = NotebookLayout.screenPage()
    if not fits then
        self:_showLibraryError(fit_err or "no_viewport")
        return nil, fit_err or "no_viewport"
    end
    self.editor_generation = self.editor_generation + 1
    local generation = self.editor_generation
    -- Declare before constructing: Lua does not put a local in scope inside
    -- its own initializer, and on_close must capture this exact window.
    local editor
    editor = self.editor_factory:new{
        controller = self.controller,
        notebook = item,
        get_eraser = function() return self.plugin.eraser end,
        set_eraser = function(value)
            self.plugin:setTool(value and "eraser" or "pen", { quiet = true })
        end,
        get_tool = function() return self.plugin:toolFor("notebook") end,
        set_tool = function(value) self.plugin:setTool(value, { quiet = true }) end,
        observe_tool = function(fn) return self.plugin:observeTool(fn) end,
        -- Editing tools wired in this build (ADR-55/56): Edit offers only these.
        edit_tools_ready = function(tool)
            return tool == "select" or tool == "paste" or tool == "shape"
        end,
        get_shape_options = function() return self.plugin:getShapeOptions() end,
        set_shape_options = function(o) return self.plugin:setShapeOptions(o) end,
        get_previous_tool = function() return self.plugin.previous_tool end,
        clipboard_has_content = function() return Clipboard.hasContent() end,
        can_send = function() return self:findLocalSend() ~= nil end,
        send_notebook = function(notebook, host) return self:sendNotebooks({ notebook }, host) end,
        get_input_mode = function() return self.plugin.input_mode end,
        set_input_mode = function(value) return self.plugin:setInputMode(value) end,
        get_pen_width = function() return self.plugin.pen_width end,
        set_pen_width = function(value) return self.plugin:setPenWidth(value) end,
        set_pen_style = function(v) return self.plugin:setPenStyle(v) end,
        get_raw_pen_style = function() return self.plugin.pen_style end,
        get_drawing_refresh_ms = function()
            return self.plugin:getDrawingRefreshInterval()
        end,
        set_drawing_refresh_ms = function(ms)
            return self.plugin:setDrawingRefreshInterval(ms)
        end,
        get_live_fast = function() return self.plugin.live_fast end,
        get_rail_side = function() return self.plugin.notebook_rail_side end,
        show_stylus_diagnostics = function()
            return self.plugin:showDiagnostics("notebook")
        end,
        set_rail_side = function(value) self.plugin:setNotebookRailSide(value) end,
        has_active_contact = function()
            return self.plugin.notebook_input
                and self.plugin.notebook_input:hasActiveContact() or false
        end,
        -- The refresh timing trace rides on the stylus diagnostics: the same
        -- 60-second window the reader already agreed to, in the same log, so a
        -- calibration run needs one button and produces one file.
        quality_trace_enabled = function()
            return self.plugin:activeStylusTrace("notebook") ~= nil
        end,
        control_touch_allowed = function()
            return not self.plugin.notebook_input
                or self.plugin.notebook_input:controlTouchAllowed()
        end,
        show_host_message = function(text)
            if self.library and not self.library.closed then
                self.library:_showInfo(text)
            else
                UIManager:show(InfoMessage:new{ text = text })
            end
        end,
        on_close = function() self:_editorClosed(editor, generation) end,
    }
    local callbacks = self:_editorCallbacks(editor, generation)
    local configured, configure_err = self.plugin:configureNotebookInteraction(callbacks)
    if not configured then
        if self.editor_generation == generation then
            self.editor_generation = self.editor_generation + 1
        end
        editor:shutdown()
        self:_showLibraryError(configure_err)
        return nil, configure_err
    end
    local session, open_err = self.controller:openNotebook(item.id)
    if not session then
        if self.editor_generation == generation then
            self.editor_generation = self.editor_generation + 1
        end
        self:_clearEditorCallbacks()
        self:_showLibraryError(open_err)
        editor:shutdown()
        return nil, open_err
    end
    self.editor = editor
    editor:onStateChanged()
    UIManager:show(editor, "full")
    editor:markShown()
    return editor, open_err
end

function NotebookUI:_editorClosed(editor, generation)
    if self.editor ~= editor or self.editor_generation ~= generation then return true end
    self.editor = nil
    self.editor_generation = self.editor_generation + 1
    self:_clearEditorCallbacks()
    UIManager:close(editor, "full")
    editor:shutdown()
    if self.library then
        if self.library_needs_layout or self.library.layout_deferred then
            self.library_needs_layout = false
            self.library:onSetDimensions()
        end
        self.library:refreshIfStale()
    end
    return true
end

function NotebookUI:onLibraryChanged()
    if not self.library then return end
    self.library:markStale()
end

function NotebookUI:onScreenResize()
    if self.closed then return true end
    if self.editor then
        if self.library then self.library_needs_layout = true end
        if self.editor.usesCurrentScreenLayout
            and self.editor:usesCurrentScreenLayout() then
            return true
        end
        return self.editor:onSetDimensions()
    end
    if self.library then self.library:onSetDimensions() end
    return true
end

function NotebookUI:onResume()
    if self.editor then
        self.editor:onStateChanged()
        self.editor:onFullRepaint()
        UIManager:setDirty(self.editor, "full")
    elseif self.library then
        self.library:onResume()
        UIManager:setDirty(self.library, "ui")
    end
    return true
end

function NotebookUI:shutdown()
    if self.closed then return true end
    self.closed = true
    -- A send being prepared stops; one already handed to LocalSend is its.
    LocalSend.cancelActive()
    self.editor_generation = self.editor_generation + 1
    local first_error
    if self.editor then
        local editor = self.editor
        self.editor = nil
        UIManager:close(editor, "full")
        editor:shutdown()
    end
    if self.library then
        local library = self.library
        self.library = nil
        UIManager:close(library, "ui")
        library:shutdown()
    end
    local stopped, stop_err = self.controller:shutdown()
    if not stopped then first_error = stop_err end
    self:_clearEditorCallbacks()
    if first_error then return nil, first_error end
    return true
end

return NotebookUI
