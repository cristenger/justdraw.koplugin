-- Native pixel checks; run with KOReader's LuaJIT from its build directory.
require("setupkoenv")
local here = debug.getinfo(1,"S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Brush = require("ink_brush")
local Render = require("ink_render")
local Style = require("ink_style")
local out = assert(arg[1], "output directory required")
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function buffer(w,h,alpha)
    local bb = BB.new(w,h,alpha and BB.TYPE_BB8A or BB.TYPE_BB8)
    if not alpha then bb:fill(BB.COLOR_WHITE) end
    return bb
end
local function gray(bb,x,y) return tonumber(bb:getPixel(x,y).a) end
local function same(a,b,label)
    local equal = true
    for y=0,a:getHeight()-1 do for x=0,a:getWidth()-1 do
        if a:getPixel(x,y) ~= b:getPixel(x,y) then equal=false end
    end end
    check(equal, label)
end

for _, width in ipairs({1,2,4,7,18}) do
    local a,b = buffer(160,120),buffer(160,120)
    check(Brush.segment(a,20,20,130,90,width,Style.ROUND), "round segment paints")
    check(Brush.segment(b,130,90,20,20,width,Style.ROUND), "reverse paints")
    same(a,b,"round nib is direction-independent")
    b:fill(BB.COLOR_WHITE)
    for i=0,9 do
        Brush.segment(b,20+11*i,20+7*i,31+11*i,27+7*i,width,Style.ROUND)
    end
    same(a,b,"subdivision preserves the capsule")
    a:free();b:free()
end
do
    local b = buffer(160,120)
    check(Brush.segment(b,20,20,20,20,1,Style.ROUND), "one-pixel tap visible")
    check(gray(b,20,20)==0, "tap hits its own pixel")
    check(not Brush.segment(b,0/0,0,10,10,4,Style.ROUND), "NaN rejected")
    check(not Brush.segment(b,0,0,1e308,1e308,4,Style.ROUND), "overflow rejected")
    check(Brush.segment(b,-1e9,60,1e9,60,4,Style.ROUND), "huge crossing bounded by viewport")
    check(gray(b,0,60)==0 and gray(b,159,60)==0, "crossing reaches both edges")
    local atlas=buffer(720,240)
    for i,w in ipairs({2,4,7,18}) do
        Brush.points(atlas,{30,40,160,40,160,85,230,85},4,1,0,(i-1)*45,w,Style.ROUND)
        Brush.segment(atlas,280,40+(i-1)*45,480,60+(i-1)*45,w,Style.ROUND)
        Brush.segment(atlas,560,40+(i-1)*45,560,40+(i-1)*45,w,Style.ROUND)
    end
    atlas:writePNG(out .. "/round-nibs.png")
    atlas:free();b:free()
end

-- Uniform alpha is coverage of a whole stroke, not each segment/stamp.
for _, alpha in ipairs({false,true}) do
    local a,b = buffer(180,120,alpha),buffer(180,120,alpha)
    local mask = BB.new(180,120,BB.TYPE_BB8)
    Brush.points(a,{20,60,160,60,20,60},3,1,0,0,18,Style.HIGHLIGHTER,mask)
    if alpha then
        check(a:getPixel(90,60).alpha==51 and gray(a,90,60)==0, "source alpha retained on transparent page")
        b:free(); b=buffer(180,120)
        b:paintRect(85,0,10,120,BB.COLOR_BLACK)
        b:alphablitFrom(a)
        check(gray(b,90,60)==0 and gray(b,60,60)==204, "PDF black preserved, paper tinted")
    else
        check(gray(a,90,60)==204, "retracing within one contact remains 20 percent")
    end
    mask:fill(BB.COLOR_BLACK)
    Brush.segment(a,90,20,90,100,18,Style.HIGHLIGHTER,mask)
    if alpha then check(a:getPixel(90,60).alpha==92, "different contacts accumulate alpha")
    else check(gray(a,90,60)==163, "different contacts accumulate on paper") end
    a:writePNG(out .. (alpha and "/highlight-alpha.png" or "/highlight-paper.png"))
    a:free();b:free();mask:free()
end

do
    local a,b=buffer(720,220),buffer(720,220)
    local p={30,40,220,40,220,90,30,90,30,150,380,150}
    Brush.points(a,p,6,1,0,0,18,Style.TEXTURED)
    Brush.points(b,p,6,1,0,0,18,Style.TEXTURED)
    same(a,b,"texture repeats exactly")
    -- Painting into a regional viewport retains the page's texture origin.
    local view=b:viewport(100,20,200,160)
    Render.safeRect(view,0,0,200,160,BB.COLOR_WHITE)
    Brush.points(view,p,6,1,-100,-20,18,Style.TEXTURED)
    same(a,b,"viewport repair preserves grain phase")
    Brush.points(a,{440,40,650,160},2,1,0,0,7,Style.TEXTURED)
    a:writePNG(out .. "/textured-graphite.png")
    a:free();b:free()
end

for _,alpha in ipairs({false,true}) do
    for _,vw in ipairs({1,20}) do
        local b=buffer(90,60,alpha)
        local view=b:viewport(30,20,vw,20)
        Render.segment(view,-50,10,70,10,4,BB.COLOR_BLACK)
        local outside=0
        for y=0,59 do for x=0,89 do
            if not (x>=30 and x<30+vw and y>=20 and y<40) then
                local p=b:getPixel(x,y)
                if alpha and p.alpha~=0 or not alpha and p.a~=255 then outside=outside+1 end
            end
        end end
        check(outside==0,"native legacy fill stays inside a narrow viewport")
        b:free()
    end
end
print(checks .. " native brush checks passed")
