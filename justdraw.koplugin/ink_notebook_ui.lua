--[[-- Coordinate notebook windows without leaking widgets into the domain. ]]

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Errors = require("ink_notebook_errors")
local Editor = require("ink_notebook_editor")
local Library = require("ink_notebook_library")
local Style = require("ink_style")

local NotebookUI = {}
NotebookUI.__index = NotebookUI

function NotebookUI.new(opts)
    opts = opts or {}
    return setmetatable({
        plugin = assert(opts.plugin),
        controller = assert(opts.controller),
        library_factory = opts.library_factory or Library,
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
    }
    self.library = library
    UIManager:show(library, "ui")
    library:markShown()
    library:startLoading()
    return library
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
    self.editor_generation = self.editor_generation + 1
    local generation = self.editor_generation
    -- Declare before constructing: Lua does not put a local in scope inside
    -- its own initializer, and on_close must capture this exact window.
    local editor
    editor = self.editor_factory:new{
        controller = self.controller,
        notebook = item,
        get_eraser = function() return self.plugin.eraser end,
        set_eraser = function(value) self.plugin.eraser = value and true or false end,
        get_input_mode = function() return self.plugin.input_mode end,
        set_input_mode = function(value) return self.plugin:setInputMode(value) end,
        get_pen_width = function() return self.plugin.pen_width end,
        set_pen_width = function(value) return self.plugin:setPenWidth(value) end,
        get_pen_style = function()
            return Style.resolve(self.plugin.pen_style, nil, true)
        end,
        set_pen_style = function(v) return self.plugin:setPenStyle(v) end,
        get_raw_pen_style = function() return self.plugin.pen_style end,
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
        UIManager:setDirty(self.library, "ui")
    end
    return true
end

function NotebookUI:shutdown()
    if self.closed then return true end
    self.closed = true
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
