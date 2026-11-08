# Per-Mapping Channel Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-mapping (per-cell) merge mode to the routing matrix: with merge + channel N selected, input from ANY channel is forwarded with its channel byte rewritten to N; without merge, all existing behavior is unchanged.

**Architecture:** A new optional `merge: Int?` field on `Destination` (`nil` = today's filter mode). A pure kernel function `rewriteToChannel` performs the channel rewrite; the engine's fan-out path applies it only for merged destinations. RouterView's cell menu gains `channel` and `merge into` submenus and merged cells are labeled `M:N` with a distinct tint.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), SwiftPM, XCTest (`swift test`).

**Spec:** `docs/superpowers/specs/2026-11-08-per-mapping-channel-merge-design.md`

## Global Constraints

- macOS 13+ target; Swift 5.9; SwiftPM only — no new dependencies.
- Back-compat: existing `state.json` files (and old presets) must decode unchanged; missing `merge` key decodes as `nil`. New files must be readable by older builds (unknown key ignored).
- All existing tests must keep passing after each task; run full suite at the end of each task: `swift test`.
- Test runner: `swift test --filter <TestName>` for one test.
- Do not modify `ChannelFilter` semantics or `PopoverView.swift`.
- Do not run `scripts/build.sh` until the final task (it also bundles the app).

---

### Task 1: `Destination.merge` data model + Codable back-compat

**Files:**
- Modify: `Sources/MidiRouterCore/Model.swift:19-27` (Destination)
- Test: `Tests/MidiRouterCoreTests/ModelTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Destination(name:filter:merge:)` (init with `merge: Int? = nil` default), `Destination.merge: Int?`, `Destination.validateMerge(_ : Int) -> Int?` (validates 1...16, else nil). Later tasks call `Destination(name: "X", filter: .all, merge: n)`, `Destination(name: "X", filter: .channel(c))`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class ModelTests: XCTestCase` in `Tests/MidiRouterCoreTests/ModelTests.swift`:

```swift
    func testMergeCodableRoundTrip() throws {
        let route = Route(
            source: "Keys", enabled: true,
            destinations: [Destination(name: "UM-1", filter: .all, merge: 10)])
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(Route.self, from: data), route)
    }

    func testLegacyJSONWithoutMergeDecodesToNil() throws {
        // Shape of the JSON the app writes today: synthesized enum Codable
        // encodes `.channel(3)` as {"channel":{"_0":3}} and `.all` as {"all":{}}.
        let json = """
        {"source":"Keys","enabled":true,
         "destinations":[{"name":"UM-1","filter":{"channel":{"_0":3}}}]}
        """
        let route = try JSONDecoder().decode(Route.self, from: Data(json.utf8))
        XCTAssertNil(route.destinations[0].merge)
        XCTAssertEqual(route.destinations[0].filter, .channel(3))
    }

    func testValidateMerge() {
        XCTAssertNil(Destination.validateMerge(0))
        XCTAssertEqual(Destination.validateMerge(1), 1)
        XCTAssertEqual(Destination.validateMerge(16), 16)
        XCTAssertNil(Destination.validateMerge(17))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelTests`
Expected: FAIL with compile error "extra argument 'merge' in call" (and/or "has no member 'validateMerge'").

- [ ] **Step 3: Implement**

In `Sources/MidiRouterCore/Model.swift` replace lines 19-27 (the `Destination` struct) with:

```swift
public struct Destination: Codable, Equatable, Hashable {
    public var name: String
    public var filter: ChannelFilter
    public var merge: Int?

    public init(name: String, filter: ChannelFilter, merge: Int? = nil) {
        self.name = name
        self.filter = filter
        self.merge = merge.flatMap(Self.validateMerge)
    }

    public static func validateMerge(_ n: Int) -> Int? {
        (1...16).contains(n) ? n : nil
    }
}
```

Note: `merge` is an `Int?` property, so the synthesized `Codable` conformance uses `decodeIfPresent` — a missing `"merge"` key decodes as `nil` (back-compat) and older builds ignore it as an unknown key (forward-compat). No custom `Codable` code is needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS (all ModelTests green, including the three new ones).

- [ ] **Step 5: Run the full suite to verify no regression**

Run: `swift test`
Expected: PASS (all existing tests untouched by this change).

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/Model.swift Tests/MidiRouterCoreTests/ModelTests.swift
git commit -m "feat(model): optional per-destination merge channel field"
```

---

### Task 2: Pure kernel `rewriteToChannel`

**Files:**
- Modify: `Sources/MidiRouterCore/MidiData.swift` (appends after `applyFilter`, line 72)
- Test: `Tests/MidiRouterCoreTests/FilterTests.swift`

**Interfaces:**
- Consumes: `UInt8.isChannelStatus` (existing, `MidiData.swift:14`), `MIDIPacket` (existing).
- Produces: `public func rewriteToChannel(_ packet: MIDIPacket, _ channel: Int) -> MIDIPacket` — rewrite every channel-voice message's status low nibble to `channel - 1`; system messages/sysex untouched; `channel` assumed pre-validated 1...16. Task 3's engine calls `rewriteToChannel(kept, merge)`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class FilterTests: XCTestCase` in `Tests/MidiRouterCoreTests/FilterTests.swift`:

```swift
    func testRewriteAllVoiceMessagesToChannel() {
        XCTAssertEqual(rewriteToChannel(pkt([0x93, 0x3C, 0x40]), 1).bytes,
                       [0x90, 0x3C, 0x40])                    // note on ch4 → ch1
        XCTAssertEqual(rewriteToChannel(pkt([0x80, 0x3C, 0x00]), 16).bytes,
                       [0x8F, 0x3C, 0x00])                    // note off ch1 → ch16
        XCTAssertEqual(rewriteToChannel(pkt([0xB5, 0x07, 0x64]), 10).bytes,
                       [0xB9, 0x07, 0x64])                    // CC ch6 → ch10
        XCTAssertEqual(rewriteToChannel(pkt([0xDE, 0x11]), 3).bytes,
                       [0xD2, 0x11])                          // pitch bend ch15 → ch3
        XCTAssertEqual(rewriteToChannel(pkt([0xA1, 0x40, 0x7F]), 5).bytes,
                       [0xA4, 0x40, 0x7F])                    // poly AT ch2 → ch5
    }

    func testRewriteAlreadyOnTargetIsIdentity() {
        XCTAssertEqual(rewriteToChannel(pkt([0x99, 0x3C, 0x40]), 10).bytes,
                       [0x99, 0x3C, 0x40])                    // ch10 → ch10, untouched
    }

    func testRewriteLeavesSystemAndSysexUntouched() {
        XCTAssertEqual(rewriteToChannel(pkt([0xF8]), 7).bytes, [0xF8])            // clock
        XCTAssertEqual(rewriteToChannel(pkt([0xF2, 0x03, 0x00]), 7).bytes,
                       [0xF2, 0x03, 0x00])                    // song position
        XCTAssertEqual(rewriteToChannel(pkt([0xF0, 0x7E, 0x01, 0xF7]), 7).bytes,
                       [0xF0, 0x7E, 0x01, 0xF7])              // sysex
    }

    func testRewriteMixedPacket() {
        let mixed = pkt([0x90, 0x3C, 0x40,      // ch1 note on → ch7
                         0xB9, 0x07, 0x64,      // ch10 CC → ch7
                         0xF8])                 // clock → untouched
        XCTAssertEqual(rewriteToChannel(mixed, 7).bytes,
                       [0x96, 0x3C, 0x40, 0xB6, 0x07, 0x64, 0xF8])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FilterTests`
Expected: FAIL with compile error "cannot find 'rewriteToChannel' in scope".

- [ ] **Step 3: Implement**

Append at the end of `Sources/MidiRouterCore/MidiData.swift`:

```swift
/// Merge mode: rewrites the channel of every channel-voice message to
/// `channel` (1...16). System messages (0xF0+) carry no channel and pass
/// untouched. Data bytes are all < 0x80 so mapping only channel-status bytes
/// covers status-first wire messages without re-splitting.
public func rewriteToChannel(_ packet: MIDIPacket, _ channel: Int) -> MIDIPacket {
    let low = UInt8(channel - 1)
    let bytes = packet.bytes.map { b -> UInt8 in
        b.isChannelStatus ? (b & 0xF0) | low : b
    }
    return MIDIPacket(timestamp: packet.timestamp, bytes: bytes)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FilterTests`
Expected: PASS (all FilterTests green).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/MidiData.swift Tests/MidiRouterCoreTests/FilterTests.swift
git commit -m "feat(kernel): rewriteToChannel for merged routing"
```

---

### Task 3: Engine — `setCell(merge:)`, forward path rewrite, matrix data + labels

**Files:**
- Modify: `Sources/MidiRouterCore/MIDIEngine.swift:154-172` (forward path), `:204-231` (setCell, cellLabel), matrix-data section (`:181-200`)
- Test: `Tests/MidiRouterCoreTests/EngineForwardTests.swift`

**Interfaces:**
- Consumes: `Destination(name:filter:merge:)`, `Destination.merge`, `rewriteToChannel(_:channel:)` from Tasks 1-2.
- Produces:
  - `public func setCell(source: String, dest: String, filter: ChannelFilter?, merge: Int? = nil)` — default `merge: nil` keeps existing call sites valid; passing a filter with `merge: nil` clears merge; passing `filter: nil` (off) removes the destination entirely (clearing both).
  - `public func cellMerge(source: String, dest: String) -> Int?` — for UI.
  - `cellLabel` returns `"M:N"` for merged cells, else unchanged labels.

- [ ] **Step 1: Write the failing tests**

Append inside `final class EngineForwardTests: XCTestCase` in `Tests/MidiRouterCoreTests/EngineForwardTests.swift`:

```swift
    func testMergeCellRewritesAllInputToTargetChannel() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .all, merge: 10)])])
        io.fakeSend(source: "Keys", packets: [
            MIDIPacket(bytes: [0x95, 0x60, 0x60]),    // ch6 → rewritten to ch10 (0x99)
            MIDIPacket(bytes: [0x90, 0x3C, 0x40]),    // ch1 → rewritten to ch10 (0x99)
            MIDIPacket(bytes: [0xF8])])               // clock passes untouched
        XCTAssertEqual(io.receivedLog.count, 1)
        XCTAssertEqual(io.receivedLog[0].to, "UM-1")
        XCTAssertEqual(io.receivedLog[0].packets.flatMap(\.bytes),
                       [0x99, 0x60, 0x60, 0x99, 0x3C, 0x40, 0xF8])
        _ = engine
    }

    func testSetCellSetsAndClearsMergeAndUpdatesLabel() {
        let (io, engine) = boot([])
        engine.setCell(source: "Keys", dest: "UM-1", filter: .all, merge: 7)
        XCTAssertEqual(engine.cellLabel(source: "Keys", dest: "UM-1"), "M:7")
        XCTAssertEqual(engine.cellMerge(source: "Keys", dest: "UM-1"), 7)

        engine.setCell(source: "Keys", dest: "UM-1", filter: .channel(3))
        XCTAssertEqual(engine.cellLabel(source: "Keys", dest: "UM-1"), "ch 3")
        XCTAssertNil(engine.cellMerge(source: "Keys", dest: "UM-1"))

        engine.setCell(source: "Keys", dest: "UM-1", filter: .all, merge: 99) // invalid → ignored
        XCTAssertEqual(engine.cellMerge(source: "Keys", dest: "UM-1"), nil)
        XCTAssertEqual(engine.cellLabel(source: "Keys", dest: "UM-1"), "all")

        engine.setCell(source: "Keys", dest: "UM-1", filter: nil)
        XCTAssertEqual(engine.cellLabel(source: "Keys", dest: "UM-1"), "—")
        _ = io
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EngineForwardTests`
Expected: FAIL — compile error "'merge' in call ... has no parameter named 'merge'" (test 2) and wrong-bytes failure (test 1, since engine still sends through filter `.all` unchanged: actual bytes keep 0x95/0x90).

- [ ] **Step 3: Implement the forward path**

In `Sources/MidiRouterCore/MIDIEngine.swift` replace the loop body at lines 161-171 (`for dest in route.destinations ...`) with:

```swift
        for dest in route.destinations where connectedTargets.contains(dest.name) {
            let filter: ChannelFilter = dest.merge == nil ? dest.filter : .all
            var filtered: [MIDIPacket] = []
            filtered.reserveCapacity(packets.count)
            for pkt in packets {
                guard var kept = applyFilter(pkt, filter) else { continue }
                if let merge = dest.merge {
                    kept = rewriteToChannel(kept, merge)
                }
                filtered.append(kept)
            }
            guard !filtered.isEmpty else { continue }
            io.send(packets: filtered, to: dest.name)
        }
```

- [ ] **Step 4: Implement `setCell` + matrix data + label**

Replace `setCell` (lines 204-226) with:

```swift
    /// Cell edit: nil filter removes (clears both modes); `.all`/`.channel(n)`
    /// sets the route entry; merge != nil turns the cell into a merged mapping.
    public func setCell(source: String, dest: String, filter: ChannelFilter?, merge: Int? = nil) {
        mutateConfig { state in
            let routeIndex =
                state.currentRoutes.firstIndex(where: { $0.source == source })
            ?? {
                state.currentRoutes.append(Route(source: source, enabled: true))
                return state.currentRoutes.count - 1
            }()

            if let filter = filter {
                let merge = merge.flatMap(Destination.validateMerge)
                let destinations = state.currentRoutes[routeIndex].destinations
                if let destIndex = destinations.firstIndex(where: { $0.name == dest }) {
                    state.currentRoutes[routeIndex].destinations[destIndex].filter = filter
                    state.currentRoutes[routeIndex].destinations[destIndex].merge = merge
                } else {
                    state.currentRoutes[routeIndex].destinations
                        .append(Destination(name: dest, filter: filter, merge: merge))
                }
            } else if let destIndex = state.currentRoutes[routeIndex].destinations
                          .firstIndex(where: { $0.name == dest }) {
                state.currentRoutes[routeIndex].destinations.remove(at: destIndex)
            }
        }
    }
```

Add to the matrix-data section (after `matrixConnectedDestinations`, line 199):

```swift
    public func cellMerge(source: String, dest: String) -> Int? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.merge
    }
```

Replace `cellLabel` (lines 228-231) with:

```swift
    public func cellLabel(source: String, dest: String) -> String {
        let d = config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })
        if let merge = d?.merge { return "M:\(merge)" }
        return d?.filter.label ?? "—"
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter EngineForwardTests`
Expected: PASS (all EngineForwardTests green, including the pre-existing six tests).

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS (RouterView compiles — `setCell`'s new parameter has a default, existing call sites still valid).

- [ ] **Step 7: Commit**

```bash
git add Sources/MidiRouterCore/MIDIEngine.swift Tests/MidiRouterCoreTests/EngineForwardTests.swift
git commit -m "feat(engine): merged cell routing rewrites input to target channel"
```

---

### Task 4: RouterView UI — submenus, `M:N` label, merge tint, tooltip

**Files:**
- Modify: `Sources/MidiRouterApp/RouterView.swift:222-249` (MatrixCell body menu) and `:275-286` (cellColor)

**Interfaces:**
- Consumes: `engine.setCell(source:dest:filter:merge:)`, `engine.cellMerge(source:dest:)`, `engine.cellLabel(source:dest:)` from Task 3.
- Produces: UI only; core API untouched.

This task has no new unit tests (SwiftUI view). The deliverable is verified by compiling and manual use in step 5.

- [ ] **Step 1: Implement the menu**

In `Sources/MidiRouterApp/RouterView.swift` replace the `Menu { ... }` contents inside `MatrixCell.body`'s else branch (lines 223-235 — the four top-level menu pieces: `off`, `all channels`, `Divider`, `ForEach(1...16)`) with:

```swift
            Menu {
                Button("off") {
                    engine.setCell(source: source, dest: dest, filter: nil)
                }
                Button("all channels") {
                    engine.setCell(source: source, dest: dest, filter: .all)
                }
                Divider()
                Menu("channel") {
                    ForEach(1...16, id: \.self) { channel in
                        Button("ch \(channel)") {
                            engine.setCell(source: source, dest: dest,
                                           filter: .channel(channel))
                        }
                    }
                }
                Menu("merge into") {
                    ForEach(1...16, id: \.self) { channel in
                        Button("ch \(channel)") {
                            engine.setCell(source: source, dest: dest,
                                           filter: .all, merge: channel)
                        }
                    }
                }
            } label: {
```

- [ ] **Step 2: Implement mode text, merge tint, tooltip**

Still in `Sources/MidiRouterApp/RouterView.swift`, inside `MatrixCell`, above `private var cellColor`, add:

```swift
    private var isMerged: Bool {
        engine.cellMerge(source: source, dest: dest) != nil
    }
```

Replace `cellColor`'s last `return` lines (lines 282-285) with tinted variants for merged cells:

```swift
        if !engine.matrixConnectedDestinations.contains(dest) {
            return isMerged ? .indigo.opacity(0.35) : .gray.opacity(0.45)   // configured, device missing
        }
        return isMerged ? .indigo.opacity(0.7) : .accentColor.opacity(0.7)  // routed + connected
```

The tooltip currently uses `cellLabel` (`M:N` in merge mode). To show the full phrase, replace line 249:

```swift
            .help("\(source) → \(dest) · \(modeText)\(routeEnabled ? "" : " (route off)")")
```

…with `modeText` defined next to `isMerged`:

```swift
    private var modeText: String {
        if let merge = engine.cellMerge(source: source, dest: dest) {
            return "merge into ch \(merge)"
        }
        return engine.cellLabel(source: source, dest: dest)
    }
```

Notes: the label expression itself (`engine.cellLabel(...)` at line 237) already renders `M:N` with no view change needed. Selecting "all channels" (merge defaults to `nil`) clears a previous merge, so switching modes works with one click.

- [ ] **Step 3: Compile check**

Run: `swift build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS (all green).

- [ ] **Step 5: Manual verification via the app**

Run: `scripts/build.sh` — full test suite runs, then the app bundle is produced at `build/mac-midi-router.app`; open `build/mac-midi-router.app`.
Verify manually:

1. Cell menu shows `off`, `all channels`, and submenus `channel` / `merge into`.
2. Pick `merge into ▸ ch 10`: cell shows `M:10` with indigo tint.
3. Connect a test midi source sending on any channel: output device receives messages on channel 10.
4. Pick `channel ▸ ch 3`: cell shows `ch 3`, only ch-3 input passes.
5. Pick `all channels`: cell shows `all` (merge cleared).
6. Pick `off`: cell shows `—`.
7. Quit and relaunch the app: merge state is restored from `state.json`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterApp/RouterView.swift
git commit -m "feat(ui): per-cell merge submenu with M:N label and tint"
```

---

### Task 5: Sticky output header while scrolling vertically

**Files:**
- Modify: `Sources/MidiRouterApp/RouterView.swift` (RouterView body + matrixBody; MatrixCell untouched)

**Interfaces:**
- Consumes: nothing new from earlier tasks (UI-only; uses existing `destWidth`, `headerHeight`, `sourceWidth`, `outputHeaderRow`).
- Produces: UI only. A header band (`axisCorner + outputHeaderRow`) fixed above the vertical scroll; it scrolls horizontally in sync with the cell rows via a scroll-offset PreferenceKey so horizontal behavior is unchanged. Source labels stay sticky-left; vertical scrolling no longer moves the output header out of view.

No new unit tests (SwiftUI layout). Verified by `swift build`, `swift test` (44→46 tests must stay green), and manual use.

- [ ] **Step 1: Implement**

In `Sources/MidiRouterApp/RouterView.swift`:

1. Add to `RouterView`'s state (after `@State private var presetName = ""`):

```swift
    @State private var headerOffset: CGFloat = 0

    /// Tracks the horizontal scroll offset of the cell rows so the output
    /// header band (fixed above the vertical scroll) moves in lock-step.
    private struct HorizontalOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
```

2. Replace `RouterView.body`'s scroll section (the `ScrollView(.vertical) { HStack(alignment: .top, spacing: 0) { sourceColumn; Rectangle()...; ScrollView(.horizontal) { matrixBody } } }` plus its `.frame(maxHeight: .infinity)`) with:

```swift
            HStack(alignment: .top, spacing: 0) {
                axisCorner
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: 1, height: headerHeight)
                outputHeaderRow
                    .offset(x: headerOffset)
                    .clipped()
            }
            .frame(height: headerHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    sourceColumn
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))   // column boundary
                        .frame(width: 1)
                    ScrollView(.horizontal) {
                        matrixBody
                            .background(alignment: .leading) {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: HorizontalOffsetKey.self,
                                        value: geo.frame(in: .global).minX)
                                }
                            }
                    }
                }
            }
            .frame(maxHeight: .infinity)
```

3. Add the sync handler to `RouterView.body`'s content (e.g. after `.padding()`):

```swift
        .onPreferenceChange(HorizontalOffsetKey.self) { contentMinX in
            // Both bands start at the same X (sourceWidth + 1) and share the
            // global space's origin, so the delta alone drives the header.
            headerOffset = (sourceWidth + 1) - contentMinX
        }
```

4. Simplify `matrixBody` to rows only (remove the header line and VStack wrapper):

```swift
    private var matrixBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(engine.matrixSources, id: \.self) { source in
                cellRow(source: source)
                    .overlay(alignment: .bottom) { rowLine() }
            }
        }
    }
```

5. Remove `axisCorner` from `sourceColumn` (it moves to the fixed header band). `sourceColumn` becomes:

```swift
    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(engine.matrixSources, id: \.self) { source in
                sourceLabel(source)
                    .overlay(alignment: .bottom) { rowLine() }
            }
        }
        .frame(width: sourceWidth, alignment: .leading)
    }
```

Keep `axisCorner`, `outputHeaderRow`, `rowLine`, `columnLine` unchanged. Note `axisCorner`'s bottom `rowLine(strong:)` overlay stays (it now sits exactly above the first row's line under the band edge).

- [ ] **Step 2: Compile check**

Run: `swift build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Full suite**

Run: `swift test`
Expected: PASS (all green, no regression).

- [ ] **Step 4: Commit**

```bash
git add Sources/MidiRouterApp/RouterView.swift
git commit -m "feat(ui): sticky output header while scrolling vertically"
```
