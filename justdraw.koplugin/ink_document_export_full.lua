-- Complete fixed pages rendered off-screen. The reader's view is never moved.
-- Backend access lives here, since Document:drawPage may apply KOPT reflow.
local Source = require("ink_export_source")
local _ = require("ink_i18n")
local T = require("ffi/util").template
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
    -- A sheet hung on a page (ADR-67) follows that page, as the page's own
    -- ink is composed onto it; every other note keeps to the appendix.
    local by_page, sheets_by_page, extras, items, wanted = {}, {}, {}, {}, {}
    for _, note in ipairs(notes) do
        if note.kind == "page_ink" then
            if not note.page or note.page < 1 or note.page > page_count
                or note.page ~= math.floor(note.page) then return nil, "bad_geometry" end
            if by_page[note.page] then return nil, "bad_surface" end
            by_page[note.page] = note
            wanted[note.page]=true
        elseif note.kind == "sheet" and note.surface
            and note.surface.anchor_kind == "page" and note.page then
            if note.page < 1 or note.page > page_count
                or note.page ~= math.floor(note.page) then return nil, "bad_geometry" end
            sheets_by_page[note.page] = sheets_by_page[note.page] or {}
            local list = sheets_by_page[note.page]
            list[#list + 1] = note
            wanted[note.page] = true
        else
            extras[#extras + 1] = note
            if note.native and note.page and note.page>=1 and note.page<=page_count then wanted[note.page]=true end
        end
    end
    local function appendPage(page)
        items[#items + 1] = { kind = "document_page", page = page, note = by_page[page] }
        for _, sheet in ipairs(sheets_by_page[page] or {}) do items[#items + 1] = sheet end
    end
    if annotated_only then
        local pages = {}
        for page in pairs(wanted) do pages[#pages + 1] = page end
        table.sort(pages)
        for _, page in ipairs(pages) do appendPage(page) end
    else
        for page = 1, page_count do appendPage(page) end
    end
    for _, item in ipairs(extras) do items[#items + 1] = item end
    if #items > Source.MAX_PAGES then return nil, "too_many_pages" end
    if #items == 0 then return nil, "empty" end
    return items
end

--[[--
The notes, each page's notes preceded by a clean copy of that page.

A *new* list: the descriptors handed in are the Document notes catalogue's
own, alive for as long as the browser is, and a run that wrote into them
would leave its marks on the next run's plan. The source pages are new rows
of their own. Notes with no page of this document -- a sheet whose anchor no
longer resolves, an annotation with no page -- keep their order at the end,
and their count comes back so the dialog can say so.
]]
function Full.withSourcePages(page_count, notes)
    if type(page_count) ~= "number" or page_count < 1
        or page_count ~= math.floor(page_count) then return nil, "bad_geometry" end
    local by_page, pages, extras = {}, {}, {}
    for _i, item in ipairs(notes) do
        local page = tonumber(item.page)
        if page and page >= 1 and page <= page_count and page == math.floor(page) then
            if not by_page[page] then
                by_page[page] = {}
                pages[#pages + 1] = page
            end
            local list = by_page[page]
            list[#list + 1] = item
        else
            extras[#extras + 1] = item
        end
    end
    table.sort(pages)
    local out = {}
    for _i, page in ipairs(pages) do
        out[#out + 1] = { kind = "source_page", page = page,
            location_label = T(_("Page %1"), page) }
        for _j, item in ipairs(by_page[page]) do out[#out + 1] = item end
    end
    for _i, item in ipairs(extras) do out[#out + 1] = item end
    if #out > Source.MAX_PAGES then return nil, "too_many_pages" end
    return out, #extras
end

function Full.renderer(opts)
    local Blitbuffer = require("ffi/blitbuffer")
    local Raster = require("ink_export_raster")
    local Notes = require("ink_document_export_source")
    local tracker = opts.tracker
    local appendix = Notes.renderer(opts)
    return function(item, index, done)
        if item.kind ~= "document_page" and item.kind ~= "source_page" then
            return appendix(item, index, done)
        end
        opts.schedule(function()
            if tracker.closed then return end
            local page, bb, dc
            local function release()
                if bb then bb:free(); bb = nil end
            end
            local ok, err = pcall(function()
                -- Required here, when a page is drawn, not when the renderer
                -- is built: building one is planning, and plans are made
                -- (and tested) where MuPDF's draw context does not exist.
                dc = require("ffi/drawcontext").new()
                page = opts.document._document:openPage(item.page)
                local w, h = page:getSize(dc)
                local scale, reason = Raster.boundedScale(w, h, (opts.dpi or 150) / 72)
                if not scale then error(reason) end
                local _pixels, pw, ph = Raster.roundedPixels(w, h, scale)
                bb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
                bb:fill(Blitbuffer.COLOR_WHITE)
                dc:setZoom(scale)
                page:draw(dc, bb, 0, 0)
                page:close(); page = nil
                if not item.note then
                    local result = { bb = bb, width_pt = w, height_pt = h, release = release }
                    -- A source page is a page of the dossier like any note,
                    -- so it carries the same band naming what it is.
                    if item.kind == "source_page" and opts.header then
                        local composed, why = require("ink_export_header").compose{
                            result = result, title = opts.header.title,
                            kind_label = _("Book page"),
                            location_label = item.location_label,
                            paint_text = opts.header.paint_text,
                        }
                        if not composed then release(); return done(nil, why) end
                        return done(composed)
                    end
                    return done(result)
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
