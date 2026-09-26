return function(ctx)
    local t = ctx.t
    local ToolState = require("ink_tool_state")

    t:describe("ink_tool_state / names and surfaces")

    t:case("unknown tools are the pen", function()
        t:eq(ToolState.normalize("lasso?"), "pen", "unknown")
        t:eq(ToolState.normalize(nil), "pen", "nil")
        for _, name in ipairs({ "pen", "eraser", "select", "shape", "paste" }) do
            t:eq(ToolState.normalize(name), name, name .. " is known")
        end
    end)

    t:case("every tool is what it says on a notebook", function()
        for _, name in ipairs({ "pen", "eraser", "select", "shape", "paste" }) do
            t:eq(ToolState.effective("notebook", name), name, name)
            t:eq(ToolState.supports("notebook", name), true, name .. " supported")
        end
    end)

    t:case("page ink and legacy ink draw with any editing tool", function()
        for _, surface in ipairs({ "page_ink", "legacy", "unknown_surface" }) do
            t:eq(ToolState.effective(surface, "eraser"), "eraser", surface .. " erases")
            for _, name in ipairs({ "select", "shape", "paste" }) do
                t:eq(ToolState.effective(surface, name), "pen", surface .. ": " .. name .. " draws")
            end
        end
    end)

    -- Changed on purpose in Phase 7 (ADR-57): sheets edit like notebooks.
    t:case("sheets edit like notebooks since phase 7", function()
        t:eq(ToolState.effective("sheet", "paste"), "paste", "paste pastes on a sheet")
        t:eq(ToolState.effective("sheet", "select"), "select", "the lasso selects")
        t:eq(ToolState.effective("sheet", "eraser"), "eraser", "the eraser erases")
    end)

    t:describe("ink_tool_state / the plugin's one tool")

    t:case("setTool derives the eraser flag and setEraser is its wrapper", function()
        ctx.reset()
        local p = ctx.newPlugin()
        t:eq(p.tool, "pen", "starts with the pen")
        p:setTool("select", { quiet = true })
        t:eq(p.tool, "select", "select")
        t:eq(p.eraser, false, "not erasing")
        t:eq(p:toolFor("notebook"), "select", "a notebook lassos")
        t:eq(p:toolFor("page_ink"), "pen", "page ink draws")
        p:setEraser(true)
        t:eq(p.tool, "eraser", "the eraser")
        t:eq(p.eraser, true, "the flag follows")
        p:setEraser(false)
        t:eq(p.tool, "pen", "off means the pen")
        p:setTool("nonsense", { quiet = true })
        t:eq(p.tool, "pen", "unknown means the pen")
    end)

    t:case("observers hear each change once; paste remembers what it interrupted", function()
        ctx.reset()
        local p = ctx.newPlugin()
        local heard = {}
        local stop = p:observeTool(function(name, previous)
            heard[#heard + 1] = previous .. ">" .. name
        end)
        p:setTool("shape", { quiet = true })
        p:setTool("shape", { quiet = true })
        p:setTool("paste", { quiet = true })
        t:eq(p.previous_tool, "shape", "paste remembers the shape tool")
        p:setTool("eraser", { quiet = true })
        t:eq(table.concat(heard, ","), "pen>shape,shape>paste,paste>eraser",
            "one notice per change, none for a repeat")
        stop()
        p:setTool("pen", { quiet = true })
        t:eq(#heard, 3, "a stopped observer hears nothing")
    end)

    t:case("a failing observer cannot stop the tool from changing", function()
        ctx.reset()
        local p = ctx.newPlugin()
        p:observeTool(function() error("boom") end)
        p:setTool("select", { quiet = true })
        t:eq(p.tool, "select", "changed anyway")
    end)
end
