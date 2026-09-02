--[[--
Compatibility helpers for the FingerInk -> JustDraw rename.

Branding and all newly-created state use `justdraw`. Existing installations
may still have settings, document ink, or SQLite databases under the former
`fingerink` identity. Scalar reads migrate forward without deleting the old
value; potentially large direct-ink data and databases keep using one existing
legacy identity in place. Database selection refuses ambiguous
current-plus-legacy histories, so the rename never guesses or risks an
interrupted multi-file SQLite move.
]]

local Compat = {
    current_id = "justdraw",
    legacy_id = "fingerink",
}

local function settingKey(id, suffix)
    return id .. "_" .. suffix
end

--- Read a JustDraw setting and fall back once to the legacy FingerInk key.
--- The migrated value is copied to the current key immediately. `false` is a
--- valid value, so only nil means absent.
function Compat.readSetting(settings, suffix, default)
    local current_key = settingKey(Compat.current_id, suffix)
    local value = settings:readSetting(current_key)
    if value == nil then
        value = settings:readSetting(settingKey(Compat.legacy_id, suffix))
        if value ~= nil then settings:saveSetting(current_key, value) end
    end
    if value == nil then return default end
    return value
end

--- Select one key for structured user data and keep using it in place. This
--- avoids duplicating a potentially large stroke table inside LuaSettings.
--- New documents use JustDraw; upgraded documents with only a legacy key keep
--- that key; if both exist, the current key is authoritative and neither is
--- merged into the other.
function Compat.readDataSetting(settings, suffix, default)
    local current_key = settingKey(Compat.current_id, suffix)
    local value = settings:readSetting(current_key)
    if value ~= nil then return value, Compat.current_id, true end
    value = settings:readSetting(settingKey(Compat.legacy_id, suffix))
    if value ~= nil then return value, Compat.legacy_id, true end
    return default, Compat.current_id, false
end

function Compat.saveDataSetting(settings, suffix, storage_id, value)
    local id = storage_id == Compat.legacy_id
        and Compat.legacy_id or Compat.current_id
    settings:saveSetting(settingKey(id, suffix), value)
end

function Compat.saveSetting(settings, suffix, value)
    settings:saveSetting(settingKey(Compat.current_id, suffix), value)
end

--- Delete both identities. Otherwise clearing ink migrated from the legacy
--- sidecar would make it reappear on the next document open.
function Compat.delSetting(settings, suffix)
    settings:delSetting(settingKey(Compat.current_id, suffix))
    settings:delSetting(settingKey(Compat.legacy_id, suffix))
end

local function readableFileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function fileExists(path)
    -- A database may exist without being readable. In that case it must still
    -- be selected so Repository.open reports the real failure instead of
    -- silently creating a second, empty history under the other name.
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        local called, mode = pcall(lfs.attributes, path, "mode")
        if called then return mode ~= nil end
    end
    -- Bare Lua tests do not necessarily have KOReader's lfs module.
    return readableFileExists(path)
end

-- ---------------------------------------------------------- capabilities

--[[--
What this KOReader can do, asked of the runtime rather than of its version
string (ADR-41).

A version string is the wrong question twice over: a nightly, a fork or a
patched build carries one that says nothing about what is in it, and the
answer would still have to be re-derived every time a capability moved. So
each of the four is a direct probe of the thing the code is about to call.

Only `stylus_api` decides anything. It is the pair that exists from 2026.07
and nowhere before it, and it is what `Capture:supportsStylus()` gates every
new surface on. The other three exist in both runtimes; they are probed so an
unusual build fails loudly at start-up instead of half-working, and
`assertCapabilities` is that loud failure, never a gate.

Every dependency is injectable, because the probe's whole job is to describe a
runtime that may not have them: a field left `nil` is resolved by a guarded
`require`, and a field set to `false` means "this one is not here". Nothing in
here may raise -- it runs in `init`, before there is any reader to tell.
]]
local function optionalModule(name)
    local ok, module = pcall(require, name)
    if ok then return module end
    return nil
end

