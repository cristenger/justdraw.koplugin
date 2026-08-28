--[[-- Full-screen standalone notebook editor and bounded paper viewport. ]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local Errors = require("ink_notebook_errors")
local NotebookLayout = require("ink_notebook_layout")
local Stack = require("ink_stack")

local Screen = Device.screen

local Editor = FocusManager:extend{
    covers_fullscreen = true,
    modal = false,
}

local QUALITY_DELAY = 0.35
local QUALITY_STROKE_BUDGET = 8
local QUALITY_AREA_RATIO = 0.25

local function inside(rect, x, y)
    return rect ~= nil and x >= rect.x and x < rect.x + rect.w
        and y >= rect.y and y < rect.y + rect.h
end

local function pageCountText(count)
    count = tonumber(count) or 0
    return T(N_("1 page", "%1 pages", count), count)
end

function Editor:init()
    self.controller = assert(self.controller)
    self.notebook = assert(self.notebook)
    self.get_eraser = self.get_eraser or function() return false end
    self.set_eraser = self.set_eraser or function() end
    self.get_input_mode = self.get_input_mode or function() return "auto" end
    self.set_input_mode = self.set_input_mode or function() return true end
    self.get_pen_width = self.get_pen_width or function() return 4 end
    self.set_pen_width = self.set_pen_width or function() return true end
    self.get_rail_side = self.get_rail_side or function() return "right" end
    self.get_live_fast = self.get_live_fast or function() return true end
    self.has_active_contact = self.has_active_contact or function() return false end
    self.quality_schedule_in = self.quality_schedule_in or function(delay, action)
        UIManager:scheduleIn(delay, action)
    end
    self.quality_unschedule = self.quality_unschedule or function(action)
        UIManager:unschedule(action)
    end
    self.show_stylus_diagnostics = self.show_stylus_diagnostics or function() end
    self.set_rail_side = self.set_rail_side or function() end
    self.show_host_message = self.show_host_message or function(text)
        UIManager:show(InfoMessage:new{ text = text })
    end
    self.snapshot = {
        state = "loading", writable = false, can_ink = false,
        can_navigate = false, can_close = true, page_count = self.notebook.page_count or 1,
        can_undo = false, pending_writes = 0,
    }
    self.interactive_regions = {}
    self.error_expanded = true
    self.shown = false
    self.closed = false
    self.modal_widget = nil
    self.modal_widgets = {}
    self.pending_resize = nil
    self.layout = nil
    self.control_entries = {}
    self.focus_layout = {}
    self:_initQualityRefresh()
    self:_computeLayout()
    self:_registerEvents()
    self:_rebuildControls()
end

function Editor:_registerEvents()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
end

function Editor:onTap() return true end
function Editor:onHold() return true end
function Editor:onSwipe() return true end

function Editor:_computeLayout()
    local page = self.controller:activeSession()
        and self.controller:activeSession():currentPage() or nil
    local computed, err = NotebookLayout.compute{
        logical_w = page and page.logical_w or 1184,
        logical_h = page and page.logical_h or 1680,
        rail_side = self.get_rail_side(),
    }
    if not computed then return nil, err end
    self.layout_geometry = computed
    self.dimen = computed.screen_rect
    self.interactive_regions.rail = computed.rail_rect
    self:_rememberScreenLayout()
    return true
end

function Editor:_rememberScreenLayout()
    self.screen_layout_w = Screen:getWidth()
    self.screen_layout_h = Screen:getHeight()
    self.screen_layout_dpi_scale = Screen:scaleByDPI(160)
    self.screen_layout_rotation = Screen:getRotationMode()
    self.screen_layout_rail_side = self.get_rail_side()
end

function Editor:usesCurrentScreenLayout()
    return self.screen_layout_w == Screen:getWidth()
        and self.screen_layout_h == Screen:getHeight()
        and self.screen_layout_dpi_scale == Screen:scaleByDPI(160)
        and self.screen_layout_rotation == Screen:getRotationMode()
        and self.screen_layout_rail_side == self.get_rail_side()
end

function Editor:viewport()
    local geometry = self.layout_geometry
    if not geometry then return nil, "no_viewport" end
    -- Transform performs the page's aspect fit inside this stable paper area.
    return geometry.paper_rect, geometry.paper_rect
end

function Editor:_currentSession()
    return self.controller:activeSession()
end

function Editor:_initQualityRefresh()
    self.quality_generation = 0
    self.quality_scheduled_kind = nil
    self.quality_scheduled_generation = nil
    self.quality_live_fast = self.get_live_fast() ~= false
    self.quality_action = function()
        local generation = self.quality_scheduled_generation
        self.quality_scheduled_kind = nil
        self.quality_scheduled_generation = nil
        self:_runQualityRefresh(generation)
    end
    self:_clearQualityAccumulator()
    self.covered_repaint = nil
end

function Editor:_clearCoveredRepaint()
    self.covered_repaint = nil
end

function Editor:_coveredRepaintValid(pending)
    if not pending or pending.session ~= self:_currentSession() then return false end
    local surface = pending.session:surface()
    local cache = surface and surface:cache()
    return surface and cache ~= nil
        and pending.page == pending.session:currentPage()
        and pending.transform == surface:transform()
        and pending.cache == cache
        and pending.generation == cache.generation
end

function Editor:_queueCoveredRepaint(box, source, session, transform, cache,
        fast)
    local page = session and session:currentPage()
    if not page then return end
    local generation = cache.generation
    local pending = self.covered_repaint
    if not pending or pending.session ~= session or pending.page ~= page
        or pending.transform ~= transform or pending.cache ~= cache
        or pending.generation ~= generation then
        pending = {
            session = session, page = page, transform = transform,
            cache = cache, generation = generation,
            screen_left = box.x, screen_top = box.y,
            screen_right = box.x + box.w, screen_bottom = box.y + box.h,
            source_left = source and source.x,
            source_top = source and source.y,
            source_right = source and source.x + source.w,
            source_bottom = source and source.y + source.h,
            can_blit = source ~= nil,
            needs_partial = not fast,
        }
        self.covered_repaint = pending
        return
    end
    pending.screen_left = math.min(pending.screen_left, box.x)
    pending.screen_top = math.min(pending.screen_top, box.y)
    pending.screen_right = math.max(pending.screen_right, box.x + box.w)
    pending.screen_bottom = math.max(pending.screen_bottom, box.y + box.h)
    pending.needs_partial = pending.needs_partial or not fast
    if not source or not pending.can_blit then
        pending.can_blit = false
        return
    end
    pending.source_left = math.min(pending.source_left, source.x)
    pending.source_top = math.min(pending.source_top, source.y)
    pending.source_right = math.max(pending.source_right, source.x + source.w)
    pending.source_bottom = math.max(pending.source_bottom, source.y + source.h)
end

function Editor:_flushCoveredRepaint(already_painted)
    local pending = self.covered_repaint
    if not pending then return true end
    if not self:_coveredRepaintValid(pending) then
        self.covered_repaint = nil
        return nil, "stale_repaint"
    end
    if Stack.visualAbove(self) then return nil, "covered" end
    local buffer
    if not already_painted and pending.can_blit then
        buffer = pending.cache:buffer()
        if not buffer then return nil, "no_buffer" end
    end
    self.covered_repaint = nil
    local box = Geom:new{
        x = pending.screen_left,
        y = pending.screen_top,
        w = pending.screen_right - pending.screen_left,
        h = pending.screen_bottom - pending.screen_top,
    }
    local refresh_box = box
    if pending.needs_partial and self:_qualityHasUnion()
        and self:_qualityBindingMatches(
            pending.session, pending.transform, pending.cache) then
        -- A partial repair hidden by a window also provides the quality
        -- boundary for any earlier fast ink. Refresh their complete union
        -- before clearing the accumulator, including disjoint regions.
        refresh_box = self:_qualityBox():combine(box)
    end
    if not already_painted then
        if not pending.can_blit then
            self:_resetQualityRefresh()
            UIManager:setDirty(self, "partial", refresh_box)
            return true
        end
        Screen.bb:blitFrom(buffer, box.x, box.y,
            pending.source_left, pending.source_top, box.w, box.h)
        self:_restorePaperChromeIfIntersecting(Screen.bb, box)
    end
    UIManager:setDirty(nil, pending.needs_partial and "partial" or "fast",
        refresh_box)
    if pending.needs_partial then self:_resetQualityRefresh() end
    return true
end

function Editor:_clearQualityAccumulator()
    self.quality_min_x = nil
    self.quality_min_y = nil
    self.quality_max_x = nil
    self.quality_max_y = nil
    self.quality_strokes = 0
    self.quality_contact_had_fast_dirty = false
    self.quality_waiting_for_contact_end = false
    self.quality_waiting_for_uncover = false
    self.quality_session = nil
    self.quality_page = nil
    self.quality_transform = nil
    self.quality_cache = nil
end

function Editor:_cancelQualityAction()
    if self.quality_scheduled_kind then
        self.quality_unschedule(self.quality_action)
    end
    self.quality_scheduled_kind = nil
    self.quality_scheduled_generation = nil
end

function Editor:_resetQualityRefresh()
    self:_cancelQualityAction()
    self.quality_generation = self.quality_generation + 1
    self:_clearQualityAccumulator()
end

function Editor:_qualityHasUnion()
    return self.quality_min_x ~= nil
end

function Editor:_qualityBox()
    if not self:_qualityHasUnion() then return nil end
    return Geom:new{
        x = self.quality_min_x,
        y = self.quality_min_y,
        w = self.quality_max_x - self.quality_min_x,
        h = self.quality_max_y - self.quality_min_y,
    }
end

function Editor:_qualityCurrentBinding(session, transform, cache)
    if not session then return nil end
    local surface = session:surface()
    if not surface then return nil end
    return session:currentPage(), transform or surface:transform(), cache or surface:cache()
end

function Editor:_qualityBindingMatches(session, transform, cache)
    if not self:_qualityHasUnion() or session ~= self.quality_session then return false end
    local page, current_transform, current_cache =
        self:_qualityCurrentBinding(session, transform, cache)
    return page ~= nil and page == self.quality_page
        and current_transform == self.quality_transform
        and current_cache == self.quality_cache
end

function Editor:_bindQualityRefresh(session, transform, cache)
    local page, current_transform, current_cache =
        self:_qualityCurrentBinding(session, transform, cache)
    if not page or not current_transform or not current_cache then return nil end
    self.quality_session = session
    self.quality_page = page
    self.quality_transform = current_transform
    self.quality_cache = current_cache
    return true
end

function Editor:_accumulateQualityBox(box, session, transform, cache)
    if not self:_qualityHasUnion() then
        if not self:_bindQualityRefresh(session, transform, cache) then return nil end
        self.quality_min_x = box.x
        self.quality_min_y = box.y
        self.quality_max_x = box.x + box.w
        self.quality_max_y = box.y + box.h
    else
        if not self:_qualityBindingMatches(session, transform, cache) then
            self:_resetQualityRefresh()
            if not self:_bindQualityRefresh(session, transform, cache) then return nil end
            self.quality_min_x = box.x
            self.quality_min_y = box.y
            self.quality_max_x = box.x + box.w
            self.quality_max_y = box.y + box.h
        else
            self.quality_min_x = math.min(self.quality_min_x, box.x)
            self.quality_min_y = math.min(self.quality_min_y, box.y)
            self.quality_max_x = math.max(self.quality_max_x, box.x + box.w)
            self.quality_max_y = math.max(self.quality_max_y, box.y + box.h)
        end
    end
    self.quality_contact_had_fast_dirty = true
    return true
end

function Editor:_qualityBudgetReached()
    if self.quality_strokes >= QUALITY_STROKE_BUDGET then return true end
    local paper = self.layout_geometry and self.layout_geometry.paper_rect
    if not self:_qualityHasUnion() or paper == nil
        or paper.w <= 0 or paper.h <= 0 then
        return false
    end
    return (self.quality_max_x - self.quality_min_x)
        * (self.quality_max_y - self.quality_min_y)
        >= paper.w * paper.h * QUALITY_AREA_RATIO
end

function Editor:_scheduleQualityAction(kind, restart)
    if self.closed or not self:_qualityHasUnion()
        or self.quality_waiting_for_contact_end
        or self.quality_waiting_for_uncover then
        return false
    end
    if kind == "immediate" then
        if self.quality_scheduled_kind == "immediate" then return false end
        self:_cancelQualityAction()
    elseif self.quality_scheduled_kind == "immediate" then
        return false
    elseif self.quality_scheduled_kind == "delayed" then
        if not restart then return false end
        self:_cancelQualityAction()
    end
    self.quality_scheduled_kind = kind
    self.quality_scheduled_generation = self.quality_generation
    self.quality_schedule_in(kind == "immediate" and 0 or QUALITY_DELAY,
        self.quality_action)
    return true
end

function Editor:_runQualityRefresh(generation)
    if generation == nil or generation ~= self.quality_generation
        or self.closed or not self:_qualityHasUnion() then
        return
    end
    if self.quality_session ~= self:_currentSession()
        or not self:_qualityBindingMatches(self.quality_session) then
        self:_resetQualityRefresh()
        return
    end
    if self.has_active_contact() then
        self.quality_waiting_for_contact_end = true
        return
    end
    if Stack.visualAbove(self) then
        self.quality_waiting_for_uncover = true
        return
    end
    local box = self:_qualityBox()
    self:_resetQualityRefresh()
    UIManager:setDirty(nil, "partial", box)
end

function Editor:_qualityCovered()
    if not self:_qualityHasUnion() then return end
    self:_cancelQualityAction()
    self.quality_waiting_for_uncover = true
end

function Editor:_qualityUncovered(after_close)
    if self.closed or not self:_qualityHasUnion() then
        self.quality_waiting_for_uncover = false
        return
    end
    if not after_close and Stack.visualAbove(self) then
        self.quality_waiting_for_uncover = true
        return
    end
    self.quality_waiting_for_uncover = false
    if self.has_active_contact() then
        self.quality_waiting_for_contact_end = true
        return
    end
    self:_scheduleQualityAction("immediate", true)
end

function Editor:_syncQualitySetting(session, transform, cache)
    local live_fast = self.get_live_fast() ~= false
    if live_fast == self.quality_live_fast then return live_fast end
    if not live_fast and self:_qualityHasUnion() then
        self:_cancelQualityAction()
        if not self:_qualityBindingMatches(session, transform, cache) then
            self:_resetQualityRefresh()
        elseif Stack.visualAbove(self) then
            self.quality_waiting_for_uncover = true
        else
            local box = self:_qualityBox()
            self:_resetQualityRefresh()
            UIManager:setDirty(nil, "partial", box)
        end
    else
        self:_resetQualityRefresh()
    end
    self.quality_live_fast = live_fast
    return live_fast
end

function Editor:_clipDirtyBox(screen_box, source_box)
    local paper = self.layout_geometry and self.layout_geometry.paper_rect
    if not paper or not screen_box then return nil end
    local x, y = tonumber(screen_box.x), tonumber(screen_box.y)
    local w, h = tonumber(screen_box.w), tonumber(screen_box.h)
    if not x or not y or not w or not h or w <= 0 or h <= 0 then return nil end
    local sx, sy, sw, sh
    if source_box then
        sx, sy = tonumber(source_box.x), tonumber(source_box.y)
        sw, sh = tonumber(source_box.w), tonumber(source_box.h)
        if not sx or not sy or not sw or not sh or sw <= 0 or sh <= 0 then
            return nil
        end
    end

    -- Adapter dirties are already Geom regions clipped to the viewport, with
    -- an equally-sized cache source. Preserve those objects on the pen hot
    -- path instead of allocating a replacement Geom and source table for every
    -- sample. Less common plain-table and clipped inputs retain the old path.
    local already_clipped = x >= paper.x and y >= paper.y
        and x + w <= paper.x + paper.w
        and y + h <= paper.y + paper.h
        and type(screen_box.combine) == "function"
    if already_clipped and (not source_box or (sw == w and sh == h)) then
        return screen_box, source_box
    end

    local left = math.max(x, paper.x)
    local top = math.max(y, paper.y)
    local right = math.min(x + w, paper.x + paper.w)
    local bottom = math.min(y + h, paper.y + paper.h)
    if right <= left or bottom <= top then return nil end
    local clipped_source
    if source_box then
        local dx, dy = left - x, top - y
        right = math.min(right, left + sw - dx)
        bottom = math.min(bottom, top + sh - dy)
        if right <= left or bottom <= top then return nil end
        clipped_source = {
            x = sx + dx, y = sy + dy,
            w = right - left, h = bottom - top,
        }
    end
    return Geom:new{ x = left, y = top, w = right - left, h = bottom - top },
        clipped_source
end

--- Restore only the portions of the paper border overwritten by a direct cache
--- blit. Work stays proportional to the dirty box even for a nib on an edge.
function Editor:_restorePaperChromeIfIntersecting(screen_bb, box)
    local paper = self.layout_geometry and self.layout_geometry.paper_rect
    if not screen_bb or not paper or not box then return false end
    local bx, by = box.x, box.y
    local br, bb = bx + box.w, by + box.h
    local rule = Size.border.window
    local restored = false

    local left, right = math.max(bx, paper.x), math.min(br, paper.x + paper.w)
    local top, bottom = math.max(by, paper.y), math.min(bb, paper.y + rule)
    if right > left and bottom > top then
        screen_bb:paintRect(left, top, right - left, bottom - top,
            Blitbuffer.COLOR_BLACK)
        restored = true
    end

    left, right = math.max(bx, paper.x), math.min(br, paper.x + rule)
    top, bottom = math.max(by, paper.y), math.min(bb, paper.y + paper.h)
    if right > left and bottom > top then
        screen_bb:paintRect(left, top, right - left, bottom - top,
            Blitbuffer.COLOR_BLACK)
        restored = true
    end
    return restored
end

function Editor:_qualityContactBoundary(session)
    if not self.quality_live_fast or not self:_qualityHasUnion() then return end
    if not self:_qualityBindingMatches(session) then
        self:_resetQualityRefresh()
        return
    end
    local completed = self.quality_contact_had_fast_dirty
    local was_waiting = self.quality_waiting_for_contact_end
    if not completed and not was_waiting then return end
    if completed then
        self.quality_strokes = self.quality_strokes + 1
        self.quality_contact_had_fast_dirty = false
    end
    self.quality_waiting_for_contact_end = false
    if Stack.visualAbove(self) then
        self:_qualityCovered()
        return
    end
    self:_scheduleQualityAction(self:_qualityBudgetReached()
        and "immediate" or "delayed", completed or was_waiting)
end

--[[--
Re-read the snapshot and repaint the rail only if what it can do changed.

The reason this is not folded into onEditChanged: a palm resting on the glass
blocks navigation without editing anything, so the only event that can unblock
it is the last contact ending. Missing that is how Add page stayed disabled
with nothing on the screen.
]]
function Editor:_refreshActionAvailability()
    local before = self.snapshot
    local snapshot = self:_refreshSnapshot()
    if not snapshot then return false end
    if before and before.can_navigate == snapshot.can_navigate
        and before.writable == snapshot.writable
        and before.can_ink == snapshot.can_ink
        and before.can_undo == snapshot.can_undo
        and before.can_close == snapshot.can_close
        and before.has_previous == snapshot.has_previous
        and before.has_next == snapshot.has_next then
        return false
    end
    self:_rebuildControls()
    self:_dirtyRail()
    return true
end

function Editor:onPhysicalContactEnd(session)
    if self.closed or session ~= self:_currentSession() then return end
    -- Unconditional: the e-ink quality pass has its own bookkeeping and may
    -- have nothing to do, but the rail's capability always has to catch up.
    self:_refreshActionAvailability()
    if not self.quality_waiting_for_contact_end then return end
    self:_syncQualitySetting(session)
    if self.quality_waiting_for_contact_end then
        self:_qualityContactBoundary(session)
    end
end

function Editor:onFullRepaint()
    self:_resetQualityRefresh()
end

function Editor:_refreshSnapshot()
    local snapshot = self.controller:uiSnapshot()
    if snapshot then self.snapshot = snapshot end
    return self.snapshot
end

function Editor:_errorForSnapshot(snapshot)
    if not snapshot then return nil end
    return snapshot.error_code
end

function Editor:_errorCopy(code)
    if code == "page_load_failed" then
        return _("Couldn’t load this page."),
            _("Your previous ink is still saved. Try loading the page again."),
            _("Retry loading")
    elseif code == "page_save_failed" then
        return _("This page’s ink hasn’t been saved."),
            _("It is still on this device. You can’t leave this notebook or change pages until it is saved."),
            _("Retry saving")
    elseif code == "pen_input_failed" then
        return _("Pen input stopped responding."), nil, _("Retry pen input")
    end
end

function Editor:_errorHeight()
    if not self:_errorForSnapshot(self.snapshot) then return 0 end
    return self.error_expanded and math.max(self.layout_geometry.target_size * 2,
        math.floor(self.layout_geometry.paper_rect.h * 0.18))
        or self.layout_geometry.target_size
end

function Editor:_publishErrorRegion()
    local code = self:_errorForSnapshot(self.snapshot)
    if not code then
        self.interactive_regions.error_band = nil
        return
    end
    local paper = self.layout_geometry.paper_rect
    local height = math.min(paper.h, self:_errorHeight())
    self.interactive_regions.error_band = Geom:new{
        x = paper.x, y = paper.y + paper.h - height, w = paper.w, h = height,
    }
end

function Editor:stylusPassthrough(x, y)
    return Stack.above(self) ~= nil
        or inside(self.interactive_regions.rail, x, y)
        or inside(self.interactive_regions.error_band, x, y)
        or inside(self.interactive_regions.modal, x, y)
end

function Editor:touchPassthrough(x, y)
    if not self:stylusPassthrough(x, y) then return false end
    if self.control_touch_allowed and not self.control_touch_allowed() then return false end
    return true
end

function Editor:_button(text, enabled, callback, rect, help_text, checked_func)
    local button = Button:new{
        text = text,
        help_text = help_text or text,
        show_parent = self,
        width = rect.w,
        height = rect.h,
        margin = 0,
        padding = Size.padding.button,
        enabled = enabled and true or false,
        checked_func = checked_func,
        callback = function()
            if enabled and not self.closed then callback() end
        end,
    }
    self.control_entries[#self.control_entries + 1] = { widget = button, rect = rect }
    self[#self + 1] = button
    return button
end

function Editor:_railRects()
    local rail = self.layout_geometry.rail_rect
    local target = self.layout_geometry.target_size
    local top_names = { "exit", "pen", "eraser", "undo" }
    local bottom_names = { "previous", "next", "add", "more" }
    local rects = {}
    for i = 1, #top_names do
        rects[top_names[i]] = Geom:new{
            x = rail.x, y = rail.y + (i - 1) * target, w = rail.w, h = target,
        }
    end
    for i = 1, #bottom_names do
        rects[bottom_names[i]] = Geom:new{
            x = rail.x, y = rail.y + rail.h - (#bottom_names - i + 1) * target,
            w = rail.w, h = target,
        }
    end
    return rects
end

function Editor:_rebuildControls()
    for i = #self, 1, -1 do self[i] = nil end
    self.control_entries = {}
    self.layout = {}
    self:_publishErrorRegion()
    local snapshot = self.snapshot
    local rects = self:_railRects()
    local exit = self:_button(_("Exit notebook"), snapshot.can_close,
        function() self:requestClose() end, rects.exit)
    local pen = self:_button(_("Pen"), snapshot.can_ink,
        function() self.set_eraser(false); self:_rebuildControls(); self:_dirtyRail() end,
        rects.pen, nil, function() return not self.get_eraser() end)
    local eraser = self:_button(_("Eraser"), snapshot.can_ink,
        function() self.set_eraser(true); self:_rebuildControls(); self:_dirtyRail() end,
        rects.eraser, nil, function() return self.get_eraser() end)
    -- Enabled state and the domain gate come from one function, so a control
    -- can look wrong only for as long as the snapshot behind it is stale --
    -- and never disagree about what would happen if it were pressed.
    local undo = self:_button(_("Undo"), self:_actionAvailability("undo", snapshot),
        function() self:_runDomain("undo") end, rects.undo)
    local previous = self:_button(_("Previous page"),
        self:_actionAvailability("previous", snapshot),
        function() self:_runDomain("previous") end, rects.previous)
    local next_button = self:_button(_("Next page"),
        self:_actionAvailability("next", snapshot),
        function() self:_runDomain("next") end, rects.next)
    local add = self:_button(_("Add page"), self:_actionAvailability("add", snapshot),
        function() self:_runDomain("add") end, rects.add)
    local more = self:_button(_("More"), snapshot.state ~= "loading",
        function() self:showMore() end, rects.more)
    self.layout = {
        { exit }, { pen }, { eraser }, { undo },
        { previous }, { next_button }, { add }, { more },
    }

    local error = self.interactive_regions.error_band
    if error then
        local target = self.layout_geometry.target_size
        local retry_rect = Geom:new{
            x = error.x + error.w - target * 2, y = error.y,
            w = target * 2, h = math.min(target, error.h),
        }
        local retry = self:_button(select(3, self:_errorCopy(snapshot.error_code)), true,
            function() self:retryError() end, retry_rect)
        local minimize_rect = Geom:new{
            x = error.x, y = error.y, w = target * 2, h = math.min(target, error.h),
        }
        local minimize = self:_button(self.error_expanded and _("Minimize") or _("Error"), true,
            function()
                local old_region = self.interactive_regions.error_band:copy()
                self.error_expanded = not self.error_expanded
                self:_publishErrorRegion()
                self:_rebuildControls()
                UIManager:setDirty(self, "ui",
                    old_region:combine(self.interactive_regions.error_band))
            end, minimize_rect)
        self.layout[#self.layout + 1] = { minimize, retry }
    end
    local selected = self.selected or { x = 1, y = 1 }
    selected.y = math.max(1, math.min(selected.y, #self.layout))
    selected.x = math.max(1, math.min(selected.x, #self.layout[selected.y]))
    self.selected = selected
    if self.shown and self.refocusWidget then self:refocusWidget() end
end

function Editor:_dirtyRail()
    UIManager:setDirty(self, "ui", self.layout_geometry.rail_rect)
end

function Editor:_showInfo(text)
    return self:showModalSafely(InfoMessage:new{ text = text })
end

--[[--
Whether one rail action may run right now, and if not, why.

The single source of truth for both the button's enabled state and the domain
call, because they used to disagree. A Button closes over the enabled flag it
was built with, so a snapshot that changed since -- a palm lifting, a page
finishing its save -- left a control that looked live and did nothing, or
looked dead while the action was available.

The reason is a closed token: `contact_active`, `transition_pending`,
`save_failed`, `load_failed`, `loading` and `closed` come from the session,
`read_only` and `boundary` are this widget's own.
]]
function Editor:_actionAvailability(action, snapshot)
    snapshot = snapshot or self.snapshot
    if not snapshot then return false, "loading" end
    if action == "undo" then
        if snapshot.can_undo then return true end
        return false, snapshot.navigation_block_reason or "unavailable"
    end
    if not snapshot.can_navigate then
        return false, snapshot.navigation_block_reason or "unavailable"
    end
    if action == "previous" then
        if snapshot.has_previous then return true end
        return false, "boundary"
    elseif action == "next" then
        if snapshot.has_next then return true end
        return false, "boundary"
    elseif action == "add" then
        if snapshot.writable then return true end
        return false, "read_only"
    end
    return false, "unavailable"
end

--[[--
Say why an activated action did nothing.

A KOReader Button draws its pressed state before the callback runs, so the
flash is proof the tap arrived and nothing more. Without this, "Add page
flashes and does nothing" is all the reader ever learns.
]]
function Editor:_reportBlockedAction(action, reason)
    logger.info("JustDraw notebooks: action blocked:", action, reason)
    if reason == "contact_active" then
        self:_showInfo(_("Lift the pen and your hand, then try again."))
    elseif reason == "boundary" then
        self:_showInfo(action == "previous" and _("First page") or _("Last page"))
    elseif reason == "save_failed" or reason == "load_failed" then
        -- The error band already carries the explanation and its retry; a
        -- second modal over it would only be one more thing to dismiss.
        self:onStateChanged()
    end
end

function Editor:_runDomain(action)
    local snapshot = self:_refreshSnapshot()
    local enabled, blocked_reason = self:_actionAvailability(action, snapshot)
    if not enabled then
        self:_reportBlockedAction(action, blocked_reason)
        return nil, blocked_reason or "disabled"
    end
    local ok, err
    if action == "undo" then
        ok, err = self.controller:undo()
    elseif action == "previous" then
        ok, err = self.controller:goPrevious()
    elseif action == "next" then
        ok, err = self.controller:goNext()
    elseif action == "add" then
        ok, err = self.controller:appendPage()
    else
        return nil, "disabled"
    end
    if not ok then
        if err == "contact_active" or err == "boundary" then
            self:_reportBlockedAction(action, err)
        else
            logger.warn("JustDraw notebooks: editor action failed:", action, err)
            self:onStateChanged()
        end
        return nil, err
    end
    return ok
end

function Editor:onDirty(screen_box, kind, session, transform, source_box)
    if self.closed or session ~= self:_currentSession() then return end
    local active = session:surface()
    if not active or transform ~= active:transform() then return end
    local cache = active:cache()
    if not cache then return end
    if self:_qualityHasUnion()
        and not self:_qualityBindingMatches(session, transform, cache) then
        self:_resetQualityRefresh()
    end
    local live_fast = self:_syncQualitySetting(session, transform, cache)
    local exact_box, exact_source = self:_clipDirtyBox(screen_box, source_box)
    if not exact_box then return end
    local live_kind = kind == "ink" or kind == "erase"
    -- A dirty produced under any visual window, including a toast, cannot be
    -- copied directly without punching through it. Retain one O(1) union bound
    -- to this exact page/cache/transform and present it after uncover.
    if Stack.visualAbove(self) then
        self:_queueCoveredRepaint(exact_box, exact_source,
            session, transform, cache, live_kind and live_fast)
        if live_kind and live_fast then
            self:_accumulateQualityBox(exact_box, session, transform, cache)
        end
        self:_qualityCovered()
        return
    end
    self:_flushCoveredRepaint(false)
    if self.quality_waiting_for_uncover then self:_qualityUncovered() end
    local buffer = cache:buffer()
    if buffer and Screen.bb and exact_source then
        Screen.bb:blitFrom(buffer, exact_box.x, exact_box.y,
            exact_source.x, exact_source.y, exact_source.w, exact_source.h)
        self:_restorePaperChromeIfIntersecting(Screen.bb, exact_box)
    end

    if live_kind and live_fast then
        -- Passing nil schedules only the panel update; repainting Editor here
        -- would redraw the full page and controls for every pen segment.
        UIManager:setDirty(nil, "fast", exact_box)
        if self:_accumulateQualityBox(exact_box, session, transform, cache)
            and self:_qualityBudgetReached() then
            self:_scheduleQualityAction("immediate")
        end
        return
    end

    local refresh_box = exact_box
    if not live_kind and self:_qualityHasUnion()
        and self:_qualityBindingMatches(session, transform, cache) then
        refresh_box = self:_qualityBox():combine(exact_box)
    end
    if not live_kind then self:_resetQualityRefresh() end
    UIManager:setDirty(nil, "partial", refresh_box)
end

function Editor:onEditChanged(session)
    if self.closed or session ~= self:_currentSession() then return end
    self:_syncQualitySetting(session)
    self:_qualityContactBoundary(session)
    local previous_can_undo = self.snapshot and self.snapshot.can_undo
    self:_refreshSnapshot()
    -- A completed stroke changes persistence state on every lift, but v1 has
    -- no visible save indicator. Once Undo is already enabled there is
    -- therefore nothing to redraw. Keeping this path empty is important on
    -- e-ink: dirtying Editor would run its full-screen paintTo even with a
    -- regional refresh box.
    if previous_can_undo == self.snapshot.can_undo then return end
    self:_rebuildControls()
    if self.shown and not Stack.visualAbove(self) then
        local rail = self.layout_geometry.rail_rect
        self:_paintRailTo(Screen.bb)
        UIManager:setDirty(nil, "ui", rail)
    end
end

function Editor:onDurableChanged(session)
    if self.closed or session ~= self:_currentSession() then return end
    -- Library recency is updated by the coordinator. The editor deliberately
    -- has no Saved label in v1, so a commit with no visible state change needs
    -- no repaint.
    self:_refreshSnapshot()
end

function Editor:onPageReady()
    if self.closed then return end
    self:_clearCoveredRepaint()
    self:_resetQualityRefresh()
    self:_computeLayout()
    self:_refreshSnapshot()
    self:_rebuildControls()
    if self.shown and not self.resize_in_progress then
        UIManager:setDirty(self, "full")
    end
end

function Editor:onStateChanged()
    if self.closed then return end
    local previous_state = self.snapshot and self.snapshot.state
    local previous_error = self.snapshot and self.snapshot.error_code
    self:_refreshSnapshot()
    -- Publish an error band before capture can classify the next contact.
    self:_publishErrorRegion()
    self:_rebuildControls()
    if self.shown and not self.resize_in_progress then
        if previous_state ~= self.snapshot.state
            or previous_error ~= self.snapshot.error_code then
            UIManager:setDirty(self, "ui")
        else
            UIManager:setDirty(self, "ui", self.layout_geometry.rail_rect)
        end
    end
end

function Editor:markShown()
    self.shown = true
    if self.refocusWidget then self:refocusWidget() end
end

function Editor:_paintText(bb, text, rect, face, align)
    if not text or text == "" then return end
    local widget = TextWidget:new{
        text = text, face = face, max_width = rect.w - 2 * Size.padding.small,
        bold = false,
    }
    local size = widget:getSize()
    local x = rect.x + Size.padding.small
    if align == "center" then x = rect.x + math.floor((rect.w - size.w) / 2) end
    local y = rect.y + math.max(0, math.floor((rect.h - size.h) / 2))
    widget:paintTo(bb, x, y)
    widget:free()
end

function Editor:_paintRailTo(bb)
    if not bb then return end
    local rail = self.layout_geometry.rail_rect
    bb:paintRect(rail.x, rail.y, rail.w, rail.h, Blitbuffer.COLOR_LIGHT_GRAY)
    for i = 1, #self.control_entries do
        local entry = self.control_entries[i]
        if entry.rect:intersectWith(rail) then
            entry.widget:paintTo(bb, entry.rect.x, entry.rect.y)
        end
    end
end

function Editor:paintTo(bb, x, y)
    local geometry = self.layout_geometry
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(geometry.rail_rect.x, geometry.rail_rect.y,
        geometry.rail_rect.w, geometry.rail_rect.h, Blitbuffer.COLOR_LIGHT_GRAY)
    local surface = self:_currentSession() and self:_currentSession():surface()
    if surface and surface:cache() and surface:isReady() then surface:cache():paintTo(bb) end
    local border = Size.border.window
    bb:paintRect(geometry.paper_rect.x, geometry.paper_rect.y,
        geometry.paper_rect.w, border, Blitbuffer.COLOR_BLACK)
    bb:paintRect(geometry.paper_rect.x, geometry.paper_rect.y,
        border, geometry.paper_rect.h, Blitbuffer.COLOR_BLACK)
    local info = pageCountText(self.snapshot.page_count)
    if self.snapshot.can_navigate and not self.snapshot.has_previous then
        info = info .. " · " .. _("First page")
    elseif self.snapshot.can_navigate and not self.snapshot.has_next then
        info = info .. " · " .. _("Last page")
    end
    if self.snapshot.writable == false and self.snapshot.state == "ready" then
        info = info .. " · " .. _("Read-only")
    end
    local title_rect = Geom:new{
        x = geometry.info_rect.x, y = geometry.info_rect.y,
        w = math.floor(geometry.info_rect.w / 2), h = geometry.info_rect.h,
    }
    self:_paintText(bb, BD.auto(self.notebook.title), title_rect,
        Font:getFace("smallinfofont", 22), nil)
    local status_rect = Geom:new{
        x = geometry.info_rect.x + math.floor(geometry.info_rect.w / 2),
        y = geometry.info_rect.y, w = math.floor(geometry.info_rect.w / 2),
        h = geometry.info_rect.h,
    }
    self:_paintText(bb, info, status_rect, Font:getFace("smallinfofont", 18), "center")
    if self.snapshot.state == "loading" then
        self:_paintText(bb, _("Loading page…"), geometry.paper_rect,
            Font:getFace("cfont", 24), "center")
    end
    local error = self.interactive_regions.error_band
    if error then
        bb:paintRect(error.x, error.y, error.w, error.h, Blitbuffer.COLOR_WHITE)
        bb:paintRect(error.x, error.y, error.w, border, Blitbuffer.COLOR_BLACK)
        if self.error_expanded then
            local title, body = self:_errorCopy(self.snapshot.error_code)
            local text_rect = Geom:new{
                x = error.x + self.layout_geometry.target_size * 2,
                y = error.y, w = error.w - self.layout_geometry.target_size * 4,
                h = error.h,
            }
            self:_paintText(bb, body and (title .. " " .. body) or title, text_rect,
                Font:getFace("smallinfofont", 18), "center")
        end
    end
    for i = 1, #self.control_entries do
        local entry = self.control_entries[i]
        entry.widget:paintTo(bb, entry.rect.x, entry.rect.y)
    end
    self:_flushCoveredRepaint(true)
    if self.quality_waiting_for_uncover and not Stack.visualAbove(self) then
        self:_qualityUncovered(true)
    end
end

function Editor:_finishResize()
    self:_resetQualityRefresh()
    self:_registerEvents()
    self:_refreshSnapshot()
    self:_rebuildControls()
    -- A same-scale transform can remain ready without a page-ready callback.
    -- In that case this is the only transition refresh.
    if self.shown and self.snapshot.state ~= "loading" then
        UIManager:setDirty(self, "full")
    end
end

function Editor:retryError()
    local code = self.snapshot.error_code
    local ok, err
    if code == "page_load_failed" then ok, err = self.controller:retryLoad()
    elseif code == "page_save_failed" then
        local pending_resize = self.pending_resize
        if pending_resize then self.resize_in_progress = true end
        ok, err = self.controller:retrySave()
        if ok and pending_resize then
            ok, err = self.controller:onScreenResize(
                pending_resize.paper_rect, pending_resize.paper_rect)
        end
        if pending_resize then self.resize_in_progress = false end
        if ok and pending_resize then
            self.pending_resize = nil
            self:_finishResize()
            return ok, err
        end
    elseif code == "pen_input_failed" then ok, err = self.controller:retryInput()
    end
    if not ok then logger.warn("JustDraw notebooks: retry failed:", code, err) end
    self:onStateChanged()
    return ok, err
end

function Editor:requestClose()
    local snapshot = self:_refreshSnapshot()
    if not snapshot.can_close then
        self:_showInfo(snapshot.state == "save_failed"
            and _("This page’s ink hasn’t been saved.")
            or _("Lift the pen and try again."))
        return nil, snapshot.state
    end
    local ok, err = self.controller:closeNotebook()
    if not ok then
        logger.warn("JustDraw notebooks: close failed:", err)
        self:onStateChanged()
        return nil, err
    end
    if self.on_close then self.on_close(self) end
    return true
end

function Editor:onClose()
    self:requestClose()
    return true
end

function Editor:showModalSafely(widget)
    if self.closed then return nil, "closed" end
    if self.has_active_contact and self.has_active_contact() then
        return nil, "contact_active"
    end
    self:_qualityCovered()
    self.interactive_regions.modal = self.dimen:copy()
    self.modal_widgets[widget] = true
    self.modal_widget = widget
    local previous = widget.onCloseWidget
    widget.onCloseWidget = function(dialog, ...)
        if previous then previous(dialog, ...) end
        self.modal_widgets[dialog] = nil
        if self.modal_widget == dialog then
            self.modal_widget = next(self.modal_widgets)
        end
        self.interactive_regions.modal = not self.closed
            and next(self.modal_widgets) and self.dimen:copy() or nil
        if not self.closed and not next(self.modal_widgets) then
            self:_flushCoveredRepaint(false)
            self:_qualityUncovered(true)
        end
    end
    widget.show_parent = widget
    UIManager:show(widget)
    return widget
end

function Editor:_closeModal(widget)
    self.modal_widgets[widget] = nil
    if self.modal_widget == widget then self.modal_widget = next(self.modal_widgets) end
    UIManager:close(widget)
    self.interactive_regions.modal = next(self.modal_widgets)
        and self.dimen:copy() or nil
    self:_flushCoveredRepaint(false)
    self:_qualityUncovered()
end

function Editor:showRename()
    local dialog
    dialog = InputDialog:new{
        title = _("Rename notebook"), input = self.notebook.title,
        buttons = {{
            { text = _("Cancel"), callback = function() self:_closeModal(dialog) end },
            { text = _("Rename"), callback = function()
                local title = dialog:getInputText():match("^%s*(.-)%s*$")
                if title == "" then self:_showInfo(_("Notebook name can’t be empty.")); return end
                if #title > 255 then self:_showInfo(_("Notebook name is too long. Use a shorter name.")); return end
                local ok, err = self.controller:renameNotebook(self.notebook.id, title)
                if not ok then
                    logger.warn("JustDraw notebooks: rename failed:", err)
                    self:_showInfo(_("Couldn’t rename this notebook. Try again."))
                    return
                end
                self.notebook.title = title
                self:_closeModal(dialog)
                UIManager:setDirty(self, "ui", self.layout_geometry.info_rect)
            end },
        }},
    }
    return self:showModalSafely(dialog)
end

function Editor:confirmDeletePage()
    if self.snapshot.page_count <= 1 then
        self:_showInfo(_("A notebook must keep at least one page, so this page can’t be deleted."))
        return nil, "last_page"
    end
    local box
    box = ConfirmBox:new{
        text = _("Delete this page and its ink? The rest of the notebook won’t change. This can’t be undone."),
        ok_text = _("Delete"),
        keep_dialog_open = true,
        ok_callback = function()
            local ok, err = self.controller:deleteCurrentPage()
            if not ok then
                logger.warn("JustDraw notebooks: page delete failed:", err)
                self:onStateChanged()
                return
            end
            self:_closeModal(box)
        end,
        cancel_callback = function() self:_closeModal(box) end,
    }
    return self:showModalSafely(box)
end

function Editor:confirmDeleteNotebook()
    local box
    box = ConfirmBox:new{
        text = T(_("Delete “%1”? This deletes its %2 and all ink. This can’t be undone."),
            BD.auto(self.notebook.title), pageCountText(self.snapshot.page_count)),
        ok_text = _("Delete"),
        keep_dialog_open = true,
        ok_callback = function()
            local closed, close_err = self.controller:closeNotebook()
            if not closed then
                logger.warn("JustDraw notebooks: close before delete failed:", close_err)
                self:_closeModal(box); self:onStateChanged(); return
            end
            local deleted, delete_err = self.controller:deleteNotebook(self.notebook.id)
            if not deleted then
                logger.warn("JustDraw notebooks: delete failed:", delete_err)
                self:_closeModal(box)
                if self.on_close then self.on_close(self) end
                -- closeNotebook has already released this editor and its
                -- input lease. Report through the uncovered host instead of
                -- trying to attach a modal to the destroyed editor.
                self.show_host_message(_("Couldn’t delete this notebook. Try again."))
                return
            end
            self:_closeModal(box)
            if self.on_close then self.on_close(self) end
        end,
        cancel_callback = function() self:_closeModal(box) end,
    }
    return self:showModalSafely(box)
end

function Editor:showMore()
    local dialog
    local writable = self.snapshot.writable and self.snapshot.can_navigate
    dialog = ButtonDialog:new{
        title = _("More"),
        buttons = {
            {{ text = _("Rename notebook"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:showRename()
            end }},
            {{ text = _("Delete page"), enabled = writable and self.snapshot.page_count > 1,
                callback = function() self:_closeModal(dialog); self:confirmDeletePage() end }},
            {{ text = _("Delete notebook"), enabled = writable, callback = function()
                self:_closeModal(dialog); self:confirmDeleteNotebook()
            end }},
            {{ text = _("Input mode"), callback = function()
                self:_closeModal(dialog); self:showInputMode()
            end }},
            {{ text = _("Pen width"), callback = function()
                self:_closeModal(dialog); self:showPenWidth()
            end }},
            {{ text = _("Rail side"), callback = function()
                self.set_rail_side(self.get_rail_side() == "left" and "right" or "left")
                self:_closeModal(dialog)
                self:onSetDimensions()
            end }},
            {{ text = _("Stylus diagnostics"), callback = function()
                self:_closeModal(dialog)
                self.show_stylus_diagnostics()
            end }},
            {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }},
        },
    }
    return self:showModalSafely(dialog)
end

function Editor:showInputMode()
    local dialog
    local function choose(value)
        local changed, err = self.set_input_mode(value)
        self:_closeModal(dialog)
        if not changed then
            logger.warn("JustDraw notebooks: input mode change failed:", err)
            if err == "contact_active" then self:_showInfo(_("Lift the pen and try again.")) end
        end
        self:onStateChanged()
    end
    local current = self.get_input_mode()
    dialog = ButtonDialog:new{
        title = _("Input mode"),
        buttons = {
            {{ text = _("Automatic"), checked_func = function() return current == "auto" end,
                callback = function() choose("auto") end }},
            {{ text = _("Stylus"), checked_func = function() return current == "stylus" end,
                callback = function() choose("stylus") end }},
            {{ text = _("Finger"), checked_func = function() return current == "finger" end,
                callback = function() choose("finger") end }},
            {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }},
        },
    }
    return self:showModalSafely(dialog)
end

function Editor:showPenWidth()
    local dialog
    local function choose(value)
        self.set_pen_width(value)
        self:_closeModal(dialog)
    end
    local current = self.get_pen_width()
    dialog = ButtonDialog:new{
        title = _("Pen width"),
        buttons = {
            {{ text = _("Thin"), checked_func = function() return current == 2 end,
                callback = function() choose(2) end }},
            {{ text = _("Medium"), checked_func = function() return current == 4 end,
                callback = function() choose(4) end }},
            {{ text = _("Thick"), checked_func = function() return current == 7 end,
                callback = function() choose(7) end }},
            {{ text = _("Close"), callback = function() self:_closeModal(dialog) end }},
        },
    }
    return self:showModalSafely(dialog)
end

function Editor:onSetDimensions()
    if self.closed then return true end
    self:_clearCoveredRepaint()
    self:_resetQualityRefresh()
    local old_modal = self.interactive_regions.modal
    local computed, compute_err = NotebookLayout.compute{
        logical_w = self:_currentSession() and self:_currentSession():currentPage().logical_w or 1184,
        logical_h = self:_currentSession() and self:_currentSession():currentPage().logical_h or 1680,
        rail_side = self.get_rail_side(),
    }
    if not computed then return nil, compute_err end
    self.layout_geometry = computed
    self.dimen = computed.screen_rect
    self.interactive_regions.rail = computed.rail_rect
    self:_rememberScreenLayout()
    self:_publishErrorRegion()
    -- Capture must see the new full-screen modal region before resize releases
    -- and reacquires input with the new paper transform.
    if next(self.modal_widgets) then self.interactive_regions.modal = self.dimen:copy() end
    self.resize_in_progress = true
    local resized, resize_err = self.controller:onScreenResize(computed.paper_rect, computed.paper_rect)
    self.resize_in_progress = false
    if not resized then
        -- The surface keeps its previous durable raster/transform, but the
        -- window envelope and chrome must still match the rotated Screen.
        self.pending_resize = computed
        self.interactive_regions.modal = next(self.modal_widgets) and self.dimen:copy()
            or old_modal and self.dimen:copy() or nil
        self:_finishResize()
        return nil, resize_err
    end
    self.pending_resize = nil
    self:_finishResize()
    return true
end

function Editor:shutdown()
    if self.closed then return true end
    self:_clearCoveredRepaint()
    self:_resetQualityRefresh()
    self.closed = true
    local modals = self.modal_widgets
    self.modal_widgets = {}
    self.modal_widget = nil
    for modal in pairs(modals) do UIManager:close(modal) end
    self.shown = false
    self.interactive_regions = {}
    self.pending_resize = nil
    for i = #self, 1, -1 do self[i] = nil end
    self.control_entries = {}
    return true
end

return Editor
