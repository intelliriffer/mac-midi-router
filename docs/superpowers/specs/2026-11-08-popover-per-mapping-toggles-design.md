# Design: Per-Mapping Toggles in the Menu-Bar Popover

Date: 2026-11-08
Status: Approved design, pending implementation plan

## Problem

The menu-bar popover shows one switch per input source that mutes the whole
source route, plus a passive `2 →` count. Individual mappings
(source → destination pairs) can only be muted by disabling the entire
source; there is no per-mapping on/off.

## Goal

Per-mapping on/off toggles inside the popover, each mapping independently
mutable and persistent, with a minimal muted indication on the matrix cell.

## Behavior

1. **Core persistence (`Model.swift`):** `Destination` gains
   `public var enabled: Bool = true`.
   - Synthesized `Codable` requires keys for non-optionals, so add a custom
     `init(from:)` decoding with `decodeIfPresent(...) ?? true` — old
     `state.json` and old presets decode unchanged (missing key = on), and
     older builds ignore the new key when reading newer files.
   - The memberwise init keeps `enabled: Bool = true` default so existing
     call sites compile unchanged.
2. **Engine (`MIDIEngine.swift`):**
   - `midi(_:source:received:)` skips destinations with `enabled == false`
     (checked alongside the existing `connectedTargets` filter).
   - New `setMappingEnabled(source:dest:enabled:)` writes the flag on the
     existing `Destination` entry (no creation, no removal).
   - `setCell` resets `enabled = true` whenever a mapping is created or its
     filter/merge is re-set (a fresh mapping is active).
3. **Popover UI (`PopoverView.swift`):**
   - Each source row keeps its master route switch + name (unchanged).
   - The trailing `2 →` becomes a `Menu` labeled the same way that lists
     that source's destinations once: each entry is a `Toggle` bound to the
     mapping's `enabled` with text `name (label)` where label is the cached
     cell label style (`ch 3`, `M:7`, `all`).
   - Source with no destinations shows a single disabled entry
     "no mappings".
   - Master route switch semantics unchanged.
4. **Matrix cell indication (minimal, user-approved):**
   - A muted mapping's cell renders a light red tint instead of its normal
     tint (dimmed variants for missing-device remain, just red-tinted).
   - Tooltip gains a `(muted)` suffix. Label, menu, other colors unchanged.

## Interaction rules

- Route master switch off → nothing flows regardless of per-mapping flags
  (AND semantics: enabled_route && enabled_mapping).
- `off` in the matrix removes the mapping entirely (existing behavior);
  per-mapping mute is non-destructive and survives relaunch.
- Presets carry the flag (it rides `Destination` in the snapshot).

## Non-goals

- No new matrix menu entries, no label changes, no new core features.
- No popover listing for connected-but-unconfigured sources (unchanged).
