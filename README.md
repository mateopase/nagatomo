# nagatomo for norns

This repo is an installable norns mod. It exposes TouchOSC as a virtual `grid` and `arc` device layer while keeping compatibility with the existing `toga.tosc` layout.

## Install

In Maiden:

```text
;install <repo-url>
```

Then on norns:

1. Open `SYSTEM -> MODS`
2. Enable the installed mod
3. Restart norns

## Layout

Import the bundled layout from:

```text
assets/toga.tosc
```

TouchOSC UDP settings:

- host: your norns IP
- send port: `10111`
- receive port: `8002` or another free local port

## Features

- installs global `grid` and `arc` wrappers at mod load
- central TouchOSC OSC routing
- client history and active session tracking
- mod page with:
  - grid and arc policy
  - active clients
  - recent clients
  - reconnect / resend / light test actions

## Policies

- `Auto`: prefer physical hardware if present
- `TouchOSC Only`: use TouchOSC even when hardware is attached
- `Mirror Both`: drive hardware and TouchOSC together

## Notes

- the target protocol is the existing `toga.tosc` layout
- current TouchOSC is the supported target
- TouchOSC Mk1 is not a supported target
- the `reference/` folder contains upstream/reference material only

## Licensing

- copyright for the root project code: `Copyright (c) 2026 Mateo Paredes Sepulveda`
- this repo is distributed under `GPL-3.0-or-later`; see `LICENSE`
- see `NOTICE` for project authorship and bundled-asset attribution
- `assets/toga.tosc` is bundled from the original TOGA project by wangpy
