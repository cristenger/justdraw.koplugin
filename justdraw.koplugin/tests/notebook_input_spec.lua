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
            scheduleIn = function() end,
            unschedule = function() end,
            fit_rect = opts.fit_rect or { x = 0, y = 0, w = 1000, h = 1400 },
            clip_rect = opts.clip_rect or opts.fit_rect
                or { x = 0, y = 0, w = 1000, h = 1400 },
        }
        session:open(1)
        local dirties, dirty_boxes, errors, edits = 0, {}, {}, 0
        local edit_saw_contact = {}
        local adapter
        adapter = Adapter.new{
            get_mode = function() return mode or "stylus" end,
            get_pen_width = opts.get_pen_width,
            eraser_radius = opts.eraser_radius,
            touch_passthrough = opts.touch_passthrough,
            stylus_passthrough = opts.stylus_passthrough,
            now = opts.now,
            control_guard = opts.control_guard,
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
            on_error = function(reason) errors[#errors + 1] = reason end,
        }
        local spec = adapter:captureSpec(session, session:currentPage(),
            session:surface():transform())
        return session, store, adapter, spec,
            function() return dirties end, errors, dirty_boxes,
            function() return edits end, edit_saw_contact
    end

    t:describe("ink_notebook_input / hardware-neutral surface adapter")

    t:case("stylus points become one queued logical stroke", function()
        local session, _, adapter, spec, dirties, _, _, edits, edit_contacts = fixture("stylus")
        t:eq(spec.backend, "stylus", "modern route selected")
        t:eq(spec.stylus_handler{
            slot = 4, id = 9, x = 10, y = 10, tool = 1,
        }, true, "pen dominated")
        spec.stylus_handler{ slot = 4, id = 9, x = 20, y = 30, tool = 1 }
        spec.stylus_handler{ slot = 4, id = -1, x = 20, y = 30, tool = 0 }
        t:eq(session:surface():pendingWrites(), 1, "one durable operation queued")
        t:eq(#session:surface():cache():strokes(), 1, "one raster stroke")
        t:check(dirties() >= 2, "live ink requested repaint")
        t:eq(edits(), 1, "one lightweight capability update follows the stroke")
        t:eq(edit_contacts[1], false, "capabilities update only after lift bookkeeping")
        t:eq(adapter:hasActiveContact(session), false, "lift clears gate")
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
        local _, _, _, spec, _, _, _, edits = fixture("stylus")
        spec.stylus_handler{ slot = 4, id = 1, x = 10, y = 10, tool = 1 }
        spec.frame_handler{ { slot = 0, id = 2, x = 20, y = 20, tool = 0 } }
        spec.stylus_handler{ slot = 4, id = -1, x = 10, y = 10, tool = 0 }
        t:eq(edits(), 0, "palm keeps controls gated")
        spec.frame_handler{ { slot = 0, id = -1, x = 20, y = 20, tool = 0 } }
        t:eq(edits(), 1, "last lift publishes the new capabilities")
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
