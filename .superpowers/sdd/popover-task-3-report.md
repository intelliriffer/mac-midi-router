# Task 3 Report — Popover per-mapping toggle menu + muted cell tint

**Branch:** `feat/popover-mapping-toggles`
**Commit:** `b6a21af` — `feat(ui): per-mapping toggles in popover with muted cell tint`

## What was implemented

### 1. Popover per-mapping menu (`Sources/MidiRouterApp/PopoverView.swift`)
Inside `routeListContent`, the passive `Text("\(route.destinations.count) →")` counter was
replaced (verbatim per brief) with a `Menu` whose contents are:

- A disabled `Button("no mappings")` placeholder when the source route has no destinations.
- A `ForEach(route.destinations, id: \.name)` of `Toggle` items, each labeled
  `dest (cellLabel)` (e.g. `UM-2 Out (ch 3)`), bound to
  `engine.mappingEnabled(source:dest:) ?? false` and driving
  `engine.setMappingEnabled(source:dest:enabled:)`, decorated with
  `.toggleStyle(.switch)`, `.controlSize(.small)`, `.disabled(!route.enabled)`.
- The label is the same counter text with the same font/secondary style/opacity-when-disabled;
  the menu uses `.menuStyle(.borderlessButton)`, `.fixedSize()` and carries the
  `.help("Toggle mappings of \"\(route.source)\"")` tooltip.

Master route switch semantics are untouched (`Toggle("", isOn: … setRouteEnabled)` row is
unchanged).

### 2. Muted matrix cell tint + tooltip suffix (`Sources/MidiRouterApp/RouterView.swift`)
In `MatrixCell`:

- Added `isMuted` (`engine.mappingEnabled(source:dest:) == false`) above `cellColor`.
- `cellColor` gained the muted branch inserted after the `isEmpty` / route-disabled cases:
  red 0.25 when muted and destination device missing, red 0.45 when muted and connected.
  All pre-existing color cases are byte-identical to before.
- `.help(...)` tooltip extended with `\(isMuted ? " (muted)" : "")` suffix only.

No other matrix visuals, labels, or menu entries were changed. Diff is surgical: those two
files only (+39/−6).

## Verification

| Command | Result |
|---|---|
| `swift build` | `Build complete! (2.53 sec)` — BUILD SUCCEEDED |
| `swift test` | `Test Suite 'All tests' passed … Executed 52 tests, with 0 failures` (52/52 as expected) |
| `scripts/build.sh` | `All tests passed. App ready: build/mac-midi-router.app` (suite re-run inside, bundle created and codesigned) |

## Manual-check coverage (cannot be executed — no human present; these are what a QA pass would cover)

1. **Popover menu opens:** clicking a row's `2 →` opens a menu listing each of that
   source's mappings with a switch or checkmark item and mode label like
   `IAC Bus 1 (ch 3)` / `(all)` / `(merge into ch 9)` per `cellLabel`.
2. **Traffic semantics:** toggling a mapping off stops that source→dest traffic
   (verifiable via another app or the engine forward path); toggling back restores it;
   the per-mapping `Destination.enabled` state persists to `state.json` across relaunch.
3. **Muted cell indication:** a muted (but enabled route + connected device) cell shows
   the light-red tint (opacity 0.45, or 0.25 if device missing), and hover tooltip ends
   with `(muted)`.
4. **Master mute interaction:** with the source master switch off, the whole source's
   cells keep their gray route-off tint (takes priority), menu items are disabled, and
   the counter label shows its 0.4 opacity dimming.

## Files changed

- `Sources/MidiRouterApp/PopoverView.swift` — routeListContent row counter → mapping menu
- `Sources/MidiRouterApp/RouterView.swift` — `MatrixCell`: `isMuted`, muted branch in `cellColor`, tooltip suffix

## Self-review findings

- Diff matches the brief's Step 1 and Step 2 code verbatim (verified against `git show b6a21af`).
- None of the earlier `cellColor` cases were altered; the muted branch is inserted exactly
  per brief, so route-disabled gray still wins over muted red, and `isEmpty` wins over
  everything (brief specifies `mappingEnabled == false` also returns true for empty cells,
  but the `isEmpty` early return precedes it — per brief ordering, so behavior is as
  specified).
- Commit is exactly the brief's message; only the two listed files staged (untracked
  `build/` left alone).
- One benign note: brief's `ForEach` keyed by `\.name` collapses duplicate destination
  names within a route; the model already dedups routes (`duplicateDestinationNames`), so
  this is consistent and safe.
- No macOS-13 compilation issues: applied code compiles cleanly on the project's
  toolchain. One rendering caveat noted in "Concerns" below (not a compile or
  spec deviation).

## Concerns

- **DONE_WITH_CONCERNS — menu switch rendering:** on macOS 13, SwiftUI does not honor
  `.toggleStyle(.switch)`/`.controlSize(.small)` inside `Menu` content; toggles in a
  macOS menu render as standard checkmark-style menu items (state as a check). The brief
  explicitly anticipates this ("toggles-in-menu rendering quirks"); the applied code is
  verbatim per the brief, compiles, and behaves correctly as stateful items whose
  checkmarks reflect and set `mappingEnabled`. Changing to a non-menu popover would have
  violated "surgical diff + verbatim brief", so left as-is.
- Manual UI verification is not possible autonomously (listed above for a later human pass).

---

# Fix: flat per-mapping popover rows (user correction)

**Date:** 2026-11-09 · branch `feat/popover-mapping-toggles`

## User correction

The trailing `2 →` Menu introduced in b6a21af was rejected. Requirement: each mapping
is its own row in the popover list, each with its own switch — no menu, no grouping,
no per-source master switch rows.

## Change

- `PopoverView.swift`: added `MappingRow` row model + `mappingRows` (flatMap over
  routes × destinations).
- `routeListContent` rewritten: one `VStack` row per mapping — small switch Toggle
  bound via `engine.mappingEnabled` / `engine.setMappingEnabled`, text
  `"\(source) → \(dest)"`, trailing `engine.cellLabel(source:dest:)` in secondary
  style. Empty state text changed to "No mappings yet — open the Router."
- Removed only the per-source master Toggle rows and the trailing `2 →` Menu.
  Footer buttons, warning banner, body structure untouched.
- `routesWouldOverflow` now counts `mappingRows.count` (×40 + 16); `maxRoutesHeight`
  unchanged.Comments updated so they stay true.

## Verification

```
$ swift build
Build complete! (1.67 sec)

$ swift test
Test Suite 'All tests' passed ...
	Executed 52 tests, with 0 failures (0 unexpected) in 0.013 (0.017) seconds
```

52 executed / 0 failures — matches expectation.

## What manual UI checks would cover

1. With multiple routes/destinations: popover shows one row per mapping, in
   route → destination order; no per-source master switch; no `2 →` menu.
2. Toggling a row's switch only mutes that mapping (other mappings keep flowing);
   state persists across popover open/close and app restart.
3. Trailing cell labels (`ch 3`, `M:7`, `all`, `—`) match the Router grid cells.
4. Rows scroll (not overflow the screen) with many mappings; height cap respected.
5. Empty config shows "No mappings yet — open the Router." single line.
6. Router grid muted cells keep the muted tint and `(muted)` tooltip (unchanged).
7. Footer About/Router/Quit buttons and warning banner still work as before.

## Commit

`fix(ui): popover lists each mapping as its own switch row` (single commit, see SHA below)
