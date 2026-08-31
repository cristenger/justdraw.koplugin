--[[--
Hand the exported PDF to two programs that share nothing with the writer, and
see whether they agree it is a PDF.

Everything else that reads these files has a stake in them. `export_pdf_spec`
parses what it needs and was written from the same understanding of ISO 32000-1
as the writer, so a misreading of the standard is invisible to it; MuPDF in
`conformance.lua` is generous by design, because a reader that refused damaged
files would be useless on the web. `qpdf --check` is neither: it walks the
whole structure and reports what it does not like, which is the only thing here
that can find a defect nobody has thought of.

The second half is orientation. That image row 0 lands at the *top* of the page
is an assumption baked into one `cm` matrix, and until now it was pinned only
as a string: change the matrix and the spec fails with a diff, not with an
upside-down page. Rendering a pattern whose four quadrants are four different
greys and reading the pixels back is what turns that into an actual claim --
any flip, rotation or transposition moves at least one quadrant, and only the
identity leaves all four where they were.

Deliberately outside `tests/run.lua`. The suite must keep running on a machine
with nothing but LuaJIT, which is the whole reason these two checks were
deferred in the first place; here they are a separate gate that skips honestly
when the tools are missing, and that CI runs with STRICT so it cannot skip.

  luajit justdraw.koplugin/tests/pdf_external_check.lua
  JUSTDRAW_PDF_EXTERNAL_STRICT=1 ...   tool absent becomes a failure
  JUSTDRAW_PDF_EXTERNAL_KEEP=1 ...     leave the fixtures behind to look at
]]

local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local Pdf = require("ink_export_pdf")

