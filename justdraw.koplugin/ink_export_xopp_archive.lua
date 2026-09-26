--[[--
gzip through the libarchive KOReader already ships, with every result checked.

A `.xopp` is a gzip stream around one XML document. KOReader bundles
libarchive and wraps it as `Archiver.Writer`, and that wrapper is the obvious
thing to use and the wrong one, for two reasons:

1. `Writer:close()` calls `archive_write_close` and throws the answer away.
   The close is where the gzip filter deflates its last buffered input and
   writes the 8-byte trailer (CRC and length). A card that fills up at that
   moment leaves a truncated stream on disk, and the wrapper reports success;
   the export would then rename a file Xournal++ cannot open into the reader's
   folder, and say "Exported".
2. `Writer:addFileFromMemory` takes the whole payload as one Lua string. A
   notebook's XML is megabytes; holding it as one string on an e-reader is the
   out-of-memory crash the rest of the export is built to avoid.

So this is a private adapter over the same library: the `raw` format with the
`gzip` filter (one entry, no container around it), a header that declares the
size the caller measured, `archive_write_data` in blocks with every return
compared with what was handed over, and then `archive_write_close` *and*
`archive_write_free`, both checked. Nothing else of libarchive is used.

Declarations are KOReader's own (`ffi/libarchive_h`), so nothing here can
disagree with them about a type. The one function that file does not declare
is `archive_write_free`; it is declared here, with archive.h's exact
prototype, and only when it is missing -- `struct archive` stays KOReader's
opaque type, and LuaJIT accepts an identical redeclaration if a later
KOReader adds it. `Archive.available()` is the conformance check: every symbol
the adapter calls must resolve in *this* build, or no export is attempted.

Every C call is synchronous. The caller bounds how much it hands over per
scheduler turn; tests/xopp_archive_native.lua measures what one block costs
on a real build.

`opts.backend` replaces the library with a table of the same functions, which
is how the specs make each call fail in turn -- header, a short write, the
close, the free -- without a disk that fills on cue.
]]

local Archive = {}

--- Every symbol the adapter calls. `available()` resolves each one.
Archive.REQUIRED = {
    "archive_write_new", "archive_write_set_format_by_name",
    "archive_write_add_filter_by_name", "archive_write_open_filename",
    "archive_entry_new", "archive_entry_free", "archive_entry_set_pathname",
    "archive_entry_set_filetype", "archive_entry_set_perm",
    "archive_entry_set_size", "archive_entry_set_mtime",
    "archive_write_header", "archive_write_data", "archive_write_close",
    "archive_write_free", "archive_error_string",
}

--- The largest block one `write` accepts. Deflate cost is linear in it, and
--- it is what bounds a single synchronous C call.
Archive.MAX_BLOCK = 65536

--- gzip's fixed header (10) and trailer (8): nothing shorter is a stream.
Archive.MIN_SIZE = 18

--- The entry's name. A raw archive does not write it anywhere; libarchive
--- still wants one for the header.
Archive.ENTRY_NAME = "document.xml"

local floor = math.floor

local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

-- ------------------------------------------------------------------ backend

local cached_backend, cached_err

--[[--
KOReader's libarchive, with its declarations, or nil plus why not.

Loaded lazily and once: the suite runs without KOReader, and a reader who
never exports to Xournal++ never pays for the library.
]]
function Archive.load()
    if cached_backend then return cached_backend end
    if cached_err then return nil, cached_err end
    local ok, backend = pcall(function()
        local ffi = require("ffi")
        -- `ffi.loadlib` is installed by this module; `ffi/archiver` relies on
        -- setupkoenv having loaded it, which is true in KOReader and not in
        -- a bare script.
        require("ffi/loadlib")
        local lib = ffi.loadlib("archive", "13")
        require("ffi/libarchive_h")
        if not pcall(function() return lib.archive_write_free end) then
            ffi.cdef("int archive_write_free(struct archive *);")
        end
        return {
            lib = lib,
            cstring = function(p)
                if p == nil then return nil end
                return ffi.string(p)
            end,
        }
    end)
    if not ok then
        cached_err = tostring(backend)
        return nil, cached_err
    end
    cached_backend = backend
    return backend
