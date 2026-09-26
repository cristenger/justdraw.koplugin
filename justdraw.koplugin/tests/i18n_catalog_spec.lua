--[[--
The shipped catalogues, checked as a release gate (Task 12.2).

`tools/extract_strings --check` (CI) says the template is what GNU xgettext
makes of today's sources. This says the rest, on bare LuaJIT:

* the Spanish catalogue passes the plugin's own strict reader, with its plural
  rule enabled;
* it answers every message of the template, completely: no fuzzy, no empty,
  both plural forms, nothing the template no longer has;
* every translation keeps its placeholders (`%1`..`%9`, which msgfmt does not
  know about, and Lua/printf formats) and its line breaks;
* every simple literal `_("...")` in the sources is in the template -- a cheap
  cross-check that catches a template left stale, not a second extractor;
* at runtime, Spanish comes from the plugin's catalogue, C is source text, and
  KOReader's global gettext is left exactly as it was.
]]
return function(ctx)
    local t = ctx.t
    local I18n = require("ink_i18n")

    local plugin_dir = I18n.catalogueDir():match("^(.*)/l10n$")

    local function readFile(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local text = f:read("*a")
        f:close()
        return text
    end

    --- A test-side reader: msgid, plural, translations and flags per entry.
    --- Deliberately simple -- the strict reader under test is ink_i18n's.
    local function entries(text)
        local out, cur, target = {}, nil, nil
        local fuzzy = false
        local function unq(s)
            return (s:match('^"(.*)"$') or ""):gsub('\\(.)', { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" })
        end
        local function close()
            if cur then out[#out + 1] = cur end
            cur = nil
        end
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            if line:find("^#,") and line:find("fuzzy", 1, true) then fuzzy = true
            elseif line:find("^msgid ") then
                close()
                cur = { msgid = unq(line:match("^msgid (.*)$")), forms = {}, fuzzy = fuzzy }
                fuzzy = false
                target = "msgid"
            elseif line:find("^msgid_plural ") then
                cur.plural = unq(line:match("^msgid_plural (.*)$")); target = "plural"
            elseif line:find("^msgstr%[") then
                local i, rest = line:match("^msgstr%[(%d+)%] (.*)$")
                cur.forms[tonumber(i) + 1] = unq(rest); target = tonumber(i) + 1
            elseif line:find("^msgstr ") then
                cur.msgstr = unq(line:match("^msgstr (.*)$")); target = "msgstr"
            elseif line:find('^"') and cur then
                if type(target) == "number" then
                    cur.forms[target] = cur.forms[target] .. unq(line)
                else
                    cur[target] = cur[target] .. unq(line)
                end
            end
        end
        close()
        return out
    end

    local function tokens(s)
        local found = {}
        for tok in s:gmatch("%%%d") do found[#found + 1] = tok end
        for tok in s:gmatch("%%[-+ #0]*%d*%.?%d*[dsfqxXigc]") do found[#found + 1] = tok end
        local _, breaks = s:gsub("\n", "")
        found[#found + 1] = "breaks=" .. breaks
        table.sort(found)
        return table.concat(found, " ")
    end

    t:describe("i18n / shipped catalogues")

    local pot_text = readFile(plugin_dir .. "/l10n/justdraw.pot")
    local po_text = readFile(plugin_dir .. "/l10n/es.po")

    t:case("the template and the Spanish catalogue ship", function()
        t:check(pot_text ~= nil, "l10n/justdraw.pot exists")
        t:check(po_text ~= nil, "l10n/es.po exists")
    end)
    if not pot_text or not po_text then return end

    local pot, po = entries(pot_text), entries(po_text)
    local by_id = {}
    for _, e in ipairs(po) do by_id[e.msgid] = e end

    t:case("Spanish passes the plugin's strict reader, plurals enabled", function()
        local ok, err = I18n.validate(po_text, "es")
        t:check(ok == true, "valid: " .. tostring(err))
        t:check(po_text:find('"Plural%-Forms: nplurals=2; plural=%(n != 1%);\\n"') ~= nil,
            "the header declares Spanish's rule")
        t:eq(po[1].msgid, "", "the header first")
        t:eq(po[1].fuzzy, false, "and not fuzzy")
    end)

    t:case("every message is translated, completely, and nothing extra", function()
        local missing, empty, fuzzy, plural_gaps = {}, {}, {}, {}
        local pot_ids = {}
        for i = 2, #pot do
            local e = pot[i]
            pot_ids[e.msgid] = true
            local tr = by_id[e.msgid]
            if not tr then missing[#missing + 1] = e.msgid
            elseif tr.fuzzy then fuzzy[#fuzzy + 1] = e.msgid
            elseif e.plural then
                if tr.plural ~= e.plural or #tr.forms ~= 2 or tr.forms[1] == "" or tr.forms[2] == "" then
                    plural_gaps[#plural_gaps + 1] = e.msgid
                end
            elseif (tr.msgstr or "") == "" then empty[#empty + 1] = e.msgid end
        end
        local extra = {}
        for i = 2, #po do
            if not pot_ids[po[i].msgid] then extra[#extra + 1] = po[i].msgid end
        end
        t:eq(#pot - 1 > 400, true, "a real template (" .. (#pot - 1) .. " messages)")
        t:eq(#missing, 0, "missing: " .. table.concat(missing, " | "))
        t:eq(#empty, 0, "untranslated: " .. table.concat(empty, " | "))
        t:eq(#fuzzy, 0, "fuzzy: " .. table.concat(fuzzy, " | "))
        t:eq(#plural_gaps, 0, "incomplete plurals: " .. table.concat(plural_gaps, " | "))
        t:eq(#extra, 0, "not in the template: " .. table.concat(extra, " | "))
    end)

    t:case("placeholders, formats and line breaks survive translation", function()
        local bad = {}
        for i = 2, #po do
            local e = po[i]
            if e.plural then
                -- Each form keeps its own source's placeholders.
                if tokens(e.forms[2] or "") ~= tokens(e.plural) then bad[#bad + 1] = e.plural end
                if tokens(e.forms[1] or "") ~= tokens(e.msgid) then bad[#bad + 1] = e.msgid end
            elseif e.msgstr and tokens(e.msgstr) ~= tokens(e.msgid) then
                bad[#bad + 1] = e.msgid
            end
        end
        t:eq(#bad, 0, "mismatched: " .. table.concat(bad, " | "))
    end)

    t:case("every simple literal message in the sources is in the template", function()
        local pot_ids = {}
        for i = 2, #pot do pot_ids[pot[i].msgid] = true end
        local lister = io.popen('ls "' .. plugin_dir .. '"/*.lua')
        local missing = {}
        for path in lister:lines() do
            local name = path:match("([^/]+)$")
            if name ~= "_meta.lua" and name ~= "ink_i18n.lua" then
                local src = readFile(path)
                for literal in src:gmatch('[^%w_%.]_%("([^"\\\n]*)"%)') do
                    if not pot_ids[literal] then missing[#missing + 1] = name .. ": " .. literal end
                end
            end
        end
        lister:close()
        t:eq(#missing, 0, "not extracted (run tools/extract_strings): " .. table.concat(missing, " | "))
    end)

    t:describe("i18n / at runtime")

    t:case("Spanish from the plugin's catalogue, C as source, KOReader's gettext untouched", function()
        local gettext = require("gettext")
        local before = {}
        for k, v in pairs(gettext) do before[k] = v end
        local lang = gettext.current_lang
        I18n.configure{}
        local ok, err = pcall(function()
            gettext.current_lang = "es"
            I18n.invalidate()
            t:eq(I18n("Notebooks"), by_id["Notebooks"].msgstr, "a Spanish label")
            local pages = by_id["1 page"]
            t:eq(I18n.ngettext("1 page", "%1 pages", 1), pages.forms[1], "singular")
            t:eq(I18n.ngettext("1 page", "%1 pages", 2), pages.forms[2], "plural for 2")
            t:eq(I18n.ngettext("1 page", "%1 pages", 0), pages.forms[2], "plural for 0")
            gettext.current_lang = "es_ES"
            I18n.invalidate()
            t:eq(I18n("Notebooks"), by_id["Notebooks"].msgstr, "a region falls back to the base")
            gettext.current_lang = "C"
            I18n.invalidate()
            t:eq(I18n("Notebooks"), "Notebooks", "C is source text")
        end)
        gettext.current_lang = lang
        I18n.invalidate()
        t:check(ok, "ran: " .. tostring(err))
        local changed = {}
        for k, v in pairs(gettext) do if before[k] ~= v then changed[#changed + 1] = tostring(k) end end
        for k in pairs(before) do if gettext[k] == nil then changed[#changed + 1] = tostring(k) end end
        t:eq(#changed, 0, "the global gettext is as it was: " .. table.concat(changed, ","))
    end)
end
