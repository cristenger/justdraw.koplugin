-- Read-only adapter. KOReader remains the owner of all native annotations.
local Note = require("ink_document_note")
local Native = {}

local function keyPart(value)
    if type(value) ~= "table" then
        return tostring(value or "")
    end
    local keys, out = {}, {}
    for k in pairs(value) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
        local part = keyPart(value[k])
        out[#out + 1] = tostring(k) .. "=" .. #part .. ":" .. part
    end
    return table.concat(out, ";")
end

local function identity(source, duplicates)
    local raw = keyPart({ source.datetime, source.page, source.pos0, source.pos1 })
    duplicates[raw] = (duplicates[raw] or 0) + 1
    return "native:" .. #raw .. ":" .. raw .. ":" .. duplicates[raw]
end

function Native.findIndex(ui, id)
    local duplicates = {}
    for index, source in ipairs(ui.annotation and ui.annotation.annotations or {}) do
        if identity(source, duplicates) == id then
            return index
        end
    end
end

function Native.snapshot(ui, offset, limit, duplicates)
    local out = {}
    duplicates = duplicates or {}
    local sources = ui.annotation and ui.annotation.annotations or {}
    for index = (offset or 0) + 1, math.min(#sources, (offset or 0) + (limit or #sources)) do
        local source = sources[index]
        local kind = source.note and source.note ~= "" and "native_note"
            or source.pos0 and "native_highlight"
            or "native_bookmark"
        local item = Note.new { kind = kind }
        -- Editing text does not change identity. Identical anchors are disambiguated.
        item.id = identity(source, duplicates)
        item.native = {
            text = source.text,
            note = source.note,
            note_format = source.note_format,
            datetime = source.datetime,
            datetime_updated = source.datetime_updated,
        }
        item.xpointer = ui.rolling and type(source.page) == "string" and source.page or nil
        if ui.rolling then
            if item.xpointer and ui.document:isXPointerInDocument(item.xpointer) then
                item.page = ui.document:getPageFromXPointer(item.xpointer)
            end
        else
            item.page = tonumber(source.page)
        end
        item.chapter = source.chapter
        item.location_label = Note.locationLabel(kind, item.page)
        local stamp = source.datetime_updated or source.datetime or ""
        local y, m, d, h, n, s = stamp:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
        if y then
            item.updated_at = os.time {
                year = tonumber(y),
                month = tonumber(m),
                day = tonumber(d),
                hour = tonumber(h),
                min = tonumber(n),
                sec = tonumber(s),
            }
        end
        out[#out + 1] = item
    end
    return out, #sources
end

function Native.matches(item, query)
    local ok, utf8 = pcall(require, "ffi/utf8proc")
    local lower = ok and utf8.lowercase or string.lower
    return lower(Native.text(item)):find(lower(query), 1, true) ~= nil
end

function Native.text(item)
    local n = item.native
    local out = {}
    if n.text and n.text ~= "" then
        out[#out + 1] = n.text
    end
    if n.note and n.note ~= "" then
        out[#out + 1] = n.note
    end
    return #out > 0 and table.concat(out, "\n\n") or Note.kindLabel(item.kind)
end

return Native
