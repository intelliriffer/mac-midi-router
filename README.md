# mac-midi-router

A macOS menu-bar app that routes MIDI between ports like a patch-matrix:
pick an **input** port, route it into any number of **output** ports, with
per-destination channel filtering, per-mapping merge, per-mapping message-type
filters, automatic reconnection, and named presets.

## Features

- **Matrix routing** — every input port (rows) × every output port (column).
  Click a cell to assign it: `off`, `all channels`, or a single channel `1…16`.
- **1 → many, many → 1** — one input can feed several outputs; several inputs
  merge into one output with no drops (CoreMIDI handles the interleave).
- **Per-cell channel filter** — route all channels, or just one (1–16).
- **Per-mapping merge** — `merge into ch N` takes *any* incoming channel,
  rewrites it to channel N and sends it to the output. Merged cells show `M:N`
  and paint indigo; regular filtered cells show `ch N`.
- **Per-mapping mute** — every mapped cell has a leading status dot
  (green = active, red = muted); clicking the dot mutes/unmutes that single
  mapping without deleting its configuration. Muted cells show red text on a
  very light red wash. The menu-bar popover lists each mapping as its own row
  (`switch · source · type → target`) with the same mute switches.
- **Per-mapping message-type filters** — the cell menu has a `pass:` section
  with 8 toggles: Note, CC, Program Change, Pitch Bend, Aftertouch, Clock,
  Sysex, System Common (all on by default). Unchecking a group drops it for
  that mapping only — e.g. a *sync lane* cell: keep Clock (+ Sysex for MMC,
  System Common for MTC) and silence everything else. Each mapped cell also
  shows a small ⏱ glyph — green while clock passes, red while clock is
  suppressed — and clicking the glyph toggles clock instantly. Replaces the
  old "sysex + system always pass" rule.
- **Launch at Login** — checkbox in the popover (System Settings → Login
  Items aware); the popover auto-hides on outside click.
- **Name-based, reorder-proof** — routes are bound by port *name*, never by
  port index or uniqueID, so re-numeration order can never break your setup.
- **Hot-plug safe** — unplug a keyboard mid-session; the route stays
  configured and reconnects automatically when the port returns. Cold start
  and hot reconnect run through the same code path.
- **Presets** — the current routing auto-saves (debounced JSON); save/load/
  delete named presets from the router window. Loading keeps your current
  on/off switches. Mute flags, merge targets, and message-type filters ride
  along in snapshots (older app versions load new files safely).
- **Quick control** — menu-bar popover: per-mapping rows with switches
  (switch · source · type → target), Launch at Login checkbox, Router/About/
  Quit.
- **Self-loop guard** — routing a port into itself is a feedback loop; the
  diagonal is shown dead in the matrix (slash).
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

Alpha (0.1.1): core routing, per-mapping merge, per-mapping mute, per-mapping
message-type filters, presets, reconnect, launch-at-login, and the full UI are
in place and covered by 64 unit tests (including the clock-only sync-lane
regression). A manual pass with your own controllers is still recommended for
live-gear checks.

## Design documents

Feature specs and implementation plans live under `docs/superpowers/`:

- `specs/2026-11-04-mac-midi-router-design.md` — original architecture
- `specs/2026-11-08-per-mapping-channel-merge-design.md` — merge mode
- `specs/2026-11-08-popover-per-mapping-toggles-design.md` — popover redesign
- `specs/2026-11-09-message-type-filters-design.md` — message-type filters

## License

MIT — see [LICENSE](LICENSE).
