--[[-- Full-screen, bounded-memory notebook library. ]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local Errors = require("ink_notebook_errors")
local NotebookLayout = require("ink_notebook_layout")

local Screen = Device.screen
local BATCH_SIZE = 50

local Library = FocusManager:extend{
    covers_fullscreen = true,
    modal = false,
}

local function pageCountText(count)
    count = tonumber(count) or 0
    return T(N_("1 page", "%1 pages", count), count)
end

local function validTitle(value)
    if type(value) ~= "string" then return nil, "invalid_name" end
    local title = value:match("^%s*(.-)%s*$")
    if title == "" then return nil, "invalid_name" end
    if #title > 255 then return nil, "name_too_long" end
    return title
end

function Library:init()
    self.controller = assert(self.controller)
    self.schedule = self.schedule or function(fn) UIManager:nextTick(fn) end
    self.batch = nil
    self.cursor_stack = { false }
    self.cursor_index = 1
    self.screen_in_batch = 1
    self.loading = false
    self.load_error_code = nil
    self.failed_cursor = nil
    self.failed_cursor_index = nil
    self.failed_stale_generation = nil
    self.stale = false
    self.stale_generation = 0
    self.started = false
    self.shown = false
    self.closed = false
    self.generation = 0
    self.modal_widgets = {}
    self.layout_deferred = false
    self.show_parent = self
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self:_registerEvents()
    self:_rebuild()
end

function Library:_registerEvents()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function Library:onTap() return true end
function Library:onHold() return true end
function Library:onSwipe() return true end

function Library:onShow()
    self.shown = true
    self:startLoading()
    return true
end

function Library:markShown()
    self.shown = true
    if self.refocusWidget then self:refocusWidget() end
end

function Library:startLoading()
    if self.started or self.closed then return end
    self.started = true
    self:_loadBatch(nil, 1, true)
end

function Library:markStale()
    self.stale = true
    self.stale_generation = self.stale_generation + 1
end

function Library:refreshIfStale()
    if not self.stale or self.closed then return end
    self:_loadBatch(nil, 1, false, self.stale_generation)
end

function Library:_showModal(widget)
    if self.closed then return nil, "closed" end
    self.modal_widgets[widget] = true
    widget.show_parent = widget
    local previous = widget.onCloseWidget
    widget.onCloseWidget = function(dialog, ...)
        if previous then previous(dialog, ...) end
        self.modal_widgets[dialog] = nil
    end
    UIManager:show(widget)
    return widget
end

--- Idempotent for the reason the editor's is: a second close of a widget that
--- is already off the window stack refreshes with nothing repainting behind
--- it, which pushes stale pixels back at the panel (ADR-28). The chained
--- onCloseWidget clears `modal_widgets` whichever route closed the widget.
function Library:_closeModal(widget)
    if not widget or not self.modal_widgets[widget] then return false end
    UIManager:close(widget)
    return true
end

function Library:_showInfo(text)
    return self:_showModal(InfoMessage:new{ text = text })
end

function Library:_loadBatch(cursor, cursor_index, initial, consume_stale_generation)
    if self.closed or self.loading then return end
    self.loading = true
    self.load_error_code = nil
    self.generation = self.generation + 1
    local generation = self.generation
    if initial then self:_rebuild() end
    self.schedule(function()
        if self.closed or generation ~= self.generation then return end
        local batch, err = self.controller:listNotebookBatch(cursor, BATCH_SIZE)
        self.loading = false
        if not batch then
            self.load_error_code = Errors.normalize(err, "library")
            self.failed_cursor = cursor
            self.failed_cursor_index = cursor_index
            self.failed_stale_generation = consume_stale_generation
            logger.warn("JustDraw notebooks: library load failed:", err)
            self:_rebuild()
            return
        end
        self.batch = batch
        self.cursor_index = cursor_index
        self.cursor_stack[cursor_index] = cursor or false
        for i = cursor_index + 1, #self.cursor_stack do self.cursor_stack[i] = nil end
        self.screen_in_batch = 1
        self.load_error_code = nil
        self.failed_cursor = nil
        self.failed_cursor_index = nil
        self.failed_stale_generation = nil
        if consume_stale_generation ~= nil then
            if self.stale_generation == consume_stale_generation then
                self.stale = false
            elseif self.stale then
                self.schedule(function() self:refreshIfStale() end)
            end
        end
        self:_rebuild()
    end)
end

function Library:_visibleItems()
    local items = self.batch and self.batch.items or {}
    local first = (self.screen_in_batch - 1) * self.rows_per_screen + 1
    local last = math.min(#items, first + self.rows_per_screen - 1)
    local visible = {}
    for i = first, last do visible[#visible + 1] = items[i] end
    return visible
end

function Library:_screenCount()
    local count = self.batch and #self.batch.items or 0
    return math.max(1, math.ceil(count / self.rows_per_screen))
end

function Library:_canPrevious()
    return not self.loading and (self.screen_in_batch > 1 or self.cursor_index > 1)
end

function Library:_canNext()
    return not self.loading and self.batch ~= nil
        and (self.screen_in_batch < self:_screenCount() or self.batch.has_more)
end

function Library:previousScreen()
    if not self:_canPrevious() then return nil, "boundary" end
    if self.screen_in_batch > 1 then
        self.screen_in_batch = self.screen_in_batch - 1
        self:_rebuild()
        return true
    end
    local index = self.cursor_index - 1
    local cursor = self.cursor_stack[index]
    self:_loadBatch(cursor ~= false and cursor or nil, index, false)
    return true
end

function Library:nextScreen()
    if not self:_canNext() then return nil, "boundary" end
    if self.screen_in_batch < self:_screenCount() then
        self.screen_in_batch = self.screen_in_batch + 1
        self:_rebuild()
        return true
    end
    local cursor = self.batch.next_cursor
    self:_loadBatch(cursor, self.cursor_index + 1, false)
    return true
end

--[[--
Every button here is placed in a column with a height budget, so `height` means
the box the widget occupies. Button reads it as the label box and grows by its
own chrome, which is why this conversion is not optional: without it the column
overspends once per row and the footer walks off the screen.
]]
function Library:_button(opts)
    opts.show_parent = self
    opts.margin = NotebookLayout.BUTTON_MARGIN
    opts.padding = Size.padding.button
    if opts.height then
        opts.height = NotebookLayout.buttonLabelHeight(opts.height)
    end
    return Button:new(opts)
end

function Library:_row(item, width, row_h, action_w)
    local body = self:_button{
        text = BD.auto(item.title) .. "\n" .. pageCountText(item.page_count),
        help_text = item.title,
        align = "left",
        width = width - action_w,
        height = row_h,
        callback = function()
            if self.on_open then self.on_open(item, self) end
        end,
    }
    local actions = self:_button{
        text = _("Actions"),
        help_text = _("Actions"),
        width = action_w,
        height = row_h,
        callback = function() self:showActions(item) end,
    }
    local group = HorizontalGroup:new{ body, actions }
    self.layout[#self.layout + 1] = { body, actions }
    return group
end

function Library:_statusButton(width, height)
    local text
    if not self.batch and self.loading then
        text = _("Loading notebooks…")
    elseif not self.batch and self.load_error_code then
        if self.load_error_code == "database_conflict" then
            text = _("Both JustDraw and FingerInk notebook databases exist.") .. "\n"
                .. _("Close KOReader, then move one database together with its matching -wal and -shm files to another directory.")
        else
            text = _("Couldn’t open the notebook library.") .. "\n"
                .. _("Your notebooks are still stored on this device. Try again, or restart KOReader.")
        end
    elseif self.batch and self.batch.read_only_code and #self.batch.items == 0 then
        text = _("Read-only") .. "\n"
            .. _("This notebook library was created by a newer version of JustDraw. You can’t create or edit notebooks with this version.")
    elseif not self.batch or #self.batch.items == 0 then
        text = _("No notebooks yet") .. "\n"
            .. _("Create your first notebook to write by hand without opening a book.")
    end
    if not text then return nil end
    local retryable = self.load_error_code ~= nil
        and self.load_error_code ~= "database_conflict"
    return self:_button{
        text = text, width = width, height = height,
        enabled = retryable,
        callback = retryable and function()
            self:_loadBatch(self.failed_cursor, self.failed_cursor_index,
                false, self.failed_stale_generation)
        end or nil,
    }
end

function Library:_rebuild()
    if self[1] and self[1].free then self[1]:free() end
    self.layout = {}
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.screen_layout_w = width
    self.screen_layout_h = height
    self.screen_layout_dpi_scale = Screen:scaleByDPI(160)
    self.screen_layout_rotation = Screen:getRotationMode()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    local title = TitleBar:new{
        fullscreen = true,
        title = _("Notebooks"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local target = NotebookLayout.physicalPixels(10) or Size.item.height_large
    local footer_h = math.max(target, Size.item.height_large)
    local list_h = math.max(target, height - title:getHeight() - footer_h)
    local row_h = math.max(target, Size.item.height_large)
    local banner_h = self.batch and self.batch.read_only_code and row_h or 0
    self.rows_per_screen = math.max(1, math.floor((list_h - banner_h) / row_h))
    local content = VerticalGroup:new{ align = "left", title }
    local status = self:_statusButton(width, list_h)
    if status then
        content[#content + 1] = status
        self.layout[#self.layout + 1] = { status }
    else
        if banner_h > 0 then
            content[#content + 1] = self:_button{
                text = _("Read-only") .. "\n"
                    .. _("This notebook was created by a newer version of JustDraw. You can view it and change pages, but you can’t edit it."),
                width = width, height = banner_h, enabled = false,
            }
        end
        local action_w = math.max(target * 2, math.floor(width * 0.22))
        local visible = self:_visibleItems()
        for i = 1, #visible do
            content[#content + 1] = self:_row(visible[i], width, row_h, action_w)
        end
        local used = banner_h + #visible * row_h
        if used < list_h then content[#content + 1] = VerticalSpan:new{ width = list_h - used } end
    end
    local previous = self:_button{
        text = _("Previous"), width = math.floor(width / 3), height = footer_h,
        enabled_func = function() return self:_canPrevious() end,
        callback = function() self:previousScreen() end,
    }
    local create = self:_button{
        text = _("New notebook"), width = math.floor(width / 3), height = footer_h,
        enabled_func = function()
            return not self.loading and self.batch ~= nil and self.batch.writable
        end,
        callback = function() self:showCreateDialog() end,
    }
    local next_button = self:_button{
        text = self.load_error_code and self.batch and _("Try again") or _("Next"),
        width = width - 2 * math.floor(width / 3), height = footer_h,
        enabled_func = function()
            return self.load_error_code ~= nil and self.batch ~= nil or self:_canNext()
        end,
        callback = function()
            if self.load_error_code and self.batch then
                self:_loadBatch(self.failed_cursor, self.failed_cursor_index,
                    false, self.failed_stale_generation)
            else
                self:nextScreen()
            end
        end,
    }
    content[#content + 1] = HorizontalGroup:new{ previous, create, next_button }
    self.layout[#self.layout + 1] = { previous, create, next_button }
    local selected = self.selected or { x = 1, y = 1 }
    selected.y = math.max(1, math.min(selected.y, #self.layout))
    selected.x = math.max(1, math.min(selected.x, #self.layout[selected.y]))
    self.selected = selected
    self[1] = content
    if self.shown and not self.closed then
        if self.refocusWidget then self:refocusWidget() end
        UIManager:setDirty(self, "ui")
    end
end

function Library:usesCurrentScreenLayout()
    return self.screen_layout_w == Screen:getWidth()
        and self.screen_layout_h == Screen:getHeight()
        and self.screen_layout_dpi_scale == Screen:scaleByDPI(160)
        and self.screen_layout_rotation == Screen:getRotationMode()
end

function Library:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    FocusManager.paintTo(self, bb, x, y)
end

function Library:showCreateDialog()
    if not self.batch or not self.batch.writable then return nil, "read_only" end
    local selected = "a5_portrait"
    local style = "blank"
    local dialog
    dialog = MultiInputDialog:new{
        title = _("New notebook"),
        fields = {{ description = _("Notebook name"), text = "" }},
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:_closeModal(dialog) end },
            { text = _("Create"), callback = function()
                local fields = dialog:getFields()
                local title, validation = validTitle(fields[1])
                if not title then
                    self:_showInfo(validation == "name_too_long"
                        and _("Notebook name is too long. Use a shorter name.")
                        or _("Notebook name can’t be empty."))
                    return
                end
                local preset = NotebookLayout.preset(selected)
                preset.title = title
                -- The presets carry blank; the chooser is what makes a
                -- notebook ruled, and every later page inherits it.
                preset.template_kind = style
                local notebook, err = self.controller:createNotebook(preset)
                if not notebook then
                    logger.warn("JustDraw notebooks: create failed:", err)
                    self:_showInfo(_("Couldn’t create this notebook. Try again."))
                    return
                end
                self:_closeModal(dialog)
                self.stale = true
                local opened
                if self.on_open then opened = self.on_open(notebook, self) end
                if not opened then self:refreshIfStale() end
            end },
        }},
    }
    local radio = RadioButtonTable:new{
        width = math.floor(Screen:getWidth() * 0.72),
        parent = dialog,
        show_parent = dialog,
        radio_buttons = {
        {{ text = _("Paper size"), enabled = false, checkable = false }},
        {
            { text = _("A5 portrait"), checked = true, value = "a5_portrait" },
            { text = _("Letter portrait"), value = "letter_portrait" },
            { text = _("A5 landscape"), value = "a5_landscape" },
        }},
        button_select_callback = function(entry) selected = entry.value end,
    }
    dialog:addWidget(radio)
    -- Its own table, so it is its own radio group: RadioButtonTable keeps one
    -- checked button per widget, across as many rows as it is given. Two by
    -- two rather than four across, because four labels do not survive the
    -- narrowest screen this runs on with the keyboard up.
    local style_radio = RadioButtonTable:new{
        width = math.floor(Screen:getWidth() * 0.72),
        parent = dialog,
        show_parent = dialog,
        radio_buttons = {
        {{ text = _("Paper style"), enabled = false, checkable = false }},
        {
            { text = _("Blank"), checked = true, value = "blank" },
            { text = _("Ruled"), value = "ruled" },
        },
        {
            { text = _("Squared"), value = "grid" },
            { text = _("Dotted"), value = "dots" },
        }},
        button_select_callback = function(entry) style = entry.value end,
    }
    dialog:addWidget(style_radio)
    self:_showModal(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end

function Library:showRenameDialog(item)
    if not self.batch or not self.batch.writable then return nil, "read_only" end
    local dialog
    dialog = InputDialog:new{
        title = _("Rename notebook"),
        input = item.title,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:_closeModal(dialog) end },
            { text = _("Rename"), callback = function()
                local title, validation = validTitle(dialog:getInputText())
                if not title then
                    self:_showInfo(validation == "name_too_long"
                        and _("Notebook name is too long. Use a shorter name.")
                        or _("Notebook name can’t be empty."))
                    return
                end
                local ok, err = self.controller:renameNotebook(item.id, title)
                if not ok then
                    logger.warn("JustDraw notebooks: rename failed:", err)
                    self:_showInfo(_("Couldn’t rename this notebook. Try again."))
                    return
                end
                self:_closeModal(dialog)
                self:_loadBatch(nil, 1, false, self.stale_generation)
            end },
        }},
    }
    self:_showModal(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end

function Library:confirmDelete(item)
    if not self.batch or not self.batch.writable then return nil, "read_only" end
    local box
    box = ConfirmBox:new{
        text = T(_("Delete “%1”? This deletes its %2 and all ink. This can’t be undone."),
            BD.auto(item.title), pageCountText(item.page_count)),
        ok_text = _("Delete"),
        keep_dialog_open = true,
        -- No cancel_callback: ConfirmBox closes itself on Cancel and on
        -- onClose, and the chained onCloseWidget does the bookkeeping.
        -- Closing it here as well made a second close of a widget already
        -- off the window stack, which refreshes with nothing repainting
        -- behind it (ADR-28).
        ok_callback = function()
            local ok, err = self.controller:deleteNotebook(item.id)
            if not ok then
                logger.warn("JustDraw notebooks: delete failed:", err)
                self:_showInfo(_("Couldn’t delete this notebook. Try again."))
                return
            end
            self:_closeModal(box)
            self:_loadBatch(nil, 1, false, self.stale_generation)
        end,
    }
    self:_showModal(box)
    return box
end

function Library:showActions(item)
    local writable = self.batch and self.batch.writable
    local dialog
    dialog = ButtonDialog:new{
        title = _("Actions"),
        buttons = {
            {{ text = _("Rename"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:showRenameDialog(item)
            end }},
            {{ text = _("Delete"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:confirmDelete(item)
            end }},
            {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }},
        },
    }
    self:_showModal(dialog)
    return dialog
end

function Library:onSetDimensions()
    if self.is_covered and self.is_covered() then
        self.layout_deferred = true
        return true
    end
    self.layout_deferred = false
    if self:usesCurrentScreenLayout() then return true end
    self:_rebuild()
    self:_registerEvents()
    return true
end

function Library:onClose()
    if self.on_close then self.on_close(self) else UIManager:close(self, "ui") end
    return true
end

function Library:shutdown()
    if self.closed then return true end
    self.closed = true
    self.shown = false
    local modals = self.modal_widgets
    self.modal_widgets = {}
    for widget in pairs(modals) do UIManager:close(widget) end
    self.generation = self.generation + 1
    self.batch = nil
    self[1] = nil
    return true
end

Library.pageCountText = pageCountText
Library.validTitle = validTitle

return Library
