# Buttons and menus: what each one must do

Every control JustDraw puts on screen, what pressing it must do, and how that is
checked. **Auto** rows are cases in `buttons_native.lua`, which taps the real
widgets on a real KOReader, checks the effect, and requires the window stack to
come back exactly as it was. That last check is what "a menu stays stuck"
means in practice: a window left open under or over the toolbar. **Device**
rows need hardware or a person, and are the checklist for a release on a pen
device.

Rules every row also has to meet:

- Whatever a control opens can be closed from inside it (Close, Cancel or the
  title bar's ✕), and closing it leaves nothing behind.
- A modal never opens while a pen or finger is still down (`contact_active`).
- Drawing is never on without a visible Stop.
- Holding an icon names it (a toast), including when the icon is disabled.

## Side toolbar (PDF and other fixed layouts)

| Control | Must do | Checked |
|---|---|---|
| Draw / Stop | Turns drawing on/off; the label follows | Auto |
| Pen icon | With the eraser on: back to the pen. With the pen on and drawing: opens Pen settings | Auto |
| Eraser icon | Selects the eraser; the underline moves to it | Auto |
| Undo icon | Removes the last stroke; harmless with nothing to undo | Auto |
| More icon | Opens the JustDraw dialog below | Auto |
| ✕ (Hide toolbar) | Takes the toolbar down and turns drawing off | Auto |
| Hold on any icon | Toast with its name; the pen's says its style and width | Auto (handler), Device (gesture) |
| A finger stroke on the page | Ink on the page layer, in page units | Auto |
| A tap beside the toolbar, drawing off | Turns the page | Auto |

### More (reader)

| Entry | Must do | Checked |
|---|---|---|
| Document notes | Turns drawing off, opens the notes browser; its ✕ closes it | Auto |
| Pen settings | Opens the pen grid; Close closes it | Auto |
| Drawing refresh | Opens the intervals; a pick applies and closes | Auto |
| Input mode | Modes are disabled while drawing; with drawing off a pick applies and closes | Auto |
| Export… | Opens the export form; Cancel closes it | Auto |
| Toolbar side | Closes More, then moves the toolbar to the other side | Auto (was stuck: More stayed open under the rebuilt toolbar) |
| Close | Closes More | Auto |
| A tap outside More | Closes More | Auto |

### Pen settings

One row per style: the style's name (a heading), then **Thin · Medium ·
Thick**. The current pair carries a ✓. A pick applies both and closes. Marker
and the modern styles are disabled where there is no surface for them. Holding
a cell names style and width. Checked: Auto (pick, reset), unit specs (every
cell, refusals, stale dialogs).

### Main menu, Tools → JustDraw

| Entry | Must do | Checked |
|---|---|---|
| Show toolbar | Toggles the toolbar; the menu stays open | Auto |
| Start drawing | Turns drawing on with the toolbar up, closes the menu | Auto |
| Toolbar side → Left / Right | Moves the toolbar | Auto |
| Input mode → each | Applies (disabled while drawing) | Auto |
| Pen style / Pen width → each | Applies | Auto |
| Drawing refresh | Opens its chooser, closes the menu | Auto |
| Fast refresh while drawing | Toggles | Auto |
| Stylus diagnostics | Asks first; Cancel starts nothing | Auto; Device: Start logs for 60 s |
| Export… | Opens the export form | Auto |
| Document notes | Opens the browser | Auto |
| Notebooks | Opens the library | Auto |
| Page notes → Delete this page note / Delete all page notes | Asks; Cancel goes back to the menu and keeps the ink; Delete removes it | Auto |
| Clear legacy ink entries | Only with ink from older versions | Device |

## Drawing sheet (EPUB and other reflowable books)

| Control | Must do | Checked |
|---|---|---|
| Draw / Stop | Turns drawing on/off | Auto |
| ✕ | Puts the sheet away, drawing off; the page turns again | Auto |
| Pen / Eraser / Undo icons | As on the side toolbar, pressed with the pen | Auto |
| Document notes icon | Opens the browser | Auto |
| More icon | Same dialog as the reader's, plus Close sheet and Delete sheet (asks; Cancel keeps it) | Auto |
| 40 % · 70 % · 100 % | Steps the height and relabels | Auto |
| A pen stroke on the sheet | Ink on the sheet; Undo removes it | Auto |
| Hold on any icon | Toast with its name | Auto (handler) |
| Dragging the strip above the controls | Resizes | Device |
| Drawing sheet → Open sheet here / Close sheet | Reopens the same sheet here; closes it | Auto |
| Go to this sheet's page / Open a sheet here instead | Only after reading on with a sheet open | Device |

## Notebooks

### Library

| Control | Must do | Checked |
|---|---|---|
| New notebook | Name and paper form; Cancel closes; Create opens the notebook | Auto |
| A notebook's row | Opens it | Auto |
| Actions → Rename / Delete / Export… / Close | Each opens and closes | Auto |
| Previous / Next | Disabled with one screen of notebooks | Auto (state), Device (paging with many) |
| Title bar ✕ | Closes the library | Auto |
| Tools → Notebooks in the file browser | Opens the library with no book open | Device |

### Editor

| Control | Must do | Checked |
|---|---|---|
| Exit icon | Back to the library | Auto |
| Pen / Eraser icons | Select; the selected pen opens Pen settings | Auto |
| Undo icon | Disabled on an empty page; enabled after a stroke; takes it back | Auto |
| Previous / Next icons | Disabled at the ends; move one page | Auto |
| Add page icon | Adds a page at the end and goes there | Auto |
| More icon | Go to page…, Pen settings, Paper style, Export…, Rename, Drawing refresh, Input mode, Stylus diagnostics, Delete page, Delete notebook, Close: each opens and closes | Auto |
| More → Go to page… → 1 → Go | Goes to page 1 | Auto |
| More → Paper style → Squared | Applies to this page and closes | Auto |
| More → Delete page → Delete | Leaves one page | Auto |
| Hold on any icon | Toast with its name, disabled ones too | Auto (handler) |

## Document notes

### Browser

| Control | Must do | Checked |
|---|---|---|
| Filter / Filtered | Opens the filter menu; the label says Filtered while one applies | Auto |
| Filter → All notes, Drawing sheets, Page notes, Without location | Applies and closes | Auto |
| Filter → Page range… / Search annotation text… | Opens a form; Cancel closes it | Auto |
| Filter → Chapter… | Opens the chapter list, or says there is none | Auto |
| Filter → Sort… | Flips the order; the label flips with it | Auto |
| Filter → KOReader annotations | Closes the browser and opens KOReader's own list | Auto |
| Filter menu | No Close row: its title bar ✕ closes it | Auto |
| Select / Done selecting | Rows toggle ☑/☐ and the count follows | Auto |
| Export… | Menu of scopes, one page; a scope prepares, then opens the export form | Auto |
| Page counter (1 / N) | Asks for a list page; Cancel closes it | Auto |
| Previous / Next | Disabled on a single page | Auto (state), Device (paging) |
| A row | Opens the note | Auto |
| Title bar ✕ | Closes the browser | Auto |

### Note detail

| Control | Must do | Checked |
|---|---|---|
| Previous / Next note | Disabled at the ends, including a lone note | Auto (was on: `has_next` was `nil`, and a nil-enabled Button is enabled) |
| Previous / Next sheet | Steps through a note's sheets | Auto |
| Scale ↔ Original size, Rotate ↔ No rotation | Relabel in place | Auto |
| − / + | Zoom in place | Auto |
| View on page | Closes the browser, opens the sheet as a note at 40 % | Auto |
| Read from here | Closes the browser, goes to the text, puts up the note bar | Auto |
| Actions… → Add sheet at end | Opens a new sheet of the same note | Auto |
| Actions… → Organize sheets… | Disabled for one sheet; opens the reorder list for two | Auto |
| Actions… → Export this note… | Closes the note (frees its preview), opens the form; Cancel lands in the list | Auto |
| Actions… → Edit in document, Close | Present; Close goes back to the note | Auto (Close) |

### Note bar (after Read from here)

| Control | Must do | Checked |
|---|---|---|
| Show note / Go to note | Opens the sheet as a note; its ✕ (Hide note) brings the bar back | Auto |
| Document notes icon | Opens the browser | Auto |
| ✕ (Dismiss) | Takes the bar down; the page turns again | Auto |
| Hold on any icon | Toast with its name | Auto (handler) |

## Rotating the screen

| Situation | Must happen | Checked |
|---|---|---|
| Side toolbar with More open | More closes; the toolbar is rebuilt on screen; the page turns | Auto (was stuck: More stayed open under the rebuilt toolbar) |
| A drawing sheet open | The sheet and its header span the new width | Auto |
| Notes browser with Filter open | Filter closes; the list is relaid | Auto |
| Notebook editor with More open | The rail is relaid; the covered library waits to be uncovered | Auto |

## Not automated yet

- Organize sheets → move a sheet to another position.
- The export forms past Cancel: Folder…, Export, Replace.
- Everything that depends on the pen hardware: palm rejection, a tap with the
  pen on a button while the hand rests on the glass, the rear eraser.
