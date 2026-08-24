# spec.md — Finger Ink (source of truth)

## Layout

```
fingerink.koplugin/
  _meta.lua        plugin manifest
  main.lua         plugin object: state machine, menu, persistence, paintTo
  ink_bar.lua      the toolbar: a window of its own, or the overlay's child
  ink_capture.lua  dual capture backend (feedEvent wrapper + stylus callback),
                   ownership-safe install/removal, guarded handlers,
                   rotation transform, slot filtering, per-slot dropContact
  ink_stack.lua    being the topmost window, and forwarding what you refuse
  ink_render.lua   allocation-free segment/stroke rasterisation
  ink_store.lua    per-page stroke list, hit test  (direct ink only)
  tests/           regression suite (support.lua + run.lua + *_spec.lua)

  -- the EPUB canvas
  ink_canvas_session.lua      one book's canvases: repository, index, open sheet
  ink_canvas_repository.lua   SQLite: schema, migrations, transactions, queries
  ink_canvas_codec.lua        the stored point format, chunked
  ink_canvas_queue.lua        bounded write batching and its failure state
  ink_anchor.lua              raw + normalised xpointer, page anchors
  ink_anchor_index.lua        canvas-to-page map, built in batches per layout
  ink_canvas_transform.lua    canvas <-> cache <-> screen, one copy of it
  ink_spatial_grid.lua        which strokes are near a place
  ink_canvas_cache.lua        the BB8 raster, built in batches, repaired locally
  ink_canvas_overlay.lua      the one window: sheet, handle, embedded toolbar
  ink_contact_router.lua      per-slot destinations, latched at contact down
```

Module names are prefixed `ink_` so plugin-local `require` cannot shadow a core
module (`require("input")` would collide with `device/input`).

There are two drawing features and they share only the toolbar, the renderer
and the capture layer:

| | Direct ink | Canvas sheet |
| --- | --- | --- |
| Where | on the page itself | on a blank sheet over it |
| Documents | any | reflowable only (EPUB and friends) |
| Anchored to | page number | an xpointer |
| Survives reflow | no | yes -- reflow moves the sheet, not the ink |
| Stored in | the sidecar, `fingerink_strokes` | `fingerink.sqlite3` |
| Coordinates | screen pixels | canvas units, 0..logical_w/h |
| While drawing | all touch swallowed | only touch on the sheet |

Nothing about direct ink changed. Every canvas path is behind `canvas_open`,
and with no sheet open the plugin behaves exactly as it did before the canvas
existed.

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
`ABS_MT_TOOL_TYPE`, never reaches the callback, and would be suppressed as
residual touch. Testers with a tablet select `stylus` by hand.

`setInputMode` refuses while `drawing` is true, and the radio items are
disabled as well. The guard lives in the setter, not only in the menu: swapping
backends inside a live contact sequence would tear down capture mid-stroke, and
the menu is not the only possible caller.

### Finger backend

The only device-agnostic hook is `Device.input.gesture_detector.feedEvent`,
which the plugin wraps **only while drawing mode is on**:

```lua
gd.feedEvent = function(gd_self, slots)
    handler(slots)                   -- ours, runs first, on untouched slots
    return original(gd_self, slots)  -- output passed through untouched
end
```

It is an observer, not a filter. The original is **always** called, so
GestureDetector's internal state stays consistent, and its output is **always**
returned, because emptying that array never could suppress the gestures that
matter. What reaches the app is decided per gesture at the widget layer; see
*Suppression* below.

### Stylus backend

`Capture:installStylus` registers `Input:registerStylusCallback` **and** wraps
`feedEvent` as well. The callback alone is not palm rejection: it only removes
the pen from gesture detection, leaving every palm contact free to turn pages.

Ordering is a hard guarantee, not luck. Every `handleTouchEv` variant runs
`Input:routeStylusEvents()` and then `gesture_detector:feedEvent(MTSlots)`
inside the same `EV_SYN:SYN_REPORT`. So within one frame `onStylusEvent` always
runs before `onStylusTouchFrame`, and a dominated pen slot is already gone from
the array the residual filter sees. That is what lets `onStylusTouchFrame`
promise never to touch `self.stroke`.

