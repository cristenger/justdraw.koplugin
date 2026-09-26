return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local FloatLayer = require("ink_float_layer")
    local Transform = require("ink_canvas_transform")
    local Style = require("ink_style")

    local function page(scale, x, y)
        scale = scale or 1
        return Transform.new{
            logical_w = 1000, logical_h = 1400,
            fit_rect = { x = x or 0, y = y or 100, w = 1000 * scale, h = 1400 * scale },
            clip_rect = { x = x or 0, y = y or 100, w = 1000 * scale, h = 1400 * scale },
        }
    end

    local function bar(x, y, len, width, tool, paint_seq)
        return { points = { x, y, x + len, y }, n = 2, width = width or 4,
            tool = tool or Style.PEN, paint_seq = paint_seq }
    end

    t:describe("ink_float_layer / building")

    t:case("a layer is exactly the payload's padded box, and owns its points", function()
        local src = bar(100, 200, 300)
        local layer = assert(FloatLayer.new{ transform = page(), strokes = { src },
            clear = support.recordingClear() })
        local rect = layer:screenRect({})
        t:eq(rect.w, 300 + 4 + 2 * FloatLayer.PAD_PX, "width: length + nib + pads")
        t:eq(rect.x, 100 - 2 - FloatLayer.PAD_PX, "placed where the payload is")
        t:eq(rect.y, 100 + 200 - 2 - FloatLayer.PAD_PX, "below the page's own origin")
        src.points[1] = 999
        local m = layer.cache:strokes()[1]
        t:check(m.points[1] ~= 999 - layer.box.min_x, "mutating the source reaches nothing")
        layer:free()
    end)

    t:case("refusals happen before any buffer exists", function()
        local made = 0
        local BB = require("ffi/blitbuffer")
        local real = BB.new
        BB.new = function(...) made = made + 1; return real(...) end
        local cases = {
            { "empty", {} },
            { "NaN", { { points = { 0 / 0, 1 }, n = 1, width = 4, tool = 1 } } },
            { "count past points", { { points = { 1, 1 }, n = 2, width = 4, tool = 1 } } },
        }
        for _, c in ipairs(cases) do
            local layer, err = FloatLayer.new{ transform = page(), strokes = c[2] }
            t:eq(layer, nil, c[1] .. " refused")
            t:check(err ~= nil, c[1] .. " named")
        end
        local layer, err = FloatLayer.new{ transform = page(), strokes = { bar(0, 0, 900) },
            max_pixels = 100 }
        t:eq(layer, nil, "too many pixels refused")
        t:eq(err, "preview_too_large", "as too large")
        local asked
        layer, err = FloatLayer.new{ transform = page(), strokes = { bar(0, 0, 100) },
            budget = function(bytes) asked = bytes; return nil, "memory_budget" end }
        t:eq(err, "memory_budget", "the owner's budget can refuse")
        t:check(asked and asked > 0, "and was asked for the real byte count")
        t:eq(made, 0, "no buffer was allocated for any refusal")
        BB.new = real
    end)

    t:case("a highlighter's fragments are painted once, in one pass", function()
        -- The fake buffer has no pixels for the brush; count the paints
        -- instead. tests/float_layer_native.lua checks the coverage itself
        -- against KOReader's real blitter.
        local Cache = require("ink_canvas_cache")
        local real = Cache._paintStroke
        local paints = {}
        Cache._paintStroke = function(self, m, points, n, target, ...)
            paints[#paints + 1] = m.paint_seq
            if Style.isModern(m.tool) then
                if Style.isGray(m.tool) then self.gray_ink = true end
                if m.tool == Style.HIGHLIGHTER then self.translucent_ink = true end
                return true
            end
            return real(self, m, points, n, target, ...)
        end
        local clears = support.recordingClear()
        local ok, layer = pcall(FloatLayer.new, { transform = page(), clear = clears,
            strokes = {
                bar(100, 100, 50, 12, Style.HIGHLIGHTER, 7),
                bar(160, 100, 50, 12, Style.HIGHLIGHTER, 7),
                bar(100, 140, 50, 4, Style.PEN, 8),
            } })
        Cache._paintStroke = real
        t:check(ok and layer, "built")
        t:eq(#paints, 3, "each stroke painted exactly once")
        t:eq(table.concat(paints, ","), "7,7,8", "in visual order")
        t:eq(layer:hasGrayInk(), true, "a translucent payload asks for a gray refresh")
        layer:free()
        local plain = assert(FloatLayer.new{ transform = page(), clear = clears,
            strokes = { bar(1, 1, 5) } })
        t:eq(plain:hasGrayInk(), false, "black ink needs no gray pass")
        plain:free()
        local gray = assert(FloatLayer.new{ transform = page(), clear = clears,
            strokes = { bar(1, 1, 5, 4, Style.GRAPHITE) } })
        t:eq(gray:hasGrayInk(), true, "graphite does")
        gray:free()
    end)

    t:describe("ink_float_layer / moving and painting")

    t:case("moving changes two numbers; painting is one clipped alpha blit", function()
        local layer = assert(FloatLayer.new{ transform = page(), strokes = { bar(100, 200, 300) },
            clear = support.recordingClear() })
        local dest = support.newBlitbuffer(1000, 1600)
        local rect = {}
        layer:setOffset(50, -20)
        layer:screenRect(rect)
        t:eq(rect.x, 100 - 2 - FloatLayer.PAD_PX + 50, "x follows the offset")
        t:eq(rect.y, 300 - 2 - FloatLayer.PAD_PX - 20, "y follows the offset")
        t:eq(layer:paintInto(dest, { x = 0, y = 100, w = 1000, h = 1400 }), true, "painted")
        t:eq(#dest.blits, 1, "one blit")
        t:eq(dest.blits[1].alpha, true, "composed, not copied over the page")
        layer:setOffset(-1000, 0)
        t:eq(layer:paintInto(dest, { x = 0, y = 100, w = 1000, h = 1400 }), false,
            "nothing painted when the layer is entirely off the paper")
        layer:setOffset(-150, 0)
        layer:paintInto(dest, { x = 0, y = 100, w = 1000, h = 1400 })
        local b = dest.blits[#dest.blits]
        t:eq(b.dest_x, 0, "clipped at the paper's left edge")
        t:check(b.offs_x > 0, "from inside the layer")
        layer:free()
    end)

    t:case("a scaled page with its own origin places the layer in screen pixels", function()
        local layer = assert(FloatLayer.new{ transform = page(0.5, 30, 40),
            strokes = { bar(100, 100, 200) }, clear = support.recordingClear() })
        local rect = layer:screenRect({})
        t:eq(rect.w, math.ceil((200 + 4 + 2 * 2 * 2) * 0.5), "half-size raster")
        t:check(math.abs(rect.x - (30 + (100 - 2 - 4) * 0.5)) <= 1, "x at the page's scale and origin")
        local screen = {}
        layer:setOffset(10.3, 0)
        layer:screenRect(screen)
        t:eq(screen.x, math.floor(30 + (100 - 2 - 4 + 10.3) * 0.5 + 0.5), "fractional offsets round")
        layer:free()
    end)

    t:case("free is idempotent and a freed layer paints nothing", function()
        local layer = assert(FloatLayer.new{ transform = page(), strokes = { bar(1, 1, 5) },
            clear = support.recordingClear() })
        local buffer = layer.cache:buffer()
        layer:free()
        layer:free()
        t:eq(buffer.freed, true, "the raster was released")
        t:eq(layer:paintInto(support.newBlitbuffer(100, 100)), false, "nothing to paint")
        t:eq(layer:hasGrayInk(), false, "no gray either")
    end)

    t:case("dragging allocates no table per sample", function()
        local layer = assert(FloatLayer.new{ transform = page(), strokes = { bar(100, 200, 300) },
            clear = support.recordingClear() })
        -- A destination that records nothing: the fake's own bookkeeping
        -- would allocate a table per blit and hide what the layer does.
        local calls = 0
        local dest = { alphablitFrom = function() calls = calls + 1 end }
        local rect = {}
        local function drag(n)
            for i = 1, n do
                layer:setOffset(i % 50, i % 30)
                layer:screenRect(rect)
                layer:paintInto(dest, nil, rect)
            end
        end
        -- Warm up first: the JIT's own trace buffers count against the heap
        -- while it compiles the loop, and they are not the layer's.
        drag(4000)
        calls = 0
        layer:paintInto(dest, nil, rect)
        collectgarbage("collect")
        collectgarbage("stop")
        local before = collectgarbage("count")
        drag(2000)
        local grown = collectgarbage("count") - before
        collectgarbage("restart")
        t:check(grown < 1, "2000 moves grew the heap by " .. string.format("%.2f", grown) .. " KiB")
        t:eq(calls, 2001, "every move painted")
        layer:free()
    end)

    t:case("one editing budget for preview, page raster, histories and clipboard", function()
        local FloatLayer = require("ink_float_layer")
        local Clipboard = require("ink_clipboard")
        local History = require("ink_edit_history")
        History.resetSharedPool()
        Clipboard.clear()
        local cache = { buffer = function() return {
            getWidth = function() return 2000 end, getHeight = function() return 2000 end } end }
        t:eq(FloatLayer.editingBudget(1024 * 1024, cache), true, "a small preview fits")
        local room = FloatLayer.EDIT_BUDGET - 2000 * 2000 * 2
        t:eq(FloatLayer.editingBudget(room + 1, cache), nil, "the page raster counts")
        local pts = {}
        for i = 1, 60000 do pts[#pts + 1] = i % 100; pts[#pts + 1] = i % 90 end
        t:eq(Clipboard.set({ { points = pts, n = 60000, width = 4, tool = 1 } }, { scale = 1 }), true,
            "a large copy")
        t:check(Clipboard.retainedBytes() > 1024, "is counted")
        t:eq(FloatLayer.editingBudget(room - 1024, cache), nil, "and so does the clipboard")
        Clipboard.clear()
        t:eq(FloatLayer.editingBudget(room - 1024, cache), true, "which gives it back when cleared")
    end)
end
