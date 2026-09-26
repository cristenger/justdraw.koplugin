--[[--
Placing ink with the pen: Paste and Shapes (U-2, §D.8).

The reader chooses what to place -- the clipboard's content, or a shape from
the Shapes menu -- and then touches the page: the ink appears there, centred
on the pen, follows the pen while it stays down, and is written when it lifts.
There is no "hold still to turn a stroke into a shape": placing is the whole
gesture.

What makes that safe is the same discipline as the lasso's:

* **Prepared before the contact.** The payload is fetched, validated against
  the page and rasterised into a floating layer when the tool is chosen, not
  when the pen lands. The contact only changes an offset and repaints the
  union of where the layer was and is.
* **Committed after the contact.** Lifting leaves an intention; a job that
  asks `can_work()` turns it into one `replaceStrokes` with new keys and paint
  orders above the page's ink, recorded as one history entry. A refused
  commit keeps the tool usable and tells the reader.
* **Anchored, not synthetic.** The physical contact that positions the
  payload has already passed capture, palm rejection and geometry trust in
  the input adapter; only the resulting points skip the pen's stroke policy,
  because nothing about them came from a pen trace (ADR-22).

Pasting returns to the tool it interrupted after one accepted placement; a
shape tool stays until the reader leaves it.
]]

local Codec = require("ink_canvas_codec")
local FloatLayer = require("ink_float_layer")
local logger = require("logger")
local _ = require("ink_i18n")

local Placement = {
    WAIT = 0.1,
}
Placement.__index = Placement

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--[[--
  opts.presenter  the editor's presenter (see ink_selection)
  opts.kind       "paste" or "shape": the history label and the lifecycle
  opts.source     function(transform) -> payload | nil, reason. A payload is
                  { strokes = {{points, n, width, tool, group}}, w, h } in the
                  destination's canvas units, relative to its own corner
  opts.schedule, opts.unschedule, opts.can_work
  opts.on_committed function(kind) after an accepted placement
  opts.layer_clear  injectable transparent clear (tests)
]]
function Placement.new(opts)
    opts = opts or {}
    local self = setmetatable({
        presenter = assert(opts.presenter, "presenter"),
        kind = opts.kind or "paste",
        source = assert(opts.source, "source"),
        schedule = assert(opts.schedule, "schedule"),
        unschedule = opts.unschedule or function() end,
        can_work = opts.can_work or function() return true end,
        on_committed = opts.on_committed,
        layer_clear = opts.layer_clear,
        state = "idle",
        payload = nil,
        layer = nil,
        identity = nil,
        dx = 0, dy = 0,
        job_token = 0,
        job_action = nil,
        rect_a = {},
    }, Placement)
    self.painter = {
        paintOverlay = function(_, bb, clip)
            if (self.state == "placing" or self.state == "pending") and self.layer then
                self.layer:paintInto(bb, clip, self.rect_a)
            end
        end,
        hasGrayInk = function()
            return self.layer ~= nil and self.state ~= "ready" and self.layer:hasGrayInk()
        end,
    }
    return self
end

function Placement:isActive()
    return self.state ~= "idle"
end

--[[--
Fetch the payload and build its preview, outside any contact. Returns true or
nil and a reason; on a refusal nothing is left prepared, and the reader is
told why (a payload larger than the page is refused, never shrunk).
]]
function Placement:prepare()
    self:cancel("prepare")
    local session = self.presenter:session()
    local transform = self.presenter:transform()
    if not session or not transform or not session:hasHistory() then
        return nil, "unavailable"
    end
    local payload, err = self.source(transform)
    if not payload then return nil, err end
    local surface = session:surface()
    if not finite(payload.w) or not finite(payload.h)
        or payload.w > surface.logical_w or payload.h > surface.logical_h then
        self.presenter:notify(_("That is too large for this page."))
        return nil, "too_large"
    end
    local layer, layer_err = FloatLayer.new{
        transform = transform, strokes = payload.strokes, clear = self.layer_clear,
        budget = function(bytes) return self.presenter:budget(bytes) end,
    }
    if not layer then
        self.presenter:notify(_("That could not be prepared for placing."))
        return nil, layer_err
    end
    self.payload = payload
    self.layer = layer
    self.identity = self.presenter:identity()
    self.state = "ready"
    self.presenter:setPainter(self.painter)
    return true
end

--- Clamp the payload's corner so all of it stays on the page.
function Placement:_clamp(x, y)
    local surface = self.presenter:session():surface()
    local maxx, maxy = surface.logical_w - self.payload.w, surface.logical_h - self.payload.h
    if x < 0 then x = 0 elseif x > maxx then x = maxx end
    if y < 0 then y = 0 elseif y > maxy then y = maxy end
    return x, y
end

