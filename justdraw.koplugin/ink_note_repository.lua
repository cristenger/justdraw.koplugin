-- Logical notes group existing canvas rows. All mutations are transactional.
local Groups = {}
Groups.__index = Groups
function Groups.new(repository)
    return setmetatable({ repository = repository }, Groups)
end
function Groups:memberships(book)
    return self.repository:_select(
        [[SELECT s.canvas_id,s.note_id,s.position
        FROM document_note_sheets s JOIN document_notes n ON n.id=s.note_id WHERE n.book_id=?1;]],
        { book },
        function(row)
            return { canvas_id = tonumber(row[1]), note_id = tonumber(row[2]), position = tonumber(row[3]) }
        end
    )
end
--- Add a sheet to the end of `surface`'s note; the transaction lives with the
--- rest of the canvas SQL (`Repository:appendNoteSheet`).
function Groups:append(book, surface)
    return self.repository:appendNoteSheet(book, surface)
end

--[[--
The sheets of `surface`'s note in reading order, the position of `surface`
among them, and the note's id -- or a note of one for a sheet that has never
had a second, which is presented as such without writing anything.
]]
function Groups:pages(book, surface)
    if not surface then return nil, "bad_surface" end
    local rows, err = self.repository:listNotePages(book, surface.id)
    if not rows then return nil, err end
    if #rows == 0 then return { { canvas_id = surface.id, position = 1 } }, 1 end
    for i, row in ipairs(rows) do
        if row.canvas_id == surface.id then return rows, i, row.note_id end
    end
    return nil, "bad_surface"
end
function Groups:reorder(book, note, ids)
    local r = self.repository
    return r:transaction(function()
        local members, err = self:memberships(book)
        if not members then
            return nil, err
        end
        local expected, count = {}, 0
        for _, m in ipairs(members) do
            if m.note_id == note then
                expected[m.canvas_id] = true
                count = count + 1
            end
        end
        if count ~= #ids or count == 0 then
            return nil, "bad_surface"
        end
        for _, id in ipairs(ids) do
            if not expected[id] then
                return nil, "bad_surface"
            end
            expected[id] = nil
        end
        local ok, why =
            r:_run("UPDATE document_note_sheets SET position=-position WHERE note_id=?1;", { note })
        if not ok then
            return nil, why
        end
        for i, id in ipairs(ids) do
            ok, why = r:_run(
                "UPDATE document_note_sheets SET position=?1 WHERE canvas_id=?2 AND note_id=?3;",
                { i, id, note }
            )
            if not ok then
                return nil, why
            end
        end
        return true
    end)
end
return Groups
