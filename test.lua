--[[--
Shim: runs the JustDraw suite from the repository root.

The suite itself lives with the plugin, at justdraw.koplugin/tests/run.lua,
so that `koreader_qa.sh test` discovers it and its LuaJIT syntax sweep covers
it. Resolved relative to this file, not to the working directory.
]]
local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)[/\\][^/\\]*$") or "."
dofile(root .. "/justdraw.koplugin/tests/run.lua")
