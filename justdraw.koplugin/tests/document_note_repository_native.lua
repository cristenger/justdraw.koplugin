-- Real SQLite: upgrade populated v3 data, preserve blobs, and reopen groups.
return function(home)
    local Repository = require("ink_canvas_repository")
    local Groups = require("ink_note_repository")
    local path = home .. "/migration-v3.sqlite3"
    local conn = require("lua-ljsqlite3/init").open(path)
    local v3 = assert(Repository.SCHEMA:match("^(.-)CREATE TABLE document_notes"))
    conn:exec(v3)
    conn:exec("PRAGMA user_version=3;")
    conn:close()
    local repo = assert(Repository.open { path = path, schema_version = 3 })
    local book = assert(repo:bookId("v3-fixture", 123, "fixture.epub"))
    local root = assert(
        repo:createCanvas(
            book,
            {
                anchor_key = "original",
                anchor_raw = "/body/p[1]",
                anchor_normalized = "/body/p[1]",
                logical_w = 600,
                logical_h = 800,
            }
        )
    )
    local stroke = assert(
        repo:addStroke(root, { points = { 0, 0, 20, 30, 50, 60 }, n = 3, width = 2, tool = 1, paint_seq = 9 })
    )
    local blob = assert(repo:readStrokeChunk(stroke, 0)).points
    repo:close()
    repo = assert(Repository.open { path = path })
    assert(repo.version == 4, "v3 migration failed")
    assert(io.open(path .. ".backup-v3", "rb")):close()
    assert(repo:readStrokeChunk(stroke, 0).points == blob, "migration changed stroke bytes")
    assert(repo:listStrokes(root.id)[1].paint_seq == 9, "migration changed paint order")
    local group = Groups.new(repo)
    assert(#group:memberships(book) == 0, "migration grouped unrelated existing notes")
    local second = assert(group:append(book, root))
    local third = assert(group:append(book, root))
    assert(second.anchor_raw == root.anchor_raw and second.anchor_key ~= root.anchor_key)
    local note = group:memberships(book)[1].note_id
    assert(group:reorder(book, note, { third.id, root.id, second.id }))
    repo:close()
    repo = assert(Repository.open { path = path })
    group = Groups.new(repo)
    local members = assert(group:memberships(book))
    table.sort(members, function(a, b)
        return a.position < b.position
    end)
    assert(
        #members == 3 and members[1].canvas_id == third.id and members[3].canvas_id == second.id,
        "sheet order did not survive reopening"
    )
    assert(repo:readStrokeChunk(stroke, 0).points == blob, "grouping changed stroke bytes")
    repo:close()
    repo = assert(Repository.open { path = path, schema_version = 3 })
    assert(repo.read_only and not Groups.new(repo):append(book, root), "older version wrote to newer schema")
    repo:close()
    print(
        "PASS migration: populated v3 to v4, backup, identical ink, persistent sheet order, read-only guard"
    )
end
