return function(ctx)
    local t = ctx.t
    local Thumbs = require("ink_thumbnail")

    local function request(over)
        local r = { db_uid = "db1", notebook_uid = "nb1", page_id = 7, revision = 3,
            template_kind = "grid", logical_w = 1000, logical_h = 1400, w = 120, h = 168 }
        for k, v in pairs(over or {}) do r[k] = v end
        return r
    end

    --- A world of fakes: a file system in a table, a scheduler queue, rasters
    --- that settle only when the test says so, and a repository whose page
    --- revision the test can move.
    local function world(opts)
        opts = opts or {}
        local w = { files = {}, sizes = {}, tasks = {}, rasters = {}, freed = {},
            revision = { [7] = 3 }, writes = 0, removed = {} }
        w.fs = {
            exists = function(p) return w.files[p] ~= nil end,
            size = function(p) return w.sizes[p] end,
            rename = function(a, b)
                if opts.rename_fails then return nil, "rename_failed" end
                w.files[b], w.sizes[b] = w.files[a], w.sizes[a]
                w.files[a], w.sizes[a] = nil, nil
                return true
            end,
            remove = function(p)
                w.removed[#w.removed + 1] = p
                w.files[p], w.sizes[p] = nil, nil
            end,
            list = function()
                local names = {}
                for p in pairs(w.files) do names[#names + 1] = p:match("[^/]+$") end
                return names
            end,
            mkdir = function() end,
        }
        w.repo = { getPage = function(_, id)
            if w.revision[id] == nil then return nil end
            return { id = id, revision = w.revision[id] }
        end }
        w.raster_open = function(ro)
            if opts.open_fails then return nil, "no_memory" end
            local job = { opts = ro, closed = false, bb = { id = #w.rasters + 1 } }
            function job.buffer(j) return (not j.closed) and j.bb or nil end
            function job.close(j)
                if not j.closed then w.freed[#w.freed + 1] = "raster" end
                j.closed = true
            end
            w.rasters[#w.rasters + 1] = job
            return job
        end
        w.scale = function(bb, sw, sh)
            if opts.scale_fails then return nil end
            local out = { from = bb, w = sw, h = sh }
            function out.free() w.freed[#w.freed + 1] = "reduced" end
            return out
        end
        w.write = function(bb, path)
            w.writes = w.writes + 1
            if w.on_write then w.on_write(path) end
            if opts.disk_full then return nil, "disk_full" end
            w.files[path] = bb
            w.sizes[path] = opts.empty_file and 0 or 512
            return true
        end
        w.schedule = function(delay, fn) w.tasks[#w.tasks + 1] = { delay = delay, fn = fn } end
        w.unschedule = function(fn)
            for i = #w.tasks, 1, -1 do
                if w.tasks[i].fn == fn then table.remove(w.tasks, i) end
            end
        end
        --- Run what is due now (delay 0), or everything with `all`.
        function w.run(all)
            local again = true
            while again do
                again = false
                for i = 1, #w.tasks do
                    local task = w.tasks[i]
                    if all or task.delay == 0 then
                        table.remove(w.tasks, i)
                        task.fn()
                        again = true
                        break
                    end
                end
            end
        end
        function w.settle(i, reason)
            local job = w.rasters[i or #w.rasters]
            if reason then job.opts.on_error(reason, job) else job.opts.on_ready(job) end
        end
        w.thumbs = Thumbs.new{ dir = "/thumbs", repository = function() return w.repo end,
            schedule = w.schedule, unschedule = w.unschedule, raster_open = w.raster_open,
            scale = w.scale, write = w.write, fs = w.fs,
            max_files = opts.max_files, max_attempts = opts.max_attempts }
        return w
    end

    local function count(list, value)
        local n = 0
        for _, v in ipairs(list) do if v == value then n = n + 1 end end
        return n
    end

    t:describe("ink_thumbnail / keys")

    t:case("the key names everything a thumbnail shows", function()
        local base = Thumbs.key(request())
        t:check(base ~= nil, "a complete request has a key")
        t:check(base:find("db1", 1, true) and base:find("nb1", 1, true), "both identities")
        local changes = {
            { revision = 4 },                           -- two edits in one second
            { page_id = 8 },                            -- another cover page
            { template_kind = "ruled" },                -- paper changed
            { logical_w = 1200 },                       -- page geometry changed
            { w = 150, h = 210 },                       -- the card's size changed
            { notebook_uid = "nb2" },                   -- a reused row id
            { db_uid = "db2" },                         -- another library
        }
        for _, change in ipairs(changes) do
            local k = Thumbs.key(request(change))
            local field = next(change)
            t:check(k and k ~= base, "a new key when " .. field .. " changes")
        end
        t:eq(Thumbs.key(request()), base, "the same request, the same key")
    end)

    t:case("requests without an identity have no key", function()
        t:eq(Thumbs.key(request({ db_uid = false })), nil, "no database")
        t:eq(Thumbs.key(request({ notebook_uid = false })), nil, "no notebook")
        t:eq(Thumbs.key(request({ revision = 0 / 0 })), nil, "NaN revision")
        t:eq(Thumbs.key(request({ w = 0 })), nil, "zero width")
        t:eq(Thumbs.key(nil), nil, "nothing")
        t:check(not Thumbs.key(request()):find("/", 1, true), "never a path separator")
        local weird = Thumbs.key(request({ notebook_uid = "../x y" }))
        t:check(not weird:find("/", 1, true) and not weird:find(" ", 1, true),
            "unsafe characters are replaced")
    end)

    t:describe("ink_thumbnail / rendering")

    t:case("a missing thumbnail is rendered, written under a temporary and renamed", function()
        local w = world()
        local got
        local path, why = w.thumbs:want(request(), function(p) got = p end)
        t:eq(path, nil, "not there yet")
        t:eq(why, "pending", "pending")
        t:eq(#w.rasters, 1, "one raster")
        local ro = w.rasters[1].opts
        t:check(math.abs(ro.scale - 0.24) < 1e-9, "twice the card, never the full page")
        t:eq(ro.surface.template_kind, "grid", "the page's paper")
        w.settle(1)
        local final = w.thumbs:pathFor(Thumbs.key(request()))
        t:eq(got, final, "the callback receives the published path")
        t:check(w.files[final] ~= nil, "published")
        t:eq(w.files[final .. ".tmp"], nil, "no temporary left")
        t:eq(count(w.freed, "raster"), 1, "the raster was freed")
        t:eq(count(w.freed, "reduced"), 1, "the reduction was freed")
        local again = w.thumbs:want(request(), function() error("not called") end)
        t:eq(again, final, "then it is served at once")
        t:eq(#w.rasters, 1, "without another raster")
    end)

    t:case("one job at a time; a duplicate request joins the queued one", function()
        local w = world()
        local heard = 0
        w.thumbs:want(request(), function() heard = heard + 1 end)
        w.thumbs:want(request(), function() heard = heard + 1 end)
        w.thumbs:want(request({ page_id = 9 }), function() end)
        w.revision[9] = 3
        t:eq(#w.rasters, 1, "the second page waits")
        w.settle(1)
        t:eq(heard, 2, "both callers heard")
        t:eq(#w.rasters, 2, "the next job started when the first finished")
    end)

    t:case("a reduction that returns the raster itself is not freed twice", function()
        local w = world()
        w.scale = function(bb) return bb end
        w.thumbs.scale = w.scale
        w.thumbs:want(request(), function() end)
        w.settle(1)
        t:eq(count(w.freed, "raster"), 1, "freed once, by the job")
        t:eq(count(w.freed, "reduced"), 0, "not as a reduction")
    end)

    t:case("a page edited while it rendered is not published", function()
        local w = world()
        local got, reason
        w.thumbs:want(request(), function(p, _, r) got, reason = p, r end)
        w.revision[7] = 4
        w.settle(1)
        local final = w.thumbs:pathFor(Thumbs.key(request()))
        t:eq(got, nil, "no path")
        t:eq(reason, "stale", "stale")
        t:eq(w.files[final], nil, "never published")
        t:eq(w.files[final .. ".tmp"], nil, "the temporary was removed")
        t:eq(w.thumbs.failed[Thumbs.key(request())], nil, "stale is not a failure")
        t:eq(w.thumbs.active, nil, "the queue is free")
    end)

    t:case("a purged page is stale too", function()
        local w = world()
        local reason
        w.thumbs:want(request(), function(_, _, r) reason = r end)
        w.revision[7] = nil
        w.settle(1)
        t:eq(reason, "stale", "the row went away")
    end)

    t:describe("ink_thumbnail / cancelling")

    t:case("cancelled before the raster settles: closed, never written", function()
        local w = world()
        local heard = false
        w.thumbs:want(request(), function() heard = true end)
        w.thumbs:retain({})
        t:eq(w.rasters[1].closed, true, "the raster was closed at once")
        w.settle(1)
        t:eq(w.writes, 0, "a late ready writes nothing")
        t:eq(heard, false, "nobody is told about a card that went away")
        t:eq(w.thumbs.active, nil, "idle")
    end)

    t:case("cancelled while writing: the temporary is removed", function()
        local w = world()
        local key = Thumbs.key(request())
        w.on_write = function() w.thumbs:retain({}) end
        w.thumbs:want(request(), function() end)
        w.settle(1)
        local final = w.thumbs:pathFor(key)
        t:eq(w.files[final], nil, "not published")
        t:eq(w.files[final .. ".tmp"], nil, "temporary removed")
        t:eq(count(w.freed, "raster"), 1, "raster freed once")
        t:eq(count(w.freed, "reduced"), 1, "reduction freed once")
    end)

    t:case("cancelled after publishing: the file stays and is served", function()
        local w = world()
        w.thumbs:want(request(), function() end)
        w.settle(1)
        w.thumbs:retain({})
        local path = w.thumbs:want(request(), function() end)
        t:eq(path, w.thumbs:pathFor(Thumbs.key(request())), "still there")
    end)

    t:case("retain keeps visible requests queued and drops the rest", function()
        local w = world()
        w.revision[8], w.revision[9] = 3, 3
        local a, b = request(), request({ page_id = 8 })
        local c = request({ page_id = 9 })
        w.thumbs:want(a, function() end)
        w.thumbs:want(b, function() end)
        w.thumbs:want(c, function() end)
        w.thumbs:retain({ [Thumbs.key(a)] = true, [Thumbs.key(c)] = true })
        t:eq(#w.thumbs.queue, 1, "one still queued")
        t:eq(w.thumbs.queue[1].key, Thumbs.key(c), "the visible one")
        w.settle(1)
        t:eq(w.rasters[2].opts.surface.id, 9, "the next job is the visible page")
    end)

    t:case("a retry waiting for a card that went away is dropped", function()
        local w = world({ disk_full = true })
        local key = Thumbs.key(request())
        w.thumbs:want(request(), function() end)
        w.settle(1)
        t:eq(#w.tasks, 1, "a retry is scheduled")
        w.thumbs:retain({})
        t:eq(#w.tasks, 0, "and unscheduled when its card is gone")
        t:eq(w.thumbs.queued[key], nil, "no longer queued")
        t:eq(#w.rasters, 1, "nothing rendered for nobody")
        t:eq(w.thumbs:has(key), false, "no file")
    end)

    t:case("close cancels everything and refuses later requests", function()
        local w = world()
        w.thumbs:want(request(), function() end)
        w.thumbs:close()
        w.thumbs:close()
        t:eq(w.rasters[1].closed, true, "closed the raster")
        local path, why = w.thumbs:want(request(), function() end)
        t:eq(path, nil, "nothing")
        t:eq(why, "closed", "closed")
    end)

    t:describe("ink_thumbnail / failures")

    local function failsWith(opts, want_reason)
        local w = world(opts)
        local reasons = {}
        w.thumbs:want(request(), function(p, _, r) reasons[#reasons + 1] = r or p end)
        for _ = 1, 3 do
            if #w.rasters > 0 and not w.rasters[#w.rasters].closed then w.settle() end
            w.run(true)
        end
        local final = w.thumbs:pathFor(Thumbs.key(request()))
        t:eq(w.files[final], nil, want_reason .. ": nothing published")
        t:eq(w.files[final .. ".tmp"], nil, want_reason .. ": no temporary left")
        t:eq(#reasons, 1, want_reason .. ": told once, after the last attempt")
        t:eq(reasons[1], want_reason, want_reason .. ": with the reason")
        return w
    end

    t:case("a full disk is retried, then reported", function()
        local w = failsWith({ disk_full = true }, "disk_full")
        t:eq(#w.rasters, 3, "three attempts")
        t:eq(count(w.freed, "raster"), 3, "every raster freed")
        t:eq(count(w.freed, "reduced"), 3, "every reduction freed")
    end)

    t:case("an empty file is not published", function()
        failsWith({ empty_file = true }, "empty_file")
    end)

    t:case("a failed reduction frees the raster", function()
        local w = failsWith({ scale_fails = true }, "scale_failed")
        t:eq(count(w.freed, "raster"), 3, "freed each time")
        t:eq(count(w.freed, "reduced"), 0, "nothing to free")
    end)

    t:case("a raster that cannot open is a failure", function()
        local w = world({ open_fails = true })
        local reason
        w.thumbs:want(request(), function(_, _, r) reason = r end)
        w.run(true); w.run(true)
        t:eq(reason, "no_memory", "reported after the attempts")
    end)

    t:case("a raster error is a failure", function()
        local w = world()
        local reason
        w.thumbs:want(request(), function(_, _, r) reason = r end)
        for _ = 1, 3 do w.settle(nil, "decode_failed"); w.run(true) end
        t:eq(reason, "decode_failed", "reported")
        t:eq(w.rasters[3].closed, true, "the raster was closed")
    end)

    t:case("a failed rename leaves no temporary", function()
        failsWith({ rename_fails = true }, "rename_failed")
    end)

    t:case("retries wait, and the queue serves other cards meanwhile", function()
        local w = world({ disk_full = true })
        w.revision[8] = 3
        w.thumbs:want(request(), function() end)
        w.thumbs:want(request({ page_id = 8 }), function() end)
        w.settle(1)
        t:eq(w.tasks[1] and w.tasks[1].delay, Thumbs.RETRY_DELAY, "the retry is later")
        t:eq(#w.rasters, 2, "the other page started meanwhile")
        t:eq(w.rasters[2].opts.surface.id, 8, "page 8")
    end)

    t:case("a failure is not asked for again until Retry", function()
        local w = failsWith({ disk_full = true }, "disk_full")
        local path, why = w.thumbs:want(request(), function() end)
        t:eq(path, nil, "no path")
        t:eq(why, "failed", "failed")
        t:eq(#w.rasters, 3, "no new attempt")
        w.thumbs:retry(request())
        w.thumbs:want(request(), function() end)
        t:eq(#w.rasters, 4, "Retry starts again")
    end)

    t:describe("ink_thumbnail / the directory")

    t:case("temporaries left by another process are removed at start", function()
        local w = world()
        w.files["/thumbs/a.png"] = true
        w.files["/thumbs/b.png.tmp"] = true
        local thumbs = Thumbs.new{ dir = "/thumbs", repository = function() return w.repo end,
            schedule = w.schedule, raster_open = w.raster_open, scale = w.scale,
            write = w.write, fs = w.fs }
        t:eq(w.files["/thumbs/b.png.tmp"], nil, "temporary removed")
        t:check(w.files["/thumbs/a.png"] ~= nil, "a thumbnail kept")
        t:eq(#thumbs.lru, 1, "and known to the LRU")
    end)

    t:case("the LRU evicts the oldest files, never a visible one", function()
        local w = world({ max_files = 2 })
        local reqs = {}
        for i = 1, 3 do
            w.revision[10 + i] = 3
            reqs[i] = request({ page_id = 10 + i })
        end
        local key1 = Thumbs.key(reqs[1])
        w.thumbs:want(reqs[1], function() end); w.settle()
        w.thumbs:want(reqs[2], function() end); w.settle()
        -- The first is on screen: the next publish must evict the second.
        w.thumbs:retain({ [key1] = true, [Thumbs.key(reqs[3])] = true })
        w.thumbs:want(reqs[3], function() end); w.settle()
        t:check(w.files[w.thumbs:pathFor(key1)] ~= nil, "the visible oldest stays")
        t:eq(w.files[w.thumbs:pathFor(Thumbs.key(reqs[2]))], nil, "the unseen one went")
        t:check(w.files[w.thumbs:pathFor(Thumbs.key(reqs[3]))] ~= nil, "the newest stays")
        t:eq(#w.thumbs.lru, 2, "back at the cap")
    end)

    t:case("serving a file refreshes its place in the LRU", function()
        local w = world({ max_files = 2 })
        local reqs = {}
        for i = 1, 3 do
            w.revision[10 + i] = 3
            reqs[i] = request({ page_id = 10 + i })
        end
        w.thumbs:want(reqs[1], function() end); w.settle()
        w.thumbs:want(reqs[2], function() end); w.settle()
        w.thumbs:want(reqs[1], function() end)   -- served, and now the newest
        w.thumbs:want(reqs[3], function() end); w.settle()
        t:check(w.files[w.thumbs:pathFor(Thumbs.key(reqs[1]))] ~= nil, "recently served stays")
        t:eq(w.files[w.thumbs:pathFor(Thumbs.key(reqs[2]))], nil, "least recent went")
    end)

    t:case("a failing callback cannot stop the queue", function()
        local w = world()
        w.revision[8] = 3
        w.thumbs:want(request(), function() error("boom") end)
        w.thumbs:want(request({ page_id = 8 }), function() end)
        w.settle(1)
        t:eq(#w.rasters, 2, "the next job started")
    end)
end
