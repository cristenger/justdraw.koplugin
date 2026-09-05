-- A fork owns a copy of CREngine's document. No ReaderUI events or disk spool.
local ffi = require("ffi")
local util = require("ffi/util")
local BB = require("ffi/blitbuffer")
local Worker = {}
Worker.__index = Worker
local MAX_PACKET = 8 * 1024 * 1024
local function writeAll(fd, data)
    local offset = 0
    while offset < #data do
        local n = tonumber(ffi.C.write(fd, ffi.cast("const char *", data) + offset, #data - offset))
        if n <= 0 then
            error("pipe_failed")
        end
        offset = offset + n
    end
end
local function send(fd, kind, data)
    writeAll(fd, kind .. " " .. #data .. "\n")
    writeAll(fd, data)
end
local function child(opts, outfd, infd)
    local bb
    local ok, err = pcall(function()
        local view = opts.document._document
        -- The child must not run inherited ReaderUI progress callbacks.
        view:setCallback(nil)
        view:enablePartialRerendering(false)
        local dpi = opts.dpi or 150
        local w, h = math.floor(148 / 25.4 * dpi + 0.5), math.floor(210 / 25.4 * dpi + 0.5)
        assert(w * h <= MAX_PACKET, "too_large")
        -- CreDocument.PAGE_VIEW_MODE is 1; 0 is continuous scrolling.
        view:setViewMode(1)
        view:setVisiblePageCount(1, false)
        view:setHeaderInfo(0)
        view:setFontSize(math.floor(24 * dpi / 150 + 0.5))
        local margin = math.floor(36 * dpi / 150 + 0.5)
        view:setPageMargins(margin, margin, margin, margin)
        bb = BB.new(w, h, BB.TYPE_BB8)
        view:drawCurrentPage(bb, false, false, false, false)
        local count = view:getPages(true)
        if count <= 0 or count > 5000 then
            error("too_many_pages", 0)
        end
        local locations = {}
        for _, note in ipairs(opts.notes or {}) do
            local xp = note.xpointer
                or note.surface and require("ink_anchor").resolve(opts.document, note.surface)
            if xp and view:isXPointerInDocument(xp) then
                locations[note.id] = view:getPageFromXPointer(xp)
            end
        end
        send(outfd, "R", require("json").encode({ count = count, w = w, h = h, locations = locations }))
        local byte = ffi.new("char[1]")
        while true do
            local line = ""
            repeat
                local n = ffi.C.read(infd, byte, 1)
                if n ~= 1 then
                    return
                end
                local c = ffi.string(byte, 1)
                if c == "\n" then
                    break
                end
                line = line .. c
                assert(#line < 32, "bad_page")
            until false
            local page = tonumber(line)
            assert(page and page >= 1 and page <= count and page == math.floor(page), "bad_page")
            view:gotoPage(page, true)
            bb:fill(BB.COLOR_WHITE)
            view:drawCurrentPage(bb, false, false, false, false)
            local actual, total = view:getCurrentPage(true), view:getPages(true)
            if actual ~= page or total ~= count then
                require("logger").warn(
                    "JustDraw EPUB: requested/actual page and expected/actual count",
                    page,
                    actual,
                    count,
                    total
                )
                error("page_size_changed", 0)
            end
            send(outfd, "P", ffi.string(bb.data, w * h))
        end
    end)
    if bb then
        bb:free()
    end
    if not ok then
        require("logger").warn("JustDraw EPUB worker:", err)
        pcall(
            send,
            outfd,
            "E",
            (err == "too_many_pages" or err == "page_size_changed") and err or "epub_worker_failed"
        )
    end
end
function Worker.supports(ui)
    return ui
            and ui.rolling
            and ui.document
            and ui.document._document
            and type(util.runInSubProcess) == "function"
            and type(util.getNonBlockingReadSize) == "function"
        or false
end
function Worker.start(opts)
    local self = setmetatable(
        { opts = opts, header = "", parts = {}, size = 0, waiting = true, started = os.time() },
        Worker
    )
    local pid, rfd, wfd = util.runInSubProcess(function(_, outfd, infd)
        child(opts, outfd, infd)
    end, "bidi")
    if not pid then
        return nil, "epub_worker_failed"
    end
    self.pid, self.rfd, self.wfd = pid, rfd, wfd
    opts.schedule_in(0.01, function()
        self:_poll()
    end)
    return self
end
function Worker:_fail(reason)
    local callback = self.callback
    self:close()
    if callback then
        callback(nil, reason)
    else
        self.opts.error(reason)
    end
end
function Worker:_poll()
    if self.closed or not self.waiting then
        return
    end
    local ok, err = pcall(function()
        for _ = 1, 4 do
            local available = util.getNonBlockingReadSize(self.rfd)
            assert(available, "pipe_failed")
            if available == 0 then
                break
            end
            local length = math.min(available, 65536)
            local buffer = ffi.new("char[?]", length)
            local n = tonumber(ffi.C.read(self.rfd, buffer, length))
            assert(n > 0, "pipe_failed")
            local data = ffi.string(buffer, n)
            if not self.expected then
                self.header = self.header .. data
                local split = self.header:find("\n", 1, true)
                if not split then
                    assert(#self.header < 64, "bad_packet")
                    break
                end
                local kind, size = self.header:sub(1, split - 1):match("^([RPE]) (%d+)$")
                self.kind, self.expected = kind, tonumber(size)
                assert(kind and self.expected <= MAX_PACKET, "bad_packet")
                data = self.header:sub(split + 1)
                self.header = ""
            end
            self.parts[#self.parts + 1] = data
            self.size = self.size + #data
            assert(self.size <= self.expected, "bad_packet")
            if self.size == self.expected then
                local payload = table.concat(self.parts)
                self.parts, self.size, self.expected, self.waiting = {}, 0, nil, false
                if self.kind == "E" then
                    return self:_fail(payload)
                end
                if self.kind == "R" then
                    self.manifest = require("json").decode(payload)
                    return self.opts.ready(self.manifest)
                end
                assert(#payload == self.manifest.w * self.manifest.h, "bad_packet")
                local bb = BB.fromstring(self.manifest.w, self.manifest.h, BB.TYPE_BB8, payload)
                local callback = self.callback
                self.callback = nil
                return callback({
                    bb = bb,
                    width_pt = 148 / 25.4 * 72,
                    height_pt = 210 / 25.4 * 72,
                    release = function()
                        if bb then
                            bb:free()
                            bb = nil
                        end
                    end,
                })
            end
        end
        if util.isSubProcessDone(self.pid) then
            return self:_fail("epub_worker_failed")
        end
        if os.time() - self.started > 600 then
            return self:_fail("epub_worker_failed")
        end
        self.opts.schedule_in(0.01, function()
            self:_poll()
        end)
    end)
    if not ok then
        self:_fail(err)
    end
end
function Worker:render(page, done)
    if self.closed or self.waiting then
        return done(nil, "epub_worker_failed")
    end
    self.callback, self.waiting, self.started = done, true, os.time()
    if not util.writeToFD(self.wfd, tostring(page) .. "\n") then
        return self:_fail("epub_worker_failed")
    end
    self.opts.schedule_in(0.01, function()
        self:_poll()
    end)
end
function Worker:close()
    if self.closed then
        return
    end
    self.closed = true
    self.parts = {}
    ffi.C.close(self.rfd)
    ffi.C.close(self.wfd)
    util.terminateSubProcess(self.pid)
    -- Also cover cancellation before the child has established its process group.
    if not util.isSubProcessDone(self.pid) then
        ffi.C.kill(self.pid, 9)
    end
    local function reap()
        if not util.isSubProcessDone(self.pid) then
            self.opts.schedule_in(0.05, reap)
        end
    end
    reap()
end
return Worker
