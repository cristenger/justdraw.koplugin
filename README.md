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
