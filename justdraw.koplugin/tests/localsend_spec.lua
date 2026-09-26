return function(ctx)
    local t = ctx.t
    local LocalSend = require("ink_localsend")

    --- A file system in a table. Paths are strings; a node is a folder, a
    --- file or a link. `lstat` never follows a link, which is the property
    --- the sweep depends on.
    local function memfs(clock)
        local fs = { nodes = { ["/cache"] = { mode = "directory", modification = 0 } }, removed = {} }
        local function parent(path) return path:match("^(.*)/[^/]+$") end
        function fs.lstat(path)
            local n = fs.nodes[path]
            if not n then return nil end
            return { mode = n.mode, size = n.text and #n.text or n.size or 0,
                modification = n.modification or clock.now }
        end
        function fs.list(dir)
            local out = {}
            for path in pairs(fs.nodes) do
                if parent(path) == dir then out[#out + 1] = path:match("([^/]+)$") end
            end
            table.sort(out)
            return out
        end
        function fs.mkdir(path)
            if fs.nodes[path] or not fs.nodes[parent(path)] then return nil end
            fs.nodes[path] = { mode = "directory", modification = clock.now }
            return true
        end
        function fs.rmdir(path)
            if #fs.list(path) > 0 then return nil, "not empty" end
            fs.nodes[path] = nil
            return true
        end
        function fs.remove(path)
            fs.removed[#fs.removed + 1] = path
            fs.nodes[path] = nil
            return true
        end
        function fs.write(path, text)
            if fs.fail_write then return nil, "disk full" end
            if not fs.nodes[parent(path)] then return nil, "no folder" end
            fs.nodes[path] = { mode = "file", text = text, modification = clock.now }
            return true
        end
        function fs.read(path)
            local n = fs.nodes[path]
            return n and n.mode == "file" and n.text or nil
        end
        return fs
    end

    local function world(token)
        local clock = { now = 10000000 }
        local fs = memfs(clock)
        local staging = LocalSend.staging{ root = "/cache/justdraw-send", fs = fs,
            now = function() return clock.now end, token = token or "aaaa" }
        return staging, fs, clock
    end

    t:describe("ink_localsend / finding LocalSend")

    t:case("found on the reader, validated, and never cached", function()
        local calls = 0
        local instance = { showFileSendFlow = function(self, path) calls = calls + 1; self.path = path end }
        t:eq(LocalSend.find({ LocalSend = instance }), instance, "on the reader")
        t:eq(LocalSend.find({}, { getPluginInstance = function(_, name)
            return name == "LocalSend" and instance or nil end }), instance, "through PluginLoader")
        local none, why = LocalSend.find({}, nil)
        t:eq(none, nil, "absent"); t:eq(why, "absent", "and says so")
        t:eq(select(2, LocalSend.find({ LocalSend = { recovery_mode = true,
            showFileSendFlow = function() end } })), "recovery_mode", "recovery mode is not usable")
        t:eq(select(2, LocalSend.find({ LocalSend = { reinstall_required = true,
            showFileSendFlow = function() end } })), "reinstall_required", "nor a pending reinstall")
        t:eq(select(2, LocalSend.find({ LocalSend = {} })), "no_send_flow", "nor one without the method")
        t:eq(select(2, LocalSend.find({}, { getPluginInstance = function() error("boom") end })),
            "absent", "a loader that raises is absence")
        -- Recreated with the reader: the next lookup finds the new one.
        local newer = { showFileSendFlow = function() end }
        local ui = { LocalSend = instance }
        ui.LocalSend = newer
        t:eq(LocalSend.find(ui), newer, "the current instance, not a remembered one")
        t:eq(calls, 0, "finding opens nothing")
    end)

    t:case("opening says only that the flow opened", function()
        local got
        local ok = LocalSend.open({ showFileSendFlow = function(_, p) got = p; return nil end }, "/x.pdf")
        t:eq(ok, true, "a nil return is still an opened flow")
        t:eq(got, "/x.pdf", "with the path")
        local bad, why = LocalSend.open({ showFileSendFlow = function() error("no wifi") end }, "/x")
        t:eq(bad, nil, "a raise is a failure"); t:eq(why, "open_failed", "open_failed")
        t:eq(select(2, LocalSend.open({ showFileSendFlow = function() end }, "")), "no_path", "no path")
    end)

    t:describe("ink_localsend / staging")

    t:case("one folder per send, a manifest of what we wrote, one file handed by path", function()
        LocalSend._resetHanded()
        local staging, fs = world()
        local op = assert(staging:begin())
        t:check(op.dir:match("^/cache/justdraw%-send/op%-10000000%-aaaa%-1$") ~= nil, "named for time, process and serial")
        fs.write(op.dir .. "/A.pdf", "pdf")
        assert(op:record(op.dir .. "/A.pdf"))
        t:eq(select(2, op:record("/elsewhere/B.pdf")), "outside", "nothing outside the folder")
        local manifest = LocalSend.parseManifest(fs.read(op.dir .. "/.justdraw-send"))
        t:eq(manifest.token, "aaaa", "the process")
        t:eq(manifest.files[1], "A.pdf", "the file")
        t:eq(op:target(), op.dir .. "/A.pdf", "one file goes by path")
        fs.write(op.dir .. "/B.pdf", "pdf"); op:record(op.dir .. "/B.pdf")
        t:eq(op:target(), op.dir, "several go as the folder")
        local op2 = assert(staging:begin())
        t:check(op2.dir ~= op.dir, "two sends, two folders")
    end)

    t:case("an abandoned send is removed; a handed-over one never is", function()
        LocalSend._resetHanded()
        local staging, fs = world()
        local op = assert(staging:begin())
        fs.write(op.dir .. "/A.pdf", "x"); op:record(op.dir .. "/A.pdf")
        fs.write(op.dir .. "/stranger.txt", "not ours")
        op:abandon()
        t:eq(fs.nodes[op.dir .. "/A.pdf"], nil, "our file went")
        t:check(fs.nodes[op.dir .. "/stranger.txt"] ~= nil, "a file we did not write stays")
        t:check(fs.nodes[op.dir] ~= nil, "and so does its folder")
        local sent = assert(staging:begin())
        fs.write(sent.dir .. "/B.pdf", "x"); sent:record(sent.dir .. "/B.pdf")
        sent:handOff()
        t:eq(sent:abandon(), false, "handed over: not abandoned")
        t:check(fs.nodes[sent.dir .. "/B.pdf"] ~= nil, "still there for LocalSend")
    end)

    t:case("the cap is checked before staging, and nothing is freed to make room", function()
        LocalSend._resetHanded()
        local staging, fs = world()
        staging.max_bytes = 10
        local op = assert(staging:begin())
        fs.write(op.dir .. "/big.pdf", string.rep("x", 20)); op:record(op.dir .. "/big.pdf")
        local refused, why = staging:begin()
        t:eq(refused, nil, "refused"); t:eq(why, "staging_full", "full")
        t:check(fs.nodes[op.dir .. "/big.pdf"] ~= nil, "the earlier send untouched")
    end)

    t:describe("ink_localsend / sweeping")

    local function oldOp(fs, root, name, token, created, files)
        local dir = root .. "/" .. name
        fs.nodes[dir] = { mode = "directory", modification = created }
        local lines = { "justdraw-send 1", "token " .. token, "created " .. created }
        for _, f in ipairs(files or {}) do
            lines[#lines + 1] = "file " .. f
            fs.nodes[dir .. "/" .. f] = { mode = "file", text = "x", modification = created }
        end
        fs.nodes[dir .. "/.justdraw-send"] = { mode = "file", text = table.concat(lines, "\n") .. "\n",
            modification = created }
        return dir
    end

    t:case("only old, manifested sends of other processes are swept", function()
        LocalSend._resetHanded()
        local staging, fs, clock = world("bbbb")
        local root = "/cache/justdraw-send"
        fs.mkdir(root)
        local day = 24 * 3600
        local old = oldOp(fs, root, "op-1000-aaaa-1", "aaaa", clock.now - day - 1, { "A.pdf" })
        local young = oldOp(fs, root, "op-2000-aaaa-2", "aaaa", clock.now - 60, { "B.pdf" })
        local mine = oldOp(fs, root, "op-3000-bbbb-1", "bbbb", clock.now - 2 * day, { "C.pdf" })
        local future = oldOp(fs, root, "op-4000-aaaa-3", "aaaa", clock.now + day, { "D.pdf" })
        local forged = oldOp(fs, root, "op-5000-aaaa-4", "cccc", clock.now - 2 * day, { "E.pdf" })
        fs.nodes[root .. "/op-6000-aaaa-5"] = { mode = "link", modification = 0 }
        fs.nodes[root .. "/notes.txt"] = { mode = "file", text = "x", modification = 0 }
        local bare = root .. "/op-7000-aaaa-6"
        fs.nodes[bare] = { mode = "directory", modification = 0 }
        local extra = oldOp(fs, root, "op-8000-aaaa-7", "aaaa", clock.now - 2 * day, { "F.pdf" })
        fs.nodes[extra .. "/user-added.pdf"] = { mode = "file", text = "x", modification = 0 }
        local report = staging:sweep()
        t:eq(fs.nodes[old], nil, "the old send is gone")
        t:check(fs.nodes[young] ~= nil, "a young one stays")
        t:check(fs.nodes[mine] ~= nil, "this process's stays")
        t:check(fs.nodes[future] ~= nil, "a time in the future is kept for review")
        t:check(fs.nodes[forged] ~= nil, "a manifest for another name is not trusted")
        t:check(fs.nodes[root .. "/op-6000-aaaa-5"] ~= nil, "a link is neither followed nor removed")
        t:check(fs.nodes[root .. "/notes.txt"] ~= nil, "a stray file stays")
        t:check(fs.nodes[bare] ~= nil, "a folder with no manifest stays")
        t:check(fs.nodes[extra .. "/user-added.pdf"] ~= nil, "a file the manifest does not list stays")
        t:eq(fs.nodes[extra .. "/F.pdf"], nil, "while the listed one goes")
        t:check(fs.nodes[extra] ~= nil, "and the folder, not empty, stays")
        t:eq(report.removed, 1, "one removed")
        t:eq(report.kept["op-2000-aaaa-2"], "too_young", "young")
        t:eq(report.kept["op-4000-aaaa-3"], "future_time", "future")
        t:eq(report.kept["op-6000-aaaa-5"], "not_a_folder", "link")
        t:eq(report.kept["op-8000-aaaa-7"], "not_empty", "not empty")
    end)

    t:case("after a restart, the previous process's sends age out like any other", function()
        LocalSend._resetHanded()
        local first, fs, clock = world("aaaa")
        local op = assert(first:begin())
        fs.write(op.dir .. "/A.pdf", "x"); op:record(op.dir .. "/A.pdf")
        op:handOff()
        t:eq(first:sweep{ min_age = 0 }.kept[op.name], "handed_over", "never in the process that handed it")
        LocalSend._resetHanded()   -- a new KOReader process
        local second = LocalSend.staging{ root = first.root, fs = fs,
            now = function() return clock.now end, token = "bbbb" }
        t:eq(second:sweep().kept[op.name], "too_young", "young after the restart")
        clock.now = clock.now + 24 * 3600 + 1
        fs.nodes[op.dir].modification = 0
        second:sweep()
        t:eq(fs.nodes[op.dir], nil, "then swept")
    end)

    t:case("manifests are parsed strictly", function()
        t:eq(LocalSend.parseManifest("junk"), nil, "junk")
        t:eq(LocalSend.parseManifest("justdraw-send 1\ntoken zz\ncreated 1\n"), nil, "bad token")
        t:eq(LocalSend.parseManifest("justdraw-send 1\ntoken ab\ncreated 1\nfile ../x\n"), nil, "a path")
        t:eq(LocalSend.parseManifest("justdraw-send 1\ntoken ab\ncreated 1\nfile .justdraw-send\n"), nil,
            "the manifest itself")
        local ok = LocalSend.parseManifest("justdraw-send 1\ntoken ab\ncreated 5\nfile Ñandú.pdf\n")
        t:eq(ok.files[1], "Ñandú.pdf", "UTF-8 names")
        t:eq(LocalSend.fileStem("a/b:c"), "a_b_c", "no separators")
        t:eq(LocalSend.fileStem("..."), "Notebook", "never empty or hidden")
    end)

    t:describe("ink_localsend / the send flow")

    local function flowWorld(opts)
        opts = opts or {}
        LocalSend._resetHanded()
        local staging, fs = world()
        local sched = require("support").newScheduler()
        local opened = {}
        local instance = { showFileSendFlow = function(_, path) opened[#opened + 1] = path end }
        local present = { value = true }
        local modals, notes = {}, {}
        local exports = {}
        local w = {
            staging = staging, fs = fs, sched = sched, opened = opened, notes = notes,
            modals = modals, exports = exports, present = present, instance = instance,
        }
        w.opts = {
            items = opts.items or { { id = 1, title = "Uno" }, { id = 2, title = "Dos" } },
            find = function() return present.value and instance or nil end,
            staging = staging,
            export_one = function(item, format, dir, stem, done)
                exports[#exports + 1] = { item = item, format = format, dir = dir, stem = stem }
                local outcome = opts.outcome and opts.outcome(item, #exports) or "done"
                if outcome == "done" then
                    local path = dir .. "/" .. stem .. "." .. format
                    fs.write(path, "data")
                    done({ status = "done", written = { path } })
                elseif outcome == "raise" then
                    error("no memory")
                else
                    done({ status = outcome })
                end
            end,
            show_modal = function(widget) modals[#modals + 1] = widget; return widget end,
            close_modal = function(widget)
                for i = #modals, 1, -1 do if modals[i] == widget then table.remove(modals, i) end end
                if widget.onCloseWidget then widget:onCloseWidget() end
            end,
            notify = function(text) notes[#notes + 1] = text end,
            schedule = function(fn) sched:schedule(fn) end,
        }
        return w
    end

    local function choose(w, label)
        local dialog = w.modals[#w.modals]
        for _, row in ipairs(dialog.buttons) do
            if row[1].text == label then return row[1].callback() end
        end
        error("no " .. label)
    end

    t:case("several notebooks: every export first, then LocalSend gets the folder", function()
        local w = flowWorld()
        assert(LocalSend.send(w.opts))
        choose(w, "Xournal++")
        w.sched:drain()
        t:eq(#w.exports, 2, "both exported")
        t:eq(w.exports[1].format, "xopp", "in the chosen format")
        t:eq(w.exports[1].dir, w.exports[2].dir, "into one folder")
        t:eq(#w.opened, 1, "LocalSend opened once")
        t:eq(w.opened[1], w.exports[1].dir, "on the folder")
        t:check(w.notes[1]:find("LocalSend is open", 1, true) ~= nil, "open, not sent")
        t:eq(LocalSend.activeFlow(), nil, "the flow is over")
    end)

    t:case("one notebook: LocalSend gets the file", function()
        local w = flowWorld{ items = { { id = 1, title = "Solo" } } }
        LocalSend.send(w.opts)
        choose(w, "PDF")
        w.sched:drain()
        t:eq(w.opened[1], w.exports[1].dir .. "/Solo.pdf", "by path")
    end)

    t:case("same titles get different files", function()
        local w = flowWorld{ items = { { id = 1, title = "Notes" }, { id = 2, title = "Notes" } } }
        LocalSend.send(w.opts)
        choose(w, "PDF")
        w.sched:drain()
        t:eq(w.exports[2].stem, "Notes (2)", "numbered")
    end)

    t:case("a failure is never sent as a subset: retry, or stop and clean up", function()
        local tries = 0
        local w = flowWorld{ outcome = function(item)
            if item.id == 2 then tries = tries + 1; return tries == 1 and "failed" or "done" end
            return "done"
        end }
        LocalSend.send(w.opts)
        choose(w, "PDF")
        w.sched:drain()
        t:eq(#w.opened, 0, "nothing handed over")
        local box = w.modals[#w.modals]
        t:check(box.text:find("• Dos", 1, true) ~= nil, "the failure named")
        box.ok_callback()
        w.sched:drain()
        t:eq(#w.exports, 3, "only the failed one again")
        t:eq(#w.opened, 1, "then sent, whole")

        local w2 = flowWorld{ outcome = function(item) return item.id == 2 and "raise" or "done" end }
        LocalSend.send(w2.opts)
        choose(w2, "PDF")
        w2.sched:drain()
        local box2 = w2.modals[#w2.modals]
        local dir = w2.exports[1].dir
        box2.cancel_callback()
        t:eq(w2.fs.nodes[dir .. "/Uno.pdf"], nil, "stopping removes what was staged")
        t:eq(#w2.opened, 0, "and sends nothing")
        t:eq(LocalSend.activeFlow(), nil, "the flow is over")
    end)

    t:case("LocalSend gone before the hand-off: the files are kept and it can be retried", function()
        local w = flowWorld()
        LocalSend.send(w.opts)
        choose(w, "PDF")
        w.present.value = false
        w.sched:drain()
        t:eq(#w.opened, 0, "nothing opened")
        local box = w.modals[#w.modals]
        t:check(box.text:find("kept in", 1, true) ~= nil, "the reader is told where")
        t:check(w.fs.nodes[w.exports[1].dir .. "/Uno.pdf"] ~= nil, "the files are kept")
        w.present.value = true
        box.ok_callback()
        w.sched:drain()
        t:eq(#w.opened, 1, "the retry opens LocalSend")
    end)

    t:case("closing the format question, a second send, and cancelling mid-way", function()
        local w = flowWorld()
        LocalSend.send(w.opts)
        t:eq(select(2, LocalSend.send(w.opts)), "busy", "one send at a time")
        w.opts.close_modal(w.modals[#w.modals])
        t:eq(LocalSend.activeFlow(), nil, "closing the question ends the flow")
        t:eq(#w.exports, 0, "and exports nothing")

        local w2 = flowWorld{ outcome = function(_, n) return n == 2 and "cancelled" or "done" end }
        LocalSend.send(w2.opts)
        choose(w2, "PDF")
        w2.sched:drain()
        t:eq(#w2.opened, 0, "a cancelled export sends nothing")
        t:eq(w2.fs.nodes[w2.exports[1].dir .. "/Uno.pdf"], nil, "and removes what it staged")

        local w3 = flowWorld()
        LocalSend.send(w3.opts)
        choose(w3, "PDF")
        LocalSend.cancelActive()
        w3.sched:drain()
        t:eq(#w3.exports, 1, "suspend stops before the next export")
        t:eq(#w3.opened, 0, "and sends nothing")
    end)

    t:case("no LocalSend: nothing starts", function()
        local w = flowWorld()
        w.present.value = false
        local flow, why = LocalSend.send(w.opts)
        t:eq(flow, nil, "no flow"); t:eq(why, "absent", "absent")
        t:eq(#w.modals, 0, "no question asked")
        t:check(w.notes[1]:find("isn’t available", 1, true) ~= nil, "the reader is told")
    end)
end
