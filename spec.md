# spec.md — Finger Ink (source of truth)

## Layout

```
fingerink.koplugin/
  _meta.lua        plugin manifest
  main.lua         plugin object: state machine, menu, persistence, paintTo
  ink_bar.lua      always-reachable side toolbar widget
  ink_capture.lua  dual capture backend (feedEvent wrapper + stylus callback),
                   ownership-safe install/removal, guarded handlers,
                   rotation transform
  tests/           LuaJIT regression suite (support.lua + run.lua)
  ink_render.lua   allocation-free segment/stroke rasterisation
  ink_store.lua    per-page stroke list, hit test
```

Module names are prefixed `ink_` so plugin-local `require` cannot shadow a core
module (`require("input")` would collide with `device/input`).

## Input capture

Two backends, one installed at a time, chosen by `fingerink_input_mode`
(`auto` | `stylus` | `finger`, default `auto`, persisted in `G_reader_settings`).

| Mode | Resolution |
| --- | --- |
| `finger` | always the legacy route |
| `stylus` | needs `Input:registerStylusCallback`; refuses with a reason if absent or already owned |
| `auto` | `stylus` when the API exists **and** `Device.input.wacom_protocol`; `finger` otherwise |

`auto` falls back to `finger`, never to `stylus`: the stylus backend suppresses
all touch, so choosing it on a device with no pen would leave the user unable to
draw. `wacom_protocol` is narrow — only the three Kindle Scribes and the
reMarkable set it — so Kobo stylus devices need the explicit mode.

The emulator is deliberately left on `finger` too. koreader-base translates
SDL3 pen events into the pen slot with a real tool, so a graphics tablet does
drive the stylus route, but a plain mouse lands on slot 0 or 1 with no
`ABS_MT_TOOL_TYPE`, never reaches the callback, and would be swallowed by the
residual filter. Testers with a tablet select `stylus` by hand.

`setInputMode` refuses while `drawing` is true, and the radio items are
disabled as well. The guard lives in the setter, not only in the menu: swapping
backends inside a live contact sequence would tear down capture mid-stroke, and
the menu is not the only possible caller.

### Finger backend

The only device-agnostic hook is `Device.input.gesture_detector.feedEvent`,
which the plugin wraps **only while drawing mode is on**:

```lua
gd.feedEvent = function(gd_self, slots)
    local emit = handler(slots)      -- ours, runs first, on untouched slots
    local evs  = original(gd_self, slots)
    if emit then return evs end
    for i = #evs, 1, -1 do evs[i] = nil end
    return evs
end
```

The original is **always** called, so GestureDetector's internal state stays
consistent; the plugin only decides whether the resulting gesture events reach
the app. Without this, a swallowed finger-down would desynchronise the detector
and the two-finger exit gesture would not fire.

### Stylus backend

`Capture:installStylus` registers `Input:registerStylusCallback` **and** wraps
`feedEvent` as well. The callback alone is not palm rejection: it only removes
the pen from gesture detection, leaving every palm contact free to turn pages.

Ordering is a hard guarantee, not luck. Every `handleTouchEv` variant runs
`Input:routeStylusEvents()` and then `gesture_detector:feedEvent(MTSlots)`
inside the same `EV_SYN:SYN_REPORT`. So within one frame `onStylusEvent` always
runs before `onStylusTouchFrame`, and a dominated pen slot is already gone from
the array the residual filter sees. That is what lets the residual filter
promise never to touch `self.stroke`.

```
frame -> routeStylusEvents -> onStylusEvent(slot)   -> true drops the slot
      -> feedEvent          -> onStylusTouchFrame() -> false empties gestures
```

### Ownership

The stylus callback is a singleton: `registerStylusCallback` just assigns, there
is no chaining and no owner query. `installStylus` validates everything before
its first mutation and refuses with `stylus_callback_busy` if
`input.stylus_callback` belongs to somebody else. `Capture:remove` is idempotent
and unhooks **by identity** — it unregisters only if the live callback is still
ours, restores `feedEvent` only if the live value is still our wrapper, and
warns instead of clobbering otherwise. It clears `active` first, so a wrapper
someone chained on top of ours finds ours transparent rather than filtering
through a dead handler.

