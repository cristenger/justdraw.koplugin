-- Complete fixed pages rendered off-screen. The reader's view is never moved.
-- Backend access lives here, since Document:drawPage may apply KOPT reflow.
local Source = require("ink_export_source")
local Full = {}

function Full.supports(ui)
    local doc = ui and ui.document
    return ui and ui.paging and doc and doc.provider == "mupdf"
        and doc._document and type(doc._document.openPage) == "function"
        and type(doc.getPageCount) == "function" or false
end

function Full.items(page_count, notes, annotated_only)
    if type(page_count) ~= "number" or page_count < 1 or page_count ~= math.floor(page_count) then
        return nil, "bad_geometry"
    end
    if not annotated_only and page_count > Source.MAX_PAGES then return nil, "too_many_pages" end
    local by_page, extras, items, wanted = {}, {}, {}, {}
    for _, note in ipairs(notes) do
        if note.kind == "page_ink" then
            if not note.page or note.page < 1 or note.page > page_count
                or note.page ~= math.floor(note.page) then return nil, "bad_geometry" end
            if by_page[note.page] then return nil, "bad_surface" end
            by_page[note.page] = note
            wanted[note.page]=true
        else
            extras[#extras + 1] = note
            if note.native and note.page and note.page>=1 and note.page<=page_count then wanted[note.page]=true end
        end
    end
    if annotated_only then
        for page in pairs(wanted) do
            items[#items + 1] = {kind = "document_page", page = page, note = by_page[page]}
        end
        table.sort(items, function(a,b) return a.page < b.page end)
    else
        for page = 1, page_count do
            items[#items + 1] = { kind = "document_page", page = page, note = by_page[page] }
        end
    end
    for _, item in ipairs(extras) do items[#items + 1] = item end
    if #items > Source.MAX_PAGES then return nil, "too_many_pages" end
    if #items == 0 then return nil, "empty" end
    return items
end

function Full.renderer(opts)
    local Blitbuffer = require("ffi/blitbuffer")
    local DrawContext = require("ffi/drawcontext")
    local Raster = require("ink_export_raster")
    local Notes = require("ink_document_export_source")
    local tracker = opts.tracker
    local appendix = Notes.renderer(opts)
    return function(item, index, done)
        if item.kind ~= "document_page" then return appendix(item, index, done) end
        opts.schedule(function()
            if tracker.closed then return end
            local page, bb, dc
            local function release()
                if bb then bb:free(); bb = nil end
            end
            local ok, err = pcall(function()
                dc = DrawContext.new()
                page = opts.document._document:openPage(item.page)
                local w, h = page:getSize(dc)
                local scale, reason = Raster.boundedScale(w, h, (opts.dpi or 150) / 72)
                if not scale then error(reason) end
                local _, pw, ph = Raster.roundedPixels(w, h, scale)
                bb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
                bb:fill(Blitbuffer.COLOR_WHITE)
                dc:setZoom(scale)
                page:draw(dc, bb, 0, 0)
                page:close(); page = nil
                if not item.note then
                    return done({ bb = bb, width_pt = w, height_pt = h, release = release })
                end
                local note = item.note
                if math.abs(note.logical_w - w) > 0.01 or math.abs(note.logical_h - h) > 0.01 then
                    error("page_size_changed")
                end
                local job, job_err = Raster.open{
                    surface = note.surface, repository = note.repository, scale = scale,
                    composition = "overlay", schedule = opts.schedule,
                    on_ready = function(raster)
                        if tracker.closed then raster:close(); release(); return end
                        local composed, why = pcall(function()
                            bb:alphablitFrom(raster:buffer(), 0, 0, 0, 0, pw, ph)
                        end)
                        raster:close()
                        tracker.job = nil
                        if not composed then release(); return done(nil, why) end
                        done({ bb = bb, width_pt = w, height_pt = h, release = release })
                    end,
                    on_error = function(reason)
                        if tracker.job then tracker.job:close(); tracker.job = nil end
                        release()
                        done(nil, reason)
                    end,
                }
                if not job then error(job_err) end
                tracker.job, tracker.release = job, release
            end)
            if page then page:close() end
            if not ok then release(); done(nil, err) end
        end)
    end
end

return Full
