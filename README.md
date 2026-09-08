# JustDraw

JustDraw is an **experimental** plugin for
[KOReader](https://github.com/koreader/koreader). It lets you write and draw on
an e-ink reader that has a stylus.

Please treat "experimental" literally. The KOReader stylus features it builds on
are still under development, and the plugin has only been tried on a couple of
real devices. Pen handling, palm rejection and screen refresh differ a lot from
one e-ink reader to another, so your results may not match what is described
here.

**Feedback is very welcome.** If something behaves oddly on your device, a short
description of what happened plus a log is the most useful thing you can send.
See [Reporting a problem](#reporting-a-problem).

## What it does

JustDraw gives you three places to write, and one place to find them all again.

- **Notebooks** — standalone drawing books that belong to no document.
- **Page notes** — a transparent layer over one page of a fixed-layout document
  (PDF, DjVu, comics). The ink is stored in the page's own coordinates, so it
  stays where you put it under zoom and pan.
- **Drawing sheets** — a panel over a reflowable book (EPUB). A sheet is
  anchored to a passage rather than to a page number, so it stays with the text
  when the font or margins change.
- **Document notes** — one list of everything in the book you are reading: your
  sheets and page notes, plus KOReader's own highlights, bookmarks and typed
  notes. From here you can read, filter, export and jump back to any of them.

You do not choose between page notes and sheets: the plugin picks one from the
document you have open.

## Requirements

- An e-ink reader whose stylus KOReader can see.
- A current KOReader **development** build. Stable releases are not supported.

Stylus drawing, page notes and drawing sheets need KOReader v2026.07 or newer.
On older development builds only the plugin's original mode works: drawing
directly on the screen with a finger, saved alongside the book's settings. That
older ink is still shown and exported on newer builds, but nothing is added to
it any more; **Clear all legacy ink** removes it.

## Install

Copy the `justdraw.koplugin` folder into KOReader's `plugins` directory and
restart KOReader. The final path should be:

```text
koreader/plugins/justdraw.koplugin/main.lua
```

Back up KOReader's settings before using or upgrading. There is no sync:
notebooks and notes stay on the device that made them.

## Finding the plugin

- **While reading:** the **Tools** tab → **JustDraw**.
- **In the file browser:** the **Tools** tab → **Notebooks**.

Everything below hangs off those two entries. If you would rather not go through
the menu, KOReader's Gesture Manager lists the plugin's actions under
*JustDraw: toggle drawing*, *toggle eraser*, *undo stroke*, *toggle toolbar*,
*open notebooks*, *browse document notes* and *open/close drawing sheet*.

## Drawing over a document

1. Open a book, then **Tools → JustDraw → Start drawing**. (**Show toolbar**
   brings up the toolbar without starting.)
2. A small toolbar appears at the side of the screen:
   **Draw · Pen · Eraser · Undo · More · Hide**. While you are drawing, **Draw**
   reads **Stop**.
3. Write. Touch is ignored while the stylus is on the glass.

**In a PDF or other fixed-layout document,** your ink goes on the current page
and stays with it: turn the page and you get that page's own layer. Manage them
under **JustDraw → Page notes**, which offers *Delete this page note* and
*Delete all page notes*.

**In an EPUB,** open a panel first: **JustDraw → Drawing sheet → Open sheet
here**. The sheet is anchored to the passage you were reading. Drag its top edge
to resize it; close it with the toolbar's **More → Close sheet**.

Because a sheet belongs to a passage and not to a page, you can keep reading
with one open. When the page behind it changes, the sheet's top edge says which
page it belongs to and it stops accepting ink. **JustDraw → Drawing sheet** then
offers both ways out: **Go to this sheet's page**, or **Open a sheet here
instead**.

Other useful entries in the same menu: **Toolbar side** (left or right),
**Input mode** (*Automatic*, *Stylus* or *Finger*) and **Drawing refresh**.

## Notebooks

1. **Tools → Notebooks** from the file browser, or **JustDraw → Notebooks**
   while reading.
2. **New notebook** asks for a name, a paper size (*A5 portrait*,
   *Letter portrait*, *A5 landscape*) and a paper style (*Blank*, *Ruled*,
   *Squared*, *Dotted*).
3. The editor fills the screen. Its rail holds **Exit notebook · Pen · Eraser ·
   Undo** at the top and **Previous page · Next page · Add page at end · More**
   at the bottom. The page itself shows **Page N of M**.
4. **More** offers *Go to page…*, *Paper for this page*, *Rename notebook*,
   *Delete page*, *Delete notebook*, *Export…*, *Rail side* and the shared pen
   and refresh settings.
5. Back in the library, each notebook's **Actions** button offers *Rename*,
   *Delete* and *Export…*.

## Document notes

1. **JustDraw → Document notes**, or the toolbar's **More → Document notes**.
2. The list gathers everything in this book — drawing sheets, page notes, older
   ink, and KOReader's own notes, highlights and bookmarks. Each row names its
   page and its kind.
3. **Filter** narrows by type, chapter, page range or annotation text, and sorts
   by document order or last change. **Select** marks rows. **Export…** writes
   all notes, the filtered results or just your selection.
4. Tap a row to open it. You can zoom and pan, and step through the list with
   **Previous note** / **Next note**.
5. From a drawing, **View on page** puts that sheet back over its place in the
   book with drawing off and the panel at 40% height, so you can read around it.
   Press **Draw** to add to it. **Read from here** goes to the same place with
   no panel at all.
6. After **View on page**, a small bar stays with the note: **Show note** (or
   **Go to note**, if you have since read on), **Notes** to return to the list,
   and **Dismiss** to put the bar away. The note is still reachable from
   **JustDraw → Drawing sheet** for the rest of the session.

A drawing note can hold several sheets. From its detail view, **Actions… → Add
sheet at end** extends it and **Organize sheets…** reorders them.

## Pens and erasing

Six styles, each in **Thin**, **Medium** or **Thick**: **Ink pen**,
**Graphite**, **Marker**, **Round ink**, **Highlighter** and **Textured
graphite**. The highlighter is black at 20% opacity and leaves the text under it
readable. Your choice is shared between notebooks and documents.

Open **More → Pen settings** to change style and width together, or tap the
**Pen** button when it is already selected. Tapping **Pen** while the eraser is
active switches back to the pen.

The eraser removes ink where you drag it. Crossing the middle of a stroke cuts
it in two, and the surviving pieces stay exactly where they were. **Undo**
removes your last stroke.

## Export

Anything you draw can be written out as PDF, PNG or JPEG, into a folder you
choose. The entry is always **Export…** — in the JustDraw menu while reading, in
a notebook's **More** menu, in the library's per-notebook **Actions**, and in
the document notes list.

Depending on where you start it, you can export the page you are on, one sheet,
one notebook or one page of it, or every note in the book. For PDFs the notes
list also offers **Annotated pages as images…** and **Complete document as
images…**; for EPUB, **Complete EPUB with notes appendix…**.

Output is a picture of your ink, not editable vectors. If the folder looks too
full you are asked before anything is written, and leftovers from an interrupted
export are offered for deletion.

## Troubleshooting

**Ink trails behind the pen.** Open **More → Drawing refresh** and pick a
shorter interval — 20, 33, 50, 75, 100, 150 or 200 milliseconds between
grayscale screen updates. 100 ms is the default. Try 75 or 50 first, and go back
up if strokes start to look erratic.

**Palm marks, or a pen that erases on its own.** Some devices report a rejected
touch with the same code KOReader uses for the stylus eraser, so a resting hand
can reach the same path as a pen. JustDraw trusts only the digitizer's own input
slot; a stylus-shaped touch anywhere else is treated as a palm and does nothing.

**A button flashes but does nothing.** Actions are refused while a contact is
still on the glass. Lift the pen *and* your hand, then try again.

**Strokes with corners you did not draw.** When the device cannot keep up with
the pen, the kernel throws input away. JustDraw ends the stroke there rather
than joining it to what comes next, so you lose the rest of one stroke instead
of getting a line across the page.

**"Turn off continuous scrolling / reflow / page optimisation to draw page
notes".** Page notes work only in single-page mode on an unmodified page. With
those settings on, what is on screen is no longer the page the notes were drawn
on, so they are hidden rather than shown in the wrong place. Nothing is lost —
turn the setting off and they come back.

### Reporting a problem

**JustDraw → Stylus diagnostics** records a short trace of the plugin's pen
decisions into KOReader's log, then stops on its own. If you also switch
KOReader's own debug logging on, switch it off again once you have reproduced
the problem: it records all raw input and grows very quickly.

Traces contain coordinates only — never the name or the contents of a document
or a notebook. Stylus behaviour is device behaviour, so if something here does
not match what your reader does, the log is the useful thing to attach.

## Development

Run the test suite from the repository root:

```sh
luajit test.lua
```

Some checks need a real KOReader build instead, because they exercise the actual
widgets, SQLite and PDF code. They live in `justdraw.koplugin/tests/`.

## Origin and license

JustDraw began as a fork of
[Finger Ink](https://github.com/SMUsamaShah/fingerink.koplugin) and is
distributed under the same terms: **AGPL-3.0**, version 3 only, not "or later".
The `LICENSE` file is the upstream one, byte for byte. That is also KOReader's
own license.

The copyleft applies: if you distribute JustDraw, or a modified version of it,
you have to offer the corresponding source under the AGPL as well.
