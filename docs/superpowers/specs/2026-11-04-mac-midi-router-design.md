# mac-midi-router — Design Spec

Date: 2026-11-04
Status: Approved (pending final review)

## Summary

A macOS menu-bar app (Swift/SwiftUI) that routes MIDI from input ports to output
ports. Each route maps one source port to one or more destination ports with a
per-destination channel filter (all channels or a single channel). Routing is
configured by port **name** so enumeration order never breaks it, reconnects
automatically when gear is unplugged/replugged, and can be stored in named
presets.

## Requirements (from requirements.md)

1. Route one MIDI input port to multiple output ports.
2. Per-route filter: a single channel or all channels.
3. Automatic handling of disconnects/reconnects.
4. Port-name-based mapping — port-number reordering must not affect connections.
5. Persist routing; save/load/delete named presets.
6. One input may drive many outputs (same as 1, at the destination level).
7. A destination port accepts merged input from multiple input sources.

## Decisions made with the user

| Decision | Choice |
|---|---|
| Form factor | Menu bar app: popover for quick route on/off + "Open Router"; full router window for the matrix |
| Stack | Pure Swift + SwiftUI, CoreMIDI directly, no virtual MIDI ports created by the app (A) |
| System messages | Always forward channel-less messages (clock, sysex, MTC…), even on single-channel routes (A); future extension may add suppression |

## Architecture

```
┌──────────────────────── mac-midi-router.app ─────────────────────────────┐
│  MenuBarController           MainWindow (Router)         PresetStore    │
│  NSStatusItem + popover      Sources×Destinations grid   JSON on disk  │
│  quick route toggles         channel picker per cell                   │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ observes / commands
                    ┌───────────▼────────────┐
                    │      MIDIEngine        │  ← only component that
                    │  1 MIDIClient          │     touches CoreMIDI
                    │  1 input port / source │
                    │  1 output port / dest  │
                    │  read callback:        │
                    │  filter → fan-out      │
                    └────────┬───────────────┘
                             │ CoreMIDI
                    [hardware ports / other apps' virtual ports]
```

### Components (single responsibility each)

- **`MIDIEngine`** — owns the `MIDIClient`. Creates one `MIDIInputPort` per
  bound source and one `MIDIOutputPort` per bound destination. Read callback:
  look up routes for that source, apply the per-destination channel filter,
  write the (possibly filtered) packet list to each destination. Also owns
  reconnection via CoreMIDI client notifications and `reconcileBindings()`.
  Exposes `@Published` observable state consumed by the UI on the main actor.
- **`Route`** — the user-visible data unit: `{ source name, enabled,
  destinations: [{ dest name, channel: .all | .channel(1...16) }] }`. The
  `enabled` flag is the popover's quick on/off.
- **`PresetStore`** — Codable structs serialized to a single JSON file holding
  *current routing state* (auto-saved, debounced) plus named presets. Purely
  data-level; `MIDIEngine` applies whatever configuration it is given, so
  presets require no MIDI knowledge.
- **`MenuBarController` / SwiftUI views** — presentation only. Popover: per-route
  enable toggles + "Open Router". Window: matrix grid; each cell's click opens a
  picker: **off / all / ch 1…16**.

**Merging (req. 7)** falls out naturally: two routes pointing at the same
destination port both write into that one `MIDIOutputPort`; CoreMIDI serializes
writes on its read thread, so interleaving is safe with no special merge node.

**Name-based mapping (req. 4)**: routes store endpoint *names*, never uniqueIDs.
UniqueIDs exist only as session glue inside the engine's bindings.

## Routing and filter semantics

Read-callback flow:

1. CoreMIDI delivers a packet list from source S.
2. Find routes whose source matches S's name and that are enabled.
3. For each destination entry, run the pure function
   `applyFilter(packetList, filter) -> packetList?` (nil when nothing survives).
4. Write the packet list to that destination's output port. A failed write
   (e.g. device vanished mid-operation) is dropped silently; the notification
   path marks the endpoint disconnected. No error spam.

Filter rules:

- Channel voice messages (`0x80`–`0xEF`): kept if the filter is `.all` or the
  status nibble's low 4 bits equal the route's channel.
- Channel-less messages (system common/realtime, sysex) pass through even when
  the filter is a single channel. A future per-route "suppress system messages"
  toggle extends `applyFilter` without changing its signature.

