-- Paginate bounded UTF-8 chunks using the same widget that paints each page.
local Text = { WIDTH = 720, HEIGHT = 960, CHUNK_BYTES = 4096 }
function Text.chunks(text)
    local chunks, first = {}, 1
    repeat
        local last = math.min(#text, first + Text.CHUNK_BYTES - 1)
        while last < #text and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do
            last = last - 1
        end
        -- Prefer a line/word boundary without changing a single source byte.
        if last < #text then
            local boundary = text:sub(first, last):match(".*()%s")
            if boundary and boundary > Text.CHUNK_BYTES / 2 then
                last = first + boundary - 1
            end
        end
        chunks[#chunks + 1] = text:sub(first, last)
        first = last + 1
    until first > #text
    return chunks
end
local function widget(text, line)
    return require("ui/widget/textboxwidget"):new {
        text = text,
        width = Text.WIDTH - 48,
        height = Text.HEIGHT - 48,
        face = require("ui/font"):getFace("cfont", 22),
        alignment = "left",
        virtual_line_num = line or 1,
    }
end
function Text.pages(item, content)
    local pages = {}
    for _, chunk in
        ipairs(content and { content } or Text.chunks(require("ink_native_annotations").text(item)))
    do
        local box = widget(chunk)
        local visible, total = box:getVisLineCount(), box:getAllLineCount()
        assert(visible > 0, "bad_geometry")
        for line = 1, math.max(1, total), visible do
            local page = {}
            for k, v in pairs(item) do
                page[k] = v
            end
            page.text_chunk, page.text_line = chunk, line
            page.logical_w, page.logical_h, page.units = Text.WIDTH, Text.HEIGHT, "px"
            pages[#pages + 1] = page
            if #pages > require("ink_export_source").MAX_PAGES then
                box:free()
                error("too_many_pages", 0)
            end
        end
        box:free()
    end
    for i, page in ipairs(pages) do
        page.location_label = item.location_label .. " · " .. i .. "/" .. #pages
    end
    return pages
end
function Text.render(item)
    local BB = require("ffi/blitbuffer")
    local box, bb
    local function release()
        if bb then
            bb:free()
            bb = nil
        end
    end
    local ok, err = pcall(function()
        box = widget(item.text_chunk or require("ink_native_annotations").text(item), item.text_line)
        bb = BB.new(Text.WIDTH, Text.HEIGHT, BB.TYPE_BB8)
        bb:fill(BB.COLOR_WHITE)
        box:paintTo(bb, 24, 24)
    end)
    if box then
        box:free()
    end
    if not ok then
        release()
        return nil, err
    end
    return { bb = bb, width_pt = 432, height_pt = 576, release = release }
end
return Text
