-- Expand logical notes and long text incrementally before choosing an output.
local Prepare = {}
function Prepare.start(items, schedule, done)
    local token = { closed = false }
    function token:close()
        self.closed = true
    end
    local flat, out = {}, {}
    for _, item in ipairs(items) do
        for _, sheet in ipairs(item.sheets or { item }) do
            flat[#flat + 1] = sheet
        end
    end
    local cursor, chunk_cursor, chunks, first_page = 1, 1, nil, 1
    local function step()
        if token.closed then
            return
        end
        local ok, err = pcall(function()
            local item = flat[cursor]
            if not item then
                token.closed = true
                return done(out)
            end
            if item.native then
                local Text = require("ink_native_text")
                if not chunks then
                    chunks = Text.chunks(require("ink_native_annotations").text(item))
                    chunk_cursor = 1
                    first_page = #out + 1
                end
                for _, page in ipairs(Text.pages(item, chunks[chunk_cursor])) do
                    out[#out + 1] = page
                end
                chunk_cursor = chunk_cursor + 1
                if chunk_cursor > #chunks then
                    for i = first_page, #out do
                        out[i].location_label = item.location_label
                            .. " · "
                            .. (i - first_page + 1)
                            .. "/"
                            .. (#out - first_page + 1)
                    end
                    chunks = nil
                    cursor = cursor + 1
                end
            else
                out[#out + 1] = item
                cursor = cursor + 1
            end
            if #out > require("ink_export_source").MAX_PAGES then
                error("too_many_pages", 0)
            end
            schedule(step)
        end)
        if not ok then
            token.closed = true
            done(nil, err)
        end
    end
    schedule(step)
    return token
end
return Prepare
