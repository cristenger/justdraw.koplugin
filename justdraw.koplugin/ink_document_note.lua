-- Metadata shared by the notes browser and the document dossier. No pixels.
local _ = require("gettext")
local T = require("ffi/util").template
local Note = {}

function Note.kindLabel(kind)
    if kind == "native_note" then
        return _("KOReader note")
    end
    if kind == "native_highlight" then
        return _("KOReader highlight")
    end
    if kind == "native_bookmark" then
        return _("KOReader bookmark")
    end
    if kind == "page_ink" then
        return _("Page note")
    end
    if kind == "legacy_page" then
        return _("Legacy ink")
    end
    return _("Drawing sheet")
end

function Note.locationLabel(kind, page)
    if not page then
        return _("Location unavailable")
    end
    if kind == "legacy_page" then
        return T(_("Stored page %1"), page)
    end
    return T(_("Page %1"), page)
end

function Note.new(spec)
    local row = spec.surface
    local note = {
        kind = spec.kind,
        page = spec.page,
        surface = row,
        repository = spec.repository,
        logical_w = spec.logical_w,
        logical_h = spec.logical_h,
        units = spec.units,
        legacy = spec.kind == "legacy_page",
        updated_at = row and row.updated_at,
    }
    note.id = spec.kind .. ":" .. tostring(row and row.id or spec.page)
    note.location_label = Note.locationLabel(note.kind, note.page)
    return note
end

function Note.before(a, b)
    if a.page and b.page then
        if a.page ~= b.page then
            return a.page < b.page
        end
        if a.legacy ~= b.legacy then
            return a.legacy
        end
    elseif a.page then
        return true
    elseif b.page then
        return false
    end
    local ai = tonumber(a.surface and a.surface.id or a.page) or 0
    local bi = tonumber(b.surface and b.surface.id or b.page) or 0
    if ai ~= bi then
        return ai < bi
    end
    return a.id < b.id
end

-- Shared by the browser and the original document export entry.
function Note.group(source, memberships, by_id)
    by_id = by_id or {}
    local map, groups, items = {}, {}, {}
    for _, m in ipairs(memberships) do
        map[m.canvas_id] = m
    end
    for _, item in ipairs(source) do
        local m = item.surface and map[item.surface.id]
        if m then
            local group = groups[m.note_id]
            if not group then
                group = {}
                for k, v in pairs(item) do
                    group[k] = v
                end
                group.id, group.note_id, group.sheets = "note:" .. m.note_id, m.note_id, {}
                groups[m.note_id] = group
                items[#items + 1] = group
                by_id[group.id] = group
            end
            item.sheet_position = m.position
            group.sheets[#group.sheets + 1] = item
            group.updated_at = math.max(group.updated_at or 0, item.updated_at or 0)
        else
            items[#items + 1] = item
        end
    end
    for note_id, group in pairs(groups) do
        table.sort(group.sheets, function(a, b)
            return a.sheet_position < b.sheet_position
        end)
        group.surface = group.sheets[1].surface
        for i, sheet in ipairs(group.sheets) do
            sheet.location_label = Note.locationLabel(sheet.kind, sheet.page)
                .. " · "
                .. T(_("Sheet %1 of %2"), i, #group.sheets)
        end
    end
    return items
end

return Note
