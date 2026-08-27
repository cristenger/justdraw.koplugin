--[[--
Who owns each contact, decided once per contact and not revisited.

The failure this prevents is a contact changing hands mid-sequence. Give a slot
back to GestureDetector part-way through and it opens a fresh contact and emits
a spurious tap on the lift; take one away part-way through and it strands a
contact that never sees its lift, leaving a pending hold timer that blocks the
slot until the next `dropContacts()`. So a contact is classified on the first
frame that carries real coordinates, and crossing a border afterwards changes
nothing: a stroke dragged onto the toolbar does not press a button, and a tap
that started on a button does not become a stroke.

Classification order is dialog, toolbar, resize handle, canvas, then the
reader's text. The toolbar's position in that order is not a detail: it is what
keeps Stop pressable with a pen resting on the page, which is the only way out
of a drawing session.

One deliberate exception to the latch: a finger already on the page when the
pen lands is cancelled, because a resting hand turning the page mid-stroke is
exactly what the stylus route exists to prevent. The caller is told which slots
those were so it can drop their contacts -- timers included -- rather than
leaving them to fire later. Fingers on the toolbar are never cancelled.

No widgets, no persistence, no KOReader. Geometry arrives as an injected
function, which is what makes every one of these rules testable as a rule.
]]

local Router = {}
Router.__index = Router

--[[--
  opts.backend      "stylus" or "finger"
  opts.regions      function(x, y) -> "bar" | "handle" | "canvas" | "reader"
  opts.dialogOnTop  function() -> boolean
]]
function Router.new(opts)
    return setmetatable({
        backend = opts.backend or "finger",
        regions = opts.regions,
        dialogOnTop = opts.dialogOnTop or function() return false end,

        touch = {},        -- [slot] = destination
        n_touch = 0,
        pen = nil,         -- destination, once classified
        pen_down = false,  -- the pen is in contact, classified or not
        cancelled = {},
    }, Router)
end

--- Swapping routes mid-sequence tears capture down inside a live contact, so
--- every latch goes with the route rather than surviving into the new one.
function Router:setBackend(backend)
    if backend == self.backend then return end
    self.backend = backend
    self:reset()
end

function Router:reset()
    self.touch = {}
    self.n_touch = 0
    self.pen = nil
    self.pen_down = false
    self.cancelled = {}
end

function Router:_classify(x, y)
    if self.dialogOnTop() then return "dialog" end
    return self.regions(x, y)
end

-- --------------------------------------------------------------------- pen

--[[--
A pen frame. Returns the latched destination, or nil while the contact has
arrived but its position has not.

A contact-down frame that carried only BTN_TOUCH presents the *previous*
sequence's coordinates, so classifying from them would put this stroke wherever
the last one ended. The caller filters those out and passes nil; the contact is
still recorded as down, because the hand is already on the page by then and a
finger arriving in that window is no less of a palm.
]]
function Router:penContact(x, y)
    self.pen_down = true
    if self.pen then return self.pen end
    if x == nil or y == nil then return nil end

    self.pen = self:_classify(x, y)
    self:_cancelRestingFingers()
    return self.pen
end

function Router:penUp()
    self.pen = nil
    self.pen_down = false
end

--- Whether the pen's slot must be kept from GestureDetector. True over the
--- canvas and over the text; false on the toolbar, the handle and a dialog,
--- which all need their taps.
function Router:penDominates()
    local d = self.pen
    return d ~= nil and d ~= "dialog" and d ~= "bar" and d ~= "handle"
end

--- Whether the pen is drawing. The text is dominated but is not a drawing
--- surface -- v1 does not put ink over the book.
function Router:penDraws()
    return self.pen == "canvas"
end


-- ------------------------------------------------------------------- touch

--[[--
A touch frame for one slot. Returns the latched destination, or nil while the
contact has arrived without a position.
]]
function Router:touchContact(slot, x, y)
    local latched = self.touch[slot]
    if latched then return latched end
    if x == nil or y == nil then return nil end

    local dest = self:_classify(x, y)
    -- The toolbar, the handle and a dialog are decided already and are never
    -- downgraded: everything below depends on the toolbar staying reachable.
    if dest == "canvas" or dest == "reader" then
        if self.pen_down then
            dest = "palm"
        elseif dest == "canvas" and self.backend == "stylus" then
            -- Blunt on purpose. There is no tool-type data that would tell a
            -- palm from a finger, so on the pen's route neither draws.
            dest = "palm"
        end
    end

    self.touch[slot] = dest
    self.n_touch = self.n_touch + 1
    return dest
end

function Router:touchUp(slot)
    if self.touch[slot] == nil then return end
    self.touch[slot] = nil
    self.n_touch = self.n_touch - 1
    if self.n_touch < 0 then self.n_touch = 0 end
end

function Router:destinationOf(slot)
    return self.touch[slot]
end

function Router:touchCount()
    return self.n_touch
end

--- This contact reaches nothing at all.
function Router:suppresses(slot)
    return self.touch[slot] == "palm"
end

--- This contact belongs to the book underneath.
function Router:forwards(slot)
    return self.touch[slot] == "reader"
end

--- This contact draws, which only ever happens on the finger route.
function Router:draws(slot)
    return self.touch[slot] == "canvas"
end

--[[--
Slots cancelled by the pen landing, cleared as they are handed over.

The caller drops each one's contact with `getContact` and `dropContact` so its
pending hold and double-tap timers go with it. Doing that per slot rather than
globally is what keeps a finger on the toolbar untouched.
]]
function Router:takeCancelled()
    local out = self.cancelled
    self.cancelled = {}
    return out
end

function Router:_cancelRestingFingers()
    for slot, dest in pairs(self.touch) do
        if dest == "canvas" or dest == "reader" then
            self.touch[slot] = "palm"
            self.cancelled[#self.cancelled + 1] = slot
        end
    end
end

return Router
