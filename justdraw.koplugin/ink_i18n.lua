--[[--
The plugin's own translation catalogue, kept apart from KOReader's.

KOReader's GetText (frontend/gettext.lua) has one global domain: a single set
of translation tables that `GetText.changeLang` replaces wholesale. A plugin
that pushed its messages into those tables would leak them into every other
plugin, and would lose them -- silently, back to English -- the next time the
user changed language. So the plugin reads its own `l10n/<lang>.po` into
tables private to this module, and only *reads* KOReader's state: the
effective language (`current_lang`) and, per message, KOReader's own
translation as the fallback.

    local _ = require("ink_i18n")
    _("Save")                           -- plugin catalogue, then KOReader, then source
    _.ngettext("%1 page", "%1 pages", n)

Lookup is per message: a region file (`es_ES.po`) answers the keys it has,
the base file (`es.po`) the rest, KOReader's gettext what neither has, and the
source text is the last word. `C`, nil and "" mean source text.

Why the PO reader is so narrow: a catalogue is data that ships inside the
plugin, and a lenient reader turns a typo into a wrong button label that no
test sees. Everything outside the subset below is refused with a line number,
never reinterpreted. At runtime a refused file is skipped as a whole -- the
plugin falls back to KOReader's gettext and logs one warning -- because a
translation problem must never stop the plugin from loading. `validate` gives
packaging checks the same verdict, strictly.

Supported (GNU gettext manual, "PO File Entries" and "Entries with Plural
Forms"): UTF-8 only, an optional BOM, `#` comments, `#, fuzzy` entries
(skipped), obsolete `#~` lines (skipped), a mandatory first header entry
(msgid "") read for Plural-Forms and charset, multi-line strings, the escapes
\n \t \" \\, `msgid_plural` with `msgstr[0..]`. Empty msgstr means untranslated.
Refused: `msgctxt`, any other escape or keyword, duplicate msgids, a fuzzy
header, invalid UTF-8, files that end mid-entry or mid-line.

Plurals are never evaluated from the catalogue's `plural=` expression (that
would mean compiling file content). Each language needs an explicit rule here,
and the catalogue's header must declare that same rule, or the file's plural
entries stay disabled. Only Spanish has one; for any other language
`ngettext` goes straight to KOReader. The English rule is deliberately not a
default: applied to, say, Polish or Arabic it would pick wrong forms.

Language changes are picked up lazily: the cache is keyed on KOReader's
`current_lang` and rebuilt when that differs; `invalidate()` forces a re-read.
Widgets already on screen keep their labels -- only rebuilt ones change.
]]

local I18n = {}

-- Budgets. A catalogue larger than this is not a catalogue; warnings are
-- capped so a broken install cannot flood the log.
local MAX_BYTES = 1024 * 1024
local MAX_WARNINGS = 4
local MAX_NPLURALS = 6

--[[ Explicit plural rules, keyed by base language. `expr` is the catalogue
header's `plural=` expression with whitespace, a trailing ';' and outer
parentheses removed; a header that declares anything else keeps the file's
plural entries disabled. ]]
local RULES = {
    es = {
        nplurals = 2,
        expr = "n!=1",
        index = function(n) return (n ~= 1) and 1 or 0 end,
    },
}

-- ---------------------------------------------------------------- defaults

local function defaultDir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = src:match("^(.*)[/\\][^/\\]*$") or "."
    return dir .. "/l10n"
end

