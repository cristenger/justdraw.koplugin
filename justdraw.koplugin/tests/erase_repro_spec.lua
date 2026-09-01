--[[--
The device failure "canvas could not be loaded: chunk_count_meta" (crash.log
2026-09-01), as regressions: an eraser gesture cuts committed strokes into
fragments while the queue commits mid-gesture, and -- the actual bug --
completely erasing the newest stroke frees its SQLite rowid for the next
fragment insert, which used to collide with the erase context's id-keyed
chunk LRU and hand the dead stroke's points to the new one. The cache must
stay ready through all of it; failing closed here blanked the whole sheet.
]]
return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local support = ctx.support

    local function canvasPlugin()
        ctx.reset{ wacom_protocol = true }
        local doc = support.newDocument{
            here = "/body/p[7]", pages = { ["/body/p[7]"] = 1 },
        }
        local store = support.newCanvasStore({})
        local p = support.newPlugin(ctx.JustDraw, env, { document = doc })
        p.canvas_repository = store
        env.UIManager:flush()
        p:onReaderReady()
        env.UIManager:flush()
        return p, store
    end

    local function penDown(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, tool = tool or 1 }
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end
    local function penFrame(p, x, y, tool)
        p:onStylusEvent{ slot = 4, id = 1, x = x, y = y, tool = tool or 1 }
    end
    local function penLift(p, x, y)
        p:onStylusEvent{ slot = 4, id = -1, x = x, y = y }
    end
    local function seed(p)
        local g = p.stylus_geometry
        if g then g:observe(-1, -1); g:reset(false) end
    end

    t:describe("erase repro / chunk readback over fresh fragments")

    t:case("a sweep over just-persisted fragments keeps the cache ready", function()
        local p = canvasPlugin()
        p:openCanvasHere()
        p:setDrawing(true)
        seed(p)
        local cache = p.session:cache()

        -- Three long horizontal strokes stacked in the sheet area.
        for row = 0, 2 do
            local y = 520 + row * 30
            penDown(p, 120, y)
            for x = 130, 420, 10 do penFrame(p, x, y) end
            penLift(p, 420, y)
        end
        env.UIManager:flush()   -- commit: strokes persisted, points dropped
        t:eq(cache:stateName(), "ready", "persisted baseline is ready")

        -- Sweep 1: vertical eraser drag cutting all three into fragments.
        p:setEraser(true)
        seed(p)
        penDown(p, 260, 505)
        for y = 510, 600, 6 do penFrame(p, 260, y) end
        penLift(p, 260, 600)
        t:eq(cache:stateName(), "ready", "the cutting sweep leaves the cache ready")

        env.UIManager:flush()   -- commit MID-SESSION: fragments markPersisted
        t:eq(cache:stateName(), "ready", "persisting the fragments leaves it ready")

        -- Sweep 2: drag across the same band, hitting the fresh fragments,
        -- which now have no m.points and must be read back chunk by chunk.
        seed(p)
        penDown(p, 150, 505)
        for y = 510, 600, 6 do penFrame(p, 150, y) end
        for x = 155, 400, 8 do penFrame(p, x, 560) end
        penLift(p, 400, 560)
        t:eq(cache:stateName(), "ready",
            "sweeping over just-persisted fragments must not fail the cache")

        -- And a third pass with commits interleaved inside the gesture, the
        -- way the device log shows them.
        env.UIManager:flush()
        seed(p)
        penDown(p, 300, 505)
        for y = 510, 596, 6 do
            penFrame(p, 300, y)
            if y % 24 == 0 then env.UIManager:flush() end
        end
        penLift(p, 300, 596)
        t:eq(cache:stateName(), "ready",
            "commits interleaved inside the sweep must not fail the cache")
    end)

    t:case("a reused row id never resurrects a dead stroke from the erase LRU", function()
        -- The device failure (crash.log 2026-09-01, chunk_count_meta):
        -- completely erasing the NEWEST stroke frees its SQLite rowid
        -- (INTEGER PRIMARY KEY without AUTOINCREMENT assigns max+1), the next
        -- fragment insert in the same gesture reuses it, and the erase
        -- context's chunk LRU -- keyed by id -- hands the dead stroke's
        -- points to the new one. The count check trips and the whole cache
        -- fails closed: blank sheet, Retry, drawing off.
        local p, store = canvasPlugin()
        p:openCanvasHere()
        p:setDrawing(true)
        seed(p)
        local cache = p.session:cache()
        local function ids()
            local out = {}
            for _, list in pairs(store.strokes) do
                for _, s in ipairs(list) do out[#out + 1] = s.id end
            end
            table.sort(out)
            return out
        end

        -- Stroke A: long, drawn first. Stroke B: a short dash drawn LAST and
        -- ON TOP of A's line, so it holds the max row id, a capsule pass
        -- swallows it whole, and its dead geometry stays inside the band the
        -- eraser keeps scrubbing -- the way a reader rubs out a correction.
        penDown(p, 120, 540)
        for x = 130, 420, 10 do penFrame(p, x, 540) end
        penLift(p, 420, 540)
        penDown(p, 240, 540)
        penFrame(p, 246, 540)
        penFrame(p, 252, 540)
        penLift(p, 252, 540)
        env.UIManager:flush()   -- both persisted; B owns the max id
        t:eq(cache:stateName(), "ready", "baseline ready")
        t:eq(#ids(), 2, "two strokes persisted")
        local b_id = ids()[2]

        -- One continuous eraser gesture: eat B completely (its chunks enter
        -- the LRU while hit-testing), let the delete COMMIT mid-gesture so
        -- the max id drops, then cut A so a fragment insert reuses B's id,
        -- commit again, and keep sweeping over that fragment.
        p:setEraser(true)
        seed(p)
        -- Scrub the band: the first pass swallows B and cuts A around it (a
        -- fragment insert reuses B's freed id inside the same or the next
        -- commit); the return passes keep hit-testing that fragment while the
        -- LRU still holds B's points under the same id.
        penDown(p, 200, 540)
        for x = 210, 290, 10 do
            penFrame(p, x, 540)
            if x == 250 then env.UIManager:flush() end
        end
        env.UIManager:flush()
        local after = ids()
        t:check(#after >= 2, "the cut left fragments")
        -- The freed id is reassigned somewhere in the churn of this pass;
        -- later frames may cut the reused stroke again, so the surviving id
        -- set is not asserted exactly -- the poisoned-LRU outcome below is
        -- the pin. What must hold is that ids never grew past reuse range.
        t:check(after[#after] <= b_id + #after, "ids stay in reuse range")
        for x = 280, 200, -10 do penFrame(p, x, 540) end
        env.UIManager:flush()
        for x = 210, 290, 10 do penFrame(p, x, 540) end
        penLift(p, 290, 540)
        t:eq(cache:stateName(), "ready",
            "a stale LRU entry under a reused id must not fail the cache")
    end)
end
