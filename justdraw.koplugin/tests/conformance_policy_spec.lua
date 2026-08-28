return function(ctx)
    local t = ctx.t
    local Policy = require("conformance_policy")

    t:describe("conformance / strict stylus policy")

    -- Keep this list independent from the production map. If a required claim
    -- is renamed, omitted or added on only one side, this contract test must
    -- fail instead of silently exercising the smaller set.
    local REQUIRED = {
        "Input exports the TOOL_TYPE_* constants",
        "registerStylusCallback and unregisterStylusCallback exist",
        "Input:routeStylusEvents exists",
        "pen_slot is defined",
        "getMtSlot hands out one persistent table per slot",
        "GestureDetector exposes getContact and dropContact",
    }

    local function rows(stylus_status)
        local result = {}
        for i = 1, #REQUIRED do
            result[#result + 1] = { stylus_status, REQUIRED[i], "" }
        end
        result[#result + 1] = {
            "UNCHECKABLE", "anchors: a real EPUB was supplied", "",
        }
        return result
    end

    t:case("the strict set contains every required stylus claim exactly once", function()
        local count = 0
        for name, required in pairs(Policy.required_stylus_claims) do
            t:eq(required, true, name .. " remains required")
            count = count + 1
        end
        t:eq(count, #REQUIRED, "strict map has no missing or extra claims")
        for i = 1, #REQUIRED do
            t:eq(Policy.required_stylus_claims[REQUIRED[i]], true,
                REQUIRED[i] .. " is in the strict map")
            local failures, strict_missing = Policy.countFailures({
                { "UNCHECKABLE", REQUIRED[i], "" },
            }, true)
            t:eq(failures, 1, REQUIRED[i] .. " fails strict mode alone")
            t:eq(strict_missing, 1,
                REQUIRED[i] .. " is counted as specifically uncheckable")
        end
    end)

    t:case("normal mode keeps old runtimes diagnostic-only", function()
        local failures, strict_missing = Policy.countFailures(rows("UNCHECKABLE"), false)
        t:eq(failures, 0, "required stylus claims do not fail normal mode")
        t:eq(strict_missing, 0, "normal mode records no strict failures")
    end)

    t:case("strict mode rejects an uncheckable required stylus claim", function()
        local failures, strict_missing = Policy.countFailures(rows("UNCHECKABLE"), true)
        t:eq(failures, #REQUIRED, "every required claim fails")
        t:eq(strict_missing, #REQUIRED,
            "every failure is identified as uncheckable")
    end)

    t:case("strict mode accepts a complete modern stylus runtime", function()
        local failures, strict_missing = Policy.countFailures(rows("OK"), true)
        t:eq(failures, 0, "modern required claims pass")
        t:eq(strict_missing, 0, "unrelated uncheckable claims remain diagnostic")
    end)
end
