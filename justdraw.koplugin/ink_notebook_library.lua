--[[--
The notebook library: a full-screen grid of cards, bounded in memory (Task 9.3,
ADR-58).

What is on screen. A title bar (the library, the open folder, or how many
items are selected), a row of actions, a grid of cards and a footer that pages
through them. Folders come first, then notebooks in the order the reader chose
(remembered in `justdraw_library_sort`). Inside a folder the first card of
every screen is Back: it takes a card's place, so it is where a finger expects
it and never needs a second row of chrome.

What is in memory. One batch of rows (a few screens' worth, never the whole
library), the cards of the screen on display, and each of those cards' decoded
thumbnail. Folders are paginated with the notebooks, so a library with many
folders does not load them all to draw the first screen. Thumbnails are files
(`ink_thumbnail`) asked for after the grid is up, one render at a time, and
only for cards that are still visible when their turn comes.

What a tap means is decided here, from rectangles computed by
`Library.gridMetrics`, and nowhere else: opening, entering a folder, going
back and toggling a selection are one hit test with a mode, not a widget per
meaning. Selection keys are typed (`folder:7`, `notebook:7`) so that a folder
and a notebook with the same row id are never the same choice.

Bulk actions are sequences of per-item actions, and they say what happened to
each: a move that failed for one notebook out of five is reported as four
moved and one failed, by name, never as "done".
]]

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
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local Card = require("ink_library_card")
local Compat = require("ink_compat")
local Errors = require("ink_notebook_errors")
local ExportDialog = require("ink_export_dialog")
local ExportSource = require("ink_export_source")
local NotebookLayout = require("ink_notebook_layout")

local Screen = Device.screen
--- Rows asked for at once. A batch is a whole number of screens (see
--- `_batchLimit`), so no screen is ever half one batch and half the next.
local BATCH_SIZE = 50
local SORT_SETTING = "library_sort"
local SORTS = { "recent", "oldest", "title_asc", "title_desc" }
local FOLDER_PAGE = 20

local Library = FocusManager:extend{
    covers_fullscreen = true,
    modal = false,
}

local function pageCountText(count)
    count = tonumber(count) or 0
    return T(N_("1 page", "%1 pages", count), count)
end

local function notebookCountText(count)
    count = tonumber(count) or 0
    return T(N_("1 notebook", "%1 notebooks", count), count)
end

local function validTitle(value)
    if type(value) ~= "string" then return nil, "invalid_name" end
    local title = value:match("^%s*(.-)%s*$")
    if title == "" then return nil, "invalid_name" end
    if #title > 255 then return nil, "name_too_long" end
    return title
end

local function sortLabel(sort)
    if sort == "oldest" then return _("Oldest first") end
    if sort == "title_asc" then return _("Title A–Z") end
    if sort == "title_desc" then return _("Title Z–A") end
    return _("Recently changed")
end

--- The typed key of a gallery item: a folder and a notebook with the same id
--- are two different things to select.
local function itemKind(item)
    return item.kind == "folder" and "folder" or "notebook"
end

local function itemKey(item)
    return itemKind(item) .. ":" .. tostring(item.id)
end

--- A title cut to a length a confirmation can list, on a character boundary.
local function shortTitle(title, max_chars)
    title = tostring(title or "")
    max_chars = max_chars or 40
    local count, cut = 0, nil
    for pos in title:gmatch("()[^\128-\191]") do
        count = count + 1
        if count == max_chars + 1 then cut = pos; break end
    end
    if not cut then return title end
    return title:sub(1, cut - 1) .. "…"
end

--[[--
Where every card goes, from the grid's box and the device's real density.

  o.width, o.height   the box the grid may use
  o.min_card          the narrowest card (30 mm in pixels)
  o.gap, o.pad        between cards, and inside one
  o.text_h            the two lines under the picture
  o.landscape         four columns rather than three
  o.aspect            picture height / width

Three columns in portrait, four in landscape, two when those would make a
card narrower than `min_card`, and one only on a screen too small for two.
At least one row, even if the picture has to shrink to fit it; two when two
rows of cards at least `min_card` tall fit. Pure: the
native test calls it with a Scribe's numbers and a Kindle's.
]]
function Library.gridMetrics(o)
    local gap, pad = o.gap, o.pad
    local cols = o.landscape and 4 or 3
    local function cell(c) return math.floor((o.width - gap * (c + 1)) / c) end
    if cell(cols) < o.min_card then cols = 2 end
    if cell(cols) < o.min_card then cols = 1 end
    local card_w = math.max(1, cell(cols))
    local thumb_w = math.max(1, card_w - 2 * pad)
    local natural_h = math.floor(thumb_w * (o.aspect or 4 / 3)) + o.text_h + 2 * pad
    -- Rows: as many as natural-size cards allow, but two when two cards that
    -- are still `min_card` tall fit -- a picture of a page shrinks well, and
    -- one row of two notebooks is a poor use of a small screen.
    local min_h = math.max(o.min_card, o.text_h + 2 * pad + 1)
    local rows_natural = math.floor((o.height - gap) / (natural_h + gap))
    local rows_max = math.floor((o.height - gap) / (min_h + gap))
    local rows = math.max(1, rows_natural, math.min(2, rows_max))
    local card_h = math.max(1, math.min(natural_h, math.floor((o.height - gap) / rows) - gap))
    local thumb_h = math.max(1, card_h - o.text_h - 2 * pad)
    local used_w = cols * card_w + (cols - 1) * gap
    local x0 = math.floor((o.width - used_w) / 2)
    local m = {
        cols = cols, rows = rows, per_screen = cols * rows,
        card_w = card_w, card_h = card_h, thumb_w = thumb_w, thumb_h = thumb_h,
        gap = gap, pad = pad, text_h = o.text_h,
    }
    --- The i-th card's rectangle inside the grid box, row-major.
    function m.rect(i)
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols
        return { x = x0 + c * (card_w + gap), y = gap + r * (card_h + gap),
            w = card_w, h = card_h }
    end
    return m
end

