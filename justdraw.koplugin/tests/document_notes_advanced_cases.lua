-- Called by the native check after its original PDF/EPUB scenarios.
return function(ctx)
    local UI, home, pump, picture = ctx.UI, ctx.home, ctx.pump, ctx.picture
    dofile(
        debug
            .getinfo(1, "S").source
            :sub(2)
            :gsub("document_notes_advanced_cases.lua$", "document_note_repository_native.lua")
    )(home)
    local doc = assert(
        require("document/documentregistry"):openDocument(
            require("ffi/util").realpath("../../test/juliet.epub")
        )
    )
    local reader =
        require("apps/reader/readerui"):new { dimen = require("device").screen:getSize(), document = doc }
    UI:show(reader)
    local host = assert(reader.justdraw or require("pluginloader"):getPluginInstance("justdraw"))
    pump(function()
        return host.session and host.session:isAvailable() and not host.session:isIndexing()
    end)
    local session = host.session
    local root = assert(session:createHere(host:currentPage()))
    local Groups = require("ink_note_repository").new(session.repository)
    local second = assert(Groups:append(session.book_id, root))
    local third = assert(Groups:append(session.book_id, root))
    session.index:add(second)
    session.index:add(third)
    local members = assert(Groups:memberships(session.book_id))
    local note_id
    for _, m in ipairs(members) do
        if m.canvas_id == root.id then
            note_id = m.note_id
        end
    end
    assert(note_id)
    assert(Groups:reorder(session.book_id, note_id, { third.id, root.id, second.id }))
    assert(
        not Groups:reorder(session.book_id, note_id, { third.id, root.id, root.id }),
        "invalid reorder accepted"
    )
    local xp = doc:getXPointer()
    local long = string.rep("Una anotación extensa con acentos, líneas y contexto.\n", 350) .. "FIN_ÚLTIMO"
    reader.annotation:addItem {
        page = xp,
        pos0 = xp,
        pos1 = xp,
        text = "Texto citado",
        note = long,
        datetime = "2026-09-05 10:00:00",
        drawer = "lighten",
    }
    local Native = require("ink_native_annotations")
    local native = Native.snapshot(reader)[1]
    assert(native and native.native.note == long)
    local identity = native.id
    reader.annotation.annotations[1].note = long .. " editado"
    assert(Native.snapshot(reader)[1].id == identity, "editing changed annotation identity")
    reader.annotation.annotations[1].note = long
    assert(host:onShowDocumentNotes())
    local notes = host.notes_controller
    pump(function()
        return notes.catalog.state == "ready" and not notes.catalog.busy
    end)
    local group = assert(notes.catalog.by_id["note:" .. note_id])
    assert(#group.sheets == 3 and group.sheets[1].surface.id == third.id, "group ordering lost")
    assert(notes.catalog.by_id[identity], "native annotation not integrated")
    notes.browser:_rebuild()
    picture(notes.browser, "advanced-mixed-list")
    assert(notes:showDetail(group.id, 2))
    pump(function()
        return notes.detail
    end)
    picture(notes.detail, "advanced-multiple-sheets")
    notes.detail.next_note()
    pump(function() return notes.detail end)
    picture(notes.detail, "advanced-next-sheet")
    notes.detail.previous_note()
    pump(function() return notes.detail end)
    picture(notes.detail, "advanced-previous-sheet")
    notes:organizeSheets(group)
    local organize = ctx.topOwned(notes)
    assert(organize ~= notes.detail and organize ~= notes.browser)
    picture(organize, "advanced-organize-sheets")
    organize.item_table[1].callback()
    local position_input = ctx.topOwned(notes)
    assert(position_input ~= organize)
    assert(position_input:isKeyboardVisible(), "sheet position keyboard was not exercised")
    picture(position_input, "advanced-sheet-position-keyboard")
    notes:closeModal(position_input)
    picture(organize, "advanced-return-to-organize")
    organize.item_table[2].callback()
    notes:onScreenResize()
    UI:_repaint()
    assert(UI._window_stack[#UI._window_stack].widget == notes.browser,
        "resize retained a child dialog or keyboard")
    assert(not notes.preview_job and not notes.preview_result)
    assert(notes:showDetail(identity))
    picture(notes.detail, "advanced-native-detail")
    notes.detail:findDialog()
    local find = UI:getNthTopWidget(2)
    assert(find and find.title == "Enter text to search for", "native search is hidden")
    assert(find:isKeyboardVisible())
    picture(find, "advanced-native-find-keyboard")
    find:setInputText("FIN_ÚLTIMO")
    notes.detail:findCallback(find)
    picture(notes.detail, "advanced-native-find-last-line")
    assert(notes.detail.search_value == "FIN_ÚLTIMO")
    notes.detail:onShowMenu()
    local text_menu = UI:getNthTopWidget()
    assert(text_menu ~= notes.detail, "native text menu is hidden")
    picture(text_menu, "advanced-native-font-menu")
    UI:close(text_menu)
    notes:closeDetail()
    notes.catalog:query({ search = "fin_último" })
    pump(function()
        return not notes.catalog.busy
    end)
    assert(#notes.catalog.result == 1, "native text search failed")
    local prepared, prep_err
    require("ink_document_notes_prepare").start(notes.catalog.items, function(fn)
        UI:nextTick(fn)
    end, function(items, err)
        prepared, prep_err = items, err
    end)
    pump(function()
        return prepared or prep_err
    end)
    assert(prepared, prep_err)
    local native_pages, tail = 0, false
    for _, item in ipairs(prepared) do
        if item.native then
            native_pages = native_pages + 1
            tail = tail or item.text_chunk:find("FIN_ÚLTIMO", 1, true) ~= nil
        end
    end
    assert(native_pages > 1 and tail, "long native note was truncated")
    local direct = assert(host.export_controller:build("notes"))
    assert(#direct.items == #prepared, "original export entry omitted native notes or sheets")
    local direct_sheets = {}
    for _, item in ipairs(direct.items) do
        if item.kind == "sheet" and item.page then
            direct_sheets[#direct_sheets + 1] = item.surface.id
        end
    end
    assert(
        direct_sheets[1] == third.id and direct_sheets[2] == root.id,
        "original export entry ignored saved sheet order"
    )
    direct.finish()
    local position, hash = doc:getXPointer(), doc:getDocumentRenderingHash()
    local annotations = require("json").encode(reader.annotation.annotations)
    local result, content_pages, warning, first_raster, last_raster
    require("ink_export_dialog").run {
        format = "pdf",
        dir = home,
        stem = "complete-epub-with-notes",
        build_async = function(done)
            notes:buildEPUB(prepared, 150, function(built, err)
                assert(built, err)
                content_pages = #built.items - #prepared
                local render = built.render
                built.render = function(item, index, callback)
                    render(item, index, function(raster, reason)
                        if
                            raster
                            and item.kind == "epub_page"
                            and (item.page == 1 or item.page == content_pages)
                        then
                            local bytes = require("ffi").string(
                                raster.bb.data,
                                raster.bb:getWidth() * raster.bb:getHeight()
                            )
                            if item.page == 1 then
                                first_raster = bytes
                            else
                                last_raster = bytes
                            end
                            raster.bb:writePNG(home .. "/epub-content-" .. item.page .. ".png")
                        end
                        callback(raster, reason)
                    end)
                end
                done(built)
            end)
        end,
        show_modal = function(widget)
            notes:showModal(widget)
            if widget.ok_callback then
                warning = widget
            end
            return true
        end,
        close_modal = function(widget)
            notes:closeModal(widget)
        end,
        notify = function(message)
            print(message)
        end,
        schedule = function(fn)
            UI:nextTick(fn)
        end,
        on_finished = function(value)
            result = value
        end,
    }
    pump(function()
        return warning
    end)
    picture(warning, "advanced-epub-warning")
    local approve = warning.ok_callback
    notes:closeModal(warning)
    approve()
    pump(function()
        return result
    end)
    assert(result.status == "done", result.error)
    assert(content_pages > 0, "no EPUB content pages")
    assert(first_raster and last_raster and first_raster ~= last_raster, "EPUB end repeats its cover")
    assert(doc:getXPointer() == position and doc:getDocumentRenderingHash() == hash, "worker altered reader")
    assert(
        require("json").encode(reader.annotation.annotations) == annotations,
        "export altered native annotations"
    )
    assert(not notes.epub_worker, "worker retained after completion")
    local Worker = require("ink_epub_export_worker")
    local late = false
    local cancelled = assert(Worker.start {
        document = doc,
        dpi = 150,
        notes = {},
        schedule_in = function(delay, fn)
            UI:scheduleIn(delay, fn)
        end,
        ready = function()
            late = true
        end,
        error = function()
            late = true
        end,
    })
    cancelled:close()
    pump(function()
        return require("ffi/util").isSubProcessDone(cancelled.pid)
    end)
    assert(not late, "cancelled worker delivered callbacks")
    local ready = false
    local rendering = assert(Worker.start {
        document = doc,
        dpi = 300,
        notes = {},
        schedule_in = function(delay, fn)
            UI:scheduleIn(delay, fn)
        end,
        ready = function()
            ready = true
        end,
        error = function(err)
            error(err)
        end,
    })
    pump(function()
        return ready
    end)
    assert(rendering.manifest.w > 1000, "300 dpi was not applied")
    rendering:render(1, function()
        late = true
    end)
    rendering:close()
    pump(function()
        return require("ffi/util").isSubProcessDone(rendering.pid)
    end)
    assert(not late, "cancelled page delivered a raster")
    notes:showNativeAnnotations(notes.catalog.by_id[identity])
    local native_details = UI._window_stack[#UI._window_stack].widget
    assert(
        native_details.text and native_details.text:find("FIN_ÚLTIMO", 1, true),
        "native details opened a different annotation"
    )
    picture(native_details, "advanced-native-edit-details")
    UI:close(native_details)
    notes:close()
    host:teardown()
    reader:onClose(false)
    print(
        string.format(
            "PASS advanced: 3 ordered sheets; %d native text pages; %d EPUB pages; isolation and worker cancellation",
            native_pages,
            content_pages
        )
    )
end