### Error containment

Nothing between the plugin and KOReader's main loop is protected:
`routeStylusEvents` calls the callback bare, `Input:waitEvent` calls
`handleTouchEv` bare, and neither UIManager nor `reader.lua` wraps that path. An
unguarded error would take KOReader down *and* leave the monkey patch installed.

Both handlers therefore run under `pcall`. On error the handler returns the
value that makes KOReader behave as if the plugin were absent: `false` from the
stylus callback (do not dominate the slot) and `true` from the residual wrapper
(let the gestures out).

Disarming is two-phase. `Capture.active` is cleared **immediately**, which makes
both wrappers inert, but the actual unhooking is deferred to the next UI tick.
`Input:routeStylusEvents` re-reads `input.stylus_callback` on *every* slot of
the frame (`input.lua:506`), so clearing it from inside the callback would make
the next stylus slot in that same frame call a nil value — the very crash the
guard exists to prevent. On the next tick the hooks come out from a safe stack,
the plugin stops drawing, the stroke in flight is dropped, and the user is told
once.

### Slot data

A slot table is `{ slot, id, x, y, tool, timev }`. `id >= 0` is a contact,
`id == -1` is a lift, `id == nil` is a slot that never carried a tracking id.

The table is Input's own `ev_slots[n]` and is **persistent**: `initMtSlot` never
clears fields, `newFrame` only empties `MTSlots`, and `MTSlots` holds references
to those durable tables. Consequences the implementation depends on:

- `id` is sticky. After a lift it stays `-1` and repeats on every hover frame,
  so the lift handler must be idempotent.
- `x`/`y` are sticky. They outlive the contact, so coordinates alone never mean
  "there is contact".
- The table must never be retained past the call; scalars are copied out first.
- `tool` can be `TOOL_TYPE_FINGER` on the pen slot, because leaving proximity
  writes exactly that and the slot is still routed by slot number. `tool`
  selects ink-or-erase, never draw-or-not.

Tool constants are read from `Device.input.TOOL_TYPE_*` at install time, with
the documented literals (0/1/2/3) only as a fallback.

Coordinates are pre-rotation; `Capture.toScreen(x, y)` applies the same
transform GestureDetector applies after detection, and returns two numbers. It
prefers `Screen:getTouchRotation()` — the contract GestureDetector itself uses,
which some backends override — and falls back to `getRotationMode()`.

## Contact arbitration — finger backend

| Active contacts | Behaviour |
| --- | --- |
| 1 | ink; gesture events discarded |
| ≥ 2 | passthrough for the remainder of the sequence; in-progress stroke aborted |

`passthrough` latches on the second contact and clears when contact count
returns to 0. The lift frame that completes a two-finger gesture is emitted
because the return value is `self.passthrough or was_passthrough`.

**Single finger draws. Two fingers behave normally.** Two-finger gestures are a
convenience, not the exit route — the toolbar is.

## Contact arbitration — stylus backend

### Pen: `onStylusEvent(slot)`

| Condition | Action | Return |
| --- | --- | --- |
| `id == nil` | nothing | `true` |
| first `id >= 0` | latch `stylus_passthrough` from `dialogOnTop()` | — |
| latched passthrough | nothing | `false` |
| first frame with `x`/`y`, inside `bar.dimen` | latch passthrough | `false` |
| contact-down repeating the previous lift's `x`/`y` | ignore the frame's coordinates | `true` |
| `id >= 0` with coordinates | draw or erase | `true` |
| dragged onto the bar | end the stroke at the edge, park until lift | `true` |
| dialog opens mid-stroke | abort the stroke, keep dominating | `true` |
| `id < 0`, was drawing | `endStroke`, reset | `true` |
| `id < 0`, was passthrough | reset | `false` |
| `id < 0`, not active | nothing (idempotent) | latched value |

Coordinates are sticky, so a contact-down frame that only carried `BTN_TOUCH`
still presents the position where the *previous* sequence ended. Latching
geometry from it can swallow the whole next stroke (if that position was on the
toolbar) or ink a phantom dot at the old spot. `stylus_lift_x/y` remembers the
last lift and the next contact-down refuses to trust an identical pair.

