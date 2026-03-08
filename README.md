# nagatomo

`nagatomo` is a norns mod based on [toga](https://github.com/wangpy/toga) and [toga-shim](https://github.com/blindorange/toga-norns/) that emulates `grid` and `arc` via a TouchOSC layout. `nagatomo` builds on the `toga` mods by patching `grid` and `arc` at a global level, meaning it should work with any script, regardless of how/when that script loads norns' system `grid` and `arc` libraries.

It keeps compatibility with the existing `toga` TouchOSC layout and OSC paths, but the mod's runtime is new and self-contained. So, you don't need the original `toga` library installed, but you can keep using the same TouchOSC layout.

## install

From Maiden:

```text
;install https://github.com/mateopase/nagatomo
```

Then on norns:

1. Open `system > mods`
2. Enable `nagatomo`
3. Restart norns

## TouchOSC setup

Import the bundled layout into TouchOSC. The `_modified.tosc` layout only contains visual changes from the base
`toga.tosc` file (also bundled in `assets/`)

```text
assets/toga_modified.tosc
```

Use a TouchOSC OSC connection with these settings:

- protocol: `udp`
- host: your norns IP address
- send port: `10111`
- receive port: `8002` or any other free local port on the TouchOSC device

After that, start the layout in TouchOSC. The mod will register a client as soon as norns receives a recognized message from the layout. Pressing the dark yellow button (green in the default `toga` layout)  works, but it is not the only way to establish the session.

## what the mod does

- installs global `grid` and `arc` wrappers when the mod loads
- routes TouchOSC OSC centrally instead of patching grid and arc separately
- mirrors script LED state back to TouchOSC
- can retry newly written LEDs once on `refresh()` to help recover from dropped UDP packets
- supports physical devices, TouchOSC-only mode, or both at once
- adds a mod page for status and recovery actions

This means normal scripts can keep using `grid.connect()` and `arc.connect()` without being modified for TouchOSC.

## mod menu

The `nagatomo` page in `system > mods` shows:

- grid policy
- arc policy
- retry writes on/off
- whether the current script has grid and arc callbacks bound
- active clients
- saved clients

Available actions:

- `resend state`: pushes the current grid and arc LED state to active clients again
- `disconnect all`: marks all active clients inactive for the current boot session
- `light test`: sends a test pattern to TouchOSC and any mirrored hardware

The `retry writes` toggle controls whether `nagatomo` sends newly written LEDs one extra time on the next `refresh()`. It is off by default.

## policies

- `auto`: prefer physical hardware when present, otherwise use TouchOSC
- `touchosc only`: use TouchOSC even if physical hardware is attached
- `mirror both`: send output to both TouchOSC and physical hardware

## notes and limitations

- the TouchOSC wire protocol still uses the `toga` OSC addresses
- TouchOSC Mk1 is not a supported target
- the virtual TouchOSC devices are exposed on port `1` in norns
- TouchOSC feedback still runs over UDP, so LED recovery is best-effort rather than acknowledged delivery

## license

- license: `GPL-3.0-or-later`
- `assets/toga.tosc` is bundled from the original TOGA project by wangpy
