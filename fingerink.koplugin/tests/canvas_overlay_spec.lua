--[[--
The canvas overlay: one window, three things inside it.

The single-window shape is the load-bearing decision. UIManager offers an input
event to the topmost non-toast widget and stops there; it does not walk down
the stack when that widget declines. A sheet and a toolbar as two ordinary
windows would therefore be two things competing to be on top, with the loser
deaf. So the sheet, the resize handle and the toolbar are children of one
window, painted in one order and hit-tested in the other, and everything the
overlay does not want is handed to the reader explicitly.

That last part is what buys back touch navigation: with the sheet open, a
finger outside it still turns pages. Under the old rule drawing suppressed
every gesture on the screen and Stop was the only way out.
]]

return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support
    local Overlay = require("ink_canvas_overlay")
    local Cache = require("ink_canvas_cache")
    local Transform = require("ink_canvas_transform")

    local Screen = env.Device.screen
    local SW, SH = Screen.w, Screen.h

    local CANVAS = { id = 1, logical_w = SW, logical_h = SH }

    local function gesture(x, y, name)
        return {
            handler = "onGesture",
            args = { { ges = name or "tap", pos = { x = x, y = y } } },
        }
    end

    local function positionless(name)
        return { handler = "onGesture", args = { { ges = name or "multiswipe" } } }
    end

    --- A plugin stand-in: the toolbar's four callbacks and the two flags its
    --- labels read.
    local function stubPlugin()
        local p = { drawing = true, eraser = false, calls = {} }
        function p:setDrawing(on) self.calls[#self.calls + 1] = "draw" ; self.drawing = on end
        function p:setEraser(on) self.calls[#self.calls + 1] = "eraser" ; self.eraser = on end
        function p:onFingerInkUndo() self.calls[#self.calls + 1] = "undo" end
        function p:setBarShown() self.calls[#self.calls + 1] = "hide" end
        return p
    end

    --- A reader window under the overlay, recording what reaches it.
    local function reader()
        local seen = {}
        local w = {
            handleEvent = function(_, event)
                seen[#seen + 1] = event.handler
                return true
            end,
            seen = seen,
        }
        return w
    end

    local function fixture(opts)
        opts = opts or {}
        env.UIManager._window_stack = {}
        env.UIManager.dirty = {}
        if not opts.keep_settings then _G.G_reader_settings.data = {} end

        local below = reader()
        env.UIManager:show(below)

        local store = support.newCanvasStore({ CANVAS })
        for _, s in ipairs(opts.strokes or {}) do store:putStroke(CANVAS.id, s) end
        local sched = support.newScheduler()
        local cache = Cache.new{
            repository = store,
            canvas = CANVAS,
            transform = Transform.new{
                logical_w = SW, logical_h = SH,
                screen_w = SW, screen_h = SH, sheet_top = 0,
            },
            schedule = function(fn) sched:schedule(fn) end,
        }
        cache:open()
        sched:drain()

        local plugin = stubPlugin()
        local overlay = Overlay:new{
            plugin = plugin,
            cache = cache,
            canvas = CANVAS,
            -- nil on purpose when the test does not care: init then falls
            -- back to the saved preference, which is what most of these check.
            height_pct = opts.height_pct,
        }
        env.UIManager:show(overlay)
        return overlay, below, plugin, cache, store
    end

    local function sheetTop(overlay)
        return overlay.transform.sheet_top
    end

    -- =================================================================
    t:describe("ink_canvas_overlay / one window")

    t:case("the overlay is the only window FingerInk puts up", function()
        local overlay = fixture()
        local ours = 0
        for _, entry in ipairs(env.UIManager._window_stack) do
            if entry.widget == overlay or entry.widget == overlay.bar then
                ours = ours + 1
            end
        end
        t:eq(ours, 1, "the toolbar is a child, not a second window")
    end)

    t:case("the embedded toolbar knows it is embedded", function()
        local overlay = fixture()
        t:eq(overlay.bar.embedded, true, "so it does not try to forward or suppress")
    end)

    t:case("the toolbar is offered input before the sheet", function()
        local overlay = fixture()
        local d = overlay.bar.dimen
        local consumed = overlay:handleEvent(gesture(d.x + 2, d.y + 2))
        t:eq(consumed, true, "the bar took it")
        t:eq(overlay.dragging, false, "and the overlay never saw it as a sheet gesture")
    end)

    -- =================================================================
    t:describe("ink_canvas_overlay / painting")

    t:case("the sheet is painted, then the canvas, then the toolbar", function()
        local overlay, _, _, cache = fixture{ height_pct = 70 }
        local bb = support.newBlitbuffer(SW, SH)
        overlay:paintTo(bb, 0, 0)
        t:check(#bb.rects > 0, "the sheet was filled")
        t:eq(#bb.blits, 1, "and the canvas blitted, not replayed")
        t:eq(bb.blits[1].src, cache:buffer(), "from the cache")
    end)

    t:case("the sheet covers its whole width, letterbox margins included", function()
        local overlay = fixture()
        local bb = support.newBlitbuffer(SW, SH)
        overlay:paintTo(bb, 0, 0)
        local first = bb.rects[1]
        t:eq(first.x, 0, "from the left edge")
        t:eq(first.w, SW, "to the right one")
        t:eq(first.y, sheetTop(overlay), "starting at the sheet top")
    end)

    t:case("nothing is painted above the sheet except the toolbar", function()
        local overlay = fixture()
        local bb = support.newBlitbuffer(SW, SH)
        overlay:paintTo(bb, 0, 0)
        local top, bar = sheetTop(overlay), overlay.bar.dimen
        local strays = 0
        for _, r in ipairs(bb.writes) do
            local in_sheet = r.y >= top
            local in_bar = r.x >= bar.x and r.y >= bar.y
                and r.x + r.w <= bar.x + bar.w and r.y + r.h <= bar.y + bar.h
            if not in_sheet and not in_bar then strays = strays + 1 end
        end
        t:eq(strays, 0, "the reader's text above the sheet is left alone")
    end)

    t:case("the dirty region covers the sheet and the toolbar", function()
        local overlay = fixture()
        local d, bar = overlay.dimen, overlay.bar.dimen
        t:check(d.y <= sheetTop(overlay), "reaches the sheet")
        t:check(d.y <= bar.y, "and up to the toolbar")
        t:check(d.x + d.w >= bar.x + bar.w, "including its far edge")
    end)

    -- =================================================================
    t:describe("ink_canvas_overlay / input routing")

    t:case("a tap on the sheet is swallowed", function()
        local overlay, below = fixture{ height_pct = 70 }
        t:eq(overlay:handleEvent(gesture(100, sheetTop(overlay) + 50)), true, "consumed")
        t:eq(#below.seen, 0, "and the reader never saw it")
    end)

    t:case("a tap above the sheet turns the page", function()
        -- The whole point of confining the drawing surface: with the canvas
        -- open, reading still works.
        local overlay, below = fixture{ height_pct = 40 }
        t:eq(overlay:handleEvent(gesture(100, 10)), true, "handled by the reader")
        t:eq(below.seen[1], "onGesture", "which is what got it")
    end)

    t:case("a tap on a toolbar button never reaches the reader", function()
        local overlay, below = fixture()
        local d = overlay.bar.dimen
        overlay:handleEvent(gesture(d.x + 5, d.y + 5))
        t:eq(#below.seen, 0, "consumed above")
    end)

    t:case("a tap in the toolbar's gaps is swallowed, not forwarded", function()
        -- Border and padding are not buttons, but a page turn under the
        -- toolbar would be worse than nothing happening.
        local overlay, below = fixture()
        local d = overlay.bar.dimen
        overlay:handleEvent(gesture(d.x + d.w - 1, d.y + d.h - 1))
        t:eq(#below.seen, 0, "nothing got through")
    end)

    t:case("a gesture with no position is swallowed", function()
        local overlay, below = fixture()
        t:eq(overlay:handleEvent(positionless()), true, "consumed")
        t:eq(#below.seen, 0, "an unattributable gesture is not handed on mid-canvas")
    end)

    t:case("a key press still reaches the reader", function()
        local overlay, below = fixture()
        overlay:handleEvent({ handler = "onKeyPress", args = {} })
        t:eq(below.seen[1], "onKeyPress", "page-turn buttons keep working")
    end)

    t:case("a dialog opened above the overlay takes the input instead", function()
        local overlay = fixture()
        local dialog = reader()
        env.UIManager:show(dialog)
        -- UIManager offers the topmost window first, and that is now the dialog.
        env.UIManager:sendEvent(gesture(100, 100))
        t:eq(dialog.seen[1], "onGesture", "the dialog is reachable")
    end)

    -- =================================================================
    t:describe("ink_canvas_overlay / height")

    t:case("the three stops are 40, 70 and 100 per cent", function()
        local overlay = fixture{ height_pct = 40 }
        t:eq(sheetTop(overlay), math.floor(SH * 0.6), "40% shows the bottom 40%")
        overlay:setHeight(70)
        t:eq(sheetTop(overlay), math.floor(SH * 0.3), "70%")
        overlay:setHeight(100)
        t:eq(sheetTop(overlay), 0, "and 100% is the whole screen")
    end)

    t:case("tapping the handle cycles through the stops", function()
        local overlay = fixture{ height_pct = 40 }
        local function tapHandle()
            local h = overlay:handleRect()
            overlay:handleEvent(gesture(h.x + h.w / 2, h.y + h.h / 2))
        end
        tapHandle()
        t:eq(overlay.height_pct, 70, "40 to 70")
        tapHandle()
        t:eq(overlay.height_pct, 100, "70 to 100")
        tapHandle()
        t:eq(overlay.height_pct, 40, "and back round")
    end)

    t:case("the height is kept as a preference, not per canvas", function()
        local overlay = fixture{ height_pct = 40 }
        overlay:setHeight(100)
        t:eq(_G.G_reader_settings.data.fingerink_canvas_height, 100, "saved")
        local again = fixture{ keep_settings = true }
        t:eq(again.height_pct, 100, "and used next time")
    end)

    t:case("a drag up snaps to the next stop on release", function()
        local overlay = fixture{ height_pct = 40 }
        local h = overlay:handleRect()
        local y = h.y + h.h / 2
        overlay:handleEvent(gesture(100, y, "hold"))
        overlay:handleEvent(gesture(100, y - SH * 0.3, "hold_pan"))
        overlay:handleEvent(gesture(100, y - SH * 0.3, "hold_release"))
        t:eq(overlay.height_pct, 70, "the nearest stop to where it was let go")
    end)

    t:case("a drag down snaps the other way", function()
        local overlay = fixture{ height_pct = 100 }
        local h = overlay:handleRect()
        local y = h.y + h.h / 2
        overlay:handleEvent(gesture(100, y, "hold"))
        overlay:handleEvent(gesture(100, y + SH * 0.3, "hold_release"))
        t:eq(overlay.height_pct, 70, "smaller")
    end)

    t:case("nothing is repainted during the drag itself", function()
        -- KOReader does not repaint a MovableContainer while it is being
        -- dragged either: continuous full refreshes on e-ink are worse than
        -- no feedback. The magnetic stops are what compensate.
        local overlay = fixture{ height_pct = 40 }
        local h = overlay:handleRect()
        local y = h.y + h.h / 2
        overlay:handleEvent(gesture(100, y, "hold"))
        env.UIManager.dirty = {}
        for i = 1, 5 do
            overlay:handleEvent(gesture(100, y - i * 10, "hold_pan"))
        end
        t:eq(#env.UIManager.dirty, 0, "not one refresh mid-drag")
        overlay:handleEvent(gesture(100, y - SH * 0.3, "hold_release"))
        t:eq(overlay.height_pct, 70, "the release is what applies the height")
        t:check(#env.UIManager.dirty > 0, "and it refreshes then, not before")
    end)

    t:case("a drag that goes nowhere leaves the height alone", function()
        local overlay = fixture{ height_pct = 70 }
        local h = overlay:handleRect()
        local y = h.y + h.h / 2
        overlay:handleEvent(gesture(100, y, "hold"))
        overlay:handleEvent(gesture(100, y + 2, "hold_release"))
        t:eq(overlay.height_pct, 70, "unchanged")
    end)

    t:case("the toolbar is reachable at every height", function()
        for _, pct in ipairs({ 40, 70, 100 }) do
            local overlay, below = fixture{ height_pct = pct }
            local d = overlay.bar.dimen
            overlay:handleEvent(gesture(d.x + 5, d.y + 5))
            t:eq(#below.seen, 0, "the bar took the tap at " .. pct .. "%")
        end
    end)

    t:case("the canvas follows the height without being rebuilt", function()
        local overlay, _, _, cache, store = fixture{
            height_pct = 40, strokes = { { width = 4, tool = 1, points = { 10, 10, 20, 20 }, n = 2 } },
        }
        local bb, reads = cache:buffer(), store.calls.stroke_read
        overlay:setHeight(100)
        t:eq(cache:buffer(), bb, "the same raster")
        t:eq(store.calls.stroke_read, reads, "not one stroke decoded again")
        t:eq(cache.transform.sheet_top, 0, "but placed where the sheet now is")
    end)

    -- =================================================================
    t:describe("ink_canvas_overlay / geometry changes")

    t:case("a rotation rebuilds the transform and the toolbar", function()
        local overlay = fixture()
        local before_bar = overlay.bar
        Screen.w, Screen.h = SH, SW
        overlay:onScreenResize()
        t:eq(overlay.transform.screen_w, SH, "the transform follows the screen")
        t:check(overlay.bar ~= before_bar, "and the toolbar is rebuilt for it")
        Screen.w, Screen.h = SW, SH
    end)

    t:case("a rotation is passed on to the raster cache", function()
        local overlay, _, _, cache = fixture()
        Screen.w, Screen.h = SH, SW
        overlay:onScreenResize()
        t:eq(cache.transform, overlay.transform, "one transform, shared")
        Screen.w, Screen.h = SW, SH
    end)
end