A dialog appearing mid-stroke aborts the ink but keeps dominating to the lift —
handing the slot back at that point is the `true` → `false` flip described
below.

**Once a frame has been dominated, the decision cannot change before the lift.**
This is correctness, not style. `GestureDetector:feedEvent` creates a `Contact`
the first time it sees a slot:

- `true` → `false` mid-sequence: the detector opens a *new* contact at the
  current position, marks it down, and emits a spurious tap on lift.
- `false` → `true` mid-sequence: the existing contact never sees its lift and
  stays in `active_contacts` with a live `pending_hold_timer`, firing a phantom
  hold and blocking the slot until the next `dropContacts()`.

### Touch: `onStylusTouchFrame(slots)`

Everything the pen did not take. Palm and finger are not told apart — refusing
to guess is what makes rejection predictable.

| Condition | Return |
| --- | --- |
| the pen handed its slot to the UI **in this frame** | `true` (whole frame) |
| dialog above the reader | `true` |
| sequence started inside `bar.dimen` | `true` until all contacts lift |
| anything else, 1 or many contacts | `false` |

The first row reads a per-frame flag set by `stylusFrameResult`, **not** the
latched `stylus_passthrough`. The lift frame is the one that carries a tap, and
`onStylusEvent` resets the latch on that frame before this filter runs; reading
the latch here made every toolbar button unreachable with the pen.

Pen slots are skipped by `Capture:isStylusSlot` rather than counted. Counting
them corrupts `n_contacts` and lets the pen's toolbar position latch
`passthrough` for the *touch* state machine, which then survives the pen's lift
and lets a resting palm turn pages.

Contact accounting runs on every frame, including frames the pen already
decided. Skipping it stranded contacts that lifted inside the pen's passthrough
window.

An empty `slots` array is normal — it happens whenever the pen was the only
contact and got dominated — and must not be read as "everything lifted".

This filter never calls `onContactPoint` and never touches `self.stroke`.

### Suppression is more than an empty array

Emptying `feedEvent`'s return value does not stop `hold` or the deferred single
`tap`. Those are produced by timer callbacks registered through
`Input:setTimeout` (`gesturedetector.lua:641` and `:675`) and dispatched
straight out of `Input:waitEvent` (`input.lua:1570-1585`), never passing through
`feedEvent`. A palm resting for the hold interval would raise the text
selection popup mid-stroke.

So on the stylus backend a suppressed frame also drops the corresponding
contacts via `GestureDetector:dropContact`, which clears their pending
timeouts.

**Finger backend limitation (pre-existing).** The legacy route cannot do this:
ADR-2 requires the detector's contact state to survive suppression, or the
two-finger gesture stops firing. A stationary drawing finger can therefore still
trip a `hold` after the hold interval. Unchanged by this work, and out of its
scope.

**Known limitation.** The emit decision is per frame, not per contact:
GestureDetector's gesture events carry `pos` but no slot number, so a frame
released for a passthrough pen also releases a simultaneous palm. Pinned by a
test so any change is deliberate. The fallback, if hardware shows the toolbar
becoming unusable, is to filter the returned array geometrically — remembering
that `ges.pos` is still unrotated at that point, since `adjustGesCoordinate`
runs later in `Input:handleTouchEv`.

### Shared point route

`applyPoint(x, y, tool)` is the one place that decides ink versus erase. A
`tool` equal to `TOOL_TYPE_ERASER` erases regardless of the toolbar; everything
else defers to it. The finger route calls `onContactPoint(slot, x, y)` with no
`tool`, so its behaviour is bit-for-bit what it was.

## Toolbar

`ink_bar.lua` is a plain KOReader widget (`FrameContainer` > `VerticalGroup` >
four `Button`s) shown via `UIManager:show`, so it sits above ReaderUI in the
widget stack and receives taps before anything else. Its position is fixed:
vertically centred, `Size.padding.large` in from the chosen edge.

Buttons, top to bottom:

