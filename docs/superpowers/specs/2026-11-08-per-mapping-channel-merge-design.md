# Design: Per-Mapping Channel Merge

Date: 2026-11-08
Status: Approved design, pending implementation plan

## Problem

Today a routing-matrix cell (source port → destination port) offers `off`,
`all channels`, or a channel filter `ch 1-16`. The filter is input-only: it
*passes* messages arriving on that channel but never rewrites them, so MIDI
data arriving on several channels cannot be concentrated onto one fixed
output channel — a common need when feeding hardware modules or single-
channel instruments.

## Goal

Add a per-mapping (per-cell) **merge** mode: when a specific channel 1–16 is
selected in merge mode, input arriving on **any** channel is routed to the
destination with every message's channel rewritten to the selected target
channel. Without merge, everything behaves exactly as before.

## Behavior

A cell's menu becomes:

```
off                       ← clears the mapping (unchanged)
all channels              ← filter mode, passes everything (unchanged)
channel       ▸ ch 1..16  ← filter mode (unchanged): only input on ch N passes
merge into    ▸ ch 1..16  ← NEW: all input passes; channel rewritten to N
```

Rules:

- Merge is **per mapping**. Other cells interleave at the destination as
  today (CoreMIDI merges concurrent sends).
- Messages already on channel N pass unchanged (rewrite is a no-op).
- System messages (0xF0–0xFF, including sysex and clock) carry no channel;
  they pass through unchanged in all modes.
- A cell holds exactly one mode. Selecting any channel in `merge into`
  replaces a previously set filter, and vice versa. `off` clears both.
- No global switch; no extra state beyond the cell itself.

## UI (`RouterView.swift`)

`MatrixCell.body`'s `Menu` gains two entries with submenus:
`channel` (today's options) and `merge into` (the 16 target channels).

Visual state:

- Filter mode cell label unchanged: `ch 10`.
- Merge mode cell label: `→ 10`, with a distinct color accent; the cell
  remains calm and readable.
- Tooltip text: `merge into ch 10` vs `ch 10`.

## Data model (`Model.swift`)

`ChannelFilter` is unchanged — it keeps the meaning "which input passes".

`Destination` gains one optional field:

```swift
struct Destination: Codable, Equatable, Hashable {
    let name: String
    var filter: ChannelFilter
    var merge: Int?   // nil = filter mode (today); 1...16 = merge-to-channel
}
```

- Back-compat: `merge` is optional, so existing `state.json` and old preset
  snapshots decode unchanged (missing key → `nil`), and the synthesized
  `Codable` decode of `Optional` fields tolerates the key's absence. Older
  app builds reading newer state files ignore the unknown key. No migration.
- `merge` values outside 1...16 are invalid; validated to 1...16 at set time
  (same convention as `ChannelFilter.channel`).

## Pure kernel (`MidiData.swift`)

New pure function:

```swift
func rewriteToChannel(packet: MIDIPacket, channel: Int) -> MIDIPacket
```

- Channel-voice messages (status 0x80–0xEF): status = (status & 0xF0) | (N−1).
- System messages (status ≥ 0xF0): returned untouched.
- Deterministic; only invoked in merge mode.

## Engine (`MIDIEngine.swift`)

Forward path, per destination, per packet:

- `merge == nil` → today's path: `applyFilter(pkt, dest.filter)`.
- `merge = N`    → `applyFilter(pkt, .all)` (passes voice + system messages)
  then `rewriteToChannel(pkt, N)`, then send.

`setCell(source:dest:filter:merge:)` gains a `merge` parameter (default
`nil` so existing call sites remain valid). `off` clears both filter and
merge. `cellLabel` renders `→ N` for merged cells.

## Tests (`Tests/MidiRouterCoreTests`)

- Kernel: rewrite from channels 1–16 onto N for note-on/note-off/CC/
  aftertouch/pitch bend; sysex and system messages untouched; messages
  already on N unchanged.
- Engine (fake IO): a merged cell forwards input from a foreign channel
  with channel bytes rewritten; a filter-mode cell regression test
  confirms unchanged behavior.
- Model: legacy JSON without `merge` decodes to `nil` (no crash), roundtrip
  encode/decode with merge set, presets preserve the merge flag.
- `setCell`/`cellLabel`: merge set and cleared; label `→ N` vs `ch N`.

## Non-goals

- No velocity, note, or CC filtering in this iteration (cell menu may later
  evolve into a mini editor; the `merge: Int?` field is designed to extend
  without migration).
- No global merge mode.
- No UI in PopoverView (it only toggles whole routes today).
