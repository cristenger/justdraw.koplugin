--[[--
Sending notebooks with LocalSend, when it is installed (Phase 11, ADR-60).

Three parts, each with one rule it must not break.

**Finding it.** LocalSend is another plugin and may not be there, may be
there in recovery mode (a failed update, a missing binary), or may have been
recreated with the reader. So it is looked up every time it is needed -- on
the reader's `ui.LocalSend`, else through KOReader's PluginLoader -- and never
kept: an instance from a previous reader window is a dead object. None of its
modules is `require`d; the only thing used is its public
`showFileSendFlow(path)`, which opens LocalSend's own device picker. That call
returning says the picker opened, not that anything was sent: the transfer,
its confirmation and its failures belong to LocalSend. JustDraw therefore
says "LocalSend is open", never "sent", and never deletes a file it handed
over.

**Staging.** Exports for a send go into a folder of our own under the cache
(`justdraw-send`), one subfolder per send (`op-<time>-<process>-<n>`) with a
manifest naming the process that made it, when, and every file JustDraw wrote
into it. One file is handed over by path; several are handed over as that
send's folder, and only once every export in it has finished -- a send never
silently carries a subset.

**Sweeping.** Deleting is where a helper like this does damage, so it is
narrow. Nothing handed over in this process is ever deleted by it. A later
start removes only operations that: sit directly in our root, are real
folders (no link is followed or removed), carry a valid manifest whose
process is not this one, and are at least 24 hours old by both the manifest
and the folder's own time -- a time in the future is anomalous and kept for
review. Only files the manifest lists are removed, and the folder only if it
is then empty. Anything else stays, and the reader can clear old sends by
hand. The size cap is checked before a new send is staged; a full root is a
question for the reader, never a reason to delete something that may still
be in use.
]]

local logger = require("logger")

local LocalSend = {
    ROOT_NAME = "justdraw-send",
    MANIFEST = ".justdraw-send",
    MIN_AGE = 24 * 3600,
    MAX_BYTES = 512 * 1024 * 1024,
}

-- ------------------------------------------------------------ finding it

--- Is `instance` a LocalSend that can open its send flow now?
function LocalSend.usable(instance)
    if type(instance) ~= "table" then return nil, "absent" end
    if instance.recovery_mode then return nil, "recovery_mode" end
    if instance.reinstall_required then return nil, "reinstall_required" end
    if type(instance.showFileSendFlow) ~= "function" then return nil, "no_send_flow" end
    return instance
end

--[[--
The live LocalSend, or nil and why. `ui` is the current reader or file
manager (its plugins are fields on it); `loader` is KOReader's PluginLoader.
Called at the moment of use, every time.
]]
function LocalSend.find(ui, loader)
    local candidate = type(ui) == "table" and rawget(ui, "LocalSend") or nil
    if candidate == nil and type(loader) == "table"
        and type(loader.getPluginInstance) == "function" then
        local ok, found = pcall(loader.getPluginInstance, loader, "LocalSend")
        if ok then candidate = found end
    end
    return LocalSend.usable(candidate)
end

--[[--
Open LocalSend's send flow on `path`. Returns true when the call returned
without raising -- which means the picker opened, and nothing more.
]]
function LocalSend.open(instance, path)
    local usable, why = LocalSend.usable(instance)
    if not usable then return nil, why end
    if type(path) ~= "string" or path == "" then return nil, "no_path" end
    local ok, err = pcall(usable.showFileSendFlow, usable, path)
    if not ok then
        logger.warn("JustDraw: LocalSend send flow failed to open:", err)
        return nil, "open_failed"
    end
    return true
end

-- ------------------------------------------------------------ staging

