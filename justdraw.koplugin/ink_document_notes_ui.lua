-- Reader-owned browser. Only the visible rows become widgets.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Layout = require("ink_notebook_layout")
local Note = require("ink_document_note")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen
-- Match KOReader's full-screen menus/viewers. A modal browser traps their
-- non-modal child windows underneath it, before ImageViewer can paint.
local Browser = FocusManager:extend{ covers_fullscreen = true }

function Browser:init()
    self.first = self.controller.first or 1
    self.select_mode = false
    self.show_parent = self
    self:_rebuild()
end

function Browser:_button(spec)
    spec.show_parent, spec.margin = self, Layout.BUTTON_MARGIN
    spec.padding = Size.padding.button
    spec.height = Layout.buttonLabelHeight(spec.height)
    return Button:new(spec)
end

function Browser:_actions(specs, width, height)
    local row, focus = HorizontalGroup:new{}, {}
    local part = math.floor(width / #specs)
    for i, spec in ipairs(specs) do
        spec.width, spec.height = i == #specs and width - part * (i - 1) or part, height
        local button = self:_button(spec)
        row[#row + 1], focus[#focus + 1] = button, button
    end
    self.layout[#self.layout + 1] = focus
    return row
end

function Browser:_rebuild()
    if self.closed then return end
    local c = self.controller.catalog
    if self[1] then self[1]:free() end
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events.Close = {{ Device.input.group.Back }}
        self.key_events.Next = {{ Device.input.group.PgFwd }}
        self.key_events.Previous = {{ Device.input.group.PgBack }}
    end
    self.layout = {}
    local ready = c.state == "ready" and not c.busy
    local status = c.state == "error" and _("Couldn’t load notes. Tap Retry.")
        or not ready and T(_("Finding notes and locations… %1 found"), #c.items)
        or T(_("%1 of %2 notes · %3 selected"), #c.result, #c.items, c:selectionCount())
    local title = TitleBar:new{ width = w, fullscreen = true, title = _("Document notes"),
        subtitle = status, close_callback = function() self:onClose() end, show_parent = self }
    local target = math.max(Size.item.height_large, Layout.physicalPixels(9))
    local controls_h = math.min(target, math.floor((h - title:getHeight()) / 5))
    local list_h = math.max(1, h - title:getHeight() - 2 * controls_h)
    local measure = TextWidget:new{ text = "Ag", face = Font:getFace("smallinfofont") }
    local row_target = target + measure:getSize().h
    measure:free()
    self.per_page = math.max(1, math.floor(list_h / row_target))
    self.first = math.max(1, math.min(self.first, math.max(1, #c.result)))
    self.first = math.floor((self.first - 1) / self.per_page) * self.per_page + 1
    local row_h = math.floor(list_h / self.per_page)
    local content = VerticalGroup:new{ align = "left", title }
    content[#content + 1] = self:_actions({
        { text = c.state == "error" and _("Retry") or next(c.filter) and _("Filtered") or _("Filter"),
          enabled = ready or c.state == "error",
          callback = function() if c.state == "error" then self.controller:retry() else self:showFilters() end end },
        { text = self.select_mode and _("Done selecting") or _("Select"), enabled = ready,
          callback = function() self.select_mode = not self.select_mode; self:_rebuild() end },
        { text = _("Export…"), enabled = ready,
          callback = function() self.controller:showExportOptions() end },
    }, w, controls_h)
    local used = 0
    self.visible_ids = {}
    for i = self.first, math.min(#c.result, self.first + self.per_page - 1) do
        local item = c.result[i]
        self.visible_ids[#self.visible_ids + 1] = item.id
        local label = (item.locating and _("Locating…") or item.location_label) .. " · " .. Note.kindLabel(item.kind)
        if item.surface then label = label .. " " .. tostring(item.surface.id) end
        if item.sheets then label=label.." · "..T(_("%1 sheets"),#item.sheets) end
        if self.select_mode then label = (c.selected[item.id] and "☑ " or "☐ ") .. label end
        local chapter = TextWidget:new{ text = item.chapter or self.controller.title,
            face = Font:getFace("smallinfofont"), max_width = w - 2 * Size.padding.large }
        local chapter_h = chapter:getSize().h
        local button = self:_button{ text = label, align = "left", width = w,
            height = row_h - chapter_h, enabled = ready or not self.select_mode,
            callback = function()
                if self.select_mode then c:toggle(item.id)
                else self.controller:showDetail(item.id) end
            end }
        content[#content + 1] = VerticalGroup:new{ align = "left", chapter, button }
        self.layout[#self.layout + 1] = {button}
        used = used + row_h
    end
    if #c.result == 0 then
        local empty = TextWidget:new{ text = c.state == "error" and _("Notes could not be loaded.")
            or not ready and _("Loading…")
            or #c.items == 0 and _("No notes in this document yet.")
            or _("No notes match this filter."), face = Font:getFace("smallinfofont"), max_width = w }
        content[#content + 1] = empty
        used = empty:getSize().h
    end
    content[#content + 1] = VerticalSpan:new{ width = math.max(0, list_h - used) }
    content[#content + 1] = self:_actions({
        {text = _("Previous"), enabled = self.first > 1, callback = function() self:onPrevious() end},
        {text = T(_("%1 / %2"), math.floor((self.first - 1) / self.per_page) + 1,
            math.max(1, math.ceil(#c.result / self.per_page))), callback = function() self:showPageDialog() end},
        {text = _("Next"), enabled = self.first + self.per_page <= #c.result,
            callback = function() self:onNext() end},
    }, w, controls_h)
    self[1] = content
    self.controller.first = self.first
    local y = math.min(self.selected and self.selected.y or 1, #self.layout)
    self.selected = {x = math.min(self.selected and self.selected.x or 1, #self.layout[y]), y = y}
    if self.shown then self:refocusWidget(); UIManager:setDirty(self, "ui") end
end

function Browser:onShow() self.shown = true; self:refocusWidget(); return true end
function Browser:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    FocusManager.paintTo(self, bb, x, y)
end
function Browser:onTap() return true end
function Browser:onNext()
    if self.first + self.per_page <= #self.controller.catalog.result then
        self.first = self.first + self.per_page; self:_rebuild()
    end
    return true
end
function Browser:onPrevious()
    self.first = math.max(1, self.first - self.per_page); self:_rebuild(); return true
end
function Browser:onSwipe(_, gesture)
    if gesture.direction == "west" then self:onNext()
    elseif gesture.direction == "east" then self:onPrevious() end
    return true
end
function Browser:onScreenResize() self.controller:onScreenResize(); return true end
Browser.onSetRotationMode = Browser.onScreenResize
function Browser:onClose() self.controller:close(); return true end
function Browser:onCloseWidget() self.closed = true end

function Browser:showPageDialog()
    local dialog
    dialog = InputDialog:new{ title = _("Go to list page"), input = "", input_type = "number",
        buttons = {{ {text = _("Cancel"), callback = function() self.controller:closeModal(dialog) end},
        {text = _("Go"), callback = function()
            local page = tonumber(dialog:getInputText())
            local count = math.max(1, math.ceil(#self.controller.catalog.result / self.per_page))
            if not page or page < 1 or page > count or page ~= math.floor(page) then
                return self.controller:notify(T(_("Enter a page from 1 to %1."), count))
            end
            self.controller:closeModal(dialog)
            self.first = (page - 1) * self.per_page + 1; self:_rebuild()
        end} }} }
    self.controller:showModal(dialog); dialog:onShowKeyboard()
end

function Browser:showRange()
    local dialog
    dialog = MultiInputDialog:new{ title = _("Document page range"),
        fields = {{text = "", hint = _("First page"), input_type = "number"},
                  {text = "", hint = _("Last page"), input_type = "number"}},
        buttons = {{{text = _("Cancel"), callback = function() self.controller:closeModal(dialog) end},
            {text = _("Apply"), callback = function()
                local values = dialog:getFields()
                local first, last = tonumber(values[1]), tonumber(values[2])
                if not first or not last or first < 1 or last < first
                    or first ~= math.floor(first) or last ~= math.floor(last) then
                    return self.controller:notify(_("Enter a valid first and last page."))
                end
                self.controller:closeModal(dialog)
                self.first = 1; self.controller.catalog:query({first = first, last = last}, self.controller.catalog.order)
            end}}} }
    self.controller:showModal(dialog); dialog:onShowKeyboard()
end

function Browser:showFilters()
    local c, dialog = self.controller.catalog
    local function choose(filter, order)
        self.controller:closeModal(dialog)
        self.first = 1; c:query(filter, order or c.order)
    end
    local rows = {}
    for _, spec in ipairs({{_("All notes"), {}}, {_("KOReader notes and highlights"), {native=true}}, {_("Drawing sheets"), {kind = "sheet"}},
        {_("Page notes"), {kind = "page_ink"}}, {_("Legacy ink"), {kind = "legacy_page"}},
        {_("Without location"), {unlocated = true}}}) do
        rows[#rows + 1] = {{text = spec[1], callback = function() choose(spec[2]) end}}
    end
    rows[#rows + 1] = {{text = _("Page range…"), callback = function()
        self.controller:closeModal(dialog); self:showRange()
    end}}
    rows[#rows+1]={{text=_("Search annotation text…"),callback=function()
        self.controller:closeModal(dialog)
        local input
        input=InputDialog:new{title=_("Search annotation text"),input="",buttons={
            {{text=_("Cancel"),callback=function()self.controller:closeModal(input)end},
             {text=_("Search"),callback=function()
                local query=input:getInputText();self.controller:closeModal(input)
                self.first=1;c:query({search=query},c.order)
             end}}}}
        self.controller:showModal(input);input:onShowKeyboard()
    end}}
    rows[#rows + 1] = {{text = _("Chapter…"), callback = function()
        self.controller:closeModal(dialog)
        local seen, items, menu = {}, {}
        for _, item in ipairs(c.items) do
            local key = item.chapter_key or item.chapter
            if key and not seen[key] then
                seen[key] = true
                items[#items + 1] = { text = item.chapter,
                    mandatory = item.chapter_page and T(_("Page %1"), item.chapter_page) or nil,
                    callback = function()
                    self.controller:closeModal(menu); self.first = 1
                    c:query(item.chapter_key and {chapter_key = key} or {chapter = item.chapter}, c.order)
                end }
            end
        end
        if #items == 0 then return self.controller:notify(_("No chapters are available.")) end
        menu = Menu:new{title = _("Chapters with notes"), item_table = items,
            items_per_page = math.max(3, math.floor(Screen:getHeight() / Screen:scaleBySize(65)) - 2),
            close_callback = function() self.controller:closeModal(menu) end}
        self.controller:showModal(menu)
    end}}
    rows[#rows + 1] = {{text = c.order == "recent" and _("Sort in document order") or _("Sort by last change"),
        callback = function() choose(c.filter, c.order == "recent" and "document" or "recent") end}}
    rows[#rows + 1] = {{text = _("KOReader annotations"), callback = function()
        self.controller:closeModal(dialog); self.controller:showNativeAnnotations()
    end}}
    rows[#rows + 1] = {{text = _("Close"), callback = function() self.controller:closeModal(dialog) end}}
    local items = {}
    for _, row in ipairs(rows) do items[#items + 1] = row[1] end
    dialog = Menu:new{ title = _("Filter notes"), item_table = items,
        items_per_page = math.max(3, math.floor(Screen:getHeight() / Screen:scaleBySize(65)) - 2),
        close_callback = function() self.controller:closeModal(dialog) end }
    self.controller:showModal(dialog)
end

return Browser
