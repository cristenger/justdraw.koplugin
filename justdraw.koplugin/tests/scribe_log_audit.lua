--[[--
scribe_log_audit: a device session's stability, as numbers out of its log.

The Scribe's Wacom reports at up to 360 Hz. When this process stops reading
for long enough the kernel discards frames and says so once, with
`SYN_DROPPED`; every one of those is a stroke that may now carry a corner
that was never drawn. The refresh policy (ADR-26/36/43) and the write
queue (ADR-42) exist so that number stays at zero, and a policy that only
"looks fine" is how the 2026-09-02 session shipped with 79 of them. This
script is the gate: it counts what the kernel dropped, what the plugin
asked of the panel and when, and what SQLite did under the pen.

It parses KOReader's own debug lines, so the log has to be recorded with
verbose logging on. Verbose logging loads the loop too, which makes this
the stricter of the two device checks; the diagnostics report covers the
quiet run.

Usage:
  luajit justdraw.koplugin/tests/scribe_log_audit.lua <crash.log>
      [--all] [--gate] [--max-ui-rate=15] [--max-fast-rate=60] [--top=10]

By default only the last KOReader session in the file is read (from the
last "[*] Version:" banner); --all reads everything. --gate exits 1 unless
every gate holds: SYN_DROPPED = 0, no commit with BTN_TOUCH down, no
partial with BTN_TOUCH down, and no contact whose ui or fast refresh rate
exceeds the limits.
]]

local path = arg[1]
if not path then
    io.stderr:write("usage: scribe_log_audit.lua <crash.log> [--all] [--gate] [--max-ui-rate=N] [--max-fast-rate=N] [--top=N]\n")
    os.exit(2)
end

local opts = { all = false, gate = false, max_ui_rate = 15, max_fast_rate = 60, top = 10 }
for i = 2, #arg do
    local a = arg[i]
    if a == "--all" then
        opts.all = true
    elseif a == "--gate" then
        opts.gate = true
    else
        local key, value = a:match("^%-%-([%w%-]+)=(.+)$")
        if not key then
            io.stderr:write("unknown argument: " .. a .. "\n")
            os.exit(2)
        end
        opts[key:gsub("%-", "_")] = tonumber(value) or value
    end
end

-- Pass 1: where the last session starts.
local start_line = 1
if not opts.all then
    local n = 0
    for line in io.lines(path) do
        n = n + 1
        if line:find("[*] Version:", 1, true) then start_line = n end
    end
end

local totals = {
    frames = 0, drops = 0, drops_after_commit = 0, drops_unanswered = 0,
    ui = 0, fast = 0, partial = 0, full = 0,
    ui_touch = 0, fast_touch = 0, partial_touch = 0,
    commits = 0, commits_touch = 0, commit_ms_max = 0,
    repairs = 0, desyncs = 0,
    wait_submission = 0, wait_completion = 0,
}
local contacts = {}
local contact = nil          -- the open BTN_TOUCH bracket
local clock = nil            -- seconds, from the last input event's `time:`
local last_commit_line = -math.huge
local pending_drops = {}     -- SYN_DROPPED lines waiting for a desync line
local buckets = {}           -- floor(clock) -> { ui = n, fast = n }
local max_bucket = { ui = 0, fast = 0 }

local function bucket(kind)
    if not clock then return end
    local key = math.floor(clock)
    local b = buckets[key]
    if not b then b = { ui = 0, fast = 0 }; buckets[key] = b end
    b[kind] = b[kind] + 1
    if b[kind] > max_bucket[kind] then max_bucket[kind] = b[kind] end
end

