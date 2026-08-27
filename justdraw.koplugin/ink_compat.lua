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
