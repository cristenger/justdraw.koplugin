--[[--
The PDF the plugin writes, read back by something that does not trust it.

A file format written by hand has a specific failure mode: the writer and its
test agree on a misreading, the bytes are self-consistent, and every reader in
the world rejects them. So the parser below is written from ISO 32000-1 --
find `startxref`, walk the twenty-byte entries, resolve each object *by the
offset the table gives* and check that something starts there -- rather than
from `ink_export_pdf.lua`. If the writer drifts, the offsets stop landing on
object headers and this notices, because it never asked the writer where
anything was.

The other half is the things that are only wrong on someone else's machine: a
title with an accent in it, a decimal point under a comma locale, a date with
no offset, and an image whose rows come out upside down. The orientation claim
is pinned here as the content stream and the byte order; that it *renders* the
right way up was established against a real renderer and is restated in
tests/conformance.lua.
]]

return function(ctx)
    local t = ctx.t
    local Pdf = require("ink_export_pdf")

    local function fixedClock()
        return { year = 2026, month = 8, day = 30, hour = 16, min = 18,
            sec = 42, offset_minutes = -300 }
    end

    --- A sink that is also a stand-in for a file handle: `tell` answers what a
    --- real one would, so the writer's offset cross-check is exercised.
    local function newSink(opts)
        opts = opts or {}
        local s = { parts = {}, n = 0, bytes = 0, drift = opts.drift }
        s.write = function(chunk)
            if opts.fail_after and s.n >= opts.fail_after then
                return nil, "no space left on device"
            end
            s.n = s.n + 1
            s.parts[s.n] = chunk
            s.bytes = s.bytes + #chunk
            return true
        end
        s.tell = function()
            if s.drift and s.n >= s.drift then return s.bytes + 1 end
            return s.bytes
        end
        s.text = function() return table.concat(s.parts, "", 1, s.n) end
        return s
    end

    --[[--
    An independent reader. Returns the parsed file or nil plus what failed,
    and knows nothing about how the writer lays anything out.
    ]]
    local function parse(doc)
        local result = { entries = {}, objects = {} }
        if doc:sub(1, 9) ~= "%PDF-1.4\n" then return nil, "bad header" end
        -- 7.5.2: a binary comment of at least four bytes >= 128, so transfer
        -- programs treat the file as binary.
        local comment = doc:sub(10, 14)
        if comment:sub(1, 1) ~= "%" then return nil, "no binary comment" end
        local high = 0
        for i = 2, 5 do
            if comment:byte(i) and comment:byte(i) >= 128 then high = high + 1 end
        end
        if high < 4 then return nil, "binary comment not binary" end

        local startxref = doc:match("startxref%s+(%d+)%s*%%%%EOF%s*$")
        if not startxref then return nil, "no startxref" end
        result.startxref = tonumber(startxref)

        local tail = doc:sub(result.startxref + 1)
        local first, count = tail:match("^xref%s*\n(%d+)%s+(%d+)%s*\n")
        if not first then return nil, "no xref table at startxref" end
        result.first, result.count = tonumber(first), tonumber(count)
        local entries_at = result.startxref
            + #("xref\n" .. first .. " " .. count .. "\n")
        for i = 0, result.count - 1 do
            local entry = doc:sub(entries_at + i * 20 + 1, entries_at + (i + 1) * 20)
            result.entries[i] = entry
        end

        local trailer = doc:match("trailer%s*<<(.-)>>%s*startxref")
        if not trailer then return nil, "no trailer" end
        result.trailer = trailer
        result.size = tonumber(trailer:match("/Size%s+(%d+)"))
        result.root = tonumber(trailer:match("/Root%s+(%d+)%s+0%s+R"))
        result.info = tonumber(trailer:match("/Info%s+(%d+)%s+0%s+R"))

        -- Resolve every in-use object through the offset the table published.
        for i = 1, result.count - 1 do
            local entry = result.entries[i]
            -- 7.5.4: ten digits, a space, five digits, a space, the type,
            -- and a two-byte end-of-line that is SP CR, SP LF or CR LF.
            local off, kind = entry:match(
                "^(%d%d%d%d%d%d%d%d%d%d) %d%d%d%d%d ([nf])[ \r][\r\n]$")
            if not off then return nil, "malformed xref entry " .. i end
            if kind == "n" then
                local at = tonumber(off)
                local header = doc:sub(at + 1, at + #tostring(i) + 6)
                if header ~= i .. " 0 obj" then
                    return nil, "xref entry " .. i .. " does not point at its object"
                end
                local body = doc:match("\n(.-)\nendobj", at + 1)
                result.objects[i] = body
            end
        end
        return result
    end

    --- The bytes of a stream object, and the /Length it declared.
    local function streamOf(doc, obj_id)
        local pattern = "\n" .. obj_id .. " 0 obj\n<<(.-)>>\nstream\n"
        local dict, at = doc:match(pattern), nil
        if not dict then
            dict = doc:match("^" .. obj_id .. " 0 obj\n<<(.-)>>\nstream\n")
        end
        if not dict then return nil end
        local declared = tonumber(dict:match("/Length%s+(%d+)"))
        local head = obj_id .. " 0 obj\n<<" .. dict .. ">>\nstream\n"
        at = doc:find(head, 1, true)
        if not at then return nil end
        local data_at = at + #head - 1
        return dict, doc:sub(data_at + 1, data_at + declared), declared
    end

    local function onePage(opts)
        opts = opts or {}
        local sink = newSink(opts.sink)
        local w = Pdf.new{
            write = sink.write, tell = sink.tell, now = fixedClock,
            title = opts.title, compress = opts.compress,
        }
        local ok, err = w:addImagePage{
            width_pt = opts.width_pt or 419.53,
            height_pt = opts.height_pt or 595.28,
            w = opts.w or 4, h = opts.h or 2,
            gray = opts.gray or (string.char(0, 0, 0, 255) .. string.char(255, 255, 255, 0)),
        }
        return w, sink, ok, err
    end

    t:describe("export / pdf writer / structure")

    t:case("a file with one page parses as a PDF", function()
        local w, sink = onePage()
        t:check(w:finish(), "finish")
        local doc, why = parse(sink.text())
        t:check(doc ~= nil, "parses: " .. tostring(why))
        if not doc then return end
        t:eq(doc.root, 1, "/Root names the catalog")
        t:eq(doc.info, 3, "/Info names the information dictionary")
        t:eq(doc.size, doc.count, "/Size matches the xref subsection count")
        t:eq(doc.entries[0], "0000000000 65535 f \n", "object 0 is the free head")
        t:check(doc.objects[1]:find("/Type/Catalog", 1, true) ~= nil, "catalog")
        t:check(doc.objects[2]:find("/Count 1", 1, true) ~= nil, "page count")
    end)

    t:case("every xref entry is exactly twenty bytes", function()
        local w, sink = onePage()
        w:finish()
        local doc = parse(sink.text())
        for i = 0, doc.count - 1 do
            t:eq(#doc.entries[i], 20, "entry " .. i .. " length")
        end
    end)

    t:case("a second page is listed in the page tree and resolvable", function()
        local sink = newSink()
        local w = Pdf.new{ write = sink.write, tell = sink.tell, now = fixedClock }
        w:addImagePage{ width_pt = 100, height_pt = 200, w = 2, h = 1,
            gray = string.char(0, 255) }
        w:addImagePage{ width_pt = 300, height_pt = 400, w = 1, h = 1,
            gray = string.char(128) }
        t:check(w:finish(), "finish")
        t:eq(w:pageCount(), 2, "page count")
        local doc, why = parse(sink.text())
        t:check(doc ~= nil, "parses: " .. tostring(why))
        if not doc then return end
        local kids = doc.objects[2]:match("/Kids%[(.-)%]")
        t:eq(kids, "6 0 R 9 0 R", "both pages are kids, in order")
        t:check(doc.objects[2]:find("/Count 2", 1, true) ~= nil, "count is two")
        t:check(doc.objects[6]:find("/MediaBox[0 0 100 200]", 1, true) ~= nil,
            "first MediaBox")
        t:check(doc.objects[9]:find("/MediaBox[0 0 300 400]", 1, true) ~= nil,
            "second MediaBox")
    end)

    t:case("the page tree is written after the pages it lists", function()
        local w, sink = onePage()
        w:finish()
        local doc = parse(sink.text())
        -- Object 2 is reserved up front and emitted last; the xref is what
        -- makes that legal, so the offsets must be out of numeric order.
        local pages_at = tonumber(doc.entries[2]:match("^(%d+)"))
        local page_at = tonumber(doc.entries[6]:match("^(%d+)"))
        t:check(pages_at > page_at, "the /Pages object comes later in the file")
    end)

    t:describe("export / pdf writer / images")

    t:case("image bytes survive verbatim when nothing compresses them", function()
        local gray = string.char(0, 17, 34, 255) .. string.char(255, 200, 100, 0)
        local w, sink = onePage{ gray = gray }
        w:finish()
        local doc = sink.text()
        local dict, data = streamOf(doc, 5)
        t:check(dict ~= nil, "image object found")
        t:eq(data, gray, "every pixel round-trips")
        t:check(dict:find("/Width 4", 1, true) ~= nil, "width")
        t:check(dict:find("/Height 2", 1, true) ~= nil, "height")
        t:check(dict:find("/ColorSpace/DeviceGray", 1, true) ~= nil, "colour space")
        t:check(dict:find("/BitsPerComponent 8", 1, true) ~= nil, "bit depth")
        t:check(dict:find("/Filter", 1, true) == nil, "no filter without a compressor")
    end)

    t:case("the declared /Length is the number of bytes actually emitted", function()
        local w, sink = onePage()
        w:finish()
        local _, data, declared = streamOf(sink.text(), 5)
        t:eq(#data, declared, "image stream length")
        local _, content, content_len = streamOf(sink.text(), 4)
        t:eq(#content, content_len, "content stream length")
    end)

    t:case("a compressor is used, declared, and reverses", function()
        local gray = string.rep("\0", 64)
        local seen
        local w, sink = onePage{
            w = 8, h = 8, gray = gray,
            compress = function(s) seen = s; return "COMPRESSED" end,
        }
        w:finish()
        t:eq(seen, gray, "the compressor was handed the raw bytes")
        local dict, data = streamOf(sink.text(), 5)
        t:check(dict:find("/Filter/FlateDecode", 1, true) ~= nil, "filter declared")
        t:eq(data, "COMPRESSED", "the compressed bytes are what got written")
    end)

    t:case("a compressor that raises downgrades to an uncompressed stream", function()
        local w, sink = onePage{ compress = function() error("zlib is missing") end }
        t:check(w:finish(), "the file is still written")
        local dict, data = streamOf(sink.text(), 5)
        t:check(dict:find("/Filter", 1, true) == nil, "no filter is claimed")
        t:eq(#data, 8, "the raw bytes went out instead")
        t:check(parse(sink.text()) ~= nil, "and it still parses")
    end)

    t:case("the image is placed upright by the content stream", function()
        local w, sink = onePage{ width_pt = 419.53, height_pt = 595.28 }
        w:finish()
        local _, content = streamOf(sink.text(), 4)
        t:eq(content, "q\n419.53 0 0 595.28 0 0 cm\n/Im0 Do\nQ\n",
            "unit square scaled to the MediaBox, no flip")
    end)

    t:describe("export / pdf writer / text and numbers")

    t:case("a decimal is emitted with a point, whatever the locale believes", function()
        t:eq(Pdf.encodeNumber(419.53), "419.53", "two decimals")
        t:eq(Pdf.encodeNumber(595.2), "595.2", "one decimal")
        t:eq(Pdf.encodeNumber(100), "100", "integer")
        t:eq(Pdf.encodeNumber(0.5), "0.5", "below one")
        t:eq(Pdf.encodeNumber(-3.25), "-3.25", "negative")
    end)

    t:case("plain ASCII is a literal string, escaped where the syntax needs it", function()
        t:eq(Pdf.encodeString("JustDraw"), "(JustDraw)", "plain")
        t:eq(Pdf.encodeString("a(b)c"), "(a\\(b\\)c)", "parentheses")
        t:eq(Pdf.encodeString("a\\b"), "(a\\\\b)", "backslash")
    end)

    t:case("anything else becomes UTF-16BE with a byte order mark", function()
        t:eq(Pdf.encodeString("anatomía"), "<FEFF0061006E00610074006F006D00ED0061>",
            "an accent forces the hex form")
        -- U+1F600 is outside the BMP and has to become a surrogate pair.
        t:eq(Pdf.encodeString("\240\159\152\128"), "<FEFFD83DDE00>", "emoji")
    end)

    t:case("malformed UTF-8 becomes a replacement character, not a raise", function()
        t:eq(Pdf.encodeString("\255\254"), "<FEFFFFFDFFFD>", "two bad bytes")
        t:eq(Pdf.encodeString("\224\128\128"), "<FEFFFFFD>", "an overlong form")
    end)

    t:case("the title reaches the information dictionary", function()
        local w, sink = onePage{ title = "Cuaderno de anatomía" }
        w:finish()
        local doc = parse(sink.text())
        t:check(doc.objects[3]:find("/Title <FEFF", 1, true) ~= nil,
            "encoded, not raw UTF-8")
        t:check(doc.objects[3]:find("/Producer (JustDraw)", 1, true) ~= nil,
            "producer")
    end)

    t:case("the creation date carries an explicit offset", function()
        local w, sink = onePage()
        w:finish()
        local doc = parse(sink.text())
        t:check(doc.objects[3]:find("(D:20260830161842-05'00')", 1, true) ~= nil,
            "date with a signed offset")
    end)

    t:case("a positive and a zero offset are both well formed", function()
        t:eq(Pdf.encodeDate{ year = 2026, month = 1, day = 2, hour = 3,
            min = 4, sec = 5, offset_minutes = 330 },
            "(D:20260102030405+05'30')", "half-hour zone")
        t:eq(Pdf.encodeDate{ year = 2026, month = 1, day = 2, hour = 3,
            min = 4, sec = 5, offset_minutes = 0 },
            "(D:20260102030405+00'00')", "UTC")
    end)

    t:describe("export / pdf writer / refusals")

    t:case("a document with no pages is refused rather than written", function()
        local sink = newSink()
        local w = Pdf.new{ write = sink.write }
        local ok, err = w:finish()
        t:check(not ok, "refused")
        t:eq(err, "no_pages", "reason")
        t:eq(sink.text(), "", "nothing was written at all")
    end)

    t:case("a page whose data does not match its dimensions is refused", function()
        local sink = newSink()
        local w = Pdf.new{ write = sink.write }
        local ok, err = w:addImagePage{ width_pt = 10, height_pt = 10,
            w = 4, h = 2, gray = string.rep("\0", 7) }
        t:check(not ok, "refused")
        t:eq(err, "bad_image_data", "reason")
    end)

    t:case("non-integer, zero and infinite geometry are all refused", function()
        local sink = newSink()
        local w = Pdf.new{ write = sink.write }
        t:eq(select(2, w:addImagePage{ width_pt = 10, height_pt = 10, w = 2.5,
            h = 1, gray = "ab" }), "bad_image_size", "fractional pixels")
        t:eq(select(2, w:addImagePage{ width_pt = 10, height_pt = 10, w = 0,
            h = 1, gray = "" }), "bad_image_size", "zero width")
        t:eq(select(2, w:addImagePage{ width_pt = 0, height_pt = 10, w = 1,
            h = 1, gray = "a" }), "bad_page_size", "zero points")
        t:eq(select(2, w:addImagePage{ width_pt = 1 / 0, height_pt = 10, w = 1,
            h = 1, gray = "a" }), "bad_page_size", "infinite points")
    end)

    t:case("nothing may be added after the file is finished", function()
        local w = onePage()
        w:finish()
        local ok, err = w:addImagePage{ width_pt = 10, height_pt = 10, w = 1,
            h = 1, gray = "\0" }
        t:check(not ok, "refused")
        t:eq(err, "finished", "reason")
        t:eq(select(2, w:finish()), "finished", "and it cannot finish twice")
    end)

    t:case("a failed write poisons the writer instead of producing a torso", function()
        local w, sink = onePage{ sink = { fail_after = 3 } }
        t:check(not w:finish(), "finish reports the failure")
        t:eq(w:failure(), "no space left on device", "the reason is kept")
        t:eq(select(2, w:addImagePage{ width_pt = 1, height_pt = 1, w = 1, h = 1,
            gray = "\0" }), "no space left on device", "every later call agrees")
    end)

    t:case("a handle that disagrees about the offset stops the file", function()
        local sink = newSink{ drift = 4 }
        local w = Pdf.new{ write = sink.write, tell = sink.tell, now = fixedClock }
        w:addImagePage{ width_pt = 10, height_pt = 10, w = 2, h = 1,
            gray = string.char(0, 255) }
        local ok, err = w:finish()
        t:check(not ok, "refused")
        t:eq(err, "offset_drift", "the xref would have been wrong")
    end)

    t:case("a page too small to have a size is refused", function()
        local sink = newSink()
        local w = Pdf.new{ write = sink.write }
        -- `pdfNumber` emits two decimals, so anything below half a hundredth
        -- of a point would be written as "0" and produce a MediaBox no reader
        -- can lay out. "Greater than zero" did not protect the emitter.
        t:eq(select(2, w:addImagePage{ width_pt = 0.004, height_pt = 100,
            w = 1, h = 1, gray = "\0" }), "bad_page_size", "sub-point width")
        t:eq(select(2, w:addImagePage{ width_pt = 100, height_pt = 0.5,
            w = 1, h = 1, gray = "\0" }), "bad_page_size", "half a point tall")
        t:check(w:addImagePage{ width_pt = 1, height_pt = 1, w = 1, h = 1,
            gray = "\0" }, "exactly one point is allowed")
    end)

    t:case("a broken byte does not swallow the character after it", function()
        -- Advancing by the *declared* length would eat the byte that broke
        -- the sequence: the "(" here would be lost as well.
        t:eq(Pdf.encodeString("a\195(b"), "<FEFF0061FFFD00280062>",
            "the truncated sequence is replaced and reading resumes at '('")
        t:eq(Pdf.encodeString("\226\130a"), "<FEFFFFFD0061>",
            "a three-byte sequence cut short keeps the 'a'")
    end)

    t:case("a writer with no sink is refused at construction", function()
        local w, err = Pdf.new{}
        t:check(w == nil, "no writer")
        t:eq(err, "no_sink", "reason")
    end)
end