local n = 0
for line in io.lines(path) do
    n = n + 1
    if n >= start_line then
        local stamp = line:match("time: (%d+%.%d+)")
        if stamp then clock = tonumber(stamp) end

        if line:find("(SYN_REPORT)", 1, true) then
            totals.frames = totals.frames + 1
            if contact then contact.frames = contact.frames + 1 end
        elseif line:find("(SYN_DROPPED)", 1, true) then
            totals.drops = totals.drops + 1
            if n - last_commit_line <= 40 then
                totals.drops_after_commit = totals.drops_after_commit + 1
            end
            pending_drops[#pending_drops + 1] = n
            if contact then contact.drops = contact.drops + 1 end
        elseif line:find("JustDraw: evdev desync", 1, true) then
            totals.desyncs = totals.desyncs + 1
            if #pending_drops > 0 then table.remove(pending_drops, 1) end
        end

        local touch = line:match("%(BTN_TOUCH%), value: (%d)")
        if touch == "1" and not contact then
            contact = { line = n, at = clock, frames = 0, drops = 0,
                        ui = 0, fast = 0, partial = 0, commits = 0 }
        elseif touch == "0" and contact then
            contact.until_line = n
            contact.duration = (clock and contact.at) and (clock - contact.at) or 0
            contacts[#contacts + 1] = contact
            contact = nil
        end

        local mode = line:match("DEBUG refresh: ([%w%-]+)")
        if mode == "ui-mode" then mode = "ui" end
        if mode == "ui" or mode == "fast" or mode == "partial" or mode == "full" then
            totals[mode] = totals[mode] + 1
            if mode ~= "full" then bucket(mode == "partial" and "ui" or mode) end
            if contact then
                if mode ~= "full" then contact[mode] = contact[mode] + 1 end
                if mode == "ui" then totals.ui_touch = totals.ui_touch + 1
                elseif mode == "fast" then totals.fast_touch = totals.fast_touch + 1
                elseif mode == "partial" then totals.partial_touch = totals.partial_touch + 1 end
            end
        elseif mode == "wait" then
            if line:find("submission", 1, true) then
                totals.wait_submission = totals.wait_submission + 1
            else
                totals.wait_completion = totals.wait_completion + 1
            end
        end

        if line:find("JustDraw: canvas commit,", 1, true) then
            totals.commits = totals.commits + 1
            last_commit_line = n
            local ms = tonumber(line:match("([%d%.]+) ms"))
            if ms and ms > totals.commit_ms_max then totals.commit_ms_max = ms end
            if contact then
                totals.commits_touch = totals.commits_touch + 1
                contact.commits = contact.commits + 1
            end
        elseif line:find("JustDraw: canvas repair,", 1, true) then
            totals.repairs = totals.repairs + 1
        end

        -- A drop the plugin never answered within 60 lines.
        while #pending_drops > 0 and n - pending_drops[1] > 60 do
            table.remove(pending_drops, 1)
            totals.drops_unanswered = totals.drops_unanswered + 1
        end
    end
end
totals.drops_unanswered = totals.drops_unanswered + #pending_drops
if contact then contacts[#contacts + 1] = contact end   -- still down at the end

local function rate(count, duration)
    if not duration or duration <= 0 then return 0 end
    return count / duration
end

local worst_ui, worst_fast = 0, 0
for _, c in ipairs(contacts) do
    c.ui_rate = rate(c.ui, c.duration)
    c.fast_rate = rate(c.fast, c.duration)
    if c.ui_rate > worst_ui then worst_ui = c.ui_rate end
    if c.fast_rate > worst_fast then worst_fast = c.fast_rate end
end

print(string.format("scribe_log_audit: %s (from line %d%s)", path, start_line,
    opts.all and ", whole file" or ", last session"))
print(string.format("frames %d   SYN_DROPPED %d   (after a commit %d, unanswered by the plugin %d)   desyncs %d",
    totals.frames, totals.drops, totals.drops_after_commit, totals.drops_unanswered, totals.desyncs))
print(string.format("refresh ui %d (under contact %d)   fast %d (%d)   partial %d (%d)   full %d",
    totals.ui, totals.ui_touch, totals.fast, totals.fast_touch,
    totals.partial, totals.partial_touch, totals.full))
print(string.format("waits: submission %d   completion %d", totals.wait_submission, totals.wait_completion))
print(string.format("commits %d (under contact %d, slowest %.1f ms)   repairs %d",
    totals.commits, totals.commits_touch, totals.commit_ms_max, totals.repairs))
print(string.format("contacts %d   worst ui rate %.0f/s   worst fast rate %.0f/s   busiest second: ui %d, fast %d",
    #contacts, worst_ui, worst_fast, max_bucket.ui, max_bucket.fast))

table.sort(contacts, function(a, b)
    if a.drops ~= b.drops then return a.drops > b.drops end
    return a.ui_rate > b.ui_rate
end)
print(string.format("%-14s %8s %7s %6s %6s %8s %8s %7s", "lines", "dur(s)", "frames",
    "drops", "ui", "ui/s", "fast/s", "commits"))
for i = 1, math.min(opts.top, #contacts) do
    local c = contacts[i]
    print(string.format("%-14s %8.2f %7d %6d %6d %8.0f %8.0f %7d",
        c.line .. "-" .. tostring(c.until_line or "?"), c.duration or 0, c.frames,
        c.drops, c.ui, c.ui_rate, c.fast_rate, c.commits))
end

if opts.gate then
    local failures = {}
    if totals.drops > 0 then failures[#failures + 1] = "SYN_DROPPED " .. totals.drops .. " (must be 0)" end
    if totals.commits_touch > 0 then failures[#failures + 1] = "commits under contact " .. totals.commits_touch .. " (must be 0)" end
    if totals.partial_touch > 0 then failures[#failures + 1] = "partial under contact " .. totals.partial_touch .. " (must be 0)" end
    if worst_ui > opts.max_ui_rate then failures[#failures + 1] = string.format("ui rate %.0f/s > %d", worst_ui, opts.max_ui_rate) end
    if worst_fast > opts.max_fast_rate then failures[#failures + 1] = string.format("fast rate %.0f/s > %d", worst_fast, opts.max_fast_rate) end
    if totals.drops_unanswered > 0 then failures[#failures + 1] = "drops the plugin did not answer " .. totals.drops_unanswered end
    if #failures == 0 then
        print("GATE: PASS")
    else
        print("GATE: FAIL")
        for _, f in ipairs(failures) do print("  - " .. f) end
        os.exit(1)
    end
end
