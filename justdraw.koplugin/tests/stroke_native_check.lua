--[[--
Stroke fidelity against KOReader's real raster and SQLite. Run from the build
with its LuaJIT and a fresh output directory as arg[1]. No Device, ReaderUI or
user database is opened. The scheduler alone is borrowed from the test harness.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local tests = assert(here:match("^(.*)/[^/]+$"))
local root = assert(tests:match("^(.*)/[^/]+$"))
package.path = root .. "/?.lua;" .. tests .. "/?.lua;" .. package.path
local Support = require("support")
local Surface = require("ink_surface_session")
local Transform = require("ink_canvas_transform")
local Codec = require("ink_canvas_codec")
local BB = require("ffi/blitbuffer")
local SQL = require("lua-ljsqlite3/init")
local out = assert(arg[1], "a fresh output directory is required")
local passed = 0
local function check(ok, why) assert(ok, why); passed = passed + 1 end
local function scalar(conn, sql) return tonumber(conn:rowexec(sql)) end
local function pixel(s, x, y)
    return tonumber(s:cache():buffer():getPixel(x, y):getColor8().a)
end
local function openSurface(repo, page, overlay)
    local sched = Support.newScheduler()
    local s = Surface.new{
        repository = repo, surface = page,
        cache_opts = { composition = overlay and "overlay" or "opaque", chunk_budget = 1 },
        transform = Transform.new{ logical_w = 460, logical_h = 200,
            fit_rect = { x = 0, y = 0, w = 460, h = 200 },
            clip_rect = { x = 0, y = 0, w = 460, h = 200 } },
        schedule = function(fn) sched:schedule(fn) end,
        scheduleIn = function(delay, fn) sched:scheduleIn(delay, fn) end,
        unschedule = function(fn) sched:unschedule(fn) end,
    }
    check(s:open(), "surface opens"); sched:drain()
    check(s:isReady(), "surface ready")
    return s
end

for _, kind in ipairs({ "canvas", "notebook" }) do
    local Repo = require("ink_" .. kind .. "_repository")
    local path = out .. "/" .. kind .. ".sqlite3"
    check(not io.open(path, "rb"), "test database must not exist")
    local table_name = kind == "canvas" and "strokes" or "notebook_strokes"
    local chunk_table = kind == "canvas" and "stroke_chunks" or "notebook_stroke_chunks"
    local old_version = Repo.SCHEMA_VERSION - 1
    local conn = SQL.open(path, "rwc")
    -- The previous schema differs only by this appended nullable column.
    local old_schema, removed = Repo.SCHEMA:gsub("    paint_seq    INTEGER,\n", "")
    check(removed == 1, "old schema fixture omits only visual order")
    conn:exec(old_schema)
    conn:exec("PRAGMA user_version=" .. old_version .. ";")
    if kind == "canvas" then
        conn:exec("INSERT INTO books VALUES(1,'synthetic',123,'/synthetic.pdf',1,1);")
        conn:exec([[INSERT INTO canvases(id,book_id,anchor_kind,anchor_key,fixed_page,
            logical_w,logical_h,created_at,updated_at) VALUES(1,1,'page','synthetic',1,460,200,1,1);]])
    else
        conn:exec("INSERT INTO notebooks VALUES(1,'Synthetic',1,2048,1,1,NULL);")
        conn:exec("INSERT INTO notebook_pages VALUES(1,1,1024,460,200,'blank',1,1,NULL);")
    end
    local owner = kind == "canvas" and "canvas_id" or "page_id"
    conn:exec("INSERT INTO " .. table_name .. "(id," .. owner
        .. ",seq,width,tool,codec,point_count,min_x,min_y,max_x,max_y,created_at)"
        .. " VALUES(1,1,1,4,1,1,3,30,100,430,100,1);")
    local blob = assert(Codec.encode({30,100,230,100,430,100},3,460,200))[1].points
    local stmt = conn:prepare("INSERT INTO " .. chunk_table
        .. " VALUES(1,0,3,CAST(?1 AS BLOB));")
    stmt:bind(blob); stmt:step(); stmt:close(); conn:close()

    -- A failure after ALTER TABLE must leave both rows and schema old.
    local refused, why = Repo.open{ path = path, wal = false, migrations = {
        [old_version] = function(c)
            Repo.MIGRATIONS[old_version](c)
            error("injected migration failure")
        end,
    } }
    check(refused == nil and why == "migration_failed", "failed migration is reported")
    conn = SQL.open(path, "ro")
    check(scalar(conn, "PRAGMA user_version;") == old_version, "version rolled back")
    check(scalar(conn, "SELECT COUNT(*) FROM " .. table_name .. ";") == 1, "row retained")
    local has_column = pcall(conn.rowexec, conn, "SELECT paint_seq FROM " .. table_name .. ";")
    check(not has_column, "column rolled back")
    conn:close()

    local repo = assert(Repo.open{ path = path, wal = false })
    check(repo.version == Repo.SCHEMA_VERSION, "migration completes")
    local backup = assert(SQL.open(path .. ".backup-v" .. old_version, "ro"))
    check(scalar(backup, "PRAGMA user_version;") == old_version, "backup has old version")
    backup:close()
    local page = { id = 1, notebook_id = 1, logical_w = 460, logical_h = 200 }
    local m = assert(repo:listStrokes(1))[1]
    check(m.paint_seq == 1, "old row inherits seq")
    local stored = assert(repo:readStrokeChunk(1,0))
    check(stored.points == blob, "point bytes unchanged by migration")
    local s = openSurface(repo, page)
    -- Densely sampled black crossing under a later marker.
    assert(s:undo()); assert(s:flush())
    local p = {}
    for x = 30,430,20 do p[#p+1]=x; p[#p+1]=100 end
    assert(s:addStroke(p,#p/2,4,1))
    assert(s:addStroke({330,25,330,175},2,12,3))
    assert(s:flush())
    local before = pixel(s,330,100)
    local canvas = BB.new(940,210,BB.TYPE_BB8); canvas:fill(BB.COLOR_WHITE)
    canvas:blitFrom(s:cache():buffer(),0,0,0,0,460,200)
    for _,x in ipairs({110,230}) do
        local ctx = s:beginErase()
        check(s:eraseAt(x,100,18,ctx) ~= nil, "erase admitted")
        s:endErase(ctx)
        check(pixel(s,330,100) == before, "distant crossing unchanged")
    end
    canvas:blitFrom(s:cache():buffer(),480,0,0,0,460,200)
    canvas:writePNG(out .. "/" .. kind .. "-erase-order.png"); canvas:free()
    check(s:flush(), "edits flush"); check(s:close(), "session closes"); repo:close()
    repo = assert(Repo.open{path=path,wal=false})
    s = openSurface(repo,page)
    check(pixel(s,330,100)==before and before==204, "crossing survives database reopen")
    check(s:close(), "reopened session closes"); repo:close()
    print("PASS native migration and erase order: " .. kind)
end

local Style = require("ink_style")
local Raster = require("ink_export_raster")
local function equalPixels(a,b,why)
    local differences = 0
    for y=0,a:getHeight()-1 do for x=0,a:getWidth()-1 do
        if a:getPixel(x,y) ~= b:getPixel(x,y) then differences=differences+1 end
    end end
    check(differences==0, why .. " (" .. differences .. " differing pixels)")
end
for _,kind in ipairs({"canvas","notebook"}) do
    local Repo = require("ink_" .. kind .. "_repository")
    local repo = assert(Repo.open{path=out .. "/" .. kind .. ".sqlite3",wal=false})
    local page={id=1,notebook_id=1,logical_w=460,logical_h=200}
    local overlay=kind=="canvas"
    for _,style in ipairs({Style.ROUND,Style.HIGHLIGHTER,Style.TEXTURED}) do
        for _,m in ipairs(assert(repo:listStrokes(1))) do assert(repo:deleteStroke(m.id)) end
        local s=openSurface(repo,page,overlay)
        local points={}
        for i=0,2399 do
            local j=i<=1199 and i or 2399-i
            points[#points+1]=30+j*400/1199;points[#points+1]=100
        end
        -- Canonical coordinates isolate raster fidelity from the unchanged
        -- uint16 codec's subpixel quantisation.
        points=assert(Codec.join(assert(Codec.encode(points,2400,460,200)),460,200))
        local cache=s:cache()
        local blank=cache:buffer():copy()
        local abandoned={}
        assert(cache:drawSegment(30,100,100,100,12,Style.colorFor(style,nil),style,abandoned))
        assert(cache:repair{min_x=30,min_y=100,max_x=100,max_y=100,width=12})
        equalPixels(blank,cache:buffer(),"aborting removes live modern ink")
        blank:free()
        local token={}
        for i=1,#points-2,2 do
            check(cache:drawSegment(points[i],points[i+1],points[i+2],points[i+3],12,
                Style.colorFor(style,nil),style,token)~=nil,"live modern segment")
        end
        local id=assert(s:addStroke(points,2400,12,style,{
            raster_cache=cache,raster_generation=cache.generation,live_raster_complete=true}))
        local live=cache:buffer():copy()
        -- Recreate an incomplete-raster save on a separate empty surface,
        -- so its fallback must compose exactly once, not darken the prefix.
        if style==Style.HIGHLIGHTER then
            check(s:undo(),"remove admitted highlighter for fallback check")
            assert(cache:drawSegment(points[1],points[2],points[201],points[202],12,
                Style.colorFor(style,nil),style,{}))
            assert(s:addStroke(points,2400,12,style,{
                raster_cache=cache,raster_generation=cache.generation-1,live_raster_complete=true}))
            equalPixels(live,cache:buffer(),"stale live token rebuilds alpha without darkening")
        end
        check(s:flush(),"modern stroke persisted")
        check(s:close(),"modern live cache released")
        s=openSurface(repo,page,overlay)
        equalPixels(live,s:cache():buffer(),"live equals chunked database replay, style "..style)
        live:free()
        if style==Style.HIGHLIGHTER then
            local px=s:cache():buffer():getPixel(330,100)
            check(overlay and px.alpha==51 or not overlay and px.a==204,"one coverage across chunks")
        end
        local before=pixel(s,330,100)
        local ctx=s:beginErase();check(s:eraseAt(110,100,18,ctx)~=nil,"modern stroke cut")
        s:endErase(ctx)
        check(pixel(s,330,100)==before,"cut does not shift distant grain/coverage")
        local repaired=s:cache():buffer():copy()
        check(s:flush(),"modern cut saved");check(s:close(),"cut cache released")
        s=openSurface(repo,page,overlay)
        equalPixels(repaired,s:cache():buffer(),"cut equals database replay")
        local sched=Support.newScheduler()
        local job=assert(Raster.open{repository=repo,surface=page,scale=1,
            composition=overlay and "overlay" or "opaque",
            schedule=function(fn) sched:schedule(fn) end})
        sched:drain();check(job:isReady(),"export raster ready")
        equalPixels(repaired,job:buffer(),"export equals repaired page")
        local stem=out .. "/" .. kind .. "-style-" .. style
        job:buffer():writePNG(stem .. ".png")
        -- Document exports compose the overlay against a page first. Use a
        -- synthetic page with black text here; the ReaderUI smoke covers PDF.
        local flat=BB.new(460,200,BB.TYPE_BB8);flat:fill(BB.COLOR_WHITE)
        if overlay then
            flat:paintRect(325,20,10,160,BB.COLOR_BLACK)
            flat:alphablitFrom(job:buffer())
        else flat:blitFrom(job:buffer()) end
        local Export=require("ink_export")
        check(Export.writeImage(flat,stem .. ".jpg","jpg",90),"native JPEG encoding")
        local f=assert(io.open(stem .. ".pdf","wb"))
        local pdf=assert(require("ink_export_pdf").new{write=function(bytes) return f:write(bytes) end})
        local bytes,w,h=Export.grayBytes(flat)
        check(pdf:addImagePage{gray=bytes,w=w,h=h,width_pt=460,height_pt=200},"PDF image accepted")
        check(pdf:finish(),"PDF complete");assert(f:close());flat:free()
        job:close();repaired:free();check(s:close(),"modern surface closes")
    end
    repo:close()
end
print(string.format("%d native stroke checks passed", passed))
