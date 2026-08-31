# JustDraw

JustDraw is an experimental [KOReader](https://github.com/koreader/koreader)
plugin for testing its new stylus support on e-ink devices. It is not built for
any particular brand or model. The plugin follows APIs that are still under
development, so expect rough edges and breaking changes.

## Requirements

- An e-ink device whose stylus input is exposed by KOReader.
- A current KOReader development build. Stable releases are not supported.

## Features

- Draw directly on document pages.
- Attach drawing sheets to reflowable documents.
- Create standalone notebooks, on blank, ruled, squared or dotted paper.
- Reject touch input while the stylus is drawing.

## Troubleshooting

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

Back up KOReader's settings before using or upgrading the plugin. Sync is not
implemented.

**Export.** A notebook, an EPUB sheet and the page you are reading in a
fixed-layout document can be written out as PDF, PNG or JPEG, to a folder you
choose. The entry is **Export…** — in the JustDraw menu while reading, in a
notebook's **More** menu, and in the library's per-notebook actions. The
proposed file name carries the page number when you are exporting a single
page, and you can change it. If the folder looks too full you are asked before
anything is written, and if an earlier export was interrupted you are offered
its leftovers to delete. The PDF is a raster: the ink is a picture, not
editable vectors. Exporting a whole EPUB by page, and exporting a page of a
reflowable book directly, are not implemented.

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