--- The real file system, without following links anywhere.
function LocalSend.nativeFs()
    local lfs = require("libs/libkoreader-lfs")
    return {
        lstat = function(path)
            local attrs = lfs.symlinkattributes(path)
            if type(attrs) ~= "table" then return nil end
            return { mode = attrs.mode, size = attrs.size, modification = attrs.modification }
        end,
        list = function(dir)
            local names = {}
            local ok, iter, state = pcall(lfs.dir, dir)
            if not ok then return names end
            for name in iter, state do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            return names
        end,
        mkdir = function(path) return lfs.mkdir(path) end,
        rmdir = function(path) return lfs.rmdir(path) end,
        remove = function(path) return os.remove(path) end,
        write = function(path, text)
            local f, err = io.open(path, "wb")
            if not f then return nil, err end
            local ok, write_err = f:write(text)
            local closed = f:close()
            if not ok or not closed then return nil, write_err or "write_failed" end
            return true
        end,
        read = function(path, limit)
            local f = io.open(path, "rb")
            if not f then return nil end
            local text = f:read(limit or 65536)
            f:close()
            return text
        end,
    }
end

local function safeName(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and not name:find("[/\\%z]") and #name <= 255
end

--- A file name from a title: no separators, no control characters, no
--- leading dot, bounded, never empty.
function LocalSend.fileStem(title)
    local stem = tostring(title or ""):gsub("[%c/\\:%*%?\"<>|]", "_"):gsub("^[%.%s]+", "")
    stem = stem:gsub("%s+$", "")
    if #stem > 120 then
        -- Cut on a character boundary.
        local cut = 120
        while cut > 0 and stem:byte(cut + 1) and stem:byte(cut + 1) >= 128
            and stem:byte(cut + 1) < 192 do cut = cut - 1 end
        stem = stem:sub(1, cut)
    end
    if stem == "" then stem = "Notebook" end
    return stem
end

local Staging = {}
Staging.__index = Staging

--- Operations handed over in this process, by folder: never swept by it.
local handed = {}

--[[--
  opts.root      the staging root (created on demand)
  opts.fs        see `nativeFs`
  opts.now       function() -> seconds
  opts.token     this process's token (random per process by default)
  opts.max_bytes the cap on everything staged
]]
function LocalSend.staging(opts)
    opts = opts or {}
    return setmetatable({
        root = assert(opts.root, "root"),
        fs = opts.fs or LocalSend.nativeFs(),
        now = opts.now or os.time,
        token = opts.token or LocalSend.processToken(),
        max_bytes = opts.max_bytes or LocalSend.MAX_BYTES,
        serial = 0,
    }, Staging)
end

local process_token
function LocalSend.processToken()
    if not process_token then
        math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
        process_token = string.format("%08x", math.random(0, 0x7fffffff))
    end
    return process_token
end

function Staging:_manifestText(op)
    local lines = { "justdraw-send 1", "token " .. op.token, "created " .. op.created }
    for _, name in ipairs(op.files) do lines[#lines + 1] = "file " .. name end
    return table.concat(lines, "\n") .. "\n"
end

--- Parse a manifest strictly; anything unexpected makes it invalid.
function LocalSend.parseManifest(text)
    if type(text) ~= "string" then return nil end
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    if lines[1] ~= "justdraw-send 1" then return nil end
    local token = (lines[2] or ""):match("^token (%x+)$")
    local created = tonumber((lines[3] or ""):match("^created (%d+)$"))
    if not token or not created then return nil end
    local files = {}
    for i = 4, #lines do
        local name = lines[i]:match("^file (.+)$")
        if not safeName(name) or name == LocalSend.MANIFEST then return nil end
        files[#files + 1] = name
    end
    return { token = token, created = created, files = files }
end

--- Bytes under the root, one level of operations deep, links not followed.
function Staging:usedBytes()
    local total = 0
    for _, name in ipairs(self.fs.list(self.root)) do
        local path = self.root .. "/" .. name
        local st = self.fs.lstat(path)
        if st and st.mode == "directory" then
            for _, inner in ipairs(self.fs.list(path)) do
                local ist = self.fs.lstat(path .. "/" .. inner)
                if ist and ist.mode == "file" then total = total + (ist.size or 0) end
            end
        elseif st and st.mode == "file" then
            total = total + (st.size or 0)
        end
    end
    return total
end

--[[--
Start one send's folder. Refused, with nothing deleted, when the root is at
its cap (`staging_full`) or cannot be made.
]]
function Staging:begin()
    local root_st = self.fs.lstat(self.root)
    if root_st and root_st.mode ~= "directory" then return nil, "bad_root" end
    if not root_st then
        self.fs.mkdir(self.root)
        root_st = self.fs.lstat(self.root)
        if not root_st or root_st.mode ~= "directory" then return nil, "bad_root" end
    end
    if self:usedBytes() >= self.max_bytes then return nil, "staging_full" end
    self.serial = self.serial + 1
    local op = setmetatable({
        staging = self, token = self.token, created = math.floor(self.now()),
        files = {}, handed = false,
    }, { __index = Staging.Op })
    op.name = string.format("op-%d-%s-%d", op.created, self.token, self.serial)
    op.dir = self.root .. "/" .. op.name
    if self.fs.lstat(op.dir) then return nil, "exists" end
    self.fs.mkdir(op.dir)
    local st = self.fs.lstat(op.dir)
    if not st or st.mode ~= "directory" then return nil, "mkdir_failed" end
    local ok, err = op:_save()
    if not ok then
        self.fs.rmdir(op.dir)
        return nil, err
    end
    return op
end

Staging.Op = {}

function Staging.Op:_save()
    return self.staging.fs.write(self.dir .. "/" .. LocalSend.MANIFEST,
        self.staging:_manifestText(self))
end

--- Record a file JustDraw wrote into this operation (a full path inside it).
function Staging.Op:record(path)
    local name = type(path) == "string" and path:sub(#self.dir + 2) or nil
    if not path or path:sub(1, #self.dir + 1) ~= self.dir .. "/" or not safeName(name) then
        return nil, "outside"
    end
    for _, known in ipairs(self.files) do if known == name then return true end end
    self.files[#self.files + 1] = name
    return self:_save()
end

--- What LocalSend is given: the one file by path, else this folder.
function Staging.Op:target()
    if #self.files == 1 then return self.dir .. "/" .. self.files[1] end
    return self.dir
end

--- Mark handed over: from here on this process never deletes it.
function Staging.Op:handOff()
    self.handed = true
    handed[self.dir] = true
    return self:target()
end

--- Remove what this operation wrote, unless it was handed over.
function Staging.Op:abandon()
    if self.handed or handed[self.dir] then return false end
    local fs = self.staging.fs
    for _, name in ipairs(self.files) do
        local path = self.dir .. "/" .. name
        local st = fs.lstat(path)
        if st and st.mode == "file" then fs.remove(path) end
    end
    fs.remove(self.dir .. "/" .. LocalSend.MANIFEST)
    fs.rmdir(self.dir)
    self.files = {}
    return true
end

--[[--
Remove old operations of other processes (see the header for every
condition). `opts.min_age` overrides the 24 hours for the reader's explicit
"clear old sends"; operations handed over in this process are never touched.
Returns { removed = n, kept = { name = reason } }.
]]
function Staging:sweep(opts)
    opts = opts or {}
    local min_age = opts.min_age or LocalSend.MIN_AGE
    local now = self.now()
    local report = { removed = 0, kept = {} }
    local fs = self.fs
    local root_st = fs.lstat(self.root)
    if not root_st or root_st.mode ~= "directory" then return report end
    for _, name in ipairs(fs.list(self.root)) do
        local dir = self.root .. "/" .. name
        local st = fs.lstat(dir)
        local why
        local token = name:match("^op%-%d+%-(%x+)%-%d+$")
        if not st or st.mode ~= "directory" then why = "not_a_folder"
        elseif not token then why = "not_ours"
        elseif handed[dir] then why = "handed_over"
        elseif token == self.token then why = "this_process"
        else
            local manifest = LocalSend.parseManifest(fs.read(dir .. "/" .. LocalSend.MANIFEST))
            local mtime = st.modification or 0
            if not manifest or manifest.token ~= token then why = "no_manifest"
            elseif manifest.created > now or mtime > now then why = "future_time"
            elseif now - manifest.created < min_age or now - mtime < min_age then why = "too_young"
            else
                for _, file in ipairs(manifest.files) do
                    local path = dir .. "/" .. file
                    local fst = fs.lstat(path)
                    if fst and fst.mode == "file" then fs.remove(path) end
                end
                fs.remove(dir .. "/" .. LocalSend.MANIFEST)
                fs.rmdir(dir)
                if fs.lstat(dir) then why = "not_empty" else report.removed = report.removed + 1 end
            end
        end
        if why then report.kept[name] = why end
    end
    return report
end

LocalSend.Staging = Staging

-- ------------------------------------------------------------ the flow

local active_flow

--[[--
Export `items` into one staged operation and open LocalSend on the result.

  opts.items        notebooks ({ id, title })
  opts.find         function() -> LocalSend instance | nil, reason
  opts.staging      a `LocalSend.staging`
  opts.export_one   function(item, format, dir, stem, done) -- runs one export
                    into `dir` and calls `done(result)` once, where result is
                    the export's { status = "done" | "cancelled" | ..., written }
                    or nil when it could not start
  opts.show_modal, opts.close_modal, opts.notify
  opts.schedule     function(fn), a later tick

One flow at a time. Returns the flow ({ cancel = fn }) or nil and a reason.
]]
function LocalSend.send(opts)
    local _ = require("gettext")
    local T = require("ffi/util").template
    local N_ = _.ngettext
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    if active_flow then return nil, "busy" end
    local items = opts.items or {}
    if #items == 0 then return nil, "empty" end
    if not opts.find() then
        opts.notify(_("LocalSend isn’t available. Install or update the LocalSend plugin, then try again."))
        return nil, "absent"
    end
    local flow = { cancelled = false, results = {} }
    local op
    local function finish()
        if active_flow == flow then active_flow = nil end
    end
    function flow.cancel()
        if flow.cancelled or flow.done then return end
        flow.cancelled = true
        if op then op:abandon() end
        finish()
    end
    active_flow = flow

    local function handOff()
        if flow.cancelled then return end
        local instance = opts.find()
        if not instance then
            -- Gone between exporting and opening: keep what was made.
            local box
            box = ConfirmBox:new{
                text = T(_("LocalSend isn’t available any more. The files are kept in:\n%1\n\nTry again?"), op.dir),
                ok_text = _("Try again"),
                ok_callback = function() opts.schedule(handOff) end,
                cancel_callback = function() flow.done = true; finish() end,
            }
            opts.show_modal(box)
            return
        end
        local target = op:handOff()
        local opened = LocalSend.open(instance, target)
        flow.done = true
        finish()
        if opened then
            -- LocalSend owns the transfer and its outcome from here.
            opts.notify(_("LocalSend is open. It shows the transfer and its result."))
        else
            opts.notify(T(_("Couldn’t open LocalSend. The files are kept in:\n%1"), op.dir))
        end
    end

    local run
    local function afterAll()
        if flow.cancelled then return end
        local failed = {}
        for _, r in ipairs(flow.results) do
            if r.status ~= "ok" then failed[#failed + 1] = r end
        end
        if #failed == 0 then return handOff() end
        -- Never send a subset without asking: retry what failed, or stop.
        local lines = { T(N_("Couldn’t prepare %1 notebook for sending:",
            "Couldn’t prepare %1 notebooks for sending:", #failed), #failed) }
        for _, r in ipairs(failed) do lines[#lines + 1] = "• " .. tostring(r.item.title) end
        lines[#lines + 1] = _("Try again?")
        local box
        box = ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Try again"),
            ok_callback = function()
                local again = {}
                for _, r in ipairs(failed) do again[#again + 1] = r.item end
                for i = #flow.results, 1, -1 do
                    if flow.results[i].status ~= "ok" then table.remove(flow.results, i) end
                end
                opts.schedule(function() run(again, flow.format) end)
            end,
            cancel_callback = function() flow.cancel() end,
        }
        opts.show_modal(box)
    end

    local used_stems = {}
    local function stemFor(item)
        local base = LocalSend.fileStem(item.title)
        local stem, n = base, 1
        while used_stems[stem] do
            n = n + 1
            stem = base .. " (" .. n .. ")"
        end
        used_stems[stem] = true
        return stem
    end

    run = function(list, format)
        local index = 0
        local function step()
            if flow.cancelled then return end
            index = index + 1
            local item = list[index]
            if not item then return afterAll() end
            local settled = false
            local ok, err = pcall(opts.export_one, item, format, op.dir, stemFor(item), function(result)
                if settled then return end
                settled = true
                if flow.cancelled then return end
                local status = "failed"
                if result and result.status == "done" then
                    status = "ok"
                    for _, path in ipairs(result.written or {}) do op:record(path) end
                elseif result and result.status == "cancelled" then
                    return flow.cancel()
                end
                flow.results[#flow.results + 1] = { item = item, status = status }
                opts.schedule(step)
            end)
            if not ok then
                logger.warn("JustDraw: send export failed to start:", err)
                if not settled then
                    settled = true
                    flow.results[#flow.results + 1] = { item = item, status = "failed" }
                    opts.schedule(step)
                end
            end
        end
        step()
    end

    local function start(format)
        flow.format = format
        local begun, err = opts.staging:begin()
        if not begun then
            if err == "staging_full" then
                local box
                box = ConfirmBox:new{
                    text = _("Earlier sends still take up space. Delete the ones from previous sessions and try again?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        opts.staging:sweep{ min_age = 0 }
                        opts.schedule(function()
                            local again = opts.staging:begin()
                            if not again then
                                opts.notify(_("There is still no room to prepare the files. Nothing was sent."))
                                return flow.cancel()
                            end
                            op = again
                            run(items, format)
                        end)
                    end,
                    cancel_callback = function() flow.cancel() end,
                }
                opts.show_modal(box)
                return
            end
            logger.warn("JustDraw: send staging failed:", err)
            opts.notify(_("Couldn’t prepare the files for sending. Nothing was sent."))
            return flow.cancel()
        end
        op = begun
        run(items, format)
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(N_("Send %1 notebook with LocalSend as:", "Send %1 notebooks with LocalSend as:",
            #items), #items) .. "\n"
            .. _("PDF is a picture of each page. Xournal++ keeps every stroke editable; some pen styles and papers are approximated."),
        buttons = {
            {{ text = _("PDF"), callback = function()
                flow.chosen = true
                opts.close_modal(dialog)
                start("pdf")
            end }},
            {{ text = _("Xournal++"), callback = function()
                flow.chosen = true
                opts.close_modal(dialog)
                start("xopp")
            end }},
            {{ text = _("Cancel"), callback = function()
                opts.close_modal(dialog)
            end }},
        },
    }
    local on_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(widget, ...)
        if on_close then on_close(widget, ...) end
        -- Closed without a choice, by any route: the flow is over.
        if not flow.chosen then flow.cancel() end
    end
    opts.show_modal(dialog)
    flow.dialog = dialog
    return flow
end

--- Cancel the send being prepared, if any (suspend, window close). Files
--- already handed to LocalSend are never touched.
function LocalSend.cancelActive()
    if active_flow then active_flow.cancel() end
end

function LocalSend.activeFlow() return active_flow end

--- Tests only: forget what this process handed over.
function LocalSend._resetHanded() handed = {} end

return LocalSend
