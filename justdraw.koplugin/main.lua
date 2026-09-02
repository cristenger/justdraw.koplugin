--[[--
JustDraw — draw on book pages with a finger.

The side toolbar is the control surface: it is a normal widget sitting above
ReaderUI, and the capture handler passes through any contact that starts inside
it, so Draw/Stop stays reachable even while every other single-finger touch is
being swallowed. Drawing can never be on without the toolbar visible.

Two input backends share that toolbar. `finger` is the legacy route: one
contact draws, two pass through. `stylus` uses KOReader's stylus callback for
the pen and suppresses every remaining touch, because the callback on its own
only hides the pen from gesture detection and would leave a palm free to turn
pages. See ADR-11 and ADR-12.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Version = require("version")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local CanvasSession = require("ink_canvas_session")
local Capture = require("ink_capture")
local Compat = require("ink_compat")
local DocumentInkSession = require("ink_document_ink_session")
local Export = require("ink_export")
local ExportController = require("ink_document_export_controller")
local InputController = require("ink_input_controller")
local InkBar = require("ink_bar")
local NotebookController = require("ink_notebook_controller")
local NotebookInput = require("ink_notebook_input")
local PalmGate = require("ink_wacom_palm")
local Style = require("ink_style")
local StylusGeometry = require("ink_stylus_geometry")
local StylusSequence = require("ink_stylus_sequence")
local Legacy = require("ink_legacy_ink")
local Limits = require("ink_limits")
local Render = require("ink_render")
local Router = require("ink_contact_router")
local Stack = require("ink_stack")
local Store = require("ink_store")
local StylusTrace = require("ink_stylus_trace")

local Screen = Device.screen
local INK = Blitbuffer.COLOR_BLACK

local PEN_THIN, PEN_MEDIUM, PEN_THICK = 2, 4, 7
local ERASER_RADIUS = 18
local SUSPENDED = -1   -- draw_slot sentinel: ignore this contact until it lifts

local INPUT_MODES = { auto = true, stylus = true, finger = true }
local function updateLiveRasterToken(stroke, box, cache, generation)
    if stroke.live_raster_complete == false then return end
    if not box or not cache or generation == nil then
        stroke.live_raster_complete = false
        return
    end
    if stroke.raster_cache == nil then
        stroke.raster_cache = cache
        stroke.raster_generation = generation
        stroke.live_raster_complete = true
    elseif stroke.raster_cache ~= cache
        or stroke.raster_generation ~= generation then
        stroke.live_raster_complete = false
    end
end

-- The margin flag that says "there is a sheet anchored here". Drawn on the
-- edge opposite the toolbar, so the two never overlap.
local MARK_W, MARK_H = 6, 28

-- Reasons Capture can refuse, mapped to something a user can act on.
local INPUT_ERRORS = {
    no_stylus_api = _("Stylus input requires KOReader v2026.07 or newer"),
    stylus_callback_busy = _("Another plugin is already using stylus input"),
    no_gesture_detector = _("JustDraw: cannot hook touch input"),
    -- Not a refusal: drawing still starts, on the finger route. It is the
    -- answer to "my pen does nothing", given before the user has to ask.
    pen_unavailable = _("Pen input needs KOReader v2026.07 or newer. Drawing with finger."),
    no_input = _("JustDraw: cannot hook touch input"),
    -- A Wacom runtime that names no pen slot cannot tell the pen from a
    -- resting hand, so the pen route refuses rather than guessing per tool.
    wacom_pen_slot_missing = _("This device does not say which input slot its pen uses, so the pen route is unavailable."),
    already_installed = _("JustDraw: input is already captured"),
    handler_error = _("JustDraw: drawing stopped after an input error"),
}

--[[--
The three menu labels the refusal below has to walk, named once.

A sentence that tells a reader where to go and then names rows that are not
there is worse than no sentence, and the way that happens is a string written
from a plan and a menu built from the code. These are the labels the menu
itself is built from, so the two can no longer disagree: rename a row here and
the instruction renames with it.
]]
local MENU_JUSTDRAW = _("JustDraw")
local MENU_DRAWING_SHEET = _("Drawing sheet")
local MENU_OPEN_SHEET_HERE = _("Open sheet here")

--[[--
What "Start drawing" means in a reflowable book on a runtime that has sheets.

The sidecar is frozen (ADR-39), so there is nowhere for this contact to go and
the honest answer is not "no" but "here is where the ink lives now" -- said as
the path a reader taps, because the button they just pressed is the one that
refused. Said by `setDrawing` rather than at the first point, because the whole
refusal is that nothing starts: no capture, no toolbar forced on, no sheet
created behind the reader's back.
]]
local LEGACY_FROZEN_EPUB = T(
    _("Open a drawing sheet to draw in this book: %1 ▸ %2 ▸ %3."),
    MENU_JUSTDRAW, MENU_DRAWING_SHEET, MENU_OPEN_SHEET_HERE)

--[[--
Every reason page ink can refuse, turned into the one sentence for it.

The table itself lives in `ink_document_ink_session`, which is the module both
halves of the feature can see: the session says some of these to the reader
itself, and this is where the rest -- a refusal handed back to Draw, to a menu
or to a view event -- becomes something readable. Two tables meant two
sentences for `read_only` and two msgids for a translator to tell apart.
]]
local DOCUMENT_ERRORS = DocumentInkSession.MESSAGES

local function documentMessage(reason)
    return DOCUMENT_ERRORS[reason] or DocumentInkSession.FALLBACK_MESSAGE
end

--[[--
Copy one box of a raster onto the screen, composed if the raster is an overlay.

A page-ink raster is `TYPE_BB8A` and mostly transparent, and `blitFrom` copies
the alpha byte as if it were a pixel: every untouched pixel of the box would
land black, painting a rectangle over the book's own text. `alphablitFrom`
leaves alpha 0 alone and copies 0xFF, which is what composition means here
(ADR-38). One `isOverlay()` at the blit is what keeps both surfaces on one
path instead of two.
]]
local function blitCacheBox(cache, src, dest, dest_x, dest_y, src_x, src_y, w, h)
    if cache:isOverlay() then
        dest:alphablitFrom(src, dest_x, dest_y, src_x, src_y, w, h)
    else
        dest:blitFrom(src, dest_x, dest_y, src_x, src_y, w, h)
    end
end

--[[--
The half-open coverage InkRender reports, snapped outward and clipped to the
screen -- or nil when nothing is left of it.

Shared by the refresh and by the regional repaint because both would take a
NaN or an infinity straight into the eink update, and a box that has been
clipped to nothing must not become a full-screen one.
]]
local function screenBox(left, top, right, bottom)
    left, top, right, bottom = tonumber(left), tonumber(top),
        tonumber(right), tonumber(bottom)
    if not left or not top or not right or not bottom
        or left ~= left or top ~= top or right ~= right or bottom ~= bottom
        or left == math.huge or top == math.huge
        or right == math.huge or bottom == math.huge
        or left == -math.huge or top == -math.huge
        or right == -math.huge or bottom == -math.huge then
        return nil
    end
    local x, y = math.floor(left), math.floor(top)
    local edge_x, edge_y = math.ceil(right), math.ceil(bottom)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if edge_x > sw then edge_x = sw end
    if edge_y > sh then edge_y = sh end
    local w, h = edge_x - x, edge_y - y
    if w <= 0 or h <= 0 then return nil end
    return x, y, w, h
end

--[[--
Whether an eraser sample is far enough from the last one to be worth a sweep.

Shared by the sheet and the page, because it is the same bargain on both: an
eraser that cuts on every sample spends a whole contact re-cutting strokes it
already cut, and the reach in surface units grows as the surface shrinks.
]]
local function eraseSampleMoved(lx, ly, cx, cy, radius)
    if lx == nil then return true end
    local threshold = radius / 3
    if threshold < 1 then threshold = 1 end
    local dx, dy = cx - lx, cy - ly
    return dx * dx + dy * dy >= threshold * threshold
end

--[[--
Append one point to a live surface stroke and paint the segment into its
raster.

Shared by the sheet and the page: the duplicate-point test, the open-point
budget, the bounding box a repair will need and the live-raster token are the
same arithmetic on both, and only where the box then goes differs. Answers
`false` when the budget stopped the stroke -- the caller aborts -- and
otherwise `true` plus the dirty box, which is nil when nothing was painted.
]]
local function addSurfacePoint(s, cx, cy, cache, limit)
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == cx and py == cy then return true end
    if s.n >= limit then return false end

    s[i + 1] = cx
    s[i + 2] = cy
    s.n = s.n + 1
    if cx < s.min_x then s.min_x = cx elseif cx > s.max_x then s.max_x = cx end
    if cy < s.min_y then s.min_y = cy elseif cy > s.max_y then s.max_y = cy end

    if not cache then
        s.live_raster_complete = false
        return true
    end
    local box, raster_cache, raster_generation =
        cache:drawSegment(px, py, cx, cy, s.w, Style.colorFor(s.t, nil))
    updateLiveRasterToken(s, box, raster_cache, raster_generation)
    return true, box
end

--[[--
The two document surfaces, as the fields and methods their shared code needs.

`applySurfacePoint` and the four below it are one implementation with two
callers, and this is what tells the callers apart: which session holds the
ink, which fields carry the live stroke and the eraser, and how a dirty box
reaches the screen -- copied out of an opaque sheet, or repainted through the
view, because a transparent layer cannot un-paint one.

Constant tables of names, resolved at call time, so the indirection costs a
hash lookup and allocates nothing per point. Two copies of these hundred lines
is what they replace, and the copies had already drifted: only one of them
stopped the capture after a stroke the queue can never accept.
]]
local CANVAS_ROUTE = {
    session = "session",
    stroke = "canvas_stroke",
    erase_ctx = "canvas_erase_ctx",
    erase_x = "canvas_erase_x",
    erase_y = "canvas_erase_y",
    backpressure_flag = "canvas_backpressure_notified",
    start_stroke = "startCanvasStroke",
    end_stroke = "endCanvasStroke",
    end_erase = "endCanvasErase",
    abort = "abortCanvasStroke",
    -- The sheet is opaque: the raster is the truth, and both live ink and a
    -- repaired region are copied straight out of it.
    paint = "blitCanvasBox",
    repair_paint = "blitCanvasBox",
    backpressure = "notifyCanvasBackpressure",
    capture_stop = "_requestCanvasStrokeCaptureStop",
    log = "JustDraw: canvas stroke not recorded:",
}

local DOCUMENT_ROUTE = {
    session = "document_session",
    stroke = "document_stroke",
    erase_ctx = "document_erase_ctx",
    erase_x = "document_erase_x",
    erase_y = "document_erase_y",
    backpressure_flag = "document_backpressure_notified",
    start_stroke = "startDocumentStroke",
    end_stroke = "endDocumentStroke",
    end_erase = "endDocumentErase",
    abort = "abortDocumentStroke",
    -- The page is an overlay: live ink is composed onto the screen, but ink
    -- taken *off* it is still in the framebuffer, so a repair goes through
    -- the view (ADR-38).
    paint = "blitDocumentBox",
    repair_paint = "repaintDocumentBox",
    backpressure = "notifyDocumentBackpressure",
    capture_stop = "_requestDocumentCaptureStop",
    log = "JustDraw: page ink stroke not recorded:",
}

--- A live stroke in surface units. Widths are stored scaled down, so a stroke
--- keeps its weight relative to the surface at any zoom or on any screen.
local function newSurfaceStroke(pen_width, style, scale, cx, cy)
    style = Style.normalize(style)
    return {
        n = 1, w = pen_width * Style.widthScale(style) / scale,
        t = style,
        min_x = cx, min_y = cy, max_x = cx, max_y = cy,
        cx, cy,
    }
end

local function addSurfaceStrokePoint(self, route, cx, cy, tr)
    local session = self[route.session]
    local ok, box = addSurfacePoint(self[route.stroke], cx, cy,
        session and session:cache(),
        self.max_open_points or Limits.MAX_OPEN_POINTS)
    if not ok then
        -- See addPoint: the pen route's budget lives in InkStylusSequence.
        self[route.abort](self)
        self.draw_slot = SUSPENDED
        self:notifyStrokeBudget()
        return false
    end
    if box then self[route.paint](self, box, tr) end
    return true
end

local function endSurfaceErase(self, route)
    local session = self[route.session]
    if self[route.erase_ctx] and session then
        session:endErase(self[route.erase_ctx])
    end
    self[route.erase_ctx] = nil
    self[route.erase_x], self[route.erase_y] = nil, nil
end

local function eraseSurfaceAt(self, route, cx, cy, tr)
    local session = self[route.session]
    -- The eraser is a fixed size under the reader's hand, so its reach in
    -- surface units grows as the surface shrinks.
    local radius = ERASER_RADIUS / tr.scale
    if not self[route.erase_ctx] then
        self[route.erase_ctx] = session:beginErase()
    end
    if not eraseSampleMoved(self[route.erase_x], self[route.erase_y],
        cx, cy, radius) then
        return
    end
    self[route.erase_x], self[route.erase_y] = cx, cy
    self[route.repair_paint](self,
        session:eraseAt(cx, cy, radius, self[route.erase_ctx]), tr)
end

--[[--
One drawing point, in screen coordinates, on whichever surface is open.

Returns whether it inked, which is what the pen route's lift-recovery uses to
tell a stroke that produced nothing from one that was simply off the surface.
]]
local function applySurfacePoint(self, route, x, y, tool)
    local session = self[route.session]
    local cache = session and session:cache()
    if not cache or not cache:isReady() then return false end
    local tr = session:transform()
    if not tr or not tr:contains(x, y) then
        -- Off the surface. End the stroke at the edge rather than clamping it
        -- into a line along the margin.
        self[route.end_stroke](self)
        return false
    end
    local cx, cy = tr:toCanvas(x, y)
    if tool == Capture.TOOL_ERASER or self.eraser then
        eraseSurfaceAt(self, route, cx, cy, tr)
    else
        self[route.end_erase](self)
        if self[route.stroke] then
            if not addSurfaceStrokePoint(self, route, cx, cy, tr) then
                return false
            end
        else
            self[route.start_stroke](self, cx, cy, tr,
                self.contact_style or self:effectiveStyle(tool))
        end
    end
    return true
end

--[[--
Hand the finished stroke to its session, and take it back off the raster if
the session will not have it.

The live segments were painted before anything accepted them, so a refusal has
to rebuild the region from what was underneath rather than leave ink on screen
that is in no surface at all.
]]
local function endSurfaceStroke(self, route)
    self[route.end_erase](self)
    local s = self[route.stroke]
    self[route.stroke] = nil
    local session = self[route.session]
    if not s or not session then return end

    local tr = session:transform()
    if s.n == 1 and tr then
        -- A dot is never painted live, because there is no segment to paint.
        local cache = session:cache()
        if cache then
            local box, raster_cache, raster_generation =
                cache:drawSegment(s[1], s[2], s[1], s[2], s.w,
                    Style.colorFor(s.t, nil))
            updateLiveRasterToken(s, box, raster_cache, raster_generation)
            self[route.paint](self, box, tr)
        end
    end

    local ok, err, painted, left, top, right, bottom =
        session:addStroke(s, s.n, s.w, s.t or Style.PEN, {
            raster_cache = s.raster_cache,
            raster_generation = s.raster_generation,
            live_raster_complete = s.live_raster_complete == true,
        })
    if not ok then
        logger.warn(route.log, err)
        local box = session:repair(s.min_x, s.min_y, s.max_x, s.max_y, s.w)
        if box and tr then self[route.repair_paint](self, box, tr) end
        if err == "queue_backpressure" then
            if not self[route.backpressure_flag] then
                self[route.backpressure_flag] = true
                self[route.backpressure](self)
            end
        elseif err == "operation_too_large" then
            -- A stroke the queue can never accept, reported from inside the
            -- stylus callback: say so once, and latch the capture stop for
            -- the residual handler rather than releasing the lease here.
            self:notifyStrokeBudget()
            self[route.capture_stop](self)
        end
        return nil, err
    end
    self[route.backpressure_flag] = false
    if painted and tr then
        self[route.paint](self, {
            x = left, y = top, w = right - left, h = bottom - top,
        }, tr)
    end
    return true
end

--- Give up the stroke in progress: its segments are already in the raster, so
--- the region has to be rebuilt from what was underneath.
local function abortSurfaceStroke(self, route)
    endSurfaceErase(self, route)
    local s = self[route.stroke]
    self[route.stroke] = nil
    local session = self[route.session]
    if not s or not session then return end
    local box = session:repair(s.min_x, s.min_y, s.max_x, s.max_y, s.w)
    local tr = session:transform()
    if box and tr then self[route.repair_paint](self, box, tr) end
end

local JustDraw = WidgetContainer:extend{
    name = "justdraw",
    is_doc_only = false,
}

-- ---------------------------------------------------------------- lifecycle

function JustDraw:init()
    -- FileManager only passes `ui`; ReaderUI additionally exposes document,
    -- view and doc_settings. Keep notebook construction document-free so the
    -- same library can be opened safely from either host.
    self.is_docless = self.ui.document == nil

    --[[--
    What this runtime can do, asked once (ADR-41).

    `stylus_api` is the whole product gate: it separates v2026.07 from
    v2026.03 and decides whether the new surfaces exist at all. The other
    three are asserted further down, where they matter.

    The two reader probes are skipped in the file manager, and that is the
    point of doing it here rather than in one call: `Compat.capabilities`
    resolves what it is not given by `require`, so asking a docless host about
    the ReaderView transform would pull the whole reader-view stack into
    file-manager start-up -- on the v2026.03 floor too -- to answer a question
    nothing docless reads.
    ]]
    self.capabilities = Compat.capabilities(self.is_docless
        and { ReaderView = false, Document = false } or nil)
    self.legacy_frozen = Compat.fullSupport(self.capabilities)

    self.notebooks = nil
    self.notebook_input = nil
    self.notebook_ui = nil
    self.screen_resize_serial = 0
    self.screen_resize_pending = false
    self.drawing = false
    self.eraser = false
    self.bar = nil
    self.pen_width = Compat.readSetting(G_reader_settings, "pen_width", PEN_MEDIUM)
    self.pen_style = Style.normalize(
        Compat.readSetting(G_reader_settings, "pen_style", Style.PEN))
    self.live_fast = Compat.readSetting(G_reader_settings, "live_fast", true)
    self.bar_side = Compat.readSetting(G_reader_settings, "bar_side", "right")
    self.notebook_rail_side = Compat.readSetting(G_reader_settings, "notebook_rail_side")
    if self.notebook_rail_side ~= "left" and self.notebook_rail_side ~= "right" then
        self.notebook_rail_side = "right"
    end

    local mode = Compat.readSetting(G_reader_settings, "input_mode")
    self.input_mode = INPUT_MODES[mode] and mode or "auto"
    self.input_backend = nil
    self.input_lease = nil

    self.contacts = {}
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    self.stroke = nil
    -- Resolved once, at the physical contact-down frame -- before the
    -- geometry policy has even proven a coherent pair to draw from -- so a
    -- style flipped mid-contact cannot retroactively restyle it. See
    -- onStylusContactStart / onStylusContactEnd.
    self.contact_style = nil

    -- One contact normalizer, one palm ledger and one geometry policy per
    -- capture lease, shared with the notebook route. See buildStylusMachine.
    self.stylus_sequence = nil
    self.palm_gate = nil
    self.stylus_geometry = nil
    self.capture_input = nil
    self.max_open_points = Limits.MAX_OPEN_POINTS
    self.max_contact_samples = Limits.MAX_CONTACT_SAMPLES
    self.stylus_budget_notified = false

    self.stylus_trace = nil
    self.trace_instance = nil
    self.trace_source = nil
    self.pen_notice_shown = false

    -- The EPUB canvas. Everything about it stays nil until a reflowable
    -- document is ready, and every entry point checks `canvas_open`, so a PDF
    -- session behaves exactly as it did before any of this existed.
    self.session = nil
    self.router = nil
    self.canvas_open = false
    self.canvas_erase_ctx = nil
    self.canvas_erase_x, self.canvas_erase_y = nil, nil
    self.direct_erase_x, self.direct_erase_y = nil, nil
    self.canvas_stroke = nil
    self.canvas_backpressure_notified = false
    self.canvas_backpressure_notice_pending = false
    self.stroke_budget_notice_pending = false
    self.canvas_pending_repaint = nil
    self.canvas_pending_capture_stop = nil
    --- Left nil in production, where the session opens its own connection.
    --- The suite runs under a bare interpreter that cannot load the SQLite
    --- driver at all, so it hands one in.
    self.canvas_repository = nil

    -- Page ink on a fixed layout. Everything here stays nil unless the
    -- runtime has the stylus API (ADR-41) and ReaderUI is a paging one, and
    -- every entry point checks `document_session`, so a v2026.03 route and
    -- every EPUB behave exactly as they did before any of this existed.
    self.document_session = nil
    self.document_stroke = nil
    self.document_erase_ctx = nil
    self.document_erase_x, self.document_erase_y = nil, nil
    self.document_pending_view_repaint = nil
    self.document_view_refresh_pending = false
    self.document_page_pending = false
    self.document_pending_page = nil
    self.document_backpressure_notified = false
    self.document_backpressure_notice_pending = false
    self.document_refusal_notice_pending = false
    self.document_refusal_notified = false
    self.document_pending_capture_stop = false
    --- Whether a failed write, and not the reader, is what stopped Draw. A
    --- retry gives it back only to somebody who had it.
    self.document_drawing_suspended = false
    --- What the "Delete all page notes" entry reads, cached: `enabled_func`
    --- runs on every paint of the menu and a COUNT per paint is exactly the
    --- query `canExport` exists not to make. Invalidated by everything that
    --- can add or remove a page's ink.
    self.document_ink_count = nil
    --- Left nil in production. The suite's fake buffer has no pixels, so the
    --- transparent clear an overlay erases through arrives injected, the same
    --- seam `canvas_repository` is.
    self.document_cache_opts = nil

    -- One controller for the reader's exports, built before the docless
    -- return so both hosts have one. Everything it reads arrives as an
    -- accessor: the store is created further down, the sheet session only in
    -- `onReaderReady`, and the input lease only while drawing is on.
    self.export_controller = ExportController.new{
        ui = self.ui,
        view = self.view,
        docless = self.is_docless,
        session = function() return self.session end,
        document_session = function() return self.document_session end,
        legacy = function() return self.legacy end,
        lease = function() return self.input_lease end,
        canvas_open = function() return self.canvas_open end,
        current_page = function() return self:currentPage() end,
        screen = function() return Screen:getWidth(), Screen:getHeight() end,
        ink = INK,
        settings = function() return G_reader_settings end,
        show_modal = function(widget) return self:showReaderModal(widget) end,
        close_modal = function(widget) return self:closeReaderModal(widget) end,
        notify = function(text) self:notify(text) end,
        schedule = function(fn) UIManager:nextTick(fn) end,
    }

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.is_docless then return end

    -- Only now, with a document open: these three exist on both runtimes
    -- (ADR-41), so a build without one is a build to complain about loudly
    -- rather than a route to fall back to. Never a gate.
    local complete, missing = Compat.assertCapabilities(self.capabilities)
    if not complete then
        logger.warn("JustDraw: this KOReader is missing", missing,
            "- page ink and drawing sheets may not work here")
    end

    local pages
    pages, self.stroke_storage_id, self.stroke_storage_present =
        Compat.readDataSetting(self.ui.doc_settings, "strokes")
    self.store = Store.new(pages)
    --[[--
    The frozen sidecar, behind a view that cannot add to it (ADR-39).

    Everything that only reads the sidecar -- `paintTo`, the two "Clear legacy
    ink" entries -- goes through this and not through `self.store`, on both
    runtimes, so there is one paint path rather than two. What the gate
    decides is whether anything may still *write*, and that is
    `legacyInkFrozen`: the direct-ink route below keeps its own reference to
    the store, and is the only thing in this file that has one.
    ]]
    self.legacy = Legacy.new(self.store)
    self.direct_ink_clear_all = false

    self.view:registerViewModule("justdraw", self)

    if Compat.readSetting(G_reader_settings, "bar_shown", true) ~= false then
        UIManager:nextTick(function() self:setBarShown(true) end)
    end
end

--- Return the headless notebook domain without opening its SQLite database.
function JustDraw:notebookController()
    if self.notebooks then return self.notebooks end
    self.notebook_input = NotebookInput.new{
        get_mode = function() return self.input_mode end,
        get_pen_width = function() return self.pen_width end,
        get_pen_style = function() return self.pen_style end,
        get_eraser = function() return self.eraser end,
        on_error = function(reason) self:notify(reason or "input_failed") end,
        on_domain_error = function(reason, session)
            if reason ~= "operation_too_large" or not session
                or type(session.failInputDeferred) ~= "function" then
                return
            end
            local ok, err = session:failInputDeferred(reason)
            if not ok then
                logger.err("JustDraw notebooks: input teardown failed:", err)
            end
        end,
        get_stylus_trace = function() return self:activeStylusTrace("notebook") end,
    }
    local adapter = self.notebook_input
    self.notebooks = NotebookController.new{
        require_viewport = true,
        schedule = function(fn) UIManager:nextTick(fn) end,
        scheduleIn = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        notify = function(text) self:notify(text) end,
        before_open = function(_, controller)
            return self:prepareNotebookHandoff(controller)
        end,
        session_opts = {
            capture_spec = function(session, page, transform)
                return adapter:captureSpec(session, page, transform)
            end,
            abort_contact = function(session) return adapter:abort(session) end,
        },
    }
    return self.notebooks
end

function JustDraw:notebookUI()
    if self.notebook_ui then return self.notebook_ui end
    local NotebookUI = require("ink_notebook_ui")
    self.notebook_ui = NotebookUI.new{
        plugin = self,
        controller = self:notebookController(),
    }
    return self.notebook_ui
end

function JustDraw:openNotebookLibrary()
    return self:notebookUI():openLibrary()
end

--[[--
The Dispatcher route to the library, in the reader and in the file browser.

Deliberately the same call the menu makes, failures included: `openLibrary` is
idempotent, so a second press of the gesture that opened the library raises no
second window.
]]
function JustDraw:onJustDrawNotebooks()
    self:openNotebookLibrary()
    return true
end

function JustDraw:setNotebookRailSide(side)
    if side ~= "left" and side ~= "right" then return nil, "bad_side" end
    if self.notebook_rail_side == side then return true end
    self.notebook_rail_side = side
    Compat.saveSetting(G_reader_settings, "notebook_rail_side", side)
    return true
end

function JustDraw:prepareNotebookHandoff(controller)
    if self.canvas_open then
        local closed, close_err = self:closeCanvas()
        if not closed then return nil, close_err end
    end
    local lease = self.input_lease
    if lease and lease:hasActiveContact() then return nil, "contact_active" end
    if lease then
        if not self.is_docless and self.drawing then
            self:setDrawing(false)
            if self.input_lease then return nil, "release_failed" end
        else
            local released, release_err = lease:release()
            if not released then return nil, release_err end
            self.input_lease = nil
        end
    end
    local owner = InputController:activeOwner()
    if owner and owner ~= controller then return nil, "already_installed" end
    return true
end

-- Public UI seam: visual code supplies only regions and
-- repaint policy. Hardware input and persistence stay below it.
function JustDraw:configureNotebookInteraction(opts)
    local controller = self:notebookController()
    opts = opts or {}
    local configured, configure_err = controller:configureInteraction{
        viewport_provider = opts.viewport_provider,
        transform_factory = opts.transform_factory,
        fit_rect = opts.fit_rect,
        clip_rect = opts.clip_rect,
        align_x = opts.align_x,
        align_y = opts.align_y,
        on_page_ready = opts.on_page_ready,
        on_dirty_box = opts.on_dirty_box,
        on_state_changed = opts.on_state_changed,
        on_durable_change = opts.on_durable_change,
        on_library_changed = opts.on_library_changed,
    }
    if not configured then return nil, configure_err end
    self.notebook_input:configure(opts)
    return true
end

--[[--
Publish the actions a gesture, a hotkey or a profile can be bound to.

Named for the `DispatcherRegisterActions` broadcast rather than called only
from `init`, because the two arrive in either order: `Dispatcher:init` fires the
broadcast at whatever is loaded, and a plugin that loads afterwards has to
register itself. Both paths run here, and `registerAction` ignores a name it
already holds.

Registered from the file browser too. The four ink actions declare `reader`, so
Dispatcher keeps them out of the file browser's own list; what would not survive
is registering nothing at all in a session that never opens a book, which is
exactly the session in which the notebook action matters.
]]
function JustDraw:onDispatcherRegisterActions()
    -- Gesture Manager persists Dispatcher action IDs. Keep these legacy IDs
    -- and events so assignments made before the rename continue to work; only
    -- their visible titles use the current brand.
    Dispatcher:registerAction("fingerink_toggle", {
        category = "none", event = "FingerInkToggle", reader = true,
        title = _("JustDraw: toggle drawing"),
    })
    Dispatcher:registerAction("fingerink_eraser", {
        category = "none", event = "FingerInkEraser", reader = true,
        title = _("JustDraw: toggle eraser"),
    })
    Dispatcher:registerAction("fingerink_undo", {
        category = "none", event = "FingerInkUndo", reader = true,
        title = _("JustDraw: undo stroke"),
    })
    Dispatcher:registerAction("fingerink_bar", {
        category = "none", event = "FingerInkBar", reader = true,
        title = _("JustDraw: toggle toolbar"),
    })
    -- No legacy identity to keep: the library postdates the rename. `general`,
    -- not `reader`, because a notebook needs no document -- Dispatcher shows an
    -- action only in the section it declares (dispatcher.lua `_addItem`), and
    -- reaching a notebook without opening a book first is the whole point.
    Dispatcher:registerAction("justdraw_notebooks", {
        category = "none", event = "JustDrawNotebooks", general = true,
        title = _("JustDraw: open notebooks"),
    })
    -- Also post-rename, so no legacy identity. A sheet exists only over a
    -- document, and this was `reader` at first for that reason -- but on
    -- device that buried the action at the bottom of the gesture manager's
    -- Reader section while the other two JustDraw actions sat together under
    -- General, and the reader could not find it at all. `general` keeps the
    -- three discoverable in one place; fired without a document the handler
    -- says why instead of doing nothing.
    Dispatcher:registerAction("justdraw_sheet", {
        category = "none", event = "JustDrawSheet", general = true,
        title = _("JustDraw: open/close drawing sheet"),
    })
    -- Also post-rename, no legacy identity. `general`, not `reader`, because
    -- pen_style is a global setting read at init, so binding the toggle in the
    -- file browser configures the next reading session.
    Dispatcher:registerAction("justdraw_marker", {
        category = "none", event = "JustDrawMarker", general = true,
        title = _("JustDraw: toggle marker/pen"),
    })
end

--[[--
Start whichever surface session this document can have, once it is ready.

Not in `init`: half the book's identity is `partial_md5_checksum`, which
ReaderUI computes on its way to emitting this event.

Exactly one of the two, because ReaderUI is exactly one of the two. A sheet
anchored by xpointer means nothing in a fixed layout; page ink keyed by page
number means nothing in a book whose pages move with the font size.
]]
function JustDraw:onReaderReady(config)
    if self.is_docless or not self.ui.document then return end

    -- The checksum lives in the document's settings, not on ReaderUI, which
    -- computes it there on its way to emitting this event
    -- (readerui.lua:473 @ v2026.07). Statistics reads it the same way.
    local settings = config or self.ui.doc_settings

    if self.ui.rolling then return self:openCanvasSession(settings) end
    if self.ui.paging then return self:openDocumentSession(settings) end
end

--[[--
The page-ink session for a fixed-layout document.

Gated on `Capture:supportsStylus()`, which is the product gate for every new
surface (ADR-41): it is the runtime and not the hardware, so a finger-only
device on v2026.07 gets page ink and a Kindle Scribe on v2026.03 keeps the
direct-ink route it always had.

The session is published before the page is looked up, because looking one up
opens a raster whose `on_ready` comes straight back here.
]]
function JustDraw:openDocumentSession(settings)
    if self.document_session or not Capture:supportsStylus() then return end

    local session = DocumentInkSession.new{
        ui = self.ui,
        view = self.view,
        identity = {
            partial_md5 = settings and settings:readSetting("partial_md5_checksum"),
            file_size = self:documentSize(),
        },
        file = self.ui.document.file,
        repository = self.canvas_repository,
        -- The raster is the whole page at zoom, so the budget that refuses a
        -- zoom is measured in screens (ADR-38).
        screen = function() return Screen:getWidth(), Screen:getHeight() end,
        schedule = function(fn) UIManager:nextTick(fn) end,
        scheduleIn = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        notify = function(text) self:notify(text) end,
        cache_opts = self.document_cache_opts,
        on_ready = function() self:onDocumentInkReady() end,
        on_load_error = function(reason) self:onDocumentInkLoadFailed(reason) end,
        on_save_error = function(reason) self:onDocumentInkSaveFailed(reason) end,
        on_save_recovered = function() self:onDocumentInkSaveRecovered() end,
        on_will_rebuild = function() self:onDocumentInkWillRebuild() end,
        on_view_refused = function(reason) self:onDocumentInkViewRefused(reason) end,
    }
    local opened, open_error = session:open()
    if not opened then
        -- Kept so Draw can say the same thing later. The session notified
        -- once, at open; a reader who presses Draw ten minutes afterwards is
        -- owed the reason again rather than a toolbar that arms over nothing.
        self.document_open_error = open_error or "unavailable"
        return
    end
    self.document_open_error = nil
    self.document_session = session
    self.document_ink_count = nil
    session:setPage(self:currentPage())
    session:refreshView()
    return session
end

function JustDraw:openCanvasSession(settings)
    if self.session then return end

    self.session = CanvasSession.new{
        document = self.ui.document,
        identity = {
            partial_md5 = settings:readSetting("partial_md5_checksum"),
            file_size = self:documentSize(),
        },
        file = self.ui.document.file,
        dom_version = settings:readSetting("cre_dom_version"),
        repository = self.canvas_repository,
        plugin = self,
        ui = self.ui,
        schedule = function(fn) UIManager:nextTick(fn) end,
        scheduleIn = function(delay, fn) UIManager:scheduleIn(delay, fn) end,
        unschedule = function(fn) UIManager:unschedule(fn) end,
        -- Every batch of the sheet index asks this first: a blocking query
        -- while the pen reports overflows evdev and costs the next pen-down
        -- (ADR-26, ADR-42).
        can_work = function() return not self:hasActivePhysicalContact() end,
        notify = function(text) self:notify(text) end,
    }
    if not self.session:open() then
        self.session = nil
        return
    end
    self.router = Router.new{
        backend = self.input_backend or "finger",
        regions = function(x, y) return self:regionAt(x, y) end,
        dialogOnTop = function() return self:dialogOnTop() end,
    }
    self:onPageUpdate(self:currentPage())
end

--- The other half of the book's identity. `lfs` is not in the test harness and
--- is not worth requiring for a value the caller can also supply.
function JustDraw:documentSize()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not self.ui.document or not self.ui.document.file then return nil end
    return lfs.attributes(self.ui.document.file, "size")
end

function JustDraw:onCloseDocument()
    self:teardown()
end

function JustDraw:onCloseWidget()
    self:teardown()
end

function JustDraw:onSuspend()
    -- A suspend flushes settings and can close connections underneath a job
    -- that is still reading through them; and the reader cannot answer a
    -- progress modal that is no longer on screen.
    Export.cancelRunning()
    if self.notebooks then self.notebooks:onSuspend() end
    if not self.is_docless then self:setDrawing(false) end
end

function JustDraw:onResume()
    if self.notebooks then
        local resumed, resume_err = self.notebooks:onResume()
        if not resumed then logger.warn("JustDraw: notebook resume failed:", resume_err) end
    end
    if self.notebook_ui then self.notebook_ui:onResume() end
end

--[[--
Every exit path lands here. It has to do exactly what stopping does, including
dropping the stroke in flight: an unfinished stroke is not in the store yet, so
leaving it dangling loses it silently and leaks contact state into whatever
document is opened next in the same session.
]]
function JustDraw:teardown()
    -- Closing the document takes its repository with it, and a raster still
    -- replaying through that connection would be reading a closed one.
    Export.cancelRunning()
    self.screen_resize_serial = self.screen_resize_serial + 1
    self.screen_resize_pending = false
    if self.notebook_ui then
        local closed, close_err = self.notebook_ui:shutdown()
        if not closed then
            logger.warn("JustDraw: notebook UI close failed during teardown:", close_err)
        end
        self.notebook_ui = nil
        self.notebooks = nil
        self.notebook_input = nil
    elseif self.notebooks then
        local closed, close_err = self.notebooks:shutdown()
        if not closed then
            logger.warn("JustDraw: notebook close failed during teardown:", close_err)
        end
        self.notebooks = nil
        self.notebook_input = nil
    end
    if self.is_docless then return end
    -- Before the session goes: abortStroke reaches the sheet's stroke through
    -- it, and an unfinished stroke is not in any store yet.
    self:abortStroke()
    if self.session then
        self.session:close{ force = true }
        self.session = nil
        self.router = nil
        self.canvas_open = false
        self.canvas_pending_repaint = nil
    end
    if self.document_session then
        self.document_session:close{ force = true }
        self.document_session = nil
        self.document_pending_view_repaint = nil
        self.document_ink_count = nil
    end
    if self.input_lease then self.input_lease:release() end
    self.input_lease = nil
    self:resetContacts()
    self:resetStylusState()
    self.input_backend = nil
    self.drawing = false
    if self.bar then
        UIManager:close(self.bar)
        self.bar = nil
    end
end

--[[--
The durable-save gate for canvas ink.

`Device:_beforeSuspend` calls `UIManager:flushSettings()` and only then emits
`Suspend`, and the close path emits this before DocSettings is written and the
document closed. Saving in `onSuspend` would already be too late.
]]
function JustDraw:onSaveSettings()
    if self.notebooks then
        local saved, save_err = self.notebooks:onFlushSettings()
        if not saved then
            logger.warn("JustDraw: SaveSettings notebook flush failed:", save_err)
        end
    end
    if self.is_docless then return end
    if self.session then
        local saved, save_err = self.session:flush()
        if not saved then
            -- Queue already retained the operations and emitted the reader's
            -- deduplicated notification; this log makes the lifecycle gate's
            -- failed return explicit without claiming settings were durable.
            logger.warn("JustDraw: SaveSettings canvas flush failed:", save_err)
        end
    end
    if self.document_session then
        local saved, save_err = self.document_session:flush()
        -- `unavailable` is the session saying there was never anything here to
        -- save, not that ink was lost; the reader has already been told about
        -- everything else, by the queue, when the write failed.
        if not saved and save_err ~= "unavailable" and save_err ~= "closed" then
            logger.warn("JustDraw: SaveSettings page ink flush failed:", save_err)
        end
    end
    local explicit_clear = self.direct_ink_clear_all
    if explicit_clear then
        Compat.delSetting(self.ui.doc_settings, "strokes")
        self.stroke_storage_id = Compat.current_id
        self.stroke_storage_present = false
        self.direct_ink_clear_all = false
    end
    if not self.store:isEmpty() then
        Compat.saveDataSetting(self.ui.doc_settings, "strokes",
            self.stroke_storage_id, self.store.pages)
        self.stroke_storage_present = true
    elseif not explicit_clear and self.stroke_storage_present then
        -- Undo, eraser and Clear page may remove the last active stroke. Keep
        -- an empty value under that active identity so readDataSetting cannot
        -- fall back to and expose (or later delete) an inactive divergent key.
        Compat.saveDataSetting(self.ui.doc_settings, "strokes",
            self.stroke_storage_id, self.store.pages)
    end
end

--- The reader's explicit "delete all of it". `direct_ink_clear_all` is what
--- turns an emptied table into a deletion of *both* compatibility identities
--- at the next flush; without it the legacy key would survive and the ink
--- would be back on the next open.
function JustDraw:clearWholeDocumentInk()
    self.legacy:clearAll()
    self.direct_ink_clear_all = true
    self:repaint()
end

--- Rotation and resize invalidate the bar's fixed position; rebuild it.
function JustDraw:rebuildBar()
    if not self.bar then return end
    UIManager:close(self.bar)
    self.bar = nil
    UIManager:nextTick(function() self:setBarShown(true) end)
end

function JustDraw:_applyScreenResize()
    if self.notebook_ui then
        local resized, resize_err = self.notebook_ui:onScreenResize()
        if not resized then
            logger.warn("JustDraw: notebook UI resize failed:", resize_err)
        end
    elseif self.notebooks then
        local resized, resize_err = self.notebooks:onScreenResize()
        if not resized then
            logger.warn("JustDraw: notebook resize failed:", resize_err)
        end
    end
    if self.is_docless then return end
    local overlay = self.session and self.session:overlay()
    if overlay then
        overlay:onScreenResize()
        self.bar = overlay.bar
    else
        self:rebuildBar()
    end
    -- The page moved under the reader, and every number the page-ink transform
    -- is built from came from the view that just changed shape.
    self:scheduleDocumentViewRefresh()
end

function JustDraw:onScreenResize()
    -- A real ScreenResize/SetDimensions after rotation supersedes the deferred
    -- SetRotationMode reconciliation below.
    self.screen_resize_serial = self.screen_resize_serial + 1
    self.screen_resize_pending = false
    self:resetStylusTraceContactHistory()
    return self:_applyScreenResize()
end

function JustDraw:onSetRotationMode()
    if self.screen_resize_pending then return end
    self:resetStylusTraceContactHistory()
    self.screen_resize_pending = true
    self.screen_resize_serial = self.screen_resize_serial + 1
    local serial = self.screen_resize_serial
    -- FileManager changes Screen dimensions after broadcasting SetRotationMode
    -- to plugin children. Reconcile on the next tick, when the host has applied
    -- the rotation. A subsequent ScreenResize invalidates this callback.
    UIManager:nextTick(function()
        if not self.screen_resize_pending or self.screen_resize_serial ~= serial then return end
        self.screen_resize_pending = false
        self:_applyScreenResize()
    end)
end

-- ----------------------------------------------------------- canvas events

--- A page turn. Only the marks are recomputed; the index answers from memory.
function JustDraw:onPageUpdate(page)
    if self.session then self.session:setPage(page or self:currentPage()) end
    self:scheduleDocumentPage(page)
end

--[[--
`PosUpdate` carries `(pos, pageno)` -- the scroll position first
(readerrolling.lua:1089 @ v2026.07). Aliasing it to `onPageUpdate` would hand a
byte offset to something that looks up canvases by page number, and every mark
in scroll mode would land on the wrong page or on none.
]]
function JustDraw:onPosUpdate(_, page)
    self:onPageUpdate(page)
end

--- Font, margin or line-height change. The page index is rebuilt; not one
--- stroke is read, written or moved.
function JustDraw:onDocumentRerendered()
    if self.session then self.session:invalidate() end
    self:abandonBlindContact("document_rerendered")
end

--[[--
The capture just went blind, and whatever is on the glass will never report its
lift.

`Input:inhibitInput` swaps `handleTouchEv` for a sink and drops KOReader's own
contacts, and `routeStylusEvents` is called from inside that handler
(input.lua @ 60ce80ed) -- so between the swap and its restore no frame reaches
either route, the lift included. A re-render is the one such window that can
open while someone is drawing: readerrolling inhibits input, re-renders, and
broadcasts `DocumentRerendered` from inside the blind stretch.

On Wacom a missing lift is worse than a missing sample. The pen's tracking id
is pinned to `pen_slot` for every contact and only ever changes to -1 on the
lift, so with the lift gone nothing distinguishes the next contact-down from
the next sample of the stroke we were drawing, and the two would be joined by a
line neither of them drew. Ending the contact here is the only thing that keeps
them apart. The geometry history goes with it: a boundary from before the blind
window names a place the pen may have left long ago.
]]
function JustDraw:abandonBlindContact(reason)
    -- The third argument is the point. `inhibitInput` already ran
    -- `Input:resetState`, so a forwarded contact is not owned by anybody any
    -- more and the drop that would hand it back is guaranteed to fail. Without
    -- saying so, the sequence refuses to end it and latches forever.
    local sequence = self.stylus_sequence
    if sequence then sequence:abort(reason, true, true) end
    if self.palm_gate then self.palm_gate:reset() end
    self:abortStroke()
    self:resetContacts()
    -- The notebook editor runs a second, independent contact machine over the
    -- same digitizer, and a notebook can be open above a document. Its own
    -- abort already survives a contact GestureDetector no longer owns -- it
    -- rebuilds the machine rather than latching -- so it needs nothing new,
    -- only to be told.
    local adapter = self.notebook_input
    if adapter and adapter:hasActiveContact() then adapter:abort() end
end

--- The asynchronous page index has caught up with the current layout. Session
--- already recomputed `marks_here`; repaint so the first visible page does not
--- wait for an unrelated PageUpdate before showing its sheet markers.
function JustDraw:onCanvasIndexReady()
    if self.session then UIManager:setDirty(self.ui, "ui") end
end

-- --------------------------------------------------- page ink: view events

--[[--
Re-read the view on the next tick, once, however many events said to.

On the next tick because the host applies the change *after* it broadcasts:
`state.offset`, `state.zoom` and `visible_area` are the reader's, not ours,
and reading them from inside the event reads the old ones. Once because a pan
emits an event per frame and rebuilding a transform per frame would be the
one allocation a drag can afford least.
]]
function JustDraw:scheduleDocumentViewRefresh()
    if not self.document_session or self.document_view_refresh_pending then return end
    self.document_view_refresh_pending = true
    UIManager:nextTick(function()
        self.document_view_refresh_pending = false
        self:refreshDocumentView()
    end)
end

--- Rebuild the page-ink transform from the live view. A refusal reaches the
--- reader through `on_view_refused`, once per change of reason, so there is
--- nothing to say about one here.
function JustDraw:refreshDocumentView()
    local session = self.document_session
    if not session then return end
    return session:refreshView()
end

--[[--
The reader turned to another page.

Deferred and coalesced for the same reason the view refresh is: the page is
the host's, and a fast page turn emits several before any of them settles.
The abort belongs on this side of the flush -- an unfinished stroke is in no
store, and the flush is what frees the raster it was drawn into.
]]
function JustDraw:scheduleDocumentPage(page)
    if not self.document_session then return end
    self.document_pending_page = page
    if self.document_page_pending then return end
    self.document_page_pending = true
    UIManager:nextTick(function()
        self.document_page_pending = false
        local target = self.document_pending_page
        self.document_pending_page = nil
        local session = self.document_session
        if not session then return end
        self:abortDocumentStroke()
        -- A refused turn (`flush_failed`) has already been notified by the
        -- queue that failed, and the session is holding the page for a retry.
        local turned = session:setPage(target or self:currentPage())
        -- Leaving a page can forget its row -- an empty surface is not a page
        -- note -- so the menu's cached count is no longer the truth.
        if turned then self.document_ink_count = nil end
        if turned and self.drawing then self:continueDocumentInk() end
    end)
end

--[[--
Carry Draw over to the page the reader has just turned to.

`setPage` deliberately creates nothing -- a reader who never draws must not
collect a row per page they walked past -- so with Draw on the new page would
otherwise have no surface at all: `canDraw` answers `no_surface`, every point
is refused, and the toolbar still says Stop. Turning a page with Draw on is
the reader saying they mean to keep drawing, and this is a lifecycle tick, so
the insert is legal here (ADR-26).

A page that cannot take ink stops Draw instead, with the sentence for it --
unless the view refusal already did both, in which case saying it twice would
be worse than not saying it at all.
]]
function JustDraw:continueDocumentInk()
    local ready, reason = self:prepareDocumentInk()
    if ready then return true end
    -- A raster still reading is not a refusal: `on_ready` is on its way, and
    -- stopping Draw for the length of one page's load would take the pen out
    -- of the reader's hand on every annotated page they turn to. Points that
    -- arrive meanwhile are refused, once, with that same sentence.
    if reason == "loading" then return true end
    if self.drawing then
        self:setDrawing(false)
        self:notify(documentMessage(reason))
    end
    return nil, reason
end

--- The page was rescaled. The raster follows on `on_will_rebuild`.
function JustDraw:onZoomUpdate()
    self:scheduleDocumentViewRefresh()
end

--- The page moved: `recalculate`, and every pan, emit this.
function JustDraw:onViewRecalculate()
    self:scheduleDocumentViewRefresh()
end

--[[--
Continuous scrolling on or off.

Scroll mode is the one view the transform cannot describe at all -- one screen
can hold parts of two pages -- so the surface is put away rather than refused
per event, and the row stays exactly where it is until the reader comes back
(ADR-38).
]]
function JustDraw:onSetScrollMode(page_scroll)
    if not self.document_session then return end
    local scrolling = page_scroll and true or false
    UIManager:nextTick(function()
        local session = self.document_session
        if not session then return end
        if scrolling then
            self:abortDocumentStroke()
            -- Only worth a sentence to somebody who was drawing, exactly as a
            -- refused view is: a reader who turns scrolling on is not asking
            -- about page notes.
            local was_drawing = self.drawing
            self:setDrawing(false)
            local ok, err = session:suspend("unsupported_mode")
            if not ok then
                if was_drawing then self:notify(documentMessage(err)) end
                return
            end
            if was_drawing then
                self:notify(documentMessage("unsupported_mode"))
            end
        else
            local ok, err = session:resume()
            if not ok then
                self:notify(documentMessage(err))
                return
            end
            self:refreshDocumentView()
        end
    end)
end

-- ------------------------------------------------ page ink: session events

--[[--
This page's raster is complete, so the page can show its ink.

Nothing else will ask for that repaint: the reader turned the page, KOReader
painted it, and the ink finished rasterising afterwards. The toolbar is
deliberately not touched -- it carries no page-ink state, and an extra refresh
of it on every page turn is not free on eink.
]]
function JustDraw:onDocumentInkReady()
    UIManager:setDirty(self.ui, "ui")
end

--- The reason a read or a write failed is the driver's own sentence -- "cannot
--- commit", a disk error -- so it goes to the log, and the reader gets the one
--- line that says what state their ink is in. This is what `CanvasSession`
--- does with the same two callbacks.
function JustDraw:onDocumentInkLoadFailed(reason)
    logger.warn("JustDraw: this page's ink could not be read:", reason)
    self:setDrawing(false)
    self:notify(DOCUMENT_ERRORS.load_failed)
end

--- A write failed. The strokes are still in memory and nothing more may be
--- added until a retry succeeds -- the same bargain the sheet makes.
function JustDraw:onDocumentInkSaveFailed(reason)
    logger.warn("JustDraw: page ink write failed:", reason)
    -- Remember whether the failure is what stopped the reader: a retry gives
    -- Draw back, and giving it to somebody who had turned it off themselves
    -- would be the plugin deciding to draw. Sticky, because the write is
    -- retried by every lifecycle gate that follows -- a page turn among them
    -- -- and the second failure finds drawing already off.
    self.document_drawing_suspended =
        self.document_drawing_suspended or self.drawing
    self:setDrawing(false)
    self:notify(DOCUMENT_ERRORS.save_failed)
end

--[[--
The retry went through, and the page change it was holding has been made.

Drawing was turned off by the failure and not by the reader, so it comes back
on -- the same bargain the sheet makes. Through `setDrawing`, which is what
gives the page the reader ended up on its surface and refuses, with a
sentence, when it cannot have one.
]]
function JustDraw:onDocumentInkSaveRecovered()
    if not self.document_drawing_suspended then return end
    self.document_drawing_suspended = false
    self:setDrawing(true)
end

--[[--
The raster is about to be replaced, because the scale moved.

This is the last moment the buffer a live stroke drew into is still there to
repair, which is why the session announces it rather than simply rebuilding.
]]
function JustDraw:onDocumentInkWillRebuild()
    self:abortDocumentStroke()
end

--- The view can no longer be mapped. Only worth a sentence to somebody who
--- was drawing; a reader panning in scroll mode is not asking a question.
function JustDraw:onDocumentInkViewRefused(reason)
    if not self.drawing then return end
    self:setDrawing(false)
    self:notify(documentMessage(reason))
end

-- ----------------------------------------------------------------- toolbar

function JustDraw:setBarShown(on)
    on = on and true or false
    -- With a sheet open the toolbar is the overlay's child, not a window of
    -- ours. "Hide" then means put the sheet away -- the invariant is still
    -- that drawing is never on without a way to turn it off.
    if self.canvas_open then
        if not on then self:closeCanvas() end
        return
    end
    Compat.saveSetting(G_reader_settings, "bar_shown", on)

    if on then
        if self.bar then return end
        self.bar = InkBar:new{ plugin = self, side = self.bar_side }
        UIManager:show(self.bar, "ui", self.bar.dimen)
    else
        -- Invariant: drawing is never on without a way to turn it off.
        self:setDrawing(false)
        if not self.bar then return end
        local dimen = self.bar.dimen
        UIManager:close(self.bar)
        self.bar = nil
        UIManager:setDirty(self.ui, "ui", dimen)
    end
end

function JustDraw:onJustDrawBar()
    self:setBarShown(self.bar == nil)
    return true
end

function JustDraw:inBar(x, y)
    return self.bar ~= nil and self.bar:contains(x, y)
end

--[[--
True while a menu or dialog is open over the reader.

Drawing mode eats single-finger touches before UIManager ever sees them, which
would otherwise make an open menu impossible to dismiss — tapping outside it is
the only way to close one. So drawing yields for as long as one is up.
]]
--- Whichever JustDraw window is currently the topmost: the canvas overlay
--- when a sheet is open, the standalone toolbar otherwise.
function JustDraw:topWindow()
    local overlay = self.session and self.session:overlay()
    if overlay then return overlay end
    return self.bar
end

function JustDraw:dialogOnTop()
    local top = self:topWindow()
    if not top then return false end
    local below = Stack.below(top)
    return below ~= nil and below ~= self.ui
end

--[[--
Which part of the screen this point belongs to.

With no sheet open there are only two answers and only the toolbar matters.
With one open this is the router's geometry oracle, and the order is the one
that keeps Stop reachable: toolbar, handle, sheet, book.

Everything inside the sheet answers "canvas", letterbox margins included. They
are not a drawing surface -- the transform refuses to ink there -- but they do
belong to the sheet, and a page turn under the sheet would be worse than
nothing happening.
]]
function JustDraw:regionAt(x, y)
    local overlay = self.session and self.session:overlay()
    if not overlay then
        return self:inBar(x, y) and "bar" or "reader"
    end
    if overlay.bar:contains(x, y) then return "bar" end
    if overlay:inHandle(x, y) then return "handle" end
    if overlay:inSheet(x, y) then return "canvas" end
    return "reader"
end

-- ------------------------------------------------------------------- state

function JustDraw:notify(text)
    UIManager:show(Notification:new{ text = text })
end

--[[--
Say one thing, on the next tick, at most once per pending notice.

Every caller can be reached from inside the stylus callback, where a widget
must not go up, and every one of them can fire per sample -- so the message is
deferred to a tick and coalesced behind `flag`. The drawing generation is the
guard that matters: a notice raised by a lease that has since been replaced
describes a contact that no longer exists. `still_valid` adds whatever else
the caller's surface has to still be true.
]]
function JustDraw:notifyDeferred(flag, text, still_valid)
    if self[flag] then return end
    self[flag] = true
    local generation = self.drawing_generation or 0
    UIManager:nextTick(function()
        self[flag] = false
        if (self.drawing_generation or 0) ~= generation then return end
        if still_valid and not still_valid() then return end
        self:notify(text)
    end)
end

function JustDraw:notifyCanvasBackpressure()
    local active = self.session and self.session:activeCanvas()
    local canvas_id = active and active.id
    self:notifyDeferred("canvas_backpressure_notice_pending",
        _("Stroke was not saved because the write queue is busy. Try again."),
        function()
            local current = self.session and self.session:activeCanvas()
            return self.canvas_open and current ~= nil and current.id == canvas_id
        end)
end

function JustDraw:notifyDocumentBackpressure()
    self:notifyDeferred("document_backpressure_notice_pending",
        _("Stroke was not saved because the write queue is busy. Try again."),
        function() return self.document_session ~= nil end)
end

--[[--
Why a point the pen just made went nowhere.

`notifyDeferred`'s own latch only coalesces one tick's worth, and the tick
between two frame batches is exactly what a contact on a page that cannot take
ink -- a raster still loading, most often, right after a page turn -- spends
its whole length crossing. So the latch here is the contact: armed when one
starts, and spent on the first refused sample of it.
]]
function JustDraw:notifyDocumentRefusal(reason)
    if self.document_refusal_notified then return end
    self.document_refusal_notified = true
    self:notifyDeferred("document_refusal_notice_pending",
        documentMessage(reason),
        function() return self.document_session ~= nil end)
end

--- A new contact may be told again why it is being refused. Called from both
--- routes' contact-down, which is the only place that means "a new one".
function JustDraw:armDocumentRefusalNotice()
    self.document_refusal_notified = false
end

function JustDraw:notifyStrokeBudget()
    self:notifyDeferred("stroke_budget_notice_pending",
        _("Stroke stopped because the pen contact did not end. Lift the pen and try again."))
end

function JustDraw:currentPage()
    return self.view.state.page or 1
end

--[[--
Which capture backend to install, or nil plus a reason.

`auto` falls back to finger rather than to stylus on purpose. The stylus
backend swallows all touch, so picking it on a device with no pen would leave
the user unable to draw at all.

`wacom_protocol` is the only capability flag KOReader offers here and it is
narrow: the three Kindle Scribes and the reMarkable set it, Kobo never does.
Kobo stylus devices report their tool through ABS_MT_TOOL_TYPE instead and do
work, but they have to be opted in with the explicit `stylus` mode, which
deliberately does not require the flag.

isSDL deliberately does *not* widen `auto`. koreader-base does translate SDL3
pen events into the pen slot with a real tool, so a graphics tablet would work
— but a plain mouse goes to slot 0 or 1 with no ABS_MT_TOOL_TYPE at all, so it
never reaches the stylus callback and the residual filter would swallow it.
Auto-selecting stylus in the emulator would mean the mouse could not draw.
Testers with a tablet pick `stylus` by hand.
]]
function JustDraw:resolveInputBackend()
    local mode = self.input_mode
    if mode == "finger" then return "finger" end

    local has_api = Capture:supportsStylus()
    if mode == "stylus" then
        if not has_api then return nil, "no_stylus_api" end
        return "stylus"
    end

    -- A Wacom runtime that does not name its pen slot cannot tell a real
    -- eraser from a palm promoted to MT_TOOL_PALM, so `auto` treats it as a
    -- device without a usable pen rather than guessing per tool value.
    if has_api and Device.input.wacom_protocol == true
        and Capture:validateStylusInput(Device.input) then
        return "stylus"
    end
    return "finger"
end

function JustDraw:reportInputFailure(reason)
    logger.warn("JustDraw: cannot start drawing:", reason)
    self:notify(INPUT_ERRORS[reason] or INPUT_ERRORS.no_gesture_detector)
end

--[[--
Emergency stop after an input handler raised. Capture has already unhooked
itself by the time this runs; this is the plugin-side half. Guarded so a second
call — Capture disarming and the handler disarming again — stays silent.
]]
function JustDraw:disarmInput(err)
    if not self.drawing and self.input_backend == nil then return end
    self:resetStylusTraceContactHistory()
    logger.err("JustDraw: disarming input capture after a handler error:", err)
    self.drawing = false
    self.input_backend = nil
    if self.input_lease then self.input_lease:release() end
    self.input_lease = nil
    self:abortStroke()
    self:resetContacts()
    self:resetStylusState()
    self:notify(INPUT_ERRORS.handler_error)
    if self.bar then self.bar:update(true) end
end

function JustDraw:setDrawing(on)
    on = on and true or false
    if on == self.drawing then return end
    if on and self.canvas_open and self.session and not self.session:isWritable() then
        self:notify(_("This sheet is read-only"))
        return
    end
    if on and self.canvas_open and self.session then
        if self.session:saveFailed() then
            self:notify(_("Could not save ink. Use Retry saving before drawing again."))
            return
        end
        local cache = self.session:cache()
        if not cache or not cache:isReady() then
            self:notify(_("This sheet's ink is still loading"))
            return
        end
    end
    if on and not self.canvas_open and not self.document_session
        and self:legacyInkFrozen() then
        --[[--
        There is nowhere for this reader's ink to go, and arming Draw anyway
        would mean a toolbar saying Stop over a page that swallows every
        point in silence (ADR-39). Refused here rather than at the first
        point, so nothing at all is created: no sheet, no capture, no toolbar
        forced on. Every way in -- the menu entry, the bar's Draw button, the
        dispatcher toggle -- comes through here.

        The two hosts are refused for different reasons and get different
        sentences. A reflowable book has a sheet to offer and the answer is
        the path to it. A fixed layout has page ink and would be using it, so
        the only way here is a session that could not open: the reason it
        reported is what the reader needs, not an instruction they cannot act
        on.
        ]]
        if self.ui.paging then
            self:notify(documentMessage(self.document_open_error or "unavailable"))
        else
            self:notify(LEGACY_FROZEN_EPUB)
        end
        return
    end
    if on and self.document_session then
        -- Before the lease, always: acquiring capture and then discovering
        -- there is nowhere to put the ink leaves the reader drawing into
        -- nothing, and creating the row is a transaction no contact may be
        -- live for.
        local ready, reason = self:prepareDocumentInk()
        if not ready then
            self:notify(documentMessage(reason))
            return
        end
    end

    -- Reusing Wacom's fixed slot/id after a lease replacement is a new
    -- diagnostic epoch even when the old lease never observed a physical
    -- lift. Never let trace deltas bridge that boundary.
    self:resetStylusTraceContactHistory()
    self.drawing_generation = (self.drawing_generation or 0) + 1
    self.legacy_refusal_logged = false

    if on then
        -- Resolve before touching the toolbar: a refusal must not leave the
        -- bar forced on and the preference rewritten.
        local backend, reason = self:resolveInputBackend()
        if not backend then
            return self:reportInputFailure(reason)
        end
        if not self.bar then self:setBarShown(true) end

        local lease
        if backend == "stylus" then
            self:buildStylusMachine(Device.input)
            lease, reason = InputController:acquire(self, {
                backend = "stylus",
                stylus_handler = function(slot) return self:onStylusEvent(slot) end,
                frame_handler = function(slots) return self:onStylusTouchFrame(slots) end,
                has_active_contact = function()
                    return self:hasActivePhysicalContact()
                end,
                on_error = function(err) self:disarmInput(err) end,
            })
        else
            self:releaseStylusMachine()
            lease, reason = InputController:acquire(self, {
                backend = "finger",
                frame_handler = function(slots) return self:onTouchFrame(slots) end,
                has_active_contact = function()
                    return self:hasActivePhysicalContact()
                end,
                on_error = function(err) self:disarmInput(err) end,
            })
        end
        -- Drawing only goes on after a complete install, never before. A
        -- refused lease must not leave a contact machine holding the Input it
        -- was built for; that is exactly what buildStylusMachine forbids.
        if not lease then
            self:releaseStylusMachine()
            return self:reportInputFailure(reason)
        end

        self.input_lease = lease
        self.input_backend = backend
        self.drawing = true
        if self.router then self.router:setBackend(backend) end
        logger.info("JustDraw: drawing on, mode", self.input_mode, "backend", backend)
        self:notePenUnavailable(backend)
    else
        self:abortStroke()
        if self.input_lease then self.input_lease:release() end
        self.input_lease = nil
        self:resetContacts()
        self:resetStylusState()
        self.input_backend = nil
        self.drawing = false
        logger.info("JustDraw: drawing off")
    end
    if self.bar then self.bar:update(true) end
end

--[[--
Say it out loud when a device that has a pen ends up on the finger route.

`auto` needs two things and only reports neither: the runtime's stylus callback
API, and a device that claims a pen digitizer. A Kindle Scribe on KOReader
v2026.03 has the second and not the first, so drawing starts, the finger inks,
the pen does nothing, and nothing on screen connects those facts.

Once per session. Repeating it on every Draw would be nagging about something
the user cannot fix without reflashing.
]]
function JustDraw:notePenUnavailable(backend)
    if backend ~= "finger" or self.pen_notice_shown then return end
    if self.input_mode ~= "auto" then return end
    if Device.input == nil or Device.input.wacom_protocol ~= true then return end
    self.pen_notice_shown = true
    logger.warn("JustDraw: device reports a pen digitizer but this runtime has no stylus API")
    self:notify(INPUT_ERRORS.pen_unavailable)
end

function JustDraw:setInputMode(mode)
    if not INPUT_MODES[mode] or mode == self.input_mode then return true end
    -- The menu item is disabled while drawing, but the guard belongs here:
    -- swapping backends inside a live contact sequence tears down capture
    -- mid-stroke, and the menu is not the only possible caller.
    if self.drawing then
        logger.warn("JustDraw: refusing to change input mode while drawing")
        return nil, "contact_active"
    end
    local function apply()
        self.input_mode = mode
        Compat.saveSetting(G_reader_settings, "input_mode", mode)
    end
    if self.notebooks and self.notebooks:activeSession() then
        local changed, change_err = self.notebooks:reconfigureInput(apply)
        if not changed then return nil, change_err end
    else
        apply()
    end
    logger.info("JustDraw: input mode set to", mode)
    return true
end

function JustDraw:setEraser(on)
    if on and self.canvas_open and self.session and not self.session:isWritable() then
        self:notify(_("This sheet is read-only"))
        return
    end
    self.eraser = on and true or false
    if not self.eraser then
        self:endCanvasErase()
        self.direct_erase_x, self.direct_erase_y = nil, nil
    end
    if self.eraser and not self.drawing then
        self:setDrawing(true)   -- also updates the bar
    elseif self.bar then
        self.bar:update(true)
    end
end

function JustDraw:resetContacts()
    for slot in pairs(self.contacts) do
        self.contacts[slot] = nil
    end
    self.n_contacts = 0
    self.passthrough = false
    self.draw_slot = nil
    self.contact_style = nil
    -- Callers reach this with capture released, made inert, or -- in
    -- abandonBlindContact -- still installed but with KOReader's own contacts
    -- already dropped underneath it by Input:resetState. In all three nothing
    -- is owed a lift any more, so ownership ends here and a reused slot starts
    -- unclassified rather than inheriting a decision made for a contact that
    -- no longer exists.
    if self.router then self.router:reset() end
end

--[[--
Build this lease's pen machine over one Input.

`input` is read once, here, rather than per sample: the slot classifier, the
Wacom proximity rule and the finger-tool constant all describe the device we
are about to hook, and re-reading Device.input from inside the callback would
let a lease outlive the thing it was built for.

The three parts are shared with the notebook route on purpose. A second copy
of the pen state machine is how the surfaces came to disagree about what a
Scribe palm is.
]]
function JustDraw:buildStylusMachine(input)
    self.capture_input = input
    self.stylus_geometry = StylusGeometry.new(Capture:penSlotPosition(input))
    self.palm_gate = PalmGate.new{
        classify = function(slot) return Capture:physicalSlotRole(slot, input) end,
        retire_touch = function(slot_number) self:retireTouchSlot(slot_number) end,
    }
    self.stylus_sequence = StylusSequence.new{
        wacom_protocol = input ~= nil and input.wacom_protocol == true,
        pen_slot = input and input.pen_slot,
        tool_finger = input and input.TOOL_TYPE_FINGER or 0,
        to_screen = Capture.toScreen,
        max_open_points = self.max_open_points,
        max_contact_samples = self.max_contact_samples,
        geometry = self.stylus_geometry,
        classify = function(x, y, tool, coherent)
            return self:classifyStylusContact(x, y, tool, coherent)
        end,
        on_contact_start = function() return self:onStylusContactStart() end,
        on_point = function(x, y, tool, is_first)
            return self:onStylusPoint(x, y, tool, is_first)
        end,
        on_finish = function(reason) return self:onStylusFinish(reason) end,
        on_abort = function(reason) return self:onStylusAbort(reason) end,
        on_contact_end = function(reason) return self:onStylusContactEnd(reason) end,
        -- Increments two integers; cannot raise inside the raw callback.
        on_pending_finish = function(kind)
            Capture:noteCollapsedContact(kind)
        end,
        on_domain_error = function(reason, phase)
            logger.warn("JustDraw: stylus contact reported", reason, phase)
        end,
        drop_contact = function(slot) return Capture:dropContact(slot) end,
    }
    self.trace_instance = self:activeStylusTrace(self:diagnosticSource())
    self.stylus_sequence:setTrace(self.trace_instance)
    self.stylus_budget_notified = false
    return self.stylus_sequence
end

function JustDraw:releaseStylusMachine()
    self.stylus_sequence = nil
    self.palm_gate = nil
    self.stylus_geometry = nil
    self.capture_input = nil
    self.trace_instance = nil
    self.stylus_budget_notified = false
end

--[[--
End this lease's pen state.

Reached with capture already released or made inert, so a contact still
forwarded to GestureDetector will never see its physical lift here; retire it
explicitly rather than leaving a pending hold timer behind. The geometry
baseline goes with the lease: nothing about the coordinates of the old Input
describes the next one.
]]
function JustDraw:resetStylusState()
    local sequence = self.stylus_sequence
    if sequence then
        local forwarded = sequence:forwardedSlot()
        if forwarded ~= nil then Capture:dropContact(forwarded) end
        sequence:abort("reset", true)
    end
    if self.palm_gate then self.palm_gate:reset() end
    self:releaseStylusMachine()
end

--[[--
Is anything still on the glass?

The lease asks this before letting a notebook take the capture over, and every
term was a way to answer it wrongly: a trusted pen, a pen handed to the UI, a
palm the tool-based bookkeeping used to lose track of at its lift, and ordinary
touch on either route.
]]
function JustDraw:hasActivePhysicalContact()
    local sequence = self.stylus_sequence
    if sequence and (sequence:hasOwnedPhysicalContact()
        or sequence:hasForwardedContact()) then
        return true
    end
    if self.palm_gate and self.palm_gate:hasActiveContact() then return true end
    if self.n_contacts > 0 then return true end
    return self.router ~= nil and self.router:touchCount() > 0
end

--- A touch slot has just been promoted to a palm. Give back everything the
--- ordinary touch route had already granted it, exactly once.
function JustDraw:retireTouchSlot(slot_number)
    local forwarded = false
    local router = self.router
    if self.canvas_open and router then
        local dest = router:destinationOf(slot_number)
        forwarded = dest ~= nil and dest ~= "palm"
        router:touchUp(slot_number)
    end
    if self.contacts[slot_number] ~= nil then
        -- The direct route hands every touch frame to GestureDetector and
        -- suppresses per gesture at the widget layer, so a counted contact is
        -- always one the detector has already opened.
        forwarded = true
        self.contacts[slot_number] = nil
        self.n_contacts = self.n_contacts - 1
        if self.n_contacts <= 0 then
            self.n_contacts = 0
            self.passthrough = false
        end
        if self.draw_slot == slot_number then
            self:endStroke()
            self.draw_slot = nil
        end
    end
    if forwarded then Capture:dropContact(slot_number) end
end

function JustDraw:onJustDrawToggle()
    self:setDrawing(not self.drawing)
    return true
end

function JustDraw:onJustDrawEraser()
    self:setEraser(not self.eraser)
    return true
end

-- ------------------------------------------------------------------- input

--[[--
Called on every touch frame while drawing mode is on, before GestureDetector
sees it. Capture only: it reads contacts to draw from and maintains the
passthrough latch. Since ADR-13 what reaches the app is decided per gesture in
InkBar:suppresses, so this always returns true.
]]
function JustDraw:onTouchFrame(slots)
    if self.canvas_open then
        local kept = self:routeCanvasFinger(slots)
        self:_flushPendingCanvasCaptureStop()
        return kept
    end

    if not self.passthrough and self:dialogOnTop() then
        -- Latches for the whole contact sequence, and re-latches on the next
        -- one, so drawing resumes by itself once the dialog is gone.
        self.passthrough = true
        self:abortStroke()
    end

    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev.slot or 0
        local id = ev.id

        if id and id >= 0 then
            if not self.contacts[slot] then
                self.contacts[slot] = true
                self.n_contacts = self.n_contacts + 1
                if self.n_contacts > 1 and not self.passthrough then
                    self.passthrough = true
                    self:abortStroke()
                end
            end
            if not self.passthrough and ev.x and ev.y then
                self:onContactPoint(slot, ev.x, ev.y)
            end
        else
            if self.contacts[slot] then
                self.contacts[slot] = nil
                self.n_contacts = self.n_contacts - 1
            end
            if self.n_contacts <= 0 then
                self.n_contacts = 0
                if not self.passthrough then
                    self:endStroke()
                end
                self.passthrough = false
                self.draw_slot = nil
            end
        end
    end

    self:_flushPendingDocumentCaptureStop()
    return true
end

--- Finger route. `tool` is always nil here and exists only so both backends
--- share one entry point; see applyPoint.
function JustDraw:onContactPoint(slot, raw_x, raw_y, tool)
    local x, y = Capture.toScreen(raw_x, raw_y)

    if self.draw_slot == nil then
        if self:inBar(x, y) then
            -- Contact started on the toolbar: hand the whole sequence to
            -- GestureDetector so the button gets its tap.
            self.passthrough = true
            self:abortStroke()
            return
        end
        self:armDocumentRefusalNotice()
        self.draw_slot = slot
    elseif self.draw_slot ~= slot then
        return
    end

    if self:inBar(x, y) then
        -- Dragged onto the toolbar. End the stroke at the edge rather than
        -- painting over the buttons.
        self:endStroke()
        self.draw_slot = SUSPENDED
        return
    end

    self:applyPoint(x, y, tool)
end

--[[--
The single place that decides ink versus erase, shared by both backends.

`tool` is whatever KOReader reported for this contact, or nil on the finger
route. A physical eraser wins over the toolbar's setting; everything else —
pen, highlighter, and the TOOL_TYPE_FINGER a pen slot reports on its way out of
proximity — defers to it.
]]
function JustDraw:applyPoint(x, y, tool)
    if self.canvas_open then return self:applyCanvasPoint(x, y, tool) end
    if self.document_session then
        -- On a fixed layout Draw means the page-ink surface and nothing else
        -- (ADR-39). A surface that cannot take this point refuses it here
        -- rather than letting the contact fall through into the sidecar,
        -- where the coordinates would be screen pixels nothing can map back
        -- to the page once the zoom moves.
        local active, reason = self:documentInkActive()
        if active then return self:applyDocumentPoint(x, y, tool) end
        -- Refusing in silence with Stop still on the toolbar is the one thing
        -- worse than refusing: deferred and coalesced, so the sentence costs
        -- one notification and not one per sample.
        self:notifyDocumentRefusal(reason)
        return false
    end
    -- The sidecar is frozen from v2026.07 (ADR-39). Every other route above
    -- has already had its chance at this contact; what is left below writes
    -- screen pixels into the document's settings, and on this runtime nothing
    -- may do that -- not a book whose sheet database would not open, and not a
    -- page whose ink surface was refused.
    if self:legacyInkFrozen() then return self:refuseLegacyPoint() end
    if tool == Capture.TOOL_ERASER or self.eraser then
        self:eraseAt(x, y)
    elseif self.stroke then
        self:addPoint(x, y)
    else
        self:startStroke(x, y, self.contact_style or self:effectiveStyle(tool))
    end
end

-- ------------------------------------------------------------- stylus input

--[[--
Called for every slot KOReader routes to us, before gesture detection.
Returning true dominates the slot: KOReader drops it from MTSlots and the
gesture detector never sees it.

Classification comes first, and that ordering is the whole point.
`Input:routeStylusEvents` routes any slot whose tool is PEN, ERASER or
HIGHLIGHTER, and Linux gives a rejected touch MT_TOOL_PALM, which is the same
number as ERASER. So on a Kindle Scribe a resting hand arrives here looking
exactly like the rear eraser, and a physical trace shows it running the erase
path over a page of somebody's notes. InkWacomPalm answers "is this the pen?"
before InkStylusSequence is allowed to answer anything at all.

Two properties of the slot data shape everything downstream, and both are easy
to get wrong (c.f. frontend/device/input.lua:1381-1450):

  * the table is Input's own persistent `ev_slots[n]`, reused frame after
    frame, so `id`, `x` and `y` all survive a contact lift. Only transitions of
    `id` open and close strokes, and X and Y are written independently, which
    is why InkStylusGeometry has to prove a pair before it is drawn from.
  * `tool` can be TOOL_TYPE_FINGER on the pen slot, because leaving proximity
    writes exactly that, and the slot is still routed here by slot number. So
    `tool` picks ink-or-erase, never draw-or-not.
]]
function JustDraw:onStylusEvent(slot)
    local trace = self:syncStylusTrace()
    local gate = self.palm_gate
    if gate then
        local handled, _dominate, _decision, reason = gate:routeStylus(slot)
        if handled then
            -- Dominated before any host state exists. A palm must not become
            -- ink, an erase, a dirty box, a queued write, or a baseline the
            -- next pen contact is measured against.
            if trace and self.stylus_sequence then
                self.stylus_sequence:tracePalm(slot, reason)
            end
            return true
        end
    end
    local sequence = self.stylus_sequence
    if not sequence then return true end
    return sequence:feed(slot)
end

--- Publish the active bounded trace to the sequence once per change. The
--- source can flip mid-lease when a sheet opens, and a trace recorded for the
--- other surface must not be continued into this one.
function JustDraw:syncStylusTrace()
    local trace = self:activeStylusTrace(self:diagnosticSource())
    if trace ~= self.trace_instance then
        self.trace_instance = trace
        if self.stylus_sequence then self.stylus_sequence:setTrace(trace) end
    end
    return trace
end

function JustDraw:afterStylusFrame()
    if self.stylus_sequence then self.stylus_sequence:afterFrame() end
end

--[[--
What a trusted pen contact means, decided on its first coherent point and
latched for the rest of the sequence.

"pass" is what keeps Stop pressable with a pen: the toolbar, the sheet's resize
handle and a dialog all need their taps, so those contacts go to
GestureDetector untouched. Over the book's text with a sheet open the pen stays
dominated -- the palm rule depends on it and no page may turn under the
reader's hand -- but the text is not a drawing surface in v1, so it blocks.

`coherent` is false when InkStylusGeometry is asking only whether this contact
belongs to somebody else, from a pair it would not draw from. Nothing may latch
on that: the router's pen destination decides where the *stroke* goes and
cancels resting fingers with it, so it waits for a pair the policy vouches for.
]]
function JustDraw:classifyStylusContact(x, y, tool, coherent)
    if self:captureStopPending() then return "block" end
    if self.canvas_open and self.router and coherent then
        self.router:penContact(x, y)
    end
    if self:dialogOnTop() then return "pass" end
    if self:penPassesThrough(x, y) then return "pass" end
    if not coherent then return "draw", "ink" end
    if self.canvas_open and self.router and not self.router:penDraws() then
        return "block"
    end
    if tool == Capture.TOOL_ERASER then
        -- Once per contact, and only for a tool the pen reported: the toolbar
        -- toggle below is our own state and says nothing about the hardware.
        Capture:noteEraserContact(self.capture_input)
        return "draw", "erase"
    end
    if self.eraser then return "draw", "erase" end
    return "draw", "ink"
end

function JustDraw:onStylusContactStart()
    self.stylus_budget_notified = false
    self:armDocumentRefusalNotice()
    -- Latch here, not at the first drawable point: the geometry policy can
    -- withhold several frames proving a coherent pair, and a manual style
    -- change in that window must not reach a contact already under way.
    self.contact_style = self:effectiveStyle(
        self.stylus_sequence and self.stylus_sequence.current_tool)
    if self.canvas_open and self.router then
        -- The pen is on the page from this frame, even though where is not
        -- known yet. A finger arriving in that window is no less of a palm.
        self.router:penContact(nil, nil)
    end
    return true
end

--[[--
One accepted point from the pen.

Where the contact started is already settled by the classification latch, so
the only cases left are a stroke dragged *onto* the toolbar, which ends at the
edge rather than scribbling over the buttons, and a dialog that appeared after
the contact began, which stops the ink without handing the slot back.
]]
function JustDraw:onStylusPoint(x, y, tool, is_first)
    if self:captureStopPending() then return "abort_suspend" end
    if not is_first and self:dialogOnTop() then return "abort_suspend" end

    if self.canvas_open then
        local region = self:regionAt(x, y)
        if region == "bar" or region == "handle" then
            return "finish_suspend"
        end
        self:applyCanvasPoint(x, y, tool)
        return "continue"
    end

    if self:inBar(x, y) then return "finish_suspend" end
    self:applyPoint(x, y, tool)
    return "continue"
end

--- Both budgets mean the same thing to the reader -- the contact never ended
--- -- and repeating it per sample would be worse than saying nothing.
function JustDraw:noteStylusBudget(reason)
    if reason ~= "point_budget" and reason ~= "sample_budget" then return end
    if self.stylus_budget_notified then return end
    self.stylus_budget_notified = true
    self:notifyStrokeBudget()
end

function JustDraw:onStylusFinish(reason)
    self:noteStylusBudget(reason)
    self:endStroke()
    return true
end

function JustDraw:onStylusAbort(reason)
    self:noteStylusBudget(reason)
    self:abortStroke()
    return true
end

function JustDraw:onStylusContactEnd()
    self.contact_style = nil
    if self.router then self.router:penUp() end
    return true
end


--[[--
Whether a pen contact starting here belongs to somebody else.

With no sheet open that is the toolbar and nothing else, exactly as before.
With one open the resize handle joins it: dragging the sheet with the pen has
to work, and a stroke is not what the reader meant there.
]]
function JustDraw:penPassesThrough(x, y)
    if self.canvas_open then
        local region = self:regionAt(x, y)
        return region == "bar" or region == "handle"
    end
    return self:inBar(x, y)
end

--[[--
Why the pen route is or is not running, in one place.

This is the first thing to look at when the pen does nothing. The symptom on
its own already says a lot -- if a finger draws, the effective backend is
`finger`, because the stylus route never inks touch -- but it does not say
*which* precondition failed, and there are three.

Deliberately callable with drawing off and no backend installed. That is the
only state anybody is in when they ask this question.
]]
function JustDraw:diagnosticReport()
    local input = Device.input or {}
    local backend, reason = self:resolveInputBackend()
    -- Guarded: the revision is the first line of a bug report and the last
    -- thing that should be able to stop one being written. A build that
    -- cannot answer it still has to be able to show the rest.
    local named, revision = pcall(function() return Version:getCurrentRevision() end)
    local r = {
        version   = named and revision or nil,
        capabilities = self.capabilities or Compat.capabilities(),
        model     = Device.model,
        mode      = self.input_mode,
        backend   = backend,
        reason    = reason,
        stylus_api = Capture:supportsStylus(),
        wacom     = input.wacom_protocol == true,
        pen_slot  = input.pen_slot,
        tool_types = input.TOOL_TYPE_PEN ~= nil,
        -- Our own active lease is not a foreign owner, and reporting it as
        -- one sent readers chasing a plugin conflict that did not exist.
        callback_taken = self:stylusCallbackIsForeign(input),
    }
    r.eraser_by_button, r.eraser_by_tool = Capture:eraserCounts()
    r.collapsed_dots, r.collapsed_discards = Capture:collapsedCounts()
    r.steered_pen, r.steered_panel, r.evdev_drops = Capture:steerCounts()

    -- The first unmet precondition, in the order the user can act on them.
    if r.mode == "finger" then
        r.blocker = _("Input mode is set to Finger. Set it to Automatic or Stylus.")
    elseif not r.stylus_api then
        r.blocker = _("This KOReader has no stylus API. The pen route needs v2026.07 or newer.")
    elseif r.callback_taken and backend ~= "stylus" then
        r.blocker = _("Another plugin already owns the stylus input callback.")
    elseif backend ~= "stylus" then
        r.blocker = _("This device does not report a pen digitizer. Set Input mode to Stylus by hand.")
    end
    return r
end

--- yes/no, because this line is read by someone comparing two devices, and
--- `true`/`nil` reads as "the field is missing" rather than "the runtime is".
local function capabilityWord(value)
    return value and "yes" or "no"
end

--- The report as lines, for the log and for the on-screen message.
function JustDraw:diagnosticLines()
    local r = self:diagnosticReport()
    local caps = r.capabilities or {}
    local lines = {
        "KOReader: " .. tostring(r.version),
        "Device: " .. tostring(r.model),
        -- The runtime's own answer to "which JustDraw is this" (ADR-41). No
        -- feature is version-string-gated, so the revision above is a label
        -- and this line is the fact: stylus API is the gate for the new
        -- surfaces, and the other three would be a build to report.
        "Capabilities: stylus API: " .. capabilityWord(caps.stylus_api)
            .. "   page transform: " .. capabilityWord(caps.view_transform)
            .. "   native page size: " .. capabilityWord(caps.native_dimensions)
            .. "   alpha overlay: " .. capabilityWord(caps.alpha_blit),
        "Input mode: " .. tostring(r.mode) .. "  ->  backend: " .. tostring(r.backend),
        "Stylus API: " .. tostring(r.stylus_api)
            .. "   tool types: " .. tostring(r.tool_types),
        "Pen digitizer flag: " .. tostring(r.wacom)
            .. "   pen slot: " .. tostring(r.pen_slot),
        "Callback owned by another plugin: " .. tostring(r.callback_taken),
        -- Splits erases by where the ERASER tool came from. KOReader never
        -- writes PEN back after a barrel-button press (Capture:eraserToolSource),
        -- so a session that erased with the button once and then reports a
        -- growing "by tool value" count with no rear-eraser use is looking at
        -- that stuck value, not at a plugin decision.
        "Erases by held pen button: " .. tostring(r.eraser_by_button)
            .. "   by tool value: " .. tostring(r.eraser_by_tool),
        -- A contact that never proves its geometry finishes as at most a dot
        -- (ADR-22). A deliberate tap lands here by design, so the number is
        -- "contacts that ended as one dot", not "defects" -- what diagnoses a
        -- collapsed underline is this growing while the reader wasn't dotting.
        -- A hand-drawn stroke wobbles enough that it never lands here.
        "Pen contacts ending as a single dot: " .. tostring(r.collapsed_dots)
            .. "   with no position: " .. tostring(r.collapsed_discards),
        -- Frames the slot steer had to move (ADR-25). Growing "pen frames"
        -- means the hand was holding the cursor; growing "hand frames" means
        -- the panel omitted ABS_MT_SLOT with the pen in range. Either would
        -- have been a lost stroke or an erase before the steer. "dropped" is
        -- the kernel's own overflow count: with ADR-26 it should stay at 0.
        "Pen frames steered back to the pen slot: " .. tostring(r.steered_pen),
        "Hand frames kept off the pen slot: " .. tostring(r.steered_panel),
        "Input events the kernel dropped: " .. tostring(r.evdev_drops),
    }
    if r.blocker then lines[#lines + 1] = "" ; lines[#lines + 1] = r.blocker end
    return lines, r
end

function JustDraw:diagnosticSource()
    if self.canvas_open then return "epub_canvas" end
    if self.document_session then return "page_ink" end
    return "direct"
end

function JustDraw:startDiagnostics(source, opts)
    source = source or self:diagnosticSource()
    opts = opts or {}
    if self.stylus_trace and self.stylus_trace:isActive() then
        self.stylus_trace:stop("reset")
    end
    local lines = self:diagnosticLines()
    for i = 1, #lines do
        if lines[i] ~= "" then logger.info("JUSTDRAW-DIAG", lines[i]) end
    end
    local emit = opts.emit or function(line) logger.info(line) end
    self.stylus_trace = StylusTrace.new{
        source = source,
        emit = emit,
        now = opts.now,
        duration_seconds = opts.duration_seconds,
        max_events = opts.max_events,
    }
    self.trace_source = source
    -- The sequence owns event/frame ordinals; publishing the new trace resets
    -- them and starts a fresh contact epoch in one place.
    self:syncStylusTrace()
    emit("JUSTDRAW-STYLUS trace_start source=" .. source)
    return lines
end

function JustDraw:activeStylusTrace(source)
    local trace = self.stylus_trace
    if not trace or not trace:isActive() then
        self.stylus_trace = nil
        return nil
    end
    if source and trace.source ~= source then return nil end
    return trace
end

function JustDraw:resetStylusTraceContactHistory()
    local trace = self.stylus_trace
    if trace and type(trace.resetContactHistory) == "function" then
        trace:resetContactHistory()
    end
end

--- Correct the one diagnostic line that could accuse JustDraw of the problem
--- it is reporting: our own registered callback is not a foreign owner.
function JustDraw:stylusCallbackIsForeign(input)
    local callback = input and input.stylus_callback
    if callback == nil then return false end
    return callback ~= Capture.stylus_callback
end

--- Warn before coordinates enter the local log, then show the capability report.
function JustDraw:showDiagnostics(source)
    local dialog
    dialog = ConfirmBox:new{
        text = _("Pen coordinates will be written to the local KOReader log for up to 60 seconds. JustDraw does not upload them; shared logs may contain them. Turn KOReader's debug logging off again afterwards: it records all raw input and the file grows very quickly."),
        ok_text = _("Start"),
        ok_callback = function()
            UIManager:close(dialog)
            local lines = self:startDiagnostics(source)
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        end,
    }
    UIManager:show(dialog)
    return dialog
end

--[[--
Residual contact bookkeeping for the stylus backend.

Runs after onStylusEvent within the same input frame, because
Input:routeStylusEvents is called immediately before feedEvent in every
handleTouchEv variant. So the pen's decision for this frame is already made and
a dominated pen slot is already gone from `slots`. That ordering is what lets
this function promise never to touch `self.stroke` — a palm landing mid-stroke
is precisely what the stylus backend exists to ignore.

Since ADR-13 it does not decide what gets emitted. Suppression lives in
InkBar:suppresses, per gesture and by position. What stays here is the state
that decision reads: how many non-pen contacts are down, and whether any of them
started on the toolbar. Always returns true.
]]
function JustDraw:onStylusTouchFrame(slots)
    if self.canvas_open then
        local kept = self:routeCanvasTouch(slots)
        self:afterStylusFrame()
        self:_flushPendingCanvasCaptureStop()
        return kept
    end

    if not self.passthrough and self:dialogOnTop() then
        self.passthrough = true
    end

    local gate = self.palm_gate
    local input = self.capture_input
    -- A promoted palm has to be withheld from the frame, not merely excluded
    -- from the contact count. Returning the whole frame gave the detector back
    -- the contact this route had just dropped, one frame later, hold timer and
    -- all -- and while a dialog latches passthrough, that palm's tap reaches
    -- the dialog. Everything else travels exactly as it always did; ADR-13
    -- still decides per gesture at the widget layer.
    local kept = {}
    for i = 1, #slots do
        local ev = slots[i]
        local palm = gate ~= nil and gate:filterResidual(ev)
        if not palm then kept[#kept + 1] = ev end
        if not palm
            and Capture:physicalSlotRole(ev, input) ~= "trusted_stylus" then
            local slot = ev.slot or 0
            local id = ev.id

            if id and id >= 0 then
                if not self.contacts[slot] then
                    -- "new" until this contact's first frame with coordinates
                    -- says where it started. The latch is per slot: a palm
                    -- that landed off the toolbar must not answer for the
                    -- finger reaching for Stop, which is the only way out.
                    self.contacts[slot] = "new"
                    self.n_contacts = self.n_contacts + 1
                end
                if self.contacts[slot] == "new" and ev.x and ev.y then
                    local x, y = Capture.toScreen(ev.x, ev.y)
                    if self:inBar(x, y) then
                        self.contacts[slot] = "bar"
                        self.passthrough = true
                    else
                        self.contacts[slot] = "page"
                    end
                end
            else
                if self.contacts[slot] then
                    self.contacts[slot] = nil
                    self.n_contacts = self.n_contacts - 1
                end
                if self.n_contacts <= 0 then
                    self.n_contacts = 0
                    self.passthrough = false
                end
            end
        end
    end

    self:afterStylusFrame()
    self:_flushPendingDocumentCaptureStop()
    return kept
end

-- --------------------------------------------------------- canvas routing

--[[--
Residual touch while a sheet is open, on the pen route.

Slots the router calls palms are withheld from GestureDetector entirely -- down
frame and lift alike. Withholding only the down would leave the detector a lift
for a contact it never opened; withholding neither would let a palm's `hold`
reach the book, and a gesture carries no slot number, so by then there is
nothing left to tell it from the reader's own.

A contact whose first frame carried no coordinates has already gone through by
the time the next one places it. `dropContact` retires that one, per slot, so a
finger on the toolbar is untouched.
]]
function JustDraw:routeCanvasTouch(slots)
    local router = self.router
    if not router then return true end

    local kept = {}
    local gate = self.palm_gate
    local input = self.capture_input
    for i = 1, #slots do
        local ev = slots[i]
        if gate and gate:filterResidual(ev) then
            -- A promoted palm reaches nothing: not the detector, not the
            -- router, not the sheet.
        elseif Capture:physicalSlotRole(ev, input) == "trusted_stylus" then
            -- A pen slot handed back to the UI is not residual touch.
            kept[#kept + 1] = ev
        else
            local slot = ev.slot or 0
            local id = ev.id
            if id and id >= 0 then
                local before = router:destinationOf(slot)
                local sx, sy
                if ev.x and ev.y then sx, sy = Capture.toScreen(ev.x, ev.y) end
                local dest = router:touchContact(slot, sx, sy)
                if dest == "palm" then
                    if before == nil then Capture:dropContact(slot) end
                else
                    kept[#kept + 1] = ev
                end
            else
                local dest = router:destinationOf(slot)
                router:touchUp(slot)
                if dest ~= "palm" then kept[#kept + 1] = ev end
            end
        end
    end

    for _, slot in ipairs(router:takeCancelled()) do
        Capture:dropContact(slot)
    end
    return kept
end

--[[--
Touch while a sheet is open, on the finger route.

A single contact on the sheet draws; everything else -- the toolbar, the
handle, the book above the sheet -- goes to GestureDetector as usual, which is
what keeps page turning alive. A second contact landing on the sheet abandons
the stroke and hands both back, the same bargain ADR-3 makes for direct ink.
]]
function JustDraw:routeCanvasFinger(slots)
    local router = self.router
    if not router then return true end

    local kept = {}
    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev.slot or 0
        local id = ev.id
        if id and id >= 0 then
            local sx, sy
            if ev.x and ev.y then sx, sy = Capture.toScreen(ev.x, ev.y) end
            local dest = router:touchContact(slot, sx, sy)
            if dest == "canvas" then
                if self.draw_slot == nil then
                    self.draw_slot = slot
                elseif self.draw_slot ~= slot then
                    self:abortCanvasStroke()
                    self.draw_slot = SUSPENDED
                end
                if self.draw_slot == slot and sx then
                    self:applyCanvasPoint(sx, sy, nil)
                end
            else
                kept[#kept + 1] = ev
            end
        else
            local dest = router:destinationOf(slot)
            router:touchUp(slot)
            if self.draw_slot == slot then
                self:endCanvasStroke()
                self.draw_slot = nil
            elseif self.draw_slot == SUSPENDED and router:touchCount() == 0 then
                self.draw_slot = nil
            end
            if dest ~= "canvas" then kept[#kept + 1] = ev end
        end
    end
    return kept
end

-- ------------------------------------------------------------------ stroke

--[[--
Whether this reader may still add to the sidecar (ADR-39).

Two things have to be true for the answer to be "no". The first is the
runtime: `stylus_api` is the one discriminator (ADR-41), and on v2026.03 every
line below behaves exactly as it always did, which is what the pre-existing
suite proves. The second is that this reader has a surface of its own to offer
instead -- a rolling reader has drawing sheets, a paging one has page ink --
because refusing the reader's ink while offering nowhere to put it would be a
worse plugin than the one that stored screen pixels.

ReaderUI is always one or the other, and registers whichever it is before it
loads a plugin (readerui.lua:297 and :382, plugins at :464). The pair is read
at the call rather than latched in `init` so a host that registers its route
later cannot leave a stale answer behind.
]]
function JustDraw:legacyInkFrozen()
    if not self.legacy_frozen then return false end
    return self.ui.rolling ~= nil or self.ui.paging ~= nil
end

--[[--
Refuse a point the frozen sidecar would otherwise have swallowed.

Reached only if something upstream let a contact through with no surface to
put it on -- a fixed layout whose database would not open, say. It is a
defect, not a reader error, so it goes to the log and not to the screen: the
reader has already been told why page ink is unavailable by the path that
refused it. Once per drawing session, because this is per point.
]]
function JustDraw:refuseLegacyPoint()
    if not self.legacy_refusal_logged then
        self.legacy_refusal_logged = true
        logger.warn("JustDraw: direct ink is frozen on this runtime;",
            "a point was refused rather than written to the sidecar (ADR-39)")
    end
    return false
end

function JustDraw:startStroke(x, y, style)
    style = Style.normalize(style)
    self.stroke = {
        n = 1, w = self.pen_width * Style.widthScale(style), t = style, x, y,
    }
end

function JustDraw:addPoint(x, y)
    local s = self.stroke
    local i = s.n * 2
    local px, py = s[i - 1], s[i]
    if px == x and py == y then return true end
    if s.n >= (self.max_open_points or Limits.MAX_OPEN_POINTS) then
        -- The pen route reaches its budget inside InkStylusSequence, which
        -- aborts and suspends the contact itself; this is the finger route's
        -- half of the same rule.
        self:abortStroke()
        self.draw_slot = SUSPENDED
        self:notifyStrokeBudget()
        return false
    end

    s[i + 1] = x
    s[i + 2] = y
    s.n = s.n + 1

    local painted, left, top, right, bottom =
        Render.segment(Screen.bb, px, py, x, y, s.w, Style.colorFor(s.t, INK))
    -- Direct ink has no raster to remember gray content, so the pass is
    -- chosen per stroke, by its own style (ADR-36).
    if painted then
        self:refreshBox(left, top, right, bottom, Style.isGray(s.t))
    end
    return true
end

--- Ends whichever stroke is in progress. Every caller -- the pen lift, a
--- dialog opening mid-stroke, Stop -- means "finish what is being drawn", and
--- what that is depends on whether a sheet is open.
function JustDraw:endStroke()
    if self.canvas_open then return self:endCanvasStroke() end
    -- Not an `elseif`: with a page-ink session open the direct route holds
    -- nothing, and running both is what keeps a session that appeared or went
    -- away mid-contact from stranding the other one's stroke.
    if self.document_session then self:endDocumentStroke() end
    self.direct_erase_x, self.direct_erase_y = nil, nil

    local s = self.stroke
    self.stroke = nil
    self.draw_slot = nil
    if not s then return end
    -- The second half of the freeze, and the one that matters: `applyPoint`
    -- decides, but below this line is the only thing in the file that grows
    -- the sidecar, and a stroke that somehow started must not be persisted
    -- (ADR-39). Before the dot, not after: painting a point that is then
    -- refused puts ink on the panel that the next refresh takes away again.
    if self:legacyInkFrozen() then return self:refuseLegacyPoint() end

    if s.n == 1 then -- a dot: never painted live, paint it now
        local painted, left, top, right, bottom =
            Render.stroke(Screen.bb, s, 0, 0, Style.colorFor(s.t, INK))
        if painted then
            self:refreshBox(left, top, right, bottom, Style.isGray(s.t))
        end
    end
    self.store:add(self:currentPage(), s)
end

--- Gives up whichever stroke is in progress. See endStroke.
function JustDraw:abortStroke()
    if self.canvas_open then
        self.draw_slot = nil
        return self:abortCanvasStroke()
    end
    if self.document_session then self:abortDocumentStroke() end
    self.direct_erase_x, self.direct_erase_y = nil, nil
    if not self.stroke then
        self.draw_slot = nil
        return
    end
    self.stroke = nil
    self.draw_slot = nil
    self:repaint()
end

--[[--
One eraser sample on the page itself.

The capsule from the previous sample is what a fast hand needs: strokes
between two samples are cut, not skipped. The anchor is per contact --
endStroke and abortStroke forget it -- so a new touch never inherits a sweep
from wherever the last one lifted.
]]
function JustDraw:eraseAt(x, y)
    local page = self:currentPage()
    local x0 = self.direct_erase_x or x
    local y0 = self.direct_erase_y or y
    self.direct_erase_x, self.direct_erase_y = x, y
    if self.store:sweep(page, x0, y0, x, y, ERASER_RADIUS) then
        self:repaint()
    end
end

-- ------------------------------------------------------------- canvas ink

--[[--
Open a sheet, taking the toolbar with it.

There is never more than one JustDraw window: the standalone toolbar steps
down and the overlay's embedded one takes its place, so `self.bar` keeps
meaning "the toolbar the reader can see" everywhere else in this file.
]]
function JustDraw:openCanvas(canvas)
    if not (self.session and canvas) then return end
    if self.canvas_open and self.session:activeCanvas() == canvas then return end

    local switching = self.canvas_open
    if switching then
        -- Session may refuse to close the old sheet. Stop capture first, but
        -- leave its embedded toolbar/window owned by the old overlay until the
        -- durable switch succeeds.
        self:abortCanvasStroke()
        self:setDrawing(false)
    else
        self.bar_restore = self.bar ~= nil
    end
    if not switching and self.bar then
        local dimen = self.bar.dimen
        UIManager:close(self.bar)
        self.bar = nil
        UIManager:setDirty(self.ui, "ui", dimen)
    end

    local overlay, err = self.session:openCanvas(canvas)
    if not overlay then
        if switching then
            local old = self.session:overlay()
            if old then
                self.bar = old.bar
            else
                self.canvas_open = false
                self.bar = nil
                if self.bar_restore then self:setBarShown(true) end
            end
        elseif self.bar_restore then
            self:setBarShown(true)
        end
        return nil, err
    end
    self.canvas_pending_repaint = nil
    self.bar = overlay.bar
    self.canvas_open = true
    if self.router then self.router:reset() end
    if self.session:isWritable() and self.session:cache():isReady() then
        self:setDrawing(true)
    end
    return overlay
end

--- Overlay replaces its embedded toolbar whenever geometry or side changes.
--- Keep `self.bar` bound to the visible object; all state and input routing in
--- this module intentionally go through that single owner reference.
function JustDraw:onCanvasOverlayBarChanged(overlay)
    local current = self.session and self.session:overlay()
    if self.canvas_open and (current == nil or current == overlay) then
        self.bar = overlay.bar
    end
end

--- A rotation changes raster scale. This hook runs before Cache releases the
--- ready buffer, which is the last safe moment to abandon and repair a live
--- stroke. Rotation events are outside the stylus callback stack, so immediate
--- unregistration is safe here.
function JustDraw:onCanvasCacheWillRebuild(canvas)
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    self.canvas_pending_repaint = nil
    self:abortCanvasStroke()
    self:setDrawing(false)
end

--[[--
Whether a domain-fatal stop is latched for the end of this frame, on either
surface.

The latch is set from inside the stylus callback and acted on by the residual
handler, so between the two there is a stretch of one frame in which nothing
may ink: the stroke that tripped it has already been refused and taken back
off the raster, and the samples behind it would paint over a surface that is
about to stop accepting anything at all.
]]
function JustDraw:captureStopPending()
    return self.canvas_pending_capture_stop ~= nil
        or self.document_pending_capture_stop == true
end

--- Latch a domain-fatal input stop until the residual handler for this same
--- SYN_REPORT has filtered palms and advanced diagnostics. The stylus callback
--- runs before feedEvent, so releasing the lease there would bypass both.
function JustDraw:_requestCanvasCaptureStop(canvas, repair_live_stroke)
    if not canvas then return nil, "no_canvas" end
    local pending = self.canvas_pending_capture_stop
    if pending and pending.canvas_id == canvas.id then
        pending.repair_live_stroke = pending.repair_live_stroke
            or repair_live_stroke == true
        return true
    end
    self.canvas_pending_capture_stop = {
        canvas = canvas,
        canvas_id = canvas.id,
        repair_live_stroke = repair_live_stroke == true,
    }
    return true
end

function JustDraw:_flushPendingCanvasCaptureStop()
    local pending = self.canvas_pending_capture_stop
    if not pending then return true end
    self.canvas_pending_capture_stop = nil
    return self:_deferCanvasCaptureStop(
        pending.canvas, pending.repair_live_stroke)
end

--- A cache or save failure may be reported from inside the stylus callback.
--- Make capture inert now, but leave the callback registered and `drawing`
--- true through the rest of this frame so palm gestures remain suppressed.
--- The visible state changes on the next safe UI tick.
function JustDraw:_deferCanvasCaptureStop(canvas, repair_live_stroke)
    self.canvas_pending_capture_stop = nil
    local active = self.session and self.session:activeCanvas()
    if not (self.canvas_open and active and canvas and active.id == canvas.id) then
        return
    end
    if not self.drawing and not self.input_lease then
        local overlay = self.session and self.session:overlay()
        if self.bar then self.bar:update(false) end
        if overlay then UIManager:setDirty(overlay, "ui") end
        return
    end
    local generation = self.drawing_generation or 0
    local lease = self.input_lease
    if not lease then return end
    lease:releaseDeferred(function()
        if self.input_lease == lease then self.input_lease = nil end
        if (self.drawing_generation or 0) ~= generation then return end
        local still_active = self.session and self.session:activeCanvas()
        if not (self.canvas_open and still_active and still_active.id == canvas.id) then
            return
        end
        if repair_live_stroke then
            self:abortCanvasStroke()
        else
            self:endCanvasErase()
            self.canvas_stroke = nil
            self.draw_slot = nil
        end
        self:setDrawing(false)
        local overlay = self.session and self.session:overlay()
        if self.bar then self.bar:update(false) end
        if overlay then UIManager:setDirty(overlay, "ui") end
    end)
end

--- Cache completion is asynchronous for a non-empty sheet. Do not capture pen
--- or touch input until every chunk has validated and reached the raster.
function JustDraw:onCanvasReady(canvas)
    local active = self.session and self.session:activeCanvas()
    local overlay = self.session and self.session:overlay()
    if not (self.canvas_open and active and canvas and overlay
        and active.id == canvas.id) then
        return
    end
    if self.session:isWritable() then
        self:setDrawing(true)
    elseif self.bar then
        self.bar:update(false)
    end
    UIManager:setDirty(overlay, "ui")
end

function JustDraw:onCanvasLoadFailed(canvas)
    local active = self.session and self.session:activeCanvas()
    local overlay = self.session and self.session:overlay()
    if not (self.canvas_open and active and canvas and overlay
        and active.id == canvas.id) then
        return
    end
    self:_deferCanvasCaptureStop(canvas, false)
end

function JustDraw:onCanvasSaveFailed(canvas)
    self:_deferCanvasCaptureStop(canvas, true)
end

function JustDraw:onCanvasSaveRecovered(canvas)
    local active = self.session and self.session:activeCanvas()
    if self.canvas_open and active and canvas and active.id == canvas.id
        and self.session:cache() and self.session:cache():isReady() then
        self:setDrawing(true)
    end
    if self.bar then self.bar:update(true) end
end

function JustDraw:retryCanvasLoad()
    if not (self.session and self.canvas_open) then return nil, "no_canvas" end
    local ok, err = self.session:retryLoad()
    if self.bar then self.bar:update(true) end
    return ok, err
end

--- Open the sheet at the reader's position, or make one there.
function JustDraw:openCanvasHere()
    if not (self.session and self.session:isAvailable()) then return end
    local here = self.session:canvasesHere(self:currentPage())
    if #here == 1 then return self:openCanvas(here[1]) end
    if #here > 1 then return self:showCanvasPicker(here) end
    local canvas, err = self.session:createHere(self:currentPage())
    if not canvas then
        if err ~= "indexing" then
            self:notify(_("Cannot anchor a sheet at this position"))
        end
        return
    end
    return self:openCanvas(canvas)
end

--[[--
The Dispatcher route to the sheet: the same calls the menu makes.

A gesture has no `enabled_func`, so the refusal the menu greys out has to be
said out loud here -- a bound swipe that silently does nothing looks broken.
`openCanvasHere` voices its own anchor failure; what is left to say is that
this document cannot hold a sheet at all. The one refusal that stays quiet is
indexing, transient by construction, which the menu handles the same way.
]]
function JustDraw:onJustDrawSheet()
    if self.canvas_open then
        self:closeCanvas()
    elseif self.session and self.session:isAvailable() then
        self:openCanvasHere()
    elseif self.is_docless then
        -- The action is `general`, so it can fire in the file browser,
        -- where "this document" would name a document that does not exist.
        self:notify(_("Drawing sheets need an open book"))
    else
        self:notify(_("Drawing sheets are not available in this document"))
    end
    return true
end

function JustDraw:closeCanvas()
    if not self.canvas_open then return end
    -- Keep the visible sheet, its retry queue and ReaderUI capture intact if
    -- durability refuses the transition. Only dismantle the surface after the
    -- same explicit save gate used by document lifecycle events succeeds.
    local durable, durable_err = self.session:flush()
    if not durable then return nil, durable_err end
    self:abortCanvasStroke()
    self:setDrawing(false)
    local ok, err = self.session:closeCanvas()
    if not ok then return nil, err end
    self.canvas_pending_repaint = nil
    self.canvas_open = false
    self.bar = nil
    if self.bar_restore then self:setBarShown(true) end
    -- The sheet uncovered a page of text; a partial refresh would leave it
    -- ghosted.
    UIManager:setDirty(self.ui, "full")
    return true
end

--[[--
Toggle between marker and pen. Any non-marker style toggles TO the marker; the
previous style is not remembered — the gesture always lands on marker or pen,
and graphite is re-picked from the Pen style dialog.
]]
function JustDraw:onJustDrawMarker()
    self:setPenStyle(self.pen_style == Style.MARKER and Style.PEN or Style.MARKER)
    if self.pen_style == Style.MARKER then
        if self:markerAvailable() then
            self:notify(_("Pen style: marker"))
        else
            self:notify(_("Pen style: marker (needs a sheet here)"))
        end
    else
        self:notify(_("Pen style: ink pen"))
    end
    return true
end

--- One drawing point, in screen coordinates, while a sheet is open.
function JustDraw:applyCanvasPoint(x, y, tool)
    return applySurfacePoint(self, CANVAS_ROUTE, x, y, tool)
end

function JustDraw:startCanvasStroke(cx, cy, tr, style)
    self.canvas_stroke = newSurfaceStroke(self.pen_width, style, tr.scale, cx, cy)
end

function JustDraw:addCanvasPoint(cx, cy, tr)
    return addSurfaceStrokePoint(self, CANVAS_ROUTE, cx, cy, tr)
end

--[[--
Copy one dirty region of the raster onto the screen, and refresh it.

The raster is the source of truth for what the sheet looks like, so live ink
goes into it first and is copied out. That is what lets a repaint mid-stroke --
a notification, a menu closing -- show the stroke so far instead of losing it.
]]
function JustDraw:_queueCanvasRepaint(box, tr, overlay, cache)
    local sx, sy = tr:fromCache(box.x, box.y)
    local pending = self.canvas_pending_repaint
    local active = self.session and self.session:activeCanvas()
    local generation = cache and cache.generation
    if not pending or pending.overlay ~= overlay or pending.cache ~= cache
        or pending.generation ~= generation or pending.transform ~= tr
        or not active or pending.canvas_id ~= active.id then
        pending = {
            overlay = overlay,
            cache = cache,
            generation = generation,
            transform = tr,
            canvas_id = active and active.id,
            cache_left = box.x,
            cache_top = box.y,
            cache_right = box.x + box.w,
            cache_bottom = box.y + box.h,
            screen_left = sx,
            screen_top = sy,
            screen_right = sx + box.w,
            screen_bottom = sy + box.h,
        }
        self.canvas_pending_repaint = pending
        return
    end
    pending.cache_left = math.min(pending.cache_left, box.x)
    pending.cache_top = math.min(pending.cache_top, box.y)
    pending.cache_right = math.max(pending.cache_right, box.x + box.w)
    pending.cache_bottom = math.max(pending.cache_bottom, box.y + box.h)
    pending.screen_left = math.min(pending.screen_left, sx)
    pending.screen_top = math.min(pending.screen_top, sy)
    pending.screen_right = math.max(pending.screen_right, sx + box.w)
    pending.screen_bottom = math.max(pending.screen_bottom, sy + box.h)
end

function JustDraw:_canvasPendingRepaintValid(pending)
    local overlay = self.session and self.session:overlay()
    local active = self.session and self.session:activeCanvas()
    local cache = self.session and self.session:cache()
    return pending and self.canvas_open and overlay == pending.overlay
        and active and active.id == pending.canvas_id
        and cache == pending.cache and cache.generation == pending.generation
        and self.session:transform() == pending.transform
end

--- Flush fallback ink only when the canvas is once again the topmost window.
--- Direct framebuffer writes while a modal is above the overlay would punch
--- through that modal. The pending union is O(1) and bound to the exact
--- canvas/cache/transform generation that produced it.
function JustDraw:_flushCanvasPendingRepaint(already_painted)
    local pending = self.canvas_pending_repaint
    if not pending then return true end
    if not self:_canvasPendingRepaintValid(pending) then
        self.canvas_pending_repaint = nil
        return nil, "stale_repaint"
    end
    if Stack.visualAbove(pending.overlay) then return nil, "covered" end
    self.canvas_pending_repaint = nil
    local x, y = pending.screen_left, pending.screen_top
    local w = pending.screen_right - x
    local h = pending.screen_bottom - y
    if not already_painted then
        local bb = pending.cache:buffer()
        if not bb then return nil, "no_buffer" end
        blitCacheBox(pending.cache, bb, Screen.bb, x, y,
            pending.cache_left, pending.cache_top, w, h)
        pending.overlay:restoreChromeIfIntersecting(Screen.bb,
            { x = x, y = y, w = w, h = h }, 0, 0)
    end
    if w > 0 and h > 0 then
        if already_painted then
            UIManager:setDirty(nil, "partial",
                Geom:new{ x = x, y = y, w = w, h = h })
        else
            self:refreshBox(x, y, x + w, y + h,
                pending.cache:hasGrayInk())
        end
    end
    return true
end

--- Called after the overlay has copied the current cache into Screen.bb.
--- Closing any KOReader modal repaints the exposed overlay; use that natural
--- lifecycle boundary to request the deferred regional refresh once.
function JustDraw:onCanvasOverlayPainted(overlay)
    local pending = self.canvas_pending_repaint
    if pending and pending.overlay == overlay then
        self:_flushCanvasPendingRepaint(true)
    end
end

function JustDraw:blitCanvasBox(box, tr)
    if not box or box.w <= 0 or box.h <= 0 then return end
    local cache = self.session and self.session:cache()
    local bb = cache and cache:buffer()
    if not bb then return end
    local overlay = self.session and self.session:overlay()
    if overlay and Stack.visualAbove(overlay) then
        self:_queueCanvasRepaint(box, tr, overlay, cache)
        return nil, "covered"
    end
    self:_flushCanvasPendingRepaint(false)
    local sx, sy = tr:fromCache(box.x, box.y)
    blitCacheBox(cache, bb, Screen.bb, sx, sy, box.x, box.y, box.w, box.h)
    if overlay then
        overlay:restoreChromeIfIntersecting(Screen.bb,
            { x = sx, y = sy, w = box.w, h = box.h }, 0, 0)
    end
    self:refreshBox(sx, sy, sx + box.w, sy + box.h, cache:hasGrayInk())
end

function JustDraw:endCanvasStroke()
    return endSurfaceStroke(self, CANVAS_ROUTE)
end

--- The sheet's half of `endSurfaceStroke`'s capture stop: which canvas the
--- refused stroke belonged to is the sheet route's own bookkeeping.
function JustDraw:_requestCanvasStrokeCaptureStop()
    return self:_requestCanvasCaptureStop(
        self.session and self.session:activeCanvas(), false)
end

function JustDraw:abortCanvasStroke()
    return abortSurfaceStroke(self, CANVAS_ROUTE)
end

function JustDraw:eraseCanvasAt(cx, cy, tr)
    return eraseSurfaceAt(self, CANVAS_ROUTE, cx, cy, tr)
end

function JustDraw:endCanvasErase()
    return endSurfaceErase(self, CANVAS_ROUTE)
end

-- --------------------------------------------------------------- page ink

--[[--
Whether this page can take ink right now.

Asked once per accepted point, so it may allocate nothing: `canDraw` answers
from fields it already has and returns one of a fixed set of reason strings.
It is the whole predicate on purpose -- a surface that is open but loading,
read-only, mid-refusal or holding a failed write is not one to add to.
]]
function JustDraw:documentInkActive()
    local session = self.document_session
    if not session then return false end
    return session:canDraw()
end

--[[--
Draw was pressed: make sure this page has somewhere to put ink.

`refreshView` first, because `ensureSurface` answers the *view's* refusal
while the view is refused, and a reason built from the view the reader had two
zooms ago is worse than no reason at all. Then `canDraw`, because a surface
can exist and still not take a stroke -- a raster still loading is the common
one, and the reader can act on being told to wait.
]]
function JustDraw:prepareDocumentInk()
    local session = self.document_session
    if not session then return true end
    session:refreshView()
    local ready, reason = session:ensureSurface()
    if not ready then return nil, reason end
    -- A row may have just been created, and one COUNT is what the menu reads.
    self.document_ink_count = nil
    local can, why = session:canDraw()
    if not can then return nil, why end
    return true
end

--[[--
Queue one repaired region for a repaint through the reader.

A transparent layer cannot un-paint the framebuffer. What an erase or an undo
takes off the overlay is still on the screen underneath it, so the page has to
be drawn again -- `setDirty` with a region does exactly that, repainting the
reader widget and refreshing only that rectangle. One per tick, unioned, for
the same reason the sheet unions its fallback repaints: an eraser sweep would
otherwise ask for one per sample. Gray or not, this is `ui`: there is no fast
path for a repaint that goes through the view (ADR-36, ADR-38).
]]
function JustDraw:queueDocumentViewRepaint(sx, sy, w, h)
    if not w or not h or w <= 0 or h <= 0 then return end
    local pending = self.document_pending_view_repaint
    if pending then
        if sx < pending.left then pending.left = sx end
        if sy < pending.top then pending.top = sy end
        if sx + w > pending.right then pending.right = sx + w end
        if sy + h > pending.bottom then pending.bottom = sy + h end
        return
    end
    self.document_pending_view_repaint = {
        left = sx, top = sy, right = sx + w, bottom = sy + h,
    }
    UIManager:nextTick(function() self:flushDocumentViewRepaint() end)
end

function JustDraw:flushDocumentViewRepaint()
    local pending = self.document_pending_view_repaint
    self.document_pending_view_repaint = nil
    if not pending then return end
    local x, y, w, h = screenBox(pending.left, pending.top,
        pending.right, pending.bottom)
    if not x then return end
    UIManager:setDirty(self.ui, "ui", Geom:new{ x = x, y = y, w = w, h = h })
end

--- One raster box, in cache coordinates, repainted through the view.
function JustDraw:repaintDocumentBox(box, tr)
    if not box or not tr or box.w <= 0 or box.h <= 0 then return end
    local sx, sy = tr:fromCache(box.x, box.y)
    self:queueDocumentViewRepaint(sx, sy, box.w, box.h)
end

--- One raster box copied onto the screen and refreshed: what live ink does,
--- and the only page-ink path that touches the framebuffer directly.
function JustDraw:blitDocumentBox(box, tr)
    if not box or not tr or box.w <= 0 or box.h <= 0 then return end
    local session = self.document_session
    local cache = session and session:cache()
    local bb = cache and cache:buffer()
    if not bb then return end
    local sx, sy = tr:fromCache(box.x, box.y)
    blitCacheBox(cache, bb, Screen.bb, sx, sy, box.x, box.y, box.w, box.h)
    self:refreshBox(sx, sy, sx + box.w, sy + box.h, cache:hasGrayInk())
end

--[[--
One drawing point, in screen pixels, on a fixed-layout page.

The transform gates the margins: ink never starts in the surround, because
there is no page there to anchor it to. Everything below this point is in the
page's own units.
]]
function JustDraw:applyDocumentPoint(x, y, tool)
    return applySurfacePoint(self, DOCUMENT_ROUTE, x, y, tool)
end

function JustDraw:startDocumentStroke(cx, cy, tr, style)
    self.document_stroke = newSurfaceStroke(self.pen_width, style, tr.scale, cx, cy)
end

function JustDraw:addDocumentPoint(cx, cy, tr)
    return addSurfaceStrokePoint(self, DOCUMENT_ROUTE, cx, cy, tr)
end

function JustDraw:endDocumentStroke()
    return endSurfaceStroke(self, DOCUMENT_ROUTE)
end

function JustDraw:abortDocumentStroke()
    return abortSurfaceStroke(self, DOCUMENT_ROUTE)
end

function JustDraw:eraseDocumentAt(cx, cy, tr)
    return eraseSurfaceAt(self, DOCUMENT_ROUTE, cx, cy, tr)
end

function JustDraw:endDocumentErase()
    return endSurfaceErase(self, DOCUMENT_ROUTE)
end

--[[--
Stop capture after a page-ink stroke the queue can never accept.

Latched rather than acted on, because `operation_too_large` is reported from
inside the stylus callback: releasing the lease there would bypass the palm
filter and the diagnostics that run for the rest of that same frame. The
residual handler flushes it, and the lease's own deferred release finishes on
the next safe tick (ADR-26). The sheet route makes the same bargain, keyed on
the canvas the stroke belonged to; a page-ink session has exactly one surface,
so a flag is the whole of it.
]]
function JustDraw:_requestDocumentCaptureStop()
    self.document_pending_capture_stop = true
    return true
end

function JustDraw:_flushPendingDocumentCaptureStop()
    if not self.document_pending_capture_stop then return true end
    self.document_pending_capture_stop = false
    local lease = self.input_lease
    if not lease then
        -- Nothing to release, and a frame handler is not the place to change
        -- the visible state by hand: the sheet's twin makes the same choice.
        if self.bar then self.bar:update(false) end
        return true
    end
    local generation = self.drawing_generation or 0
    lease:releaseDeferred(function()
        if self.input_lease == lease then self.input_lease = nil end
        if (self.drawing_generation or 0) ~= generation then return end
        self:abortDocumentStroke()
        self:setDrawing(false)
    end)
    return true
end

--- Undo on a fixed layout: the page's own ink, never the sidecar's (ADR-39).
function JustDraw:undoDocumentInk()
    local session = self.document_session
    local can, why = session:canDraw()
    if not can then
        self:notify(documentMessage(why))
        return true
    end
    local box, err = session:undo()
    if not box then
        if err then self:notify(documentMessage(err))
        else self:notify(_("Nothing to undo on this page")) end
        return true
    end
    if type(box) == "table" then
        self:repaintDocumentBox(box, session:transform())
    else
        UIManager:setDirty(self.ui, "ui")
    end
    return true
end

-- ------------------------------------------------------------------ output

function JustDraw:paintTo(bb, x, y)
    self:paintMarks(bb)

    -- Through the read-only view, on both runtimes: what a paint needs from
    -- the sidecar is the page's list and nothing else, and the object it asks
    -- has no way to grow one (ADR-39).
    local list = self.legacy:strokes(self:currentPage())
    if list then
        for i = 1, #list do
            Render.stroke(bb, list[i], 0, 0, Style.colorFor(list[i].t, INK))
        end
    end
    -- Last, and over the legacy ink: page ink is the current surface, and the
    -- frozen one belongs underneath it (ADR-39).
    self:paintDocumentInk(bb)
end

--[[--
This page's own ink, composed over the page the reader is looking at.

The transform already carries `view.dimen`'s origin, so the offsets this is
handed are ignored exactly as the direct ink ignores them. A refused view
paints nothing at all -- there is no transform, so there is nowhere honest to
put it, and a page zoomed past the raster budget shows the book alone.
]]
function JustDraw:paintDocumentInk(bb)
    local session = self.document_session
    if not session or session:viewReason() then return end
    if not session:transform() then return end
    local cache = session:cache()
    if not cache or not cache:isReady() then return end
    cache:paintTo(bb)
end

--[[--
A flag in the margin for every sheet anchored on this view.

Reads a table the session filled when the page turned. No query, no CREngine
call and no xpointer resolution happens here, which is what keeps turning a
page in a heavily annotated book the same cost as turning one in a plain book.

Drawn on the edge opposite the toolbar so the two never overlap.
]]
function JustDraw:paintMarks(bb)
    if not self.session then return end
    local marks = self.session:marks()
    if #marks == 0 then return end

    local x = (self.bar_side == "left") and (Screen:getWidth() - MARK_W) or 0
    local limit = Screen:getHeight() - MARK_H
    for i = 1, #marks do
        local y = marks[i].y - math.floor(MARK_H / 2)
        if y < 0 then y = 0 elseif y > limit then y = limit end
        bb:paintRect(x, y, MARK_W, MARK_H, INK)
    end
end

function JustDraw:repaint()
    UIManager:setDirty(self.ui, "ui")
end

--- Refresh the half-open coverage returned by InkRender, clamped to screen.
--- `grayscale` overrides the fast path: the device's fast refresh is forced
--- monochrome and drops gray ink. The grayscale pass is `ui`, never
--- `partial` -- partial is REAGL, and its completion fence with the pen
--- reporting overflows evdev and drops input (ADR-26/36, crash (7).log).
function JustDraw:refreshBox(left, top, right, bottom, grayscale)
    local x, y, w, h = screenBox(left, top, right, bottom)
    if not x then return end

    if grayscale then
        Screen:refreshUI(x, y, w, h)
    elseif self.live_fast then
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshPartial(x, y, w, h)
    end
end

-- -------------------------------------------------------------------- menu

function JustDraw:onJustDrawUndo()
    if self.canvas_open then
        local box, err = self.session:undo()
        if not box then
            if err == "read_only" then self:notify(_("This sheet is read-only"))
            elseif err == "loading" or err == "load_failed" then
                self:notify(_("This sheet's ink is still loading"))
            else self:notify(_("Nothing to undo on this sheet")) end
            return true
        end
        local tr = self.session:transform()
        if type(box) == "table" and tr then
            self:blitCanvasBox(box, tr)
        else
            UIManager:setDirty(self.session:overlay(), "ui")
        end
        return true
    end
    if self.document_session then return self:undoDocumentInk() end
    -- Undo means "take back what I just drew", and on this runtime nothing
    -- that was just drawn is in the sidecar. Popping it would delete a stroke
    -- from another KOReader version instead (ADR-39). The event is still
    -- consumed: the reader asked this plugin to undo, and there is nothing
    -- underneath it that should act on the gesture either.
    if self:legacyInkFrozen() then
        logger.info("JustDraw: undo has nothing to take back; legacy ink is frozen")
        return true
    end

    local page = self:currentPage()
    if not self.store:pop(page) then
        self:notify(_("Nothing to undo on this page"))
        return true
    end
    self:repaint()
    return true
end

function JustDraw:setPenWidth(w)
    self.pen_width = w
    Compat.saveSetting(G_reader_settings, "pen_width", w)
end

function JustDraw:setPenStyle(style)
    style = Style.normalize(style)
    self.pen_style = style
    Compat.saveSetting(G_reader_settings, "pen_style", style)
end

--[[--
Where the marker may draw: a surface this plugin owns end to end.

A sheet, and a fixed page's ink layer -- which is a transparent layer of ours
over the book's page, so a wide translucent stroke lands where a highlighter
belongs, over the text. What is still not ours to fill is the framebuffer
itself, which is all the v2026.03 direct-ink route has.
]]
function JustDraw:markerAvailable()
    return self.canvas_open == true or self.document_session ~= nil
end

function JustDraw:effectiveStyle(hw_tool)
    return Style.resolve(self.pen_style, hw_tool, self:markerAvailable())
end

function JustDraw:penItem(text, w)
    return {
        text = text,
        checked_func = function() return self.pen_width == w end,
        radio = true,
        callback = function() self:setPenWidth(w) end,
    }
end

function JustDraw:styleItem(text, value)
    return {
        text = text,
        checked_func = function() return self.pen_style == value end,
        radio = true,
        callback = function() self:setPenStyle(value) end,
    }
end

function JustDraw:setBarSide(side)
    if self.bar_side == side then return end
    self.bar_side = side
    Compat.saveSetting(G_reader_settings, "bar_side", side)
    local overlay = self.session and self.session:overlay()
    if overlay then
        overlay:setBarSide(side)
        self.bar = overlay.bar
    else
        self:rebuildBar()
    end
end

function JustDraw:sideItem(text, side)
    return {
        text = text,
        checked_func = function() return self.bar_side == side end,
        radio = true,
        callback = function() self:setBarSide(side) end,
    }
end

--- Radio item for the input mode. Locked while drawing, because swapping
--- backends mid-sequence would tear down capture inside a live contact.
function JustDraw:inputModeItem(text, value)
    return {
        text = text,
        checked_func = function() return self.input_mode == value end,
        radio = true,
        enabled_func = function() return not self.drawing end,
        callback = function() self:setInputMode(value) end,
    }
end

--- One choice sub-dialog off the toolbar's More: checked options, then Close.
--- A pick applies and closes; the More dialog it came from is already gone.
function JustDraw:showBarChoices(title, options)
    local dialog
    local rows = {}
    for i = 1, #options do
        local opt = options[i]
        rows[#rows + 1] = { {
            text = opt.text,
            enabled = opt.enabled ~= false,
            checked_func = opt.checked_func,
            -- The pick closes this dialog inside the button's own callback.
            -- Without this flag Button:onTapSelectButton refreshes the checked
            -- label after the callback and repaints the dead row over whatever
            -- the close exposed (ADR-35).
            no_refresh_checkmark = true,
            callback = function()
                opt.callback()
                self:closeReaderModal(dialog)
            end,
        } }
    end
    rows[#rows + 1] = { {
        text = _("Close"),
        callback = function() self:closeReaderModal(dialog) end,
    } }
    dialog = ButtonDialog:new{ title = title, buttons = rows }
    return self:showReaderModal(dialog)
end

function JustDraw:showPenStyleDialog()
    local function style(text, value, enabled)
        return {
            text = text,
            enabled = enabled ~= false,
            checked_func = function() return self.pen_style == value end,
            callback = function() self:setPenStyle(value) end,
        }
    end
    return self:showBarChoices(_("Pen style"), {
        style(_("Ink pen"), Style.PEN),
        style(_("Graphite"), Style.GRAPHITE),
        -- The book's page is not ours to fill; the marker needs a sheet.
        style(_("Marker"), Style.MARKER, self:markerAvailable()),
    })
end

function JustDraw:showPenWidthDialog()
    local function width(text, w)
        return {
            text = text,
            checked_func = function() return self.pen_width == w end,
            callback = function() self:setPenWidth(w) end,
        }
    end
    return self:showBarChoices(_("Pen width"), {
        width(_("Thin"), PEN_THIN),
        width(_("Medium"), PEN_MEDIUM),
        width(_("Thick"), PEN_THICK),
    })
end

--- Locked while drawing for the same reason the menu locks it: swapping
--- backends mid-sequence would tear down capture inside a live contact.
function JustDraw:showInputModeDialog()
    local function mode(text, value)
        return {
            text = text,
            enabled = not self.drawing,
            checked_func = function() return self.input_mode == value end,
            callback = function() self:setInputMode(value) end,
        }
    end
    return self:showBarChoices(_("Input mode"), {
        mode(_("Automatic"), "auto"),
        mode(_("Stylus"), "stylus"),
        mode(_("Finger"), "finger"),
    })
end

--[[--
The toolbar's More: the reader's JustDraw settings without the menu trip.

The same state the main menu edits, presented the way the notebook rail
presents its More -- because with drawing on, the menu is the thing that
cannot be reached. Refused while a contact is live: a modal rising under a
moving pen orphans the stroke, which is why every reader modal makes the
same check before it goes up.
]]
function JustDraw:showBarMenu()
    local lease = self.input_lease
    if lease and lease:hasActiveContact() then return nil, "contact_active" end
    local dialog
    --- Close the More dialog before what was picked goes up: two stacked
    --- modals leave two window stacks competing for the same taps.
    local function pick(fn)
        return function()
            self:closeReaderModal(dialog)
            fn()
        end
    end
    local rows = {
        { { text = _("Pen style"),
            callback = pick(function() self:showPenStyleDialog() end) } },
        { { text = _("Pen width"),
            callback = pick(function() self:showPenWidthDialog() end) } },
        { { text = _("Input mode"),
            callback = pick(function() self:showInputModeDialog() end) } },
        { { text = _("Export…"), enabled = self:canExport(),
            callback = pick(function() self:showExportDialog() end) } },
    }
    if self.canvas_open then
        local active = self.session:activeCanvas()
        rows[#rows + 1] = { { text = _("Close sheet"),
            callback = pick(function() self:closeCanvas() end) } }
        rows[#rows + 1] = { { text = _("Delete sheet"),
            enabled = self.session:isWritable(),
            callback = pick(function() self:confirmDeleteCanvas(active) end) } }
    end
    rows[#rows + 1] = { { text = _("Toolbar side"),
        callback = function()
            self:setBarSide(self.bar_side == "left" and "right" or "left")
        end } }
    rows[#rows + 1] = { { text = _("Close"),
        callback = function() self:closeReaderModal(dialog) end } }
    dialog = ButtonDialog:new{ title = _("JustDraw"), buttons = rows }
    return self:showReaderModal(dialog)
end

--[[--
Ask which sheet, when the reader's position has more than one.

Opening the first one silently is the failure worth avoiding: the reader would
write into a sheet they cannot see the identity of, and find their earlier
notes in the other one later.
]]
function JustDraw:showCanvasPicker(list)
    local buttons = {}
    for i = 1, #list do
        local canvas = list[i]
        buttons[i] = { {
            text = string.format(_("Sheet %d"), i),
            callback = function()
                if self.canvas_picker then
                    UIManager:close(self.canvas_picker)
                    self.canvas_picker = nil
                end
                self:openCanvas(canvas)
            end,
        } }
    end
    self.canvas_picker = ButtonDialog:new{
        title = _("Sheets at this position"),
        buttons = buttons,
    }
    UIManager:show(self.canvas_picker)
end

function JustDraw:confirmDeleteCanvas(canvas)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this sheet and everything drawn on it?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteCanvas(canvas)
        end,
    })
end

--- Delete through the plugin so its visible state changes together with the
--- session. Session deliberately knows nothing about JustDraw's toolbar and
--- capture flags.
function JustDraw:deleteCanvas(canvas)
    if not (self.session and canvas) then return nil, "no_canvas" end
    local active = self.canvas_open and self.session:activeCanvas()
        and self.session:activeCanvas().id == canvas.id
    if active then
        self:abortCanvasStroke()
        self:setDrawing(false)
    end

    local ok, err = self.session:deleteCanvas(canvas)
    if not ok then
        self:notify(_("Could not delete this sheet"))
        return nil, err
    end

    if active then
        self.canvas_pending_repaint = nil
        self.canvas_open = false
        self.bar = nil
        if self.router then self.router:reset() end
        if self.bar_restore then self:setBarShown(true) end
    end
    UIManager:setDirty(self.ui, "full")
    return true
end

--[[--
The sheet menu, rebuilt every time it is opened.

Deliberately built on demand rather than kept as a static table: what it can
offer depends on where the reader is, whether a sheet is open, and whether the
page index has finished -- and a stale menu that offers to create a second
sheet on a paragraph that already has one is the failure this feature can least
afford.
]]
function JustDraw:canvasMenu()
    local items = {}
    if not (self.session and self.session:isAvailable()) then return items end

    if self.canvas_open then
        local active = self.session:activeCanvas()
        items[#items + 1] = {
            text = _("Close sheet"),
            callback = function() self:closeCanvas() end,
        }
        items[#items + 1] = {
            text = _("Delete this sheet"),
            enabled_func = function() return self.session:isWritable() end,
            keep_menu_open = true,
            separator = true,
            callback = function() self:confirmDeleteCanvas(active) end,
        }
    else
        local open_here = MENU_OPEN_SHEET_HERE
        items[#items + 1] = {
            -- Closes the menu on purpose: opening a sheet turns drawing on,
            -- and an open menu is unusable once the pen is inking.
            text = open_here,
            --[[--
            While the index builds, this entry is disabled and this is where
            the reader is looking, so the count goes here rather than into a
            modal or a notification: nothing is waiting on their answer, and
            the wait is measured in ticks stolen from an idle process
            (ADR-42). A total the count never produced is left out rather
            than shown as a zero.
            ]]
            text_func = function()
                local progress = self.session:isIndexing()
                    and self.session:indexProgress()
                if not progress then return open_here end
                if progress.total then
                    return T(_("Indexing sheets %1/%2"),
                        progress.loaded, progress.total)
                end
                return T(_("Indexing sheets %1"), progress.loaded)
            end,
            enabled_func = function()
                if self.session:isIndexing() then return false end
                return self.session:isWritable()
                    or #self.session:canvasesHere(self:currentPage()) > 0
            end,
            callback = function() self:openCanvasHere() end,
            help_text = _([[Creates a blank sheet anchored to this position in the book, or opens the one that is already here. The sheet keeps its own coordinates, so changing font or margins moves the sheet, not what you drew on it.]]),
        }
    end

    if self.session:saveFailed() then
        -- Editing is refused until this succeeds, so it has to be the first
        -- thing here and it has to say what state the ink is in.
        items[#items + 1] = {
            text = _("Retry saving ink"),
            keep_menu_open = true,
            separator = true,
            help_text = _([[A write to the sheet database failed. Nothing has been lost -- the strokes are still in memory -- but they are not durable until this succeeds, and no more can be drawn until it does.]]),
            callback = function() self.session:retrySave() end,
        }
    end

    if self.session:loadFailed() then
        items[#items + 1] = {
            text = _("Retry loading sheet"),
            keep_menu_open = true,
            separator = true,
            callback = function() self:retryCanvasLoad() end,
        }
    end

    local here = self.session:canvasesHere(self:currentPage())
    if #here > 1 then
        local sub = {}
        for i = 1, #here do
            local canvas = here[i]
            sub[i] = {
                text = string.format(_("Sheet %d"), i),
                callback = function() self:openCanvas(canvas) end,
            }
        end
        items[#items + 1] = {
            text = _("Sheets on this page"),
            separator = true,
            sub_item_table = sub,
        }
    end

    local orphans = self.session:orphans()
    if #orphans > 0 then
        local sub = {}
        for i = 1, #orphans do
            local canvas = orphans[i]
            sub[i] = {
                text = string.format(_("Lost sheet %d"), i),
                sub_item_table = {
                    {
                        text = _("Open it anyway"),
                        callback = function() self:openCanvas(canvas) end,
                    },
                    {
                        text = _("Delete it"),
                        enabled_func = function() return self.session:isWritable() end,
                        keep_menu_open = true,
                        callback = function() self:confirmDeleteCanvas(canvas) end,
                    },
                },
            }
        end
        items[#items + 1] = {
            -- Anchors that no longer resolve are kept, never deleted for the
            -- reader: the text may come back. But a sheet nothing can reach is
            -- no use either, so there is a way in.
            text = string.format(_("Lost sheets (%d)"), #orphans),
            help_text = _([[Sheets whose place in the book can no longer be found -- usually because the file was replaced with a different edition. Nothing drawn on them has been lost.]]),
            sub_item_table = sub,
        }
    end

    return items
end

-- --------------------------------------------------------- page ink: menu

--[[--
How many pages of this book carry ink, cached until something changes it.

`enabled_func` runs on every paint of the menu, so a COUNT per paint is a
query the reader pays for by scrolling. The cache is invalidated by every path
that can create or remove a page's ink, which is Draw, the two deletes and
opening the book.
]]
function JustDraw:documentInkCount()
    if self.document_ink_count ~= nil then return self.document_ink_count end
    local session = self.document_session
    self.document_ink_count = session and session:countSurfaces() or 0
    return self.document_ink_count
end

function JustDraw:confirmDeleteDocumentInk()
    UIManager:show(ConfirmBox:new{
        text = _("Delete the ink on this page? Drawing sheets and legacy ink are not affected."),
        ok_text = _("Delete"),
        ok_callback = function() self:deleteDocumentInk() end,
    })
end

function JustDraw:confirmDeleteAllDocumentInk()
    UIManager:show(ConfirmBox:new{
        text = _("Delete the ink on every page of this book? Drawing sheets and legacy ink are not affected."),
        ok_text = _("Delete"),
        ok_callback = function() self:deleteAllDocumentInk() end,
    })
end

--- Delete through the plugin, so the visible state changes with the session:
--- the session knows nothing about the toolbar or the capture.
function JustDraw:deleteDocumentInk()
    local session = self.document_session
    if not session then return nil, "no_session" end
    self:abortDocumentStroke()
    self:setDrawing(false)
    local ok, err = session:deleteCurrent()
    if not ok then
        self:notify(documentMessage(err))
        return nil, err
    end
    self.document_ink_count = nil
    -- The ink came off a transparent layer: the page under it has to be drawn
    -- again, and the whole page changed.
    UIManager:setDirty(self.ui, "ui")
    return true
end

function JustDraw:deleteAllDocumentInk()
    local session = self.document_session
    if not session then return nil, "no_session" end
    self:abortDocumentStroke()
    self:setDrawing(false)
    local ok, err = session:deleteAll()
    if not ok then
        self:notify(documentMessage(err))
        return nil, err
    end
    self.document_ink_count = nil
    UIManager:setDirty(self.ui, "ui")
    return true
end

function JustDraw:retryDocumentInkSave()
    local session = self.document_session
    if not session then return nil, "no_session" end
    -- A success relays `on_save_recovered`, which is where drawing comes back.
    local ok, err = session:retrySave()
    if not ok then self:notify(documentMessage(err)) end
    return ok, err
end

--[[--
The page-notes menu, rebuilt every time it is opened.

Built on demand for the reason the sheet menu is: what it can offer depends on
whether this page has ink, whether the book has any at all, and whether a
write is waiting to be retried -- and an entry offering to delete something
that is not there is the failure this feature can least afford.
]]
function JustDraw:documentInkMenu()
    local items = {}
    local session = self.document_session
    if not session then return items end

    if session:saveFailed() then
        -- Editing is refused until this succeeds, so it comes first and says
        -- what state the ink is in.
        items[#items + 1] = {
            text = _("Retry saving ink"),
            keep_menu_open = true,
            separator = true,
            help_text = _([[A write to the page-ink database failed. Nothing has been lost -- the strokes are still in memory -- but they are not durable until this succeeds, and no more can be drawn until it does.]]),
            callback = function() self:retryDocumentInkSave() end,
        }
    end

    items[#items + 1] = {
        text = _("Delete this page note"),
        keep_menu_open = true,
        -- Read through the plugin, not the captured session: a built submenu
        -- outlives the document it was built for, and this runs on every
        -- paint of it. `hasInk`, not "is there a row": Draw creates the row
        -- before the first stroke, and offering to delete an empty working
        -- surface would be offering to delete nothing.
        enabled_func = function()
            return self.document_session ~= nil
                and self.document_session:hasInk()
        end,
        callback = function() self:confirmDeleteDocumentInk() end,
    }
    items[#items + 1] = {
        text = _("Delete all page notes"),
        keep_menu_open = true,
        enabled_func = function() return self:documentInkCount() > 0 end,
        help_text = _([[Deletes the ink drawn on the pages of this book. Drawing sheets and ink drawn before this KOReader version are not affected.]]),
        callback = function() self:confirmDeleteAllDocumentInk() end,
    }
    return items
end

--[[--
Build the top menu entry.

`sorting_hint` is an id MenuSorter looks up anywhere in the assembled tree
(`menusorter.lua`, the orphan pass), not just among the submenus, so "tools"
names the Tools tab itself and puts the entry one tap closer than the
"more_tools" of KOReader's own plugin example -- which is a page below the
`plugin_management` and `patch_management` entries, since an orphan is always
appended last. Anything nearer than the tab requires either mutating the order
table `ui/elements/reader_menu_order` hands out (what
`ui/plugin/insert_menu.lua` does) or claiming a tab of the icon bar, and this
plugin does not take core state or screen furniture from the reader.

Quick access is the Dispatcher's job: see `onDispatcherRegisterActions`.
]]
-- ------------------------------------------------------------------ export

--[[--
Modals this plugin owns over the reader: the export flow, the toolbar's More.

The notebook windows have an owner that tracks what is open; in the reader
there is none, so the plugin keeps the record itself. `UIManager:close` fires
CloseWidget before it looks at the window stack but only schedules the widgets
underneath to repaint when it actually found the widget there, so a second
close refreshes with nothing repainting behind it and pushes stale pixels back
at the panel. The record is what makes that second close a no-op (ADR-28).
]]
function JustDraw:showReaderModal(widget)
    self.reader_modals = self.reader_modals or {}
    self.reader_modals[widget] = true
    local previous = widget.onCloseWidget
    widget.onCloseWidget = function(dialog, ...)
        if previous then previous(dialog, ...) end
        self.reader_modals[dialog] = nil
        -- The second half of ADR-28: the dialogs' own close refreshes are
        -- regional (`flashui` over `movable.dimen`, or `ui`), and on MTK only
        -- a full-screen flashing update is fenced against the DU highlight
        -- still in flight. Full-screen, with no region, is the form
        -- `_isFullScreen` recognises.
        UIManager:setDirty(nil, "flashui")
    end
    widget.show_parent = widget
    UIManager:show(widget)
    return widget
end

function JustDraw:closeReaderModal(widget)
    if not widget or not self.reader_modals or not self.reader_modals[widget] then
        return false
    end
    UIManager:close(widget)
    return true
end

--[[--
The reader's export decisions live in `ink_document_export_controller.lua`.

These keep the names the menu, the toolbar and the suite already call, and do
nothing else: the controller holds no state of its own, so which surface a
scope describes is still decided at the moment the reader asks.
]]
function JustDraw:exportScopes()
    return self.export_controller:scopes()
end

function JustDraw:canExport()
    return self.export_controller:canExport()
end

function JustDraw:exportScopePage(scope)
    return self.export_controller:scopePage(scope)
end

function JustDraw:exportStem(scope, stamp)
    return self.export_controller:stem(scope, stamp)
end

function JustDraw:buildExport(scope)
    return self.export_controller:build(scope)
end

function JustDraw:showExportDialog()
    return self.export_controller:showDialog()
end

function JustDraw:addToMainMenu(menu_items)
    if self.is_docless then
        menu_items.justdraw_notebooks = {
            text = _("Notebooks"),
            sorting_hint = "tools",
            callback = function() self:openNotebookLibrary() end,
        }
        return
    end
    -- The marker needs a surface this plugin owns: a sheet, or a page's own
    -- ink layer.
    local marker_style_item = self:styleItem(_("Marker"), Style.MARKER)
    marker_style_item.enabled_func = function() return self:markerAvailable() end
    local sheet_item = {
        text = MENU_DRAWING_SHEET,
        separator = true,
        enabled_func = function()
            return self.session ~= nil and self.session:isAvailable()
        end,
        help_text = _([[Blank sheets anchored to a position in a reflowable book. Not available in PDFs and other fixed layouts, where drawing goes straight onto the page instead.]]),
        sub_item_table_func = function() return self:canvasMenu() end,
    }
    menu_items.justdraw = {
        text = MENU_JUSTDRAW,
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Notebooks"),
                callback = function() self:openNotebookLibrary() end,
            },
            {
                -- Deliberately closes the menu: turning drawing on swallows
                -- single-finger taps, so an open menu would be unusable.
                text = _("Start drawing"),
                enabled_func = function() return not self.drawing end,
                callback = function() self:setDrawing(true) end,
                help_text = _([[Use the Draw/Stop button on the side toolbar to switch drawing off again. Two fingers also work as usual while drawing is on.]]),
            },
            {
                text = _("Show toolbar"),
                checked_func = function() return self.bar ~= nil end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:setBarShown(self.bar == nil)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Toolbar side"),
                separator = true,
                sub_item_table = {
                    self:sideItem(_("Left"), "left"),
                    self:sideItem(_("Right"), "right"),
                },
            },
            {
                text = _("Input mode"),
                separator = true,
                help_text = _([[Automatic uses the stylus route on devices that report a pen digitizer, and the finger route everywhere else. On a drawing sheet, finger and palm never draw; touches above the bounded sheet can still turn pages. With direct ink, press Stop to return all touch input to reading.]]),
                sub_item_table = {
                    self:inputModeItem(_("Automatic"), "auto"),
                    self:inputModeItem(_("Stylus"), "stylus"),
                    self:inputModeItem(_("Finger"), "finger"),
                },
            },
            {
                text = _("Pen style"),
                sub_item_table = {
                    self:styleItem(_("Ink pen"), Style.PEN),
                    self:styleItem(_("Graphite"), Style.GRAPHITE),
                    marker_style_item,
                },
            },
            {
                text = _("Pen width"),
                sub_item_table = {
                    self:penItem(_("Thin"), PEN_THIN),
                    self:penItem(_("Medium"), PEN_MEDIUM),
                    self:penItem(_("Thick"), PEN_THICK),
                },
            },
            {
                text = _("Fast refresh while drawing"),
                checked_func = function() return self.live_fast end,
                callback = function()
                    self.live_fast = not self.live_fast
                    Compat.saveSetting(G_reader_settings, "live_fast", self.live_fast)
                end,
                help_text = _([[On: strokes appear with the DU waveform — quick, but grainy and it leaves ghosting until the next page turn. Off: slower, cleaner.]]),
                separator = true,
            },
            {
                -- Deliberately not gated on the stylus backend being live: the
                -- only person who opens this is someone whose pen does nothing,
                -- and for them it never is.
                text = _("Stylus diagnostics"),
                callback = function() self:showDiagnostics() end,
                help_text = _([[Shows why the pen route is or is not running. With confirmation, it writes pen coordinates and decisions to the local log for up to one minute or 8,192 events. No book or notebook identity is logged.]]),
                separator = true,
            },
            sheet_item,
            {
                -- Deliberately closes the menu: the export dialog is a modal,
                -- and arranging one underneath an open menu leaves two window
                -- stacks competing for the same taps.
                text = _("Export…"),
                separator = true,
                enabled_func = function() return self:canExport() end,
                callback = function() self:showExportDialog() end,
                help_text = _([[Writes what you have drawn to a PDF, PNG or JPEG in a folder of your choosing. Exports the page you are reading, the sheet that is open, or every sheet in this book. Nothing in the book itself is changed.]]),
            },
        },
    }
    local sub = menu_items.justdraw.sub_item_table
    self:addPageNotesMenuItem(sub, sheet_item)
    local clear_page, clear_all = self:legacyInkItems()
    sub[#sub + 1] = clear_page
    sub[#sub + 1] = clear_all
end

--[[--
The two entries that delete direct ink, named for what they delete.

Three families of ink can be in a book at once and each has its own deletion,
so no confirmation may say just "ink": deleting a page note, deleting a sheet
and deleting the sidecar are three different losses (ADR-39). "Stored page N"
is the honest label for the number, too -- in a reflowable book it stopped
meaning a page at the first reflow, which is exactly why this ink is frozen.

With the gate false these are the entries they always were, word for word: on
v2026.03 direct ink is the only ink there is, and calling it "legacy" in front
of a reader who is still drawing it would be a lie.
]]
function JustDraw:legacyInkItems()
    if not self:legacyInkFrozen() then
        return {
            text = _("Clear this page"),
            keep_menu_open = true,
            callback = function()
                if self.legacy:clearPage(self:currentPage()) then
                    self:repaint()
                else
                    self:notify(_("No ink on this page"))
                end
            end,
        }, {
            text = _("Clear whole document"),
            keep_menu_open = true,
            callback = function()
                if self.legacy:isEmpty() then
                    self:notify(_("No ink in this document"))
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = _("Delete all ink in this document?"),
                    ok_text = _("Delete"),
                    ok_callback = function() self:clearWholeDocumentInk() end,
                })
            end,
        }
    end

    return {
        text = _("Clear legacy ink on this stored page"),
        keep_menu_open = true,
        enabled_func = function()
            return self.legacy:hasInk(self:currentPage())
        end,
        help_text = _([[Ink drawn on this page by an older JustDraw or FingerInk, in screen pixels. It is shown and exported as it was stored, and this is the only thing that can change it.]]),
        callback = function() self:confirmClearLegacyPage() end,
    }, {
        text = _("Clear all legacy ink"),
        keep_menu_open = true,
        enabled_func = function() return not self.legacy:isEmpty() end,
        callback = function() self:confirmClearLegacyBook() end,
    }
