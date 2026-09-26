--[[--
The Xournal++ XML the plugin writes, checked the way a strict reader would.

The writer's promises are about things that only break on someone else's
machine or someone else's notebook: a comma locale, a title with an ampersand
or a stray control byte, a 20 000-point stroke on a device with little memory,
a disk that fills halfway through. Each has a case here, plus one tiny
document pinned byte for byte so that any drift in the format is a visible
diff rather than a file Xournal++ quietly refuses.
]]

return function(ctx)
    local t = ctx.t
    local Xopp = require("ink_export_xopp")

    local UNITS_PER_MM = 8

    --- A sink that records every call, and can be told to fail or raise on
    --- the Nth one.
    local function newSink(opts)
        opts = opts or {}
        local s = { parts = {}, calls = 0, max = 0, fail_at = opts.fail_at }
        s.write = function(chunk)
            s.calls = s.calls + 1
            if opts.raise_at and s.calls >= opts.raise_at then
                error("sink exploded")
            end
            if s.fail_at and s.calls >= s.fail_at then
                return nil, "no space left on device"
            end
            s.parts[#s.parts + 1] = chunk
            if #chunk > s.max then s.max = #chunk end
            return true
        end
        s.text = function() return table.concat(s.parts) end
        return s
    end

    local function begin(sink, extra)
        local opts = { units_per_mm = UNITS_PER_MM, title = "Notes", version = "1.4" }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return Xopp.beginDocument(sink.write, opts)
    end

    --[[--
    Balanced tags, nothing but the XML declaration before the root, no DTD,
    and every `&` the start of one of the escapes the writer may use. Written
    from the XML grammar, not from the writer.
    ]]
    local function wellFormed(doc)
        if doc:find("<!", 1, true) then return nil, "DTD or comment" end
        local body = doc:match('^<%?xml [^?]*%?>\n(.*)$')
        if not body then return nil, "no declaration" end
        local stack, roots = {}, 0
        for close, name, attrs in body:gmatch("<(/?)([%a_][%w_]*)([^>]*)>") do
            if close == "/" then
                if stack[#stack] ~= name then return nil, "mismatched </" .. name .. ">" end
                stack[#stack] = nil
            else
                if #stack == 0 then roots = roots + 1 end
                if attrs:sub(-1) ~= "/" then stack[#stack + 1] = name end
            end
        end
        if #stack ~= 0 then return nil, "unclosed <" .. stack[#stack] .. ">" end
        if roots ~= 1 then return nil, "roots: " .. roots end
        for amp in doc:gmatch("&[^;]*;?") do
            if not (amp == "&amp;" or amp == "&lt;" or amp == "&gt;"
                or amp == "&quot;" or amp == "&apos;" or amp:match("^&#%d+;$")) then
                return nil, "bad reference " .. amp
            end
        end
        return true
    end

    -- --------------------------------------------------------------- mapping

    t:describe("ink_export_xopp / numbers and units")

    t:case("numbers are six decimals, trimmed, and never negative zero", function()
        local f = Xopp.formatNumber
        t:eq(f(0), "0", "zero")
        t:eq(f(-0.0), "0", "negative zero")
        t:eq(f(-0.0000001), "0", "tiny negative rounds to plain zero")
        t:eq(f(90), "90", "integer")
        t:eq(f(1.5), "1.5", "trimmed")
        t:eq(f(-1.25), "-1.25", "negative")
        t:eq(f(2.8346456692913), "2.834646", "six decimals, rounded")
        t:eq(f(2.9999999), "3", "carry into the integer part")
        t:eq(f(0.000001), "0.000001", "smallest step")
        t:eq(f(123456.123456), "123456.123456", "all six survive")
        t:eq(f(0 / 0), nil, "NaN refused")
        t:eq(f(math.huge), nil, "infinity refused")
        t:eq(f(1e9), nil, "past the magnitude bound")
    end)

    t:case("a positive width never rounds to zero", function()
        t:eq(Xopp.formatNumber(1e-12, true), "0.000001", "floored to the smallest step")
        t:eq(Xopp.formatNumber(0, true), "0", "zero is not positive")
        t:eq(Xopp.formatNumber(-1e-12, true), "0", "negative is not floored")
    end)

    t:case("units convert by the surface's millimetres, not a screen's dpi", function()
        t:eq(Xopp.formatNumber(Xopp.toPoints(254, UNITS_PER_MM)), "90", "254 units = 31.75 mm = 90 pt")
        t:eq(Xopp.formatNumber(Xopp.toPoints(1184, UNITS_PER_MM)), "419.527559", "A5 width")
        t:eq(Xopp.toPoints(8, 0), nil, "zero units per mm")
        t:eq(Xopp.toPoints(0 / 0, UNITS_PER_MM), nil, "NaN")
    end)

    t:case("output has no comma under a comma-decimal locale", function()
        -- Simulated: a string.format that answers what a de_DE libc would
        -- for every float conversion. A fresh copy of the module is loaded
        -- under it so nothing captured at require time can hide the effect.
        local real_format = string.format
        string.format = function(fmt, ...)
            local out = real_format(fmt, ...)
            if fmt:find("%%[%d.]*[fgeFGE]") then out = out:gsub("%.", ",") end
            return out
        end
        local ok, err = pcall(function()
            t:eq(string.format("%.2f", 1.5), "1,50", "the simulation is in force")
            local Fresh = assert(loadfile(ctx.plugin_dir .. "/ink_export_xopp.lua"))()
            t:eq(Fresh.formatNumber(419.527559), "419.527559", "dot kept")
            t:eq(Fresh.formatNumber(-0.5), "-0.5", "dot kept, negative")
            local sink = newSink()
            local w = Fresh.beginDocument(sink.write, { units_per_mm = UNITS_PER_MM })
            w:beginPage({ width = 1184, height = 1680 })
            w:writeStroke({ tool = 1, width = 3, points = { 1, 2, 3, 4 } })
            w:endPage()
            w:endDocument()
            t:check(not sink.text():find(",", 1, true), "no comma anywhere in the file")
        end)
        string.format = real_format
        t:check(ok, "simulated locale case ran: " .. tostring(err))

        -- And the real thing, where the host has a comma locale installed.
        if os.setlocale then
            local previous = os.setlocale(nil, "numeric")
            for _, name in ipairs({ "de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "es_ES.UTF-8" }) do
                if os.setlocale(name, "numeric") then
                    local formatted = Xopp.formatNumber(2.8346456692913)
                    os.setlocale(previous, "numeric")
                    t:eq(formatted, "2.834646", "real " .. name .. " locale")
                    break
                end
            end
            os.setlocale(previous, "numeric")
        end
    end)

    t:describe("ink_export_xopp / style and paper mapping")

    t:case("style ids agree with ink_style", function()
        local Style = require("ink_style")
        local function mapped(style)
            local tool, color = Xopp.styleFor(style)
            return tool .. " " .. color
        end
        t:eq(mapped(Style.PEN), "pen #000000ff", "pen")
        t:eq(mapped(Style.ROUND), "pen #000000ff", "round")
        t:eq(mapped(Style.MARKER), "pen #ccccccff", "marker: opaque LIGHT_GRAY pen")
        t:eq(mapped(Style.GRAPHITE), "pen #666666ff", "graphite: GRAY_6")
        t:eq(mapped(Style.HIGHLIGHTER), "highlighter #0000007f", "highlighter: Xournal++ alpha")
        t:eq(mapped(Style.TEXTURED), "pen #666666ff", "textured: GRAY_6")
        t:eq(mapped(nil), "pen #000000ff", "legacy stroke without a style")
        t:eq(mapped(999), "pen #000000ff", "unknown style degrades to pen")
        -- The gray styles on the device are exactly the non-black pens here.
        for _, style in ipairs({ Style.PEN, Style.MARKER, Style.GRAPHITE, Style.ROUND, Style.TEXTURED }) do
            local _, color = Xopp.styleFor(style)
            t:eq(color ~= "#000000ff", Style.isGray(style), "gray agrees for style " .. style)
        end
    end)

    t:case("every approximation a mapping makes is declared", function()
        local ids = {}
        for _, l in ipairs(Xopp.limitations) do
            t:check(type(l.text) == "string" and #l.text > 0, "limitation " .. tostring(l.id) .. " has text")
            ids[l.id] = true
        end
        for style, entry in pairs(Xopp.STYLE_MAP) do
            if entry.limitation then
                t:check(ids[entry.limitation], "style " .. style .. " limitation listed")
            end
        end
        t:check(ids.paper_fallback, "paper fallback listed")
        t:check(ids.single_point, "dot duplication listed")
    end)

    t:case("paper kinds map to backgrounds, unknown ones to ruled", function()
        local function bg(kind)
            local style, exact = Xopp.backgroundStyle(kind)
            return style .. (exact and "" or "~")
        end
        t:eq(bg("blank"), "plain", "blank")
        t:eq(bg(nil), "plain", "no paper is blank")
        t:eq(bg("ruled"), "ruled", "ruled is lines without a margin")
        t:eq(bg("grid"), "graph", "grid")
        t:eq(bg("dots"), "dotted", "dots")
        t:eq(bg("ruled_narrow"), "ruled~", "narrow ruled approximated")
        t:eq(bg("checklist"), "ruled~", "checklist approximated")
        t:eq(bg("hexagons"), "ruled~", "future kind approximated")
    end)

    -- ------------------------------------------------------------------ text

    t:describe("ink_export_xopp / text")

    t:case("titles are escaped, UTF-8 intact", function()
        t:eq(Xopp.escapeText("Cuaderno de anatomía — «ñ» 😀"),
            "Cuaderno de anatomía — «ñ» 😀", "UTF-8 passes through")
        t:eq(Xopp.escapeText([[a & b <c> "d" 'e']]),
            "a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;", "the five escapes")
        t:eq(Xopp.escapeText("a\tb\nc\rd"), "a\tb\nc&#13;d", "tab and LF kept, CR referenced")
        t:eq(Xopp.escapeAttribute("a\tb\nc"), "a&#9;b&#10;c", "attribute whitespace referenced")
    end)

    t:case("characters XML 1.0 cannot carry are refused", function()
        local function refused(s, want, label)
            local out, err = Xopp.escapeText(s)
            t:eq(out, nil, label)
            t:eq(err, want, label .. " reason")
        end
        refused("a\0b", "invalid_char", "NUL")
        refused("a\1b", "invalid_char", "SOH")
        refused("a\27b", "invalid_char", "ESC")
        refused("\31", "invalid_char", "unit separator")
        refused("\239\191\190", "invalid_char", "U+FFFE")
        refused("\239\191\191", "invalid_char", "U+FFFF")
        refused("a\195(", "invalid_utf8", "truncated sequence")
        refused("a\195", "invalid_utf8", "sequence cut at the end")
        refused("\192\175", "invalid_utf8", "overlong slash")
        refused("\224\128\175", "invalid_utf8", "overlong three-byte")
        refused("\237\160\128", "invalid_utf8", "surrogate")
        refused("\244\144\128\128", "invalid_utf8", "past U+10FFFF")
        refused("\255", "invalid_utf8", "never a UTF-8 byte")
        t:eq(Xopp.escapeText(nil), nil, "not a string")

        local sink = newSink()
        local w, err = begin(sink, { title = "bad\7title" })
        t:eq(w, nil, "document with a control byte in its title refused")
        t:eq(err, "invalid_char", "and says why")
        t:eq(sink.calls, 0, "before a byte was written")
    end)

    -- -------------------------------------------------------------- document

    t:describe("ink_export_xopp / document")

    t:case("a tiny document, byte for byte", function()
        local sink = newSink()
        local w = assert(begin(sink))
        t:check(w:beginPage({ width = 1184, height = 1680, paper = "grid" }), "page")
        t:check(w:writeStroke({ tool = 1, width = 8, points = { 0, 0, 254, 127 } }), "pen")
        t:check(w:writeStroke({ tool = 67, n = 1, width = 24, points = { 254, 254 } }), "dot")
        t:check(w:writeStroke({ tool = 65, n = 3, width = 8, widths = { 4, 16 },
            points = { 0, 0, 127, 0, 254, 0 } }), "pressure")
        t:check(w:endPage(), "end page")
        t:check(w:endDocument(), "end document")
        t:eq(sink.text(), table.concat({
            '<?xml version="1.0" encoding="UTF-8"?>\n',
            '<xournal creator="JustDraw 1.4" fileversion="4">\n',
            '<title>Notes</title>\n',
            '<page width="419.527559" height="595.275591">\n',
            '<background type="solid" color="#ffffffff" style="graph"/>\n',
            '<layer>\n',
            '<stroke tool="pen" color="#000000ff" width="2.834646" capStyle="round">0 0 90 45</stroke>\n',
            '<stroke tool="highlighter" color="#0000007f" width="8.503937" capStyle="round">90 90 90 90</stroke>\n',
            '<stroke tool="pen" color="#666666ff" width="2.834646 1.417323 5.669291" capStyle="round">0 0 45 0 90 0</stroke>\n',
            '</layer>\n',
            '</page>\n',
            '</xournal>\n',
        }), "exact output")
        t:check(w:isFinished(), "finished")
        t:eq(w:pageCount(), 1, "one page")
    end)

    t:case("a small full document is well formed", function()
        local sink = newSink()
        local w = assert(begin(sink, { title = [[<Tom & "Jerry's"> ñ]] }))
        for p = 1, 3 do
            w:beginPage({ width = 1184, height = 1680, paper = ({ "blank", "dots", "checklist" })[p] })
            for s = 1, p do
                w:writeStroke({ tool = 66, width = 2, points = { s, s, s + 10, s + 20 } })
            end
            w:endPage()
        end
        w:beginPage({ width = 1184, height = 1680 })
        w:endPage() -- an empty page still has its layer
        assert(w:endDocument())
        local ok, why = wellFormed(sink.text())
        t:check(ok, "well formed: " .. tostring(why))
        local _, pages = sink.text():gsub("<page ", "")
        local _, layers = sink.text():gsub("<layer>", "")
        t:eq(pages, 4, "four pages")
        t:eq(layers, 4, "one layer each")
        t:check(sink.text():find("<title>&lt;Tom &amp; &quot;Jerry&apos;s&quot;&gt; ñ</title>", 1, true),
            "title escaped in place")
        t:check(wellFormed('<?xml version="1.0"?>\n<a><b></a></b>') == nil, "checker catches crossed tags")
    end)

    t:case("extreme but valid geometry", function()
        local sink = newSink()
        local w = assert(begin(sink))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        t:check(w:writeStroke({ tool = 1, width = 1e-9, points = { 0, 0, 1184, 1680 } }),
            "corner to corner, hair-thin")
        t:check(w:writeStroke({ tool = 1, width = 8, widths = { 1e-12 }, points = { 0, 0, 0, 0 } }),
            "a pressure width near zero")
        local text = sink.text()
        t:check(text:find('width="0.000001"', 1, true), "thin width floored, not zero")
        t:check(text:find('width="2.834646 0.000001"', 1, true), "thin segment floored, not zero")
        t:check(text:find(">0 0 419.527559 595.275591<", 1, true), "page edges are the page size")
        t:check(not text:find('width="0"', 1, true), "no zero width anywhere")
    end)

    t:case("a single point is doubled, never stretched", function()
        local sink = newSink()
        local w = assert(begin(sink))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        t:check(w:writeStroke({ tool = 1, width = 8, points = { 127, 254 } }), "n taken from the array")
        t:check(w:writeStroke({ tool = 1, n = 1, width = 8, widths = {}, points = { 127, 254 } }),
            "no segments, so no segment widths")
        local _, dots = sink.text():gsub('capStyle="round">45 90 45 90</stroke>', "")
        t:eq(dots, 2, "both dots are the same point twice")
        t:check(not sink.text():find('width="2.834646 ', 1, true), "no pressure values for a dot")
    end)

    t:describe("ink_export_xopp / validation")

    t:case("bad strokes are refused before a byte is written", function()
        local sink = newSink()
        local w = assert(begin(sink))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        local before_calls, before_text = sink.calls, sink.text()
        local nan, inf = 0 / 0, math.huge
        local cases = {
            { "not a table", "bad_stroke", 42 },
            { "no points", "bad_point", { width = 1 } },
            { "empty", "bad_count", { width = 1, points = {} } },
            { "odd array", "bad_count", { width = 1, points = { 1, 2, 3 } } },
            { "n larger than the array", "bad_count", { n = 3, width = 1, points = { 1, 2, 3, 4 } } },
            { "n smaller than the array", "bad_count", { n = 1, width = 1, points = { 1, 2, 3, 4 } } },
            { "n zero", "bad_count", { n = 0, width = 1, points = {} } },
            { "n fractional", "bad_count", { n = 1.5, width = 1, points = { 1, 2, 3 } } },
            { "NaN coordinate", "bad_point", { width = 1, points = { 1, nan, 3, 4 } } },
            { "infinite coordinate", "bad_point", { width = 1, points = { 1, 2, inf, 4 } } },
            { "string coordinate", "bad_point", { width = 1, points = { 1, 2, "3", 4 } } },
            { "absurd coordinate", "out_of_range", { width = 1, points = { 1, 2, 1e12, 4 } } },
            { "zero width", "bad_width", { width = 0, points = { 1, 2, 3, 4 } } },
            { "negative width", "bad_width", { width = -1, points = { 1, 2, 3, 4 } } },
            { "NaN width", "bad_width", { width = nan, points = { 1, 2, 3, 4 } } },
            { "no width", "bad_width", { points = { 1, 2, 3, 4 } } },
            { "widths: one too many", "bad_widths", { width = 1, widths = { 1, 1 }, points = { 1, 2, 3, 4 } } },
            { "widths: one too few", "bad_widths", { width = 1, widths = { 1 }, points = { 1, 2, 3, 4, 5, 6 } } },
            { "widths: per point, not per segment", "bad_widths",
                { width = 1, widths = { 1, 1, 1 }, points = { 1, 2, 3, 4, 5, 6 } } },
            { "widths: zero", "bad_widths", { width = 1, widths = { 1, 0 }, points = { 1, 2, 3, 4, 5, 6 } } },
            { "widths: NaN", "bad_widths", { width = 1, widths = { nan }, points = { 1, 2, 3, 4 } } },
            { "widths: negative", "bad_widths", { width = 1, widths = { -2 }, points = { 1, 2, 3, 4 } } },
            { "widths: not a table", "bad_widths", { width = 1, widths = 3, points = { 1, 2, 3, 4 } } },
        }
        for _, c in ipairs(cases) do
            local ok, err = w:writeStroke(c[3])
            t:eq(ok, nil, c[1] .. " refused")
            t:eq(err, c[2], c[1] .. " reason")
        end
        t:eq(sink.calls, before_calls, "nothing reached the sink")
        t:eq(sink.text(), before_text, "output unchanged")
        t:eq(w:failure(), nil, "a refused stroke does not poison the writer")
        t:check(w:writeStroke({ width = 1, points = { 1, 2, 3, 4 } }), "the next good stroke is written")
        t:check(w:endPage() and w:endDocument(), "and the document closes")
        t:check(wellFormed(sink.text()), "still well formed")
    end)

    t:case("documents and pages are validated", function()
        local sink = newSink()
        t:eq(select(2, Xopp.beginDocument(nil, { units_per_mm = 8 })), "bad_sink", "no sink")
        t:eq(select(2, Xopp.beginDocument(sink.write, {})), "bad_units", "no units")
        t:eq(select(2, Xopp.beginDocument(sink.write, { units_per_mm = 0 })), "bad_units", "zero units")
        t:eq(select(2, Xopp.beginDocument(sink.write, { units_per_mm = 8, block_limit = 10 })),
            "bad_block_limit", "block limit too small")
        t:eq(select(2, Xopp.beginDocument(sink.write, { units_per_mm = 8, block_limit = 1e6 })),
            "bad_block_limit", "block limit above the cap")
        t:eq(sink.calls, 0, "nothing written by refused documents")

        local w = assert(begin(sink))
        t:eq(select(2, w:writeStroke({ width = 1, points = { 1, 2 } })), "bad_state", "stroke outside a page")
        t:eq(select(2, w:endPage()), "bad_state", "no page to end")
        t:eq(select(2, w:beginPage({ width = 0, height = 10 })), "bad_page_size", "zero width page")
        t:eq(select(2, w:beginPage({ width = 10, height = 0 / 0 })), "bad_page_size", "NaN height page")
        t:eq(select(2, w:beginPage({ width = -5, height = 10 })), "bad_page_size", "negative page")
        t:eq(select(2, w:beginPage("A5")), "bad_page", "not a table")
        assert(w:beginPage({ width = 10, height = 10 }))
        t:eq(select(2, w:beginPage({ width = 10, height = 10 })), "bad_state", "nested page")
        t:eq(select(2, w:endDocument()), "bad_state", "document closed over an open page")
        assert(w:endPage())
        assert(w:endDocument())
        t:eq(select(2, w:beginPage({ width = 10, height = 10 })), "bad_state", "page after the end")

        local empty = assert(begin(newSink()))
        t:eq(select(2, empty:endDocument()), "no_pages", "a document without pages")
        t:eq(empty:failure(), "no_pages", "is a failed document")
    end)

    t:describe("ink_export_xopp / the sink")

    t:case("a failing sink stops the writer for good", function()
        -- Call 1 is the header; call 2 the page; call 3 the first stroke.
        local sink = newSink({ fail_at = 3 })
        local w = assert(begin(sink))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        local ok, err = w:writeStroke({ width = 1, points = { 1, 2, 3, 4 } })
        t:eq(ok, nil, "the stroke that met the failure fails")
        t:eq(err, "no space left on device", "with the sink's reason")
        local calls = sink.calls
        t:eq(select(2, w:writeStroke({ width = 1, points = { 1, 2, 3, 4 } })),
            "no space left on device", "later strokes refused")
        t:eq(select(2, w:endPage()), "no space left on device", "end page refused")
        t:eq(select(2, w:endDocument()), "no space left on device", "end document refused")
        t:eq(sink.calls, calls, "the sink was never called again")
        t:eq(w:isFinished(), false, "never finished")
        t:eq(w:failure(), "no space left on device", "failure reported")
    end)

    t:case("a sink that fails on the header yields no writer", function()
        local w, err = begin(newSink({ fail_at = 1 }))
        t:eq(w, nil, "no writer")
        t:eq(err, "no space left on device", "the sink's reason")
    end)

    t:case("a sink that raises is a sink that failed", function()
        local sink = newSink({ raise_at = 2 })
        local w = assert(begin(sink))
        local ok, err = w:beginPage({ width = 1184, height = 1680 })
        t:eq(ok, nil, "the call fails instead of raising")
        t:check(tostring(err):find("sink exploded", 1, true), "with the error's text")
        t:eq(select(2, w:endPage()), err, "and the writer stays failed")
        t:eq(sink.calls, 2, "no further calls")
    end)

    t:case("a sink failing mid-stroke stops within the stroke", function()
        local sink = newSink()
        local w = assert(begin(sink, { block_limit = 64 }))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        -- The stroke's third block fails; it needs dozens.
        local fail_at = sink.calls + 3
        sink.fail_at = fail_at
        local points = {}
        for i = 1, 400 do points[i] = i end
        local ok, err = w:writeStroke({ width = 1, points = points })
        t:eq(ok, nil, "the long stroke fails")
        t:eq(err, "no space left on device", "with the reason")
        t:eq(sink.calls, fail_at, "nothing after the failing call")
    end)

    t:case("fragmented blocks join to the same document", function()
        local function build(limit)
            local sink = newSink()
            local w = assert(begin(sink, { block_limit = limit,
                title = string.rep("título & más ", 40) }))
            w:beginPage({ width = 1184, height = 1680, paper = "ruled" })
            local points = {}
            for i = 1, 200 do points[i] = i * 1.37 end
            w:writeStroke({ tool = 67, width = 3, points = points })
            local widths = {}
            for i = 1, 99 do widths[i] = 1 + i / 100 end
            w:writeStroke({ tool = 1, width = 2, widths = widths, points = points })
            w:endPage()
            assert(w:endDocument())
            return sink
        end
        local whole, fragmented = build(nil), build(64)
        t:eq(fragmented.text(), whole.text(), "identical once concatenated")
        t:check(fragmented.max <= 64, "no fragment past its limit (" .. fragmented.max .. ")")
        t:check(fragmented.calls > 50, "and it really was fragmented")
        t:check(wellFormed(fragmented.text()), "well formed")
    end)

    t:case("a 20000-point stroke never becomes one big write", function()
        local sink = newSink()
        local w = assert(begin(sink))
        assert(w:beginPage({ width = 1184, height = 1680 }))
        local n = 20000
        local points, widths = {}, {}
        for i = 1, n do
            points[i * 2 - 1] = (i % 1184) + 0.123456
            points[i * 2] = (i % 1680) + 0.654321
            if i < n then widths[i] = 1 + (i % 7) / 3 end
        end
        t:check(w:writeStroke({ tool = 1, n = n, width = 2, widths = widths, points = points }), "written")
        assert(w:endPage())
        assert(w:endDocument())
        t:check(sink.max <= Xopp.BLOCK_LIMIT, "largest write " .. sink.max .. " within the cap")
        t:check(sink.max <= 16384, "the cap is 16 KiB")
        t:check(#sink.text() > 10 * Xopp.BLOCK_LIMIT, "and the stroke really was big")
        local body = sink.text():match('capStyle="round">([^<]*)</stroke>')
        local _, numbers = body:gsub("%S+", "")
        t:eq(numbers, n * 2, "every coordinate present")
        local width_attr = sink.text():match('<stroke [^>]*width="([^"]*)"')
        local _, width_values = width_attr:gsub("%S+", "")
        t:eq(width_values, n, "nominal width plus n - 1 segment widths")
        t:check(wellFormed(sink.text()), "well formed")
    end)
end
