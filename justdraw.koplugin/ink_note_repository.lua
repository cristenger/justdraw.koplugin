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
function Groups:append(book, surface)
    local r = self.repository
    return r:transaction(function()
        local rows, err = r:_select(
            "SELECT id FROM canvases WHERE id=?1 AND book_id=?2 AND surface_role='sheet';",
            { surface.id, book },
            function(row)
                return tonumber(row[1])
            end
        )
        if not rows or not rows[1] then
            return nil, err or "bad_surface"
        end
        local members, merr = self:memberships(book)
        if not members then
            return nil, merr
        end
        local note
        for _, m in ipairs(members) do
            if m.canvas_id == surface.id then
                note = m.note_id
            end
        end
        if not note then
            local ok, why = r:_run("INSERT INTO document_notes(book_id) VALUES (?1);", { book })
            if not ok then
                return nil, why
            end
            note = assert(r:_lastId())
            ok, why = r:_run(
                "INSERT INTO document_note_sheets(canvas_id,note_id,position) VALUES (?1,?2,1);",
                { surface.id, note }
            )
            if not ok then
                return nil, why
            end
        end
        local position = 1
        for _, m in ipairs(members) do
            if m.note_id == note then
                position = math.max(position, m.position)
            end
        end
        position = position + 1
        local spec = {}
        for k, v in pairs(surface) do
            spec[k] = v
        end
        -- Identity for the extra surface is distinct; its durable xpointer stays identical.
        local nonce = r:_select("SELECT COALESCE(MAX(id),0)+1 FROM canvases;", nil, function(row)
            return tonumber(row[1])
        end)
        if not nonce then
            return nil, "list_failed"
        end
        spec.anchor_key = "justdraw-note:" .. note .. ":" .. nonce[1]
        local canvas, why = r:createCanvas(book, spec)
        if not canvas then
            return nil, why
        end
        local ok
        ok, why = r:_run(
            "INSERT INTO document_note_sheets(canvas_id,note_id,position) VALUES (?1,?2,?3);",
            { canvas.id, note, position }
        )
        if not ok then
            return nil, why
        end
        return canvas
    end)
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
