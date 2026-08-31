--[[--
A PDF file, written by hand, one grey image per page.

KOReader ships MuPDF but not a way to *create* a document with it: the pinned
wrapper exposes `mupdf_pdf_save_document` and the annotation setters, and
nothing that makes a new `pdf_document` or a `fz_document_writer`. So a plugin
that wants to hand the reader a PDF has to emit the bytes itself. That is less
alarming than it sounds -- a page that is one full-bleed image needs four
object types and a cross-reference table -- but it is exactly the kind of code
that is wrong in ways no eyeball catches, so everything here is written to be
checkable by a parser that shares none of its assumptions.

Three decisions are load-bearing:

**The sink is injected, and so is the clock.** This module never opens a file.
It writes through `opts.write` and asks `opts.tell` where the handle thinks it
is, which is what makes the offsets in the xref table verifiable rather than
merely computed: a short write on a full disk desynchronises the two and the
next object refuses to start. Tests pass a string buffer and a fixed clock.

**Byte offsets are counted, then cross-checked.** Every xref entry has to point
at the first byte of `N 0 obj`. Counting is the only way to know that while
streaming, and `tell` is the only way to know the count is still true.

**No `string.format("%.2f")` anywhere near a number that reaches the file.**
`%f` follows the C locale, and under a comma locale `419.53` is emitted as
`419,53` -- two tokens where the syntax needs one, in a MediaBox that then
fails to parse. Every number goes through `pdfNumber`, which is integer
arithmetic and has no opinion about locales.

Text is the other trap. A PDF literal string is bytes in PDFDocEncoding, not
UTF-8, so a notebook called "Cuaderno de anatomía" would arrive mojibake in
every reader's document properties. Anything that is not printable ASCII is
therefore emitted as a UTF-16BE hex string with a BOM (ISO 32000-1, 7.9.2.2).

Structure follows ISO 32000-1:2008: binary comment after the header (7.5.2) so
transfer programs treat the file as binary, one indirect object per catalog,
page tree, page, content stream and image (7.3.10), a classic cross-reference
table whose entries are exactly 20 bytes (7.5.4), and a trailer with `/Size`,
`/Root` and `/Info` followed by `startxref` and `%%EOF`.

The page tree is written *after* the pages it lists, because its `/Kids` array
is only known once they are all out. Nothing requires objects to appear in the
file in numeric order -- the xref is what resolves them -- so object 2 is
reserved at the start and emitted at the end.
]]

local Pdf = {}
Pdf.__index = Pdf

--- Catalog, page tree and document information dictionary. Fixed, because
--- every page's `/Parent` has to name the tree before the tree exists.
local ID_CATALOG, ID_PAGES, ID_INFO = 1, 2, 3
local FIRST_FREE_ID = 4

--- A bound, so a runaway caller cannot produce a file no reader will open.
--- Deliberately the same number as `ink_export_source.MAX_PAGES`: a lower cap
--- here would let a notebook pass enumeration and then be refused after
--- thousands of pages had been rasterised and compressed, at which point the
--- commit discards all of it.
local MAX_PAGES = 5000

local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function positiveInteger(v)
    return finite(v) and v >= 1 and v == floor(v)
end

--[[--
A PDF real, to two decimals, without touching the C locale.

`string.format("%.2f", 419.53)` answers "419,53" wherever LC_NUMERIC says a
comma is the decimal separator, and KOReader does not pin LC_NUMERIC. A
MediaBox containing "419,53" is a syntax error in every conforming reader.
]]
local function pdfNumber(v)
    local scaled = floor(v * 100 + 0.5)
    local sign = ""
    if scaled < 0 then
        sign = "-"
        scaled = -scaled
    end
    local whole = floor(scaled / 100)
    local frac = scaled - whole * 100
    if frac == 0 then return sign .. tostring(whole) end
    if frac % 10 == 0 then
        return string.format("%s%d.%d", sign, whole, floor(frac / 10))
    end
    return string.format("%s%d.%02d", sign, whole, frac)
end

