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
2. A small toolbar appears at the side of the screen: **Draw**, then icons for
   **Pen · Eraser · Undo · More · Hide** (the ✕). While you are drawing, **Draw**
   reads **Stop**. The selected tool is underlined; hold any icon to see its
   name, and hold the pen to see which style and width it has.
3. Write. Touch is ignored while the stylus is on the glass.

**In a PDF or other fixed-layout document,** your ink goes on the current page
and stays with it: turn the page and you get that page's own layer. Manage them
under **JustDraw → Page notes**, which offers *Delete this page note* and
*Delete all page notes*.

**In an EPUB,** open a panel first: **JustDraw → Drawing sheet → Open sheet
here**. The sheet is anchored to the passage you were reading. Its controls sit
across its top, above the paper, so neither hand rests on them:
**Draw** and a ✕ that puts the sheet away, with the current pen between them,
then icons for **Pen · Eraser · Edit · Undo · Redo · More**. **More** starts
with *Document notes* and *Sheet height* (**40 % · 70 % · 100 %**); tap or drag
the strip above the icons to resize it directly. **Edit** offers the same
lasso, shapes and paste as a notebook (see [Editing ink](#editing-ink)).

Because a sheet belongs to a passage and not to a page, you can keep reading
with one open. When the page behind it changes, the sheet's top edge says which
page it belongs to and it stops accepting ink. **JustDraw → Drawing sheet** then
offers both ways out: **Go to this sheet's page**, or **Open a sheet here
instead**.

Other useful entries in the same menu: **Toolbar side** (left or right, for the
reader's toolbar; a sheet keeps its controls on top), **Input mode**
(*Automatic*, *Stylus* or *Finger*) and **Drawing refresh**.

## Notebooks

1. **Tools → Notebooks** from the file browser, or **JustDraw → Notebooks**
   while reading.
2. The library is a grid of cards: folders first, then notebooks, each with a
   picture of its current page, its title and its number of pages. **New
   notebook** asks for a name and a paper style (*Blank*, *Ruled*, *Narrow
   ruled*, *Squared*, *Dotted*, *Checklist*). The page takes the shape of the
   paper under the editor's controls on the screen it is created on, so it
   reaches both edges; on a Kindle Scribe in portrait that is 158 × 179 mm, and
   an export keeps that size. Every page added later has the same shape.
3. The editor fills the screen. A line across the top shows the notebook's
   title, **Page N of M** and the current pen; under it one row of nine icons
   holds **Exit notebook · Pen · Eraser · Edit · Undo · Redo · Previous page ·
   Next page · More**. On the last page, **Next page** adds a new one. Hold an
   icon to see its name. The page takes the rest of the screen, so no control
   sits under a resting hand.
4. **More** offers *Go to page…*, *Add page at end*, *Paper style* (for this
   page), *Export…*, *Send…* (with LocalSend, see below), *Rename*, *Delete
   page*, *Delete notebook* and the shared pen and refresh settings.

### The library

- **Folders** are one level deep. **New folder** makes one; tap a folder to open
  it, and the first card inside is **Back**. Deleting a folder puts its
  notebooks back in the library — it never deletes them.
- **Sort** orders notebooks by *Recently changed*, *Oldest first*, *Title A–Z*
  or *Title Z–A*, and remembers your choice.
- **Hold a card** for its actions: *Rename*, *Move…*, *Duplicate*, *Export…*,
  *Delete* (and *Retry preview* if its picture could not be made).
- **Select** turns taps into choices. Then **Move**, **Duplicate**, **Export**,
  **Delete** (and **Send**) act on everything chosen; actions that do not fit
  the screen are under **More**. A confirmation lists exactly what will be
  deleted, and the result says what worked and what did not, by name.
- A **duplicate** is copied in the background, in small steps, and appears when
  it is complete. Closing its progress box cancels it.
- Pictures are made one at a time, only for the cards on screen, and kept as
  files under KOReader's cache; a changed page gets a new picture.

## Editing ink

In a notebook or on a drawing sheet, **Edit** offers three tools. The lasso
and a shape stay selected until you pick another tool; paste places once and
goes back to the tool it interrupted. Undo and redo cover every edit, one step
each.

- **Lasso.** Draw a loop around ink. A stroke with at least half its length
  inside is selected, and a dashed frame shows the selection. Drag the selection with the pen to move it; the
  small menu beside it offers **Copy**, **Cut** and **Delete**, and ✕ lets go.
- **Shapes…** Pick a *Line*, *Arrow*, *Square*, *Rectangle*, *Circle*,
  *Ellipse* or *Triangle*, a size (*Small*, *Medium*, *Large*) and, for
  shapes that have one, an angle. Then touch the page: the shape follows the
  pen and is drawn, in the current pen, where you lift it. Shapes are placed,
  never recognised from a scribble.
- **Paste.** After *Copy* or *Cut*, touch the page to place a copy; it follows
  the pen and is written where you lift it. Paste works across notebooks and
  sheets.

The stylus's eraser end always erases, and ends any selection first.

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
it in two, and the surviving pieces stay exactly where they were. In notebooks
and on drawing sheets **Undo** and **Redo** step back and forth through strokes,
erasing and edits; on page notes over a PDF, **Undo** removes your last stroke.

## Export

Anything you draw can be written out as PDF, PNG or JPEG, into a folder you
choose. The entry is always **Export…** — in the JustDraw menu while reading, in
a notebook's **More** menu, in the library (hold a card, or select several),
and in the document notes list.

**Notebooks can also be exported as Xournal++ (`.xopp`)**, which keeps every
stroke as an editable vector. Before exporting you are told what Xournal++
approximates: the highlighter is darker there (50 % instead of 20 %), textured
strokes lose their grain, the legacy marker becomes a light-gray pen, strokes
get round ends, narrow ruled and checklist paper become ruled, and paper
spacing is Xournal++'s own. For a faithful picture, use PDF.

Depending on where you start it, you can export the page you are on, one sheet,
one notebook or one page of it, or every note in the book. For PDFs the notes
list also offers **Annotated pages as images…** and **Complete document as
images…**; for EPUB, **Complete EPUB with notes appendix…**.

Output is a picture of your ink, not editable vectors. If the folder looks too
full you are asked before anything is written, and leftovers from an interrupted
export are offered for deletion.

## Sending with LocalSend

If the [LocalSend plugin](https://github.com/kaikozlov/localsend.koplugin) is
installed and working, **Send…** appears in a notebook's **More** menu and as
**Send** in the library's selection mode. Choose *PDF* or *Xournal++*; JustDraw
exports first, then opens LocalSend's own device picker with the file (or,
for several notebooks, a folder holding them). From there LocalSend shows the
transfer and its result — JustDraw only says that LocalSend is open. If one
export fails, nothing is sent until you retry or cancel. Without LocalSend,
there is no Send button.

Files prepared for sending are kept under KOReader's cache in
`justdraw-send`, and removed only after a day, by a later session, and only the
ones JustDraw itself wrote.

## Language

JustDraw's own texts follow KOReader's language. Spanish is included; any other
language shows KOReader's translation where it has one, and English otherwise.

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
widgets, SQLite and PDF code. They live in `justdraw.koplugin/tests/`. Any
Linux build of KOReader v2026.07 or newer works; the release tarball needs no
compiling:

```sh
curl -LO https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz
tar xf koreader-linux-x86_64-v2026.07.1.tar.xz
cd lib/koreader
```

From there, `tests/buttons_native.lua` presses every button and menu entry of
the side toolbar, a drawing sheet, the notebook library and the notebook
editor, and checks what each one did and that nothing it opened stays open. It
needs `sample.pdf` and `juliet.epub` from
[koreader/test-data](https://github.com/koreader/test-data):

```sh
SDL_VIDEODRIVER=dummy JUSTDRAW_PDF=/path/to/sample.pdf JUSTDRAW_EPUB=/path/to/juliet.epub \
  ./luajit /path/to/justdraw.koplugin/tests/buttons_native.lua
```

`JUSTDRAW_SHOTS=1` also saves a picture of every dialog it opens. The same
check runs in CI. What each button is expected to do is listed in
`justdraw.koplugin/tests/buttons_plan.md`.

To try the plugin by hand in the emulator, link it into a data directory of
its own and start the reader there:

```sh
mkdir -p /tmp/ko-home/plugins
ln -s /path/to/justdraw.koplugin /tmp/ko-home/plugins/
KO_HOME=/tmp/ko-home ./reader.lua /path/to/sample.pdf
```

The mouse is a finger. The **Automatic** input mode draws with it; pick
**Stylus** only with a graphics tablet.

## Origin and license

JustDraw began as a fork of
[Finger Ink](https://github.com/SMUsamaShah/fingerink.koplugin) and is
distributed under the same terms: **AGPL-3.0**, version 3 only, not "or later".
The `LICENSE` file is the upstream one, byte for byte. That is also KOReader's
own license.

The copyleft applies: if you distribute JustDraw, or a modified version of it,
you have to offer the corresponding source under the AGPL as well.