```
frame -> routeStylusEvents -> onStylusEvent(slot)      -> true drops the slot
      -> feedEvent          -> onStylusTouchFrame()    -> contact bookkeeping
      -> UIManager dispatch  -> InkBar:suppresses(ges) -> true swallows it
```

`onStylusTouchFrame` no longer decides what is emitted. It counts the non-pen
contacts that are down and remembers, per slot, whether each one started on the
toolbar. Those are the two facts the suppression decision reads.

### Suppression

Suppression happens in `InkBar:suppresses(ges)`, not in either capture hook.

```
suppresses(ges) == true  when  the plugin is drawing
                         and   a backend is installed
                         and   the plugin is not in passthrough
                         and   (ges.pos is nil, or ges.pos is outside the bar)
```

The toolbar is the topmost non-toast widget, and `UIManager:sendEvent` offers
every input event to that widget first and stops if it returns true. Two
properties follow, and both are why the decision lives here rather than in
`feedEvent`:

- **Timer-born gestures are visible.** `hold` and the deferred single `tap` are
  produced by `Input:setTimeout` callbacks and returned straight from
  `Input:waitEvent`, never passing through `feedEvent`. They reach the widget
  layer through the same dispatch as everything else.
- **The decision is per gesture.** Gestures arrive rotation-adjusted and carry
  `pos`, so a palm's gesture can be swallowed in the same input frame that
  carries the pen's tap on a button. No coordinate transform is needed here;
  `Capture.toScreen` exists for raw slot data, which this is not.

A gesture with no position cannot be attributed to a contact, so it is
suppressed. Once drawing stops, `suppresses` returns false for everything and
the reader behaves normally.

This makes "drawing implies a visible toolbar" a safety requirement rather than
a convenience: with no bar on the stack there is nothing to suppress with.
`setBarShown(false)` calls `setDrawing(false)`, and that call is load-bearing.

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
stylus callback (do not dominate the slot), and for the frame wrapper it does
not matter what the handler answers, because the detector's output is passed
through either way.

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

It emits nothing and suppresses nothing; it always returns `true`. Its job is to
maintain the two facts `InkBar:suppresses` reads:

| State | Meaning |
| --- | --- |
| `self.n_contacts` | how many non-pen contacts are currently down |
| `self.contacts[slot]` | `"new"`, `"bar"` or `"page"` — where *that* contact started |
| `self.passthrough` | a dialog is above the reader, or some contact started on the bar |

**The geometry latch is per slot, not per sequence.** A palm that landed off the
toolbar must not answer for the finger reaching for Stop, which is the only way
out of stylus drawing mode. Latching once per sequence made a resting palm a
lock-out.

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

### Why suppression cannot live in `feedEvent`

Emptying `feedEvent`'s return value does not stop `hold` or the deferred single
`tap`. Those are produced by timer callbacks registered through
`Input:setTimeout` (`gesturedetector.lua:641` and `:675`) and dispatched
straight out of `Input:waitEvent` (`input.lua:1584`), never passing through
`feedEvent`. A palm resting for the hold interval would raise the text selection
popup mid-stroke.

It also cannot be selective. At that point the gestures do not exist yet, so the
choice is the whole frame or none of it, and a frame released for a passthrough
pen released a simultaneous palm with it.

Both are answered by deciding at the widget layer instead, where every gesture
is visible individually and already carries a screen position. See *Suppression*
above and ADR-13.

An earlier version dropped the suppressed frame's contacts with
`GestureDetector:dropContact`, which does clear their pending timeouts. It was
destructive, and the finger route could never use it: ADR-2 requires the
detector's contact state to survive suppression or the two-finger gesture stops
firing. Nothing needs it now.

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

## The EPUB canvas

A sheet of blank paper anchored to a position in a reflowable book. It is a
frontend overlay: it inserts no space into CREngine, is not part of the DOM,
and does not affect reflow.

### Why it exists

Direct ink is stored in screen coordinates against a page number, so changing
font size, margins or rotation in an EPUB moves the text and leaves the ink
behind. A canvas moves the whole problem: the strokes live in the canvas's own
coordinates, and the only thing that has to survive a recomposition is *where
the sheet hangs* — one xpointer.