--- Read a catalogue file. nil without a reason means "no such file" (normal:
--- most languages have none); nil with a reason is worth a warning.
local function defaultRead(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    if not size or size > MAX_BYTES then
        f:close()
        return nil, "file too large"
    end
    f:seek("set", 0)
    local text = f:read("*a")
    f:close()
    if not text then return nil, "unreadable" end
    return text
end

local config = {}
local state -- the cache: nil, or the catalogues for one current_lang value
local warned = {}
local warn_count = 0

local function globalGettext()
    if config.gettext then return config.gettext end
    local ok, gt = pcall(require, "gettext")
    if ok then return gt end
    return nil
end

local function warn(path, reason)
    if warned[path] or warn_count >= MAX_WARNINGS then return end
    warned[path] = true
    warn_count = warn_count + 1
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.warn then
        logger.warn("JustDraw: ignoring translation catalogue", path,
            tostring(reason):sub(1, 200))
    end
end

-- -------------------------------------------------------------- languages

--[[--
Map KOReader's language string to a catalogue code, or "C", or nil.

Only `ll` and `ll_CC` pass. Anything else -- dots, slashes, `..`, encodings,
modifiers, upper-case languages -- is refused rather than cleaned up, because
the result becomes part of a file name and a cleaned-up locale string is
still attacker-shaped.
]]
function I18n.normalizeLang(lang)
    if lang == nil or lang == "" or lang == "C" then return "C" end
    if type(lang) ~= "string" then return nil end
    if lang:match("^[a-z][a-z]$") or lang:match("^[a-z][a-z]_[A-Z][A-Z]$") then
        return lang
    end
    return nil
end

--- The catalogue files a code consults, most specific first.
local function candidates(code)
    local list = { code }
    if #code == 5 then list[2] = code:sub(1, 2) end
    return list
end

-- ------------------------------------------------------------- PO reader

local ESCAPES = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" }

local function fail(line, msg)
    error({ po_line = line, po_msg = msg }, 0)
end

--- True when a line is well-formed UTF-8: no overlongs, surrogates, or code
--- points past U+10FFFF.
local function utf8Ok(s)
    local i, n = 1, #s
    while true do
        i = s:find("[\128-\255]", i)
        if not i then return true end
        local c = s:byte(i)
        local need
        if c >= 0xC2 and c <= 0xDF then need = 1
        elseif c >= 0xE0 and c <= 0xEF then need = 2
        elseif c >= 0xF0 and c <= 0xF4 then need = 3
        else return false end
        if i + need > n then return false end
        local lo, hi = 0x80, 0xBF
        if c == 0xE0 then lo = 0xA0
        elseif c == 0xED then hi = 0x9F
        elseif c == 0xF0 then lo = 0x90
        elseif c == 0xF4 then hi = 0x8F end
        local c1 = s:byte(i + 1)
        if c1 < lo or c1 > hi then return false end
        for k = 2, need do
            local ck = s:byte(i + k)
            if ck < 0x80 or ck > 0xBF then return false end
        end
        i = i + need + 1
    end
end

--- Decode one quoted PO string occupying the rest of a line.
local function parseString(s, line)
    if s:sub(1, 1) ~= '"' then fail(line, "expected a quoted string") end
    local out, i, n = {}, 2, #s
    while true do
        local j = s:find('["\\]', i)
        if not j then fail(line, "unterminated string (truncated file?)") end
        out[#out + 1] = s:sub(i, j - 1)
        if s:sub(j, j) == '"' then
            if not s:sub(j + 1):find("^%s*$") then
                fail(line, "unexpected text after the closing quote")
            end
            return table.concat(out)
        end
        local e = s:sub(j + 1, j + 1)
        if j + 1 > n then fail(line, "unterminated string (truncated file?)") end
        local v = ESCAPES[e]
        if not v then fail(line, "unsupported escape \\" .. e) end
        out[#out + 1] = v
        i = j + 2
    end
end

--- `plural=` expression reduced to a comparable form, e.g. "(n != 1);" -> "n!=1".
local function canonicalExpr(expr)
    local s = expr:gsub("%s+", ""):gsub(";+$", "")
    while s:sub(1, 1) == "(" and s:sub(-1) == ")" do
        local inner, depth, ok = s:sub(2, -2), 0, true
        for k = 1, #inner do
            local ch = inner:sub(k, k)
            if ch == "(" then depth = depth + 1
            elseif ch == ")" then
                depth = depth - 1
                if depth < 0 then ok = false break end
            end
        end
        if not ok or depth ~= 0 then break end
        s = inner
    end
    return s
end

local function parseHeader(cat, msgstr, line)
    for field in msgstr:gmatch("[^\n]+") do
        local key, value = field:match("^([%w%-]+):%s*(.-)%s*$")
        if key == "Content-Type" then
            local charset = value:match("charset=([%w%-_]+)")
            if charset and charset:lower() ~= "utf-8" then
                fail(line, "charset " .. charset .. " is not supported (UTF-8 only)")
            end
        elseif key == "Plural-Forms" then
            local np, expr = value:match("^nplurals%s*=%s*(%d+)%s*;%s*plural%s*=%s*(.-)%s*$")
            np = tonumber(np)
            if not np or np < 1 or np > MAX_NPLURALS or expr == "" then
                fail(line, "malformed Plural-Forms header")
            end
            cat.nplurals = np
            cat.plural_expr = canonicalExpr(expr)
        end
    end
end

--[[--
Parse PO text into { singular = {msgid = msgstr}, plural = {msgid = {plural
= msgid_plural, forms = {...}}}, nplurals, plural_expr, has_plurals }.
Raises a {po_line, po_msg} table on the first violation.
]]
local function parse(text)
    if type(text) ~= "string" then fail(0, "catalogue is not text") end
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    if text == "" then fail(1, "empty catalogue") end
    if text:sub(-1) ~= "\n" then
        local _, count = text:gsub("\n", "")
        fail(count + 1, "last line has no newline (truncated file?)")
    end

    local cat = { singular = {}, plural = {}, has_plurals = false }
    local seen = {}          -- msgid -> line of its first entry
    local entries = 0
    local cur                -- entry being read
    local pending_fuzzy = false

    local function complete(e)
        return e.msgstr ~= nil or #e.forms > 0
    end

    local function finish(e)
        if seen[e.msgid] then
            fail(e.line, "duplicate msgid (first at line " .. seen[e.msgid] .. ")")
        end
        seen[e.msgid] = e.line
        entries = entries + 1
        if e.msgid == "" then
            if entries ~= 1 then fail(e.line, "the header entry must come first") end
            if e.plural then fail(e.line, "the header entry cannot be plural") end
            if e.fuzzy then fail(e.line, "the header entry is marked fuzzy") end
            parseHeader(cat, e.msgstr, e.line)
            return
        end
        if entries == 1 then fail(e.line, "the first entry must be the header (msgid \"\")") end
        if e.plural then
            if not cat.nplurals then
                fail(e.line, "plural entry without a Plural-Forms header")
            end
            if #e.forms ~= cat.nplurals then
                fail(e.line, string.format("plural entry has %d forms, header declares %d",
                    #e.forms, cat.nplurals))
            end
            cat.has_plurals = true
            if e.fuzzy then return end
            local forms, any = {}, false
            for k = 1, #e.forms do
                if e.forms[k] ~= "" then forms[k] = e.forms[k]; any = true
                else forms[k] = false end
            end
            if any then cat.plural[e.msgid] = { plural = e.plural, forms = forms } end
        elseif not e.fuzzy and e.msgstr ~= "" then
            cat.singular[e.msgid] = e.msgstr
        end
    end

    local function closeEntry()
        if cur then
            finish(cur)
            cur = nil
        end
    end

    local lineno = 0
    for raw in text:gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        local line = raw:gsub("\r$", "")
        if not utf8Ok(line) then fail(lineno, "invalid UTF-8") end

        if line:find("^%s*$") then
            if cur and not complete(cur) then
                fail(lineno, "entry at line " .. cur.line .. " has no msgstr")
            end
            closeEntry()
            -- Flags belong to the entry they precede; a blank line ends that.
            pending_fuzzy = false
        elseif line:sub(1, 1) == "#" then
            if cur and not complete(cur) then
                fail(lineno, "comment inside an entry")
            end
            closeEntry()
            if line:sub(1, 2) == "#," then
                for flag in line:sub(3):gmatch("[^,]+") do
                    if flag:match("^%s*(.-)%s*$") == "fuzzy" then pending_fuzzy = true end
                end
            elseif line:sub(1, 2) == "#~" then
                -- An obsolete entry consumes the flags written above it
                -- (msgmerge keeps `#, fuzzy` on obsolete entries).
                pending_fuzzy = false
            end
            -- Every other comment is ignored.
        elseif line:find("^msgctxt[%s\"]") or line == "msgctxt" then
            fail(lineno, "msgctxt is not supported")
        elseif line:find("^msgid_plural%s") then
            if not cur or cur.plural or complete(cur) then
                fail(lineno, "msgid_plural must follow a msgid")
            end
            cur.plural = parseString(line:match("^msgid_plural%s+(.*)$"), lineno)
            cur.target = "plural"
        elseif line:find("^msgid%s") then
            if cur and not complete(cur) then
                fail(lineno, "entry at line " .. cur.line .. " has no msgstr")
            end
            closeEntry()
            cur = {
                line = lineno,
                fuzzy = pending_fuzzy,
                msgid = parseString(line:match("^msgid%s+(.*)$"), lineno),
                forms = {},
                target = "msgid",
            }
            pending_fuzzy = false
        elseif line:find("^msgstr%[") then
            local idx, rest = line:match("^msgstr%[(%d+)%]%s+(.*)$")
            idx = tonumber(idx)
            if not idx then fail(lineno, "malformed msgstr[N]") end
            if not cur or not cur.plural or cur.msgstr ~= nil then
                fail(lineno, "msgstr[N] outside a plural entry")
            end
            if idx ~= #cur.forms then
                fail(lineno, "msgstr[" .. idx .. "] out of order")
            end
            cur.forms[idx + 1] = parseString(rest, lineno)
            cur.target = idx + 1
        elseif line:find("^msgstr%s") then
            if cur and cur.plural then
                fail(lineno, "a plural entry takes msgstr[N], not msgstr")
            end
            if not cur or cur.msgstr ~= nil then
                fail(lineno, "msgstr without a matching msgid")
            end
            cur.msgstr = parseString(line:match("^msgstr%s+(.*)$"), lineno)
            cur.target = "msgstr"
        elseif line:find('^%s*"') then
            if not cur then fail(lineno, "string continuation outside an entry") end
            local s = parseString(line:match('^%s*(.*)$'), lineno)
            local target = cur.target
            if type(target) == "number" then
                cur.forms[target] = cur.forms[target] .. s
            else
                cur[target] = cur[target] .. s
            end
        else
            fail(lineno, "unsupported syntax")
        end
    end

    if cur and not complete(cur) then
        fail(lineno, "entry at line " .. cur.line .. " has no msgstr (truncated file?)")
    end
    closeEntry()
    if entries == 0 then fail(lineno, "no header entry") end
    return cat
end

local function protectedParse(text)
    local ok, res = pcall(parse, text)
    if ok then return res end
    if type(res) == "table" and res.po_msg then
        return nil, "line " .. tostring(res.po_line) .. ": " .. res.po_msg
    end
    return nil, tostring(res)
end

--- nil when the catalogue's plural entries may be used for `base`, else why not.
local function pluralMismatch(cat, base)
    local rule = RULES[base]
    if not rule then return "no plural rule for language " .. base end
    if not cat.nplurals then return "no Plural-Forms header" end
    if cat.nplurals ~= rule.nplurals or cat.plural_expr ~= rule.expr then
        return "Plural-Forms header does not match the rule for " .. base
    end
    return nil
end

--[[--
Strict check for packaging: true, or nil and "line N: reason".

With `lang`, also checks that the file's plural entries (if any) can be
enabled for that language: it must have an explicit rule and the header must
declare it.
]]
function I18n.validate(text, lang)
    local cat, err = protectedParse(text)
    if not cat then return nil, err end
    if lang ~= nil then
        local code = I18n.normalizeLang(lang)
        if not code or code == "C" then return nil, "invalid language code" end
        local base = code:sub(1, 2)
        if cat.has_plurals or (cat.nplurals and RULES[base]) then
            local why = pluralMismatch(cat, base)
            if why then return nil, why end
        end
    end
    return true
end

-- ---------------------------------------------------------------- runtime

local function loadCatalogue(path, base)
    local read = config.read or defaultRead
    local ok, text, read_err = pcall(read, path)
    if not ok then
        warn(path, text)
        return nil
    end
    if text == nil then
        if read_err then warn(path, read_err) end
        return nil
    end
    local cat, err = protectedParse(text)
    if not cat then
        warn(path, err)
        return nil
    end
    if cat.has_plurals then
        local why = pluralMismatch(cat, base)
        if why then
            -- Singular entries stay usable; plural ones are never guessed.
            if RULES[base] then warn(path, why) end
            cat.plural = {}
        end
    end
    return cat
end

local function build(raw)
    local code = I18n.normalizeLang(raw)
    local st = { raw = raw, code = code, cats = {} }
    if code and code ~= "C" then
        local dir = config.dir or defaultDir()
        local base = code:sub(1, 2)
        st.rule = RULES[base]
        for _, c in ipairs(candidates(code)) do
            local cat = loadCatalogue(dir .. "/" .. c .. ".po", base)
            if cat then st.cats[#st.cats + 1] = cat end
        end
    end
    return st
end

local function current()
    local gt = globalGettext()
    local raw = type(gt) == "table" and gt.current_lang or nil
    if not state or state.raw ~= raw then
        state = build(raw)
    end
    return state
end

--- Translate one message. Also reachable as `_("text")`.
function I18n.gettext(msgid)
    local st = current()
    if st.code == "C" then return msgid end
    for i = 1, #st.cats do
        local v = st.cats[i].singular[msgid]
        if v then return v end
    end
    local gt = globalGettext()
    if gt then
        local ok, v = pcall(gt, msgid)
        if ok and v ~= nil then return v end
    end
    return msgid
end

--- Translate a message with a count. The source language picks the singular
--- only for exactly 1.
function I18n.ngettext(singular, plural, n)
    local st = current()
    if st.code == "C" then
        return (n ~= 1) and plural or singular
    end
    if st.rule then
        local idx = st.rule.index(n) + 1
        for i = 1, #st.cats do
            local e = st.cats[i].plural[singular]
            if e and e.plural == plural then
                local v = e.forms[idx]
                if v then return v end
            end
        end
    end
    local gt = globalGettext()
    if type(gt) == "table" and gt.ngettext then
        local ok, v = pcall(gt.ngettext, singular, plural, n)
        if ok and v ~= nil then return v end
    end
    return (n ~= 1) and plural or singular
end

--- Drop the cache; the next lookup re-reads the catalogues. A change of
--- KOReader's current_lang does this by itself.
function I18n.invalidate()
    state = nil
end

--[[--
Replace the defaults, for tests and packaging tools: `dir` (catalogue
directory), `read(path) -> text | nil[, reason]`, `gettext` (the global
module). Omitted fields return to the defaults; the cache and the warning
budget are reset.
]]
function I18n.configure(opts)
    opts = opts or {}
    config = { dir = opts.dir, read = opts.read, gettext = opts.gettext }
    state = nil
    warned = {}
    warn_count = 0
end

--- The catalogue directory in use.
function I18n.catalogueDir()
    return config.dir or defaultDir()
end

return setmetatable(I18n, {
    __call = function(_, msgid) return I18n.gettext(msgid) end,
})