end

--[[--
Whether every symbol the adapter needs resolves in this build.

Answers true, or nil, "archive_unavailable" and the first missing name. A
symbol that is declared but absent from the shared object raises on first
index in LuaJIT, which is why each is touched inside a pcall rather than
trusted from the declaration file.
]]
function Archive.available(backend)
    local load_err
    if not backend then backend, load_err = Archive.load() end
    if not backend then return nil, "archive_unavailable", load_err end
    local lib = backend.lib
    for i = 1, #Archive.REQUIRED do
        local name = Archive.REQUIRED[i]
        local ok, fn = pcall(function() return lib[name] end)
        if not ok or fn == nil then
            return nil, "archive_unavailable", name
        end
    end
    return true
end

-- ------------------------------------------------------------------- writer

local Writer = {}
Writer.__index = Writer

local function errorString(self)
    local ok, text = pcall(function()
        return self.cstring(self.lib.archive_error_string(self.a))
    end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return nil
end

--- Tear down after a failure. The free's answer is not interesting here: the
--- stream is already broken and the caller discards the file.
function Writer:_release()
    local lib = self.lib
    if self.entry ~= nil then
        pcall(lib.archive_entry_free, self.entry)
        self.entry = nil
    end
    if self.a ~= nil then
        pcall(lib.archive_write_free, self.a)
        self.a = nil
    end
end

function Writer:_fail(stage)
    local detail = errorString(self)
    self.failed = stage .. (detail and (": " .. detail) or "")
    self:_release()
    return nil, "archive_failed", self.failed
end

--[[--
Open `path` for a gzip stream of exactly `opts.size` bytes of payload.

  opts.size     the payload length, measured beforehand (required)
  opts.mtime    entry time; default now
  opts.backend  { lib, cstring } in place of KOReader's library

Returns the writer, or nil, reason, detail. libarchive creates the file; the
caller removes it on any failure, including this one.
]]
function Archive.open(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or path == "" then return nil, "bad_path" end
    local size = opts.size
    if not finite(size) or size < 0 or size ~= floor(size) then
        return nil, "bad_size"
    end
    local backend, load_err = opts.backend, nil
    if not backend then backend, load_err = Archive.load() end
    if not backend then return nil, "archive_unavailable", load_err end
    local lib = backend.lib
    local OK = tonumber(lib.ARCHIVE_OK) or 0

    local self = setmetatable({
        lib = lib, cstring = backend.cstring or tostring, OK = OK,
        expected = size, written = 0, closed = false,
    }, Writer)

    local called, a = pcall(lib.archive_write_new)
    if not called or a == nil then return nil, "archive_failed", "archive_write_new" end
    self.a = a
    if lib.archive_write_set_format_by_name(a, "raw") ~= OK then
        return self:_fail("format")
    end
    if lib.archive_write_add_filter_by_name(a, "gzip") ~= OK then
        return self:_fail("filter")
    end
    if lib.archive_write_open_filename(a, path) ~= OK then
        return self:_fail("open")
    end

    local entry = lib.archive_entry_new()
    if entry == nil then return self:_fail("entry") end
    self.entry = entry
    lib.archive_entry_set_pathname(entry, Archive.ENTRY_NAME)
    lib.archive_entry_set_filetype(entry, tonumber(lib.AE_IFREG) or 32768)
    lib.archive_entry_set_perm(entry, 420) -- 0644
    lib.archive_entry_set_size(entry, size)
    lib.archive_entry_set_mtime(entry, opts.mtime or os.time(), 0)
    if lib.archive_write_header(a, entry) ~= OK then
        return self:_fail("header")
    end
    lib.archive_entry_free(entry)
    self.entry = nil
    return self
end

--[[--
Compress one block. The answer must be exactly the block's length: libarchive
reports a failed write as -1 (ARCHIVE_FATAL), and anything else short is still
data that did not go where the header said it would.

More than the header declared is refused before it reaches C: the size is a
promise the caller made, and breaking it is a caller bug worth stopping on.
]]
function Writer:write(block)
    if self.a == nil then return nil, "archive_failed", self.failed or "closed" end
    if type(block) ~= "string" then return nil, "bad_block" end
    local len = #block
    if len == 0 then return true end
    if len > Archive.MAX_BLOCK then return nil, "bad_block" end
    if self.written + len > self.expected then
        self:_release()
        self.failed = "size"
        return nil, "archive_failed", "more data than the header declared"
    end
    local ok, n = pcall(self.lib.archive_write_data, self.a, block, len)
    if not ok then return self:_fail("write") end
    if tonumber(n) ~= len then return self:_fail("short write") end
    self.written = self.written + len
    return true
end

--[[--
Finish the stream: the trailer is written here, so here is where a full disk
finally shows. Both the close and the free are checked -- the free is the last
point at which libarchive can report the close of the underlying file.
]]
function Writer:close()
    if self.closed then return true end
    if self.a == nil then return nil, "archive_failed", self.failed or "closed" end
    if self.written ~= self.expected then
        self:_release()
        self.failed = "size"
        return nil, "archive_failed", "less data than the header declared"
    end
    local lib, a = self.lib, self.a
    local closed_ok, closed = pcall(lib.archive_write_close, a)
    local detail
    if not closed_ok or closed ~= self.OK then detail = errorString(self) end
    -- Freed whatever the close said: the handle is spent either way.
    self.a = nil
    local freed_ok, freed = pcall(lib.archive_write_free, a)
    if not closed_ok or closed ~= self.OK then
        self.failed = "close" .. (detail and (": " .. detail) or "")
        return nil, "archive_failed", self.failed
    end
    if not freed_ok or freed ~= self.OK then
        self.failed = "free"
        return nil, "archive_failed", self.failed
    end
    self.closed = true
    return true
end

--- Release without finishing. Idempotent; for cancellation and failures.
function Writer:abort()
    self:_release()
    return true
end

function Writer:bytesWritten()
    return self.written
end

-- ------------------------------------------------------------- verification

local function le32(s, at)
    local a, b, c, d = s:byte(at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

--[[--
Read back what is on disk and check it is a finished gzip of the right length.

The magic and method at the front, and at the end the trailer's ISIZE -- the
payload length modulo 2^32 -- which a truncated stream does not have in the
right place. Cheap: two small reads, however large the file is. Every check
the adapter made on the way in is a claim about calls; this is the claim about
the file.

`fs.open` must give a handle with `read`, `seek` and `close` (io.open does).
]]
function Archive.verify(path, expected_size, fs)
    fs = fs or { open = io.open }
    local handle = fs.open(path, "rb")
    if not handle then return nil, "archive_invalid", "unreadable" end
    local ok, err = pcall(function()
        local head = handle:read(10)
        if type(head) ~= "string" or #head < 10 then error("short header", 0) end
        local b1, b2, method = head:byte(1, 3)
        if b1 ~= 0x1f or b2 ~= 0x8b or method ~= 8 then error("not gzip", 0) end
        local size = handle:seek("end")
        if not finite(size) or size < Archive.MIN_SIZE then error("too short", 0) end
        handle:seek("set", size - 8)
        local tail = handle:read(8)
        if type(tail) ~= "string" or #tail ~= 8 then error("short trailer", 0) end
        local isize = le32(tail, 5)
        if isize ~= expected_size % 4294967296 then
            error("trailer length " .. isize .. " for " .. expected_size, 0)
        end
    end)
    pcall(handle.close, handle)
    if not ok then return nil, "archive_invalid", tostring(err) end
    return true
end

Archive.Writer = Writer

return Archive
