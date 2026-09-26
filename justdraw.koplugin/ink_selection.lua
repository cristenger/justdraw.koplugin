--[[--
The lasso tool's controller: collect a path, resolve what it encloses, move,
copy, cut or delete it (ADR-55).

Independent of any surface. A notebook editor and a document sheet each hand it
a presenter -- how to paint, refresh and place a menu on *their* screen -- and
a way to reach the current `SurfaceSession`; everything that changes ink goes
through `SurfaceSession:replaceStrokes`, so every edit is one history entry
and all-or-nothing.

Three things shape it:

* **Nothing expensive under the pen.** The path is collected into a buffer
  sized before the contact; resolving the enclosed strokes, building the
  floating preview and committing a move all run as scheduled jobs that ask
  `can_work()` first and wait -- with a positive delay, never a zero-delay
  spin -- while any contact is still on the glass. `scheduleIn(0)` is not a
  promise that the pen has lifted (§D.8).
* **One job, cancellable.** Every job carries a token; changing tool, page,
  undoing, rotating, suspending, closing or a failed save bumps it, and a job
  whose token is stale, or whose surface is no longer the presenter's, does
  nothing. Resolving yields every few milliseconds or few thousand points.
* **Lifting is a mask, not a removal.** While a selection is dragged its
  originals are hidden from painting (`SurfaceSession:hideStrokes`) but keep
  their metadata, index entries and pending ids, so a COMMIT can re-key them
  and a rotation's rebuild still knows them. A cleared selection always puts
  the mask back before anything else.

States: idle → collecting → resolving → selected ⇄ dragging → pending →
selected; any of them can clear back to idle.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Codec = require("ink_canvas_codec")
local FloatLayer = require("ink_float_layer")
local Lasso = require("ink_lasso")
local Render = require("ink_render")
local logger = require("logger")
local _ = require("ink_i18n")

local Selection = {
    MAX_STROKES = 256,
    MAX_POINTS = 65536,
    --- Cooperative budgets per scheduled turn (initial design limits, to be
    --- confirmed on the Scribe; ADR-53).
    TURN_MS = 4,
    TURN_POINTS = 8192,
    --- Seconds between asks while a contact is still down.
    WAIT = 0.1,
    --- Frame padding around the selected ink, in millimetres.
    PAD_MM = 2,
    --- Minimum lasso size, millimetres; anything smaller is a tap.
    TAP_MM = 2,
    --- Distance between accepted path points, screen pixels.
    PATH_STEP_PX = 3,
    DASH_ON = 6,
    DASH_OFF = 4,
    FRAME_PX = 2,
}
Selection.__index = Selection

local floor = math.floor

local function monotonic()
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.now then return time.now() / time.s(1) end
    return os.clock()
end

--[[--
  opts.presenter  see the presenter contract in `Editor:selectionPresenter`
  opts.schedule   function(delay, fn)      UIManager:scheduleIn
  opts.unschedule function(fn)             UIManager:unschedule
  opts.can_work   function() -> boolean, false while any contact is down
  opts.clock      seconds, monotonic
  opts.clipboard  ink_clipboard, or nil (Copy/Cut disabled)
  opts.on_changed function(state) after every state change
]]
function Selection.new(opts)
    opts = opts or {}
    local self = setmetatable({
        presenter = assert(opts.presenter, "presenter"),
        schedule = assert(opts.schedule, "schedule"),
        unschedule = opts.unschedule or function() end,
        can_work = opts.can_work or function() return true end,
        clock = opts.clock or monotonic,
        clipboard = opts.clipboard,
        on_changed = opts.on_changed,
        --- The floating layer's transparent clear; injectable because the
        --- suite's fake buffer has no pixels (see Cache.clearTransparent).
        layer_clear = opts.layer_clear,
        turn_ms = opts.turn_ms or Selection.TURN_MS,
        turn_points = opts.turn_points or Selection.TURN_POINTS,
        max_strokes = opts.max_strokes or Selection.MAX_STROKES,
        max_points = opts.max_points or Selection.MAX_POINTS,
        state = "idle",
        -- Sized once for the controller's life: collecting writes into it.
        path = Lasso.newPath(Lasso.MAX_POINTS),
        job_token = 0,
        job_action = nil,
        identity = nil,
        items = nil,       -- selected strokes: key, version, base points...
        layer = nil,
        masked = false,
        committed_dx = 0, committed_dy = 0,
        drag_dx = 0, drag_dy = 0,
        start_x = 0, start_y = 0,
        box = nil,         -- selected ink's canvas box at offset 0
        menu_rect = nil,
        -- Reused on every drag sample: no allocation per move.
        rect_a = {}, rect_b = {},
    }, Selection)
    self.painter = {
        paintOverlay = function(_, bb, clip) return self:_paintOverlay(bb, clip) end,
        hasGrayInk = function() return self.state == "dragging" and self.layer ~= nil
            and self.layer:hasGrayInk() end,
    }
    return self
end

function Selection:_setState(state)
    self.state = state
    if self.on_changed then pcall(self.on_changed, state, self) end
end

function Selection:isActive()
    return self.state ~= "idle"
end

--- Whether a contact at this screen point belongs to the menu, not the pen.
function Selection:menuRect()
    return self.menu_rect
end

-- ------------------------------------------------------------ jobs

--[[--
Run `fn(token)` on a later turn once `can_work()` allows it. One job at a
time: arming a new one retires the previous. A job whose token went stale does
nothing, and an error inside one ends the selection visibly instead of
leaving it half-done.
]]
function Selection:_arm(fn)
    self:_cancelJob()
    local token = self.job_token
    local action
    self.job_step = fn
    action = function()
        if token ~= self.job_token or self.job_action ~= action then return end
        if not self.can_work() then
            -- Positive delay: re-running a due task at zero delay would spin
            -- the UI loop while the pen is still down.
            self.schedule(Selection.WAIT, action)
            return
        end
        if not self:_sameSurface() then
            self.job_action = nil
            self:clear("stale")
            return
        end
        local step = self.job_step
        self.job_step = nil
        if not step then return end
        local ok, err = pcall(step)
        if not ok then
            logger.err("JustDraw: selection job failed:", err)
            self.job_action = nil
            self:clear("error")
            self.presenter:notify(_("The selection could not be completed."))
        end
    end
    self.job_action = action
    self.schedule(0, action)
    return action
end

--- Continue the running job on a later turn. Same token: a tool change or a
--- page turn in between still cancels it.
function Selection:_yield(step)
    self.job_step = step
    if self.job_action then self.schedule(0, self.job_action) end
end

function Selection:_cancelJob()
    self.job_token = self.job_token + 1
    if self.job_action then self.unschedule(self.job_action) end
    self.job_action = nil
end

function Selection:_sameSurface()
    return self.identity ~= nil and self.presenter:identity() == self.identity
        and self.presenter:session() ~= nil
end

-- ------------------------------------------------------------ contacts

--[[--
A contact began at canvas (cx, cy). Returns true when the controller took it;
nil and a reason when it refuses, in which case the adapter keeps the contact
consumed until lift and draws nothing (§D.8).
]]
function Selection:contactBegin(cx, cy)
    local state = self.state
    if state == "resolving" or state == "pending" then return nil, "busy" end
    if state == "selected" then
        if self:_insideFrame(cx, cy) then return self:_beginDrag(cx, cy) end
        self:clear("new_lasso")
    end
    local session = self.presenter:session()
    local transform = self.presenter:transform()
    if not session or not transform or not session:hasHistory() then
        return nil, "unavailable"
    end
    self.identity = self.presenter:identity()
    self:_watchRebuilds(session)
    self.path:reset(Selection.PATH_STEP_PX / transform.scale)
    self.path:add(cx, cy)
    self.path_full = false
    self:_setState("collecting")
    return true
end

function Selection:contactMove(cx, cy)
    local state = self.state
    if state == "collecting" then
        local path = self.path
        local n = path.n
        local ok = path:add(cx, cy)
        if ok == nil then self.path_full = true; return true end
        if ok and n > 0 then
            local transform = self.presenter:transform()
            local x0, y0 = transform:toScreen(path.xy[n * 2 - 1], path.xy[n * 2])
            local x1, y1 = transform:toScreen(cx, cy)
            self.presenter:drawPath(x0, y0, x1, y1)
        end
        return true
    elseif state == "dragging" then
        return self:_moveDrag(cx, cy)
    end
    return true
end

--- The logical end of a contact (lift, or the pen left the paper).
function Selection:contactEnd()
    local state = self.state
    if state == "collecting" then
        return self:_finishPath()
    elseif state == "dragging" then
        self:_setState("pending")
        self:_arm(function() self:_commitMove() end)
        return true
    end
    return true
end

--- The contact was taken away (palm, suspend, a dialog): undo what it did.
function Selection:contactAbort()
    local state = self.state
    if state == "collecting" then
        self:_erasePath()
        self:_setState("idle")
    elseif state == "dragging" then
        self:_revertDrag()
    end
    return true
end

--[[--
Hear the surface's rebuilds -- rotation, paper, reload -- so the mask is put
back while the old raster still exists (§D.6.6). One subscription per
surface; a new surface drops the old one.
]]
function Selection:_watchRebuilds(session)
    if self.watched == session or type(session.onBeforeRebuild) ~= "function" then return end
    if self.unwatch then self.unwatch() end
    self.watched = session
    self.unwatch = session:onBeforeRebuild(function()
        if self.state ~= "idle" then self:clear("rebuild") end
    end)
end

-- ------------------------------------------------------------ lasso

function Selection:_pathScreenBox()
    local path = self.path
    if path.n == 0 then return nil end
    local transform = self.presenter:transform()
    if not transform then return nil end
    local x0, y0 = transform:toScreen(path.min_x, path.min_y)
    local x1, y1 = transform:toScreen(path.max_x, path.max_y)
    return x0 - 4, y0 - 4, x1 + 4, y1 + 4
end

function Selection:_erasePath()
    local x0, y0, x1, y1 = self:_pathScreenBox()
    if x0 then self.presenter:repaint(x0, y0, x1, y1) end
end

function Selection:_finishPath()
    local transform = self.presenter:transform()
    local tap = transform and self.path:isTap(self.presenter:mmToPixels(Selection.TAP_MM)
        / transform.scale)
    if not transform or tap then
        self:_erasePath()
        self:_setState("idle")
        return true
    end
    if self.path_full then
        self:_erasePath()
        self:_setState("idle")
        self.presenter:notify(_("That lasso was too long. Draw a shorter one."))
        return true
    end
    self:_setState("resolving")
    self:_arm(function() self:_resolveStart() end)
    return true
end

--[[--
Resolving, first turn: simplify the path (within one screen pixel, at most
256 vertices, or refuse) and open a bounded query over its box.
]]
function Selection:_resolveStart()
    local transform = self.presenter:transform()
    local path = self.path
    local poly, v = Lasso.simplify(path.xy, path.n, 1 / transform.scale, Lasso.MAX_VERTICES)
    if not poly then
        self:_erasePath()
        self:_setState("idle")
        self.presenter:notify(_("That lasso is too complex. Draw a simpler one."))
        return
    end
    local session = self.presenter:session()
    local min_x, min_y, max_x, max_y = Lasso.bounds(poly, v)
    local cursor, err = session:cache():openQuery(min_x, min_y, max_x, max_y)
    if not cursor then
        self:_erasePath()
        self:_setState("idle")
        logger.warn("JustDraw: lasso query failed:", err)
        return
    end
    self.resolve = {
        poly = poly, v = v, cursor = cursor, pending = {}, at = 1,
        min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y,
        items = {}, points = 0, step = 1 / transform.scale,
    }
    self:_resolveTurn()
end

--- One bounded turn of resolving. Yields by re-arming itself.
function Selection:_resolveTurn()
    local r = self.resolve
    local deadline = self.clock() + self.turn_ms / 1000
    local read = 0
    local session = self.presenter:session()
    local cache = session:cache()
    while true do
        if r.at > #r.pending then
            if r.cursor_done then break end
            r.pending, r.at = {}, 1
            local added, done = r.cursor:next(64, r.pending)
            if added == nil then
                self:_erasePath()
                self:_setState("idle")
                return
            end
            r.cursor_done = done
            if added == 0 and done then break end
        end
        local m = r.pending[r.at]
        r.at = r.at + 1
        local w = (tonumber(m.width) or 0) / 2
        if m.key and cache:metaById(m.id) == m
            and Lasso.boxesTouch(r.min_x, r.min_y, r.max_x, r.max_y,
                m.min_x - w, m.min_y - w, m.max_x + w, m.max_y + w) then
            local points, n = cache:readPoints(m)
            if not points then
                self:_erasePath()
                self:_setState("idle")
                self.presenter:notify(_("The selection could not be read."))
                return
            end
            read = read + n
            if Lasso.selects((Lasso.coverage(r.poly, r.v, points, n, r.step))) then
                r.points = r.points + n
                if #r.items + 1 > self.max_strokes or r.points > self.max_points then
                    self:_erasePath()
                    self:_setState("idle")
                    self.presenter:notify(_("Too much ink for one selection. Select less."))
                    return
                end
                r.items[#r.items + 1] = { meta = m, points = points, n = n }
            end
        end
        if self.clock() > deadline or read >= self.turn_points then
            return self:_yield(function() self:_resolveTurn() end)
        end
    end
    r.cursor:close()
    self:_resolveFinish(r.items)
end

function Selection:_resolveFinish(found)
    self.resolve = nil
    if #found == 0 then
        self:_erasePath()
        self:_setState("idle")
        return
    end
    local session = self.presenter:session()
    local surface = session:surface()
    local transform = self.presenter:transform()
    local items, strokes = {}, {}
    local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #found do
        local f = found[i]
        local m = f.meta
        -- The base is what the store holds: every later move is computed from
        -- it plus a total offset, so repeated drags never accumulate rounding.
        local base = Codec.snap(f.points, f.n, surface.logical_w, surface.logical_h,
            { clamp = true })
        items[i] = {
            key = m.key, version = m.version or 1, points = base, n = f.n,
            width = m.width, tool = m.tool, paint_seq = m.paint_seq or m.seq,
        }
        strokes[i] = { points = base, n = f.n, width = m.width, tool = m.tool,
            paint_seq = m.paint_seq or m.seq }
        for p = 1, f.n do
            local x, y = base[p * 2 - 1], base[p * 2]
            if x < min_x then min_x = x end
            if x > max_x then max_x = x end
            if y < min_y then min_y = y end
            if y > max_y then max_y = y end
        end
    end
    local layer, err = FloatLayer.new{
        transform = transform, strokes = strokes, clear = self.layer_clear,
        budget = function(bytes) return self.presenter:budget(bytes) end,
        max_pixels = FloatLayer.MAX_PREVIEW_PIXELS,
    }
    if not layer then
        self:_erasePath()
        self:_setState("idle")
        self.presenter:notify(err == "preview_too_large"
            and _("That selection is too large to move. Select less.")
            or _("The selection could not be prepared."))
        return
    end
    self.items = items
    self.layer = layer
    self.box = { min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y }
    self.committed_dx, self.committed_dy = 0, 0
    self.drag_dx, self.drag_dy = 0, 0
    self:_erasePath()
    self.presenter:setPainter(self.painter)
    -- Lift the originals off the page raster now, in this job, and let the
    -- layer draw them where they are: the pen-down that starts a drag then
    -- changes a state and an offset, and replays nothing (§D.3).
    local hidden = session:hideStrokes(self:_keys())
    if hidden then
        self.masked = true
        if type(hidden) == "table" then self.presenter:presentCacheBox(hidden) end
    end
    self:_setState("selected")
    self:_showMenu()
    self:_repaintFrame()
end

-- ------------------------------------------------------------ frame, menu

--- The frame's canvas box at the current offset, padded.
function Selection:_frameCanvas()
    local b, transform = self.box, self.presenter:transform()
    local pad = self.presenter:mmToPixels(Selection.PAD_MM) / transform.scale
    local dx, dy = self.drag_dx, self.drag_dy
    return b.min_x + dx - pad, b.min_y + dy - pad, b.max_x + dx + pad, b.max_y + dy + pad
end

function Selection:_frameScreen(out)
    local transform = self.presenter:transform()
    local x0, y0, x1, y1 = self:_frameCanvas()
    local sx0, sy0 = transform:toScreen(x0, y0)
    local sx1, sy1 = transform:toScreen(x1, y1)
    out.x, out.y = floor(sx0), floor(sy0)
    out.w, out.h = floor(sx1 + 0.5) - out.x, floor(sy1 + 0.5) - out.y
    return out
end

function Selection:_insideFrame(cx, cy)
    if not self.box then return false end
    local x0, y0, x1, y1 = self:_frameCanvas()
    return cx >= x0 and cx <= x1 and cy >= y0 and cy <= y1
end

function Selection:_repaintFrame()
    local r = self:_frameScreen(self.rect_a)
    local pad = Selection.FRAME_PX + 1
    self.presenter:repaint(r.x - pad, r.y - pad, r.x + r.w + pad, r.y + r.h + pad)
end

function Selection:_showMenu()
    local frame = self:_frameScreen({})
    local busy = function() return self.state ~= "selected" end
    local has_clipboard = self.clipboard ~= nil
    self.menu_rect = self.presenter:showMenu(frame, {
        { id = "copy", text = _("Copy"), enabled = has_clipboard,
            callback = function() if not busy() then self:copy() end end },
        { id = "cut", text = _("Cut"), enabled = has_clipboard,
            callback = function() if not busy() then self:cut() end end },
        { id = "delete", text = _("Delete"), enabled = true,
            callback = function() if not busy() then self:delete() end end },
        { id = "close", text = "✕", help = _("Close"), enabled = true,
            callback = function() if not busy() then self:clear("closed") end end },
    })
    local r = self.menu_rect
    if r then self.presenter:repaint(r.x, r.y, r.x + r.w, r.y + r.h) end
end

function Selection:_hideMenu()
    if not self.menu_rect then return end
    local r = self.menu_rect
    self.menu_rect = nil
    self.presenter:hideMenu()
    self.presenter:repaint(r.x, r.y, r.x + r.w, r.y + r.h)
end

--- One dash of the frame, clipped. A plain function: repaints run per drag
--- sample and must not build a closure each time.
local function dash(bb, clip, x, y, w, h)
    local x0, y0 = math.max(x, clip.x), math.max(y, clip.y)
    local x1, y1 = math.min(x + w, clip.x + clip.w), math.min(y + h, clip.y + clip.h)
    if x1 > x0 and y1 > y0 then bb:paintRect(x0, y0, x1 - x0, y1 - y0, Blitbuffer.COLOR_BLACK) end
end

--[[--
Draw the floating preview and the dashed frame, never outside `clip`. The
frame's dashes are painted rectangle by rectangle: nothing is allocated.
]]
function Selection:_paintOverlay(bb, clip)
    if not self.box then return end
    -- The layer stands in for the originals whenever they are masked.
    if (self.masked or self.state == "dragging") and self.layer then
        self.layer:paintInto(bb, clip, self.rect_b)
    end
    local r = self:_frameScreen(self.rect_a)
    local t = Selection.FRAME_PX
    local on, off = Selection.DASH_ON, Selection.DASH_OFF
    local x = r.x
    while x < r.x + r.w do
        local w = math.min(on, r.x + r.w - x)
        dash(bb, clip, x, r.y, w, t)
        dash(bb, clip, x, r.y + r.h - t, w, t)
        x = x + on + off
    end
    local y = r.y
    while y < r.y + r.h do
        local h = math.min(on, r.y + r.h - y)
        dash(bb, clip, r.x, y, t, h)
        dash(bb, clip, r.x + r.w - t, y, t, h)
        y = y + on + off
    end
    if self.menu_rect then self.presenter:paintMenu(bb, clip) end
end

-- ------------------------------------------------------------ moving

function Selection:_beginDrag(cx, cy)
    local session = self.presenter:session()
    if not session or not self:_sameSurface() then
        self:clear("stale")
        return nil, "stale"
    end
    local box
    if not self.masked then
        -- Only when masking at resolve time failed: the old path, a repair
        -- under the pen, rather than no move at all.
        box = session:hideStrokes(self:_keys())
        if not box then
            return nil, "unavailable"
        end
        self.masked = true
    end
    self.start_x, self.start_y = cx, cy
    self:_hideMenu()
    self:_setState("dragging")
    if type(box) == "table" then self.presenter:presentCacheBox(box) end
    return true
end

--- Clamp an offset so every selected point stays on the page.
function Selection:_clamp(dx, dy)
    local surface = self.presenter:session():surface()
    local b = self.box
    if b.min_x + dx < 0 then dx = -b.min_x end
    if b.max_x + dx > surface.logical_w then dx = surface.logical_w - b.max_x end
    if b.min_y + dy < 0 then dy = -b.min_y end
    if b.max_y + dy > surface.logical_h then dy = surface.logical_h - b.max_y end
    return dx, dy
end

function Selection:_moveDrag(cx, cy)
    local dx, dy = self:_clamp(self.committed_dx + cx - self.start_x,
        self.committed_dy + cy - self.start_y)
    if dx == self.drag_dx and dy == self.drag_dy then return true end
    local old = self:_frameScreen(self.rect_a)
    local ox0, oy0, ox1, oy1 = old.x, old.y, old.x + old.w, old.y + old.h
    self.drag_dx, self.drag_dy = dx, dy
    self.layer:setOffset(dx, dy)
    local new = self:_frameScreen(self.rect_a)
    local pad = Selection.FRAME_PX + 1
    self.presenter:repaint(math.min(ox0, new.x) - pad, math.min(oy0, new.y) - pad,
        math.max(ox1, new.x + new.w) + pad, math.max(oy1, new.y + new.h) + pad)
    return true
end

function Selection:_keys()
    local keys = {}
    for i = 1, #self.items do keys[i] = self.items[i].key end
    return keys
end

function Selection:_unmask(repaint)
    if not self.masked then return end
    self.masked = false
    local session = self.presenter:session()
    if not session then return end
    local box = session:showStrokes(self:_keys())
    if repaint and type(box) == "table" then self.presenter:presentCacheBox(box) end
end

--- Put a drag back where it started, originals visible.
function Selection:_revertDrag()
    local old = self:_frameScreen(self.rect_a)
    local pad = Selection.FRAME_PX + 1
    local ox0, oy0, ox1, oy1 = old.x - pad, old.y - pad, old.x + old.w + pad, old.y + old.h + pad
    self.drag_dx, self.drag_dy = self.committed_dx, self.committed_dy
    if self.layer then self.layer:setOffset(self.drag_dx, self.drag_dy) end
    self:_setState("selected")
    -- The originals stay masked while selected: the layer draws them.
    self.presenter:repaint(ox0, oy0, ox1, oy1)
    self:_showMenu()
    self:_repaintFrame()
end

--- Points of every selected stroke at offset (dx, dy), snapped once.
function Selection:_specsAt(dx, dy, bump)
    local surface = self.presenter:session():surface()
    local specs = {}
    for i = 1, #self.items do
        local it = self.items[i]
        local moved = {}
        for p = 1, it.n do
            moved[p * 2 - 1] = it.points[p * 2 - 1] + dx
            moved[p * 2] = it.points[p * 2] + dy
        end
        local snapped, err = Codec.snap(moved, it.n, surface.logical_w, surface.logical_h)
        if not snapped then return nil, err end
        specs[i] = {
            key = it.key, version = it.version + (bump and 1 or 0),
            points = snapped, n = it.n, width = it.width, tool = it.tool,
            paint_seq = it.paint_seq,
        }
    end
    return specs
end

local function samePoints(a, b)
    for i = 1, #a do
        local pa, pb = a[i].points, b[i].points
        for p = 1, a[i].n * 2 do
            if pa[p] ~= pb[p] then return false end
        end
    end
    return true
end

--[[--
Commit a finished drag (deferred, `can_work()`). A drag that quantises to no
change removes the mask without a history entry; otherwise the strokes are
replaced by moved versions with the same keys and paint order, as one entry.
]]
function Selection:_commitMove()
    local specs, err = self:_specsAt(self.drag_dx, self.drag_dy, true)
    local current = specs and self:_specsAt(self.committed_dx, self.committed_dy, false)
    if not specs or not current then
        self:_revertDrag()
        logger.warn("JustDraw: move refused:", err)
        return
    end
    if samePoints(specs, current) then
        self:_revertDrag()
        return
    end
    local session = self.presenter:session()
    local keys, versions = self:_keys(), {}
    for i = 1, #self.items do versions[self.items[i].key] = self.items[i].version end
    local opts = { label = "move", expect_versions = versions }
    local room, room_err = session:ensureCapacity(keys, specs, opts)
    local result, replace_err
    if room then result, replace_err = session:replaceStrokes(keys, specs, opts) end
    if not result then
        self:_revertDrag()
        logger.warn("JustDraw: move refused:", room_err or replace_err)
        self.presenter:notify(_("The selection could not be moved. Try again."))
        return
    end
    -- The removed originals took their mask with them; the moved strokes
    -- are masked again here, in this job, so the next drag starts clean.
    self.masked = false
    for i = 1, #self.items do self.items[i].version = self.items[i].version + 1 end
    self.committed_dx, self.committed_dy = self.drag_dx, self.drag_dy
    self:_setState("selected")
    local hidden = not result.repaint_error and session:hideStrokes(keys)
    if hidden then self.masked = true end
    if result.box then self.presenter:presentCacheBox(result.box) end
    if type(hidden) == "table" then self.presenter:presentCacheBox(hidden) end
    if result.repaint_error then
        self:clear("repaint_failed")
        return
    end
    self:_showMenu()
    self:_repaintFrame()
end

-- ------------------------------------------------------------ actions

--- A caller-owned payload of the selection at its current place.
function Selection:_payload()
    local specs = self:_specsAt(self.committed_dx, self.committed_dy, false)
    if not specs then return nil end
    return specs
end

function Selection:copy()
    if self.state ~= "selected" or not self.clipboard then return nil, "unavailable" end
    local transform = self.presenter:transform()
    local ok, err = self.clipboard.set(self:_payload(), { scale = transform.scale })
    if not ok then
        self.presenter:notify(_("The selection could not be copied."))
        return nil, err
    end
    self.presenter:notify(_("Copied"))
    return true
end

--- Remove the selection, recording one entry. `prepared` (a clipboard
--- payload) is published only once the removal is accepted, so a refused cut
--- leaves the previous clipboard alone.
function Selection:_removeSelected(label, prepared)
    self:_setState("pending")
    self:_arm(function()
        local session = self.presenter:session()
        local keys, versions = self:_keys(), {}
        for i = 1, #self.items do versions[self.items[i].key] = self.items[i].version end
        local opts = { label = label, expect_versions = versions }
        local room, room_err = session:ensureCapacity(keys, {}, opts)
        local result, err
        if room then result, err = session:replaceStrokes(keys, {}, opts) end
        if not result then
            self:_setState("selected")
            logger.warn("JustDraw: selection removal refused:", room_err or err)
            self.presenter:notify(_("The selection could not be removed. Try again."))
            return
        end
        if prepared then self.clipboard.publish(prepared) end
        self.masked = false
        self.items = {}
        if result.box then self.presenter:presentCacheBox(result.box) end
        self:clear(label)
    end)
    return true
end

function Selection:delete()
    if self.state ~= "selected" then return nil, "unavailable" end
    return self:_removeSelected("delete")
end

function Selection:cut()
    if self.state ~= "selected" or not self.clipboard then return nil, "unavailable" end
    local transform = self.presenter:transform()
    local prepared, err = self.clipboard.prepare(self:_payload(), { scale = transform.scale })
    if not prepared then
        self.presenter:notify(_("The selection could not be copied."))
        return nil, err
    end
    return self:_removeSelected("cut", prepared)
end

-- ------------------------------------------------------------ ending

--[[--
End whatever is in progress (§D.6.6). `reason` "rebuild" is special: the
raster is about to be replaced, so the mask is dropped without repairing an
old raster; "close" repaints nothing at all.
]]
function Selection:clear(reason)
    local was = self.state
    self:_cancelJob()
    if self.resolve and self.resolve.cursor then self.resolve.cursor:close() end
    self.resolve = nil
    local repaint = reason ~= "close" and reason ~= "rebuild"
    if self.masked then
        if reason == "rebuild" then
            local session = self.presenter:session()
            local cache = session and session:cache()
            if cache then cache:clearHidden() end
            self.masked = false
        else
            self:_unmask(repaint)
        end
    end
    local frame
    if self.box and repaint then frame = self:_frameScreen({}) end
    if self.menu_rect then
        if repaint then self:_hideMenu() else self.presenter:hideMenu(); self.menu_rect = nil end
    end
    if was == "collecting" and repaint then self:_erasePath() end
    if self.layer then self.layer:free() end
    self.layer = nil
    self.items = nil
    self.box = nil
    self.identity = nil
    self.presenter:setPainter(nil)
    if frame then
        local pad = Selection.FRAME_PX + 1
        self.presenter:repaint(frame.x - pad, frame.y - pad,
            frame.x + frame.w + pad, frame.y + frame.h + pad)
    end
    if was ~= "idle" then self:_setState("idle") end
    return true
end

--- The pen that drew the lasso path, in screen pixels.
Selection.renderPath = function(bb, x0, y0, x1, y1, color)
    return Render.segment(bb, x0, y0, x1, y1, 2, color)
end

return Selection