local rows = {}
local function claim(name, checkable, ok, detail)
    if not checkable then
        rows[#rows + 1] = { "UNCHECKABLE", name, detail or "tool absent" }
    elseif ok then
        rows[#rows + 1] = { "OK", name, detail or "" }
    else
        rows[#rows + 1] = { "MISMATCH", name, detail or "" }
    end
end

-- ------------------------------------------------------------------- tools

--[[--
`os.execute` under Lua 5.1 answers the raw `wait` status, not the exit code.

qpdf's three outcomes -- 0 clean, 2 errors, 3 warnings only -- are the whole
point of running it, so collapsing them to "non-zero" would throw away the
distinction this gate exists to make.
]]
local function exitCode(raw)
    if type(raw) == "boolean" then return raw and 0 or 1 end
    local code = tonumber(raw) or 1
    if code >= 256 then return math.floor(code / 256) end
    return code
end

local function haveTool(name)
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null")
    if not pipe then return false end
    local found = pipe:read("*l")
    pipe:close()
    return found ~= nil and found ~= ""
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--[[--
zlib through the FFI, because `ffi/zlib` belongs to KOReader and this harness
runs without it.

The round trip on the way in is not ceremony. A binding that produced a broken
stream would make `qpdf` blame the PDF writer for a defect of the harness, and
the whole value of this file is that it points at the right thing.
]]
local function newCompressor()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, "ffi unavailable" end
    local loaded, z = pcall(ffi.load, "z")
    if not loaded then return nil, "libz could not be loaded" end
    pcall(ffi.cdef, [[
        unsigned long compressBound(unsigned long sourceLen);
        int compress2(unsigned char *dest, unsigned long *destLen,
                      const unsigned char *source, unsigned long sourceLen, int level);
        int uncompress(unsigned char *dest, unsigned long *destLen,
                       const unsigned char *source, unsigned long sourceLen);
    ]])
    local function deflate(s)
        local bound = tonumber(z.compressBound(#s))
        local dest = ffi.new("unsigned char[?]", bound)
        local dlen = ffi.new("unsigned long[1]", bound)
        if z.compress2(dest, dlen, s, #s, 9) ~= 0 then return nil end
        return ffi.string(dest, dlen[0])
    end
    local probe = string.rep("justdraw", 512)
    local packed = deflate(probe)
    if not packed then return nil, "compress2 failed" end
    local back = ffi.new("unsigned char[?]", #probe)
    local blen = ffi.new("unsigned long[1]", #probe)
    if z.uncompress(back, blen, packed, #packed) ~= 0
        or ffi.string(back, blen[0]) ~= probe then
        return nil, "libz round trip failed"
    end
    return deflate
end

-- ---------------------------------------------------------------- fixtures

--[[--
Four quadrants, four distinct greys.

Any flip, quarter turn or transposition moves at least one of them; the
identity is the only transformation that leaves all four in place. Two values
would only catch a vertical flip, which is the mistake this is looking for but
not the only one worth catching.
]]
local function quadrants(w, h)
    local rows_out = {}
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            local top, left = y < h / 2, x < w / 2
            local v
            if top and left then v = 0
            elseif top then v = 85
            elseif left then v = 170
            else v = 255 end
            row[#row + 1] = string.char(v)
        end
        rows_out[#rows_out + 1] = table.concat(row)
    end
    return table.concat(rows_out)
end

--- Ten points per image pixel, rendered at 72 dpi: every source pixel becomes
--- exactly ten device pixels square, so nothing is resampled and a quadrant
--- centre is the source value, not an average of its neighbours.
local PT_PER_PIXEL = 10

local function writeFixture(path, pages, compress)
    local out, open_err = io.open(path, "wb")
    if not out then return nil, tostring(open_err) end
    local pdf, pdf_err = Pdf.new{
        write = function(s) return out:write(s) end,
        tell = function() return out:seek() end,
        compress = compress,
        title = "JustDraw external check",
        -- A fixed clock: a fixture that differs between runs is a fixture
        -- whose failures cannot be compared.
        now = 1756512000,
    }
    if not pdf then out:close() return nil, tostring(pdf_err) end
    for i = 1, #pages do
        local w, h = pages[i][1], pages[i][2]
        local ok, err = pdf:addImagePage{
            w = w, h = h, gray = quadrants(w, h),
            width_pt = w * PT_PER_PIXEL, height_pt = h * PT_PER_PIXEL,
        }
        if not ok then out:close() return nil, tostring(err) end
    end
    local ok, err = pdf:finish()
    out:close()
    if not ok then return nil, tostring(err) end
    return true
end

-- --------------------------------------------------------------------- PGM

--[[--
A binary PGM, read by hand.

`pdftoppm -gray` writes P5: three integers with `#` comments possible between
them, and then **exactly one** whitespace byte before the first sample.
Miscounting that byte shifts the whole image by one and turns an orientation
check into noise -- which is how the first version of this parser reported the
header's newline as the top-left pixel.
]]
local function readPGM(path)
    local data = readAll(path)
    if not data then return nil, "cannot open " .. path end
    if data:sub(1, 2) ~= "P5" then return nil, "not a binary PGM" end
    local pos, nums = 3, {}
    while #nums < 3 do
        local c = data:sub(pos, pos)
        if c == "" then return nil, "truncated PGM header" end
        if c == "#" then
            pos = (data:find("\n", pos, true) or #data) + 1
        elseif c:match("%s") then
            pos = pos + 1
        else
            local s, e, tok = data:find("^(%d+)", pos)
            if not s then return nil, "malformed PGM header" end
            nums[#nums + 1] = tonumber(tok)
            pos = e + 1
        end
    end
    local img = { w = nums[1], h = nums[2], max = nums[3],
                  data = data, base = pos + 1 }
    if img.max ~= 255 then return nil, "expected 8-bit samples" end
    if #img.data - img.base + 1 ~= img.w * img.h then
        return nil, string.format("%d samples for a %dx%d image",
            #img.data - img.base + 1, img.w, img.h)
    end
    function img:at(x, y) return self.data:byte(self.base + y * self.w + x) end
    return img
end

--- The centre of each quadrant, not the corner: a corner pixel depends on how
--- the renderer treats the edge of the MediaBox, which is not what is being
--- claimed here.
local function checkOrientation(img)
    local qx, qy = math.floor(img.w / 4), math.floor(img.h / 4)
    local seen = {
        img:at(qx, qy), img:at(img.w - qx, qy),
        img:at(qx, img.h - qy), img:at(img.w - qx, img.h - qy),
    }
    local want = { 0, 85, 170, 255 }
    local names = { "top-left", "top-right", "bottom-left", "bottom-right" }
    for i = 1, 4 do
        if math.abs(seen[i] - want[i]) > 2 then
            return nil, string.format(
                "%s is %d, expected %d -- the image is not upright",
                names[i], seen[i], want[i])
        end
    end
    return true
end

-- ------------------------------------------------------------------- setup

local strict = os.getenv("JUSTDRAW_PDF_EXTERNAL_STRICT") == "1"
local keep = os.getenv("JUSTDRAW_PDF_EXTERNAL_KEEP") == "1"

math.randomseed(os.time())
local work = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    .. "/justdraw-pdf-check-" .. os.time() .. "-" .. math.random(100000, 999999)
os.execute("mkdir -p '" .. work .. "'")

local have_qpdf = haveTool("qpdf")
local have_pdftoppm = haveTool("pdftoppm")
local deflate, zlib_why = newCompressor()

--- Every fixture: name, pages as {image_w, image_h}, and whether it is Flate.
local FIXTURES = {
    { name = "plain", pages = { { 8, 12 } }, compressed = false },
    { name = "flate", pages = { { 8, 12 } }, compressed = true },
    -- Three different page sizes: a MediaBox copied from the first page shows
    -- up here and nowhere else.
    { name = "mixed", pages = { { 8, 12 }, { 12, 8 }, { 6, 6 } }, compressed = true },
}

local built = {}
for i = 1, #FIXTURES do
    local fixture = FIXTURES[i]
    local path = work .. "/" .. fixture.name .. ".pdf"
    if fixture.compressed and not deflate then
        claim("fixture " .. fixture.name .. " could be written",
            false, false, zlib_why or "no compressor")
    else
        local ok, err = writeFixture(path, fixture.pages,
            fixture.compressed and deflate or nil)
        claim("fixture " .. fixture.name .. " could be written", true, ok, ok and "" or err)
        if ok then built[fixture.name] = { path = path, pages = fixture.pages } end
    end
end

-- ------------------------------------------------------------------- qpdf

--[[--
`--check` walks structure, encryption, linearisation and stream encoding.

Exit 0 is the only pass. qpdf answers 2 for errors and 3 for warnings without
errors, and for a writer this project controls a warning is a defect: nothing
about these files is a legacy shape someone else produced.
]]
for i = 1, #FIXTURES do
    local name = FIXTURES[i].name
    local fixture = built[name]
    local checkable = have_qpdf and fixture ~= nil
    if not checkable then
        claim("qpdf --check accepts the " .. name .. " export", false, false,
            have_qpdf and "fixture missing" or "qpdf not installed")
    else
        local log = work .. "/" .. name .. "-qpdf.txt"
        local code = exitCode(os.execute(
            "qpdf --check '" .. fixture.path .. "' > '" .. log .. "' 2>&1"))
        local detail = ""
        if code ~= 0 then
            detail = string.format("exit %d: %s", code,
                (readAll(log) or ""):gsub("%s+", " "):sub(1, 160))
        end
        claim("qpdf --check accepts the " .. name .. " export", true, code == 0, detail)
    end
end

-- --------------------------------------------------------------- rendering

local function renderPage(pdf_path, page_no, root)
    local code = exitCode(os.execute(table.concat({
        "pdftoppm -gray -r 72 ",
        "-f ", tostring(page_no), " -l ", tostring(page_no), " ",
        -- Without -singlefile poppler numbers the output with a width derived
        -- from the page count, so the name is not predictable from here.
        "-singlefile '", pdf_path, "' '", root, "' 2>/dev/null",
    })))
    if code ~= 0 then return nil, "pdftoppm exit " .. code end
    return readPGM(root .. ".pgm")
end

for i = 1, #FIXTURES do
    local fixture = FIXTURES[i]
    local entry = built[fixture.name]
    local checkable = have_pdftoppm and entry ~= nil
    if not checkable then
        claim("the " .. fixture.name .. " export renders upright", false, false,
            have_pdftoppm and "fixture missing" or "pdftoppm not installed")
    else
        local ok, detail = true, ""
        for page_no = 1, #entry.pages do
            local root = work .. "/" .. fixture.name .. "-p" .. page_no
            local img, err = renderPage(entry.path, page_no, root)
            if not img then
                ok, detail = false, "page " .. page_no .. ": " .. tostring(err)
                break
            end
            -- The page is width_pt x height_pt at 72 dpi, and a point is a
            -- device pixel there, so the render's own size states whether
            -- each page kept its own MediaBox.
            local want_w = entry.pages[page_no][1] * PT_PER_PIXEL
            local want_h = entry.pages[page_no][2] * PT_PER_PIXEL
            if img.w ~= want_w or img.h ~= want_h then
                ok = false
                detail = string.format("page %d rendered %dx%d, expected %dx%d",
                    page_no, img.w, img.h, want_w, want_h)
                break
            end
            local upright, why = checkOrientation(img)
            if not upright then
                ok, detail = false, "page " .. page_no .. ": " .. tostring(why)
                break
            end
        end
        claim("the " .. fixture.name .. " export renders upright", true, ok, detail)
    end
end

-- ------------------------------------------------------------------ report

if not keep then os.execute("rm -rf '" .. work .. "'") end

for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-56s %s\n", r[1], r[2], r[3]))
end

local bad, uncheckable = 0, 0
for _, r in ipairs(rows) do
    if r[1] == "MISMATCH" then bad = bad + 1
    elseif r[1] == "UNCHECKABLE" then uncheckable = uncheckable + 1 end
end
if strict then bad = bad + uncheckable end

io.write(string.format("\n%d claims, %d failures", #rows, bad))
if uncheckable > 0 then
    io.write(string.format(" (%d uncheckable%s)", uncheckable,
        strict and ", counted because STRICT is set" or ""))
end
io.write("\n")
if keep then io.write("fixtures kept in " .. work .. "\n") end
os.exit(bad == 0 and 0 or 1)
