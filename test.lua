--[[--
Shim: runs the FingerInk suite from the repository root.

The suite itself lives with the plugin, at fingerink.koplugin/tests/run.lua,
so that `koreader_qa.sh test` discovers it and its LuaJIT syntax sweep covers
it. Resolved relative to this file, not to the working directory.
]]
local here = debug.getinfo(1, "S").source:sub(2)
local root = here:match("^(.*)[/\\][^/\\]*$") or "."
dofile(root .. "/fingerink.koplugin/tests/run.lua")