--[[--
UTF-8 bytes to codepoints, replacing anything malformed with U+FFFD.

Titles come from a reader who typed them, so they are UTF-8 and may be
anything at all. Overlong forms and surrogates are rejected rather than
re-encoded: both are invalid UTF-8, and passing a surrogate through would
produce an unpaired one in the UTF-16BE output.
]]
local function utf8Codepoints(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local cp, len
        if b < 0x80 then
            cp, len = b, 1
        elseif b >= 0xC2 and b <= 0xDF then
            cp, len = b - 0xC0, 2
        elseif b >= 0xE0 and b <= 0xEF then
            cp, len = b - 0xE0, 3
        elseif b >= 0xF0 and b <= 0xF4 then
            cp, len = b - 0xF0, 4
        else
            cp, len = nil, 1
        end
        -- Bytes actually consumed, which is not the declared length when the
        -- sequence turns out to be truncated. Advancing by the declared
        -- length would eat the byte that broke it: "a\xC3(b)" would lose its
        -- "(" as well. Unicode's recommended practice is to resume at the
        -- offending byte.
        local consumed = len
        if cp and len > 1 then
            if i + len - 1 > n then
                cp, consumed = nil, 1
            else
                for k = 1, len - 1 do
                    local c = s:byte(i + k)
                    if c < 0x80 or c > 0xBF then
                        cp, consumed = nil, k
                        break
                    end
                    cp = cp * 64 + (c - 0x80)
                end
            end
        end
        if cp and ((len == 2 and cp < 0x80) or (len == 3 and cp < 0x800)
            or (len == 4 and cp < 0x10000)) then
            cp = nil -- overlong
        end
        if not cp or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
            cp = 0xFFFD
        end
        out[#out + 1] = cp
        i = i + consumed
    end
    return out
end

local function isPlainAscii(s)
    return s:find("^[\32-\126]*$") ~= nil
end

local function literalString(s)
    return "(" .. s:gsub("([\\()])", "\\%1") .. ")"
end

local function hexUtf16String(s)
    local parts = { "FEFF" }
    local cps = utf8Codepoints(s)
    for i = 1, #cps do
        local cp = cps[i]
        if cp < 0x10000 then
            parts[#parts + 1] = string.format("%04X", cp)
        else
            local v = cp - 0x10000
            parts[#parts + 1] = string.format("%04X%04X",
                0xD800 + floor(v / 0x400), 0xDC00 + (v % 0x400))
        end
    end
    return "<" .. table.concat(parts) .. ">"
end

--- A text string object: literal when it is plainly ASCII, UTF-16BE hex with a
--- BOM otherwise. Both forms are valid everywhere; only the second survives an
--- accent (ISO 32000-1, 7.9.2.2).
local function pdfString(s)
    s = tostring(s or "")
    if isPlainAscii(s) then return literalString(s) end
    return hexUtf16String(s)
end
Pdf.encodeString = pdfString
Pdf.encodeNumber = pdfNumber

--- `D:YYYYMMDDHHmmSS+HH'mm'` (ISO 32000-1, 7.9.4). The offset is explicit
--- because a bare local time is ambiguous and some readers assume UTC.
local function pdfDate(t)
    local off = tonumber(t.offset_minutes) or 0
    local sign = off < 0 and "-" or "+"
    local magnitude = off < 0 and -off or off
    return string.format("(D:%04d%02d%02d%02d%02d%02d%s%02d'%02d')",
        t.year, t.month, t.day, t.hour, t.min, t.sec,
        sign, floor(magnitude / 60), magnitude % 60)
end
Pdf.encodeDate = pdfDate

--- Local wall clock plus its offset from UTC. Injectable, so a test can assert
--- an exact `/CreationDate` and a device keeps telling the truth.
local function systemNow()
    local stamp = os.time()
    local local_t = os.date("*t", stamp)
    local utc_t = os.date("!*t", stamp)
    local_t.isdst = false
    utc_t.isdst = false
    local offset = floor(os.difftime(os.time(local_t), os.time(utc_t)) / 60 + 0.5)
    return {
        year = local_t.year, month = local_t.month, day = local_t.day,
        hour = local_t.hour, min = local_t.min, sec = local_t.sec,
        offset_minutes = offset,
    }
end

--[[--
  opts.write     function(string) -> truthy | nil, err   (required)
  opts.tell      function() -> byte offset of the sink   (optional, checked)
  opts.compress  function(string) -> string              (optional; zlib)
  opts.title     document title, UTF-8
  opts.producer  defaults to "JustDraw"
  opts.now       function() -> { year, month, ..., offset_minutes }
]]
function Pdf.new(opts)
    opts = opts or {}
    if type(opts.write) ~= "function" then return nil, "no_sink" end
    return setmetatable({
        write_fn = opts.write,
        tell_fn = type(opts.tell) == "function" and opts.tell or nil,
        compress = type(opts.compress) == "function" and opts.compress or nil,
        title = opts.title,
        producer = opts.producer or "JustDraw",
        now = type(opts.now) == "function" and opts.now or systemNow,
        offset = 0,
        offsets = {},
        next_id = FIRST_FREE_ID,
        page_ids = {},
        pages = 0,
        started = false,
        finished = false,
        failed = nil,
    }, Pdf)
end

function Pdf:_emit(s)
    if self.failed then return nil, self.failed end
    local ok, err = self.write_fn(s)
    if not ok then
        self.failed = err or "write_failed"
        return nil, self.failed
    end
    self.offset = self.offset + #s
    return true
end

--[[--
Open an indirect object and record where it starts.

The `tell` cross-check is the point of this function. A sink that silently
wrote fewer bytes than it was handed -- a full filesystem, a truncated write --
leaves every subsequent xref entry pointing into the middle of an object, and
the file opens in some readers and not others. Comparing the counted offset
with the handle's own turns that into a clean failure here.
]]
function Pdf:_beginObject(id)
    if self.tell_fn then
        local at = self.tell_fn()
        if type(at) == "number" and at ~= self.offset then
            self.failed = "offset_drift"
            return nil, self.failed
        end
    end
    self.offsets[id] = self.offset
    return self:_emit(id .. " 0 obj\n")
end

function Pdf:_writeObject(id, body)
    local ok, err = self:_beginObject(id)
    if not ok then return nil, err end
    ok, err = self:_emit(body .. "\n")
    if not ok then return nil, err end
    return self:_emit("endobj\n")
end

--- `/Length` is the count of stream bytes only; the EOL before `endstream` is
--- not part of the stream (ISO 32000-1, 7.3.8.1).
function Pdf:_writeStream(id, dict, data)
    local ok, err = self:_beginObject(id)
    if not ok then return nil, err end
    ok, err = self:_emit("<<" .. dict .. "/Length " .. #data .. ">>\nstream\n")
    if not ok then return nil, err end
    ok, err = self:_emit(data)
    if not ok then return nil, err end
    ok, err = self:_emit("\nendstream\n")
    if not ok then return nil, err end
    return self:_emit("endobj\n")
end

--- The binary comment is not decoration: it is what tells a transfer program
--- the file is binary and must not have its line endings rewritten (7.5.2).
function Pdf:_startFile()
    if self.started then return true end
    self.started = true
    return self:_emit("%PDF-1.4\n%\226\227\207\211\n")
end

--[[--
Append one page whose entire content is a greyscale image.

`gray` is exactly `w * h` bytes, one per pixel, 0 = black. That is a BB8's own
layout once it has been copied without padding, which is why the caller
normalises and this module never sees a BlitBuffer or the FFI.

`width_pt`/`height_pt` are the physical page, independent of the pixel count:
a notebook page keeps its millimetres however far the raster was scaled down.
]]
function Pdf:addImagePage(page)
    if self.failed then return nil, self.failed end
    if self.finished then return nil, "finished" end
    if type(page) ~= "table" then return nil, "bad_page" end

    local w, h = tonumber(page.w), tonumber(page.h)
    if not positiveInteger(w) or not positiveInteger(h) then
        return nil, "bad_image_size"
    end
    -- One point, not "greater than zero": `pdfNumber` emits two decimals, so
    -- anything under half a hundredth of a point would round to "0" and
    -- produce a MediaBox no reader can lay out.
    local width_pt, height_pt = tonumber(page.width_pt), tonumber(page.height_pt)
    if not finite(width_pt) or not finite(height_pt)
        or width_pt < 1 or height_pt < 1 then
        return nil, "bad_page_size"
    end
    if type(page.gray) ~= "string" or #page.gray ~= w * h then
        return nil, "bad_image_data"
    end
    if self.pages >= MAX_PAGES then return nil, "too_many_pages" end

    local ok, err = self:_startFile()
    if not ok then return nil, err end

    -- Compression is best-effort by contract: zlib may be absent, and
    -- `zlib_compress` asserts rather than returning an error. An uncompressed
    -- stream is a bigger but equally valid file, so a failure here downgrades
    -- instead of failing the export.
    local data, filter = page.gray, ""
    if self.compress then
        local compressed_ok, compressed = pcall(self.compress, page.gray)
        if compressed_ok and type(compressed) == "string" and #compressed > 0 then
            data, filter = compressed, "/Filter/FlateDecode"
        end
    end

    local content_id = self.next_id
    local image_id = content_id + 1
    local page_id = image_id + 1
    self.next_id = page_id + 1

    local content = table.concat({
        "q\n",
        pdfNumber(width_pt), " 0 0 ", pdfNumber(height_pt), " 0 0 cm\n",
        "/Im0 Do\n",
        "Q\n",
    })
    ok, err = self:_writeStream(content_id, "", content)
    if not ok then return nil, err end

    ok, err = self:_writeStream(image_id, table.concat({
        "/Type/XObject/Subtype/Image",
        "/Width ", tostring(w), "/Height ", tostring(h),
        "/ColorSpace/DeviceGray/BitsPerComponent 8", filter,
    }), data)
    if not ok then return nil, err end

    ok, err = self:_writeObject(page_id, table.concat({
        "<</Type/Page/Parent ", ID_PAGES, " 0 R",
        "/MediaBox[0 0 ", pdfNumber(width_pt), " ", pdfNumber(height_pt), "]",
        "/Resources<</ProcSet[/PDF/ImageB]/XObject<</Im0 ",
        image_id, " 0 R>>>>",
        "/Contents ", content_id, " 0 R>>",
    }))
    if not ok then return nil, err end

    self.pages = self.pages + 1
    self.page_ids[self.pages] = page_id
    return true
end

--[[--
Write the page tree, the catalog, the information dictionary and the xref.

Nothing is buffered until here: the pages are already on disk, and what
remains is the map that lets a reader find them. A file that stops before this
runs is not a shorter PDF, it is not a PDF -- which is why the caller keeps
everything under a temporary name until this returns true.
]]
function Pdf:finish()
    if self.failed then return nil, self.failed end
    if self.finished then return nil, "finished" end
    if self.pages == 0 then
        self.failed = "no_pages"
        return nil, self.failed
    end

    local kids = {}
    for i = 1, self.pages do
        kids[i] = self.page_ids[i] .. " 0 R"
    end
    local ok, err = self:_writeObject(ID_PAGES, table.concat({
        "<</Type/Pages/Kids[", table.concat(kids, " "), "]",
        "/Count ", tostring(self.pages), ">>",
    }))
    if not ok then return nil, err end

    ok, err = self:_writeObject(ID_CATALOG,
        "<</Type/Catalog/Pages " .. ID_PAGES .. " 0 R>>")
    if not ok then return nil, err end

    local info = { "<</Producer ", pdfString(self.producer) }
    if self.title ~= nil and self.title ~= "" then
        info[#info + 1] = "/Title "
        info[#info + 1] = pdfString(self.title)
    end
    info[#info + 1] = "/CreationDate "
    info[#info + 1] = pdfDate(self.now())
    info[#info + 1] = ">>"
    ok, err = self:_writeObject(ID_INFO, table.concat(info))
    if not ok then return nil, err end

    local size = self.next_id
    local xref_at = self.offset
    ok, err = self:_emit("xref\n0 " .. size .. "\n0000000000 65535 f \n")
    if not ok then return nil, err end
    for id = 1, size - 1 do
        local at = self.offsets[id]
        if type(at) ~= "number" then
            self.failed = "missing_object"
            return nil, self.failed
        end
        ok, err = self:_emit(string.format("%010d 00000 n \n", at))
        if not ok then return nil, err end
    end

    ok, err = self:_emit(table.concat({
        "trailer\n<</Size ", tostring(size),
        "/Root ", ID_CATALOG, " 0 R/Info ", ID_INFO, " 0 R>>\n",
        "startxref\n", tostring(xref_at), "\n%%EOF\n",
    }))
    if not ok then return nil, err end

    self.finished = true
    return true
end

function Pdf:pageCount()
    return self.pages
end

function Pdf:isFinished()
    return self.finished == true
end

function Pdf:failure()
    return self.failed
end

return Pdf
