return function(ctx)
    local t = ctx.t
    local ShapeDialog = require("ink_shape_dialog")

    local function build(options)
        local chosen, closed = {}, 0
        local rows = ShapeDialog.rows{
            options = options, checkmark = "*",
            choose = function(o) chosen[#chosen + 1] = o end,
            close = function() closed = closed + 1 end,
        }
        return rows, chosen, function() return closed end
    end

    local function find(rows, text)
        for _, row in ipairs(rows) do
            for _, b in ipairs(row) do if b.text == text then return b end end
        end
    end

    t:describe("ink_shape_dialog / rows")

    t:case("seven kinds, three sizes, the current ones marked", function()
        local rows = build{ kind = "circle", size = "L" }
        local kinds, marked = 0, {}
        for _, row in ipairs(rows) do
            for _, b in ipairs(row) do
                if b.text:sub(-1) == "*" then marked[#marked + 1] = b.text end
                for _, label in pairs(ShapeDialog.LABELS) do
                    if b.text:find(label, 1, true) == 1 then kinds = kinds + 1 end
                end
            end
        end
        t:eq(kinds, 7, "every kind is offered")
        t:eq(table.concat(marked, ","), "Circle*,Large*", "kind and size marked")
        t:eq(find(rows, "→"), nil, "a circle has no direction row")
    end)

    t:case("lines get four directions, arrows eight", function()
        local rows = build{ kind = "line" }
        local count = 0
        for _, g in ipairs({ "→", "↗", "↑", "↖", "←", "↙", "↓", "↘" }) do
            if find(rows, g) or find(rows, g .. "*") then count = count + 1 end
        end
        t:eq(count, 4, "line: four")
        rows = build{ kind = "arrow", angle = 225 }
        count = 0
        for _, g in ipairs({ "→", "↗", "↑", "↖", "←", "↙", "↓", "↘" }) do
            if find(rows, g) or find(rows, g .. "*") then count = count + 1 end
        end
        t:eq(count, 8, "arrow: eight")
        t:check(find(rows, "↙*") ~= nil, "the stored diagonal is marked")
    end)

    t:case("every choice closes once and stores normalized options", function()
        local rows, chosen, closed = build{ kind = "arrow", size = "S", angle = 90 }
        find(rows, "Square").callback()
        t:eq(closed(), 1, "closed")
        t:eq(chosen[1].kind, "square", "kind stored")
        t:eq(chosen[1].size, "S", "size kept")
        t:eq(chosen[1].angle, 0, "a square drops the arrow's angle")
        for _, row in ipairs(rows) do
            for _, b in ipairs(row) do
                if b.text ~= "Close" then t:eq(b.no_refresh_checkmark, true, b.text .. " closes cleanly") end
            end
        end
        find(rows, "Large").callback()
        t:eq(chosen[2].size, "L", "size choice")
        t:eq(chosen[2].kind, "arrow", "keeps the kind")
    end)

    t:case("corrupt stored options fall back to the defaults", function()
        local rows = build{ kind = 7, size = {}, angle = "x" }
        t:check(find(rows, "Line*") ~= nil, "default kind marked")
        t:check(find(rows, "Medium*") ~= nil, "default size marked")
        t:check(find(rows, "→*") ~= nil, "default angle marked")
    end)

    t:describe("ink_shape_dialog / stored options")

    t:case("the plugin stores the options and reads corrupt ones as defaults", function()
        ctx.reset()
        local p = ctx.newPlugin()
        local o = p:getShapeOptions()
        t:eq(o.kind, "line", "default kind"); t:eq(o.size, "M", "default size"); t:eq(o.angle, 0, "default angle")
        p:setShapeOptions{ kind = "arrow", size = "L", angle = 315 }
        t:eq(G_reader_settings:readSetting("justdraw_shape_kind"), "arrow", "kind stored under its key")
        t:eq(G_reader_settings:readSetting("justdraw_shape_size"), "L", "size stored")
        t:eq(G_reader_settings:readSetting("justdraw_shape_angle"), 315, "angle stored")
        o = p:getShapeOptions()
        t:eq(o.kind .. o.size .. o.angle, "arrowL315", "read back")
        G_reader_settings:saveSetting("justdraw_shape_kind", "dodecahedron")
        G_reader_settings:saveSetting("justdraw_shape_angle", "north")
        o = p:getShapeOptions()
        t:eq(o.kind, "line", "an unknown kind is the default")
        t:eq(o.angle, 0, "an unreadable angle is 0")
    end)

    t:describe("ink_shape_dialog / editor wiring")

    t:case("paste and shape controllers exist when wired, and paste gives the tool back", function()
        ctx.reset()
        local Editor = require("ink_notebook_editor")
        local tool = "pen"
        local controller = { calls = {} }
        function controller:activeSession() return nil end
        function controller:uiSnapshot() return { state = "loading", page_count = 1 } end
        local editor = Editor:new{
            controller = controller,
            notebook = { id = 1, title = "N", page_count = 1 },
            edit_tools_ready = function() return true end,
            get_tool = function() return tool end,
            set_tool = function(v) tool = v end,
            get_previous_tool = function() return "select" end,
        }
        local paste = editor:editController("paste")
        local shape = editor:editController("shape")
        t:check(paste ~= nil and paste.kind == "paste", "a paste placement")
        t:check(shape ~= nil and shape.kind == "shape", "a shape placement")
        t:check(paste ~= shape, "two separate tools")
        tool = "paste"
        paste.on_committed("paste")
        t:eq(tool, "select", "one accepted paste returns to the interrupted tool")
        tool = "shape"
        shape.on_committed("shape")
        t:eq(tool, "shape", "a shape tool stays")
        editor:shutdown()
    end)
end
