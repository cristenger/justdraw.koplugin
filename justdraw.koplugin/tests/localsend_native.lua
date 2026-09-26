--[[--
LocalSend staging against the real file system (Task 11.1).

The suite's file system is a table. It cannot say whether `lfs` really
reports a link as a link without following it, whether removing a folder
that still holds a file fails, or whether the manifest survives a real
write and read. This does, in a fresh temporary folder, with real links.

    cd <koreader>/lib/koreader && ./luajit <repo>/justdraw.koplugin/tests/localsend_native.lua

Prints LOCALSEND_NATIVE_OK and exits 0 when every check passes.
]]
require("setupkoenv")
local here = debug.getinfo(1, "S").source:sub(2)
local root = assert(here:match("^(.*)/tests/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path
local lfs = require("libs/libkoreader-lfs")
local LocalSend = require("ink_localsend")

local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local tmp = os.getenv("TMPDIR") or "/tmp"
local base = string.format("%s/jd-send-native-%d-%d", tmp, os.time(), math.random(1, 1e6))
assert(lfs.mkdir(base))
local send_root = base .. "/justdraw-send"
local outside = base .. "/outside"
assert(lfs.mkdir(outside))
local precious = outside .. "/precious.pdf"
local f = assert(io.open(precious, "wb")); f:write("keep me"); f:close()

local clock = os.time()
local fs = LocalSend.nativeFs()
local first = LocalSend.staging{ root = send_root, fs = fs, token = "aaaa",
    now = function() return clock end }
local op = assert(first:begin())
check(lfs.attributes(op.dir, "mode") == "directory", "the operation's folder exists")
local path = op.dir .. "/Notes.pdf"
f = assert(io.open(path, "wb")); f:write("pdf"); f:close()
assert(op:record(path))
check(LocalSend.parseManifest(fs.read(op.dir .. "/.justdraw-send")).files[1] == "Notes.pdf",
    "the manifest round-trips through a real file")
check(op:target() == path, "one file is handed by path")

-- A link inside the root, pointing outside, named like an operation, with a
-- forged manifest beside what it points at: never followed, never removed.
local link = send_root .. "/op-1-aaaa-9"
os.execute(string.format("ln -s '%s' '%s'", outside, link))
check(fs.lstat(link) and fs.lstat(link).mode == "link", "lstat reports the link as a link")
f = assert(io.open(outside .. "/.justdraw-send", "wb"))
f:write("justdraw-send 1\ntoken aaaa\ncreated 1\nfile precious.pdf\n"); f:close()

-- A new process, a day later.
clock = clock + 2 * 24 * 3600
local second = LocalSend.staging{ root = send_root, fs = fs, token = "bbbb",
    now = function() return clock end }
-- The folder's own time is now; age it the way a day would.
os.execute(string.format("touch -d '@%d' '%s'", clock - 2 * 24 * 3600, op.dir))
local report = second:sweep()
check(lfs.attributes(precious, "mode") == "file", "nothing outside the root was touched through the link")
check(lfs.symlinkattributes(link, "mode") == "link", "the link itself stays")
check(report.kept["op-1-aaaa-9"] == "not_a_folder", "and is reported as not ours to sweep")
check(lfs.attributes(op.dir, "mode") == nil, "the old operation was swept: " .. tostring(report.kept[op.name]))

-- A folder with a file the manifest does not list keeps that file and itself.
local op2 = assert(second:begin())
local stranger = op2.dir .. "/stranger.txt"
f = assert(io.open(stranger, "wb")); f:write("x"); f:close()
op2:abandon()
check(lfs.attributes(stranger, "mode") == "file", "abandon removes only what it wrote")
check(lfs.attributes(op2.dir, "mode") == "directory", "and a non-empty folder stays")

os.execute(string.format("rm -rf '%s'", base))
print(string.format("LOCALSEND_NATIVE_OK %d checks", checks))
