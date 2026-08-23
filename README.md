# Finger Ink

https://github.com/user-attachments/assets/66a1f825-9707-4755-bf09-310789dac2b5

Draw on book pages in KOReader with your **finger** on e-readers that have no
stylus (Kindle Paperwhite included), or with the **pen** on a Kindle Scribe.

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
| **Undo** | remove the last stroke on this page |
| **Hide** | stop drawing and hide the toolbar |

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

## Menu and gestures

Top menu → More tools → Finger Ink: start drawing, show/hide the toolbar, put
it on the left instead, input mode, pen width, refresh quality, clear page,
clear document.
"Start drawing" closes the menu on purpose — an open menu is useless once
single-finger taps are going to ink.

Optional Gesture Manager actions: *toggle drawing*, *toggle eraser*, *undo
stroke*, *toggle toolbar*. A two-finger tap is a good fit for any of them,
since two-finger gestures keep working while drawing.

## Known limits

- **Set your layout before you write.** Strokes are stored in screen
  coordinates against a page number, so changing font size, margins or rotation
  in an EPUB moves the text and leaves the ink behind. Same caveat
  `pencil.koplugin` carries.
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
- **Stylus route, narrow case:** if you tap the toolbar with the pen while a
  palm rests on the screen, that one input frame is released as a whole and the
  palm's gesture can get through with it. KOReader's gesture events carry a
  position but not a slot number, so the decision cannot be made per contact.
- **Finger route: a stationary finger can still trigger a long-press.**
  KOReader produces `hold` from a timer that does not pass through the hook this
  route uses, so holding still while drawing can raise the text-selection popup.
  Pre-existing; the stylus route does not have this problem, because it drops
  suppressed contacts outright.
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
runtime is older than the API in question. **`UNCHECKABLE` is not a pass** — on
a KOReader without the stylus API, the pen claims come back unchecked and the
stylus route is still only covered by fakes. A `MISMATCH` means a fake lies;
fix the fake. Covers rasterisation,
the stroke store and hit test, the rotation transform for all four rotations,
both capture backends, ownership-safe install and removal, error containment,
the pen state machine (latching, sticky tracking ids, the physical eraser), the
residual touch filter, and toolbar reachability — that a tap starting on the bar
passes through and inks nothing, and that a stroke dragged onto it is truncated
rather than painted over the buttons.

The pen tests drive synthetic slots that reproduce KOReader's real slot
lifetime: one persistent table per slot, reused across frames, with `id`, `x`
and `y` surviving a lift.

**Not covered:** real Wacom hardware, e-ink ghosting and latency, and Kindle
firmware. Those need a physical Kindle Scribe.

## Docs

`requirements.md` — what this is for. `spec.md` — how it works, source of truth.
`decisions.md` — why it works that way.