Fan-out: one source's route contains N destination entries; each receives its
own filtered copy (one write per destination; CoreMIDI copies per write).

Threading: the callback only reads immutable configuration and writes to
existing ports — no locks, no shared mutable state. UI ↔ engine communication
runs on the main actor. A lock-free queue can be added later without
semantics changes if profiling demands it.

## Hotplug and reconnection

Register a `CoreMIDINotificationProc` for `kMIDINotificationMessageAdded` /
`Removed` (covers devices, entities, and endpoints).

Invariant: **configuration is separate from bindings.** Bindings (endpoint
uniqueID + generated port) are always derivable from configuration plus the
current CoreMIDI endpoint list.

Single reconciler — `reconcileBindings()`, called on:

- app launch,
- every endpoint added/removed notification,
- preset load / route configuration change.

Behavior:

1. Snapshot the current CoreMIDI endpoints by name (sources, destinations).
2. For every configured source/destination not currently bound, look it up by
   exact name.
3. Found → create the port, (for sources) connect input port to the endpoint,
   resume routing. Not found → remain "disconnected", wait for the next
   notification.

Notes:

- On endpoint removal: drop the binding, keep the route entry, show it as
  "disconnected" in the UI. Cold start and hot reconnect are the same code path.
- Same-name-different-device (physically swapped identical interface) reconnects
  by design since identity is the name; the UI's connected state makes it
  visible.
- Duplicate endpoint names: first match wins, and the UI shows a ⚠️. No
  disambiguation heuristics.

## Persistence

File: `~/Library/Application Support/mac-midi-router/state.json`

```json
{
  "currentRoutes": [
    { "source": "Keystation 88", "enabled": true,
      "destinations": [
        { "dest": "UM-1", "channel": 1 },
        { "dest": "IAC",  "channel": "all" }
      ] }
  ],
  "presets": {
    "gig setup": [ { "source": "Keystation 88", "enabled": true,
      "destinations": [ { "dest": "UM-1", "channel": 1 } ] } ]
  }
}
```

- Current routing state **auto-saves** (debounced) on every change; launch
  restores the last state.
- **Presets are explicit**: Save-as-name (snapshot current flattened routes),
  Load (replace currentRoutes, keep enabled flags), Delete.
- Presets store names only — never endpoint IDs.
- A corrupt file is logged and the app starts empty rather than crashing.

## UI details

- **Popover**: one row per route (source name + destination count) with a
  toggle, and an "Open Router" button. Status icon shows activity when any
  route is enabled.
- **Router window**: rows = seen + configured-but-missing sources, columns =
  destinations. Cell click → picker (**off / all / ch 1…16**) — the only way to
  create a routing. The matrix shows connected vs waiting-for-device states.

## Testing plan (must-implement, not optional)

The MIDI I/O layer sits behind a thin protocol (`MIDIIO`) so the exact engine
logic is testable with a fake client, no MIDI hardware required.

1. **Pure unit tests (XCTest)**
   - `applyFilter`: every channel-message status nibble, `.all` vs
     `.channel(n)` matching/non-matching, sysex/clock/start-stop/active-sensing
     pass-through on single-channel filters, multi-packet lists with mixed
     channels, filter-drop-returns-nil behavior.
   - `Route` / state: Codable round-trips (encode→decode→encode equality),
     corrupt-JSON recovery path, missing-fields defaults.
   - Name matching / `reconcileBindings` against a fake endpoint list: cold
     start binding, add-notification binding, remove-notification unbinding,
     re-add rebind, same-name duplicates (first-match + ⚠️), configured-but-absent
     stays disconnected.
2. **Integration (fake MIDIIO)**: full engine path — one source → multiple
   filtered destinations; two sources → one destination merge; enabled toggle
   gating; reconnect exercise (remove fake endpoint, re-add, verify routing
   resumes); preset load applies configuration through the same reconcile path.
3. **Manual smoke checklist** (run with real gear/loopbacks before release):
   hot-unplug/re-plug both a source and a destination, relaunch with gear
   present/absent, preset save→load→delete cycles, duplicate-name warning
   display.

## Out of scope (recorded for possible future work)

- The app creating virtual MIDI ports (test-only virtual endpoints are fine).
- Per-route system-message suppression.
- Channel remapping (e.g. ch 5 → ch 3), per-channel multi-select.
- Latency calibration, MIDI monitoring window.
