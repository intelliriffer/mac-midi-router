# mac-midi-router

A macOS menu-bar app that routes MIDI between ports like a patch-matrix:
pick an **input** port, route it into any number of **output** ports, with
per-destination channel filtering, automatic reconnection, and named presets.

## Features

- **Matrix routing** — every input port (rows) × every output port (column).
  Click a cell to assign it: `off`, `all channels`, or a single channel `1…16`.
- **1 → many, many → 1** — one input can feed several outputs; several inputs
  merge into one output with no drops (CoreMIDI handles the interleave).
- **Per-cell channel filter** — route all channels, or just one (1–16).
  Channel-less messages (sysex, clock, MTC, active sensing) always pass, even
  on single-channel routes.
- **Name-based, reorder-proof** — routes are bound by port *name*, never by
  port index or uniqueID, so re-numeration order can never break your setup.
- **Hot-plug safe** — unplug a keyboard mid-session; the route stays
  configured and reconnects automatically when the port returns. Cold start
  and hot reconnect run through the same code path.
- **Presets** — the current routing auto-saves (debounced JSON); save/load/
  delete named presets from the router window. Loading keeps your current
  on/off switches.
- **Quick control** — menu-bar popover with per-route on/off switches and
  one click to the full matrix window.
- **Self-loop guard** — routing a port into itself is a feedback loop; the
  diagonal is shown dead in the matrix.
- **Quit, properly** — popover Quit button (⌘Q works too).

## Screenshot

The router window is a live matrix: green dot = port connected, gray = still
waiting for the device to come back; every colored cell is a route.

## Build

Requirements: macOS 13+, Xcode / Swift 5.9+ toolchain.

```sh
./scripts/build.sh          # one command: full test suite, then build/mac-midi-router.app
open build/mac-midi-router.app
```

For development without packaging: `swift run` (menu-bar app in place).

Regenerate the app icon after changing `scripts/make-icon.swift`:

```sh
swift scripts/make-icon.swift Resources/AppIcon.icns
```

## Architecture (in one paragraph)

`MidiRouterCore` holds everything testable: the route model, the pure
`applyFilter` packet-filtering kernel, the preset store, and
`MIDIEngine` — which owns a single `MIDIIO` abstraction. `MIDIIO` has two
implementations: `FakeMIDIIO` (dictionary-backed test double driving the
whole engine without hardware) and `RealMIDIIO` (CoreMIDI: one client,
one input port per bound source, one output port per bound destination,
classic `MIDIPacketList` API, notification-driven reconnect).
`MidiRouterApp` is the SwiftUI/AppKit menu-bar shell plus a debounced
JSON autosave in `~/Library/Application Support/mac-midi-router/state.json`.

## Manual smoke test

`docs/manual-smoke.md` is the human checklist (routing, channel filters,
hot-plug, sysex multi-packet traffic, preset lifecycle, relaunch restore).

## Status

Alpha (0.1.0): core routing, filters, presets, reconnect, and UI are in place
and covered by 35 unit tests; live-gear checklist (items 12–14) still
recommends a manual pass with your own controllers.

## License

MIT — see [LICENSE](LICENSE).
