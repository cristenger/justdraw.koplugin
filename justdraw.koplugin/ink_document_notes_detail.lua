-- Use KOReader's pan/zoom implementation with explicit note navigation.
local ImageViewer = require("ui/widget/imageviewer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Detail = ImageViewer:extend{ fullscreen = true, image_disposable = false, buttons_visible = true }

function Detail:init()
    -- ImageViewer.init ends with self:update(). Wait for our replacement buttons
    -- so we build the image and queue its refresh only once.
    self._initializing = true
    ImageViewer.init(self)
    self.button_container:free()
    self.button_table = ButtonTable:new{ width = self.width - 2 * self.button_padding,
        zero_sep = true, show_parent = self,
        buttons = {
            {{text = self.previous_label or _("Previous note"), enabled = self.has_previous, callback = self.previous_note},
             {text = self.next_label or _("Next note"), enabled = self.has_next, callback = self.next_note}},
            {{text = _("Go to document"), enabled = self.can_navigate, callback = self.go_to_document},
             {text = _("Actions…"), callback = self.note_actions}},
            {{id = "scale", text = _("Scale"), callback = function()
                self.scale_factor = self._scale_to_fit and 1 or 0
                self._scale_to_fit = not self._scale_to_fit
                self._center_x_ratio, self._center_y_ratio = 0.5, 0.5; self:update()
             end},
             {id = "rotate", text = _("Rotate"), callback = function()
                self.rotated = not self.rotated; self:update()
             end},
             {text = "−", callback = function() self:onZoomOut() end},
             {text = "+", callback = function() self:onZoomIn() end}},
        } }
    self.button_container = CenterContainer:new{ dimen = Geom:new{
        w = self.width, h = self.button_table:getSize().h }, self.button_table }
    self._initializing = nil
    self:update()
end

-- Single-image layout from KOReader ImageViewer.update (9192014d8b / 5ec0242b50).
-- Own the refresh callback: an async preview can close, be replaced, or become
-- covered before its first paint. The upstream callback dereferences dimen even
-- in that case. Keep pan/zoom and raster disposal in the upstream ImageViewer.
function Detail:update()
    if self._initializing or self._closed then return end
    self:_clean_image_wg()
    local orig_dimen = self.main_frame.dimen and self.main_frame.dimen:copy()
    self.height = Screen:getHeight() - (self.fullscreen and 0 or Screen:scaleBySize(40))
    self.width = Screen:getWidth() - (self.fullscreen and 0 or Screen:scaleBySize(40))
    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()
    if self.with_title_bar then
        table.insert(self.frame_elements,
            self.caption and self.caption_visible and self.captioned_title_bar or self.title_bar)
    end
    local image_index = #self.frame_elements + 1
    if self.buttons_visible then
        local scale = self.button_table:getButtonById("scale")
        scale:setText(self._scale_to_fit and _("Original size") or _("Scale"), scale.width)
        local rotate = self.button_table:getButtonById("rotate")
        rotate:setText(self.rotated and _("No rotation") or _("Rotate"), rotate.width)
        table.insert(self.frame_elements, self.button_container)
    end
    self.img_container_h = self.height - self.frame_elements:getSize().h
    self:_new_image_wg()
    table.insert(self.frame_elements, image_index, self.image_container)
    self.frame_elements:resetLayout()
    self.main_frame.radius = not self.fullscreen and 8 or nil
    self:queueRefresh(Device:hasKaleidoWfm() and "partial" or "ui", orig_dimen)
end

function Detail:queueRefresh(mode, previous_region)
    self.dithered = true
    UIManager:setDirty(self, function()
        local region = self.main_frame.dimen
        if self._closed or not region then return end
        return mode, region:combine(previous_region), true
    end)
end

function Detail:onShow()
    self:queueRefresh("full")
    return true
end

function Detail:onCloseWidget()
    self._closed = true
    ImageViewer.onCloseWidget(self)
end

function Detail:onClose() self.close_note(); return true end

return Detail
