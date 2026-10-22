return function(ctx)
    local t, support = ctx.t, ctx.support
    local Catalog = require("ink_document_notes_catalog")
    local Note = require("ink_document_note")
    local function fixture(count)
        local rows = {}
        for i = 1, count do rows[i] = {id = i, fixed_page = count - i + 1,
            logical_w = 600, logical_h = 800, surface_role = "page_ink", updated_at = i} end
        local store, sched = support.newCanvasStore(rows), support.newScheduler()
        local c = Catalog.new{repository = store, book_id = 1, units = "pt", screen = {w = 600,h = 800},
            schedule = function(fn) sched:schedule(fn) end,
            chapter = function(page) return page <= 100 and "First" or "Second" end}
        return c, store, sched
    end
    t:describe("document notes / metadata catalogue")
    t:case("5000 notes load and sort cooperatively without decoding ink", function()
        local c, store, sched = fixture(5000)
        c:start()
        t:eq(#c.items, 0, "opening returns before querying rows")
        sched:tick()
        t:eq(#c.items, 100, "only one bounded batch")
        local ticks = sched:drain()
        t:check(ticks > 500, "sorting as well as loading yields")
        t:eq(c.state, "ready", "catalogue complete")
        t:eq(#c.result, 5000, "all rows, beyond the first batch")
        t:eq(c.result[1].page, 1, "reading order")
        t:eq(c.result[5000].page, 5000, "last note")
        t:eq(store.calls.stroke_read, 0, "no point payload")
        t:eq(store.calls.stroke_list, 0, "no surface opened")
    end)
    t:case("selection survives filters and exports exactly the chosen identities", function()
        local c, _, sched = fixture(250); c:start(); sched:drain()
        local a, b = c.result[1].id, c.result[220].id
        c:toggle(a); c:toggle(b)
        c:query({chapter = "First"}, "recent"); sched:drain()
        t:eq(#c.result, 100, "chapter filter")
        t:eq(c:selectionCount(), 2, "selection spans hidden results")
        t:eq(#c:exportItems("selected"), 2, "only explicit selection")
        t:eq(#c:exportItems("results"), 100, "all filtered results")
        t:eq(#c:exportItems("all"), 250, "all is independent of the filter")
        c:query({first = 45, last = 48}); sched:drain()
        t:eq(#c.result, 4, "inclusive page range")
        t:eq(c.result[1].page, 45, "range starts in document order")
    end)
    t:case("replacement filters cancel earlier sorts and close cancels queued reads", function()
        local c, _, sched = fixture(200); c:start(); sched:drain()
        c:query({first = 1,last = 40}); sched:tick()
        c:query({first = 90,last = 95}); sched:drain()
        t:eq(#c.result, 6, "no stale query result")
        t:eq(c.result[1].page, 90, "last query wins")
        local fresh, _, next_sched = fixture(500)
        fresh:start(); fresh:close(); next_sched:drain()
        t:eq(#fresh.items, 0, "closed owner never reads")
    end)
    t:case("missing locations and legacy ink stay visible and exportable", function()
        local sched = support.newScheduler()
        local rows = {{id = 7, logical_w = 600, logical_h = 800}, {id = 3,logical_w = 600,logical_h = 800}}
        local index = {
            phase = function() return "ready" end,
            metadataBatch = function(_, offset, limit)
                local out = {}; for i = offset+1,math.min(#rows,offset+limit) do out[#out+1]=rows[i] end
                return out,true
            end,
            pageOf = function(_, id) if id == 7 then return 4 end end,
        }
        local c = Catalog.new{rolling = true, index = index, screen = {w=600,h=800},
            schedule = function(fn) sched:schedule(fn) end,
            legacy = {pages = function() return {4} end}}
        c:start(); sched:drain()
        t:eq(#c.result, 3, "all kinds kept")
        t:eq(c.result[1].kind, "legacy_page", "legacy first on same page")
        t:eq(c.result[3].page, nil, "orphan has no invented page")
        c:query({unlocated=true}); sched:drain()
        t:eq(#c:exportItems("results"), 1, "orphan export available")
    end)
    t:case("read failures are not presented as an empty book", function()
        local c, store, sched = fixture(5)
        store.fail_list_page_ink = "locked"
        c:start(); sched:drain()
        t:eq(c.state,"error","explicit error")
        t:eq(c.error,"locked","reason retained")
        t:eq(select(2,c:exportItems("all")),"index_incomplete","no partial export")
    end)
    t:case("an unavailable source is not presented as an empty book", function()
        local c, _, sched = fixture(0)
        c.opts.source_error = "no_repository"
        c:start(); sched:drain()
        t:eq(c.state,"error","source unavailable")
        t:eq(select(2,c:exportItems("all")),"index_incomplete","whole book cannot claim completeness")
    end)
    t:case("chapters with the same title keep distinct identities", function()
        local c, _, sched = fixture(4)
        c.opts.chapter = function(page) return "Introduction", page <= 2 and "a" or "b" end
        c:start(); sched:drain(); c:query({chapter_key="b"}); sched:drain()
        t:eq(#c.result,2,"same title does not merge chapters")
        t:eq(c.result[1].page,3,"chosen chapter starts at its own location")
        c:close()
        t:eq(#c.items,0,"metadata freed on close")
        t:eq(next(c.opts),nil,"borrowed repository and index released")
    end)
    t:case("shared descriptors have unique kinds and total order", function()
        local sheet = Note.new{kind="sheet",page=1,surface={id=1}}
        local legacy = Note.new{kind="legacy_page",page=1}
        t:check(sheet.id ~= legacy.id,"source namespacing")
        t:check(Note.before(legacy,sheet),"legacy order preserved")
        t:check(not Note.before(sheet,sheet),"strict comparator")
    end)
    t:case("a fixed layout lists its page notes and the sheets on its pages", function()
        local PageIndex = require("ink_page_index")
        local rows = {
            {id = 1, fixed_page = 4, logical_w = 600, logical_h = 800,
             surface_role = "page_ink", anchor_kind = "page", updated_at = 1},
            {id = 2, fixed_page = 2, logical_w = 600, logical_h = 800,
             surface_role = "sheet", anchor_kind = "page", anchor_key = "page:2", updated_at = 2},
        }
        local store, sched = support.newCanvasStore(rows), support.newScheduler()
        local index = PageIndex.new{repository = store, book_id = 1,
            schedule = function(fn) sched:schedule(fn) end}
        index:open()
        sched:drain()
        local c = Catalog.new{repository = store, sheet_repository = store, book_id = 1,
            index = index, units = "pt", screen = {w = 600, h = 800},
            schedule = function(fn) sched:schedule(fn) end,
            chapter = function() return "First" end}
        c:start()
        sched:drain()
        t:eq(c.state, "ready", "loaded")
        local kinds, sheet = {}, nil
        for _, item in ipairs(c.result) do
            kinds[item.kind] = (kinds[item.kind] or 0) + 1
            if item.kind == "sheet" then sheet = item end
        end
        t:eq(kinds.page_ink, 1, "the page note")
        t:eq(kinds.sheet, 1, "and the sheet")
        t:eq(sheet and sheet.page, 2, "placed by its own page, not by locating")
        t:eq(c.result[1].kind, "sheet", "in page order: page 2 before page 4")
    end)

    t:case("deleting a selection takes every sheet of a note and nothing KOReader owns", function()
        local Controller = require("ink_document_notes_controller")
        local group = {id = "note:1", kind = "sheet", surface = {id = 3},
            sheets = {{surface = {id = 3}}, {surface = {id = 4}}}}
        local lone = {id = "sheet:5", kind = "sheet", surface = {id = 5}}
        local page = {id = "page:6", kind = "page_ink", surface = {id = 6}}
        local native = {id = "native:x", kind = "native_highlight"}
        local legacy = {id = "legacy:2", kind = "legacy_page"}
        local unselected = {id = "sheet:9", kind = "sheet", surface = {id = 9}}
        local c = Controller.new{}
        c.catalog = {items = {group, lone, page, native, legacy, unselected}, selected = {
            [group.id] = true, [lone.id] = true, [page.id] = true,
            [native.id] = true, [legacy.id] = true}}
        local ids, notes, skipped = c:selectedDeletion()
        table.sort(ids)
        t:eq(table.concat(ids, ","), "3,4,5,6", "both sheets of the note, the lone sheet and the page")
        t:eq(notes, 3, "three notes")
        t:eq(skipped, 2, "the annotation and the legacy page are kept")

        local asked
        c.host = {notify = function(_, text) asked = text end,
            deleteDocumentNotes = function() error("must not be reached") end}
        c.catalog.selected = {[native.id] = true}
        c:confirmDeleteSelected()
        t:check(asked ~= nil, "a selection with nothing deletable says so instead of asking")
    end)
    t:describe("document notes / native annotations and logical sheets")
    t:case("native identity survives edits and duplicate anchors span batches", function()
        local Native=require("ink_native_annotations")
        local a={page=7,datetime="2026-09-05 10:00:00",text="Quote",note="First",pos0={x=1,y=2}}
        local b={};for k,v in pairs(a)do b[k]=v end
        local ui={annotation={annotations={a,b}}}
        local duplicates={}
        local first=Native.snapshot(ui,0,1,duplicates)[1]
        local second=Native.snapshot(ui,1,1,duplicates)[1]
        t:check(first.id~=second.id,"duplicates have distinct stable identities")
        a.note="Edited"
        t:eq(Native.snapshot(ui)[1].id,first.id,"text edit keeps identity")
        t:eq(Native.findIndex(ui,second.id),2,"exact annotation is found without text layout")
        t:eq(first.page,7,"fixed source page retained")
        t:check(Native.matches(first,"FIRST"),"case-insensitive search")
    end)
    t:case("UTF-8 chunks preserve every byte of long text", function()
        local Text=require("ink_native_text")
        local value=string.rep("Árbol 漢字 📝\n",2000).."FIN"
        local chunks=Text.chunks(value)
        t:eq(table.concat(chunks),value,"all text including final characters preserved")
        for _,chunk in ipairs(chunks)do
            t:check(#chunk<=Text.CHUNK_BYTES,"layout input is bounded")
            local byte=chunk:byte(1)
            t:check(not byte or byte<128 or byte>=192,"starts at a UTF-8 boundary")
        end
    end)
    t:case("grouped sheets export as one selection in saved order", function()
        local sched=support.newScheduler()
        local rows={{id=1,logical_w=600,logical_h=800},{id=2,logical_w=600,logical_h=800},{id=3,logical_w=600,logical_h=800}}
        local index={phase=function()return "ready"end,metadataBatch=function()return rows,true end,pageOf=function()return 7 end}
        local c=Catalog.new{rolling=true,index=index,screen={w=600,h=800},schedule=function(fn)sched:schedule(fn)end,
            memberships=function()return {{canvas_id=1,note_id=9,position=2},{canvas_id=2,note_id=9,position=1}}end}
        c:start();c.selected["sheet:1"]=true;sched:drain()
        t:eq(#c.items,2,"group and independent note")
        local group=c.by_id["note:9"]
        t:eq(group.sheets[1].surface.id,2,"saved order overrides canvas ids")
        t:check(c.selected[group.id] and not c.selected["sheet:1"],"selection follows a newly grouped sheet")
        local selected=c:exportItems("selected")
        t:eq(#selected,1,"selection counts logical notes")
        local flat
        require("ink_document_notes_prepare").start(selected,function(fn)sched:schedule(fn)end,function(items)flat=items end)
        sched:drain()
        t:eq(#flat,2,"all selected sheets prepared")
        t:eq(flat[1].surface.id,2,"export retains sheet order")
    end)
    t:describe("document notes / complete document scope")
    local Full = require("ink_document_export_full")
    t:case("full export keeps unannotated pages and context uses exact selection", function()
        local a = Note.new{kind="page_ink",page=3,surface={id=30}}
        local b = Note.new{kind="page_ink",page=1,surface={id=10}}
        local legacy = Note.new{kind="legacy_page",page=2}
        local all = assert(Full.items(4,{a,b,legacy},false))
        t:eq(#all,5,"every source page plus explicit legacy appendix")
        t:eq(all[2].page,2,"unannotated page retained")
        t:eq(all[2].note,nil,"no invented overlay")
        t:eq(all[3].note,a,"right note on right page")
        t:eq(all[5],legacy,"legacy never guessed onto a document page")
        local selected = assert(Full.items(4,{a},true))
        t:eq(#selected,1,"context only contains selected ink")
        t:eq(selected[1].page,3,"preserves source page number")
        t:eq(#assert(Full.items(2,{},false)),2,"empty notes still export whole document")
        t:eq(select(2,Full.items(2,{},true)),"empty","empty context is explicit")
    end)
    t:case("invalid pages and oversized exports are never silently truncated", function()
        t:eq(select(2,Full.items(5001,{},false)),"too_many_pages","full page limit")
        t:eq(select(2,Full.items(0,{},false)),"bad_geometry","invalid source")
        local bad = {kind="page_ink",page=4}
        t:eq(select(2,Full.items(3,{bad},true)),"bad_geometry","stale location")
        t:eq(select(2,Full.items(5,{bad,bad},true)),"bad_surface","ambiguous overlay refused")
        t:eq(#assert(Full.items(1000000,{bad},true)),1,"context does not scan all source pages")
    end)
end
