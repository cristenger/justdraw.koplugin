return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local Controller = require("ink_input_controller")

    local function spec()
        return {
            backend = "stylus",
            stylus_handler = function() return true end,
            frame_handler = function(slots) return slots end,
        }
    end

    t:describe("ink_input_controller / lease ownership")

    t:case("only one owner can hold capture", function()
        ctx.reset()
        local a, b = {}, {}
        local first = Controller:acquire(a, spec())
        local second, err = Controller:acquire(b, spec())
        t:check(first ~= nil, "first owner acquired")
        t:eq(second, nil, "second owner refused")
        t:eq(err, "already_installed", "with a stable reason")
        t:eq(Controller:activeOwner(), a, "first owner is still active")
        first:release()
    end)

    t:case("an obsolete lease cannot remove its successor", function()
        ctx.reset()
        local a, b = {}, {}
        local old = Controller:acquire(a, spec())
        old:release()
        local current = Controller:acquire(b, spec())
        old:release()
        t:eq(Controller:activeOwner(), b, "successor survived stale release")
        t:check(env.Device.input.stylus_callback ~= nil, "hook is still installed")
        current:release()
    end)

    t:case("deferred release keeps the controller occupied until the safe tick", function()
        ctx.reset()
        local lease = Controller:acquire({}, spec())
        lease:releaseDeferred()
        local other, err = Controller:acquire({}, spec())
        t:eq(other, nil, "no half-installed successor")
        t:eq(err, "already_installed", "lease remains reserved")
        env.UIManager:flush()
        local successor = Controller:acquire({}, spec())
        t:check(successor ~= nil, "available after unhook")
        successor:release()
    end)

    t:case("a multi-slot callback failure stays installed until the frame is safe", function()
        local input = ctx.reset()
        local calls = 0
        local lease = Controller:acquire({}, {
            backend = "stylus",
            stylus_handler = function()
                calls = calls + 1
                error("probe", 0)
            end,
            frame_handler = function(slots) return slots end,
        })
        local callback = input.stylus_callback
        t:eq(callback(input, { slot = 4, id = 1 }), false, "failure passes first slot")
        t:eq(callback(input, { slot = 5, id = 2 }), false, "same callback handles next slot")
        t:eq(input.stylus_callback, callback, "not unregistered in-frame")
        env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "removed on safe tick")
        t:eq(Controller:activeOwner(), nil, "lease cleared after failure")
        t:check(lease ~= nil and calls == 1, "wrapper became inert immediately")
    end)

    t:case("a broken contact probe fails closed", function()
        ctx.reset()
        local lease = Controller:acquire({}, {
            backend = "stylus",
            stylus_handler = function() return true end,
            frame_handler = function(slots) return slots end,
            has_active_contact = function() error("probe failed", 0) end,
        })
        t:eq(lease:hasActiveContact(), true,
            "navigation must assume a contact may still be active")
        lease:release()
    end)
end
