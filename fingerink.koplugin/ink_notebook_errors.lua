--[[--
Normalize internal notebook failures before they reach visual widgets.

Raw SQLite, codec and input reasons remain useful to the logger, but the UI
only consumes the stable codes returned here.
]]

local Errors = {}

local DIRECT = {
    bad_title = "invalid_name",
    bad_geometry = "invalid_geometry",
    no_viewport = "no_viewport",
    contact_active = "contact_active",
    closed = "closed",
    read_only = "schema_newer",
    last_page = "last_page",
    boundary = "boundary",
}

local INPUT = {
    no_stylus_api = true, stylus_callback_busy = true,
    no_gesture_detector = true, no_input = true,
    already_installed = true, handler_error = true,
    input_failed = true, release_failed = true,
}

local OPEN = {
    no_driver = true, open_failed = true, schema_failed = true,
    migration_missing = true, migration_failed = true,
    backup_failed = true, migration_checkpoint_failed = true,
}

function Errors.normalize(reason, context)
    if DIRECT[reason] then return DIRECT[reason] end
    if INPUT[reason] then return "pen_input_failed" end
    if context == "library" or context == "list" then
        return reason == "schema_newer" and "schema_newer" or "library_open_failed"
    elseif context == "create" then
        return reason == "bad_title" and "invalid_name" or "create_failed"
    elseif context == "rename" then
        return reason == "bad_title" and "invalid_name" or "rename_failed"
    elseif context == "delete" or context == "delete_page" then
        return "delete_failed"
    elseif context == "load" or context == "page" then
        return "page_load_failed"
    elseif context == "save" or reason == "save_failed" then
        return "page_save_failed"
    elseif context == "input" then
        return "pen_input_failed"
    end
    if OPEN[reason] then return "library_open_failed" end
    return "operation_failed"
end

return Errors
