return function(ctx)
    local t = ctx.t
    local support = ctx.support
    local Adapter = require("ink_notebook_input")
    local Session = require("ink_notebook_session")

    local function fixture(mode, opts)
        opts = opts or {}
        local store = support.newNotebookStore{
            pages = { { id = 11, notebook_id = 1, sort_key = 1024,
                logical_w = 1000, logical_h = 1400, template_kind = "blank" } },
        }
        local session = Session.new{
            repository = store,
            schedule = function(fn) fn() end,
            scheduleIn = opts.scheduleIn or function() end,
            unschedule = opts.unschedule or function() end,
            fit_rect = opts.fit_rect or { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = opts.clip_rect or opts.fit_rect
                or { x = 0, y = 0, w = 1000, h = 1400 },
        }
        session:open(1)
        local dirties, dirty_boxes, errors, edits = 0, {}, {}, 0
        local edit_saw_contact, physical_ends = {}, {}
        local domain_errors = {}
        local adapter
        adapter = Adapter.new{
            get_mode = function() return mode or "stylus" end,
            get_pen_width = opts.get_pen_width,
            eraser_radius = opts.eraser_radius,
            touch_passthrough = opts.touch_passthrough,
            stylus_passthrough = opts.stylus_passthrough,
            now = opts.now,
            control_guard = opts.control_guard,
            max_open_points = opts.max_open_points,
            max_contact_samples = opts.max_contact_samples,
            on_dirty = function(box, kind, _, _, source)
                dirties = dirties + 1
                dirty_boxes[#dirty_boxes + 1] = {
                    box = box, kind = kind, source = source,
                }
            end,
            on_edit_changed = function()
                edits = edits + 1
                edit_saw_contact[#edit_saw_contact + 1] = adapter:hasActiveContact(session)
            end,
            on_stylus_frame = opts.on_stylus_frame,
            on_physical_contact_end = function(_, reason)
                physical_ends[#physical_ends + 1] = reason
                if opts.on_physical_contact_end then
                    opts.on_physical_contact_end(session, reason)
                end
            end,
            on_error = function(reason) errors[#errors + 1] = reason end,
            on_domain_error = function(reason, active_session)
                domain_errors[#domain_errors + 1] = {
                    reason = reason, session = active_session,
                }
                if opts.on_domain_error then
                    opts.on_domain_error(reason, active_session)
                end
            end,
            get_stylus_trace = opts.get_stylus_trace,
        }
        local spec = adapter:captureSpec(session, session:currentPage(),
            session:surface():transform())
        return session, store, adapter, spec,
            function() return dirties end, errors, dirty_boxes,
            function() return edits end, edit_saw_contact, physical_ends,
            domain_errors
    end

    t:describe("ink_notebook_input / hardware-neutral surface adapter")

    t:case("capture lifecycle resets diagnostic contact history", function()
        local Trace = require("ink_stylus_trace")
        local trace = Trace.new{
            source = "notebook", now = function() return 0 end,
            emit = function() end,
        }
        trace:deltas(4, 4, 1, 10, 10, 100)
        local _, _, adapter = fixture("stylus", {
            get_stylus_trace = function() return trace end,
        })
        local dx, dy, dt = trace:deltas(4, 4, 1, 900, 700, 500)
        t:eq(dx, nil, "new lease has no inherited x delta")
        t:eq(dy, nil, "new lease has no inherited y delta")
        t:eq(dt, nil, "new lease has no inherited time delta")

        trace:deltas(4, 4, 1, 910, 710, 510)
        adapter:abort()
        dx, dy, dt = trace:deltas(4, 4, 1, 20, 30, 900)
        t:eq(dx, nil, "abort begins another diagnostic epoch")
        t:eq(dy, nil, "abort drops prior coordinates")
        t:eq(dt, nil, "abort drops prior timestamp")
    end)

    t:case("stylus points become one queued logical stroke", function()
        local session, _, adapter, spec, dirties, _, _, edits, edit_contacts = fixture("stylus")
        t:eq(spec.backend, "stylus", "modern route selected")
        -- The frame that opens a contact carries whatever the persistent slot
        -- last held, so it is a baseline; the stroke starts at the first pair
        -- that has moved on both axes.
        t:eq(spec.stylus_handler{
            slot = 4, id = 9, x = 10, y = 10, tool = 1,
        }, true, "pen dominated")
        spec.stylus_handler{ slot = 4, id = 9, x = 20, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 9, x = 40, y = 60, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 40, y = 60, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "one durable operation queued")
        t:eq(#session:surface():cache():strokes(), 1, "one raster stroke")
        t:check(dirties() >= 2, "live ink requested repaint")
        t:eq(edits(), 1, "one lightweight capability update follows the stroke")
        t:eq(edit_contacts[1], false, "capabilities update only after lift bookkeeping")
        t:eq(adapter:hasActiveContact(session), false, "lift clears gate")
    end)

    t:case("the notebook stores the chosen style, not the hardware tool", function()
        -- Until now the row recorded which physical tool was held; the column
        -- now means style, and phase-1 default style is pen even under a pen
        -- reporting tool=1. Injection of non-pen styles arrives with Task 4.
        -- Same build as "stylus points become one queued logical stroke",
        -- with the style-resolution seam asserted on the built stroke.
        local session, _, adapter, spec, dirties, _, _, edits, edit_contacts = fixture("stylus")
        t:eq(spec.backend, "stylus", "modern route selected")
        t:eq(spec.stylus_handler{
            slot = 4, id = 9, x = 10, y = 10, tool = 1,
        }, true, "pen dominated")
        spec.stylus_handler{ slot = 4, id = 9, x = 20, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 9, x = 40, y = 60, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 40, y = 60, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "one durable operation queued")
        t:eq(#session:surface():cache():strokes(), 1, "one raster stroke")
        t:check(dirties() >= 2, "live ink requested repaint")
        t:eq(edits(), 1, "one lightweight capability update follows the stroke")
        t:eq(edit_contacts[1], false, "capabilities update only after lift bookkeeping")
        t:eq(adapter:hasActiveContact(session), false, "lift clears gate")
        local strokes = session:surface():cache():strokes()
        t:eq(strokes[1].tool, 1, "a plain pen contact resolves to Style.PEN")
    end)

    t:case("a valid live-raster token prevents repaint on stylus lift", function()
        local session, _, _, spec = fixture("stylus")
        local cache = session:surface():cache()
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        local before = #cache:buffer().writes
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 20, tool = 0 }
        t:eq(#cache:buffer().writes, before,
            "registration does not rasterize the finished stroke again")
        t:eq(#cache:strokes(), 1, "metadata is still registered")
    end)

    t:case("a stale live-raster token repaints once and publishes coverage", function()
        local session, _, _, spec, _, _, dirty_boxes = fixture("stylus")
        local cache = session:surface():cache()
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        cache.generation = cache.generation + 1
        local before_writes, before_dirty = #cache:buffer().writes, #dirty_boxes
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 20, tool = 0 }
        t:check(#cache:buffer().writes > before_writes,
            "generation mismatch falls back to rasterizing the stroke")
        t:eq(#dirty_boxes, before_dirty + 1,
            "fallback coverage is returned to the visible host")
        t:eq(dirty_boxes[#dirty_boxes].kind, "ink", "fallback remains live ink")
    end)

    t:case("queue backpressure repairs live ink and recovers automatically", function()
        local session, _, adapter, spec, _, errors = fixture("stylus")
        local surface = session:surface()
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        surface.queue.hard_ops = 1

        spec.stylus_handler{ slot = 4, id = 2, x = 30, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 2, x = 40, y = 40, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 40, y = 40, tool = 0 }
        t:eq(errors[1], "queue_backpressure", "transient rejection is classified")
        t:eq(#errors, 1, "one congestion episode reports once")
        t:eq(surface.queue:isFailed(), false, "backpressure is not a save failure")
        t:eq(surface:pendingWrites(), 1, "the admitted stroke remains queued")
        t:eq(#surface:cache():strokes(), 1, "rejected live ink was repaired")
        t:eq(adapter:hasActiveContact(session), false, "physical lift clears ownership")

        t:eq(surface:flush(), true, "urgent work can commit without Retry")
        spec.stylus_handler{ slot = 4, id = 3, x = 50, y = 50, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 50, y = 50, tool = 0 }
        t:eq(surface:pendingWrites(), 1, "the next contact is accepted automatically")
        t:eq(#surface:cache():strokes(), 2, "recovery keeps the durable stroke")
    end)

    t:case("mid-contact backpressure stays owned through urgent commit and lift", function()
        local scheduler = support.newScheduler()
        local session, _, adapter, spec, _, errors, _, _, _, physical_ends =
            fixture("stylus", {
                schedule = function(fn) scheduler:schedule(fn) end,
                scheduleIn = function(delay, fn) scheduler:scheduleIn(delay, fn) end,
                unschedule = function(fn) scheduler:unschedule(fn) end,
            })
        local surface = session:surface()
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        surface.queue.hard_ops = 1
        local ends_before = #physical_ends

        spec.stylus_handler{ slot = 4, id = 2, x = 30, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 2, x = 40, y = 40, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 2, x = 1200, y = 40, tool = 1 }
        t:eq(errors[#errors], "queue_backpressure", "logical finish is rejected")
        t:eq(#surface:cache():strokes(), 1, "rejected live stroke is repaired")
        t:eq(adapter:hasActiveContact(session), true,
            "physical ownership survives the logical finish")
        t:eq(#physical_ends, ends_before, "no physical end is invented")
        t:eq(surface:pendingWrites(), 1, "admitted operation remains queued")

        scheduler:drain()
        t:eq(surface:pendingWrites(), 0, "urgent commit drains on the next tick")
        t:eq(adapter:hasActiveContact(session), true,
            "commit does not release the still-supported pen")
        t:eq(#physical_ends, ends_before, "commit is not a contact boundary")

        spec.stylus_handler{ slot = 4, id = -1, x = 1200, y = 40, tool = 0 }
        t:eq(adapter:hasActiveContact(session), false, "physical lift clears ownership")
        t:eq(#physical_ends, ends_before + 1, "one boundary is published at lift")
        spec.stylus_handler{ slot = 4, id = 3, x = 60, y = 60, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 60, y = 60, tool = 0 }
        t:eq(surface:pendingWrites(), 1, "next contact recovers without Retry")
    end)

    t:case("oversized operation repairs ink and requests domain teardown", function()
        local session, _, _, spec, _, errors, _, _, _, _, domain_errors =
            fixture("stylus")
        local surface = session:surface()
        surface.queue.max_single_op_bytes = 0
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        t:eq(errors[1], "operation_too_large", "visible error is classified")
        t:eq(domain_errors[1], nil, "teardown waits for residual filtering")
        local kept = spec.frame_handler{
            { slot = 0, id = 8, x = 20, y = 20, tool = 0 },
        }
        t:eq(#kept, 0, "same-frame palm is filtered before teardown")
        t:eq(domain_errors[1].reason, "operation_too_large",
            "fatal seam requests deferred release")
        t:eq(domain_errors[1].session, session, "release is bound to this session")
        t:eq(#surface:cache():strokes(), 0, "live ink is repaired")
        t:eq(surface.queue:isFailed(), false, "SQLite failure latch remains clear")
    end)

    t:case("fatal stylus teardown waits for the complete SYN pipeline", function()
        local Capture = require("ink_capture")
        local Replay = require("input_replay")
        local input = ctx.reset{ wacom_protocol = true }
        local session, _, _, spec = fixture("stylus", {
            on_domain_error = function()
                Capture:removeDeferred()
            end,
        })
        session:surface().queue.max_single_op_bytes = 0
        local installed = Capture:installStylus(
            spec.stylus_handler, spec.frame_handler)
        t:eq(installed, true, "real capture pipeline installed")
        local callback = input.stylus_callback
        local replay = Replay.new{
            mode = "integration", input = input, capture = Capture,
        }
        replay:set(4, { id = 1, x = 10, y = 10, tool = Capture.TOOL_PEN })
        replay:syn()

        replay:set(4, { id = -1, x = 10, y = 10, tool = Capture.TOOL_FINGER })
        replay:set(5, { id = 2, x = 30, y = 30, tool = Capture.TOOL_PEN })
        replay:set(0, { id = 9, x = 20, y = 20, tool = Capture.TOOL_FINGER })
        local _, _, dominated = replay:syn()
        t:eq(#dominated, 2, "all stylus slots remain dominated through the frame")
        t:eq(#input.gesture_detector.last_slots, 0,
            "same-frame palm never reaches GestureDetector")
        t:eq(Capture.active, false, "capture becomes inert after filtering")
        t:eq(input.stylus_callback, callback,
            "callback remains registered until the safe tick")
        ctx.env.UIManager:flush()
        t:eq(input.stylus_callback, nil, "safe tick removes the callback")
    end)

    t:case("point budget repairs the whole stroke and owns through lift", function()
        local session, _, adapter, spec, _, errors, _, _, _, physical_ends =
            fixture("stylus", { max_open_points = 2 })
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 30, y = 30, tool = 1 }
        t:eq(spec.stylus_handler{
            slot = 4, id = 1, x = 40, y = 40, tool = 1,
        }, true, "over-budget sample stays dominated")
        t:eq(errors[1], "point_budget", "the bounded reason is reported")
        t:eq(session:surface():pendingWrites(), 0, "no prefix is persisted")
        t:eq(#session:surface():cache():strokes(), 0, "live prefix is repaired")
        t:eq(adapter:hasActiveContact(session), true,
            "lifecycle remains blocked until the physical boundary")
        spec.stylus_handler{ slot = 4, id = -1, x = 40, y = 40, tool = 0 }
        t:eq(physical_ends[1], "owner_lift", "one physical end is published")
        t:eq(adapter:hasActiveContact(session), false, "lift clears the gate")

        spec.stylus_handler{ slot = 4, id = 2, x = 60, y = 70, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 60, y = 70, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "the next contact rearms normally")
    end)

    t:case("sample budget closes eraser work without rolling accepted deletes back", function()
        local session, _, adapter, spec, _, errors = fixture("stylus", {
            max_contact_samples = 2,
        })
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 20, tool = 0 }
        spec.stylus_handler{ slot = 4, id = 2, x = 15, y = 15, tool = 2 }
        spec.stylus_handler{ slot = 4, id = 2, x = 16, y = 16, tool = 2 }
        spec.stylus_handler{ slot = 4, id = 2, x = 17, y = 17, tool = 2 }
        t:eq(errors[1], "sample_budget", "orphaned eraser contact is bounded")
        t:eq(#session:surface():cache():strokes(), 0,
            "erasures accepted before the cap remain applied")
        t:eq(adapter.erase_ctx, nil, "erase context closes exactly at the cap")
        t:eq(adapter:hasActiveContact(session), true, "ownership remains until lift")
        spec.stylus_handler{ slot = 4, id = -1, x = 17, y = 17, tool = 0 }
        t:eq(adapter:hasActiveContact(session), false, "lift rearms input")
    end)

    t:case("physical contact boundaries publish even without an edit", function()
        local _, _, adapter, spec, _, _, _, edits, _, physical_ends =
            fixture("stylus", {
                stylus_passthrough = function(x) return x >= 400 end,
            })
        spec.stylus_handler{ slot = 4, id = 1, x = 450, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 450, y = 10, tool = 0 }
        t:eq(edits(), 0, "a control tap did not edit paper")
        t:eq(#physical_ends, 1, "passthrough lift still publishes a boundary")
        t:eq(physical_ends[1], "owner_lift", "boundary reason is stable")

        spec.stylus_handler{ slot = 4, id = 2, tool = 1 }
        adapter:abort()
        t:eq(#physical_ends, 2, "external teardown publishes once")
        t:eq(physical_ends[2], "external_abort", "teardown reason is distinct")
    end)

    t:case("two stylus dots at the same coordinate are both retained", function()
        local session, _, _, spec = fixture("stylus")
        for id = 1, 2 do
            spec.stylus_handler{ slot = 4, id = id, x = 10, y = 10, tool = 1 }
            spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        end
        t:eq(session:surface():pendingWrites(), 2, "both contacts are durable")
        t:eq(#session:surface():cache():strokes(), 2, "both dots remain visible")
    end)

    t:case("hover is consumed without becoming a contact lift", function()
        local session, _, adapter, spec = fixture("stylus")
        t:eq(spec.stylus_handler{
            slot = 4, id = nil, x = 80, y = 90, tool = 1,
        }, true, "pre-contact hover is consumed")
        t:eq(adapter.last_lift_x, nil, "hover did not rewrite lift history")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        t:eq(spec.stylus_handler{
            slot = 4, id = nil, x = 15, y = 15, tool = 1,
        }, true, "hover-like frame does not end an active contact")
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 20, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "one uninterrupted stroke")
    end)

    t:case("coordinate-less pen down waits for geometry and still inks", function()
        local session, _, adapter, spec = fixture("stylus")
        t:eq(spec.stylus_handler{ slot = 4, id = 1, tool = 1 }, true,
            "unknown contact is dominated until it can be classified")
        t:eq(adapter:hasActiveContact(session), true, "lifecycle gate sees it")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "later coordinates completed ink")
    end)

    t:case("sticky coordinates are never used to classify or paint a new contact", function()
        local session, _, _, spec = fixture("stylus")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        -- The next contact really begins outside paper. Its first frame still
        -- contains the previous lift; it must not paint another dot at 10,10.
        spec.stylus_handler{ slot = 4, id = 2, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 2, x = 1200, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 1200, y = 10, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "no phantom second stroke")

        -- Conversely, a previous outside lift cannot latch a genuine inside
        -- contact as passthrough before its first fresh coordinate arrives.
        t:eq(spec.stylus_handler{
            slot = 4, id = 3, x = 1200, y = 10, tool = 1,
        }, true, "sticky outside coordinate stays undecided")
        spec.stylus_handler{ slot = 4, id = 3, x = 30, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 30, y = 30, tool = 0 }
        t:eq(session:surface():pendingWrites(), 2, "fresh inside coordinate inks")
    end)

    t:case("palm contacts on paper are filtered but chrome can pass", function()
        local _, _, _, spec = fixture("stylus")
        local paper = spec.frame_handler{
            { slot = 0, id = 1, x = 100, y = 100, tool = 0 },
        }
        t:eq(#paper, 0, "paper contact never reaches gestures")
        spec.frame_handler{ { slot = 0, id = -1, x = 100, y = 100, tool = 0 } }
        local chrome = spec.frame_handler{
            { slot = 1, id = 2, x = 1200, y = 100, tool = 0 },
        }
        t:eq(#chrome, 1, "outside-paper control contact passes")
    end)

    t:case("a residual palm delays capability refresh until every contact lifts", function()
        local _, _, _, spec, _, _, _, edits, _, physical_ends = fixture("stylus")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.frame_handler{ { slot = 0, id = 2, x = 20, y = 20, tool = 0 } }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        t:eq(edits(), 0, "palm keeps controls gated")
        t:eq(#physical_ends, 0, "stylus lift is not aggregate zero while palm remains")
        spec.frame_handler{ { slot = 0, id = -1, x = 20, y = 20, tool = 0 } }
        t:eq(edits(), 1, "last lift publishes the new capabilities")
        t:eq(#physical_ends, 1, "only aggregate zero publishes the boundary")
        t:eq(physical_ends[1], "residual_lift", "the final residual owns the boundary")
    end)

    t:case("aggregate residual and finger lifts rearm editor quality cleanup", function()
        local Editor = require("ink_notebook_editor")
        local Geom = require("ui/geometry")
        for _, case in ipairs({
            { mode = "stylus", down = function(spec)
                spec.frame_handler{
                    { slot = 0, id = 2, x = 20, y = 20, tool = 0 },
                }
            end, lift = function(spec)
                spec.frame_handler{
                    { slot = 0, id = -1, x = 20, y = 20, tool = 0 },
                }
            end },
            { mode = "finger", down = function(spec)
                spec.frame_handler{
                    { slot = 0, id = 2, x = 1200, y = 20, tool = 0 },
                }
            end, lift = function(spec)
                spec.frame_handler{
                    { slot = 0, id = -1, x = 1200, y = 20, tool = 0 },
                }
            end },
        }) do
            ctx.reset()
            local editor
            local session, _, adapter, spec, _, _, _, edits =
                fixture(case.mode, {
                    on_physical_contact_end = function(active, reason)
                        editor:onPhysicalContactEnd(active, reason)
                    end,
                })
            local scheduler = support.newScheduler()
            local controller = {
                activeSession = function() return session end,
                uiSnapshot = function()
                    return {
                        state = "ready", writable = true, can_ink = true,
                        can_navigate = true, can_close = true,
                        has_previous = false, has_next = false, page_count = 1,
                        can_undo = true, pending_writes = 0,
                    }
                end,
            }
            editor = Editor:new{
                controller = controller,
                notebook = { id = 1, title = "Notes", page_count = 1 },
                get_live_fast = function() return true end,
                has_active_contact = function()
                    return adapter:hasActiveContact(session)
                end,
                quality_schedule_in = function(delay, action)
                    scheduler:scheduleIn(delay, action)
                end,
                quality_unschedule = function(action)
                    scheduler:unschedule(action)
                end,
            }
            local transform = session:surface():transform()
            local paper = editor.layout_geometry.paper_rect
            editor:onDirty(Geom:new{
                    x = paper.x + 10, y = paper.y + 10, w = 8, h = 8,
                }, "ink", session, transform,
                { x = 10, y = 10, w = 8, h = 8 })
            editor:onEditChanged(session)
            case.down(spec)
            scheduler:advance(0.35)
            t:eq(editor.quality_waiting_for_contact_end, true,
                case.mode .. " contact owns the expired cleanup")
            local edits_before_lift = edits()
            case.lift(spec)
            t:eq(edits(), edits_before_lift,
                case.mode .. " contact made no edit")
            t:eq(scheduler:pending(), 1,
                case.mode .. " aggregate zero transition rearms cleanup")
            scheduler:advance(0.35)
            t:eq(ctx.env.UIManager.dirty[#ctx.env.UIManager.dirty][2], "partial",
                case.mode .. " cleanup completes after lift")
        end
    end)

    t:case("control touch stays guarded for 300 ms after stylus lift", function()
        local clock = require("ui/time")
        clock._set(0)
        local _, _, adapter, spec = fixture("stylus")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        clock._set(clock.ms(299))
        t:eq(adapter:controlTouchAllowed(), false, "299 ms remains guarded")
        clock._set(clock.ms(300))
        t:eq(adapter:controlTouchAllowed(), true, "guard expires at 300 ms")
        clock._set(0)
    end)

    t:case("stylus overlay regions pass through without ink underneath", function()
        local blocked = true
        local session, _, _, spec = fixture("stylus", {
            stylus_passthrough = function(x)
                return blocked and x >= 400 and x < 500
            end,
        })
        t:eq(spec.stylus_handler{
            slot = 4, id = 1, x = 450, y = 100, tool = 1,
        }, false, "fresh pen down reaches an overlay inside the page")
        t:eq(spec.stylus_handler{
            slot = 4, id = -1, x = 450, y = 100, tool = 0,
        }, false, "overlay sequence remains passthrough through lift")
        t:eq(session:surface():pendingWrites(), 0, "no ink under control")

        spec.stylus_handler{ slot = 4, id = 2, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 450, y = 100, tool = 0 }
        t:eq(session:surface():pendingWrites(), 0,
            "coordinate-less down cannot recover a dot under overlay")

        blocked = false
        spec.stylus_handler{ slot = 4, id = 3, x = 100, y = 100, tool = 1 }
        blocked = true
        spec.stylus_handler{ slot = 4, id = 3, x = 450, y = 100, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 450, y = 100, tool = 0 }
        t:eq(session:surface():pendingWrites(), 0,
            "overlay appearing mid-contact repairs and suspends live ink")

        blocked = false
        spec.stylus_handler{ slot = 4, id = 4, x = 100, y = 100, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 100, y = 100, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1,
            "callback remains configured for later paper contacts")
    end)

    t:case("two stylus taps can activate the same control pixel", function()
        local _, _, _, spec = fixture("stylus", {
            stylus_passthrough = function(x)
                return x >= 400 and x < 500
            end,
        })
        for id = 1, 2 do
            local down = spec.stylus_handler{
                slot = 4, id = id, x = 450, y = 100, tool = 1,
            }
            local update = spec.stylus_handler{
                slot = 4, id = id, x = 450, y = 100, tool = 1,
            }
            local lift = spec.stylus_handler{
                slot = 4, id = -1, x = 450, y = 100, tool = 0,
            }
            if id == 1 then
                t:eq(down, false, "first control down passes")
            else
                t:eq(down, true, "one sticky tracking-id frame is suppressed")
                t:eq(update, false,
                    "the next same-position frame starts a coherent control contact")
            end
            t:eq(lift, false, "control lift passes")
        end
    end)

    t:case("the physical eraser removes ink through the same surface", function()
        local session, _, _, spec, _, _, _, edits = fixture("stylus")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 20, y = 20, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 20, tool = 0 }
        spec.stylus_handler{ slot = 4, id = 2, x = 15, y = 15, tool = 2 }
        spec.stylus_handler{ slot = 4, id = -1, x = 15, y = 15, tool = 0 }
        t:eq(#session:surface():cache():strokes(), 0, "eraser hit removed stroke")
        t:eq(session:surface():pendingWrites(), 0,
            "pending insert and erase cancel without flash writes")
        t:eq(edits(), 2, "pen and one eraser contact each update capabilities once")
    end)

    t:case("the eraser cuts a notebook stroke instead of swallowing it", function()
        local session, _, _, spec = fixture("stylus")
        -- Draw a 4-point diagonal-ish stroke (frame 1 is the baseline).
        spec.stylus_handler{ slot = 4, id = 1, x = 100, y = 500, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 200, y = 505, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 300, y = 510, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 400, y = 515, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 500, y = 520, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 500, y = 520, tool = 0 }
        t:eq(#session:surface():cache():strokes(), 1, "one stroke drawn")
        local drawn = session:surface():cache():strokes()[1].point_count
        t:check(drawn >= 4, "with enough points to cut (" .. drawn .. ")")
        -- Cut it mid-way: two eraser samples straddling the stroke, whose
        -- capsule crosses it near x = 350.
        spec.stylus_handler{ slot = 4, id = 2, x = 340, y = 300, tool = 2 }
        spec.stylus_handler{ slot = 4, id = 2, x = 360, y = 700, tool = 2 }
        spec.stylus_handler{ slot = 4, id = -1, x = 360, y = 700, tool = 0 }
        local metas = session:surface():cache():strokes()
        t:eq(#metas, 2, "the sweep left two fragments")
        t:check(metas[1].from_erase and metas[2].from_erase, "flagged as debris")
    end)

    --[[--
    One erase contact is one count, on this surface too.

    The sequence asks `classify` again on every frame while the geometry is
    still unproven, so a counter placed there without consulting `coherent`
    fires several times for a single contact and once more for contacts that
    never erase at all. A unit test of the counters cannot see that; only
    driving the real route can.
    ]]
    t:case("an erase contact is counted once on the notebook surface", function()
        local Capture = require("ink_capture")
        local session, _, _, spec = fixture("stylus")
        Capture:resetEraserCounts()

        spec.stylus_handler{ slot = 4, id = 2, x = 15, y = 15, tool = 2 }
        spec.stylus_handler{ slot = 4, id = 2, x = 40, y = 60, tool = 2 }
        spec.stylus_handler{ slot = 4, id = 2, x = 70, y = 95, tool = 2 }
        spec.stylus_handler{ slot = 4, id = -1, x = 70, y = 95, tool = 0 }
        local by_button, by_tool = Capture:eraserCounts()
        t:eq(by_button, 0, "no barrel button was held")
        t:eq(by_tool, 1, "three samples are still one erase contact")

        spec.stylus_handler{ slot = 4, id = 3, x = 200, y = 200, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 3, x = 260, y = 250, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 260, y = 250, tool = 0 }
        by_button, by_tool = Capture:eraserCounts()
        t:eq(by_tool, 1, "and an ink contact adds nothing")
        t:check(session ~= nil, "the surface stayed usable throughout")
    end)

    t:case("every routed stylus frame, hover included, reaches on_stylus_frame", function()
        local frames = 0
        local session, _, _, spec = fixture("stylus", {
            on_stylus_frame = function() frames = frames + 1 end,
        })
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 1 }
        t:eq(frames, 1, "a hover frame counts")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 40, y = 40, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 40, y = 40, tool = 0 }
        t:eq(frames, 4, "so do down, move and lift")
        t:check(session ~= nil, "the surface stayed usable throughout")
    end)

    t:case("a collapsed contact is counted on the notebook surface too", function()
        local Capture = require("ink_capture")
        local session, _, _, spec = fixture("stylus")
        Capture:resetCollapsedCounts()

        -- Only X ever moves, so the geometry is never proven and the contact
        -- finishes as its single lift dot.
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 60, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 1, x = 120, y = 10, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 120, y = 10, tool = 0 }
        local dots, discards = Capture:collapsedCounts()
        t:eq(dots, 1, "the collapse is visible from this surface as well")
        t:eq(discards, 0, "and is not a discard")

        spec.stylus_handler{ slot = 4, id = 2, x = 200, y = 200, tool = 1 }
        spec.stylus_handler{ slot = 4, id = 2, x = 260, y = 250, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 260, y = 250, tool = 0 }
        dots = Capture:collapsedCounts()
        t:eq(dots, 1, "a proven stroke adds nothing")
        t:check(session ~= nil, "the surface stayed usable throughout")
    end)

    t:case("finger compatibility draws one contact and filters it", function()
        local session, _, _, spec = fixture("finger")
        t:eq(spec.backend, "finger", "legacy route selected")
        local down = spec.frame_handler{
            { slot = 0, id = 3, x = 10, y = 10, tool = 0 },
        }
        t:eq(#down, 0, "drawing finger is suppressed from gestures")
        spec.frame_handler{ { slot = 0, id = 3, x = 30, y = 40, tool = 0 } }
        spec.frame_handler{ { slot = 0, id = -1, x = 30, y = 40, tool = 0 } }
        t:eq(session:surface():pendingWrites(), 1, "finger stroke queued")
    end)

    t:case("coordinate-less finger down waits for geometry without leaking", function()
        local session, _, adapter, spec = fixture("finger")
        local unknown = spec.frame_handler{ { slot = 0, id = 3, tool = 0 } }
        t:eq(#unknown, 0, "unknown down is suppressed fail-closed")
        t:eq(adapter:hasActiveContact(session), true, "lifecycle sees undecided touch")
        local inside = spec.frame_handler{
            { slot = 0, id = 3, x = 10, y = 10, tool = 0 },
        }
        t:eq(#inside, 0, "resolved paper contact remains suppressed")
        spec.frame_handler{ { slot = 0, id = -1, x = 10, y = 10, tool = 0 } }
        t:eq(session:surface():pendingWrites(), 1, "resolved contact becomes ink")

        local outside_down = spec.frame_handler{ { slot = 1, id = 4, tool = 0 } }
        local outside_move = spec.frame_handler{
            { slot = 1, id = 4, x = 1200, y = 10, tool = 0 },
        }
        local outside_up = spec.frame_handler{
            { slot = 1, id = -1, x = 1200, y = 10, tool = 0 },
        }
        t:eq(#outside_down + #outside_move + #outside_up, 0,
            "a suppressed down is never reintroduced as half a chrome gesture")
        t:eq(session:surface():pendingWrites(), 1, "outside sequence creates no ink")
    end)

    t:case("a passed finger keeps a coherent lift when paper gets another touch", function()
        local _, _, _, spec = fixture("finger")
        local outside = spec.frame_handler{
            { slot = 0, id = 1, x = 1200, y = 10, tool = 0 },
        }
        t:eq(#outside, 1, "outside down passed")
        local mixed = spec.frame_handler{
            { slot = 0, id = 1, x = 1200, y = 20, tool = 0 },
            { slot = 1, id = 2, x = 10, y = 10, tool = 0 },
        }
        t:eq(#mixed, 1, "only the already-passed contact continues")
        local lift = spec.frame_handler{
            { slot = 0, id = -1, x = 1200, y = 20, tool = 0 },
        }
        t:eq(#lift, 1, "GestureDetector receives the matching lift")
    end)

    t:case("abort retires contacts already forwarded to GestureDetector", function()
        local Capture = require("ink_capture")
        for _, mode in ipairs({ "stylus", "finger" }) do
            local input = ctx.reset()
            local session, _, adapter, spec = fixture(mode)
            local installed
            if mode == "stylus" then
                installed = Capture:installStylus(
                    spec.stylus_handler, spec.frame_handler)
            else
                installed = Capture:installFinger(spec.frame_handler)
            end
            t:eq(installed, true, mode .. " capture installed")
            input.gesture_detector:feedEvent{
                { slot = 0, id = 1, x = 1200, y = 10, tool = 0 },
            }
            t:check(input.gesture_detector:getContact(0) ~= nil,
                mode .. " down reached gestures")
            adapter:abort(session)
            t:eq(input.gesture_detector:getContact(0), nil,
                mode .. " resize-style abort retires contact")
            Capture:remove()
        end
    end)

    t:case("nib, eraser and dirty regions respect viewport scale and offset", function()
        local half, _, _, half_spec, _, _, half_dirty = fixture("stylus", {
            fit_rect = { x = 100, y = 200, w = 500, h = 700 },
            clip_rect = { x = 100, y = 200, w = 500, h = 700 },
        })
        half_spec.stylus_handler{ slot = 4, id = 1, x = 150, y = 250, tool = 1 }
        half_spec.stylus_handler{ slot = 4, id = -1, x = 150, y = 250, tool = 0 }
        local half_stroke = half:surface():cache():strokes()[1]
        t:eq(half_stroke.width, 8, "4 screen px stored as 8 logical at 0.5x")
        t:eq(half:surface():transform():scaleWidth(half_stroke.width), 4,
            "rendered nib remains 4 px")
        t:check(half_dirty[1].box.x >= 100 and half_dirty[1].box.y >= 200,
            "dirty callback is in screen coordinates")
        t:check(type(half_dirty[1].box.openIntersectWith) == "function"
            and type(half_dirty[1].box.combine) == "function",
            "dirty callback supplies KOReader Geom regions")
        t:check(half_dirty[1].source.x < half_dirty[1].box.x,
            "cache source is supplied separately from screen destination")

        -- The point is 30 logical units (15 screen px) from the stroke and
        -- must be hit by an 18-screen-pixel eraser at 0.5x.
        half_spec.stylus_handler{ slot = 4, id = 2, x = 165, y = 250, tool = 2 }
        half_spec.stylus_handler{ slot = 4, id = -1, x = 165, y = 250, tool = 0 }
        t:eq(#half:surface():cache():strokes(), 0,
            "eraser radius is converted to logical units")

        local double, _, _, double_spec = fixture("stylus", {
            fit_rect = { x = 0, y = 0, w = 2000, h = 2800 },
            clip_rect = { x = 0, y = 0, w = 2000, h = 2800 },
        })
        double_spec.stylus_handler{ slot = 4, id = 1, x = 100, y = 100, tool = 1 }
        double_spec.stylus_handler{ slot = 4, id = -1, x = 100, y = 100, tool = 0 }
        local double_stroke = double:surface():cache():strokes()[1]
        t:eq(double_stroke.width, 2, "4 screen px stored as 2 logical at 2x")
        t:eq(double:surface():transform():scaleWidth(double_stroke.width), 4,
            "larger viewport still renders the selected nib")
    end)

    t:case("auto mode requires KOReader's Wacom capability flag", function()
        local previous = ctx.env.Device.input.wacom_protocol
        ctx.env.Device.input.wacom_protocol = false
        local _, _, _, without_wacom = fixture("auto")
        t:eq(without_wacom.backend, "finger",
            "callback availability alone does not select stylus")
        ctx.env.Device.input.wacom_protocol = true
        local _, _, _, with_wacom = fixture("auto")
        t:eq(with_wacom.backend, "stylus", "known Wacom route selects stylus")
        ctx.env.Device.input.wacom_protocol = previous
    end)
end
