-- FingerInk -> JustDraw compatibility and data-identity migration.

return function(ctx)
    local t = ctx.t
    local Compat = require("ink_compat")

    local function settings(data)
        return {
            data = data or {},
            readSetting = function(self, key) return self.data[key] end,
            saveSetting = function(self, key, value) self.data[key] = value end,
            delSetting = function(self, key) self.data[key] = nil end,
        }
    end

    t:describe("rename compatibility")

    t:case("legacy settings migrate forward without losing false", function()
        local s = settings{ fingerink_live_fast = false }
        t:eq(Compat.readSetting(s, "live_fast", true), false, "legacy false survives")
        t:eq(s.data.justdraw_live_fast, false, "current key is populated")
        t:eq(s.data.fingerink_live_fast, false, "legacy key remains for rollback")
    end)

    t:case("current settings take precedence over legacy values", function()
        local s = settings{
            justdraw_bar_side = "left",
            fingerink_bar_side = "right",
        }
        t:eq(Compat.readSetting(s, "bar_side", "right"), "left", "current value wins")
    end)

    t:case("deleting migrated document ink removes both identities", function()
        local s = settings{
            justdraw_strokes = { [1] = {} },
            fingerink_strokes = { [1] = {} },
        }
        Compat.delSetting(s, "strokes")
        t:eq(s.data.justdraw_strokes, nil, "current ink removed")
        t:eq(s.data.fingerink_strokes, nil, "legacy ink cannot reappear")
    end)

    t:case("database path reuses one identity and refuses two histories", function()
        local dir = "/settings"
        local current_name = "justdraw.sqlite3"
        local legacy_name = "fingerink.sqlite3"
        local current = dir .. "/" .. current_name
        local legacy = dir .. "/" .. legacy_name
        ctx.env.file_modes = {}

        t:eq(Compat.databasePath(dir, current_name, legacy_name), current,
            "new install chooses current filename")

        ctx.env.file_modes[legacy] = "file"
        t:eq(Compat.databasePath(dir, current_name, legacy_name), legacy,
            "upgrade opens existing legacy database in place")

        ctx.env.file_modes[current] = "file"
        local path, reason, current_path, legacy_path =
            Compat.databasePath(dir, current_name, legacy_name)
        t:eq(path, nil, "two databases are never selected silently")
        t:eq(reason, "database_conflict", "conflict is actionable")
        t:eq(current_path, current, "current candidate reported")
        t:eq(legacy_path, legacy, "legacy candidate reported")

        ctx.env.file_modes[legacy] = nil
        t:eq(Compat.databasePath(dir, current_name, legacy_name), current,
            "an existing current path is selected without probing readability")
        ctx.env.file_modes = {}
    end)

    t:case("divergent sidecars keep one active history without overwriting the other", function()
        local current = { [1] = { { n = 2, w = 4, 1, 1, 2, 2 } } }
        local rollback = {
            [1] = { { n = 2, w = 4, 1, 1, 2, 2 } },
            [3] = { { n = 2, w = 4, 5, 5, 6, 6 } },
        }
        local s = settings{
            justdraw_strokes = current,
            fingerink_strokes = rollback,
        }
        local loaded, storage_id = Compat.readDataSetting(s, "strokes")
        loaded[2] = { { n = 2, w = 4, 3, 3, 4, 4 } }
        Compat.saveDataSetting(s, "strokes", storage_id, loaded)
        t:eq(storage_id, "justdraw", "current key is authoritative when both exist")
        t:eq(s.data.justdraw_strokes, current, "current key remains authoritative")
        t:eq(s.data.fingerink_strokes, rollback, "legacy history is not overwritten")
        t:eq(#s.data.fingerink_strokes[3], 1,
            "ink made during rollback remains recoverable")
        t:eq(s.data.fingerink_strokes[2], nil,
            "divergent histories are never synchronized automatically")
    end)

    t:case("plugin imports legacy preferences and direct document ink", function()
        ctx.reset()
        _G.G_reader_settings.data.fingerink_input_mode = "finger"
        _G.G_reader_settings.data.fingerink_bar_shown = false
        local legacy = { [2] = { { 10, 10, 20, 20 } } }
        local plugin = ctx.newPlugin{
            page = 2,
            doc_settings = { fingerink_strokes = legacy },
        }

        t:eq(plugin.input_mode, "finger", "legacy input mode restored")
        t:eq(plugin.bar, nil, "legacy hidden-toolbar preference restored")
        t:eq(plugin.store.pages, legacy, "legacy document ink is used in place")
        t:eq(plugin.stroke_storage_id, "fingerink", "legacy key remains the active store")
        t:eq(#plugin.store.pages[2], 1, "legacy document ink loaded")
        t:eq(_G.G_reader_settings.data.justdraw_input_mode, "finger",
            "input mode migrated")
        t:eq(_G.G_reader_settings.data.justdraw_bar_shown, false,
            "toolbar preference migrated")

        plugin.store:add(3, { n = 2, w = 4, 30, 30, 40, 40 })
        plugin:onSaveSettings()
        t:eq(plugin.ui.doc_settings.data.fingerink_strokes, legacy,
            "upgraded document keeps one in-place stroke table")
        t:eq(#plugin.ui.doc_settings.data.fingerink_strokes[3], 1,
            "JustDraw edits remain visible to an old-plugin rollback")
        t:eq(plugin.ui.doc_settings.data.justdraw_strokes, nil,
            "no duplicate current table is created")

        plugin:clearWholeDocumentInk()
        plugin:onSaveSettings()
        t:eq(plugin.ui.doc_settings.data.justdraw_strokes, nil,
            "current document ink cleared")
        t:eq(plugin.ui.doc_settings.data.fingerink_strokes, nil,
            "legacy document ink cleared with it")
    end)

    t:case("new documents store direct ink under JustDraw only", function()
        ctx.reset()
        local plugin = ctx.newPlugin{ page = 1, doc_settings = {} }
        plugin:onSaveSettings()
        t:eq(plugin.ui.doc_settings.data.justdraw_strokes, nil,
            "opening a blank document creates no empty key")
        plugin.store:add(1, { n = 2, w = 4, 1, 1, 2, 2 })
        plugin:onSaveSettings()
        t:eq(plugin.stroke_storage_id, "justdraw", "new identity selected")
        t:eq(#plugin.ui.doc_settings.data.justdraw_strokes[1], 1,
            "new ink saved under current key")
        t:eq(plugin.ui.doc_settings.data.fingerink_strokes, nil,
            "legacy key is not created")
    end)

    t:case("emptying current ink preserves a divergent legacy history", function()
        ctx.reset()
        local current = { [1] = { { n = 2, w = 4, 1, 1, 2, 2 } } }
        local legacy = { [3] = { { n = 2, w = 4, 5, 5, 6, 6 } } }
        local plugin = ctx.newPlugin{
            page = 1,
            doc_settings = {
                justdraw_strokes = current,
                fingerink_strokes = legacy,
            },
        }
        t:eq(plugin.store:pop(1) ~= nil, true, "last current stroke removed")
        plugin:onSaveSettings()
        local saved = plugin.ui.doc_settings.data
        t:check(type(saved.justdraw_strokes) == "table"
            and next(saved.justdraw_strokes) == nil,
            "empty current tombstone prevents legacy fallback")
        t:eq(saved.fingerink_strokes, legacy,
            "undo never deletes the inactive legacy history")

        local reopened = ctx.newPlugin{ page = 1, doc_settings = saved }
        t:eq(reopened.stroke_storage_id, "justdraw", "empty current remains active")
        t:eq(reopened.store:isEmpty(), true, "legacy ink does not reappear")
        t:eq(reopened.ui.doc_settings.data.fingerink_strokes, legacy,
            "legacy remains available for manual recovery")
    end)

    t:case("legacy Gesture Manager actions still target JustDraw handlers", function()
        ctx.reset()
        local plugin = ctx.newPlugin{ doc_settings = {} }
        local actions = ctx.env.dispatcher_actions
        t:eq(actions.fingerink_toggle.event, "FingerInkToggle", "toggle event retained")
        t:eq(actions.fingerink_eraser.event, "FingerInkEraser", "eraser event retained")
        t:eq(actions.fingerink_undo.event, "FingerInkUndo", "undo event retained")
        t:eq(actions.fingerink_bar.event, "FingerInkBar", "bar event retained")
        t:eq(plugin.onFingerInkToggle, plugin.onJustDrawToggle, "toggle alias resolves")
        t:eq(plugin.onFingerInkEraser, plugin.onJustDrawEraser, "eraser alias resolves")
        t:eq(plugin.onFingerInkUndo, plugin.onJustDrawUndo, "undo alias resolves")
        t:eq(plugin.onFingerInkBar, plugin.onJustDrawBar, "bar alias resolves")
    end)

    -- =================================================================
    --[[--
    The capability report (ADR-41).

    No feature is version-string-gated: what separates the two runtimes is the
    stylus callback pair, and the other three are asserted so an unusual build
    fails loudly instead of half-working. Everything here is injected, because
    the whole point of the probe is what it does when a module is not there.
    ]]
    t:describe("runtime capabilities")

    local function input(present)
        if not present then return false end
        return {
            registerStylusCallback = function() end,
            unregisterStylusCallback = function() end,
        }
    end

    local function readerView(present)
        if not present then return false end
        return {
            screenToPageTransform = function() end,
            pageToScreenTransform = function() end,
        }
    end

    local function document(present)
        if not present then return false end
        return { getNativePageDimensions = function() end }
    end

    --- A Blitbuffer module shaped like the real one for the alpha probe: a
    --- numeric TYPE_BB8A, a callable Color8A and a buffer that knows how to
    --- compose. `freed` is what proves the probe releases what it made.
    local function blitbuffer(opts)
        opts = opts or {}
        local made = {}
        if opts.present == false then return made, false end
        local module = {
            TYPE_BB8A = opts.no_type and "two" or 2,
            new = function(w, h, bbtype)
                local bb = { w = w, h = h, bbtype = bbtype, freed = false }
                if not opts.no_alphablit then bb.alphablitFrom = function() end end
                function bb:free() self.freed = true end
                made[#made + 1] = bb
                return bb
            end,
        }
        if not opts.no_color then
            module.Color8A = function(v, a) return { v, a } end
        end
        return made, module
    end

    local function caps(over)
        over = over or {}
        local function want(key) return over[key] ~= false end
        local _, bb = blitbuffer{
            present = want("Blitbuffer"),
            no_type = over.no_type,
            no_color = over.no_color,
            no_alphablit = over.no_alphablit,
        }
        return Compat.capabilities{
            input = input(want("input")),
            ReaderView = readerView(want("ReaderView")),
            Document = document(want("Document")),
            Blitbuffer = bb,
        }
    end

    t:case("a complete runtime answers every capability true", function()
        local c = caps()
        t:eq(c.stylus_api, true, "the stylus callback pair")
        t:eq(c.view_transform, true, "both ReaderView transforms")
        t:eq(c.native_dimensions, true, "the document's native page size")
        t:eq(c.alpha_blit, true, "and a BB8A buffer that composes")
    end)

    t:case("each missing dependency answers false and nothing else does", function()
        local missing = {
            { field = "input", capability = "stylus_api" },
            { field = "ReaderView", capability = "view_transform" },
            { field = "Document", capability = "native_dimensions" },
            { field = "Blitbuffer", capability = "alpha_blit" },
        }
        for i = 1, #missing do
            local c = caps{ [missing[i].field] = false }
            t:eq(c[missing[i].capability], false,
                missing[i].field .. " absent means " .. missing[i].capability .. " false")
            for j = 1, #missing do
                if j ~= i then
                    t:eq(c[missing[j].capability], true,
                        missing[j].capability .. " is unaffected")
                end
            end
        end
    end)

    t:case("half a stylus API is not a stylus API", function()
        local c = Compat.capabilities{
            input = { registerStylusCallback = function() end },
            ReaderView = false, Document = false, Blitbuffer = false,
        }
        t:eq(c.stylus_api, false, "unregistering is half the pair")
    end)

    t:case("one transform is not the pair either", function()
        local c = Compat.capabilities{
            input = false, Document = false, Blitbuffer = false,
            ReaderView = { screenToPageTransform = function() end },
        }
        t:eq(c.view_transform, false, "the inverse is what paints the ink back")
    end)

    t:case("the alpha probe wants all three of its parts", function()
        t:eq(caps{ no_type = true }.alpha_blit, false, "TYPE_BB8A must be a number")
        t:eq(caps{ no_color = true }.alpha_blit, false, "Color8A must be callable")
        t:eq(caps{ no_alphablit = true }.alpha_blit, false,
            "and the buffer must know how to compose")
    end)

    t:case("the alpha probe releases the buffer it made", function()
        local made, bb = blitbuffer{}
        local c = Compat.capabilities{
            input = false, ReaderView = false, Document = false, Blitbuffer = bb,
        }
        t:eq(c.alpha_blit, true, "the probe answered")
        t:eq(#made, 1, "with exactly one buffer")
        t:eq(made[1].freed, true, "and it was released again")
    end)

    t:case("a dependency that raises is a missing capability, never a crash", function()
        local exploding = setmetatable({}, {
            __index = function() error("no such module", 0) end,
        })
        local ok, c = pcall(Compat.capabilities, {
            input = exploding, ReaderView = exploding,
            Document = exploding, Blitbuffer = exploding,
        })
        t:eq(ok, true, "the probe does not raise")
        t:eq(c.stylus_api, false, "and answers false all round")
        t:eq(c.view_transform, false, "for the view transform")
        t:eq(c.native_dimensions, false, "for the native page size")
        t:eq(c.alpha_blit, false, "and for the alpha blit")
    end)

    t:case("fullSupport reads the one discriminator and nothing else", function()
        t:eq(Compat.fullSupport(caps()), true, "a complete runtime is supported")
        t:eq(Compat.fullSupport(caps{ input = false }), false,
            "no stylus callback pair means the old route (ADR-41)")
        t:eq(Compat.fullSupport(caps{ ReaderView = false }), true,
            "a missing transform does not decide the version")
        t:eq(Compat.fullSupport(caps{ Document = false }), true,
            "nor does a missing page size")
        t:eq(Compat.fullSupport(caps{ Blitbuffer = false }), true,
            "nor a missing alpha blit")
        t:eq(Compat.fullSupport(nil), false, "and no report at all is not support")
    end)

    t:case("assertCapabilities names the first non-gate capability missing", function()
        t:eq(Compat.assertCapabilities(caps()), true, "a complete runtime asserts")
        t:eq(Compat.assertCapabilities(caps{ input = false }), true,
            "the gate is never what this complains about")
        local ok, missing = Compat.assertCapabilities(caps{ ReaderView = false })
        t:eq(ok, nil, "a missing transform fails the assertion")
        t:eq(missing, "view_transform", "and is named")
        ok, missing = Compat.assertCapabilities(caps{ Document = false })
        t:eq(missing, "native_dimensions", "so is a missing page size")
        ok, missing = Compat.assertCapabilities(caps{ Blitbuffer = false })
        t:eq(missing, "alpha_blit", "and so is a missing alpha blit")
        ok, missing = Compat.assertCapabilities(nil)
        t:eq(ok, nil, "no report is not an assertion")
        t:eq(missing, "capabilities", "and says so")
    end)
end
