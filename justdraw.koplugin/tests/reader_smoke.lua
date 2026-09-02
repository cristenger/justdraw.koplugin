--[[--
Drive page ink through a real ReaderUI, on the KOReader runtime that is
actually installed.

Every other test in this plugin proves one seam against a fake. That is what
keeps `tests/run.lua` runnable on a machine with nothing but LuaJIT, and it is
also its blind spot: a fake ReaderView cannot tell you that `state.offset` is
nil until `recalculate` has run, a fake Blitbuffer cannot fail an
`alphablitFrom` from BB8A onto RGB32, and a fake store cannot hand back an
int64 the arithmetic then truncates. This script is the other half. It opens a
real MuPDF document through a real `ReaderUI`, lets `PluginLoader` instantiate
the plugin the way the reader does, registers the stylus callback on the real
`Input`, pushes a synthetic pen contact through `Input:routeStylusEvents`, runs
the real deferred queue into a real SQLite file, blits the overlay onto the
emulator's own framebuffer, turns a page and closes.

It is deliberately NOT in `tests/run.lua`: it needs a KOReader build, an SDL
screen and a document. Like `tests/conformance.lua` it runs from inside the
build directory so `setupkoenv` resolves; unlike it, it writes -- so it insists
on an isolated `KO_HOME` and creates one itself when it was not given one.
Nothing here may touch the reader's own settings, and nothing here stubs a
KOReader module: a step that cannot run on the real stack is a FAIL to report,
not a fake to install.

    cd <koreader-build>/koreader \
      && KO_HOME=$(mktemp -d) ./luajit <repo>/justdraw.koplugin/tests/reader_smoke.lua

  KO_HOME                 an isolated data dir; one is created when unset
  JUSTDRAW_SMOKE_PDF      the document to open (default: ../../test/sample.pdf)
  JUSTDRAW_SMOKE_KEEP=1   keep a created KO_HOME on disk to look at

Exit status is 0 only when every step printed OK.
]]

-- KOReader's own search paths, exactly as reader.lua does it first.
require("setupkoenv")

local ffi = require("ffi")
ffi.cdef [[
    int setenv(const char *name, const char *value, int overwrite);
    int symlink(const char *target, const char *linkpath);
    int getpid(void);
]]

-- This file's own neighbours, resolved from the file rather than from the
-- working directory: the script runs from inside a KOReader build.
local this = debug.getinfo(1, "S").source:sub(2)
local tests_dir = this:match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tests_dir:match("^(.*)[/\\][^/\\]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. tests_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")

-- ---------------------------------------------------------------- reporting

local failures = 0