end

function JustDraw:confirmClearLegacyPage()
    local page = self:currentPage()
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete the legacy ink stored for page %1? Drawing sheets and page notes are not affected."), page),
        ok_text = _("Delete"),
        ok_callback = function()
            if self.legacy:clearPage(page) then self:repaint() end
        end,
    })
end

function JustDraw:confirmClearLegacyBook()
    UIManager:show(ConfirmBox:new{
        text = _("Delete all legacy ink in this book? Drawing sheets and page notes are not affected."),
        ok_text = _("Delete"),
        ok_callback = function() self:clearWholeDocumentInk() end,
    })
end

--[[--
Put "Page notes" next to "Drawing sheet", where it can exist at all.

Absent rather than greyed on an EPUB and on a runtime with no stylus API
(ADR-41): a permanently disabled row is a promise about a feature this session
can never have, and on the v2026.03 route it would be the one visible trace of
a surface that does not exist there.

Placed by the identity of the sheet row rather than by an index or a
translated label, so neither reordering the menu nor translating it can move
it somewhere else.
]]
function JustDraw:addPageNotesMenuItem(items, sheet_item)
    if not (Capture:supportsStylus() and self.ui.paging) then return end
    local at = #items + 1
    for i = 1, #items do
        if items[i] == sheet_item then at = i + 1 break end
    end
    table.insert(items, at, {
        text = _("Page notes"),
        separator = true,
        enabled_func = function() return self.document_session ~= nil end,
        help_text = _([[Ink drawn on the pages of a PDF or another fixed layout, stored in the page's own units so it follows zoom and panning. Not available in reflowable books, where a drawing sheet is anchored to the text instead.]]),
        sub_item_table_func = function() return self:documentInkMenu() end,
    })
end

-- Compatibility event handlers for Gesture Manager assignments created by
-- FingerInk. The registered action IDs above intentionally keep emitting the
-- old event names, while all current code calls the JustDraw handlers.
JustDraw.onFingerInkBar = JustDraw.onJustDrawBar
JustDraw.onFingerInkToggle = JustDraw.onJustDrawToggle
JustDraw.onFingerInkEraser = JustDraw.onJustDrawEraser
JustDraw.onFingerInkUndo = JustDraw.onJustDrawUndo

return JustDraw