function Placement:_moveTo(cx, cy)
    local layer = self.layer
    local old = layer:screenRect(self.rect_a)
    local ox0, oy0, ox1, oy1 = old.x, old.y, old.x + old.w, old.y + old.h
    local was_visible = self.visible
    self.dx, self.dy = self:_clamp(cx - self.payload.w / 2, cy - self.payload.h / 2)
    layer:setOffset(self.dx, self.dy)
    local new = layer:screenRect(self.rect_a)
    if was_visible then
        self.presenter:repaint(math.min(ox0, new.x), math.min(oy0, new.y),
            math.max(ox1, new.x + new.w), math.max(oy1, new.y + new.h))
    else
        self.presenter:repaint(new.x, new.y, new.x + new.w, new.y + new.h)
    end
    self.visible = true
end

--[[--
The pen touched the page at canvas (cx, cy). Refused -- and the contact kept
consumed until its lift by the adapter -- while a commit is pending or the
preview belongs to a page or transform that is no longer on screen.
]]
function Placement:contactBegin(cx, cy)
    if self.state == "pending" then return nil, "busy" end
    if self.state ~= "ready" or self.identity ~= self.presenter:identity() then
        -- Stale or never prepared: prepare after this contact, not under it.
        self:_arm(function() self:prepare() end)
        return nil, "not_ready"
    end
    self.state = "placing"
    self.visible = false
    self:_moveTo(cx, cy)
    return true
end

function Placement:contactMove(cx, cy)
    if self.state ~= "placing" then return true end
    self:_moveTo(cx, cy)
    return true
end

function Placement:contactEnd()
    if self.state ~= "placing" then return true end
    self.state = "pending"
    self:_arm(function() self:_commit() end)
    return true
end

function Placement:contactAbort()
    if self.state ~= "placing" then return true end
    self:_hide()
    self.state = "ready"
    return true
end

function Placement:_hide()
    if not self.visible or not self.layer then return end
    self.visible = false
    local r = self.layer:screenRect(self.rect_a)
    local x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
    -- Painted as "ready": the painter no longer draws the layer.
    local state = self.state
    self.state = "ready"
    self.presenter:repaint(x0, y0, x1, y1)
    self.state = state
end

--- Specs for the payload at the current offset, with paint orders placed
--- above every stroke on the page and groups kept together (§D.7).
function Placement:_specs(session)
    local surface = session:surface()
    local base = session:nextSeq()
    local first_of_group = {}
    local specs = {}
    for i = 1, #self.payload.strokes do
        local s = self.payload.strokes[i]
        local group = s.group or i
        if not first_of_group[group] then first_of_group[group] = i end
        local moved = {}
        for p = 1, s.n do
            moved[p * 2 - 1] = s.points[p * 2 - 1] + self.dx
            moved[p * 2] = s.points[p * 2] + self.dy
        end
        local snapped, err = Codec.snap(moved, s.n, surface.logical_w, surface.logical_h)
        if not snapped then return nil, err end
        specs[i] = { points = snapped, n = s.n, width = s.width, tool = s.tool,
            paint_seq = base + first_of_group[group] - 1 }
    end
    return specs
end

function Placement:_commit()
    local session = self.presenter:session()
    local specs, err = self:_specs(session)
    local result, replace_err
    if specs then
        local opts = { label = self.kind }
        local room, room_err = session:ensureCapacity({}, specs, opts)
        if room then result, replace_err = session:replaceStrokes({}, specs, opts)
        else replace_err = room_err end
    end
    if not result then
        logger.warn("JustDraw: placement refused:", err or replace_err)
        self:_hide()
        self.state = "ready"
        self.presenter:notify(_("That could not be placed. Try again."))
        return
    end
    self.visible = false
    self.state = "ready"
    if result.box then self.presenter:presentCacheBox(result.box) end
    local r = self.layer:screenRect(self.rect_a)
    self.presenter:repaint(r.x, r.y, r.x + r.w, r.y + r.h)
    if self.on_committed then self.on_committed(self.kind, result) end
end

-- ------------------------------------------------------------ jobs

function Placement:_arm(fn)
    self.job_token = self.job_token + 1
    if self.job_action then self.unschedule(self.job_action) end
    local token = self.job_token
    local action
    action = function()
        if token ~= self.job_token or self.job_action ~= action then return end
        if not self.can_work() then
            self.schedule(Placement.WAIT, action)
            return
        end
        self.job_action = nil
        local ok, err = pcall(fn)
        if not ok then
            logger.err("JustDraw: placement job failed:", err)
            self:cancel("error")
        end
    end
    self.job_action = action
    self.schedule(0, action)
end

--- Drop the preview and any pending job. Safe any number of times.
function Placement:cancel(reason)
    self.job_token = self.job_token + 1
    if self.job_action then self.unschedule(self.job_action) end
    self.job_action = nil
    if self.layer then
        if reason ~= "close" and reason ~= "rebuild" then self:_hide() end
        self.layer:free()
    end
    self.layer = nil
    self.payload = nil
    self.visible = false
    if self.state ~= "idle" and self.presenter.setPainter then
        self.presenter:setPainter(nil)
    end
    self.state = "idle"
    return true
end

-- The controller interface the input adapter expects.
Placement.clear = Placement.cancel

return Placement