### Lifecycle

`ReaderReady` opens the session, and only for `ui.rolling` documents.
`partial_md5_checksum` lives in the document's settings, where ReaderUI
computes it on its way to that event; with it and the file size the book has an
identity that survives a rename. Without both, canvases are unavailable for
that book and the reader is told once — a path is not used as a substitute.

`onSaveSettings` is the durable-save gate. `Device:_beforeSuspend` calls
`UIManager:flushSettings()` and only then emits `Suspend`, so saving on suspend
would already be too late. `onCloseDocument` flushes again, cancels scheduled
work by reference, frees the raster and closes the connection.

### Anchors and the page index

A canvas stores the raw *and* the normalised xpointer, plus the
`cre_dom_version` it was born under. `getNormalizedXPointer` is canonical only
for DOMs at or above `getDomVersionWithNormalizedXPointers`, and KOReader's own
xpointer migration walks the last position and the annotations — it has never
heard of this plugin's tables. On load the form matching the current DOM is
tried first and the other is the fallback. An anchor that resolves to neither
is an **orphan**: kept, listed in the menu, never deleted.

Resolving every anchor on every repaint would be a CREngine call per canvas per
page turn. Instead the canvas-to-page map is built once per layout, keyed by
`getDocumentRenderingHash(true)`, cached in `canvas_layout_cache` and pruned to
the two most recent layouts of that book. Building is spread over
`UIManager:nextTick` in batches of eight; a generation counter keeps a rerender
from mixing two layouts, and a half-built index is never cached.

Three properties of the read path are enforced by counting calls:

- turning a page during a build resolves no xpointers;
- painting a view issues no query and makes no CREngine call;
- the document is asked to confirm only the candidates the map produced.

Creating a canvas is **refused while the index is still building**, because the
index is the only thing that knows whether this paragraph already has one.

### Coordinates

One transform, shared by input, hit testing, erasing, the raster and painting.
The canvas keeps the geometry it was born with and gets an aspect-fit rectangle
on every screen — never distorted, letterboxed at the sides when the shape no
longer matches, and aligned to the **top** of the sheet because the sheet
reveals the page downwards.

```
scale    = min(screen_w / logical_w, screen_h / logical_h)
offset_x = (screen_w - logical_w * scale) / 2
screen_x = offset_x + canvas_x * scale
screen_y = sheet_top + canvas_y * scale
```

The letterbox margins are *sheet*, not canvas: a contact there belongs to the
sheet and swallows, but ink is refused.

### The raster

One BB8 buffer per open canvas, the size of the whole transformed canvas —
about 4.4 MiB on a Scribe. Painting a view is one `blitFrom`. Building it is
batched over `nextTick` with one stroke decoded and released at a time, so
opening a dense canvas costs its longest stroke rather than its contents.

Because the buffer holds the whole canvas and not the visible part, dragging
the sheet to another height re-rasterises nothing — only the blit's source
rectangle moves. A rotation changes the scale and rebuilds from the vectors,
which are never rewritten.

Erasing and undo stay local through a grid over the stroke bounding boxes:
clear the region, ask the grid what overlaps it, redraw those into a
`BlitBuffer:viewport` of the region. A viewport bounds the write, so the repair
physically cannot paint outside it; clipping the refresh rectangle alone would
not stop the pixels.

### The window

`InkCanvasOverlay` is the only window. `UIManager:sendEvent` offers an input
event to the topmost non-toast widget and stops when one returns true — it does
not walk down the stack when that widget declines. Two ordinary windows would
be two things competing to be topmost with the loser deaf, so the sheet, the
handle and the toolbar are children of one widget.

Paint order and hit-test order are opposite on purpose. The toolbar is `self[1]`
so `WidgetContainer` offers it every gesture first; `paintTo` draws it last.

The overlay declines exactly one region — the screen above the sheet — and
`ink_stack` hands that to the window below. **That is what keeps touch
navigation alive with a sheet open.**

