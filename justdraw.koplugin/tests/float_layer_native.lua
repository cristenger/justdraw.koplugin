--[[--
The floating layer against KOReader's real blitter (§D.3, Task 3.1).

The suite's fake buffer records calls and has no pixels, so it cannot say
whether a transparent layer really leaves the page under it untouched, whether
two highlighter fragments of one stroke share one coverage (no darker seam
where they overlap), or how much memory a full-page preview takes. This does.

    cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/float_layer_native.lua [out-dir]

Prints FLOAT_LAYER_NATIVE_OK and exits 0 when every check passes.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/tests/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local FloatLayer = require("ink_float_layer")
local Paper = require("ink_paper")
local Style = require("ink_style")
local Transform = require("ink_canvas_transform")

local out = arg[1] or os.getenv("TMPDIR") or "/tmp"
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function gray(bb, x, y) return tonumber(bb:getPixel(x, y):getColor8().a) end

local W, H = 600, 800
local page = assert(Transform.new{
    logical_w = W, logical_h = H,
    fit_rect = { x = 0, y = 0, w = W, h = H }, clip_rect = { x = 0, y = 0, w = W, h = H },
})

local function ruledPage()
    local bb = BB.new(W, H, BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    Paper.paint(bb, "ruled", 1, 0, 0, W, H, BB.COLOR_GRAY)
    return bb
end

-- 1. A transparent layer leaves the ruled page untouched away from its ink,
--    and black ink covers what is under it.
do
    local bb = ruledPage()
    local before = bb:copy()
    local layer = assert(FloatLayer.new{ transform = page, strokes = {
        { points = { 100, 200, 400, 200 }, n = 2, width = 6, tool = Style.PEN },
    } })
    check(layer.cache:buffer():getType() == BB.TYPE_BB8A, "the layer is a BB8A raster")
    check(layer:paintInto(bb, { x = 0, y = 0, w = W, h = H }), "painted")
    check(gray(bb, 250, 200) < 0x40, "the pen's ink is on the page")
    local rect = layer:screenRect({})
    local untouched = true
    for y = rect.y, rect.y + rect.h - 1 do
        for x = rect.x, rect.x + rect.w - 1 do
            if math.abs(y - 200) > 6 and bb:getPixel(x, y) ~= before:getPixel(x, y) then
                untouched = false
            end
        end
    end
    check(untouched, "transparent pixels of the layer leave the ruling as it was")
    layer:setOffset(0, 100)
    local moved = before:copy()
    layer:paintInto(moved, { x = 0, y = 0, w = W, h = H })
    check(gray(moved, 250, 300) < 0x40 and gray(moved, 250, 200) == gray(before, 250, 200),
        "moving the layer moves the ink, not the page")
    moved:writePNG(out .. "/float-layer-pen.png")
    layer:free(); layer:free()
    check(layer.cache == nil, "free is idempotent")
    bb:free(); before:free(); moved:free()
end

-- 2. Two fragments of one highlighter stroke share one coverage: the overlap
--    is exactly as dark as either fragment alone.
do
    local bb = BB.new(W, H, BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    local layer = assert(FloatLayer.new{ transform = page, strokes = {
        { points = { 100, 300, 300, 300 }, n = 2, width = 30, tool = Style.HIGHLIGHTER, paint_seq = 5 },
        { points = { 250, 300, 450, 300 }, n = 2, width = 30, tool = Style.HIGHLIGHTER, paint_seq = 5 },
    } })
    check(layer:hasGrayInk(), "a highlighter asks for a gray refresh")
    layer:paintInto(bb, { x = 0, y = 0, w = W, h = H })
    local single, overlap = gray(bb, 150, 300), gray(bb, 275, 300)
    check(single < 0xFF, "the highlighter shows")
    check(overlap == single, ("one coverage: overlap %d == single %d"):format(overlap, single))
    bb:writePNG(out .. "/float-layer-highlighter.png")
    layer:free(); bb:free()
end

-- 3. Memory: a whole-page selection at Kindle Scribe size, measured.
do
    local SW, SH = 1860, 2122
    local scribe = assert(Transform.new{
        logical_w = SW, logical_h = SH,
        fit_rect = { x = 0, y = 0, w = SW, h = SH }, clip_rect = { x = 0, y = 0, w = SW, h = SH },
    })
    local strokes = {}
    for i = 0, 40 do
        strokes[#strokes + 1] = { points = { 10, 10 + i * 50, SW - 10, 10 + i * 50 },
            n = 2, width = 4, tool = Style.PEN }
    end
    collectgarbage("collect")
    local layer = assert(FloatLayer.new{ transform = scribe, strokes = strokes })
    local rect = layer:screenRect({})
    print(("MEASURED full-page preview %dx%d = %d bytes raster+coverage (layer.bytes %d)")
        :format(rect.w, rect.h, rect.w * rect.h * 3, layer.bytes))
    check(layer.bytes == rect.w * rect.h * 3, "the checked budget is the allocated size")
    local refused, err = FloatLayer.new{ transform = scribe, strokes = strokes,
        max_pixels = rect.w * rect.h - 1 }
    check(refused == nil and err == "preview_too_large", "one pixel over the ceiling is refused")
    layer:free()
end

print("FLOAT_LAYER_NATIVE_OK checks=" .. checks)
os.exit(0)
