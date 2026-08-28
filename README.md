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
- Create standalone notebooks.
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

Back up KOReader's settings before using or upgrading the plugin. Sync and
export are not implemented.

## Development

Run the test suite from the repository root:

```sh
luajit test.lua
```

## Origin and license

JustDraw began as a fork of
[Finger Ink](https://github.com/SMUsamaShah/fingerink.koplugin). The upstream
project does not currently declare a software license. Until that is resolved,
this repository cannot be offered under the MIT License as a whole.
