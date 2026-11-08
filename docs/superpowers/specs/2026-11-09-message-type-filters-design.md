# Design: Per-Mapping Message-Type Filters

Date: 2026-11-09
Status: Approved design, pending implementation plan

## Problem

System messages currently pass through every enabled mapping regardless of the
mapping's channel selection ("sysex + system always pass" rule). Users need
per-mapping control over which message categories a mapping forwards.

## Goal

Each mapping (matrix cell) offers 8 on/off toggles — Note, CC, Program Change,
Pitch Bend, Aftertouch, Clock, Sysex, System Common — default all enabled,
shown directly in the cell's main menu. Channel filtering (`ch N` / `merge
into ch N`) stays orthogonal.

## Behavior

1. Each `Destination` carries `suppressed: Set<MessageType>` (empty = all
   pass). Toggling a type off adds it to the set.
2. A message passes only if BOTH the channel filter passes AND its type group
   is not suppressed. This **replaces** the old always-pass rule for sysex and
   system messages.
3. Suppressing all 8 groups makes the mapping forward nothing (muted-
   equivalent) without touching the mute flag; the popover/dot mute switch
   remains independent.
4. Type toggles: independent of mute; visible even while muted (menu still
   reachable), though nothing forwards while muted.

## Data model (`Model.swift`)

```swift
public enum MessageType: String, Codable, CaseIterable, Hashable {
    case note, cc, programChange, pitchBend, aftertouch, clock, sysex, systemCommon
}
```

`Destination` gains `public var suppressed: Set<MessageType>` (default `[]`).
The custom `init(from:)` decodes it with `decodeIfPresent ?? []` (old files =
all pass). Synthesized `encode` writes it always; older builds ignore the
unknown key.

## Kernel (`MidiData.swift`)

```swift
public func messageType(_ status: UInt8) -> MessageType
```

- 0x80, 0x90 → `.note`
- 0xA0, 0xD0 → `.aftertouch`     // poly + channel pressure
- 0xB0 → `.cc`
- 0xC0 → `.programChange`
- 0xE0 → `.pitchBend`
- 0xF0 → `.sysex`
- 0xF1–0xF6 → `.systemCommon`
- 0xF8–0xFF → `.clock`

Type-suppression is applied inside the existing per-message keep decision:
`applyFilter(pkt, filter, suppressed:)` drops messages whose group is
suppressed (channel filtering logic unchanged). Data bytes never trigger
suppression on their own (only status bytes decide).

## Engine (`MIDIEngine.swift`)

- Forward path passes `dest.suppressed` into `applyFilter`.
- New `setMappingTypes(source:dest:suppressed:)` — replaces the set in the
  existing destination entry (no creation); invalid enum values are impossible
  by type design.
- `mappingTypes(source:dest:) -> Set<MessageType>?` — UI accessor (nil when the
  mapping does not exist).

## UI (`RouterView.swift`)

Cell menu layout:

```
off
all channels
channel ▸ ch 1..16
merge into ▸ ch 1..16
────
pass:
  Note / CC / Program Change / Pitch Bend /
  Aftertouch / Clock / Sysex / System Common   (checkmark toggles)
```

- Implemented with SwiftUI `Section("pass")` of 8 `Toggle`s (macOS menus
  render checkmark items).
- Cell label unchanged; tooltip gains `(no <type>, <type>)` listing suppressed
  groups when non-empty.
- Selecting `off` clears the whole destination (suppressed set dies with it);
  channel/merge selection preserves the suppressed set.

## Tests

- Kernel: classification of every status class; suppression of each group;
  channel filter × suppression matrix (e.g. `.channel(3)` + no clock ⇒ 0xF8
  dropped); data bytes unaffected; empty set = old behavior.
- Engine: `setMappingTypes` writes/ unreachable source/dest no-op; a cell with
  clock suppressed sends no 0xF8; note suppression drops 0x90 but passes 0xF8
  when clock not suppressed; off clears everything.
- Model: legacy JSON (no `suppressed`) decodes to empty; roundtrip with a
  non-empty set; presets preserve the set.

## Non-goals

- No per-type routing to different destinations (single per-mapping set).
- No popover-row editing of types (cell menu only).
- No finer refinement of groups (velocity/note splits) in this iteration.
