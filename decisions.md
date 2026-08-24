# decisions.md — Finger Ink

## ADR-1 — Hook `GestureDetector:feedEvent`, not the stylus callback *(superseded by ADR-11)*

**Context.** `pencil.koplugin` and `stylus-annotations.koplugin` both route
through `Input:registerStylusCallback` / `Input:routeStylusEvents`. That path
filters on `slot.tool == TOOL_TYPE_PEN/ERASER` or `slot.slot == Input.pen_slot`
(`pen_slot = main_finger_slot + 4`). A Kindle touch panel reports neither: no
`ABS_MT_TOOL_TYPE`, contacts in slots 0/1. The callback can never fire for a
finger. `registerStylusCallback` also does not exist in v2026.03 — it landed in
v2026.07, which is what reopened this decision. See ADR-11.

**Decision.** Wrap `Device.input.gesture_detector.feedEvent`, the same hook
`notes.koplugin` uses. It is the only place in v2026.03 where fully parsed MT
slots — finger included — are observable without patching core.

**Consequences.** Monkey-patching a core object. Mitigated by installing only
while drawing mode is on and removing on every exit path. Will need revisiting
if a real touch-observer API lands upstream.

## ADR-2 — Always call the original `feedEvent`, gate only its output

**Context.** Swallowing frames outright keeps GestureDetector from seeing a
consistent contact sequence, so the two-finger exit gesture would intermittently
fail to fire (its first finger's down was never delivered).

**Decision.** Call `original(gd_self, slots)` on every frame. Clear the returned
event list in place when the plugin is consuming the sequence.

**Consequences.** GestureDetector does redundant work during ink strokes. Cheap
relative to the e-ink refresh, and clearing in place adds no allocation.

## ADR-3 — Single finger inks, two fingers pass through *(superseded in part by ADR-8, and entirely on the stylus backend by ADR-11)*

**Context.** Something has to turn drawing off while single-finger touch is
being consumed, on a device with no buttons but power. A floating toolbar means
a widget, hit-test passthrough, and text rendering. Invisible hot corners are
undiscoverable.

**Decision.** Contact count is the modifier. One contact draws; two or more
latch passthrough for the rest of the sequence. Toggle is a Dispatcher action
the user maps to a two-finger tap.

**Consequences.** No toolbar to build or maintain. Costs the two-finger gesture
set while drawing is on, and aborts a stroke if a second finger lands mid-line
(palm contact). Acceptable — there is no palm rejection to be had anyway.

**Outcome.** Wrong. A two-finger tap on an IR panel while a palm rests on the
screen is unreliable, the toggle was buried in a menu that itself becomes
unusable once taps are swallowed, and the only dependable exit turned out to be
the power button. The contact-count rule is kept as a convenience; the exit
route is now ADR-8.

## ADR-4 — Flat number arrays for strokes

**Decision.** `{ n, w, x1, y1, x2, y2, ... }` rather than an array of point
tables. Two array slots per point, one table per stroke.

**Consequences.** Zero allocation while a stroke is being drawn after the
initial table, and the hot loops (render, hit test) touch only numbers.
Indexing is `i*2-1 / i*2` arithmetic, which is the one place the code is less
obvious than it could be.

## ADR-5 — Absolute screen coordinates, keyed by page number

**Decision.** Store raw post-rotation screen pixels. Key by
`self.view.state.page`.

**Consequences.** Simple and exact for PDFs at a fixed zoom. In EPUBs, changing
font size, margins or rotation moves the text and leaves the ink where it was.
Same limitation `pencil.koplugin` documents. Set your layout before you write.
Rejected for v1: xpointer anchoring (large), layout-signature invalidation
(hides ink without explaining why).

## ADR-6 — Direct `Screen.bb` paint plus `refreshFast` for live feedback

**Context.** `notes.koplugin` calls `UIManager:setDirty(self, "ui", region)` per
stroke segment. `"ui"` is a quality partial refresh, and `setDirty` repaints the
widget stack — both far too slow per point on a PW4.

**Decision.** Paint the new segment straight into `Screen.bb` and
`Screen:refreshFast` its padded bounding box (DU waveform, 1-bit, ~100 ms).
`paintTo` remains the authoritative redraw.

**Consequences.** DU ghosting builds up; the next page turn's full refresh
clears it. Direct framebuffer painting is outside UIManager's model, so any
repaint the plugin does not trigger itself must still produce correct output —
hence `paintTo` replays everything rather than trusting the framebuffer.

## ADR-7 — Stroke-level erase, point-based hit test

**Decision.** Erase removes a whole stroke; hit test scans stored points, not
interpolated segments.

**Consequences.** Long fast strokes sampled sparsely have gaps that do not
respond to the eraser. Segment-distance hit testing is the fix if it becomes
annoying; it is ~15 more lines and was not worth it before seeing real strokes.

## ADR-8 — An always-visible toolbar, reached by geometric passthrough *(see also ADR-10)*

**Context.** ADR-3 left no dependable way out of drawing mode. What was needed
was an on-screen control that keeps working while the plugin owns single-finger
input.

**Decision.** A real KOReader widget (`ink_bar.lua`) shown through
`UIManager:show`, so it renders natively and sits above ReaderUI in the widget
stack. Input is handled geometrically rather than by wiring the widget into the
capture path: a contact whose first point lands inside `bar.dimen` latches
passthrough for the whole sequence, GestureDetector emits a normal tap, and the
Button handles it as it would any other.

Two invariants make the stuck state unreachable: turning drawing on shows the
bar; hiding the bar turns drawing off.

**Consequences.**

- The visuals are KOReader's — no hand-painted rects, no guessing at icon names
  or glyph coverage in the Kindle font stack. Text labels for the same reason.
- No hook is needed while drawing is off. The bar is an ordinary widget then and
  gets taps the ordinary way, so requirement 4 survives intact.
- The bar occupies ~15% of screen width. It is hideable, and side-switchable for
  left-handers.
- A stroke dragged onto the bar is truncated at the edge rather than drawn under
  it. `draw_slot = SUSPENDED` parks the contact until lift so it cannot resume
  in the middle of a line.
- Position is computed once from screen size, so rotation and resize have to
  rebuild it.

Rejected: hand-painting the toolbar into `Screen.bb` inside `paintTo` and
hit-testing it ourselves. Fewer moving parts on paper, but it means owning text
rendering, pressed states and refresh regions — more code, worse looking.

## ADR-9 — "Start drawing" closes the menu

**Context.** The menu item toggled drawing and called `updateItems()`, leaving
the menu open on top of a reader that no longer responds to single-finger taps.

**Decision.** The item is one-way (`Start drawing`, disabled once on) and lets
the menu close. Stopping is the toolbar's job.

**Consequences.** Slightly asymmetric menu. Correct, though: the menu is only
usable in the state where drawing is off, so it should only offer the action
that is valid in that state.

## ADR-10 — The toolbar forwards input it does not want

**Context.** ADR-8 assumed that sitting on top of the widget stack only affected
what the bar *receives*. It also decides what everything else receives.
`UIManager:sendEvent` offers an input event to exactly one window — the topmost
non-toast one — and its fallback pass afterwards reaches only widgets flagged
`is_always_active` or registered as someone's `active_widgets`. ReaderUI is
neither, and neither is TouchMenu.

So while the bar was up, it was the only thing on screen that could be touched.
Page turns did nothing. Worse, showing the bar from the menu left the menu open
and unclosable: tapping outside it is the only way to dismiss one, and those
taps stopped at the bar. The only escape was Hide, which is what the bug report
described.

Drawing mode had the same hole one layer down: the `feedEvent` hook eats
single-finger contacts before UIManager sees them at all, so an open menu stayed
stuck even once the bar started forwarding.

**Decision.** Two guards, one per layer.

`InkBar:handleEvent` forwards to `self:windowBelow()` — the topmost non-toast
window that is not the bar — but only for the four handlers that arrive through
`sendEvent` (`onGesture`, `onKeyPress`, `onKeyRepeat`, `onKeyRelease`).
Everything else is broadcast to every window already and would be delivered
twice. `InkBar:onGesture` swallows gestures that land on the bar but miss every
button, so its border and padding do not turn pages.

`FingerInk:dialogOnTop` reports whether the window under the bar is something
other than ReaderUI. When it is, `onTouchFrame` latches passthrough for the
contact sequence instead of inking, so any menu or dialog can always be
dismissed. It re-latches per sequence, so drawing resumes on its own once the
dialog is gone.

**Consequences.**

- Reading with the bar shown works: taps, swipes and hardware keys all reach the
  reader.
- Forwarding returns the callee's own result rather than a blanket `true`, so
  UIManager's `is_always_active` / `active_widgets` pass still runs on a miss.
  A widget below that is itself always-active may see one unhandled event twice;
  it returned false the first time, so the second changes nothing.
- Reaches into `UIManager._window_stack`. It is private by name only — stable
  across releases and already poked at by plugins — but it is the one part of
  this that a KOReader refactor could break.
- Drawing yields entirely while a dialog is up. Deliberate: an undismissable
  dialog is a worse failure than a dropped stroke.

Rejected: making the bar a `toast`. Toasts do pass input through, which is half
of what is wanted, but they can never consume it — the bar's own buttons would
have fired *and* turned a page underneath.

Rejected: dropping the window entirely and painting the bar from `paintTo` with
ReaderUI touch zones for input. Architecturally the tidiest, and how ReaderFooter
does it, but the zones have to name every reader zone they override
(`tap_forward`, `readerhighlight_tap`, and so on) — a brittle list, for a bigger
change than the bug warrants.

## ADR-11 — Stylus callback *plus* a residual touch filter *(superseded in part by ADR-13)*

**Context.** KOReader v2026.07 added `Input:registerStylusCallback`. Returning
true from it removes the pen slot from `MTSlots` before
`GestureDetector:feedEvent`, which is exactly the hook ADR-1 said did not
exist. But it only hides *the pen*. Every palm contact still reaches the reader
and still turns pages, so the callback on its own is not palm rejection — it is
half of one.

The callback is also a singleton: `registerStylusCallback` assigns, there is no
chaining and no way to ask who owns it.

**Decision.** On the stylus backend, register the callback *and* keep the
ADR-1 `feedEvent` wrapper, now suppressing all residual touch outside the
toolbar and dialogs. Keep the two backends separate rather than generalising
one: the finger route has no tool data and must not change. Refuse activation
outright when another plugin owns the callback; never overwrite it. Remove by
identity, and treat the pen's domination decision as latched from contact-down
to lift, because GestureDetector's contact bookkeeping cannot survive a flip
mid-sequence.

**Suppression has to drop contacts, not just blank the array.** `hold` and the
deferred single `tap` come from `Input:setTimeout` callbacks dispatched directly
by `Input:waitEvent`; they never pass through `feedEvent`, so clearing its
return value cannot stop them. A resting palm would raise the text selection
popup mid-stroke. The stylus backend therefore calls
`GestureDetector:dropContact` for the slots in a suppressed frame. The finger
backend deliberately does not — ADR-2 needs that state alive for the two-finger
gesture — so the legacy route keeps that (pre-existing) hole.

**The pen's per-frame decision is published to the touch filter.** The two
handlers run in the same input frame, and the lift frame — the one carrying a
toolbar tap — resets the passthrough latch before the filter runs. The filter
reads a per-frame flag instead. Without it, no toolbar button was reachable with
the pen.

**Consequences.** Real palm rejection on the Scribe, at the price of no touch
navigation while drawing — Stop is the way back. Two hooks instead of one.

**Superseded in part.** The residual filter no longer suppresses anything; it
only keeps the contact bookkeeping the suppression decision reads. Suppression
moved to the widget layer, and `dropContact` went with it. See ADR-13.
Coexistence with another stylus plugin is impossible by construction, which is
reported rather than papered over. The emit decision stays per frame, so a
passthrough pen frame releases a simultaneous palm; gestures carry no slot
number, so per-contact filtering is not available without geometry.

Rejected: dropping the `feedEvent` wrapper and relying on the callback alone.
Simpler, and it does put ink on the page — but a palm still turns the page
mid-sentence, which is the entire problem on a Scribe.

Rejected: classifying palm versus finger by contact size or count. No size data
in the slot, and any count-based rule makes rejection unpredictable, which is
worse than a blunt rule the user can learn.

Rejected: widening `auto` to cover the SDL emulator. It looked free —
`stylus_tool_protocol` is `wacom_protocol or is_sdl` in core, and koreader-base
really does translate SDL3 pen events into the pen slot with a proper tool. But
a plain **mouse** goes to slot 0/1 emitting no `ABS_MT_TOOL_TYPE` at all, so it
never reaches the callback and the residual filter would eat it: the emulator
would open with a plugin that cannot draw. Serving the rare tablet case by
breaking the common one is the wrong trade, and the explicit `stylus` mode
already covers the tablet.

## ADR-12 — Input handlers run guarded, and disarm themselves

**Context.** Nothing between this plugin and KOReader's main event loop catches
errors. `Input:routeStylusEvents` calls `self.stylus_callback(self, slot)`
bare; `Input:waitEvent` calls `self:handleTouchEv(event)` bare — the nearby
`pcall` covers only the C-level `waitForEvent` — and neither
`UIManager:handleInput` nor `reader.lua` wraps that path.

So a Lua error in a handler does not degrade the ink. It takes KOReader down
with a traceback, *and* leaves the monkey patch installed, so the session ends
with input captured by a plugin in an unknown state.

**Decision.** Both handlers are installed as guarded wrappers. On error:
`Capture` logs, removes itself by identity, and returns the value that makes
KOReader behave as though the plugin were absent — `false` from the stylus
callback (do not dominate), `true` from the residual wrapper (let gestures
out). It then calls the plugin's `on_error`, itself guarded so a failure there
cannot resurrect the original. The plugin stops drawing, drops the stroke in
flight, and notifies once.

**Unhooking is deferred one UI tick.** `Input:routeStylusEvents` re-reads
`input.stylus_callback` on every slot of the frame, so unregistering from inside
the callback makes the next stylus slot in that same frame call a nil value —
reintroducing exactly the crash this ADR exists to prevent. Clearing `active` is
enough to make both wrappers inert immediately; the hooks come out on the next
tick, from a safe stack.

**Consequences.** One `pcall` per input frame, which is noise next to the
per-segment refresh ioctl already on that path. A bug surfaces as "drawing
stopped, here is a notification" instead of a crash. There is a one-tick window
where the hooks are installed but inert, which is the price of not corrupting
the frame we failed in.

Rejected: letting errors propagate and relying on KOReader's crash log. It is
the current behaviour, and it is how a one-line typo becomes a device that has
to be restarted with the pen still on the page.

## ADR-13 — Suppress at the widget layer, not in the capture hook

**Context.** Clearing `GestureDetector:feedEvent`'s return array suppressed only
what feedEvent produced. `hold` and the deferred single `tap` come from
`Input:setTimeout` callbacks dispatched directly by `Input:waitEvent`
(input.lua:1584 @ v2026.07), so they escaped it: a stationary finger raised the
text-selection popup mid-stroke. The stylus route papered over that with
`dropContact`, which destroys the contact and was unusable on the finger route
because ADR-2 needs that state alive.

The decision was also per frame. Gestures carry a position but not a slot, so
releasing the frame that carried the pen's tap on a toolbar button released a
simultaneous palm's gesture with it.

And it forced the plugin to keep its own copy of GestureDetector's contact
bookkeeping to reconstruct what was happening. Every bug in that copy was a
behaviour bug: a palm that landed first answered for the finger reaching for
Stop, and the pen's per-frame flag leaking past an error disarm released the
next session's first frame.

**Decision.** Suppress in `InkBar:onGesture`, via `InkBar:suppresses`.
`UIManager:sendEvent` offers every input event to the topmost non-toast widget
and stops when it returns true (uimanager.lua:884 @ v2026.07), timer-born
gestures included — they arrive through the same `handleInputEvent` path.
Gestures reach a widget rotation-adjusted and carrying `pos`, so the decision is
per gesture and needs no coordinate transform of its own. A gesture with no
position cannot be attributed to a contact and is suppressed. The capture hook
goes back to its original job: observing contacts to draw from.

**Consequences.** The timer path is covered on both routes. Palm rejection is
per gesture, so the narrow case where a palm escaped with the pen's toolbar tap
is closed. `dropSuppressedContacts` is gone and the plugin's contact bookkeeping
shrank to what the decision actually reads.

The price is a hard dependency on the toolbar being the topmost widget. The
invariant "drawing implies a visible toolbar" stops being a UX promise and
becomes a safety requirement — `setBarShown(false)` already calls
`setDrawing(false)`, and that call is now load-bearing.

Rejected: clearing `contact.pending_hold_timer` on suppressed contacts. It works
— the hold timer is only ever armed on the initial contact down
(gesturedetector.lua:673 @ v2026.07) and its callback re-checks the field — but
it reaches into another module's private state, it cannot fix the per-frame
problem, and it would silently kill a legitimate two-finger hold.

*Refined by ADR-17.* The reasoning above holds for a contact that already
exists. Withholding a slot from its *very first* frame is a different thing: no
Contact is opened, so there is no timer to suppress. The canvas needs that,
because it hands gestures above the sheet to the book on purpose and a gesture
carries no slot number.

## ADR-14 — Canvas ink goes in its own SQLite database, not in the sidecar

**Context.** The EPUB canvas stores freehand ink against a book position rather
than a page. A reader who uses it seriously accumulates far more ink than the
per-page PDF feature ever produces, and all of it belongs to one book.

`fingerink_strokes` lives in the document sidecar, which is the obvious place
to put canvases too. It does not survive the volume. `DocSettings:flush()`
serialises the *entire* settings table with `dump()` and rewrites the file, so
one new stroke re-serialises every point in the book. Measured against
KOReader's own `dump.lua`, the current stroke format costs about 67 bytes per
point; a thousand 600-point strokes is roughly 38 MiB of Lua source, rewritten
on every flush, and duplicated again in whatever metadata backups the reader
has enabled.

**Decision.** Canvases and their strokes live in
`DataStorage:getSettingsDir() .. "/fingerink.sqlite3"` — the same global
location and the same `lua-ljsqlite3` pattern the Statistics plugin uses.
Points are stored as chunked binary blobs, four bytes per point, and are read
only for the canvas that is open. `fingerink_strokes` and `ink_store.lua` are
untouched: the PDF feature keeps its format.

A book is keyed by `(partial_md5_checksum, file_size)`, not by path, so
renaming or moving a book keeps its notes. Without both values the repository
refuses rather than falling back to the path.

The file is not put inside `.sdr`. `DocSettings.updateLocation` only knows
about `metadata.lua`, the custom cover and custom metadata, so a companion file
there would not reliably follow a move, copy or delete.

**Consequences.** A reader's backup has to include `fingerink.sqlite3`, not
just the book's `.sdr` folder — and with WAL on, either with KOReader closed or
including the `-wal`/`-shm` files. Copying a book to another device no longer
carries its canvases; sync and export stay out of scope.

Two properties of the driver had to be discovered by probing it rather than by
reading the design, and both are load-bearing:

- INTEGER columns come back as int64 cdata. `1LL == 1` is true, but `t[1LL]`
  and `t[1]` are different table keys and `1LL .. ""` raises. Every integer is
  converted at the repository boundary; a page index built from raw driver
  output would silently miss every lookup.
- A Lua string binds as TEXT even into a column declared BLOB, and SQL that
  touches a TEXT value stops at its first NUL — `length()` on a point blob
  answers 1. `CAST(?n AS BLOB)` going in and `CAST(points AS TEXT)` coming out
  give a genuine blob with plain Lua strings on both sides.

Rejected: a plain-Lua fake SQL engine for the test suite. The suite runs under
a bare interpreter with no KOReader and cannot load the driver, so the
repository's own tests drive a recorder that proves control flow — transaction
order, backup before migration, that the listing query does not name `points` —
and say so. Everything about SQL *semantics* is proven in `tests/conformance.lua`
against real SQLite, alongside the existing runtime claims. A fake that answered
questions about constraints would be answering them wrong.

Rejected: `drawnotes.koplugin`'s approach of opening a second `DocSettings` for
the same book and flushing whole snapshots. It can overwrite live metadata and
keeps the monolithic cost. One source of truth, and no `DocSettings:flush()` of
our own.

## ADR-15 — Anchor the sheet, not the ink

**Context.** Direct ink is stored in screen coordinates against a page number,
which is fine in a PDF and wrong in an EPUB: change the font size and the text
moves while the ink stays. Making ink follow reflowing text means tying every
point to a position in the DOM, recovering those positions after every
recomposition, and deciding what a stroke that spanned a line break now means.
There is no answer to that last question that a reader would recognise as
theirs.

**Decision.** The ink does not follow the text. A canvas is a blank sheet
anchored to one position in the book, and the strokes live in the canvas's own
coordinate space. Reflow moves the sheet; it cannot move what is on it.

**Consequences.** The hard problem disappears. The only thing that has to
survive a recomposition is a single xpointer, and the layout-detection
machinery an earlier sketch of this needed — comparing rendering hashes to
decide whether stored ink is still valid — is gone. What remains of
`getDocumentRenderingHash` is a key for a discardable cache of resolved pages;
a stale entry costs one redundant confirmation, never a misplaced canvas.

The second consequence was not the goal and may matter more day to day: the
drawing surface is now a bounded rectangle, so there is somewhere for touch to
still mean "turn the page". Under the old rule drawing suppressed every gesture
on the screen and Stop was the only way back into the book.

The price is that a canvas cannot be drawn *over* the text. v1 does not try;
the pen over the book does nothing.

Both xpointer forms are stored, raw and normalised, with the `cre_dom_version`
the canvas was born under. `getNormalizedXPointer` is canonical only for DOMs
at or above `getDomVersionWithNormalizedXPointers`, and `ReaderRolling`'s own
xpointer migration walks the last position and the annotations — it has never
heard of this plugin's tables. Storing both from birth is what makes a canvas
findable after a DOM upgrade without depending on a closed loop.

An anchor that resolves to neither form is kept and listed, never deleted. The
text may come back, and a reader's notes are not the plugin's to discard.

## ADR-16 — One composite window, not a stack of them

**Context.** The sheet, its resize handle and the toolbar all need input. The
obvious arrangement is three ordinary windows in the order
`ReaderUI < sheet < toolbar`.

`UIManager:sendEvent` makes that unworkable. It offers an input event to the
topmost non-toast widget and stops as soon as one returns true; it does *not*
carry on down the stack when that widget returns false. Two of our windows
would therefore be two things competing to be topmost, with whichever lost deaf
to everything.

**Decision.** `InkCanvasOverlay` is the only window. The sheet, the handle and
the toolbar are its children. `InkBar` gained an `embedded` mode: as a child it
answers for its buttons and leaves the forwarding and the suppression decision
to the overlay; standalone over a PDF it is unchanged.

Paint order and hit-test order are opposite on purpose. `WidgetContainer`
offers an event to numeric children before its own handler, so the toolbar is
`self[1]` and gets first refusal; `paintTo` draws it last so it sits on top.

**Consequences.** There is exactly one place that decides where a gesture goes,
and it decides by geometry. The overlay declines one region — the screen above
the sheet — and hands it to the window below through `ink_stack`, which is the
same explicit forwarding ADR-10 established for the standalone toolbar and now
lives in one file instead of two.

The invariant from ADR-8 survives in a new shape: *Hide* with a sheet open puts
the sheet away rather than hiding a toolbar that is not a window.

Rejected: keeping three windows and marking the sheet `is_always_active`. That
flag gets a widget a second pass over input, not first refusal, and the
ordering between two such windows is exactly as fragile as the problem it would
be papering over.

## ADR-17 — Latch a contact's destination, and withhold a palm's slot

**Context.** With a sheet open the screen has four owners — the toolbar, the
handle, the sheet, and the book above it — and a contact can cross between them
mid-sequence.

Changing a contact's owner part-way through corrupts GestureDetector either
way. Giving a slot back makes it open a fresh contact and emit a spurious tap
on lift; taking one away strands a contact that never sees its lift, leaving a
hold timer that blocks the slot until the next `dropContacts()`.

**Decision.** A contact is classified once, on the first frame that carries
real coordinates, and never reclassified. Order: dialog, toolbar, handle,
canvas, book. A stroke dragged onto the toolbar presses no button; a tap that
began on a button never becomes a stroke.

The toolbar's position in that order is the safety invariant. A new finger
while the pen is down becomes a palm anywhere on the page — but never on the
toolbar, because pressing Stop with a pen resting on the sheet has to work.

A palm's slot is withheld from `GestureDetector` entirely, the down frame and
the lift alike.

**Consequences.** This is not belt-and-braces over ADR-13's widget-layer
filter; it is the only mechanism available. An emitted gesture carries `ges`,
`pos` and `time` and no slot number (gesturedetector.lua:540, :606, :1262), and
the overlay deliberately forwards gestures above the sheet to the book. So once
a palm's `hold` has been produced there is nothing left to distinguish it from
the reader's own. Keeping the Contact from existing is where the two can still
be told apart.

Withholding the lift as well as the down matters: handing the detector a lift
for a contact it never opened is the other half of the same bookkeeping bug.

One case a filter cannot reach: a contact-down frame with no coordinates has
already gone through by the time the next frame places it. `Capture:dropContact`
retires that one — per slot, through GestureDetector's own method, so a finger
on the toolbar is not caught up in it. That is the same API ADR-13 declined to
reach past, used the way it is meant to be.

A finger already resting when the pen lands is cancelled: the single deliberate
exception to the latch, because a hand turning the page mid-stroke is the
failure the stylus route exists to prevent.

## Deferred

- Scroll view mode (`paintTo` offset and page identity both change).
- Segment-distance eraser (ADR-7).
- Layout-change detection for EPUBs (ADR-5). The canvas sidesteps it: an
  anchored sheet keeps its own coordinates, so reflow moves the sheet, not the
  ink (ADR-15).
- Drawing on a sheet over a PDF. The `anchor_kind = 'page'` column is reserved
  and `ink_anchor.forPage` exists; nothing uses either yet.
- A global list of every canvas in every book, and search across them.
- Export and cross-device sync of canvases.
- A live indicator while the sheet's resize handle is dragged. Only worth
  adding if the physical gate shows the magnetic stops are not enough.
- Save-on-stroke instead of `onSaveSettings`, if crash loss turns out to matter.
- Draggable toolbar (`MovableContainer`) if the fixed centred position gets in
  the way of a particular book's layout.
