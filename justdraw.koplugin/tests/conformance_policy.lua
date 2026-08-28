-- Exit-policy shared by the real-runtime conformance probe and its bare tests.
local Policy = {}

Policy.required_stylus_claims = {
    ["Input exports the TOOL_TYPE_* constants"] = true,
    ["registerStylusCallback and unregisterStylusCallback exist"] = true,
    ["Input:routeStylusEvents exists"] = true,
    ["pen_slot is defined"] = true,
    ["getMtSlot hands out one persistent table per slot"] = true,
    ["GestureDetector exposes getContact and dropContact"] = true,
}

function Policy.countFailures(rows, strict_stylus)
    local failures, strict_uncheckable = 0, 0
    for i = 1, #rows do
        local row = rows[i]
        if row[1] == "MISMATCH" then
            failures = failures + 1
        elseif strict_stylus and row[1] == "UNCHECKABLE"
            and Policy.required_stylus_claims[row[2]] then
            failures = failures + 1
            strict_uncheckable = strict_uncheckable + 1
        end
    end
    return failures, strict_uncheckable
end

return Policy
