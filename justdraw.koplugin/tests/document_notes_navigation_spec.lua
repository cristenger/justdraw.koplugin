-- Navigation is a handoff of ownership, not merely a reader event. Exercise
-- its failures with real plugin/session code and controlled completion ticks.
return function(ctx)
    local t, env, support = ctx.t, ctx.env, ctx.support
    local Controller = require("ink_document_notes_controller")
    local Catalog = require("ink_document_notes_catalog")
    local Note = require("ink_document_note")
    local function drain(predicate)
        for _ = 1, 300 do
            env.UIManager:flush()
            if predicate() then return end
        end
        error("navigation did not settle")
    end
    local function fixture()
        ctx.reset{wacom_protocol=true}
        local rows = {}
        for i, xp in ipairs({"/a", "/b", "/b2"}) do
            rows[i] = {id=i,anchor_kind="xpointer",anchor_key="xp:"..xp,
                anchor_raw=xp,anchor_normalized=xp,logical_w=600,logical_h=800}
        end
        local doc = support.newDocument{pages={["/a"]=3,["/b"]=10,["/b2"]=10},here="/a",current_page=3}
        doc.getPageCount = function() return 30 end
        local store = support.newCanvasStore(rows)
        for _, row in ipairs(rows) do
            store:putStroke(row.id,{width=3,tool=1,n=2,points={10,10,30,30}})
        end
        local p = support.newPlugin(ctx.JustDraw,env,{document=doc,page=3})
        p.canvas_repository = store
        env.UIManager:flush(); p:onReaderReady()
        drain(function() return not p.session:isIndexing() end)
        local events, history = {}, {}
        p.ui.link = {addCurrentLocationToStack=function() history[#history+1]=p:currentPage() end}
        p.ui.handleEvent = function(_, event)
            if event.handler == "onGotoXPointer" or event.handler == "onGotoPage" then
                events[#events+1] = event
                local page = event.handler == "onGotoXPointer" and doc.pages[event.args[1]] or event.args[1]
                doc.current_page, p.view.state.page = page, page
                p:onPageUpdate(page)
            end
            return true
        end
        local notes = Controller.new(p)
        p.notes_controller = notes
        local items = {}
        for i, row in ipairs(rows) do items[i]=Note.new{kind="sheet",surface=row,page=doc.pages[row.anchor_raw]} end
        local function browser()
            local c = Catalog.new{}
            c.state,c.items,c.result,c.busy="ready",items,items,false
            for _, item in ipairs(items) do c.by_id[item.id]=item end
            notes.catalog = c
            notes.browser = {first=1,visible_ids={items[1].id},select_mode=false,
                _rebuild=function() end}
        end
        browser()
        return p,notes,items,store,doc,events,history,browser
    end
    local function settle(p)
        drain(function() return not p.notes_controller.pending_navigation
            and (not p.canvas_open or p.session:cache():stateName() ~= "loading") end)
    end

    t:describe("document notes / contextual reader handoff")
    t:case("view replaces another panel, read closes it, and Show preserves exact sheet", function()
        local p,n,items,store,doc,events,history,browser=fixture()
        p:openCanvas(items[1].surface); settle(p)
        t:eq(p.drawing,true,"A is initially editing")
        n.focus_id,n.surface_id="note:12",3
        t:eq(n:navigate(items[3],"view"),true,"B2 accepted")
        t:eq(p.canvas_open,false,"A removed before B is displayed")
        t:eq(p:currentPage(),10,"correct book page")
        settle(p)
        t:eq(p.session:activeCanvas().id,3,"exact B2 leaf")
        t:eq(p.drawing,false,"view is not editing")
        t:eq(p.input_lease,nil,"no hidden capture")
        t:eq(p.session:overlay().height_pct,40,"partial context height")
        t:eq(events[1].args[2],nil,"no delayed marker over panel")
        t:eq(#history,1,"one history entry")
        t:eq(p.bar.pen_btn.enabled,false,"tools require Draw")
        p:setDrawing(true); t:eq(p.drawing,true,"explicit Draw")
        p:setDrawing(false)
        p.session:overlay():setHeight(100)
        t:eq(p:hideNote(),true,"Hide succeeds")
        t:eq(p.session:cache(),nil,"hidden raster released")
        t:eq(p.bar.note_return,true,"compact controls")
        p:showNote(); settle(p)
        t:eq(p.session:activeCanvas().id,3,"Show keeps B2")
        t:eq(p.session:overlay().height_pct,100,"Show keeps expansion")
        t:eq(#history,1,"Show does not navigate")
        p:hideNote()
        doc.current_page,p.view.state.page=3,3; p:onPageUpdate(3)
        t:eq(p.bar.show_btn.text,"Go to note","away label is explicit")
        p:showNote(); settle(p)
        t:eq(p:currentPage(),10,"Go returns to original page")
        t:eq(#history,2,"Go pushes once")
        browser(); t:eq(n:navigate(items[1],"read"),true,"read accepted")
        settle(p)
        t:eq(p.canvas_open,false,"read has no panel")
        t:eq(p.note_context.surface_id,1,"return route belongs to read target")
        t:eq(p.drawing,false,"read stays stopped")
        p:teardown()
    end)

    t:case("preflight failures preserve viewer, position and retryable old ink", function()
        local p,n,items,store,doc,events,history=fixture()
        p:openCanvas(items[1].surface); settle(p)
        local old, browser=p.session:overlay(),n.browser
        doc.pages["/b"]=nil
        t:eq(n:navigate(items[2],"view"),false,"cached page cannot rescue lost anchor")
        t:eq(n.browser,browser,"viewer owner retained")
        t:eq(p.session:overlay(),old,"old sheet retained")
        doc.pages["/b"]=10
        items[2].surface.logical_w=0
        t:eq(n:navigate(items[2],"view"),false,"bad geometry refused")
        items[2].surface.logical_w=600
        p.session:addStroke({20,20,40,40},2,3,1)
        store.fail_transaction="commit"
        t:eq(n:navigate(items[2],"view"),false,"failed flush refuses movement")
        t:eq(p.session:overlay(),old,"retryable sheet survives")
        t:check(p.session:pendingWrites()>0,"pending ink survives")
        t:eq(#events,0,"no reader event on preflight failure")
        t:eq(#history,0,"no history on refusal")
        store.fail_transaction=nil; p:teardown()
    end)

    t:case("empty and populated context views keep capture off through rotation", function()
        for _, empty in ipairs({true,false}) do
            local p,n,items,store=fixture()
            if empty then store.strokes[2]={} end
            n:navigate(items[2],"view"); settle(p)
            t:eq(p.drawing,false,"ready remains view")
            local screen=require("device").screen
            local w,h=screen.w,screen.h
            screen.w,screen.h=h,w
            p:onScreenResize(); settle(p)
            t:eq(p.drawing,false,"rotated ready remains view")
            t:eq(p.input_lease,nil,"rotation cannot acquire capture")
            t:eq(p.bar.note_context,p.note_context,"context controls retained")
            t:eq(p.session:overlay().height_pct,40,"transient height retained")
            screen.w,screen.h=w,h
            p:teardown()
        end
    end)

    t:case("Hide refuses a failed save and keeps the exact retryable sheet", function()
        local p,n,items,store=fixture()
        n:navigate(items[2],"view"); settle(p)
        local overlay=p.session:overlay()
        p.session:addStroke({20,20,40,40},2,3,1)
        store.fail_transaction="commit"
        local ok=p:hideNote()
        t:check(not ok,"Hide refused")
        t:eq(p.session:overlay(),overlay,"visible sheet retained")
        t:eq(p.note_context.surface_id,2,"return identity retained")
        t:check(p.session:pendingWrites()>0,"pending ink retained")
        store.fail_transaction=nil
        t:eq(p:hideNote(),true,"Hide succeeds after recovery")
        t:eq(p.drawing,false,"save recovery cannot turn viewing into editing")
        p:teardown()
    end)

    t:case("non-sheet locations validate bounds without creating a panel", function()
        local p,n=fixture()
        local page={kind="page_ink",page=2}
        t:eq(n:canNavigate(page,"view"),false,"unavailable page renderer cannot promise View")
        t:eq(n:canNavigate(page,"read"),true,"location remains readable")
        t:eq(n:canNavigate({kind="legacy_page",page=31},"read"),false,"out of range refused")
        t:eq(n:canNavigate({kind="legacy_page",page=1.5},"read"),false,"fractional page refused")
        local native={kind="bookmark",xpointer="/b",native=true}
        t:eq(n:canNavigate(native,"view"),false,"native has one reader destination")
        t:eq(n:navigate(native,"read"),true,"native location accepted")
        settle(p)
        t:eq(p:currentPage(),10,"native anchor used")
        t:eq(p.canvas_open,false,"no new panel")
        t:eq(p.note_context,nil,"no invented sheet return route")
        p:teardown()
    end)

    t:case("read-only sheets view and recover without writing or drawing", function()
        local p,n,items,store,_,_,_,browser=fixture()
        store.read_only=true
        t:eq(n:canEdit(items[2]),false,"edit refused")
        t:eq(n:navigate(items[2],"view"),true,"view allowed")
        settle(p)
        t:eq(p.session:activeCanvas().id,2,"readable target opened")
        t:eq(p.bar.draw_btn.enabled,false,"Draw disabled")
        p:setDrawing(true); p:onCanvasSaveRecovered(items[2].surface)
        t:eq(p.drawing,false,"callbacks cannot arm read-only input")
        t:eq(p.session:pendingWrites(),0,"no writes from viewing")
        browser(); t:eq(n:navigate(items[3],"read"),true,"read also allowed")
        settle(p); p:teardown()
    end)

    t:case("superseding requests and lifecycle changes cancel delayed opening", function()
        for _, cancel in ipairs({"close","suspend","rerender","page","book","generic"}) do
            local p,n,items,_,doc=fixture()
            n:navigate(items[2],"view")
            local old_request=n.pending_navigation
            if cancel=="close" then n:close()
            elseif cancel=="suspend" then p:onSuspend()
            elseif cancel=="rerender" then p:onDocumentRerendered()
            elseif cancel=="page" then doc.current_page,p.view.state.page=3,3; p:onPageUpdate(3)
            elseif cancel=="book" then p.ui.document={file="other.epub"}
            else p:openCanvas(items[3].surface,{mode="view"}) end
            old_request.run()
            t:check(not p.canvas_open or p.session:activeCanvas().id~=2,cancel.." prevents stale B")
            t:eq(p.drawing,false,cancel.." cannot arm drawing")
            p:teardown()
        end
        local p,n,items=fixture()
        n:navigate(items[2],"view"); local old=n.pending_navigation
        n:navigate(items[3],"view"); old.run(); settle(p)
        t:eq(p.session:activeCanvas().id,3,"latest request wins")
        p:teardown()
    end)

    t:case("dismiss and rotation preserve transient bar ownership and deletion clears identity", function()
        local p,n,items=fixture()
        p:setBarShown(false)
        local shown=G_reader_settings.data.justdraw_bar_shown
        n:navigate(items[2],"view"); settle(p); p:hideNote()
        p:rebuildBar()
        t:eq(p.bar.note_return,true,"rotation retains return variant")
        p:dismissNoteReturnBar(); env.UIManager:flush()
        t:eq(p.bar,nil,"no delayed toolbar resurrection")
        t:eq(G_reader_settings.data.justdraw_bar_shown,shown,"transient flow preserves preference")
        p:showNote(); settle(p); p:hideNote()
        p:deleteCanvas(items[2].surface)
        t:eq(p.note_context,nil,"deleted hidden sheet forgotten")
        t:eq(p.bar,nil,"return control removed")
        p:teardown()
    end)

    t:case("restoration scans bounded metadata and waits for final results", function()
        local p,n=fixture()
        local result={}
        for i=1,5000 do result[i]={id="sheet:"..i,surface={id=i}} end
        n.catalog.result=result
        n.restore_state={first=4401,first_id="sheet:4401",focus_id="sheet:4444",surface_id=4444}
        local calls=0
        n.browser._rebuild=function() calls=calls+1 end
        n.catalog.busy=true; n:restoreBrowser()
        t:eq(n.restore_job,nil,"partial query cannot restore")
        n.catalog.busy=false; n:restoreBrowser(); env.UIManager:flush()
        t:eq(calls,0,"one slice does not scan all 5000 notes")
        drain(function() return n.restore_job==nil end)
        t:eq(n.browser.first,4401,"viewport restored")
        t:eq(n.browser.restore_focus,4444,"focus independent of checkbox selection")
        t:eq(n.surface_id,4444,"exact sheet retained")
        n.restore_state={first=20}; n:restoreBrowser(); n:cancelRestore(); env.UIManager:flush()
        t:eq(n.browser.first,4401,"user cancellation beats late restore")
        p:teardown()
    end)
end
