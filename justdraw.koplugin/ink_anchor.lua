--[[--
What ties a canvas to a place in the book.

A canvas holds its strokes in its own coordinates, so reflow cannot move the
ink -- it can only move the sheet. That makes the anchor the one piece of a
canvas that has to survive a font change, a margin change, or a DOM upgrade,
and the only piece worth this much care.

Two forms of the same position are kept. `getNormalizedXPointer` returns the
canonical pointer for DOMs at or above
`getDomVersionWithNormalizedXPointers()`, and something else below it, so a
book opened today under an old DOM and reopened later under a new one needs
both to be findable either way. KOReader's own migration in `ReaderRolling`
cannot help here: it walks the last position and the annotations, and it has
never heard of this plugin's tables.

Nothing in this module talks to a database or to a widget. It takes a document
and answers questions about pointers.
]]

local Anchor = {}

--- Anchor keys are prefixed so a page anchor and an xpointer anchor can share
--- one uniqueness constraint without ever colliding.
Anchor.XPOINTER_PREFIX = "xp:"
Anchor.PAGE_PREFIX = "page:"

--[[--
An anchor spec for wherever the document is now.

Returns the spec, or nil plus `no_position` when the document will not say
where it is, or `not_in_document` when it will not vouch for the pointer it
just handed over. Both are refusals to create a canvas that could never be
found again -- an orphan at birth is worse than no canvas at all.
]]
function Anchor.forCurrentPosition(document, dom_version)
    local raw = document:getXPointer()
    if type(raw) ~= "string" or raw == "" then return nil, "no_position" end

    -- Returns false, not nil, for a pointer the DOM does not contain.
    local normalized = document:getNormalizedXPointer(raw)
    if normalized == false or normalized == nil or normalized == "" then
        normalized = nil
    end

    if not document:isXPointerInDocument(raw)
        and not (normalized and document:isXPointerInDocument(normalized)) then
        return nil, "not_in_document"
    end

    return {
        anchor_kind        = "xpointer",
        anchor_key         = Anchor.XPOINTER_PREFIX .. (normalized or raw),
        anchor_raw         = raw,
        anchor_normalized  = normalized,
        anchor_dom_version = dom_version,
    }
end

--[[--
An anchor spec for a fixed-layout page.

Reserved: v1 does not put canvases on PDFs. The column and the key shape exist
so the schema does not have to change when it does.
]]
function Anchor.forPage(page)
    return {
        anchor_kind = "page",
        anchor_key  = Anchor.PAGE_PREFIX .. tostring(page),
        fixed_page  = page,
    }
end

--[[--
The pointer of this canvas that today's document actually understands, or nil.

Order matters only for speed, not for correctness: the form matching the
current DOM is tried first and the other is the fallback, so a book that has
been through a DOM upgrade still finds its canvases on the first reopen.

nil means the anchor has gone missing. It is never a reason to delete the
canvas -- the text may come back, and a reader's notes are not the plugin's to
throw away.
]]
function Anchor.resolve(document, canvas)
    local raw, normalized = canvas.anchor_raw, canvas.anchor_normalized

    local prefer_normalized = true
    local threshold = document.getDomVersionWithNormalizedXPointers
        and document:getDomVersionWithNormalizedXPointers()
    if threshold and canvas.anchor_dom_version
        and canvas.anchor_dom_version < threshold then
        prefer_normalized = false
    end

    local first = prefer_normalized and normalized or raw
    local second = prefer_normalized and raw or normalized

    if first and document:isXPointerInDocument(first) then return first end
    if second and document:isXPointerInDocument(second) then return second end
    return nil
end

return Anchor
