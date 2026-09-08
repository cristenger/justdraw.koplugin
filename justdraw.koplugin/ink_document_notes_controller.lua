-- Owns the browser, its one preview raster and all its child dialogs.
local Catalog = require("ink_document_notes_catalog")
local Note = require("ink_document_note")
local Anchor = require("ink_anchor")
local Source = require("ink_document_export_source")
local Raster = require("ink_export_raster")
local ExportSource = require("ink_export_source")
local Export = require("ink_export")
local ExportDialog = require("ink_export_dialog")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Device = require("device")
local _ = require("gettext")
local T = require("ffi/util").template
local Controller = {}
Controller.__index = Controller

local function copyMap(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function Controller.new(host)
    return setmetatable({ host = host, modals = {}, generation = 0, first = 1 }, Controller)
end

-- A queued reader handoff belongs to this controller generation, not to a
-- closed preview. Keep the callback reference so lifecycle events cancel it.
function Controller:cancelNavigation()
    local request = self.pending_navigation
    self.pending_navigation = nil
    if request and request.run then UIManager:unschedule(request.run) end
end

function Controller:notify(text)
    self.host:notify(text)
end
function Controller:showModal(widget)
    -- "Modal" here means owned by this flow. Preserve KOReader's stacking flag:
    -- forcing it true would cover native children (TextViewer Find, folder picker).
    self.modals[widget] = true
    local previous = widget.onCloseWidget
    widget.onCloseWidget = function(dialog, ...)
        self.modals[dialog] = nil
        if previous then
            previous(dialog, ...)
        end
    end
    return self.host:showReaderModal(widget)
end
function Controller:closeModal(widget)
    if widget and self.modals[widget] then
        return self.host:closeReaderModal(widget)
    end
    return false
end

-- Snapshot TOC once, then binary-search its numeric pages without engine calls.
function Controller:chapterLookup()
    local toc = self.host.ui.toc
    if not toc then
        return
    end
    local ok = pcall(function()
        toc:fillToc()
    end)
    if not ok then
        return
    end
    local entries = {}
    for ordinal, entry in ipairs(toc.toc or {}) do
        if type(entry.page) == "number" and type(entry.title) == "string" then
            entries[#entries + 1] = {
                page = entry.page,
                title = entry.title,
                ordinal = ordinal,
                key = tostring(entry.xpointer or ordinal) .. ":" .. entry.title,
            }
        end
    end
    table.sort(entries, function(a, b)
        return a.page < b.page or a.page == b.page and a.ordinal < b.ordinal
    end)
    return function(page)
        local lo, hi, found = 1, #entries
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if entries[mid].page <= page then
                found, lo = mid, mid + 1
            else
                hi = mid - 1
            end
        end
        if found then
            return entries[found].title, entries[found].key, entries[found].page
        end
    end
end

function Controller:open()
    self:cancelNavigation()
    if self.browser or self.host.is_docless then
        return false
    end
    if Export.isRunning() then
        self:notify(ExportDialog.reason("export_busy"))
        return false
    end
    local host = self.host
    if host.input_lease and host.input_lease:hasActiveContact() then
        self:notify(ExportDialog.reason("contact_active"))
        return false
    end
    host:setDrawing(false)
    if host.drawing then
        return false
    end
    local ok, err = host.export_controller:flushSurfaces()
    if not ok then
        self:notify(ExportDialog.reason(err))
        return false
    end
    self.generation = self.generation + 1
    self.title = host.export_controller:bookName()
    local opts = {
        rolling = host.ui.rolling ~= nil,
        legacy = host.legacy,
        screen = { w = Device.screen:getWidth(), h = Device.screen:getHeight() },
        units = host.ui.document.provider == "mupdf" and "pt" or "px",
        schedule = function(fn)
            UIManager:nextTick(fn)
        end,
        schedule_in = function(delay, fn)
            UIManager:scheduleIn(delay, fn)
        end,
        chapter = self:chapterLookup(),
        changed = function()
            self:changed()
        end,
    }
    if opts.rolling and host.session and host.session:isAvailable() then
        opts.repository, opts.index = host.session:exportSources()
        if opts.repository then
            opts.memberships = function()
                return require("ink_note_repository").new(opts.repository):memberships(host.session.book_id)
            end
        end
    elseif not opts.rolling and host.document_session and host.document_session:isAvailable() then
        opts.repository, opts.book_id = host.document_session:exportSources()
    elseif opts.rolling and host.session or not opts.rolling and host.document_session then
        opts.source_error = "no_repository"
    end
    local duplicates = {}
    opts.native_batch = function(offset, limit)
        return require("ink_native_annotations").snapshot(host.ui, offset, limit, duplicates)
    end
    self.catalog = Catalog.new(opts)
    local saved = self.view_state
    if saved and saved.file == host.ui.document.file then
        self.catalog.filter, self.catalog.order = copyMap(saved.filter), saved.order
        self.restore_state = saved
        self.focus_id, self.surface_id = saved.focus_id, saved.surface_id
    else
        self.first, self.focus_id, self.surface_id = 1, nil, nil
    end
    self.browser = require("ink_document_notes_ui"):new { controller = self }
    self:showModal(self.browser)
    self.catalog:start()
    if saved and saved.file == host.ui.document.file then
        self.catalog.selected = copyMap(saved.selected)
    end
    return true
end

function Controller:cancelRestore()
    self.restore_state = nil
    if self.restore_job then UIManager:unschedule(self.restore_job) end
    self.restore_job = nil
end

-- Restoration waits for grouped, sorted results. An empty first browser paint
-- must not turn a saved page 12 into page 1. Scan metadata in bounded slices,
-- once; never search thousands of entries inside a widget paint/rebuild.
function Controller:restoreBrowser()
    local saved, catalog, browser = self.restore_state, self.catalog, self.browser
    if not saved or self.restore_job or not browser or catalog.state ~= "ready" or catalog.busy then return end
    local result, generation, query = catalog.result, self.generation, catalog.query_generation
    local i, sheet, first, focus, leaf_index, leaf_focus = 1, 0
    local run
    run = function()
        if self.restore_job ~= run or self.generation ~= generation or self.browser ~= browser then return end
        if catalog.query_generation ~= query then self:cancelRestore(); return end
        local budget = Catalog.BATCH
        while i <= #result and budget > 0 do
            local item = result[i]
            if sheet == 0 then
                if item.id == saved.first_id then first = i end
                if item.id == saved.focus_id then focus = i end
                if not item.sheets then
                    if item.surface and item.surface.id == saved.surface_id then
                        leaf_focus, leaf_index = i, 1
                    end
                    i = i + 1
                else sheet = 1 end
            else
                local leaf = item.sheets[sheet]
                if leaf and leaf.surface.id == saved.surface_id then leaf_focus, leaf_index = i, sheet end
                sheet = sheet + 1
                if sheet > #item.sheets then i, sheet = i + 1, 0 end
            end
            budget = budget - 1
        end
        if i <= #result then UIManager:nextTick(run); return end
        self.restore_job, self.restore_state = nil, nil
        focus = leaf_focus or focus
        self.focus_id = focus and result[focus].id or saved.focus_id
        self.surface_id, self.focus_sheet_index = saved.surface_id, leaf_index
        browser.first = first or saved.first or 1
        browser.restore_focus = focus
        browser:_rebuild()
    end
    self.restore_job = run
    UIManager:nextTick(run)
end

function Controller:saveViewState()
    local browser, catalog = self.browser, self.catalog
    if not browser or not catalog then return end
    if self.restore_state then return end -- retain the saved state during loading
    self.view_state = {
        file = self.host.ui.document.file,
        selected = copyMap(catalog.selected), filter = copyMap(catalog.filter), order = catalog.order,
        first = browser.first, first_id = browser.visible_ids and browser.visible_ids[1],
        focus_id = self.focus_id, surface_id = self.surface_id,
        select_mode = browser.select_mode,
    }
end

function Controller:retry()
    self:close()
    return self:open()
end

function Controller:changed()
    if not self.browser or self.refresh_pending then
        return
    end
    self.refresh_pending = true
    local generation = self.generation
    UIManager:scheduleIn(0.2, function()
        if generation ~= self.generation then
            return
        end
        self.refresh_pending = false
        if self.browser then
            self:restoreBrowser()
            self.browser:_rebuild()
        end
    end)
end

function Controller:closeDetail()
    if self.epub_worker then
        self.epub_worker:close()
        self.epub_worker = nil
    end
    if self.preparation then
        self.preparation:close()
        self.preparation = nil
    end
    self.preview_generation = (self.preview_generation or 0) + 1
    self:closeModal(self.detail)
    self.detail = nil
    self:closeModal(self.loading)
    self.loading = nil
    if self.preview_job then
        self.preview_job:close()
        self.preview_job = nil
    end
    if self.preview_result then
        self.preview_result.release()
        self.preview_result = nil
    end
end

function Controller:onScreenResize()
    if not self.browser then
        return
    end
    Export.cancelRunning()
    self:closeDetail()
    local children = {}
    for widget in pairs(self.modals) do
        if widget ~= self.browser then
            children[#children + 1] = widget
        end
    end
    for _, widget in ipairs(children) do
        self:closeModal(widget)
    end
    self.browser:_rebuild()
end

function Controller:close()
    self:cancelNavigation()
    self:saveViewState()
    self:cancelRestore()
    self.generation = self.generation + 1
    self.refresh_pending = false
    Export.cancelRunning()
    self:closeDetail()
    if self.catalog then
        self.catalog:close()
    end
    local widgets = {}
    for widget in pairs(self.modals) do
        widgets[#widgets + 1] = widget
    end
    for _, widget in ipairs(widgets) do
        self:closeModal(widget)
    end
    self.browser = nil
end

function Controller:showDetail(id, sheet_index)
    self:cancelRestore()
    local group = self.catalog.by_id[id]
    if not sheet_index and group and group.sheets and id == self.focus_id and self.surface_id then
        local ordinal = self.focus_sheet_index
        if ordinal and group.sheets[ordinal] and group.sheets[ordinal].surface.id == self.surface_id then
            sheet_index = ordinal
        else
            self:notify(_("The previously selected sheet is no longer in this note."))
        end
    end
    sheet_index = sheet_index or 1
    local item = group and group.sheets and group.sheets[sheet_index] or group
    if not item then return false end
    self.focus_id, self.surface_id, self.focus_sheet_index = id, item.surface and item.surface.id, sheet_index
    self:closeDetail()
    if item.native then
        self.detail = require("ui/widget/textviewer"):new {
            title = item.location_label .. " · " .. Note.kindLabel(item.kind),
            text = require("ink_native_annotations").text(item),
            add_default_buttons = true,
            buttons_table = {
                {
                    {
                        text = _("Read from here"),
                        enabled = self:canNavigate(item, "read"),
                        callback = function()
                            self:navigate(item, "read")
                        end,
                    },
                    {
                        text = _("Export…"),
                        callback = function()
                            self:export({ item }, "notes")
                        end,
                    },
                },
                { {
                    text = _("Edit in KOReader"),
                    callback = function()
                        self:showNativeAnnotations(item)
                    end,
                } },
            },
            close_callback = function()
                self:closeDetail()
            end,
        }
        self:showModal(self.detail)
        return true
    end
    local generation = self.preview_generation
    local ButtonDialog = require("ui/widget/buttondialog")
    self.loading = ButtonDialog:new {
        title = _("Opening note…"),
        dismissable = false,
        buttons = { { {
            text = _("Cancel"),
            callback = function()
                self:closeDetail()
            end,
        } } },
    }
    self:showModal(self.loading)
    local render = Source.renderer {
        schedule = function(fn)
            UIManager:nextTick(fn)
        end,
        legacy = self.host.legacy,
        geometry = function(note)
            local target = note.kind == "page_ink" and 300 / 72 or 1
            local scale = Raster.boundedScale(
                note.logical_w,
                note.logical_h,
                target,
                math.min(Raster.MAX_PIXELS, 2 * Device.screen:getWidth() * Device.screen:getHeight())
            )
            return scale, note.logical_w, note.logical_h
        end,
        track = function(job)
            self.preview_job = job
        end,
    }
    local function ready(result, reason)
        if generation ~= self.preview_generation or not self.browser then
            if result then
                result.release()
            end
            return
        end
        self:closeModal(self.loading)
        self.loading = nil
        if not result then
            self:closeDetail()
            self:notify(ExportDialog.reason(reason))
            return
        end
        self.preview_result = result
        -- A loading catalogue may still change order: freeze this reading sequence.
        local sequence, position = {}, 1
        for i, note in ipairs(self.catalog.result) do
            sequence[i] = note.id
            if note.id == id then
                position = i
            end
        end
        local function relative(offset)
            if group.sheets and group.sheets[(sheet_index or 1) + offset] then
                return self:showDetail(id, (sheet_index or 1) + offset)
            end
            local target = sequence[position + offset]
            if target then
                local previous = self.catalog.by_id[target]
                self:showDetail(target, offset < 0 and previous.sheets and #previous.sheets or 1)
            end
        end
        local ok, detail = pcall(function()
            return require("ink_document_notes_detail"):new {
                image = result.bb,
                title_text = T(
                    _("Note %1 of %2 · %3"),
                    position,
                    #sequence,
                    item.locating and _("Locating…") or item.location_label
                ),
                caption = (item.chapter or self.title) .. " · " .. (group.sheets and T(
                    _("Sheet %1 of %2"),
                    sheet_index or 1,
                    #group.sheets
                ) or Note.kindLabel(item.kind)),
                has_previous = position > 1 or (sheet_index or 1) > 1,
                has_next = position < #sequence or group.sheets and (sheet_index or 1) < #group.sheets,
                previous_label = group.sheets and (sheet_index or 1) > 1 and _("Previous sheet") or nil,
                next_label = group.sheets and (sheet_index or 1) < #group.sheets and _("Next sheet") or nil,
                show_view_on_page = item.kind == "sheet" or item.kind == "page_ink",
                can_view_on_page = self:canNavigate(item, "view"),
                can_read_from_here = self:canNavigate(item, "read"),
                previous_note = function()
                    relative(-1)
                end,
                next_note = function()
                    relative(1)
                end,
                view_on_page = function()
                    self:navigate(item, "view")
                end,
                read_from_here = function()
                    self:navigate(item, "read")
                end,
                note_actions = function()
                    self:showNoteActions(group, item)
                end,
                close_note = function()
                    self:closeDetail()
                end,
            }
        end)
        if not ok then
            self:closeDetail()
            self:notify(_("This note could not be displayed."))
            return
        end
        self.detail = detail
        self:showModal(detail)
    end
    local ok, err = pcall(render, item, 1, ready)
    if not ok then
        ready(nil, err)
    end
    return true
end

-- Resolve only the selected descriptor at a UI boundary. The catalogue's
-- cached page is a label, never a fallback for a sheet with a lost anchor.
function Controller:resolveDestination(item, destination)
    if destination ~= "read" and destination ~= "view" and destination ~= "edit" then
        return nil, "invalid_destination"
    end
    if not item or item.sheets then return nil, "no_sheet" end
    if destination == "view" and item.kind ~= "sheet" and item.kind ~= "page_ink" then
        return nil, "unsupported"
    end
    local host, target = self.host, {}
    local document = host.ui.document
    if destination == "view" and item.kind == "page_ink"
        and not (host.document_session and host.document_session:isAvailable()) then
        return nil, "unavailable"
    end
    if item.kind == "sheet" then
        local session = host.session
        if not (session and session:isAvailable() and session.document == document) then
            return nil, "unavailable"
        end
        local row = item.surface and session.index and session.index:get(item.surface.id)
        if not row or row.anchor_key ~= item.surface.anchor_key then return nil, "no_sheet" end
        target.canvas = row
        target.xp = Anchor.resolve(document, row)
        if not target.xp then return nil, "location_unavailable" end
        if destination ~= "read" then
            local valid, err = session:validateCanvas(row)
            if not valid then return nil, err end
        end
    elseif item.xpointer then
        if not document:isXPointerInDocument(item.xpointer) then return nil, "location_unavailable" end
        target.xp = item.xpointer
    else
        local page = item.page
        if type(page) ~= "number" or page ~= math.floor(page) or page < 1
            or page > document:getPageCount() then return nil, "location_unavailable" end
        target.page = page
    end
    if destination == "edit" then
        local session = target.canvas and host.session or host.document_session
        if item.native or item.legacy or not session or not session:isWritable() then
            return nil, "read_only"
        end
    end
    return target
end

function Controller:canNavigate(item, destination)
    local ok, target = pcall(self.resolveDestination, self, item, destination)
    return ok and target ~= nil
end

function Controller:navigationError(reason)
    if reason == "location_unavailable" then
        self:notify(_("This note’s location is no longer available."))
    elseif reason == "no_sheet" then
        self:notify(_("This drawing sheet is no longer available."))
    elseif reason == "bad_geometry" then
        self:notify(_("This drawing sheet has invalid dimensions."))
    else
        self:notify(_("Could not open this note in the document."))
    end
end

function Controller:navigate(item, destination, resume_context)
    local host = self.host
    if Export.isRunning() or host.input_lease and host.input_lease:hasActiveContact() then
        self:notify(ExportDialog.reason(Export.isRunning() and "export_busy" or "contact_active"))
        return false, "busy"
    end
    local resolved, target, why = pcall(self.resolveDestination, self, item, destination)
    if not resolved or not target then
        self:navigationError(resolved and why or "location_unavailable")
        return false, why or "location_unavailable"
    end
    host:setDrawing(false)
    local durable, err = host.export_controller:flushSurfaces()
    if not durable then
        self:notify(ExportDialog.reason(err))
        return false, err
    end
    local restore_bar = host:ordinaryBarShown()
    local active = host.session and host.session:activeCanvas()
    if host.canvas_open and (destination == "read" or not target.canvas
        or not active or active.id ~= target.canvas.id) then
        local closed, close_err = host:closeCanvas(false)
        if not closed then
            self:notify(ExportDialog.reason(close_err))
            return false, close_err
        end
    end
    local group_id = self.focus_id
    self:close()
    local document = host.ui.document
    local request = { generation = self.generation, document = document,
        session = host.session, target = target, destination = destination }
    self.pending_navigation = request
    if target.canvas then
        local height
        if destination ~= "edit" then height = 40 end
        if resume_context == host.note_context and resume_context then height = resume_context.height_pct end
        host:rememberNoteContext(target.canvas, group_id, height, restore_bar)
    else
        host:clearNoteContext()
    end
    local navigated = pcall(function()
        if host.ui.link then host.ui.link:addCurrentLocationToStack() end
        -- The followed-link marker paints/restores the framebuffer on timers.
        -- A panel destination must not leave it scheduled over the new sheet.
        host.ui:handleEvent(target.xp and Event:new("GotoXPointer", target.xp)
            or Event:new("GotoPage", target.page))
    end)
    if not navigated then
        self:cancelNavigation()
        if host.note_context and not host.canvas_open then host:showNoteReturnBar() end
        self:navigationError("location_unavailable")
        return false, "location_unavailable"
    end
    request.run = function()
        if self.pending_navigation ~= request then return end
        if self.generation ~= request.generation or host.ui.document ~= document
            or host.session ~= request.session or host.reader_closed or host.reader_suspended then
            self:cancelNavigation()
            return
        end
        local ok, here = pcall(function()
            return target.xp and document:isXPointerInCurrentPage(target.xp)
                or not target.xp and host:currentPage() == target.page
        end)
        if not ok or not here then
            self:cancelNavigation()
            return
        end
        if target.canvas then
            if destination == "read" then
                host:showNoteReturnBar()
            else
                local context = host.note_context
                local overlay, open_err = host:openCanvas(target.canvas, {
                    mode = destination, height_pct = context and context.height_pct,
                    remember_height = false, note_context = context,
                    navigation_request = request,
                })
                if not overlay then
                    host:showNoteReturnBar()
                    self:navigationError(open_err)
                end
            end
        elseif destination == "edit" and host.document_session then
            host:setDrawing(true)
        end
        if self.pending_navigation == request then self.pending_navigation = nil end
    end
    UIManager:nextTick(request.run)
    return true
end

function Controller:canEdit(item)
    -- Organization acts on a logical group; navigation always acts on a leaf.
    local leaf = item and item.sheets and item.sheets[1] or item
    return self:canNavigate(leaf, "edit")
end

function Controller:showNoteActions(item, current_sheet)
    local dialog
    dialog = require("ui/widget/buttondialog"):new {
        title = item.location_label,
        buttons = {
            {
                {
                    text = _("Add sheet at end"),
                    enabled = item.kind == "sheet" and self:canEdit(item),
                    callback = function()
                        self:closeModal(dialog)
                        self:addSheet(item)
                    end,
                },
            },
            {
                {
                    text = _("Organize sheets…"),
                    enabled = item.sheets ~= nil and self:canEdit(item),
                    callback = function()
                        self:closeModal(dialog)
                        self:organizeSheets(item)
                    end,
                },
            },
            {
                {
                    text = _("Export this note…"),
                    callback = function()
                        self:closeModal(dialog)
                        self:export({ item }, "notes")
                    end,
                },
            },
            {
                {
                    text = _("Edit in document"),
                    enabled = self:canEdit(current_sheet or item),
                    callback = function()
                        self:closeModal(dialog)
                        self:navigate(current_sheet or item, "edit")
                    end,
                },
            },
            { {
                text = _("Close"),
                callback = function()
                    self:closeModal(dialog)
                end,
            } },
        },
    }
    self:showModal(dialog)
end

function Controller:addSheet(item)
    local session = self.host.session
    local ok, err = session:flush()
    if not ok then
        return self:notify(ExportDialog.reason(err))
    end
    local canvas, why =
        require("ink_note_repository").new(session.repository):append(session.book_id, item.surface)
    if not canvas then
        return self:notify(ExportDialog.reason(why))
    end
    session.index:add(canvas, item.page)
    self:navigate({ kind = "sheet", surface = canvas, page = item.page }, "edit")
end

function Controller:organizeSheets(item)
    if not self:canEdit(item) then
        return false
    end
    local menu, rows
    rows = {}
    for i, sheet in ipairs(item.sheets) do
        rows[#rows + 1] = {
            text = T(_("Sheet %1 · move to position…"), i),
            callback = function()
                local input
                input = require("ui/widget/inputdialog"):new {
                    title = T(_("Position (1–%1)"), #item.sheets),
                    input = tostring(i),
                    input_type = "number",
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    self:closeModal(input)
                                end,
                            },
                            {
                                text = _("Move"),
                                callback = function()
                                    local target = tonumber(input:getInputText())
                                    if
                                        not target
                                        or target ~= math.floor(target)
                                        or target < 1
                                        or target > #item.sheets
                                    then
                                        return
                                    end
                                    local ids = {}
                                    for j, s in ipairs(item.sheets) do
                                        ids[j] = s.surface.id
                                    end
                                    table.insert(ids, target, table.remove(ids, i))
                                    local session = self.host.session
                                    local ok, err = require("ink_note_repository")
                                        .new(session.repository)
                                        :reorder(session.book_id, item.note_id, ids)
                                    if not ok then
                                        return self:notify(ExportDialog.reason(err))
                                    end
                                    self:retry()
                                end,
                            },
                        },
                    },
                }
                self:showModal(input)
                input:onShowKeyboard()
            end,
        }
    end
    menu = require("ui/widget/menu"):new {
        title = _("Reorder sheets"),
        item_table = rows,
        close_callback = function()
            self:closeModal(menu)
        end,
    }
    self:showModal(menu)
end

function Controller:showNativeAnnotations(item)
    local bookmark = self.host.ui.bookmark
    local index = item and require("ink_native_annotations").findIndex(self.host.ui, item.id)
    self:close()
    if bookmark then
        if index and not bookmark.bookmark_menu then
            bookmark:showBookmarkDetails(index)
        else
            bookmark:onShowBookmark()
        end
    end
end

function Controller:export(items, mode, dpi, prepared)
    if #items > ExportSource.MAX_PAGES then
        return self:notify(ExportDialog.reason("too_many_pages"))
    end
    self:closeDetail()
    if not prepared then
        self.loading = require("ui/widget/buttondialog"):new {
            title = _("Preparing notes…"),
            dismissable = false,
            buttons = { { {
                text = _("Cancel"),
                callback = function()
                    self:closeDetail()
                end,
            } } },
        }
        self:showModal(self.loading)
        self.preparation = require("ink_document_notes_prepare").start(items, function(fn)
            UIManager:nextTick(fn)
        end, function(flat, err)
            self.preparation = nil
            self:closeModal(self.loading)
            self.loading = nil
            if not flat then
                return self:notify(ExportDialog.reason(err))
            end
            self:export(flat, mode, dpi, true)
        end)
        return
    end
    if mode ~= "notes" and not dpi then
        local dialog
        local function choose(value)
            self:closeModal(dialog)
            self:export(items, mode, value, true)
        end
        dialog = require("ui/widget/buttondialog"):new {
            title = _("Document image quality"),
            buttons = {
                { {
                    text = _("150 dpi · smaller files"),
                    callback = function()
                        choose(150)
                    end,
                } },
                { {
                    text = _("300 dpi · finer detail"),
                    callback = function()
                        choose(300)
                    end,
                } },
                { {
                    text = _("Cancel"),
                    callback = function()
                        self:closeModal(dialog)
                    end,
                } },
            },
        }
        return self:showModal(dialog)
    end
    local export = self.host.export_controller
    local title = mode == "full" and _("Complete document as images")
        or mode == "context" and _("Annotated document pages as images")
        or mode == "epub" and _("Complete EPUB with notes appendix")
        or T(_("Export %1 pages of notes"), #items)
    ExportDialog.show {
        title = dpi and T(_("%1 · %2 dpi"), title, dpi) or title,
        stem = export:stem("notes", os.date("%Y-%m-%d-%H%M%S")) .. (mode == "notes" and "" or "-" .. mode),
        scopes = {
            {
                value = mode,
                label = mode == "notes" and T(_("%1 output pages"), #items)
                    or (mode == "full" or mode == "epub") and _(
                        "Every document page, including pages without notes"
                    )
                    or _("Document pages containing the selected notes"),
            },
        },
        build = function()
            return export:buildNotes(items, mode, dpi)
        end,
        build_async = mode == "epub" and function(done)
            self:buildEPUB(items, dpi, done)
        end or nil,
        settings = export.settings(),
        show_modal = function(w)
            return self:showModal(w)
        end,
        close_modal = function(w)
            return self:closeModal(w)
        end,
        notify = function(text)
            self:notify(text)
        end,
    }
end

function Controller:buildEPUB(notes, dpi, done)
    local generation = self.generation
    self.loading = require("ui/widget/buttondialog"):new {
        title = _("Laying out EPUB…"),
        dismissable = false,
        buttons = { { {
            text = _("Cancel"),
            callback = function()
                self:closeDetail()
            end,
        } } },
    }
    self:showModal(self.loading)
    local function failed(err)
        self:closeDetail()
        done(nil, err)
    end
    local worker, err = require("ink_epub_export_worker").start {
        document = self.host.ui.document,
        dpi = dpi,
        notes = notes,
        schedule_in = function(delay, fn)
            UIManager:scheduleIn(delay, fn)
        end,
        error = failed,
        ready = function(manifest)
            if generation ~= self.generation then
                return self:closeDetail()
            end
            self:closeModal(self.loading)
            self.loading = nil
            if manifest.count + #notes > ExportSource.MAX_PAGES then
                return failed("too_many_pages")
            end
            local items = {}
            for page = 1, manifest.count do
                items[#items + 1] = { kind = "epub_page", page = page }
            end
            local appendix = {}
            for note_index, note in ipairs(notes) do
                local copy = {}
                for k, v in pairs(note) do
                    copy[k] = v
                end
                local page = manifest.locations[note.id]
                if page then
                    copy.location_label = copy.location_label .. " · " .. T(_("Export page %1"), page)
                end
                items[#items + 1] = copy
                appendix[#appendix + 1] = copy
            end
            local base, why
            if #appendix > 0 then
                base, why = self.host.export_controller:buildNotes(appendix, "notes")
            end
            if #appendix > 0 and not base then
                return failed(why)
            end
            local owner = self.epub_worker
            local function close()
                owner:close()
                if self.epub_worker == owner then
                    self.epub_worker = nil
                end
                if base then
                    base.finish()
                end
            end
            done({
                items = items,
                pixels = manifest.w * manifest.h * #items,
                render = function(item, index, callback)
                    if item.kind == "epub_page" then
                        owner:render(item.page, callback)
                    else
                        base.render(item, index, callback)
                    end
                end,
                flush = function()
                    return self.host.export_controller:flushSurfaces()
                end,
                finish = close,
                cancel = close,
                progress_interval = 5,
                confirm_warning = _(
                    "The complete EPUB is reflowed to A5 grayscale pages. Notes and native annotations follow in an appendix with source references. Text will not be selectable and links will not be preserved."
                ),
            })
        end,
    }
    if not worker then
        return failed(err)
    end
    self.epub_worker = worker
end

function Controller:showExportOptions()
    local c, dialog = self.catalog
    local function run(scope, mode)
        local items, err = c:exportItems(scope)
        if not items and not ((mode == "full" or mode == "epub") and err == "empty") then
            return self:notify(ExportDialog.reason(err))
        end
        self:closeModal(dialog)
        self:export(items or {}, mode or "notes")
    end
    local rows = {
        {
            {
                text = T(_("All document notes (%1)…"), #c.items),
                enabled = #c.items > 0,
                callback = function()
                    run("all")
                end,
            },
        },
        {
            {
                text = T(_("Filtered results (%1)…"), #c.result),
                enabled = #c.result > 0,
                callback = function()
                    run("results")
                end,
            },
        },
        {
            {
                text = T(_("Selected notes (%1)…"), c:selectionCount()),
                enabled = c:selectionCount() > 0,
                callback = function()
                    run("selected")
                end,
            },
        },
        {
            {
                text = _("Select this list page"),
                callback = function()
                    for _, id in ipairs(self.browser.visible_ids) do
                        c.selected[id] = true
                    end
                    self:closeModal(dialog)
                    self:changed()
                end,
            },
        },
        {
            {
                text = _("Select all filtered results"),
                callback = function()
                    for _, item in ipairs(c.result) do
                        c.selected[item.id] = true
                    end
                    self:closeModal(dialog)
                    self:changed()
                end,
            },
        },
        {
            {
                text = _("Clear selection"),
                callback = function()
                    c.selected = {}
                    self:closeModal(dialog)
                    self:changed()
                end,
            },
        },
    }
    if require("ink_document_export_full").supports(self.host.ui) then
        rows[#rows + 1] = {
            {
                text = _("Annotated pages as images…"),
                enabled = #c.items > 0,
                callback = function()
                    run(c:selectionCount() > 0 and "selected" or "results", "context")
                end,
            },
        }
        rows[#rows + 1] =
            { {
                text = _("Complete document as images…"),
                callback = function()
                    run("all", "full")
                end,
            } }
    end
    if require("ink_epub_export_worker").supports(self.host.ui) then
        rows[#rows + 1] =
            { {
                text = _("Complete EPUB with notes appendix…"),
                callback = function()
                    run("all", "epub")
                end,
            } }
    end
    rows[#rows + 1] = { {
        text = _("Close"),
        callback = function()
            self:closeModal(dialog)
        end,
    } }
    local items = {}
    for _, row in ipairs(rows) do
        local item = row[1]
        item.select_enabled, item.dim = item.enabled ~= false, item.enabled == false
        items[#items + 1] = item
    end
    dialog = require("ui/widget/menu"):new {
        title = _("Export and selection"),
        item_table = items,
        items_per_page = math.max(
            3,
            math.floor(Device.screen:getHeight() / Device.screen:scaleBySize(65)) - 2
        ),
        close_callback = function()
            self:closeModal(dialog)
        end,
    }
    self:showModal(dialog)
end

return Controller
