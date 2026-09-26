--[[--
Which tool the pen is, and which surfaces can use it (ADR-54).

Before the editing tools there were two: the pen and the eraser, and a boolean
said which. Five do not fit a boolean, and `main.lua` reads `plugin.eraser`
in many places that have no business learning about lassos. So the tool is one
name, the boolean stays as a value derived from it, and every surface asks
here what the name means for it: page ink and legacy direct ink cannot select,
place or paste -- a transparent layer over a book cannot be repainted from a
blit (ADR-38) -- so for them anything but the eraser is the pen.

Without this, each surface would re-derive "can I lasso here" and one of them
would eventually disagree with the toolbar that offered the tool.
]]

local ToolState = {}

ToolState.PEN = "pen"
ToolState.ERASER = "eraser"
ToolState.SELECT = "select"
ToolState.SHAPE = "shape"
ToolState.PASTE = "paste"

local KNOWN = {
    pen = true, eraser = true, select = true, shape = true, paste = true,
}

--- Tools each surface understands. Notebooks and sheets edit alike (ADR-57);
--- page ink and legacy direct ink never do.
ToolState.SUPPORT = {
    notebook = { pen = true, eraser = true, select = true, shape = true, paste = true },
    sheet = { pen = true, eraser = true, select = true, shape = true, paste = true },
    page_ink = { pen = true, eraser = true },
    legacy = { pen = true, eraser = true },
}

--- The editing tools: a contact with one of these never draws ink.
ToolState.EDITING = { select = true, shape = true, paste = true }

--- A known tool name, or the pen.
function ToolState.normalize(name)
    if KNOWN[name] then return name end
    return ToolState.PEN
end

function ToolState.supports(surface, name)
    local support = ToolState.SUPPORT[surface]
    return support ~= nil and support[name] == true
end

--- What the tool means on this surface: itself when supported, the pen
--- otherwise. An unknown surface understands the pen and the eraser only.
function ToolState.effective(surface, name)
    name = ToolState.normalize(name)
    local support = ToolState.SUPPORT[surface] or ToolState.SUPPORT.legacy
    if support[name] then return name end
    return ToolState.PEN
end

function ToolState.isEditing(name)
    return ToolState.EDITING[name] == true
end

return ToolState
