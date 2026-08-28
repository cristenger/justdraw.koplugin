# JustDraw

https://github.com/user-attachments/assets/66a1f825-9707-4755-bf09-310789dac2b5

Draw on book pages in KOReader with your **finger** on e-readers that have no
stylus (Kindle Paperwhite included), or with the **pen** on a Kindle Scribe.

Two ways to draw:

- **On the page.** Ink goes straight onto whatever is there. Works in any
  document. Anchored to a page number, so in an EPUB it stays put while the
  text moves.
- **On a sheet.** A blank page anchored to a *position* in a reflowable book.
  Change the font and the sheet follows the paragraph — the drawing itself
  never moves, because it is not on the page at all. And with a sheet open you
  can still turn pages with a finger.

No core files are patched; it is a plain drop-in plugin folder.

## Compatibility

| Route | Minimum KOReader | Devices |
| --- | --- | --- |
| Finger | v2026.03 | any touch e-reader |
| Stylus | **v2026.07** | Kindle Scribe (Scribe, Scribe 3, Scribe Colorsoft) |

The stylus route needs `Input:registerStylusCallback`, which landed in
v2026.07. Do not use v2026.03 for pen input: it shipped a Kindle Scribe
regression that broke the stylus while touch kept working
([#15164](https://github.com/koreader/koreader/issues/15164)), reverted for the
v2026.07 milestone ([#15675](https://github.com/koreader/koreader/pull/15675)).

Kobo stylus devices (Elipsa, Sage, Libra Colour) are **not supported**: they
are untested here. They report their tool differently from the Kindle Scribe,
so the stylus route may well work — select *Stylus* by hand under Input mode
and treat it as experimental.

## Install

Copy `justdraw.koplugin` into KOReader's `plugins` directory. Over SSH:

```sh
scp -r justdraw.koplugin root@<kindle>:/mnt/us/koreader/plugins/
```

You should end up with `koreader/plugins/justdraw.koplugin/main.lua` — not a
doubled `justdraw.koplugin/justdraw.koplugin/`. Restart KOReader.

### Upgrading from FingerInk

Stop KOReader and **rename or replace** the former `fingerink.koplugin`
directory; do not leave the old and new plugin directories installed together.
For example, on the device:

```sh
mv /mnt/us/koreader/plugins/fingerink.koplugin \
   /mnt/us/koreader/plugins/justdraw.koplugin
```

Then copy the new JustDraw files into that directory and restart KOReader.
Preferences are read from their former identifiers once and copied forward.
Potentially large direct page ink is not duplicated: an upgraded document that
only has `fingerink_strokes` keeps using that key in place, while a new document
uses `justdraw_strokes`. A rollback to FingerInk therefore sees and edits the
same history for upgraded documents. If both keys already exist, JustDraw uses
the current key and leaves the legacy history untouched; it never merges them.

Existing canvas and notebook databases are opened in place under their legacy
filenames; new installations create the new filenames. This avoids moving an
SQLite database separately from a pending `-wal` or `-shm` file. If both the
JustDraw and FingerInk filenames exist for the same feature, JustDraw refuses to
open either. With KOReader closed, move one complete database set to another
directory: the `.sqlite3` file together with any matching `.sqlite3-wal` and
`.sqlite3-shm` files. JustDraw never guesses which note history to keep and
never merges databases automatically.

## Using it

A four-button toolbar sits on the right edge of the screen. It is always
tappable, including while drawing is on — that is the whole point of it.

| Button | Does |
| --- | --- |
| **Draw** / **Stop** | start and stop drawing |
| **Pen** / **Eraser** | switch tool (also starts drawing if it is off) |
| **Undo** | remove the last stroke on this page, or on the open sheet |
| **Hide** | stop drawing and hide the toolbar, or put the sheet away |

### Input modes

Top menu → More tools → JustDraw → **Input mode**. Not changeable while
drawing; press Stop first.

- **Automatic** (default) — the stylus route on devices that report a pen
  digitizer, the finger route everywhere else. A Paperwhite is unaffected.
- **Stylus** — force the pen route. Refuses to start, with an explanation, if
  this KOReader has no stylus API or another plugin already owns it.
- **Finger** — force the legacy route.

### Finger route

- **One finger** draws, anywhere except on the toolbar.
- **Two fingers** work exactly as they normally do — page turn, menus,
  gestures. Landing a second finger cancels the stroke in progress.
- Eraser removes a whole stroke you touch, not part of one.

### Stylus route

- **The pen tip** draws. **The eraser end** erases whole strokes, whatever the
  toolbar's tool is set to.
- **Finger and palm do nothing at all** while Draw is on: no ink, no page
  turns, no gestures, and they never cancel the pen's stroke. That is the palm
  rejection, and it is deliberately blunt — no attempt is made to tell a palm
  from a finger. **Press Stop to read again.**
- The toolbar still takes taps from finger *and* pen, and an open menu or
  dialog still takes input, so nothing can trap you.
- The side button, if your Scribe's firmware reports one, is handled by
  KOReader as an eraser modifier while held. Unverified on hardware.
- Dragging a stroke onto the toolbar ends it at the edge instead of scribbling
  over the buttons.

You can never end up drawing with no toolbar on screen: starting to draw shows
it, and hiding it stops drawing.

Ink is saved into the book's sidecar, per page, when KOReader flushes settings.

## Drawing sheets (EPUB and other reflowable books)

Top menu → More tools → JustDraw → **Drawing sheet** → *Open sheet here*.

A blank sheet slides up from the bottom and is anchored to wherever you are in
the book. **Tap the strip along its top edge** to cycle through 40%, 70% and
full screen, or drag that strip and let go — it snaps to the nearest of the
three. There is no live preview while you drag; e-ink cannot repaint fast
enough for one to be worth having, which is why there are three stops rather
than a continuous height.

While a sheet is open:

- the **pen** draws on the sheet, and does nothing over the book's text;
- a **finger above the sheet still turns pages**, so you can read around it;
- a **palm resting on the sheet** does nothing at all — no ink, no page turn,
  and it cannot interrupt what the pen is drawing;
- the toolbar floats on top and stays tappable, always. **Hide** puts the sheet
  away.

A book with sheets in it shows a small flag in the margin on every page that
has one. Reopening is *Open sheet here* on that page; if a position has more
than one sheet you are asked which.

Sheets are anchored by position, not by page, so changing font, margins or line
spacing moves the sheet with its paragraph and leaves the drawing untouched.
Rotating the device rescales the sheet to fit, letterboxed if the shape
changed, with everything still on it.

If the book is replaced by a different edition, an anchor can stop resolving.
Those sheets are **never deleted** — they appear under *Lost sheets*, where you
can open or remove them.

### Where sheets are stored

In `settings/justdraw.sqlite3`, one database beside KOReader's own, not in the
book's `.sdr` folder. Two consequences worth knowing:

- **Back up that file**, not only the `.sdr` folders. With WAL active, back it
  up with KOReader closed, or include the `-wal` and `-shm` files.
- Copying a book to another device does **not** take its sheets along. Sync and
  export are not implemented.

An installation upgraded from FingerInk may continue to use
`settings/fingerink.sqlite3`. JustDraw selects that existing database only
when `settings/justdraw.sqlite3` does not exist, so no notes are copied,
merged or silently discarded during the rename. If both files exist, drawing
sheets stay unavailable until KOReader is closed and one complete database set
— main file plus matching `-wal` and `-shm` companions — is moved together to
another directory.

A book is identified by its checksum and size, so renaming or moving it keeps
its sheets. If KOReader has not computed a checksum yet, sheets are unavailable
for that book and the plugin says so rather than falling back to the file path,
which would lose them at the first rename.

Ink on a sheet is written within a quarter of a second of lifting the pen, and
always before KOReader suspends or closes the book. If a write fails you are
told, drawing stops, and the strokes stay in memory so you can retry — nothing
is silently reported as saved.

Opening a populated sheet streams its strokes a chunk at a time and yields
between bounded point budgets. Drawing stays off until every chunk has passed
its codec, order, seam and count checks. A read error leaves the database
unchanged and keeps the sheet open with **Retry loading sheet**; pending edits
are committed before a retry rebuilds the raster, so a reload cannot resurrect
a pending erase or lose a pending insert.

Books with many sheets also build and persist their page index in small
per-tick batches. No final O(number of sheets) SQLite burst runs on the UI
thread; only the last small batch prunes stale layout caches.

If the database was created by a newer JustDraw schema, this version reopens
it read-only. Existing sheets can still be viewed and hidden, but create,
delete, pen, eraser and undo stay disabled; no journal setting or note row is
written by that compatibility path.

## Standalone notebooks

The notebook domain is implemented separately from books and drawing sheets:
notebooks, pages, current-page state and chunked ink live in
`settings/justdraw-notebooks.sqlite3`. It does not use book checksums,
xpointers, document sidecars or the EPUB canvas database.

An upgraded installation may instead keep using the existing
`settings/fingerink-notebooks.sqlite3` for the same in-place safety rule. If
both notebook filenames exist, the library names the conflict and remains
closed until KOReader is stopped and one complete database set, including any
matching `-wal` and `-shm` companions, is moved together to another directory.

Open **Notebooks** from FileManager's **More tools** menu or from
**More tools → JustDraw** while reading. The full-screen library creates,
opens, renames and deletes notebooks without requiring a document. Opening a
row keeps the library underneath a full-screen editor, so leaving the notebook
returns to the same library instead of rebuilding the whole navigation stack.

The editor presents a bounded paper viewport and a physical control rail. Pen
input is captured only over the paper; the rail, error banner and dialogs stay
interactive. Rail placement is an explicit left/right preference and does not
change with the book language. Controls and rows target at least 10 mm using
KOReader's DPI scaling, subject to the available screen geometry.

The backend is designed for large libraries and dense pages:

- notebook and page lists are metadata-only, keyset-paginated and capped;
- one open page owns one raster, and changing page frees the previous raster;
- strokes load in bounded chunk/point batches;
- each persisted chunk is fetched by key and its SQLite statement is closed
  inside that scheduler turn; no long-stroke cursor or WAL snapshot survives
  between ticks;
- a hardware-neutral input adapter maps the existing pen, physical eraser and
  finger-compatibility routes onto the active page; Automatic selects stylus
  only when KOReader exposes both the callback API and a Wacom device flag.
  Nib width and eraser reach are converted from screen pixels to logical page
  units once per contact;
- ReaderUI validates the database, initial page and viewport before handing
  its single process-wide input lease to the notebook. An open EPUB sheet is
  flushed and its raster freed first; a failed flush keeps its retry surface
  and prevents the notebook from opening. Closing a notebook deliberately
  does not restart book drawing;
- page order is append-only in v1, with an O(1) `next_sort_key` counter;
- deleting a notebook, page or stroke first writes a small tombstone;
- a controller-owned leaf-first purge runs one bounded batch per scheduler
  turn, pauses during load, save failure or pen contact, never runs `VACUUM`,
  and never cascades a large tree in one UI tick;
- every committed ink batch updates page/library recency once, not once per
  stylus sample or stroke;
- stroke and current-page metadata failures keep the queue/cache alive, block
  navigation, resize, editing and normal close, and remain retryable;
- suspend releases capture and resume reacquires it only when there is no
  pending input error. `input_failed` survives resume, page navigation and page
  creation until `retryInput` is invoked explicitly;
- future-schema read-only databases can navigate pages entirely in memory;
  current-page state, append and deletion perform zero writes;
- a forced host teardown always releases the global callback and closes SQLite;
  if its final COMMIT fails, only then is the in-memory retry queue discarded.

The UI supplies the controller with the actual page viewport, paint
invalidation, touch pass-through and stylus-overlay regions without accessing
SQLite or `ink_capture` directly. Dirty callbacks receive a clipped screen
destination box plus a separate cache-source box. A control or modal inside
the page is declared through `stylus_passthrough`; if it appears mid-stroke,
live ink is repaired and the pen remains suppressed until lift. Resize or open
without a viewport, and explicit fit/clip rectangles with no visible
intersection, are rejected instead of treating screen chrome as paper.

The library loads metadata in capped keyset batches of 50. Page navigation uses
cached neighbour flags, while ink and page data keep the bounded scheduling,
single-raster ownership and durability gates described below. UI state reads
do not issue SQLite queries during paint or stylus callbacks.

The v1 information strip intentionally omits a **Saved/Not saved** label. Ink
remains protected by the same durable close and navigation gates, but avoiding
that label also avoids a timer and repeated chrome refreshes after short ink
batches on e-ink hardware.

As with drawing sheets, back up the database with KOReader closed, or include
its WAL sidecars. Notebook export, sync, trash restoration, page reordering,
templates beyond their stored identifier, and multi-page thumbnails remain
out of scope for this backend phase.

## Menu and gestures

FileManager → More tools → Notebooks: open the standalone notebook library.

Reader top menu → More tools → JustDraw: notebooks, start drawing, show/hide
the toolbar, put it on the left instead, input mode, pen width, refresh quality,
stylus diagnostics, clear page, clear document.

### The pen does nothing

Open **Stylus diagnostics**. It puts the answer on screen: your KOReader
version, whether this build has the stylus API at all, whether the device
reports a pen digitizer, and which route *Automatic* settled on — plus the first
unmet requirement in plain words.

The quickest thing to know: **if your finger draws, the pen route is not
running.** The stylus route suppresses all touch, so a finger that inks proves
the plugin fell back to the finger route. The report says why.

The most common cause is the KOReader version. The pen route needs **v2026.07**.
On a device that reports a pen digitizer but runs an older KOReader, drawing
still starts on the finger route and the plugin says so once.

**v2026.03 cannot drive the pen on a Scribe at all**, for two independent
reasons, and no plugin can work around either:

- it has no `Input:registerStylusCallback` — the API the pen route is built on
  does not exist in that release;
- its Kindle input match mask still includes the raw `INPUT_TABLET`
  device alongside the properly scaled one, so the two emit conflicting pen
  events ([#15164](https://github.com/koreader/koreader/issues/15164), reverted
  for v2026.07 in [#15675](https://github.com/koreader/koreader/pull/15675)).

It also only knows one Scribe model. `KindleScribe3` and `KindleScribeColorSoft`
were added in v2026.07, so on v2026.03 those two are not detected as Scribes and
never get their pen set up in the first place.

The same screen also arms a local log: one line per pen event for one minute,
capped at 8,192 events, then it stops on its own. It is available from the
standalone notebook editor's **More** menu as well as the reader menu. Each
line contains scalar digitizer data (frame, slot, tracking id, tool, position
and time), the state transition and the routing decision. It contains no book
title, path, xpointer or notebook content and JustDraw does not upload it.
Coordinates can still reveal the shape and timing of handwriting, so inspect
the warning before recording and treat a shared KOReader log as sensitive.
"Start drawing" closes the menu on purpose — an open menu is useless once
single-finger taps are going to ink.

Optional Gesture Manager actions: *toggle drawing*, *toggle eraser*, *undo
stroke*, *toggle toolbar*. A two-finger tap is a good fit for any of them,
since two-finger gestures keep working while drawing.

## Known limits

- **Drawing on the page: set your layout before you write.** Strokes are stored
  in screen coordinates against a page number, so changing font size, margins
  or rotation in an EPUB moves the text and leaves the ink behind. Same caveat
  `pencil.koplugin` carries. Drawing sheets exist precisely to avoid this and
  do not have it.
- **Sheets are for reflowable books only.** In a PDF or another fixed layout
  the menu entry is greyed out; draw on the page instead.
- **Standalone notebook ergonomics still require the physical Scribe gate.**
  The emulator and automated suites verify discovery, bounded rendering,
  lifecycle, persistence and synthetic routing, but not Wacom latency, palm
  feel, e-ink ghosting or whether the resize-independent control rail is
  comfortable on real hardware.
- **Stylus contact-boundary hardening is trace-gated.** KOReader gives plugins
  accumulated `{x, y}` slot state but no per-frame changed-axis mask. JustDraw
  now has bounded diagnostics, a persistent-slot replay harness and a shared
  fail-closed sequence normalizer, but the existing drawing routes are not
  switched to that normalizer until a real Scribe trace identifies a geometry
  rule that does not discard legitimate dots, horizontal lines or vertical
  lines. Until that physical gate is completed, a missing or reordered Wacom
  boundary may still join two contacts. This limitation is not hidden by a
  distance or fixed-sample heuristic.
- **You cannot draw over the text on a sheet.** The sheet is blank paper: the
  pen inks on it and does nothing over the book itself.
- **Opening a sheet is refused while a book is still being indexed.** On a book
  with hundreds of sheets that takes a moment after opening; the menu entry is
  greyed out until it finishes, so you cannot accidentally make a second sheet
  on a paragraph that already has one.
- Single-page view only. Scroll mode is not handled.
- Fast refresh uses the DU waveform: grainy, and ghosting can build up. Turn it
  off in the menu if you would rather use quality partial refreshes while
  drawing. Standalone notebooks use the selected mode for live ink; after fast
  ink they schedule one regional partial cleanup for the accumulated burst
  (after 350 ms of idle, eight completed contacts, or 25% of the paper area).
  The cleanup is deferred while the pen is down or a modal covers the paper.
  Direct page ink and EPUB sheets retain their existing per-segment behavior;
  whether further coalescing feels better remains a hardware measurement.
- **Finger route: no palm rejection.** There is no tool-type data on that
  hardware to do it with, so a palm landing as a second contact cancels the
  stroke in progress. The stylus route does reject palms, by suppressing all
  touch.
- **Stylus route on the book page: touch navigation is off while drawing.** On
  a bounded drawing sheet, a finger above the sheet can still navigate; touch
  on the sheet remains suppressed.
- **Both routes: touch gestures are filtered by position while drawing.** A
  gesture that lands on the toolbar goes to the toolbar; everything else is
  swallowed until you press Stop. That includes long-presses, which used to slip
  through on the finger route, and a palm's gesture in the same frame as a pen
  tap on a button, which used to slip through on the stylus route.
- **The toolbar has to be on screen for that filtering to happen.** It always
  is — hiding it stops drawing — but it is now a requirement rather than a
  convenience.
- **Suspend stops drawing.** Resuming leaves drawing off and the toolbar up;
  press Draw again. Suspending mid-stroke means KOReader never delivers the pen
  lift, so restarting from a clean state is the only safe option.
- **A handler error stops drawing** rather than taking KOReader down: the
  plugin unhooks itself, tells you once, and leaves reading working.
- The toolbar takes about 15% of the screen width. Hide it when you are just
  reading.

## Tests

```sh
luajit test.lua                       # from the repository root
luajit tests/run.lua                  # from inside justdraw.koplugin/
lua test.lua                          # any Lua 5.1+, no LuaJIT needed
```

All three run the same suite; it needs no KOReader session. Every push and
pull request runs it on CI, together with a syntax sweep over every Lua file
in the plugin.

The suite fakes KOReader. `tests/conformance.lua` is what checks those fakes
against the real thing — run it from inside a KOReader build directory:

```sh
cd /path/to/koreader-emulator-*/koreader
./luajit /path/to/justdraw.koplugin/tests/conformance.lua
```

It prints one line per assumption: `OK`, `MISMATCH`, or `UNCHECKABLE` when the
runtime is older than the API in question — or, for the anchor claims, when no
book was passed. **`UNCHECKABLE` is not a pass** — on
a KOReader without the stylus API, the pen claims come back unchecked and the
stylus route is still only covered by fakes. A `MISMATCH` means a fake lies;
fix the fake.

The suite covers clipped rasterisation, live-raster generation tokens, bounded
write admission, the stroke store and hit test, the rotation transform for all
four rotations, both capture backends, ownership-safe install and removal,
error containment, the current pen route, the isolated sequence normalizer,
the residual contact bookkeeping, notebook quality refreshes, the widget-layer
suppression rule, and toolbar reachability — that a tap starting on the bar
passes through and inks nothing, that a stroke dragged onto it is truncated
rather than painted over the buttons, and that a resting palm cannot make Stop
unreachable.

What it cannot prove is the toolbar's pixel layout: the fake buttons have no hit
rectangles, so "the tap reached the toolbar" is as far as it goes. Whether it
landed on the right button is what the physical test matrix is for.

The pen tests drive synthetic slots that reproduce KOReader's real slot
lifetime: one persistent table per slot, reused across frames, with `id`, `x`
and `y` surviving a lift.

Synthetic replay proves the state-machine invariants but cannot choose a safe
initial geometry policy: KOReader's public callback does not say which axes
changed in a frame. The shared normalizer therefore remains fail-closed and is
not wired into production drawing hosts until the Scribe trace gate is met.

**Not covered:** real Wacom hardware, e-ink ghosting and latency, and Kindle
firmware. Those need a physical Kindle Scribe.

The canvas suites lean on counters rather than pixels, because what they are
claiming is about work that must not happen: ten repaints of a sheet decode no
points, a 100,000-point stroke yields at the point budget, an erase reads only
nearby chunks and reuses an eight-chunk LRU for one contact, turning a page
while a book is being indexed resolves no xpointers, and painting a margin flag
issues no query and makes no CREngine call.

The database is the one thing `tests/run.lua` cannot honestly test. The suite
runs under a bare interpreter with no KOReader and cannot load the SQLite
driver, so the repository is driven there by a recorder that executes nothing
and pins only control flow — transaction and rollback order, backup strictly
before migration, that the listing query never names `points`. Everything about
SQL *semantics* lives in `conformance.lua` instead, against real SQLite:
transactional schema creation, constraints, cascades, the blob round trip,
streaming cursors, the layout prune and a blocked WAL checkpoint that must stop
a migration before backup. Pass a book to that script and it also checks the
xpointer API against a real rendered document:

```sh
./luajit /path/to/justdraw.koplugin/tests/conformance.lua /path/to/book.epub
```

## Docs

`requirements.md` — what this is for. `spec.md` — how it works, source of truth.
`decisions.md` — why it works that way.