--[[--
Which header actions fit, and which fold into More. Every button keeps the
same minimum width -- a target, not a label squeezed into what is left -- so
on a narrow screen the rightmost optional actions move into More rather than
shrinking. `Done` never folds: it is the way out.
]]
function Library.headerButtons(width, min_w, selecting, extra)
    local optional, fixed
    if selecting then
        optional = { "move", "duplicate", "export", "delete" }
        for _, id in ipairs(extra or {}) do optional[#optional + 1] = id end
        fixed = { "done" }
    else
        optional = { "new_notebook", "new_folder", "sort" }
        fixed = { "select" }
    end
    local fits = math.max(1, math.floor(width / math.max(1, min_w)))
    local shown, more = {}, {}
    for _, id in ipairs(optional) do shown[#shown + 1] = id end
    while #shown + #fixed + (#more > 0 and 1 or 0) > fits and #shown > 0 do
        table.insert(more, 1, table.remove(shown))
    end
    local row = {}
    for _, id in ipairs(shown) do row[#row + 1] = id end
    if #more > 0 then row[#row + 1] = "more" end
    for _, id in ipairs(fixed) do row[#row + 1] = id end
    return row, more
end

function Library:init()
    self.controller = assert(self.controller)
    self.schedule = self.schedule or function(fn) UIManager:nextTick(fn) end
    self.settings = self.settings or _G.G_reader_settings
    self.batch = nil
    self.cursor_stack = { false }
    self.cursor_index = 1
    self.screen_in_batch = 1
    self.screen_number = 1
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
    self.folder = nil
    local sort = self.settings and Compat.readSetting(self.settings, SORT_SETTING)
    self.sort = Library.SORT_KEYS[sort] and sort or "recent"
    self.selecting = false
    self.selection = {}
    self.selection_count = 0
    self.cards = {}
    self.card_images = {}   -- item key -> { key = thumbnail key, path, state }
    self.card_generation = 0
    self.thumb_action = nil
    self.bulk = nil
    if not self.thumbnails and self.thumbnail_factory then
        local ok, thumbs = pcall(self.thumbnail_factory, self)
        if ok then self.thumbnails = thumbs
        else logger.warn("JustDraw notebooks: no thumbnails:", thumbs) end
    end
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

--- The card under a point, or nil. Rectangles are the ones the cards were
--- last painted at, which before the first paint are the computed ones.
function Library:cardAt(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    for _, card in ipairs(self.cards) do
        local d = card.dimen
        if x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h then return card end
    end
    return nil
end

function Library:onTap(_, ges)
    local card = ges and ges.pos and self:cardAt(ges.pos.x, ges.pos.y)
    if card then self:activateCard(card) end
    return true
end

function Library:onHold(_, ges)
    local card = ges and ges.pos and self:cardAt(ges.pos.x, ges.pos.y)
    if card then self:holdCard(card) end
    return true
end

function Library:onSwipe(_, ges)
    local direction = ges and ges.direction
    if direction == "west" then self:nextScreen()
    elseif direction == "east" then self:previousScreen() end
    return true
end

--- Back leaves selection mode first, then the folder, then the library.
function Library:onClose()
    if self.selecting then self:setSelecting(false); return true end
    if self.folder then self:leaveFolder(); return true end
    if self.on_close then self.on_close(self) else UIManager:close(self, "ui") end
    return true
end

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

--- The library has no ink of its own, so no DU history, but ConfirmBox and
--- InfoMessage still enqueue only `ui` when they close and a widget with no
--- close handler enqueues nothing. Full screen rather than the modal's own
--- rectangle for the reason the editor's twin explains: only a full-screen
--- flashing UI update is fenced against the update still in flight
--- (`framebuffer_mxcfb.lua:341-347`). `rect` is only the question "was
--- anything actually on screen" (ADR-28).
function Library:_refreshClosedModal(rect)
    if self.closed or type(rect) ~= "table" then return false end
    local w, h = tonumber(rect.w), tonumber(rect.h)
    if not w or not h or w <= 0 or h <= 0 then return false end
    UIManager:setDirty(nil, "flashui")
    return true
end

function Library:_showModal(widget)
    if self.closed then return nil, "closed" end
    self.modal_widgets[widget] = true
    widget.show_parent = widget
    local previous = widget.onCloseWidget
    widget.onCloseWidget = function(dialog, ...)
        if previous then previous(dialog, ...) end
        self.modal_widgets[dialog] = nil
        self:_refreshClosedModal(dialog.movable and dialog.movable.dimen
            or dialog.dimen)
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

-- ------------------------------------------------------------ loading

--- Items a screen shows besides Back.
function Library:_itemsPerScreen()
    local per = self.metrics and self.metrics.per_screen or 1
    if self.folder then per = per - 1 end
    return math.max(1, per)
end

function Library:_batchLimit()
    local per = self:_itemsPerScreen()
    return per * math.max(1, math.floor(BATCH_SIZE / per))
end

function Library:_listOpts()
    return { folder_id = self.folder and self.folder.id or nil, sort = self.sort }
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
        local batch, err = self.controller:listNotebookBatch(cursor, self:_batchLimit(),
            self:_listOpts())
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
        local previous_index = self.cursor_index
        self.batch = batch
        self.cursor_index = cursor_index
        self.cursor_stack[cursor_index] = cursor or false
        for i = cursor_index + 1, #self.cursor_stack do self.cursor_stack[i] = nil end
        self.screen_in_batch = 1
        if cursor_index == 1 then
            self.screen_number = 1
        elseif cursor_index < previous_index then
            -- Back into the previous batch: its last screen, where the reader
            -- came from.
            self.screen_in_batch = self:_screenCount()
            self.screen_number = self.screen_number - 1
        else
            self.screen_number = self.screen_number + 1
        end
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
        self:_pruneSelection()
        self:_rebuild()
    end)
end

--- Reload from the first screen, keeping any stale change consumed.
function Library:reload()
    self:_loadBatch(nil, 1, false, self.stale_generation)
end

function Library:_visibleItems()
    local items = self.batch and self.batch.items or {}
    local per = self:_itemsPerScreen()
    local first = (self.screen_in_batch - 1) * per + 1
    local last = math.min(#items, first + per - 1)
    local visible = {}
    for i = first, last do visible[#visible + 1] = items[i] end
    return visible
end

function Library:_screenCount()
    local count = self.batch and #self.batch.items or 0
    return math.max(1, math.ceil(count / self:_itemsPerScreen()))
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
        self.screen_number = self.screen_number - 1
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
        self.screen_number = self.screen_number + 1
        self:_rebuild()
        return true
    end
    local cursor = self.batch.next_cursor
    self:_loadBatch(cursor, self.cursor_index + 1, false)
    return true
end

-- ------------------------------------------------------------ folders

function Library:openFolder(folder)
    if not folder or self.closed then return end
    self.folder = { id = folder.id, name = folder.name }
    self:_resetForNewList()
end

function Library:leaveFolder()
    if not self.folder then return end
    self.folder = nil
    self:_resetForNewList()
end

function Library:_resetForNewList()
    self:clearSelection()
    self.batch = nil
    self.cursor_stack = { false }
    self.cursor_index = 1
    self.screen_in_batch = 1
    self.screen_number = 1
    self:_loadBatch(nil, 1, true, self.stale_generation)
end

function Library:setSort(sort)
    if not Library.SORT_KEYS[sort] or sort == self.sort then return false end
    self.sort = sort
    if self.settings then Compat.saveSetting(self.settings, SORT_SETTING, sort) end
    self:_resetForNewList()
    return true
end

-- ------------------------------------------------------------ selection

function Library:setSelecting(on)
    on = on and true or false
    if self.selecting == on then return end
    self.selecting = on
    if not on then self.selection, self.selection_count = {}, 0 end
    self:_rebuild()
end

function Library:clearSelection()
    self.selection, self.selection_count = {}, 0
end

function Library:toggleSelected(item)
    local key = itemKey(item)
    if self.selection[key] then
        self.selection[key] = nil
        self.selection_count = self.selection_count - 1
    else
        self.selection[key] = item
        self.selection_count = self.selection_count + 1
    end
    return self.selection[key] ~= nil
end

--- The chosen items, in a stable order: folders first, then by id.
function Library:selectedItems(kind)
    local out = {}
    for _, item in pairs(self.selection) do
        if not kind or itemKind(item) == kind then out[#out + 1] = item end
    end
    table.sort(out, function(a, b)
        local ka, kb = itemKind(a), itemKind(b)
        if ka ~= kb then return ka == "folder" end
        return a.id < b.id
    end)
    return out
end

--- Keep only chosen items that the fresh batch still shows, refreshed to its
--- rows: what was deleted elsewhere cannot stay chosen, and a row renamed
--- elsewhere is confirmed under its new name. Items on other batches keep
--- their last known row.
function Library:_pruneSelection()
    if self.selection_count == 0 or not self.batch then return end
    for _, item in ipairs(self.batch.items or {}) do
        local key = itemKey(item)
        if self.selection[key] then self.selection[key] = item end
    end
end

-- ------------------------------------------------------------ taps

function Library:activateCard(card)
    if self.closed then return end
    if card.kind == "back" then self:leaveFolder(); return end
    local item = card.item
    if self.selecting then
        card.selected = self:toggleSelected(item)
        self:_rebuild()
        return
    end
    if card.kind == "folder" then self:openFolder(item); return end
    if self.on_open then self.on_open(item, self) end
end

function Library:holdCard(card)
    if self.closed or card.kind == "back" then return end
    if self.selecting then return self:activateCard(card) end
    if card.kind == "folder" then return self:showFolderActions(card.item) end
    return self:showActions(card.item, card)
end

-- ------------------------------------------------------------ building

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

function Library:_statusText()
    if not self.batch and self.loading then
        return _("Loading notebooks…")
    elseif not self.batch and self.load_error_code then
        if self.load_error_code == "database_conflict" then
            return _("Both JustDraw and FingerInk notebook databases exist.") .. "\n"
                .. _("Close KOReader, then move one database together with its matching -wal and -shm files to another directory.")
        end
        return _("Couldn’t open the notebook library.") .. "\n"
            .. _("Your notebooks are still stored on this device. Try again, or restart KOReader.")
    elseif self.folder then
        return nil   -- a folder always has its Back card; empty is not an error
    elseif self.batch and self.batch.read_only_code and #self.batch.items == 0 then
        return _("Read-only") .. "\n"
            .. _("This notebook library was created by a newer version of JustDraw. You can’t create or edit notebooks with this version.")
    elseif not self.batch or #self.batch.items == 0 then
        return _("No notebooks yet") .. "\n"
            .. _("Create your first notebook to write by hand without opening a book.")
    end
    return nil
end

function Library:_statusButton(width, height)
    local text = self:_statusText()
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

function Library:_writable()
    return not self.loading and self.batch ~= nil and self.batch.writable == true
end

--- What each header action is, and when it can be pressed.
function Library:_headerAction(id)
    local notebooks = function() return #self:selectedItems("notebook") > 0 end
    local actions = {
        new_notebook = { _("New notebook"), function() return self:_writable() end,
            function() self:showCreateDialog() end },
        -- One level of folders: there is no folder inside a folder.
        new_folder = { _("New folder"), function() return self:_writable() and not self.folder end,
            function() self:showNewFolder() end },
        sort = { _("Sort"), function() return not self.loading end,
            function() self:showSortMenu() end },
        select = { _("Select"), function() return self.batch ~= nil and #self.batch.items > 0 end,
            function() self:setSelecting(true) end },
        move = { _("Move"), function() return self:_writable() and notebooks() end,
            function() self:showMoveDialog(self:selectedItems("notebook")) end },
        duplicate = { _("Duplicate"), function() return self:_writable() and notebooks() end,
            function() self:duplicateItems(self:selectedItems("notebook")) end },
        export = { _("Export"), notebooks,
            function() self:exportItems(self:selectedItems("notebook")) end },
        delete = { _("Delete"), function() return self:_writable() and self.selection_count > 0 end,
            function() self:confirmDeleteItems(self:selectedItems()) end },
        done = { _("Done"), function() return true end,
            function() self:setSelecting(false) end },
    }
    for id_, extra in pairs(self.extra_actions or {}) do actions[id_] = extra end
    return actions[id]
end

function Library:_headerRow(width, height)
    local min_w = NotebookLayout.physicalPixels(20) or 120
    local extra = {}
    for id in pairs(self.extra_actions or {}) do extra[#extra + 1] = id end
    table.sort(extra)
    local ids, more = Library.headerButtons(width, min_w, self.selecting, extra)
    self.header_more = more
    local buttons = {}
    local each = math.floor(width / #ids)
    for i, id in ipairs(ids) do
        local w = (i == #ids) and (width - each * (#ids - 1)) or each
        local button
        if id == "more" then
            button = self:_button{ text = _("More"), width = w, height = height,
                callback = function() self:showHeaderMore() end }
        else
            local spec = self:_headerAction(id)
            button = self:_button{ text = spec[1], width = w, height = height,
                enabled_func = spec[2], callback = spec[3] }
        end
        button.action_id = id
        buttons[#buttons + 1] = button
    end
    self.header_buttons = buttons
    return buttons
end

--- The actions that did not fit, with the same targets in a list.
function Library:showHeaderMore()
    local rows = {}
    local dialog
    for _, id in ipairs(self.header_more or {}) do
        local spec = self:_headerAction(id)
        rows[#rows + 1] = {{ text = spec[1], enabled = spec[2](),
            no_refresh_checkmark = true,
            callback = function() self:_closeModal(dialog); spec[3]() end }}
    end
    rows[#rows + 1] = {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }}
    dialog = ButtonDialog:new{ buttons = rows }
    self:_showModal(dialog)
    return dialog
end

function Library:_titleText()
    if self.selecting then
        return T(N_("%1 selected", "%1 selected", self.selection_count), self.selection_count)
    end
    if self.folder then return BD.auto(self.folder.name) end
    return _("Notebooks")
end

function Library:_cardFor(item, rel, m)
    local kind = itemKind(item)
    local card = Card.new{
        kind = kind, item = item, rel = rel, w = m.card_w, h = m.card_h, pad = m.pad,
        thumb_w = m.thumb_w, thumb_h = m.thumb_h,
        title = BD.auto(item.kind == "folder" and item.name or item.title),
        subtitle = kind == "folder" and notebookCountText(item.notebook_count)
            or pageCountText(item.page_count),
        selecting = self.selecting,
        selected = self.selection[itemKey(item)] ~= nil,
        failed_text = _("No preview"),
    }
    card.key = itemKey(item)
    local known = self.card_images[card.key]
    if known then
        card.thumb_key = known.key
        card:setImage(known.path, known.state)
    end
    return card
end

function Library:_computeMetrics(width, grid_h)
    local mm = function(n) return NotebookLayout.physicalPixels(n) or n * 6 end
    return Library.gridMetrics{
        width = width, height = grid_h, min_card = mm(30),
        gap = mm(2), pad = mm(1.5),
        text_h = Card.textHeight(),
        landscape = Screen:getWidth() > Screen:getHeight(),
        aspect = 4 / 3,
    }
end

function Library:_rebuild()
    if self[1] and self[1].free then self[1]:free() end
    self.layout = {}
    self.cards = {}
    self.card_generation = self.card_generation + 1
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.screen_layout_w = width
    self.screen_layout_h = height
    self.screen_layout_dpi_scale = Screen:scaleByDPI(160)
    self.screen_layout_rotation = Screen:getRotationMode()
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = height }
    local title = TitleBar:new{
        fullscreen = true,
        title = self:_titleText(),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local target = NotebookLayout.physicalPixels(10) or Size.item.height_large
    local bar_h = math.max(target, Size.item.height_large)
    local banner_h = self.batch and self.batch.read_only_code and bar_h or 0
    local grid_h = math.max(target, height - title:getHeight() - 2 * bar_h - banner_h)
    local previous_per = self.metrics and self.metrics.per_screen
    self.metrics = self:_computeMetrics(width, grid_h)
    if previous_per and previous_per ~= self.metrics.per_screen and self.batch then
        -- A new shape means new screens: the old page boundaries are gone.
        self.screen_in_batch = math.min(self.screen_in_batch, self:_screenCount())
    end
    local content = VerticalGroup:new{ align = "left", title }
    local header = self:_headerRow(width, bar_h)
    content[#content + 1] = HorizontalGroup:new(header)
    self.layout[#self.layout + 1] = header
    if banner_h > 0 then
        content[#content + 1] = self:_button{
            text = _("Read-only") .. "\n"
                .. _("This notebook was created by a newer version of JustDraw. You can view it and change pages, but you can’t edit it."),
            width = width, height = banner_h, enabled = false,
        }
    end
    local grid_y = title:getHeight() + bar_h + banner_h
    self.grid_y = grid_y
    local status = self:_statusButton(width, grid_h)
    self.status_button = status
    if status then
        content[#content + 1] = status
        self.layout[#self.layout + 1] = { status }
    else
        local m = self.metrics
        local entries = {}
        if self.folder then
            entries[1] = { back = true }
        end
        for _, item in ipairs(self:_visibleItems()) do entries[#entries + 1] = { item = item } end
        local row
        for i, entry in ipairs(entries) do
            local rel = m.rect(i)
            local card
            if entry.back then
                card = Card.new{ kind = "back", rel = rel, w = m.card_w, h = m.card_h,
                    pad = m.pad, thumb_w = m.thumb_w, thumb_h = m.thumb_h,
                    title = "‹ " .. _("Back"), subtitle = _("All notebooks") }
                card.key = "back"
            else
                card = self:_cardFor(entry.item, rel, m)
            end
            card.dimen.y = grid_y + rel.y
            card.on_focus_changed = function(c) self:_repaintCard(c) end
            self.cards[#self.cards + 1] = card
            if (i - 1) % m.cols == 0 then
                row = {}
                self.layout[#self.layout + 1] = row
            end
            row[#row + 1] = card
        end
        content[#content + 1] = Card.newGrid{ w = width, h = grid_h, cards = self.cards }
    end
    local third = math.floor(width / 3)
    local previous = self:_button{
        text = _("Previous"), width = third, height = bar_h,
        enabled_func = function() return self:_canPrevious() end,
        callback = function() self:previousScreen() end,
    }
    local position = self:_button{
        text = T(_("Page %1"), self.screen_number), width = third, height = bar_h,
        enabled = false,
    }
    local next_button = self:_button{
        text = self.load_error_code and self.batch and _("Try again") or _("Next"),
        width = width - 2 * third, height = bar_h,
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
    self.footer_buttons = { previous, position, next_button }
    content[#content + 1] = HorizontalGroup:new{ previous, position, next_button }
    self.layout[#self.layout + 1] = { previous, next_button }
    local selected = self.selected or { x = 1, y = 1 }
    selected.y = math.max(1, math.min(selected.y, #self.layout))
    selected.x = math.max(1, math.min(selected.x, #self.layout[selected.y]))
    self.selected = selected
    self[1] = content
    if self.shown and not self.closed then
        if self.refocusWidget then self:refocusWidget() end
        UIManager:setDirty(self, "ui")
    end
    self:_scheduleThumbnails()
end

function Library:_repaintCard(card)
    if self.closed or not self.shown then return end
    local d = card.dimen
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    end)
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

-- ------------------------------------------------------------ thumbnails

--[[--
Ask for the pictures of the cards on screen, on a later tick: never while the
grid is being built, and never for a card that has since scrolled away. The
queue keeps only these keys; a result for a card that was rebuilt since is
checked against the card's current key and generation, and dropped when it
no longer matches.
]]
function Library:_scheduleThumbnails()
    local thumbs = self.thumbnails
    if not thumbs or self.closed or not self.controller.thumbnailRequest then return end
    if self.thumb_action then return end
    local action
    action = function()
        if self.thumb_action ~= action then return end
        self.thumb_action = nil
        self:_requestThumbnails()
    end
    self.thumb_action = action
    self.schedule(action)
end

function Library:_requestThumbnails()
    local thumbs = self.thumbnails
    if not thumbs or self.closed or self.suspended then return end
    local m = self.metrics
    local generation = self.card_generation
    local wanted, visible = {}, {}
    for _, card in ipairs(self.cards) do
        if card.kind == "notebook" then
            local req = self.controller:thumbnailRequest(card.item, m.thumb_w, m.thumb_h)
            local key = req and require("ink_thumbnail").key(req)
            if key then
                card.thumb_key = key
                card.thumb_req = req
                visible[key] = true
                wanted[#wanted + 1] = card
            end
        end
    end
    thumbs:retain(visible)
    for _, card in ipairs(wanted) do
        local path, why = thumbs:want(card.thumb_req, function(done_path, key, reason)
            self:_thumbnailArrived(generation, card, key, done_path, reason)
        end)
        if path then
            self:_setCardImage(card, card.thumb_key, path, "ready")
        elseif why == "failed" then
            self:_setCardImage(card, card.thumb_key, nil, "failed")
        end
    end
end

function Library:_setCardImage(card, key, path, state)
    self.card_images[card.key] = { key = key, path = path, state = state }
    if card:setImage(path, state) then self:_repaintCard(card) end
end

function Library:_thumbnailArrived(generation, card, key, path, reason)
    if self.closed or generation ~= self.card_generation or card.thumb_key ~= key then
        -- A card that was rebuilt, or now shows another page: remember the
        -- file for when it is drawn again, but touch no widget.
        return
    end
    if path then self:_setCardImage(card, key, path, "ready")
    elseif reason ~= "stale" and reason ~= "cancelled" then
        self:_setCardImage(card, key, nil, "failed")
    else
        -- The page moved on while it rendered: ask again for what it is now.
        self:_scheduleThumbnails()
    end
end

function Library:retryThumbnail(card)
    if not self.thumbnails or not card or not card.thumb_req then return end
    self.thumbnails:retry(card.thumb_req)
    self.card_images[card.key] = nil
    card:setImage(nil, "pending")
    self:_repaintCard(card)
    self:_scheduleThumbnails()
end

function Library:onSuspend()
    self.suspended = true
    if self.thumbnails then self.thumbnails:cancelAll() end
    self:_cancelBulk()
end

function Library:onResume()
    self.suspended = false
    self:_scheduleThumbnails()
end

-- ------------------------------------------------------------ dialogs

function Library:showCreateDialog(previous)
    if not self.batch or not self.batch.writable then return nil, "read_only" end
    local style = previous and previous.paper or "blank"
    local dialog
    dialog = MultiInputDialog:new{
        title = _("New notebook"),
        fields = {{ description = _("Notebook name"), text = previous and previous.title or "" }},
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:_closeModal(dialog) end },
            { text = _("Create"), callback = function()
                if self.closed or not self.modal_widgets[dialog] then return end
                local fields = dialog:getFields()
                local title, validation = validTitle(fields[1])
                if not title then
                    self:_showInfo(validation == "name_too_long"
                        and _("Notebook name is too long. Use a shorter name.")
                        or _("Notebook name can’t be empty."))
                    return
                end
                -- The shape is this screen's, taken now: the form may have
                -- been rebuilt after a rotation, and the notebook has to fit
                -- the screen it is created on. The chooser is what makes it
                -- ruled, and every later page inherits both (ADR-52).
                local spec, shape_err = NotebookLayout.screenPage()
                if not spec then
                    logger.warn("JustDraw notebooks: no page shape:", shape_err)
                    self:_showInfo(_("Couldn’t create this notebook. Try again."))
                    return
                end
                spec.title = title
                spec.template_kind = style
                -- Created where the reader is: inside the open folder.
                spec.folder_id = self.folder and self.folder.id or nil
                local notebook, err = self.controller:createNotebook(spec)
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
    local width = dialog.getAddedWidgetAvailableWidth
        and dialog:getAddedWidgetAvailableWidth()
        or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.72)
    local option_width = width - ScrollableContainer:getScrollbarWidth()
    -- Two across rather than six, because even four labels do not survive
    -- the narrowest screen this runs on with the keyboard up.
    local style_radio = RadioButtonTable:new{
        width = option_width,
        parent = dialog,
        show_parent = dialog,
        radio_buttons = {
        {{ text = _("Paper style"), enabled = false, checkable = false }},
        {
            { text = _("Blank"), checked = style == "blank", value = "blank" },
            { text = _("Ruled"), checked = style == "ruled", value = "ruled" },
        },
        {
            { text = _("Squared"), checked = style == "grid", value = "grid" },
            { text = _("Dotted"), checked = style == "dots", value = "dots" },
        },
        {
            { text = _("Narrow ruled"), checked = style == "ruled_narrow",
                value = "ruled_narrow" },
            { text = _("Checklist"), checked = style == "checklist",
                value = "checklist" },
        }},
        button_select_callback = function(entry) style = entry.value end,
    }
    dialog.paper_options = { style_radio }
    local content = VerticalGroup:new{ align = "left", style_radio }
    local base_height = dialog.dialog_frame:getSize().h
    local viewport = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = content:getSize().h },
        show_parent = dialog,
        content,
    }
    -- UIManager uses this owner to crop a radio button's tap feedback too.
    dialog.cropping_widget = viewport
    dialog:addWidget(viewport)
    -- Measuring the empty frame cached its group's offsets before addWidget.
    dialog.dialog_frame[1]:resetLayout()
    local function fitOptions()
        if dialog.closing or dialog.reflowing then return end
        local keyboard_h = dialog:isKeyboardVisible() and dialog._input_widget:getKeyboardDimen().h or 0
        local height = math.max(1, math.min(content:getSize().h,
            Screen:getHeight() - keyboard_h - base_height - 2 * Size.padding.default))
        if viewport.dimen.h ~= height then
            viewport.dimen.h = height
            viewport:reset()
            dialog._added_widgets[1].dimen.h = height
            dialog.dialog_frame[1]:resetLayout()
        end
        dialog[1].dimen.h = Screen:getHeight() - keyboard_h
        UIManager:setDirty(dialog, "ui")
    end
    local show_keyboard, close_keyboard = dialog.onShowKeyboard, dialog.onCloseKeyboard
    dialog.onShowKeyboard = function(widget, ...)
        show_keyboard(widget, ...)
        fitOptions()
    end
    dialog.onCloseKeyboard = function(widget, ...)
        close_keyboard(widget, ...)
        fitOptions()
    end
    local keyboard_changed = dialog.onKeyboardHeightChanged
    dialog.onKeyboardHeightChanged = function(widget, ...)
        widget.reflowing = true
        keyboard_changed(widget, ...)
        widget.reflowing = false
        fitOptions()
    end
    local on_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        widget.closing = true
        if self.create_dialog == widget then self.create_dialog = nil end
        if on_close then on_close(widget, ...) end
    end
    dialog.creationState = function(widget)
        return { title = widget:getFields()[1], paper = style,
            keyboard_visible = widget:isKeyboardVisible() }
    end
    self.create_dialog = dialog
    self:_showModal(dialog)
    if previous and not previous.keyboard_visible then dialog:onCloseKeyboard()
    else dialog:onShowKeyboard() end
    return dialog
end


local function nameDialog(self, opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = opts.input or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:_closeModal(dialog) end },
            { text = opts.ok_text, callback = function()
                if self.closed or not self.modal_widgets[dialog] then return end
                local name, validation = validTitle(dialog:getInputText())
                if not name then
                    self:_showInfo(validation == "name_too_long"
                        and _("That name is too long. Use a shorter name.")
                        or _("The name can’t be empty."))
                    return
                end
                if opts.apply(name) then self:_closeModal(dialog) end
            end },
        }},
    }
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
                self:reload()
            end },
        }},
    }
    self:_showModal(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end

function Library:showNewFolder()
    if not self:_writable() or self.folder then return nil, "read_only" end
    return nameDialog(self, {
        title = _("New folder"), ok_text = _("Create"),
        apply = function(name)
            local folder, err = self.controller:createFolder(name)
            if not folder then
                logger.warn("JustDraw notebooks: create folder failed:", err)
                self:_showInfo(_("Couldn’t create this folder. Try again."))
                return false
            end
            self:reload()
            return true
        end,
    })
end

function Library:showRenameFolder(folder)
    if not self:_writable() then return nil, "read_only" end
    return nameDialog(self, {
        title = _("Rename folder"), ok_text = _("Rename"), input = folder.name,
        apply = function(name)
            local ok, err = self.controller:renameFolder(folder.id, name)
            if not ok then
                logger.warn("JustDraw notebooks: rename folder failed:", err)
                self:_showInfo(_("Couldn’t rename this folder. Try again."))
                return false
            end
            if self.folder and self.folder.id == folder.id then self.folder.name = name end
            self:reload()
            return true
        end,
    })
end

function Library:showSortMenu()
    local rows = {}
    local dialog
    for _, sort in ipairs(SORTS) do
        rows[#rows + 1] = {{
            text = sortLabel(sort),
            checked_func = function() return self.sort == sort end,
            -- This row closes its dialog: no checkmark repaint on a widget
            -- that is about to be gone.
            no_refresh_checkmark = true,
            callback = function()
                self:_closeModal(dialog)
                self:setSort(sort)
            end,
        }}
    end
    rows[#rows + 1] = {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }}
    dialog = ButtonDialog:new{ title = _("Sort notebooks"), buttons = rows }
    self:_showModal(dialog)
    return dialog
end

function Library:showActions(item, card)
    local writable = self.batch and self.batch.writable
    local dialog
    local function row(text, enabled, fn)
        return {{ text = text, enabled = enabled, callback = function()
            self:_closeModal(dialog); fn()
        end }}
    end
    local buttons = {
        row(_("Rename"), writable, function() self:showRenameDialog(item) end),
        row(_("Move…"), writable, function() self:showMoveDialog({ item }) end),
        row(_("Duplicate"), writable, function() self:duplicateItems({ item }) end),
        row(_("Export…"), true, function() self:showExport(item) end),
        row(_("Delete"), writable, function() self:confirmDelete(item) end),
    }
    if card and card.image_state == "failed" and card.thumb_req then
        buttons[#buttons + 1] = row(_("Retry preview"), true, function() self:retryThumbnail(card) end)
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }}
    dialog = ButtonDialog:new{ title = BD.auto(shortTitle(item.title)), buttons = buttons }
    self:_showModal(dialog)
    return dialog
end

function Library:showFolderActions(folder)
    local writable = self.batch and self.batch.writable
    local dialog
    dialog = ButtonDialog:new{
        title = BD.auto(shortTitle(folder.name)),
        buttons = {
            {{ text = _("Open"), callback = function()
                self:_closeModal(dialog); self:openFolder(folder)
            end }},
            {{ text = _("Rename"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:showRenameFolder(folder)
            end }},
            {{ text = _("Delete"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:confirmDeleteItems({ folder })
            end }},
            {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }},
        },
    }
    self:_showModal(dialog)
    return dialog
end

-- ------------------------------------------------------------ bulk actions

--[[--
What happened, item by item, in one message. `results` is a list of
`{ item, status = "ok" | "failed" | "cancelled" }`. Nothing is called done
that was not: a failure is named, a cancellation is counted.
]]
function Library.summarize(action, results)
    local ok, failed, cancelled = 0, {}, 0
    for _, r in ipairs(results) do
        if r.status == "ok" then ok = ok + 1
        elseif r.status == "cancelled" then cancelled = cancelled + 1
        else failed[#failed + 1] = r.item end
    end
    local lines = {}
    if ok > 0 then
        local template
        if action == "move" then template = N_("Moved %1 notebook.", "Moved %1 notebooks.", ok)
        elseif action == "duplicate" then template = N_("Duplicated %1 notebook.", "Duplicated %1 notebooks.", ok)
        elseif action == "export" then template = N_("Exported %1 notebook.", "Exported %1 notebooks.", ok)
        else template = N_("Deleted %1 item.", "Deleted %1 items.", ok) end
        lines[#lines + 1] = T(template, ok)
    end
    if #failed > 0 then
        lines[#lines + 1] = T(N_("%1 failed:", "%1 failed:", #failed), #failed)
        for _, item in ipairs(failed) do
            lines[#lines + 1] = "• " .. BD.auto(shortTitle(item.title or item.name))
        end
    end
    if cancelled > 0 then
        lines[#lines + 1] = T(N_("%1 cancelled.", "%1 cancelled.", cancelled), cancelled)
    end
    if #lines == 0 then lines[1] = _("Nothing was changed.") end
    return table.concat(lines, "\n"), ok, #failed, cancelled
end

function Library:_finishBulk(action, results)
    self:clearSelection()
    self.selecting = false
    self:markStale()
    self:reload()
    return self:_showInfo((Library.summarize(action, results)))
end

function Library:showMoveDialog(items, cursor)
    if not self:_writable() or #items == 0 then return nil, "read_only" end
    local folders, err = self.controller:listFolders{
        after_name = cursor and cursor.name, after_id = cursor and cursor.id,
        limit = FOLDER_PAGE + 1,
    }
    if not folders then
        logger.warn("JustDraw notebooks: list folders failed:", err)
        self:_showInfo(_("Couldn’t list the folders. Try again."))
        return nil, err
    end
    local more = #folders > FOLDER_PAGE
    if more then folders[#folders] = nil end
    local dialog
    local function choose(folder_id)
        self:_closeModal(dialog)
        self:moveItems(items, folder_id)
    end
    local rows = {}
    if not cursor then
        rows[#rows + 1] = {{ text = _("No folder"), enabled = self.folder ~= nil or nil,
            callback = function() choose(nil) end }}
    end
    for _, folder in ipairs(folders) do
        rows[#rows + 1] = {{ text = BD.auto(shortTitle(folder.name)),
            enabled = not (self.folder and self.folder.id == folder.id),
            callback = function() choose(folder.id) end }}
    end
    if more then
        local last = folders[#folders]
        rows[#rows + 1] = {{ text = _("More folders…"), callback = function()
            self:_closeModal(dialog)
            self:showMoveDialog(items, { name = last.name, id = last.id })
        end }}
    end
    rows[#rows + 1] = {{ text = _("Cancel"), callback = function() self:_closeModal(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(N_("Move %1 notebook to:", "Move %1 notebooks to:", #items), #items),
        buttons = rows,
    }
    self:_showModal(dialog)
    return dialog
end

function Library:moveItems(items, folder_id)
    local results = {}
    for _, item in ipairs(items) do
        local ok, err = self.controller:moveNotebook(item.id, folder_id)
        if not ok then logger.warn("JustDraw notebooks: move failed:", item.id, err) end
        results[#results + 1] = { item = item, status = ok and "ok" or "failed" }
    end
    self:_finishBulk("move", results)
    return results
end

--[[--
Copies, one notebook after another, each in bounded batches on later ticks
(`Controller:duplicateNotebook`). The progress box's Cancel stops the copy in
flight and every one after it; so does closing the box by any other route,
suspending, or closing the library -- nothing keeps copying behind a screen
that no longer says so.
]]
function Library:duplicateItems(items)
    if not self:_writable() or #items == 0 or self.bulk then return nil, "busy" end
    local bulk = { results = {}, index = 0, items = items, action = "duplicate" }
    self.bulk = bulk
    local progress
    local function finish()
        if self.bulk ~= bulk then return end
        self.bulk = nil
        bulk.finished = true
        if progress then self:_closeModal(progress) end
        for i = #bulk.results + 1, #items do
            bulk.results[i] = { item = items[i], status = "cancelled" }
        end
        self:_finishBulk("duplicate", bulk.results)
    end
    bulk.cancel = function()
        if bulk.finished then return end
        bulk.cancelled = true
        if bulk.job then bulk.job:cancel() end
        bulk.job = nil
        finish()
    end
    local function step()
        if self.bulk ~= bulk or bulk.cancelled then return end
        bulk.index = bulk.index + 1
        local item = items[bulk.index]
        if not item then return finish() end
        if progress then
            progress:setTitle(T(_("Duplicating %1 of %2…"), bulk.index, #items))
            UIManager:setDirty(progress, "ui")
        end
        local title = T(_("%1 (copy)"), shortTitle(item.title, 200))
        local job, err = self.controller:duplicateNotebook(item.id, {
            title = title,
            on_done = function(new_id, done_err)
                if self.bulk ~= bulk then return end
                bulk.job = nil
                if not new_id then
                    logger.warn("JustDraw notebooks: duplicate failed:", item.id, done_err)
                end
                bulk.results[bulk.index] = { item = item,
                    status = new_id and "ok" or (done_err == "cancelled" and "cancelled" or "failed") }
                self.schedule(step)
            end,
        })
        if not job then
            logger.warn("JustDraw notebooks: duplicate refused:", item.id, err)
            bulk.results[bulk.index] = { item = item, status = "failed" }
            self.schedule(step)
            return
        end
        bulk.job = job
    end
    progress = ButtonDialog:new{
        title = T(_("Duplicating %1 of %2…"), 1, #items),
        title_align = "center",
        dismissable = false,
        buttons = {{{ text = _("Cancel"), callback = function() bulk.cancel() end }}},
    }
    local on_close = progress.onCloseWidget
    progress.onCloseWidget = function(widget, ...)
        if on_close then on_close(widget, ...) end
        -- Closed by anything but the end of the run: that is a cancel.
        if not bulk.finished then
            progress = nil
            bulk.cancel()
        end
    end
    self:_showModal(progress)
    step()
    return bulk
end

function Library:_cancelBulk()
    local bulk = self.bulk
    if bulk and bulk.cancel then bulk.cancel() end
end

--- The export of one notebook, as the library's Export row runs it.
function Library:_exportBuild(item, repository, done)
    local title = item.title or "Notebook"
    return function()
        local pages, list_err = ExportSource.notebookPages(repository, item.id)
        if not pages then return nil, list_err end
        local tracker = {}
        return {
            items = pages,
            pixels = ExportSource.totalPixels(pages, ExportSource.notebookGeometry),
            title = title,
            -- Another notebook may be open in an editor with unsaved ink;
            -- the controller's flush covers whichever session that is.
            flush = function() return self.controller:onFlushSettings() end,
            render = ExportSource.surfaceRenderer{
                repository = repository,
                schedule = function(fn) UIManager:nextTick(fn) end,
                geometry = ExportSource.notebookGeometry,
                track = function(job) tracker.job = job end,
            },
            finish = function(result)
                if tracker.job then tracker.job:close() end
                if done then done(result) end
            end,
            cancel = function()
                if tracker.job then tracker.job:close() end
            end,
        }
    end
end

--[[--
Export a whole notebook from the library, with no notebook open.

Reachable from the file browser, which is the point: a notebook needs no book,
and neither does getting one out. Read-only is not a bar -- an export writes
nothing to the store -- so this stays available where Rename and Delete do not.
]]
function Library:showExport(item)
    local repository, repo_err = self.controller:exportRepository()
    if not repository then
        self:_showInfo(ExportDialog.reason(repo_err))
        return nil, repo_err
    end
    local title = item.title or "Notebook"
    return ExportDialog.show{
        title = T(_("Export “%1”"), title),
        stem = title .. " " .. os.date("%Y-%m-%d-%H%M%S"),
        settings = _G.G_reader_settings,
        show_modal = function(widget) return self:_showModal(widget) end,
        close_modal = function(widget) return self:_closeModal(widget) end,
        notify = function(text) self:_showInfo(text) end,
        build = self:_exportBuild(item, repository),
    }
end

--[[--
Export several notebooks, one after another, each to its own file, in the
format and folder the reader last chose. One question first, naming how many
and where; then each export runs to its end (or its own question) before the
next starts, and one message at the end says what happened to each.
]]
function Library:exportItems(items)
    if #items == 0 or self.bulk then return nil, "busy" end
    if #items == 1 then return self:showExport(items[1]) end
    local repository, repo_err = self.controller:exportRepository()
    if not repository then
        self:_showInfo(ExportDialog.reason(repo_err))
        return nil, repo_err
    end
    local settings = _G.G_reader_settings
    local format = ExportDialog.rememberedFormat(settings)
    local dir = ExportDialog.rememberedDirectory(settings)
    local bulk = { results = {}, index = 0, action = "export" }
    local function finish()
        if self.bulk ~= bulk then return end
        self.bulk = nil
        bulk.finished = true
        for i = #bulk.results + 1, #items do
            bulk.results[i] = { item = items[i], status = "cancelled" }
        end
        self:_finishBulk("export", bulk.results)
    end
    bulk.cancel = function() bulk.cancelled = true; finish() end
    local step
    step = function()
        if self.bulk ~= bulk or bulk.cancelled then return end
        bulk.index = bulk.index + 1
        local item = items[bulk.index]
        if not item then return finish() end
        local index = bulk.index
        local settled = false
        local function settle(status)
            if settled then return end
            settled = true
            bulk.results[index] = { item = item, status = status }
            self.schedule(step)
        end
        local build = self:_exportBuild(item, repository, function(result)
            local status = "failed"
            if result and result.status == "done" then status = "ok"
            elseif result and result.status == "cancelled" or result == nil then status = "cancelled" end
            settle(status)
        end)
        local built_once = false
        ExportDialog.run{
            build = function(scope)
                local built, err = build(scope)
                built_once = built ~= nil
                return built, err
            end,
            format = format, dir = dir,
            stem = (item.title or "Notebook") .. " " .. os.date("%Y-%m-%d-%H%M%S"),
            -- One message at the end, not one per notebook.
            notify = function(text) logger.info("JustDraw notebooks: export:", text) end,
            show_modal = function(widget) return self:_showModal(widget) end,
            close_modal = function(widget) return self:_closeModal(widget) end,
        }
        if not built_once then settle("failed") end
    end
    local box
    box = ConfirmBox:new{
        text = T(N_("Export %1 notebook as %2 to:\n%3", "Export %1 notebooks as %2 to:\n%3", #items),
            #items, tostring(format):upper(), dir),
        ok_text = _("Export"),
        ok_callback = function()
            self.bulk = bulk
            step()
        end,
    }
    self:_showModal(box)
    return box
end

function Library:confirmDelete(item)
    return self:confirmDeleteItems({ item })
end

--[[--
Delete what is chosen, after a confirmation that names exactly that: every
title, not a count. A folder's notebooks are not deleted with it -- they go
back to the library -- and the box says so.
]]
function Library:confirmDeleteItems(items)
    if not self.batch or not self.batch.writable then return nil, "read_only" end
    if #items == 0 then return nil, "empty" end
    local text
    local folders = 0
    for _, item in ipairs(items) do
        if itemKind(item) == "folder" then folders = folders + 1 end
    end
    if #items == 1 and folders == 0 then
        text = T(_("Delete “%1”? This deletes its %2 and all ink. This can’t be undone."),
            BD.auto(items[1].title), pageCountText(items[1].page_count))
    elseif #items == 1 then
        text = T(_("Delete the folder “%1”? Its notebooks are not deleted: they go back to Notebooks."),
            BD.auto(items[1].name))
    else
        local lines = { T(N_("Delete %1 item? This can’t be undone.",
            "Delete these %1 items? This can’t be undone.", #items), #items) }
        for _i, item in ipairs(items) do
            lines[#lines + 1] = itemKind(item) == "folder"
                and "• " .. T(_("Folder “%1”"), BD.auto(shortTitle(item.name)))
                or "• " .. BD.auto(shortTitle(item.title))
        end
        if folders > 0 then
            lines[#lines + 1] = _("Notebooks inside a deleted folder are not deleted: they go back to Notebooks.")
        end
        text = table.concat(lines, "\n")
    end
    local box
    box = ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        keep_dialog_open = true,
        -- No cancel_callback: ConfirmBox closes itself on Cancel and on
        -- onClose, and the chained onCloseWidget does the bookkeeping.
        -- Closing it here as well made a second close of a widget already
        -- off the window stack, which refreshes with nothing repainting
        -- behind it (ADR-28).
        ok_callback = function()
            local results = {}
            for _, item in ipairs(items) do
                local ok, err
                if itemKind(item) == "folder" then
                    ok, err = self.controller:deleteFolder(item.id)
                else
                    ok, err = self.controller:deleteNotebook(item.id)
                end
                if not ok then logger.warn("JustDraw notebooks: delete failed:", itemKey(item), err) end
                results[#results + 1] = { item = item, status = ok and "ok" or "failed" }
            end
            self:_closeModal(box)
            if self.folder then
                for _, r in ipairs(results) do
                    if r.status == "ok" and itemKind(r.item) == "folder"
                        and r.item.id == self.folder.id then
                        self.folder = nil
                    end
                end
            end
            if #items == 1 then
                self:clearSelection()
                if results[1].status ~= "ok" then
                    self:_showInfo(folders == 1 and _("Couldn’t delete this folder. Try again.")
                        or _("Couldn’t delete this notebook. Try again."))
                end
                self:reload()
                return
            end
            self:_finishBulk("delete", results)
        end,
    }
    self:_showModal(box)
    return box
end

-- ------------------------------------------------------------ lifecycle

function Library:onSetDimensions()
    if self.is_covered and self.is_covered() then
        self.layout_deferred = true
        return true
    end
    self.layout_deferred = false
    if self:usesCurrentScreenLayout() then return true end
    self:_rebuild()
    self:_registerEvents()
    -- MultiInputDialog does not reposition its keyboard or form on rotation.
    -- Rebuild this one dialog from its unsaved choices after the host resized.
    local create = self.create_dialog
    if create and self.modal_widgets[create] then
        local state = create:creationState()
        self:_closeModal(create)
        self:showCreateDialog(state)
    end
    return true
end

function Library:shutdown()
    if self.closed then return true end
    self:_cancelBulk()
    self.closed = true
    self.shown = false
    self.thumb_action = nil
    if self.thumbnails then
        self.thumbnails:close()
        self.thumbnails = nil
    end
    local modals = self.modal_widgets
    self.modal_widgets = {}
    for widget in pairs(modals) do UIManager:close(widget) end
    self.generation = self.generation + 1
    self.batch = nil
    if self[1] and self[1].free then self[1]:free() end
    self[1] = nil
    self.cards = {}
    return true
end

Library.pageCountText = pageCountText
Library.validTitle = validTitle
Library.itemKey = itemKey
Library.shortTitle = shortTitle
Library.SORTS = SORTS
Library.SORT_KEYS = { recent = true, oldest = true, title_asc = true, title_desc = true }

return Library
