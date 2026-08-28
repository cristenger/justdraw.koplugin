# requirements.md — JustDraw

## Goal

Scribble on book pages in KOReader:

1. with a **finger** on a **Kindle Paperwhite 10th gen**, where there is no
   stylus and no `ABS_MT_TOOL_TYPE` reporting — the original goal, unchanged;
2. with the **pen** on a **Kindle Scribe**, including the eraser end and real
   palm rejection.

The Paperwhite route is the compatibility floor. Nothing added for the Scribe
may change how it behaves.

## Must have

1. Draw freehand ink over the page of the book currently being read.
2. Work with finger input only. No stylus, no eraser end, no side button.
3. The finger route works on KOReader **v2026.03** — no dependency on
   `Input:registerStylusCallback`. The stylus route requires **v2026.07**,
   where that callback and the `Input.TOOL_TYPE_*` exports first appear, and
   which is also the first release with the Kindle Scribe stylus regression of
   v2026.03 reverted.
4. Leave normal reading completely untouched when drawing mode is off:
   no input hooks installed, no per-event cost, no changed gestures. The
   toolbar may stay visible; it must not alter input handling while idle.
5. An **always-reachable on-screen control** to start and stop drawing and to
   erase. It must keep working while single-finger touch is being swallowed.
   Reaching for the power button is not an exit route.
6. Ink persists per document, per page, across sessions.
7. Undo, erase, clear page, clear document.
8. Stroke feedback fast enough to be usable on e-ink — segment-level DU refresh,
   not a full-page repaint per point.

9. It must not be possible to reach a state where drawing is on and there is
   no visible way to turn it off.
10. On the stylus route: the pen tip draws, an eraser reported by KOReader
    erases, and finger and palm neither draw, nor navigate, nor cancel the
    pen's stroke. The toolbar and any open dialog stay reachable with both.
11. A Lua error raised inside an input handler must not reach KOReader's event
    loop. The plugin unhooks itself, reports once, and leaves reading working.
12. Activation must fail safely and visibly if another plugin already owns the
    single stylus callback. Never overwrite it.
13. A physical pen contact may retain at most 8,192 ink points and process at
    most 32,768 owner samples. Exceeding either limit must not persist a partial
    ink stroke or release palm rejection before the physical boundary.
14. Corrupt or extreme coordinates must not make raster work proportional to
    their distance. Render and refresh coverage stays finite and clipped to the
    active buffer.
15. Notebook/canvas writes must have hard admission bounds and must not begin a
    SQLite transaction synchronously from the stylus callback.

## Must not

- Replace or patch any KOReader core file. Drop-in plugin folder only.
- Allocate per touch point in the draw / render / hit-test paths.
- Leave input hooks installed after drawing mode is turned off.

## Out of scope for v1

- Scroll (continuous) view mode.
- Reflow-stable anchoring: strokes are keyed by page number, so changing font
  size or margins in an EPUB moves the text out from under the ink.
- Pressure, tilt and hover (the stylus callback does not expose them).
- Palm rejection on the **finger** route — there is no tool data to do it with.
  On the stylus route it is a requirement, met by suppressing all touch rather
  than by classifying it.
- Highlighter as a distinct tool: KOReader can report it, it draws as a pen.
- Certified support for stylus devices other than the Kindle Scribe.
- Vector export, PDF flattening, colour.
- Notebook export, synchronization, page reordering and multi-page thumbnails.
