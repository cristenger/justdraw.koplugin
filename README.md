# JustDraw

JustDraw is an experimental [KOReader](https://github.com/koreader/koreader)
plugin for testing its new stylus support on e-ink devices. It is not built for
any particular brand or model. The plugin follows APIs that are still under
development, so expect rough edges and breaking changes.

## Requirements

- An e-ink device whose stylus input is exposed by KOReader.
- A current KOReader development build. Stable releases are not supported.

## Features

- Draw on the pages of fixed-layout documents (PDF, DjVu, comics). The ink is
  stored per page in the page's own coordinates, so it stays put under zoom
  and pan. Needs KOReader 2026.07 or newer.
- Attach drawing sheets to reflowable documents.
- Create standalone notebooks, on blank, ruled, squared or dotted paper.
- Export every note in a book — sheets, page notes and older direct ink — as
  one PDF or a series of images ("Document notes").
- Reject touch input while the stylus is drawing.

On KOReader 2026.03 only the original route remains: drawing straight onto the
screen with a finger, saved with the book's settings. From 2026.07 that older
"legacy" ink is still shown and exported, but nothing new is added to it: new
ink goes on drawing sheets (EPUB) or page notes (fixed layout). It can be
removed with **Clear legacy ink** in the JustDraw menu.

## Troubleshooting

**Graphite or marker trails behind the pen.** Open **More → Drawing refresh**
in a notebook or document drawing panel. Choose 20, 33, 50, 75, 100, 150 or
200 **milliseconds** between grayscale screen updates; 100 ms is the default.
The choice applies immediately and is remembered across documents and notebooks.
Try 75 or 50 ms first, then compare lower values on your device. Return to
100 ms if strokes become erratic. Black-only pages retain their 20 ms fast
refresh; pages containing gray ink use the selected interval even when you
switch back to the ink pen.

**Palm marks, stray lines, or a pen that erases on its own.** On Wacom devices
— the Kindle Scribes and the reMarkable — Linux reports a rejected touch with
the same numeric tool value KOReader uses for the stylus eraser, so a resting
hand reaches the same code path a pen does. JustDraw now trusts only the
digitizer's own slot, and a stylus-valued tool on any other slot is treated as
a palm: it draws nothing, erases nothing, and is withheld from the reader.

**A control that flashes but does nothing.** Notebook actions are refused while
any contact is still on the glass. Lift the pen *and* your hand; the rail comes
back on its own, and an action you activate meanwhile now says why it was
refused instead of failing silently.

**"Turn off continuous scrolling / reflow / page optimisation to draw page
notes", "Zoom out to see and draw page notes".** Page notes are shown and
editable only in single-page mode on an unmodified page: with scroll mode,
reflow or KOReader's page optimisation on, the page on screen no longer has
the geometry the notes were drawn in, so they are hidden rather than shown in
the wrong place. Zoomed far in, the page's note layer would not fit the memory
budget; zoom out and it comes back. Nothing is lost in either case.

**Strokes with corners you did not draw, or two strokes joined into one.**
When the device cannot keep up with the pen, the kernel throws input away and
says so once. JustDraw now ends the stroke there rather than joining what came
after it, so a lost moment costs the rest of one stroke instead of a line
across the page. *More tools → JustDraw → Stylus diagnostics* reports **Input
events the kernel dropped**; it should read 0. If it does not, the log is the
useful thing to attach.

**The sheet is showing a note I wrote somewhere else.** A drawing sheet is
anchored to a position in the book, not to a page, and you can keep reading
with one open — so the page behind it can change while the sheet stays put.
When that happens the sheet's top edge says which page it belongs to, and it
will not take ink until you are back on that page. The JustDraw menu has both
ways out: **Go to this sheet's page**, or **Open a sheet here instead**.

**Reporting an input problem.** *More tools → JustDraw → Stylus diagnostics*
records a bounded trace of pen decisions to the local KOReader log. It stops by
itself. If you also turned KOReader's debug logging on, turn it off again once
you have the reproduction: it records all raw input and the log grows very
quickly. Traces contain coordinates; they never contain document or notebook
identity.

Stylus behaviour is device behaviour, and the palm and coordinate handling
described here has not yet been through a hardware pass. If something above
does not match what your device does, the trace is the useful thing to attach.

## Install

Copy `justdraw.koplugin` into KOReader's `plugins` directory and restart
KOReader. The final path should be:

```text
koreader/plugins/justdraw.koplugin/main.lua
```

Open **More tools → JustDraw** while reading. Standalone notebooks are also
available under **File manager → More tools → Notebooks**.

**Pen controls.** Open **More → Pen settings** to choose a style and width
together: Ink pen, Graphite or Marker, each in Thin, Medium or Thick. The
toolbar shows the selected combination. Tap the already selected pen to open
the same palette; in document panels, drawing must be running for this
shortcut. Tapping Pen while the eraser is selected returns to the pen.
Preferences are shared between notebooks and documents.

**Notebooks.** Choose a name, paper size and paper style when creating a
notebook. The paper options scroll when the virtual keyboard leaves little
room; rotating the screen keeps the name and choices. The editor shows
**Page N of M**. Use **More → Go to page…** to jump to a page by its current
number. **Add page at end** appends a page; **More → Paper for this page**
changes the current page's background.

Back up KOReader's settings before using or upgrading the plugin. Sync is not
implemented.

**Export.** A notebook, an EPUB sheet, the page you are reading in a
fixed-layout document (with its page notes and any legacy ink), or every note
in the book (**Document notes**) can be written out as PDF, PNG or JPEG, to a
folder you choose. The entry is **Export…** — in the JustDraw menu while
reading, in a notebook's **More** menu, and in the library's per-notebook
actions. "Document notes" writes the notes on white, in reading order, each
page under a small header naming the book, the kind of note and where it was;
it does not reproduce the book's pages. If the set includes legacy ink you
are warned first, because its original zoom and screen size were never
stored. The proposed file name carries the page number when you are exporting
a single page, and you can change it. If the folder looks too full you are
asked before anything is written, and if an earlier export was interrupted
you are offered its leftovers to delete. The PDF is a raster: the ink is a
picture, not editable vectors. Exporting the book's own pages with the notes
on them, and exporting a page of a reflowable book directly, are not
implemented.

## Development

Run the test suite from the repository root:

```sh
luajit test.lua
```

## Origin and license

JustDraw began as a fork of
[Finger Ink](https://github.com/SMUsamaShah/fingerink.koplugin), which is
licensed under the GNU Affero General Public License, version 3. JustDraw is a
derivative work of it and is distributed under the same terms: **AGPL-3.0**.
The `LICENSE` file is the upstream one, byte for byte.

That is also KOReader's own license, so a plugin under these terms fits its
host exactly. In practice the network clause is inert here — nothing about
drawing on a page involves a user interacting with the plugin over a network —
but the copyleft is not: if you distribute JustDraw, or a modified version of
it, you have to offer the corresponding source under the AGPL as well.

Version 3 only, not "or later". Upstream's `LICENSE` carries no notice
choosing a version policy, so this repository does not claim to grant more
than it received.