| Button | Label | Action |
| --- | --- | --- |
| 1 | Draw / **Stop** | toggle capture |
| 2 | Pen / **Eraser** | current tool; switches capture on if off |
| 3 | Undo | drop last stroke on this page |
| 4 | Hide | switch drawing off, then hide the bar |

`InkBar:update(refresh)` relabels buttons 1 and 2 from plugin state. Called
from every path that changes `drawing` or `eraser`.

### Reachability

Three rules together guarantee the bar is always usable:

1. `setDrawing(true)` shows the bar first if it is hidden.
2. `setBarShown(false)` calls `setDrawing(false)` first.
3. A contact whose **first** point falls inside `bar.dimen` latches
   `passthrough`, so GestureDetector produces the tap and the Button fires.

Rules 1 and 2 make "drawing on, no bar" unreachable. Rule 3 makes the bar
work while every other single-finger touch is being consumed.

A stroke that starts off the bar and is **dragged onto** it is ended at the
edge and the contact is parked at `draw_slot = SUSPENDED` (-1) until it lifts,
so ink is never painted over the buttons and never resumes mid-drag.

Rotation and `onScreenResize` rebuild the bar, since its position is computed
once from screen dimensions.

## Stroke data

```lua
stroke = { n = <point count>, w = <pen width px>, x1, y1, x2, y2, ... }
```

Flat number array, two slots per point. No per-point table. Serialises
directly into the document sidecar under `fingerink_strokes`, keyed by page:

```lua
pages = { [17] = { stroke, stroke }, [23] = { stroke } }
```

Coordinates are absolute screen pixels. `paintTo` therefore ignores its `x, y`
arguments — ReaderView is full-screen, so the view origin is always `0, 0`.

## Rendering

- `Render.segment` walks a DDA between two points painting `w × w` rects.
  Integer locals only, no table allocation, no `math.abs` on the hot path.
- Live feedback paints straight into `Screen.bb` and calls
  `Screen:refreshFast(x, y, w, h)` (DU) over the padded segment bounding box,
  clamped to screen bounds. `refreshPartial` if the user prefers quality.
- `paintTo(bb)` replays every stroke on the current page. This is the
  authoritative path — direct `Screen.bb` painting is only a latency shortcut
  and is always recoverable by a repaint.

## Erasing

Stroke-level. `Store.hit(list, x, y, r)` scans points back-to-front and returns
the index of the first stroke with a point within `r` (default 18 px). Squared
distance, no `sqrt`. Whole stroke is removed, then a `"ui"` repaint.

Point-based, not segment-based: a long straight stroke drawn in two samples has
an unerasable middle. Accepted for v1.

## Persistence

`onSaveSettings` writes `pages` to `doc_settings`, or deletes the key when
empty. No write on every stroke.

## Lifecycle

`onSuspend` calls `setDrawing(false)`; `onCloseDocument` and `onCloseWidget`
call `teardown()`, which does the same work and then closes the bar. Both abort
the stroke in flight, reset both state machines, and remove capture. No hook is
ever left installed.

There is no `onResume`, deliberately. `Input:inhibitInput(true)` swaps
`handleTouchEv` for `voidEv` and calls `resetState()`, which drops every
contact and rebuilds `ev_slots` from scratch — so suspending mid-stroke means
the pen lift is never delivered and any cached slot reference is dead. Stopping
on suspend and requiring an explicit Draw after resume is the only state that
is knowably clean.

## Menu

Top menu → Finger Ink:

- Start drawing (disabled while already on; **closes the menu**, because an
  open menu is unusable once single-finger taps are being swallowed)
- Show toolbar (toggle, default on, persisted)
- Toolbar side: left / right
- Input mode: automatic / stylus / finger (radio, persisted, **disabled while
  drawing**)
- Pen width: thin (2) / medium (4) / thick (7)
- Fast refresh while drawing (toggle, default on)
- Clear this page
- Clear whole document

Stop, tool and undo live on the toolbar, not in the menu — reaching them
through the menu is exactly the thing that does not work while drawing.

Dispatcher actions for Gesture Manager: `fingerink_toggle`, `fingerink_undo`,
`fingerink_eraser`, `fingerink_bar`.