Height is 40, 70 or 100 per cent of the screen. Tap the handle to cycle, or
drag it and it snaps to the nearest on release. Nothing is repainted mid-drag,
the way `MovableContainer` does not repaint mid-move: continuous refreshes on
e-ink cost more than the feedback is worth, and three magnetic stops are the
compensation for a height the reader cannot watch themselves choosing.

### Contact routing

Destinations are latched at the first frame with real coordinates and never
revisited. The order is:

```
dialog > bar > handle > canvas > reader
```

| Destination | Pen | Finger, stylus route | Finger, finger route |
| --- | --- | --- | --- |
| `dialog` | passthrough | passthrough | passthrough |
| `bar` | passthrough | to the toolbar | to the toolbar |
| `handle` | passthrough | to the overlay | to the overlay |
| `canvas` | draw or erase | suppressed as a palm | draws |
| `reader` | dominated, no ink | to the book | to the book |

The toolbar's place in that order is the safety invariant: a new finger while
the pen is down becomes a palm anywhere on the page, but never on the toolbar.

A palm's slot is **withheld from `GestureDetector` entirely** — the down frame
and the lift alike — so no Contact and no hold timer ever exist for it. That is
necessary rather than belt-and-braces: an emitted gesture carries `ges`, `pos`
and `time` and no slot number, and the overlay deliberately hands gestures
above the sheet to the book, so once a palm's `hold` exists nothing can tell it
from the reader's own. A contact whose first frame carried no coordinates has
already gone through by the time the next one places it; `Capture:dropContact`
retires that one, per slot.

A finger already resting when the pen lands is cancelled — the single
deliberate exception to the latch — and its slot is reported so its contact and
timers go with it.

### Persistence

`DataStorage:getSettingsDir() .. "/fingerink.sqlite3"`, one database for every
book, following the pattern Statistics established. Tables: `books`,
`canvases`, `canvas_layout_cache`, `strokes`, `stroke_chunks`. Version in
`PRAGMA user_version`, foreign keys on, WAL only where `Device:canUseWAL()`.

Points are two little-endian `uint16` each, normalised to the canvas geometry,
chunked at 1024 points with the seam point repeated so a segment across a chunk
boundary is drawable from one chunk. `join` refuses a seam that does not line
up rather than drawing the jump.

Two driver behaviours are load-bearing and were settled by probing the real
thing:

- INTEGER columns arrive as int64 cdata. `1LL == 1` is true, but `t[1LL]` and
  `t[1]` are different table keys — a page index built from raw driver output
  would miss every lookup. Every integer is converted at the boundary.
- a Lua string binds as TEXT even into a BLOB column, and SQL stops at its
  first NUL, so `length()` on a point blob answers 1. `CAST(?n AS BLOB)` going
  in and `CAST(points AS TEXT)` coming out give a real blob with plain strings
  on both sides.

Writes are queued and flushed at the first of: 250 ms, 8 operations, 64 KiB, a
canvas change, `SaveSettings`, or close. Strokes carry a **local** id from the
moment they are drawn, because the row id does not exist until the insert runs;
that is what lets an undo of a pending stroke delete its queued insert instead
of writing the stroke and deleting it again. A failed flush keeps the queue
exactly as it was, refuses further editing and says so — nothing is marked
written and no fresh database is reached for.

Failure policy: a database that will not open is never recreated; a schema
newer than this one opens read-only rather than being downgraded; a migration
checkpoints, closes and copies the file before it writes a single statement,
and refuses outright on a gap in the ladder.

### Not in v1

Drawing over the text itself; a global list of every canvas; export or sync;
multi-sheet notebooks; pressure, tilt and hover; canvases on PDFs (the
`anchor_kind = 'page'` column is reserved); migrating the direct-ink store;
manual compaction of the database.

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
- Drawing sheet (reflowable documents only; disabled otherwise)
  - Open sheet here / Close sheet, Delete this sheet
  - Sheets on this page (when the position has more than one)
  - Lost sheets (n) — orphaned anchors, openable and deletable
- Clear this page
- Clear whole document

Stop, tool and undo live on the toolbar, not in the menu — reaching them
through the menu is exactly the thing that does not work while drawing.

Dispatcher actions for Gesture Manager: `fingerink_toggle`, `fingerink_undo`,
`fingerink_eraser`, `fingerink_bar`.