--- `t[key]` is a function -- for any `t`, including one whose `__index`
--- raises, which is what a half-loaded module looks like from here.
local function isFunction(t, key)
    if type(t) ~= "table" then return false end
    local read, value = pcall(function() return t[key] end)
    return read and type(value) == "function"
end

--[[--
Whether a transparent overlay can be composed onto the page at all.

Three separate things have to hold, and a missing one has a different symptom:
without `TYPE_BB8A` there is no overlay to draw into, without `Color8A` there
is no transparent pixel to clear it with, and without `alphablitFrom` the
overlay reaches the screen through `blitFrom`, which copies alpha 0 as black
and paints a rectangle over the reader's book.

Probed on a real 1x1 buffer rather than by reading the module: `alphablitFrom`
lives on the buffer's metatype, not on the module table. The buffer is freed
again -- this runs once per plugin instance, and a leaked allocation per book
is still a leak. A colour is cdata whose `__eq` indexes its argument, so
`rawequal` is the only safe nil test here.
]]
local function alphaBlitSupported(Blitbuffer)
    if type(Blitbuffer) ~= "table" then return false end
    local read, bb8a = pcall(function() return Blitbuffer.TYPE_BB8A end)
    if not read or type(bb8a) ~= "number" then return false end

    local made, color = pcall(function() return Blitbuffer.Color8A(0, 0) end)
    if not made or rawequal(color, nil) then return false end

    local built, bb = pcall(function() return Blitbuffer.new(1, 1, bb8a) end)
    if not built or rawequal(bb, nil) then return false end
    local got, blitter = pcall(function() return bb.alphablitFrom end)
    pcall(function() if bb.free then bb:free() end end)
    return got and type(blitter) == "function"
end

function Compat.capabilities(env)
    env = env or {}

    local input = env.input
    if input == nil then
        local device = optionalModule("device")
        input = type(device) == "table" and device.input or nil
    end
    local ReaderView = env.ReaderView
    if ReaderView == nil then
        ReaderView = optionalModule("apps/reader/modules/readerview")
    end
    local Document = env.Document
    if Document == nil then Document = optionalModule("document/document") end
    local Blitbuffer = env.Blitbuffer
    if Blitbuffer == nil then Blitbuffer = optionalModule("ffi/blitbuffer") end

    return {
        stylus_api = isFunction(input, "registerStylusCallback")
            and isFunction(input, "unregisterStylusCallback"),
        view_transform = isFunction(ReaderView, "screenToPageTransform")
            and isFunction(ReaderView, "pageToScreenTransform"),
        native_dimensions = isFunction(Document, "getNativePageDimensions"),
        alpha_blit = alphaBlitSupported(Blitbuffer),
    }
end

--- The one discriminator between the two runtimes (ADR-41). Deliberately
--- reads nothing else: a build missing one of the other three is a build to
--- complain about, not a build to fall back to v2026.03 behaviour on.
function Compat.fullSupport(caps)
    return type(caps) == "table" and caps.stylus_api == true
end

--- The other three, for a start-up log. Answers `true`, or nil and the name
--- of the first capability missing. Never a gate: what it reports is a
--- runtime nobody expected, and the reader is better served by a warning in
--- the log than by a feature silently switching itself off.
function Compat.assertCapabilities(caps)
    if type(caps) ~= "table" then return nil, "capabilities" end
    if not caps.view_transform then return nil, "view_transform" end
    if not caps.native_dimensions then return nil, "native_dimensions" end
    if not caps.alpha_blit then return nil, "alpha_blit" end
    return true
end

--- New installations create the JustDraw filename. Upgrades continue using
--- an existing legacy database when no current database exists. Keeping the
--- file in place also keeps any SQLite -wal/-shm companions correctly paired.
function Compat.databasePath(settings_dir, current_filename, legacy_filename, exists)
    exists = exists or fileExists
    local current = settings_dir .. "/" .. current_filename
    local legacy = settings_dir .. "/" .. legacy_filename
    local current_exists = exists(current)
    local legacy_exists = exists(legacy)
    if current_exists and legacy_exists then
        return nil, "database_conflict", current, legacy
    end
    if current_exists then return current end
    if legacy_exists then return legacy end
    return current
end

return Compat
