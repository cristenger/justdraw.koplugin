# Finger Ink

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

Copy `fingerink.koplugin` into KOReader's `plugins` directory. Over SSH:

```sh
scp -r fingerink.koplugin root@<kindle>:/mnt/us/koreader/plugins/
```

You should end up with `koreader/plugins/fingerink.koplugin/main.lua` — not a
doubled `fingerink.koplugin/fingerink.koplugin/`. Restart KOReader.

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

Top menu → More tools → Finger Ink → **Input mode**. Not changeable while
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

Top menu → More tools → Finger Ink → **Drawing sheet** → *Open sheet here*.

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

In `settings/fingerink.sqlite3`, one database beside KOReader's own, not in the
book's `.sdr` folder. Two consequences worth knowing:

- **Back up that file**, not only the `.sdr` folders. With WAL active, back it
  up with KOReader closed, or include the `-wal` and `-shm` files.
- Copying a book to another device does **not** take its sheets along. Sync and
  export are not implemented.

A book is identified by its checksum and size, so renaming or moving it keeps
its sheets. If KOReader has not computed a checksum yet, sheets are unavailable
for that book and the plugin says so rather than falling back to the file path,
which would lose them at the first rename.

Ink on a sheet is written within a quarter of a second of lifting the pen, and
always before KOReader suspends or closes the book. If a write fails you are
told, drawing stops, and the strokes stay in memory so you can retry — nothing
is silently reported as saved.

## Menu and gestures

Top menu → More tools → Finger Ink: start drawing, show/hide the toolbar, put
it on the left instead, input mode, pen width, refresh quality, stylus
diagnostics, clear page, clear document.

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

The same screen also arms a log: one line per pen event for a minute, capped at
500 lines, then it stops on its own. Each line carries the digitizer's slot,
tracking id, tool, position and whether that position repeated the last lift —
nothing about the book you have open.
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
- **You cannot draw over the text on a sheet.** The sheet is blank paper: the
  pen inks on it and does nothing over the book itself.
- **Opening a sheet is refused while a book is still being indexed.** On a book
  with hundreds of sheets that takes a moment after opening; the menu entry is
  greyed out until it finishes, so you cannot accidentally make a second sheet
  on a paragraph that already has one.
- Single-page view only. Scroll mode is not handled.
- Fast refresh uses the DU waveform: grainy, and ghosting builds up until the
  next page turn. Turn it off in the menu if you would rather have clean strokes
  slowly.
- **Finger route: no palm rejection.** There is no tool-type data on that
  hardware to do it with, so a palm landing as a second contact cancels the
  stroke in progress. The stylus route does reject palms, by suppressing all
  touch.
- **Stylus route: touch navigation is off while drawing.** Not a bug — see
  above.
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
luajit tests/run.lua                  # from inside fingerink.koplugin/
lua test.lua                          # any Lua 5.1+, no LuaJIT needed
```

All three run the same suite; it needs no KOReader session. Every push and
pull request runs it on CI, together with a syntax sweep over every Lua file
in the plugin.

The suite fakes KOReader. `tests/conformance.lua` is what checks those fakes
against the real thing — run it from inside a KOReader build directory:

```sh
cd /path/to/koreader-emulator-*/koreader
./luajit /path/to/fingerink.koplugin/tests/conformance.lua
```

It prints one line per assumption: `OK`, `MISMATCH`, or `UNCHECKABLE` when the
runtime is older than the API in question — or, for the anchor claims, when no
book was passed. **`UNCHECKABLE` is not a pass** — on
a KOReader without the stylus API, the pen claims come back unchecked and the
stylus route is still only covered by fakes. A `MISMATCH` means a fake lies;
fix the fake.

The suite covers rasterisation, the stroke store and hit test, the rotation
transform for all four rotations, both capture backends, ownership-safe install
and removal, error containment, the pen state machine (latching, sticky tracking
ids, the physical eraser), the residual contact bookkeeping, the widget-layer
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

**Not covered:** real Wacom hardware, e-ink ghosting and latency, and Kindle
firmware. Those need a physical Kindle Scribe.

The canvas suites lean on counters rather than pixels, because what they are
claiming is about work that must not happen: ten repaints of a sheet decode no
points, an erase reads only what the spatial index puts near it, turning a page
while a book is being indexed resolves no xpointers, and painting a margin flag
issues no query and makes no CREngine call.

The database is the one thing `tests/run.lua` cannot honestly test. The suite
runs under a bare interpreter with no KOReader and cannot load the SQLite
driver, so the repository is driven there by a recorder that executes nothing
and pins only control flow — transaction and rollback order, backup strictly
before migration, that the listing query never names `points`. Everything about
SQL *semantics* lives in `conformance.lua` instead, against real SQLite:
schema, constraints, cascades, the blob round trip, the layout prune. Pass a
book to that script and it also checks the xpointer API against a real rendered
document:

```sh
./luajit /path/to/fingerink.koplugin/tests/conformance.lua /path/to/book.epub
```

## Docs

`requirements.md` — what this is for. `spec.md` — how it works, source of truth.
`decisions.md` — why it works that way.
