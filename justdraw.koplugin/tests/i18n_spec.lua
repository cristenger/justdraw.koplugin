--[[--
The plugin's own translation catalogue (ink_i18n).

What these cases defend: a PO reader that refuses rather than guesses, a
lookup that falls back per message (region file, base file, KOReader, source),
plural forms only where an explicit rule exists, locale strings that can
never become paths outside l10n/, and -- most of all -- KOReader's global
gettext left exactly as it was found.
]]
return function(ctx)
    local t = ctx.t
    local env = ctx.env
    local I18n = require("ink_i18n")
    local fixture_dir = ctx.tests_dir .. "/fixtures/i18n"
    local DIR = "/cat"

    local HEADER = table.concat({
        'msgid ""',
        'msgstr ""',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"',
        "",
        "",
    }, "\n")

    local function po(...)
        return HEADER .. table.concat({ ... }, "\n") .. "\n"
    end

    --- A stand-in for KOReader's gettext that marks what it answers, so a
    --- fallback to it is told apart from a fallback to source text.
    local function globalGettext(lang)
        return setmetatable({
            current_lang = lang,
            ngettext = function(s, p, n) return "KO:" .. ((n == 1) and s or p) end,
        }, { __call = function(_, msgid) return "KO:" .. msgid end })
    end

    --- In-memory catalogue files, with a log of every path asked for.
    local function memory(files)
        local log = {}
        local read = function(path)
            log[#log + 1] = path
            return files[path]
        end
        return read, log
    end

    local function use(lang, files)
        local g = globalGettext(lang)
        local read, log = memory(files or {})
        I18n.configure({ dir = DIR, read = read, gettext = g })
        return g, log
    end

    local function validateErr(text, lang)
        local ok, err = I18n.validate(text, lang)
        return ok, err or ""
    end

    t:describe("ink_i18n / lookup and fallback")

    t:case("the module is callable and exposes ngettext", function()
        use("C")
        t:eq(I18n("Save"), "Save", "_() via __call")
        t:eq(type(I18n.ngettext), "function", "ngettext")
        t:eq(type(I18n.invalidate), "function", "invalidate")
        t:eq(type(I18n.validate), "function", "validate")
    end)

    t:case("C, nil and empty mean source text, without reading anything", function()
        for _, lang in ipairs({ "C", "", false }) do
            local _, log = use(lang ~= false and lang or nil)
            t:eq(I18n("Save"), "Save", "singular is source for " .. tostring(lang))
            t:eq(I18n.ngettext("%1 page", "%1 pages", 1), "%1 page", "n=1 source")
            t:eq(I18n.ngettext("%1 page", "%1 pages", 0), "%1 pages", "n=0 source")
            t:eq(I18n.ngettext("%1 page", "%1 pages", 2), "%1 pages", "n=2 source")
            t:eq(#log, 0, "no catalogue read for " .. tostring(lang))
        end
    end)

    t:case("the fixture catalogue on disk translates, per message", function()
        I18n.configure({ dir = fixture_dir, gettext = globalGettext("es") })
        t:eq(I18n("Save"), "Guardar", "plain entry")
        t:eq(I18n("Delete this note?"), "¿Borrar esta nota?", "multi-line strings concatenate")
        t:eq(I18n('Line one\nTab\there "quoted" back\\slash'),
            "Línea uno\nTab\taquí «citado» barra\\invertida", "escapes decode")
        t:eq(I18n("Untranslated"), "KO:Untranslated", "empty msgstr falls back to KOReader")
        t:eq(I18n("Not in the catalogue"), "KO:Not in the catalogue", "missing key -> KOReader")
    end)

    t:case("fuzzy and obsolete entries are ignored", function()
        I18n.configure({ dir = fixture_dir, gettext = globalGettext("es") })
        t:eq(I18n("Pen"), "KO:Pen", "#, fuzzy")
        t:eq(I18n("Eraser"), "KO:Eraser", "fuzzy among other flags")
        t:eq(I18n("Old label"), "KO:Old label", "#~ obsolete")
        t:eq(I18n("Old fuzzy label"), "KO:Old fuzzy label", "obsolete fuzzy entry")
        t:eq(I18n("Brush"), "Pincel", "the fuzzy flag of an obsolete entry does not leak")
        local text = po("#, fuzzy", "", 'msgid "Save"', 'msgstr "Guardar"')
        use("es", { [DIR .. "/es.po"] = text })
        t:eq(I18n("Save"), "Guardar", "a flag separated by a blank line belongs to no entry")
    end)

    t:case("Spanish plurals: 0 and 2 plural, 1 singular", function()
        I18n.configure({ dir = fixture_dir, gettext = globalGettext("es") })
        t:eq(I18n.ngettext("%1 page", "%1 pages", 0), "%1 páginas", "n=0")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 1), "%1 página", "n=1")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 2), "%1 páginas", "n=2")
    end)

    t:case("a missing plural form falls back for that form only", function()
        I18n.configure({ dir = fixture_dir, gettext = globalGettext("es") })
        t:eq(I18n.ngettext("%1 note", "%1 notes", 1), "%1 nota", "translated form used")
        t:eq(I18n.ngettext("%1 note", "%1 notes", 2), "KO:%1 notes", "empty msgstr[1] -> KOReader")
        t:eq(I18n.ngettext("%1 page", "%1 other pages", 2), "KO:%1 other pages",
            "a different msgid_plural is a different message")
        t:eq(I18n.ngettext("Save", "Saves", 1), "KO:Save", "a singular entry never answers ngettext")
    end)

    t:case("without a KOReader gettext, the source text is the last word", function()
        I18n.configure({ dir = fixture_dir, gettext = { current_lang = "es" } })
        t:eq(I18n("Save"), "Guardar", "catalogue still used")
        t:eq(I18n("Nowhere"), "Nowhere", "no global -> source")
        t:eq(I18n.ngettext("a", "b", 2), "b", "no global ngettext -> source rule")
    end)

    t:case("region files fall back to the base file per key", function()
        local _, log = use("es_ES", {
            [DIR .. "/es_ES.po"] = po('msgid "Save"', 'msgstr "Guardar (ES)"'),
            [DIR .. "/es.po"] = po(
                'msgid "Save"', 'msgstr "Guardar"', "",
                'msgid "Cancel"', 'msgstr "Cancelar"', "",
                'msgid "%1 page"', 'msgid_plural "%1 pages"',
                'msgstr[0] "%1 página"', 'msgstr[1] "%1 páginas"'),
        })
        t:eq(I18n("Save"), "Guardar (ES)", "region key wins")
        t:eq(I18n("Cancel"), "Cancelar", "key the region lacks comes from es.po")
        t:eq(I18n("Other"), "KO:Other", "key neither has comes from KOReader")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 3), "%1 páginas", "plural from the base file")
        t:eq(#log, 2, "two files consulted")
        t:eq(log[1], DIR .. "/es_ES.po", "region first")
        t:eq(log[2], DIR .. "/es.po", "then base")
    end)

    t:case("a region without its own file uses the base file", function()
        use("es_MX", { [DIR .. "/es.po"] = po('msgid "Save"', 'msgstr "Guardar"') })
        t:eq(I18n("Save"), "Guardar", "es_MX -> es.po")
    end)

    t:case("a language without a plural rule never uses the catalogue's plurals", function()
        local fr = table.concat({
            'msgid ""', 'msgstr ""',
            '"Content-Type: text/plain; charset=UTF-8\\n"',
            '"Plural-Forms: nplurals=2; plural=(n > 1);\\n"', "",
            'msgid "Save"', 'msgstr "Enregistrer"', "",
            'msgid "%1 page"', 'msgid_plural "%1 pages"',
            'msgstr[0] "%1 page FR"', 'msgstr[1] "%1 pages FR"', "",
        }, "\n")
        local before = #env.logs.warn
        use("fr", { [DIR .. "/fr.po"] = fr })
        t:eq(I18n("Save"), "Enregistrer", "singular entries still apply")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 1), "KO:%1 page", "n=1 -> KOReader")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 0), "KO:%1 pages", "n=0 -> KOReader, not English")
        t:eq(#env.logs.warn, before, "no rule is expected, not a warning")
    end)

    t:case("a Spanish header declaring another rule disables plurals, with a warning", function()
        local text = table.concat({
            'msgid ""', 'msgstr ""',
            '"Plural-Forms: nplurals=2; plural=(n > 1);\\n"', "",
            'msgid "Save"', 'msgstr "Guardar"', "",
            'msgid "%1 page"', 'msgid_plural "%1 pages"',
            'msgstr[0] "%1 página"', 'msgstr[1] "%1 páginas"', "",
        }, "\n")
        local before = #env.logs.warn
        use("es", { [DIR .. "/es.po"] = text })
        t:eq(I18n("Save"), "Guardar", "singular kept")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 2), "KO:%1 pages", "plural not guessed")
        t:eq(#env.logs.warn, before + 1, "one warning")
    end)

    t:describe("ink_i18n / invalid catalogues at runtime")

    t:case("a duplicate msgid makes the whole file fall back, with one warning", function()
        local before = #env.logs.warn
        use("es", { [DIR .. "/es.po"] = po(
            'msgid "Save"', 'msgstr "Guardar"', "",
            'msgid "Cancel"', 'msgstr "Cancelar"', "",
            'msgid "Save"', 'msgstr "Salvar"') })
        t:eq(I18n("Save"), "KO:Save", "duplicate key falls back")
        t:eq(I18n("Cancel"), "KO:Cancel", "and so does every other key in the file")
        t:eq(I18n.ngettext("a", "b", 2), "KO:b", "plurals too")
        I18n.invalidate()
        t:eq(I18n("Save"), "KO:Save", "still falls back after a reload")
        t:eq(#env.logs.warn, before + 1, "exactly one warning")
        local w = env.logs.warn[#env.logs.warn]
        t:check(tostring(w[2]):find("/cat/es.po", 1, true) ~= nil, "warning names the file")
        t:check(tostring(w[3]):find("duplicate", 1, true) ~= nil, "and the reason")
    end)

    t:case("an invalid region file does not hide a valid base file", function()
        local before = #env.logs.warn
        use("es_ES", {
            [DIR .. "/es_ES.po"] = po('msgid "Save"', 'msgstr "bad \\q escape"'),
            [DIR .. "/es.po"] = po('msgid "Save"', 'msgstr "Guardar"'),
        })
        t:eq(I18n("Save"), "Guardar", "es.po answers")
        t:eq(#env.logs.warn, before + 1, "one warning for es_ES.po")
    end)

    t:case("truncated, non-UTF-8 and unreadable files never raise", function()
        local cases = {
            po('msgid "Save"', 'msgstr "Guar'),
            HEADER .. 'msgid "Save"\n',
            po('msgid "Save"', 'msgstr "Guardar\255"'),
        }
        for i, text in ipairs(cases) do
            use("es", { [DIR .. "/es.po"] = text })
            local ok, res = pcall(I18n, "Save")
            t:check(ok, "case " .. i .. " did not raise")
            t:eq(res, "KO:Save", "case " .. i .. " falls back")
        end
        local g = globalGettext("es")
        I18n.configure({ dir = DIR, gettext = g, read = function() error("disk on fire") end })
        local ok, res = pcall(I18n, "Save")
        t:check(ok, "a reader that raises is contained")
        t:eq(res, "KO:Save", "and falls back")
    end)

    t:case("warnings are bounded across many broken files", function()
        local before = #env.logs.warn
        local files = {}
        local g = globalGettext("es")
        I18n.configure({ dir = DIR, gettext = g, read = function(path)
            files[#files + 1] = path
            return "garbage"
        end })
        for _, lang in ipairs({ "es", "es_ES", "es_MX", "es_AR", "es_CO", "es_CL", "es_PE" }) do
            g.current_lang = lang
            I18n("Save")
        end
        t:check(#files >= 7, "every language was tried")
        t:check(#env.logs.warn - before <= 4, "no more than the warning budget")
    end)

    t:describe("ink_i18n / locale strings never become paths")

    t:case("malicious or malformed locales read nothing", function()
        for _, lang in ipairs({ "../../etc", "es/..", "es.po", "../es", "es_ES/../../x",
            "es\\..", "/es", "es_ES.UTF-8", "sr@latin", "ES", "es_es", "e", "esp", "es\0",
            "es_", "es_E" }) do
            local _, log = use(lang, { [DIR .. "/es.po"] = po('msgid "Save"', 'msgstr "Guardar"') })
            t:eq(I18n.normalizeLang(lang), nil, "rejected: " .. lang)
            t:eq(I18n("Save"), "KO:Save", "falls back for " .. lang)
            t:eq(I18n.ngettext("a", "b", 2), "KO:b", "plural falls back for " .. lang)
            t:eq(#log, 0, "nothing read for " .. lang)
        end
    end)

    t:case("valid locales only ever read <dir>/<code>.po", function()
        for _, lang in ipairs({ "es", "es_ES", "pt_BR", "de" }) do
            local _, log = use(lang)
            I18n("Save")
            for _, path in ipairs(log) do
                local code = path:match("^/cat/([a-z][a-z]_?[A-Z]?[A-Z]?)%.po$")
                t:check(code ~= nil, "path inside l10n: " .. path)
            end
        end
        t:eq(I18n.normalizeLang("es_ES"), "es_ES", "region code kept")
        t:eq(I18n.normalizeLang("C"), "C", "C")
    end)

    t:case("the default catalogue directory is l10n next to the module", function()
        I18n.configure()
        local dir = I18n.catalogueDir()
        t:eq(dir, ctx.plugin_dir .. "/l10n", "resolved from the module's own path")
    end)

    t:describe("ink_i18n / language change")

    t:case("a language change rebuilds; invalidate re-reads", function()
        local files = { [DIR .. "/es.po"] = po('msgid "Save"', 'msgstr "Guardar"') }
        local g, log = use("es", files)
        t:eq(I18n("Save"), "Guardar", "Spanish")
        t:eq(I18n("Save"), "Guardar", "cached")
        t:eq(#log, 1, "read once")
        g.current_lang = "C"
        t:eq(I18n("Save"), "Save", "C after the change")
        g.current_lang = "es"
        t:eq(I18n("Save"), "Guardar", "Spanish again")
        t:eq(#log, 2, "re-read on the language change")
        files[DIR .. "/es.po"] = po('msgid "Save"', 'msgstr "Guardar cambios"')
        t:eq(I18n("Save"), "Guardar", "same language: cache kept")
        I18n.invalidate()
        t:eq(I18n("Save"), "Guardar cambios", "invalidate picks up the new file")
        t:eq(#log, 3, "one more read")
    end)

    t:describe("ink_i18n / KOReader's gettext is left untouched")

    t:case("loading the plugin catalogue does not mutate the global gettext", function()
        local gettext = require("gettext")
        local function snapshot(v, seen)
            seen = seen or {}
            if type(v) ~= "table" then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, x in pairs(v) do copy[k] = snapshot(x, seen) end
            local mt = getmetatable(v)
            if mt then copy["<mt>"] = snapshot(mt, seen) end
            return copy
        end
        local function same(a, b, path, seen)
            seen = seen or {}
            if type(a) ~= "table" or type(b) ~= "table" then
                return a == b, path
            end
            if seen[a] then return true end
            seen[a] = true
            for k, x in pairs(a) do
                local ok, where = same(x, b[k], path .. "." .. tostring(k), seen)
                if not ok then return false, where end
            end
            for k in pairs(b) do
                if a[k] == nil then return false, path .. "." .. tostring(k) end
            end
            return true
        end

        local saved_lang = gettext.current_lang
        gettext.current_lang = "es"
        local before = snapshot(gettext)
        local loaded_before = package.loaded["gettext"]

        I18n.configure({ dir = fixture_dir }) -- the real (fake) global module
        t:eq(I18n("Save"), "Guardar", "plugin catalogue in use")
        t:eq(I18n.ngettext("%1 page", "%1 pages", 2), "%1 páginas", "plural in use")
        t:eq(I18n("Not here"), "Not here", "global consulted for a missing key")
        t:eq(gettext("Save"), "Save", "KOReader's own lookup does not see the plugin's msgids")
        t:eq(gettext.ngettext("%1 page", "%1 pages", 2), "%1 pages", "nor its plurals")

        local ok, where = same(before, snapshot(gettext), "gettext")
        t:check(ok, "global gettext unchanged (" .. tostring(where) .. ")")
        t:eq(package.loaded["gettext"], loaded_before, "same module instance")
        t:eq(gettext.current_lang, "es", "language not touched")
        gettext.current_lang = saved_lang
        I18n.configure()
    end)

    t:describe("ink_i18n / validate")

    t:case("the fixture validates, for Spanish too", function()
        local f = assert(io.open(fixture_dir .. "/es.po", "rb"))
        local text = f:read("*a")
        f:close()
        t:eq(I18n.validate(text), true, "valid")
        t:eq(I18n.validate(text, "es"), true, "valid for es")
        t:eq(I18n.validate(text, "es_ES"), true, "valid for es_ES")
        local ok, err = validateErr(text, "fr")
        t:eq(ok, nil, "plural entries without a rule for fr")
        t:check(err:find("no plural rule", 1, true) ~= nil, "reason: " .. err)
    end)

    t:case("a BOM at the start is accepted, and CRLF line ends", function()
        local text = "\239\187\191" .. po('msgid "Save"', 'msgstr "Guardar"')
        t:eq(I18n.validate(text), true, "BOM stripped")
        t:eq(I18n.validate((po('msgid "Save"', 'msgstr "Guardar"'):gsub("\n", "\r\n"))), true, "CRLF")
        use("es", { [DIR .. "/es.po"] = text })
        t:eq(I18n("Save"), "Guardar", "BOM file used at runtime")
    end)

    local function refused(label, text, needle, line, lang)
        t:case("refused: " .. label, function()
            local ok, err = validateErr(text, lang)
            t:eq(ok, nil, label .. " is invalid")
            t:check(err:find(needle, 1, true) ~= nil, label .. " reason: " .. err)
            if line then
                t:check(err:find("^line " .. line .. ":") ~= nil, label .. " line: " .. err)
            end
        end)
    end

    -- HEADER is five lines; the first body line is line 6.
    refused("unknown escape", po('msgid "Save"', 'msgstr "a\\x"'), "unsupported escape \\x", 7)
    refused("octal escape", po('msgid "Save"', 'msgstr "a\\101"'), "unsupported escape", 7)
    refused("msgctxt", po('msgctxt "menu"', 'msgid "Save"', 'msgstr "Guardar"'), "msgctxt", 6)
    refused("duplicate msgid",
        po('msgid "Save"', 'msgstr "Guardar"', "", 'msgid "Save"', 'msgstr "Salvar"'),
        "duplicate msgid (first at line 6)", 9)
    refused("duplicate across singular and plural",
        po('msgid "Save"', 'msgstr "Guardar"', "",
            'msgid "Save"', 'msgid_plural "Saves"', 'msgstr[0] "a"', 'msgstr[1] "b"'),
        "duplicate msgid", 9)
    refused("unterminated string", po('msgid "Save"', 'msgstr "Guar'), "unterminated", 7)
    refused("missing final newline", HEADER .. 'msgid "Save"\nmsgstr "Guardar"',
        "no newline", 7)
    refused("msgid without msgstr at end of file", HEADER .. 'msgid "Save"\n',
        "has no msgstr", 6)
    refused("msgid without msgstr before the next", po('msgid "Save"', 'msgid "Cancel"',
        'msgstr "x"'), "line 6 has no msgstr", 7)
    refused("invalid byte", po('msgid "Save"', 'msgstr "\255"'), "invalid UTF-8", 7)
    refused("overlong encoding", po('msgid "Save"', 'msgstr "\192\175"'), "invalid UTF-8", 7)
    refused("surrogate", po('msgid "Save"', 'msgstr "\237\160\128"'), "invalid UTF-8", 7)
    refused("cut multibyte sequence", po('msgid "Save"', 'msgstr "\195"'), "invalid UTF-8", 7)
    refused("past U+10FFFF", po('msgid "Save"', 'msgstr "\244\144\128\128"'), "invalid UTF-8", 7)
    refused("unsupported line", po('msgid "Save"', 'msgstr "x"', "", "domain \"x\""),
        "unsupported syntax", 9)
    refused("keyword without space", po('msgid"Save"', 'msgstr "x"'), "unsupported syntax", 6)
    refused("text after a string", po('msgid "Save" x', 'msgstr "x"'), "after the closing quote", 6)
    refused("comment inside an entry", po('msgid "Save"', "# note", 'msgstr "x"'),
        "comment inside an entry", 7)
    refused("no header", 'msgid "Save"\nmsgstr "Guardar"\n', "must be the header", 1)
    refused("empty file", "", "empty", 1)
    refused("fuzzy header", '#, fuzzy\nmsgid ""\nmsgstr "Plural-Forms: nplurals=2; plural=n!=1;\\n"\n',
        "fuzzy", 2)
    refused("non-UTF-8 charset", 'msgid ""\nmsgstr "Content-Type: text/plain; charset=ISO-8859-1\\n"\n',
        "UTF-8 only", 1)
    refused("plural entry with too few forms",
        po('msgid "a"', 'msgid_plural "b"', 'msgstr[0] "x"'), "has 1 forms, header declares 2", 6)
    refused("plural forms out of order",
        po('msgid "a"', 'msgid_plural "b"', 'msgstr[1] "x"', 'msgstr[0] "y"'), "out of order", 8)
    refused("plural entry with a plain msgstr",
        po('msgid "a"', 'msgid_plural "b"', 'msgstr "x"'), "takes msgstr[N]", 8)
    refused("plural without Plural-Forms",
        'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8\\n"\n\nmsgid "a"\nmsgid_plural "b"\nmsgstr[0] "x"\nmsgstr[1] "y"\n',
        "without a Plural-Forms header", 4)
    refused("Spanish header with another rule",
        'msgid ""\nmsgstr "Plural-Forms: nplurals=3; plural=(n%10==1 ? 0 : n ? 1 : 2);\\n"\n',
        "does not match the rule for es", nil, "es")
    refused("malicious language for validate", po('msgid "a"', 'msgstr "b"'),
        "invalid language code", nil, "../es")

    t:case("validation is strict about continuation lines", function()
        local ok = I18n.validate(po('"orphan"'))
        t:eq(ok, nil, "a string with no keyword before it")
        t:eq(I18n.validate(po('msgid "a"', '   "b"', 'msgstr "c"', '"d"')), true,
            "indented continuations of msgid and msgstr")
    end)

    I18n.configure()
end
