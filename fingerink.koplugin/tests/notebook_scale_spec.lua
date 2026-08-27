return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Session = require("ink_notebook_session")

    t:describe("standalone notebooks / scale contracts")

    t:case("a 10,000-page library returns one metadata page and no strokes", function()
        local pages = {}
        for i = 1, 10000 do
            pages[i] = { id = i, notebook_id = 1, sort_key = i * 1024,
                logical_w = 1000, logical_h = 1400, template_kind = "blank" }
        end
        local store = support.newNotebookStore{ pages = pages }
        local rows = store:listPages(1, { limit = 50 })
        t:eq(#rows, 50, "bounded metadata page")
        t:eq(store.calls.stroke_list, 0, "no stroke metadata")
        t:eq(store.calls.stroke_read, 0, "no point payload")
    end)

    t:case("switching through 100 pages retains exactly one live raster", function()
        local pages = {}
        for i = 1, 100 do
            pages[i] = { id = i, notebook_id = 1, sort_key = i * 1024,
                logical_w = 1000, logical_h = 1400, template_kind = "blank" }
        end
        local store = support.newNotebookStore{ pages = pages }
        local session = Session.new{
            repository = store,
            schedule = function(fn) fn() end,
            scheduleIn = function(_, fn) fn() end,
            unschedule = function() end,
            fit_rect = { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = { x = 0, y = 0, w = 1000, h = 1400 },
        }
        session:open(1)
        for i = 2, 100 do
            local old = session:surface():cache():buffer()
            t:eq(session:goToPage(i), true, "page " .. i)
            t:eq(old.freed, true, "old raster " .. (i - 1) .. " freed")
        end
        t:eq(session:currentPage().id, 100, "last page active")
        t:eq(store.calls.stroke_read, 0, "empty navigation decoded no points")
    end)
end