--- One step. Everything is inside one, so a raise anywhere is a FAIL with its
--- traceback rather than a silent exit. `fn(say)` may report detail lines and
--- returns the sentence printed after the step name.
local function step(name, fn)
    if failures > 0 then
        print(string.format("SKIP %s (an earlier step failed)", name))
        return nil
    end
    local lines = {}
    local function say(fmt, ...)
        lines[#lines + 1] = select("#", ...) > 0
            and string.format(fmt, ...) or fmt
    end
    local ok, result = xpcall(function() return fn(say) end, debug.traceback)
    if not ok then failures = failures + 1 end
    print(string.format("%s %s%s", ok and "OK  " or "FAIL", name,
        (ok and type(result) == "string") and (" -- " .. result) or ""))
    for i = 1, #lines do print("       " .. lines[i]) end
    if not ok then
        for line in tostring(result):gmatch("[^\n]+") do print("       " .. line) end
    end
    return ok and result or nil
end

local function expect(cond, fmt, ...)
    if cond then return cond end
    error(select("#", ...) > 0 and string.format(fmt, ...) or fmt, 2)
end

local function num(v)
    return tonumber(v)
end

-- --------------------------------------------------------------- the session

-- Everything the steps share. Assigned in the step that creates it, so a
-- failure upstream leaves the rest skipped rather than indexing nil.
local S = {}

--[[--
Run every scheduled task that is due, which is what the UI loop does between
input frames.

There is no loop here, so everything the plugin defers has to be pumped by
hand: the coalesced view refresh, the page change, and above all the canvas
queue -- which exists precisely so that no SQLite transaction is opened from
the stylus callback (ADR-26). A task may schedule another, and `_checkTasks`
already drains those; the rounds are for tasks that schedule onto the *next*
tick rather than this one.
]]
function S.tick(rounds)
    for _ = 1, rounds or 2 do S.UIManager:_checkTasks() end
end

--[[--
One `SYN_REPORT`'s worth of pen traffic, assembled in `Input`'s own slot
tables and delivered through `Input`'s own routing.

`Input:handleTouchEv` builds a frame by `addSlot`-ing the slots that moved,
writing their fields with `setCurrentMtSlot`, stamping `timev` on the frame's
slots and then, on SYN_REPORT, calling `routeStylusEvents` followed by exactly
one `gesture_detector:feedEvent` over whatever survived it. This mirrors that,
so the stylus callback, the domination of the slot, JustDraw's feed wrapper
and its residual filter all run for real. Only the evdev decoding above it is
supplied by hand.
]]
local time = require("ui/time")
local frame_epoch = nil
function S.penFrame(id, x, y, ordinal)
    local input = S.Input
    frame_epoch = frame_epoch or time.now()
    input:newFrame()
    input:addSlot(input.pen_slot)
    input:setCurrentMtSlot("id", id)
    input:setCurrentMtSlot("tool", input.TOOL_TYPE_PEN)
    input:setCurrentMtSlot("x", x)
    input:setCurrentMtSlot("y", y)
    for _, slot in ipairs(input.MTSlots) do
        input:setMtSlot(slot.slot, "timev",
            frame_epoch + time.ms(12 * (ordinal or 1)))
    end
    input:routeStylusEvents()
    input.gesture_detector:feedEvent(input.MTSlots)
end

--[[--
Read the plugin's database from outside the plugin.

A second, read-only connection through the same driver: it proves the rows
are committed rather than merely present in the writer's own transaction, and
it is the only honest way to ask what is on disk while the reader still holds
the file open. Blobs come back through `CAST(... AS TEXT)`, without which a
NUL truncates them.
]]
local SQL = require("lua-ljsqlite3/init")

local function withDatabase(fn)
    local conn = expect(SQL.open(S.db_path, "ro"),
        "could not open %s read-only", tostring(S.db_path))
    local ok, result = pcall(fn, conn)
    conn:close()
    if not ok then error(result, 0) end
    return result
end

--[[--
Dismiss the start-up notices a fresh profile puts over the toolbar.

Drawing yields to anything on top of it -- a pen contact under an open dialog
classifies as `pass` and goes to GestureDetector, because tapping outside is
the only way to close one. That rule is the reason this has to be done rather
than ignored: a first run creates KOReader's book-info cache and CoverBrowser
says so in an InfoMessage, which in a real session times out a few seconds
later and here would sit there for ever, silently swallowing the pen.

Closing one is what dismissing it does, and nothing but widgets above our own
toolbar is touched.
]]
function S.clearOverlays()
    local Stack = require("ink_stack")
    local closed = {}
    for _ = 1, 20 do
        if not S.plugin:dialogOnTop() then break end
        local widget = Stack.below(S.plugin.bar)
        if not widget or widget == S.reader then break end
        closed[#closed + 1] = tostring(widget.text or widget.title or "widget")
        S.UIManager:close(widget)
        S.tick(1)
    end
    return closed
end

--- One number: the first column of the single row a COUNT returns.
function S.count(sql)
    return withDatabase(function(conn) return num(conn:rowexec(sql)) end)
end

--- One row as an array of its columns, or nil when there is none.
function S.row(sql)
    return withDatabase(function(conn)
        local res, rows = conn:exec(sql)
        if not res or (rows or 0) < 1 then return nil end
        local out = {}
        for i = 1, #res do out[i] = res[i][1] end
        return out
    end)
end

--- The first column of every row, in order.
function S.column(sql)
    return withDatabase(function(conn)
        local res, rows = conn:exec(sql)
        if not res or (rows or 0) < 1 then return {} end
        local out = {}
        for i = 1, rows do out[i] = res[1][i] end
        return out
    end)
end

-- ------------------------------------------------------------------- step 1

--[[--
An isolated data dir, and the plugin where `PluginLoader` will look.

A KO_HOME handed in (`koreader_qa.sh prepare` makes one) is used as it stands;
without one a fresh temp directory is created and the plugin symlinked into
its `plugins/`, which is the path `PluginLoader` falls back to when
`extra_plugin_paths` is unset. Never the reader's own data dir: this script
writes settings, a database and a document sidecar.
]]
local function forbiddenHome(path)
    local home = os.getenv("HOME")
    if not home then return false end
    return path == home .. "/Library/Application Support/koreader"
        or path == home .. "/.config/koreader"
end

local function isDir(path)
    return path ~= nil and lfs.attributes(path, "mode") == "directory"
end

step("1 boot: isolated KO_HOME, Device, CanvasContext", function(say)
    local given = os.getenv("KO_HOME")
    if given == "" then given = nil end
    if given then
        expect(isDir(given), "KO_HOME is not a directory: %s", given)
    else
        local base = os.getenv("TMPDIR") or "/tmp"
        if base:sub(-1) == "/" then base = base:sub(1, -2) end
        given = string.format("%s/justdraw-reader-smoke-%d-%d",
            base, ffi.C.getpid(), os.time())
        expect(lfs.mkdir(given), "could not create %s", given)
        S.home_created = true
    end
    expect(not forbiddenHome(given),
        "refusing to run against the reader's own data dir: %s", given)

    --[[--
    Somewhere for `PluginLoader` to find this worktree's plugin.

    `koreader_qa.sh prepare` symlinks it into the runtime's own `plugins/`,
    which is `DEFAULT_PLUGIN_PATH` and needs nothing here. A bare
    `KO_HOME=$(mktemp -d)` does not, and then the only lookup path left is the
    `<data dir>/plugins/` fallback -- so make it, and link this exact
    directory into it. A copy would be a different plugin.
    ]]
    if not isDir("plugins/justdraw.koplugin")
        and not isDir(given .. "/plugins/justdraw.koplugin") then
        if not isDir(given .. "/plugins") then
            expect(lfs.mkdir(given .. "/plugins"),
                "could not create %s/plugins", given)
        end
        expect(ffi.C.symlink(plugin_dir,
            given .. "/plugins/justdraw.koplugin") == 0,
            "could not symlink the plugin into %s/plugins", given)
    end
    expect(ffi.C.setenv("KO_HOME", given, 1) == 0, "could not set KO_HOME")
    S.home = given

    local DataStorage = require("datastorage")
    expect(DataStorage:getDataDir() == given,
        "DataStorage resolved %s, not the isolated home",
        DataStorage:getDataDir())
    S.DataStorage = DataStorage
    S.settings_dir = DataStorage:getSettingsDir()

    -- The two globals reader.lua creates before anything else; document code
    -- indexes G_defaults at load time and would fail a long way from here.
    local LuaSettings = require("luasettings")
    _G.G_defaults = _G.G_defaults or require("luadefaults"):open()
    _G.G_reader_settings = _G.G_reader_settings
        or LuaSettings:open(given .. "/settings.reader.lua")

    --[[--
    Keep the document's sidecar inside the isolated home.

    KOReader's default is a `.sdr` folder beside the book, and the book here
    is a fixture in somebody's KOReader checkout: writing there would litter
    a tree this script does not own, and -- worse for a smoke test -- the next
    run would inherit the settings this one left, starting from a view the
    first run had to change. `dir` puts every sidecar under `KO_HOME`, so each
    run opens the book exactly as a reader opening it for the first time.
    ]]
    G_reader_settings:saveSetting("document_metadata_folder", "dir")

    --[[--
    Another plugin's stylus callback is a refusal, by design: the callback is
    a singleton with no chaining and no owner query, so JustDraw declines to
    take one it did not install. On a developer machine the build's `plugins/`
    holds JustDraw's own ancestors, and they would win the race and make this
    script prove nothing. Disable exactly those -- any plugin that registers a
    stylus callback and is not this one -- and say which.
    ]]
    local disabled = G_reader_settings:readSetting("plugins_disabled", {})
    local rivals = {}
    if isDir("plugins") then
        for entry in lfs.dir("plugins") do
            if entry:sub(-9) == ".koplugin" and entry ~= "justdraw.koplugin"
                and isDir("plugins/" .. entry) then
                local claims = false
                for file in lfs.dir("plugins/" .. entry) do
                    if file:sub(-4) == ".lua" then
                        local fh = io.open("plugins/" .. entry .. "/" .. file)
                        if fh then
                            local body = fh:read("*a") or ""
                            fh:close()
                            if body:find("registerStylusCallback", 1, true) then
                                claims = true
                            end
                        end
                    end
                    if claims then break end
                end
                if claims then
                    local name = entry:sub(1, -10)
                    disabled[name] = true
                    rivals[#rivals + 1] = name
                end
            end
        end
    end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    if #rivals > 0 then
        say("disabled rival stylus plugins: %s", table.concat(rivals, ", "))
    end

    local Device = require("device")
    require("document/canvascontext"):init(Device)
    S.Device = Device
    S.Screen = Device.screen
    S.Input = Device.input
    S.UIManager = require("ui/uimanager")
    S.Event = require("ui/event")
    S.Blitbuffer = require("ffi/blitbuffer")

    local rev = io.open("git-rev")
    S.revision = rev and (rev:read("*l") or "?") or "?"
    if rev then rev:close() end
    say("runtime %s, screen %dx%d, screen bb type %d, pen_slot %s",
        S.revision, S.Screen:getWidth(), S.Screen:getHeight(),
        S.Screen.bb:getType(), tostring(S.Input.pen_slot))
    return S.home .. (S.home_created and " (created)" or "")
end)

-- ------------------------------------------------------------------- step 2

--[[--
A real ReaderUI over a real MuPDF page, without the SDL main loop.

`ReaderUI:doShowReader` wraps this in history bookkeeping, a full-screen
refresh and `UIManager:show`; none of that is what page ink depends on.
`ReaderUI:new` alone runs the whole module registration, `PluginLoader`, the
`ReadSettings` and `ReaderReady` broadcasts and ReaderPaging's first
`recalculate` -- which is what fills `view.state.offset`, `view.state.zoom`
and `view.visible_area`, the three the page-ink transform reads. `view.dimen`
comes from the `dimen` handed to `new` (readerview.lua's own `init`), so no
`UIManager:show` is needed for it either.
]]
step("2 open sample.pdf through ReaderUI", function(say)
    local path = os.getenv("JUSTDRAW_SMOKE_PDF")
    if not path or path == "" then path = "../../test/sample.pdf" end
    expect(lfs.attributes(path, "mode") == "file",
        "no document at %s (set JUSTDRAW_SMOKE_PDF)", path)
    -- Absolute, so nothing downstream records a path relative to the build
    -- directory this happens to have been started from.
    path = require("ffi/util").realpath(path) or path

    local DocumentRegistry = require("document/documentregistry")
    local ReaderUI = require("apps/reader/readerui")
    local document = expect(DocumentRegistry:openDocument(path),
        "DocumentRegistry could not open %s", path)
    S.document = document
    S.reader = ReaderUI:new{
        dimen = S.Screen:getSize(),
        document = document,
    }
    expect(S.reader.paging, "the reader is not in paging mode")

    --[[--
    Single-page mode, which is what page ink needs and what a fresh profile
    does not start in: KOReader opens a PDF in continuous view, and the
    transform refuses that outright because one screen can then hold parts of
    two pages (ADR-38, `unsupported_mode`). `SetScrollMode` is the reader's
    own event for the "continuous view" toggle -- ReaderView answers it by
    recalculating -- so this is the reader turning it off, not the test
    reaching past it.
    ]]
    S.started_scrolling = S.reader.view.page_scroll and true or false
    if S.started_scrolling then
        S.reader:handleEvent(S.Event:new("SetScrollMode", false))
        S.tick(3)
        expect(not S.reader.view.page_scroll, "the reader is still scrolling")
        say("the reader opened in continuous view; turned off with SetScrollMode")
    end

    local native = expect(document:getNativePageDimensions(1),
        "page 1 has no native dimensions")
    S.native_w, S.native_h = num(native.w), num(native.h)
    say("provider %s, %d pages, native page 1 %.3f x %.3f %s",
        tostring(document.provider), document:getPageCount(),
        S.native_w, S.native_h,
        document.provider == "mupdf" and "pt" or "px")
    say("view.state page %s zoom %.6f offset %s,%s; visible_area %sx%s",
        tostring(S.reader.view.state.page), S.reader.view.state.zoom,
        tostring(S.reader.view.state.offset.x),
        tostring(S.reader.view.state.offset.y),
        tostring(S.reader.view.visible_area.w),
        tostring(S.reader.view.visible_area.h))
    return string.format("%s, page %d of %d",
        path:match("[^/]+$"), S.reader.view.state.page,
        document:getPageCount())
end)

-- ------------------------------------------------------------------- step 3

step("3 the plugin, its capabilities and its page-ink session", function(say)
    local PluginLoader = require("pluginloader")
    local plugin = S.reader.justdraw or PluginLoader:getPluginInstance("justdraw")
    expect(plugin, "PluginLoader did not instantiate justdraw")
    expect(plugin == PluginLoader:getPluginInstance("justdraw"),
        "reader.justdraw is not the loaded plugin instance")
    S.plugin = plugin

    local Capture = require("ink_capture")
    S.Capture = Capture
    expect(Capture:supportsStylus(),
        "this runtime has no stylus callback API (needs v2026.07)")

    local caps = expect(plugin.capabilities, "the plugin declared no capabilities")
    for _, name in ipairs({ "stylus_api", "view_transform",
                            "native_dimensions", "alpha_blit" }) do
        expect(caps[name] == true, "capability %s is %s", name, tostring(caps[name]))
    end

    local session = expect(plugin.document_session,
        "no page-ink session (open error: %s)",
        tostring(plugin.document_open_error))
    S.session = session
    expect(session:isAvailable(), "the session is not available: %s",
        tostring(session:stateName()))
    expect(session:page() == S.reader.view.state.page,
        "session is on page %s, the reader on %s",
        tostring(session:page()), tostring(S.reader.view.state.page))

    --[[--
    `refreshView` answers `true` here, not a transform object: with no row on
    this page yet it probes the page's own geometry, keeps nothing, and says
    only whether the view could be mapped at all. That is the assertion --
    the transform itself belongs to a surface, and there is none until Draw
    creates one in step 4. What matters now is that no reason came back.
    ]]
    local refreshed, reason = session:refreshView()
    expect(refreshed, "refreshView refused: %s", tostring(reason))
    expect(session:viewReason() == nil,
        "the view is refused: %s", tostring(session:viewReason()))

    local DocumentTransform = require("ink_document_transform")
    local spec, spec_err = DocumentTransform.surfaceSpec(S.document, session:page())
    expect(spec, "the page has no surface spec: %s", tostring(spec_err))
    say("surface spec for page %d: %d x %d %s (native %.3f x %.3f)",
        session:page(), spec.logical_w, spec.logical_h, spec.units,
        S.native_w, S.native_h)
    return string.format("stylus_api=%s, session on page %d, view accepted",
        tostring(caps.stylus_api), session:page())
end)

-- ------------------------------------------------------------------ step 4

step("4 Draw on: the page-ink row and the BB8A raster", function(say)
    local plugin = S.plugin

    --[[--
    `auto` picks the finger route here and is right to: it opts into the
    stylus backend only for a device that claims a Wacom digitizer, and the
    emulator claims none (`wacom_protocol` is nil). A tester with a graphics
    tablet picks `stylus` by hand, and so does this script -- the whole point
    is to exercise the callback route.
    ]]
    local set, mode_err = plugin:setInputMode("stylus")
    expect(set, "could not select the stylus backend: %s", tostring(mode_err))

    plugin:setDrawing(true)
    S.tick()
    expect(plugin.drawing, "Draw did not come on")
    expect(plugin.input_backend == "stylus",
        "backend is %s, not stylus", tostring(plugin.input_backend))
    expect(type(S.Input.stylus_callback) == "function",
        "nothing registered a stylus callback on Input")
    expect(S.Input.stylus_callback == S.Capture.stylus_callback,
        "the registered stylus callback is not JustDraw's")
    expect(plugin.bar, "drawing is on with no toolbar to stop it")

    -- The other half of the capture, and the one step 9 has to see given
    -- back: on a stock runtime `feedEvent` is inherited from the
    -- GestureDetector class, so the wrapper is an own field where there was
    -- none, and removal has to restore exactly that shape.
    local gd = S.Input.gesture_detector
    expect(rawget(gd, "feedEvent") ~= nil,
        "the residual frame filter was not installed on the gesture detector")
    S.feed_was_own = S.Capture.feed_was_own
    expect(S.feed_was_own == false,
        "feedEvent was already an own field before the capture installed")

    S.db_path = S.settings_dir .. "/justdraw.sqlite3"
    expect(lfs.attributes(S.db_path, "mode") == "file",
        "no database at %s", S.db_path)
    expect(S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'page_ink';") == 1,
        "expected exactly one page_ink canvas")
    expect(S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'page_ink' AND fixed_page = 1;") == 1,
        "no page_ink row for page 1")
    expect(S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'sheet';") == 0,
        "a sheet canvas was created for a fixed-layout document")

    local row = S.row([[SELECT logical_w, logical_h, coordinate_space
                          FROM canvases WHERE surface_role = 'page_ink'
                         AND fixed_page = 1;]])
    say("page_ink row: logical %s x %s, coordinate_space %s",
        tostring(num(row[1])), tostring(num(row[2])), tostring(row[3]))

    local tr = expect(S.session:transform(),
        "the surface has no transform: %s", tostring(S.session:viewReason()))
    S.transform = tr
    local rect = tr:canvasRect()
    local cw, ch = tr:cacheSize()
    say("transform scale %.6f (view zoom %.6f), cache %d x %d px",
        tr.scale, S.reader.view.state.zoom, cw, ch)
    say("canvasRect on screen: x=%d y=%d w=%d h=%d", rect.x, rect.y, rect.w, rect.h)

    local cache = expect(S.session:cache(), "the session has no raster cache")
    expect(cache:isReady(), "the raster is not ready: %s", cache:stateName())
    local bb = expect(cache:buffer(), "the raster has no buffer")
    expect(bb:getType() == S.Blitbuffer.TYPE_BB8A,
        "the raster is type %d, not BB8A (%d)",
        bb:getType(), S.Blitbuffer.TYPE_BB8A)
    say("raster %dx%d, type %d (BB8A), screen bb type %d (RGB32)",
        bb:getWidth(), bb:getHeight(), bb:getType(), S.Screen.bb:getType())
    return "drawing on, one page_ink row, BB8A raster"
end)

-- ------------------------------------------------------------------ step 5

--[[--
One physical pen contact, assembled the way `Input:handleTouchEv` assembles
one and delivered through the runtime's own `routeStylusEvents`.

Nothing here is a shortcut past KOReader: the slot tables are `Input`'s own
persistent `ev_slots` entries, populated through `addSlot` and
`setCurrentMtSlot` exactly as the evdev branch does, and each frame ends the
way a `SYN_REPORT` ends -- `routeStylusEvents` first, then one
`gesture_detector:feedEvent` over what survived it, which is where JustDraw's
own feed wrapper and its residual filter run. What this script supplies is the
evdev traffic a pen would have produced, and nothing else.
]]
step("5 a synthetic pen contact, its stroke and its row", function(say)
    local plugin, session = S.plugin, S.session
    local dismissed = S.clearOverlays()
    if #dismissed > 0 then
        say("dismissed %d start-up notice(s): %s",
            #dismissed, table.concat(dismissed, " | "))
    end
    expect(not plugin:dialogOnTop(),
        "a widget sits above the toolbar; the pen would pass through to it")

    local tr = expect(session:transform(), "the view is refused: %s",
        tostring(session:viewReason()))
    local rect = tr:canvasRect()
    local points = {}
    for i = 0, 8 do
        -- A diagonal on purpose: the axis policy collapses pixel-perfect
        -- axis-constant input to a dot, which is its documented bargain
        -- (ADR-22) and not what this step is about.
        points[#points + 1] = {
            x = rect.x + math.floor(rect.w * 0.25) + i * 17,
            y = rect.y + math.floor(rect.h * 0.30) + i * 23,
        }
    end
    for _, p in ipairs(points) do
        expect(tr:contains(p.x, p.y), "%d,%d is not on the page", p.x, p.y)
        expect(not plugin:inBar(p.x, p.y), "%d,%d is on the toolbar", p.x, p.y)
    end

    local first, last = points[1], points[#points]
    for i, p in ipairs(points) do
        S.penFrame(1, p.x, p.y, i)
    end
    S.penFrame(-1, last.x, last.y, #points + 1)
    S.tick(4)

    local cache = expect(session:cache(), "the session lost its raster")
    local metas = cache:strokes()
    expect(#metas == 1, "the raster holds %d stroke(s), not 1", #metas)
    local m = metas[1]
    expect(num(m.point_count) >= 2,
        "the stroke has %s point(s)", tostring(m.point_count))
    say("raster stroke: %d points, box %.2f,%.2f .. %.2f,%.2f (page units)",
        num(m.point_count), m.min_x, m.min_y, m.max_x, m.max_y)
    S.ink_min_x, S.ink_min_y = m.min_x, m.min_y
    S.ink_max_x, S.ink_max_y = m.max_x, m.max_y
    say("screen contact ran %d,%d .. %d,%d (%d frames + lift)",
        first.x, first.y, last.x, last.y, #points)

    -- The lifecycle gate, exactly as the reader reaches it: SaveSettings is
    -- what makes ink durable, and the queue writes on a tick before that.
    S.reader:saveSettings()
    S.tick(2)

    expect(S.count([[SELECT COUNT(*) FROM strokes s
                       JOIN canvases c ON c.id = s.canvas_id
                      WHERE c.surface_role = 'page_ink' AND c.fixed_page = 1;]]) == 1,
        "page 1 does not have exactly one persisted stroke")
    local row = S.row([[SELECT s.point_count, s.min_x, s.min_y, s.max_x, s.max_y,
                               c.logical_w, c.logical_h, s.id
                          FROM strokes s JOIN canvases c ON c.id = s.canvas_id
                         WHERE c.surface_role = 'page_ink' AND c.fixed_page = 1;]])
    local n = num(row[1])
    local min_x, min_y, max_x, max_y = num(row[2]), num(row[3]), num(row[4]), num(row[5])
    local lw, lh = num(row[6]), num(row[7])
    S.stroke_id = num(row[8])
    expect(n >= 2, "the persisted stroke has %d point(s)", n)
    expect(lw == math.ceil(S.native_w) and lh == math.ceil(S.native_h),
        "the surface is %dx%d, not the page's %dx%d",
        lw, lh, math.ceil(S.native_w), math.ceil(S.native_h))

    -- The whole claim of ADR-38 in one assertion: what is on disk is the
    -- page's own units, not the pixels the pen was seen at. Screen x ran past
    -- 300 here; a page-unit x cannot exceed the page's native width.
    expect(min_x >= 0 and max_x <= lw and min_y >= 0 and max_y <= lh,
        "stroke box %.2f,%.2f..%.2f,%.2f is outside the %dx%d page",
        min_x, min_y, max_x, max_y, lw, lh)
    expect(max_x < first.x,
        "stroke x max %.2f is not below the screen x %d it was drawn at",
        max_x, first.x)

    -- And the blob decodes back to the same units through the codec that
    -- wrote it: uint16 per axis, normalised on the canvas geometry.
    local Codec = require("ink_canvas_codec")
    local blobs = S.column([[SELECT CAST(k.points AS TEXT) FROM stroke_chunks k
                               JOIN strokes s ON s.id = k.stroke_id
                               JOIN canvases c ON c.id = s.canvas_id
                              WHERE c.surface_role = 'page_ink' AND c.fixed_page = 1
                              ORDER BY k.chunk_no;]])
    expect(#blobs >= 1, "the stroke has no chunks")
    local chunks = {}
    for i = 1, #blobs do chunks[i] = { points = blobs[i] } end
    local decoded, count = Codec.join(chunks, lw, lh)
    expect(decoded, "the chunks did not decode: %s", tostring(count))
    expect(count == n, "decoded %d points, the row says %d", count, n)
    for i = 1, count do
        local x, y = decoded[i * 2 - 1], decoded[i * 2]
        expect(x >= 0 and x <= lw and y >= 0 and y <= lh,
            "decoded point %d is %.2f,%.2f, outside the %dx%d page", i, x, y, lw, lh)
    end
    say("persisted stroke id %d: %d points in %d chunk(s), first %.2f,%.2f pt",
        S.stroke_id, n, #chunks, decoded[1], decoded[2])
    S.persisted_points = n
    return string.format("%d points, page units within %dx%d", n, lw, lh)
end)

-- ------------------------------------------------------------------ step 6

--[[--
The overlay composited onto the framebuffer the emulator actually has.

`alphablitFrom` from a BB8A source onto an RGB32 destination is a path no fake
can exercise: the test harness's buffers are Lua tables and its colours are
strings. Not raising is the first half of the claim; the second is that
something arrived, so a box around the middle of the stroke is compared before
and after. A blit that quietly did nothing -- the wrong source type, an alpha
of zero everywhere, a transform that put the raster off-screen -- would pass
the first half and fail this one.
]]
step("6 alphablitFrom BB8A onto the emulator's RGB32 screen", function(say)
    local bb = S.Screen.bb
    local mid_x, mid_y = S.transform:toScreen(
        (S.ink_min_x + S.ink_max_x) / 2, (S.ink_min_y + S.ink_max_y) / 2)
    mid_x, mid_y = math.floor(mid_x), math.floor(mid_y)
    local half = 4
    local function sample()
        local out = {}
        for y = mid_y - half, mid_y + half do
            for x = mid_x - half, mid_x + half do
                out[#out + 1] = bb:getPixel(x, y):getColor8().a
            end
        end
        return out
    end

    local function darkCount(box)
        local dark = 0
        for i = 1, #box do
            if box[i] < 128 then dark = dark + 1 end
        end
        return dark
    end

    -- What live ink already put there. The pen's own path blits the repaired
    -- box straight to the framebuffer, so this is normally already inked --
    -- reported, not asserted, because a refresh is allowed to have taken
    -- another route.
    local live_dark = darkCount(sample())

    -- Now the composition on its own terms: a white page, and only the
    -- overlay over it. That is what `ReaderView` hands the plugin after it
    -- has drawn the page, and it makes "did the ink arrive" answerable.
    bb:fill(S.Blitbuffer.COLOR_WHITE)
    expect(darkCount(sample()) == 0, "the fill did not clear the box")
    S.plugin:paintTo(bb, 0, 0)

    local on_stroke = darkCount(sample())
    expect(on_stroke > 0,
        "no ink in the %dx%d box at %d,%d after paintTo: the BB8A overlay "
        .. "never reached the RGB32 framebuffer",
        half * 2 + 1, half * 2 + 1, mid_x, mid_y)

    -- And nowhere else: an alpha the blitter ignored would paint the whole
    -- transparent raster over the page, which this box is far enough from
    -- the stroke to catch.
    local off_x, off_y = mid_x, mid_y
    mid_x, mid_y = math.floor(off_x + 200), math.floor(off_y - 200)
    local off_stroke = darkCount(sample())
    mid_x, mid_y = off_x, off_y
    expect(off_stroke == 0,
        "%d dark pixel(s) 200px off the stroke: the overlay ignored its alpha",
        off_stroke)

    say("Screen.bb type %d (%s), %dx%d", bb:getType(),
        bb:getType() == S.Blitbuffer.TYPE_BBRGB32 and "RGB32" or "?",
        bb:getWidth(), bb:getHeight())
    say("live ink had already blitted %d dark pixel(s) into the box at %d,%d",
        live_dark, mid_x, mid_y)
    say("over a white page: %d dark of %d on the stroke, %d off it",
        on_stroke, (half * 2 + 1) ^ 2, off_stroke)
    return string.format("BB8A overlay composited onto a type-%d framebuffer",
        bb:getType())
end)

-- ------------------------------------------------------------------ step 7

--[[--
A page turn, and the row a page nobody drew on must not keep.

`PageUpdate` is what ReaderPaging broadcasts; `ReaderView:onPageUpdate` sets
`state.page` and recalculates, and the plugin coalesces its own reaction onto
the next tick. Draw stays on across the turn, so page 2 gets a surface the
moment it is asked for one -- and leaving it again without a stroke on it has
to take that surface away with it.
]]
step("7 page turn, and what page 2 leaves behind", function(say)
    local Event = S.Event
    S.reader:handleEvent(Event:new("PageUpdate", 2))
    S.tick(4)
    expect(S.reader.view.state.page == 2,
        "the reader is on page %s", tostring(S.reader.view.state.page))
    expect(S.session:page() == 2,
        "the session is on page %s, the reader on 2", tostring(S.session:page()))
    local on_two = S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'page_ink' AND fixed_page = 2;")
    say("with Draw on, page 2 holds %d page_ink row(s) while it is open", on_two)

    S.reader:handleEvent(Event:new("PageUpdate", 1))
    S.tick(4)
    expect(S.session:page() == 1,
        "the session is on page %s after turning back", tostring(S.session:page()))
    S.reader:saveSettings()
    S.tick(2)

    expect(S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'page_ink' AND fixed_page = 2;") == 0,
        "page 2 kept a row nobody drew on")
    expect(S.count([[SELECT COUNT(*) FROM strokes s
                       JOIN canvases c ON c.id = s.canvas_id
                      WHERE c.surface_role = 'page_ink' AND c.fixed_page = 1;]]) == 1,
        "page 1 lost its stroke over the page turn")
    return "page 1 keeps its stroke, page 2 left no row"
end)

-- ------------------------------------------------------------------ step 8

--- Nothing reached the sidecar. On a runtime with the stylus API the legacy
--- direct-ink store is frozen: it is read for painting and never written
--- (ADR-39). Both compatibility identities are checked, because the freeze
--- would be just as broken if it wrote the old key.
step("8 the frozen sidecar is still empty", function(say)
    local settings = expect(S.reader.doc_settings, "the reader has no doc_settings")
    for _, key in ipairs({ "justdraw_strokes", "fingerink_strokes" }) do
        local value = settings:readSetting(key)
        expect(value == nil or next(value) == nil,
            "%s is not empty after drawing", key)
        say("%s = %s", key, value == nil and "absent" or "present but empty")
    end
    expect(S.plugin.legacy_frozen == true,
        "the plugin does not consider the sidecar frozen on this runtime")
    return "no ink reached the document sidecar"
end)

-- ------------------------------------------------------------------ step 9

step("9 close: the reader tears down and the database is released", function(say)
    S.reader:onClose()
    S.tick(4)
    expect(S.plugin.document_session == nil,
        "the page-ink session survived the close")
    expect(S.plugin.drawing == false, "drawing survived the close")
    expect(S.plugin.input_lease == nil, "the input lease survived the close")

    -- "No hooks left installed when drawing is off", against the Input this
    -- runtime actually has rather than a fake of it.
    expect(S.Input.stylus_callback == nil,
        "a stylus callback was left registered after the close")
    expect(rawget(S.Input.gesture_detector, "feedEvent") == nil,
        "the feedEvent wrapper was left on the gesture detector")
    expect(S.Capture.active ~= true, "the capture is still active")

    -- A second read-only connection is the proof the file was released with
    -- its contents committed, not merely that the handle went away.
    local strokes = S.count([[SELECT COUNT(*) FROM strokes s
                                JOIN canvases c ON c.id = s.canvas_id
                               WHERE c.surface_role = 'page_ink' AND c.fixed_page = 1;]])
    expect(strokes == 1, "the reopened database holds %d stroke(s)", strokes)
    local canvases = S.count("SELECT COUNT(*) FROM canvases WHERE surface_role = 'page_ink';")
    expect(canvases == 1, "the reopened database holds %d page_ink row(s)", canvases)
    say("reopened %s: %d page_ink canvas, %d stroke", S.db_path, canvases, strokes)
    return "closed cleanly, ink durable"
end)

-- ------------------------------------------------------------------ summary

if failures == 0 then
    print(string.format(
        "SUMMARY 9/9 OK -- %s, page %.0fx%.0f pt at scale %.4f, "
        .. "1 page_ink canvas, 1 stroke of %s points, sidecar empty",
        S.revision or "?", S.native_w or 0, S.native_h or 0,
        S.transform and S.transform.scale or 0,
        tostring(S.persisted_points)))
else
    print(string.format("SUMMARY %d step(s) failed", failures))
end
-- A home this script made is its own to remove -- except after a failure,
-- where the database and the log are the evidence, and a KO_HOME that was
-- handed in, which belongs to whoever handed it in.
if S.home_created then
    if failures == 0 and os.getenv("JUSTDRAW_SMOKE_KEEP") ~= "1" then
        os.execute("rm -rf '" .. S.home .. "'")
    else
        print("kept " .. S.home)
    end
end
os.exit(failures == 0 and 0 or 1)
