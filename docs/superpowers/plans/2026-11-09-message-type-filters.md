# Per-Mapping Message-Type Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-mapping message-category toggles (Note/CC/Program Change/Pitch Bend/Aftertouch/Clock/Sysex/System Common — default all pass), shown as a "pass:" section directly in the cell menu; suppression replaces the old "sysex+system always pass" rule.

**Architecture:** New `MessageType` enum; `Destination.suppressed: Set<MessageType>` (tolerant decode, missing = empty); `applyFilter` gains a suppression parameter driven by a status-byte classifier; engine forwards the destination's set; SwiftUI menu section with 8 toggles.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), SwiftPM, XCTest (`swift test`).

**Spec:** `docs/superpowers/specs/2026-11-09-message-type-filters-design.md`

## Global Constraints

- macOS 13+; Swift 5.9; SwiftPM only — no new dependencies.
- Back-compat: old `state.json` and presets decode unchanged (missing `suppressed` = empty set); new files readable by older builds.
- Channel filter semantics for channel-voice messages unchanged; suppression only extends what may drop.
- All existing tests keep passing after each task; run full suite: `swift test`. Focused: `swift test --filter <Name>`.
- Do not run `scripts/build.sh` until the final task.
- Only the matrix cell menu changes visually; popover rows unchanged.

---

### Task 1: `MessageType` enum + `Destination.suppressed` model

**Files:**
- Modify: `Sources/MidiRouterCore/Model.swift` (add enum; extend Destination)
- Test: `Tests/MidiRouterCoreTests/ModelTests.swift`

**Interfaces:**
- Produces: `MessageType` (String, Codable, CaseIterable, Hashable), `Destination.suppressed: Set<MessageType>` (default `[]`), init param `suppressed: Set<MessageType> = []`, tolerant decode (missing key → `[]`).

- [ ] **Step 1: Write the failing tests**

Append inside `final class ModelTests: XCTestCase`:

```swift
    func testSuppressedRoundTrip() throws {
        var d = Destination(name: "UM-1", filter: .all, merge: 7)
        XCTAssertTrue(d.suppressed.isEmpty)
        d.suppressed = [.clock, .sysex]
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(Destination.self, from: data), d)
    }

    func testLegacyJSONWithoutSuppressedDecodesEmpty() throws {
        let json = """
        {"name":"UM-1","filter":{"all":{}},"merge":10,"enabled":false}
        """
        let d = try JSONDecoder().decode(Destination.self, from: Data(json.utf8))
        XCTAssertTrue(d.suppressed.isEmpty)
        XCTAssertFalse(d.enabled)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ModelTests`
Expected: FAIL — compile error: `MessageType` unknown / `Destination` has no member `suppressed`.

- [ ] **Step 3: Implement**

In `Sources/MidiRouterCore/Model.swift`, above `Destination`:

```swift
public enum MessageType: String, Codable, CaseIterable, Hashable {
    case note, cc, programChange, pitchBend, aftertouch, clock, sysex, systemCommon
}
```

Extend `Destination` (add the field, init default, custom decode line):

```swift
public var suppressed: Set<MessageType>
```

- init gains `suppressed: Set<MessageType> = []` (last parameter), assigns it.
- In `init(from:)`: `suppressed = try c.decodeIfPresent(Set<MessageType>.self, forKey: .suppressed) ?? []`
- Add `case suppressed` to `CodingKeys`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ModelTests` — expected: PASS (all ModelTests green).

- [ ] **Step 5: Full suite**

Run: `swift test` — expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/Model.swift Tests/MidiRouterCoreTests/ModelTests.swift
git commit -m "feat(model): per-mapping suppressed message-type set"
```

---

### Task 2: Kernel — `messageType` classifier + `applyFilter` suppression

**Files:**
- Modify: `Sources/MidiRouterCore/MidiData.swift` (classifier + applyFilter signature)
- Test: `Tests/MidiRouterCoreTests/FilterTests.swift`

**Interfaces:**
- Consumes: `MessageType` (Task 1).
- Produces: `public func messageType(_ status: UInt8) -> MessageType`; `public func applyFilter(_ packet: MIDIPacket, _ filter: ChannelFilter, suppressed: Set<MessageType> = []) -> MIDIPacket?` — default `[]` keeps existing call sites valid. Engine (Task 3) calls `applyFilter(pkt, filter, suppressed: dest.suppressed)`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class FilterTests: XCTestCase`:

```swift
    func testMessageClassification() {
        XCTAssertEqual(messageType(0x80), .note)          // note off
        XCTAssertEqual(messageType(0x91), .note)          // note on
        XCTAssertEqual(messageType(0xA5), .aftertouch)    // poly aftertouch
        XCTAssertEqual(messageType(0xB3), .cc)            // CC
        XCTAssertEqual(messageType(0xC0), .programChange)
        XCTAssertEqual(messageType(0xDF), .aftertouch)    // channel pressure
        XCTAssertEqual(messageType(0xE7), .pitchBend)
        XCTAssertEqual(messageType(0xF0), .sysex)
        XCTAssertEqual(messageType(0xF2), .systemCommon)  // song position
        XCTAssertEqual(messageType(0xF8), .clock)         // clock
        XCTAssertEqual(messageType(0xFE), .clock)         // active sensing
    }

    func testSuppressionDropsSuppressedGroups() {
        let s: Set<MessageType> = [.note, .clock]
        XCTAssertNil(applyFilter(pkt([0x90, 0x3C, 0x40]), .all, suppressed: s))
        XCTAssertNil(applyFilter(pkt([0xF8]), .all, suppressed: s))
        XCTAssertEqual(applyFilter(pkt([0xB5, 0x07, 0x64]), .all, suppressed: s),
                       pkt([0xB5, 0x07, 0x64]))                          // CC survives
        XCTAssertEqual(applyFilter(pkt([0xF8]), .all, suppressed: []), pkt([0xF8]))
    }

    func testSuppressionCombinesWithChannelFilter() {
        let s: Set<MessageType> = [.clock]
        // .channel(2) keeps only ch2 notes; clock suppressed regardless.
        XCTAssertNil(applyFilter(pkt([0xF8, 0x90, 0x3C, 0x40]), .channel(2), suppressed: s))
        XCTAssertEqual(applyFilter(pkt([0xF8, 0x91, 0x3C, 0x40]), .channel(2), suppressed: s),
                       pkt([0x91, 0x3C, 0x40]))
        // Channel-voice `all` filter with everything else passing.
        XCTAssertEqual(applyFilter(pkt([0xC1, 0x00, 0xF8]), .all, suppressed: [.clock]),
                       pkt([0xC1, 0x00]))                     // program change kept, clock gone
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FilterTests`
Expected: FAIL — compile error: cannot find `messageType` / `applyFilter` argument mismatch.

- [ ] **Step 3: Implement**

Append to `Sources/MidiRouterCore/MidiData.swift` (and modify `applyFilter`):

```swift
/// The message-category of a status byte; used for per-mapping suppression.
public func messageType(_ status: UInt8) -> MessageType {
    switch status {
    case 0x80...0x9F: return .note
    case 0xA0...0xAF, 0xD0...0xDF: return .aftertouch
    case 0xB0...0xBF: return .cc
    case 0xC0...0xCF: return .programChange
    case 0xE0...0xEF: return .pitchBend
    case 0xF0: return .sysex
    case 0xF1...0xF7: return .systemCommon
    default: return .clock                    // 0xF8...0xFF real-time
    }
}
```

Change `applyFilter` to accept `suppressed` and drop suppressed groups:

```swift
public func applyFilter(_ packet: MIDIPacket, _ filter: ChannelFilter,
                        suppressed: Set<MessageType> = []) -> MIDIPacket? {
    if case .all = filter, suppressed.isEmpty { return packet }
    var out: [UInt8] = []
    for msg in splitMessages(packet.bytes)
          where messageKept(msg[0], filter) && !suppressed.contains(messageType(msg[0])) {
        out.append(contentsOf: msg)
    }
    return out.isEmpty ? nil : MIDIPacket(timestamp: packet.timestamp, bytes: out)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FilterTests` — expected: PASS.

- [ ] **Step 5: Full suite**

Run: `swift test` — expected: PASS (default `suppressed: []` keeps engine/call sites green).

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/MidiData.swift Tests/MidiRouterCoreTests/FilterTests.swift
git commit -m "feat(kernel): message-type classification and suppression"
```

---

### Task 3: Engine — forward unt suppressed set + accessors

**Files:**
- Modify: `Sources/MidiRouterCore/MIDIEngine.swift`
- Test: `Tests/MidiRouterCoreTests/EngineForwardTests.swift`

**Interfaces:**
- Consumes: Task 1-2 APIs.
- Produces: `public func mappingTypes(source: String, dest: String) -> Set<MessageType>?` (nil when the mapping does not exist); `public func setMappingTypes(source: String, dest: String, suppressed: Set<MessageType>)` (no-op if the mapping does not exist); forward path now: `applyFilter(pkt, filter, suppressed: dest.suppressed)`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class EngineForwardTests: XCTestCase`:

```swift
    func testSuppressedClockDoesNotForward() {
        var route = Route(source: "Keys", enabled: true,
                          destinations: [Destination(name: "UM-1", filter: .all)])
        route.destinations[0].suppressed = [.clock]
        let (io, engine) = boot([route])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0xF8])])
        XCTAssertTrue(io.receivedLog.isEmpty)
        XCTAssertEqual(engine.mappingTypes(source: "Keys", dest: "UM-1"), [.clock])
        _ = engine
    }

    func testTypeTogglesInMatrixCombinations() {
        var route = Route(source: "Keys", enabled: true,
                          destinations: [Destination(name: "UM-1", filter: .all)])
        route.destinations[0].suppressed = [.clock]
        let (io, engine) = boot([route])
        io.fakeSend(source: "Keys", packets: [
            MIDIPacket(bytes: [0xF8]),          // suppressed
            MIDIPacket(bytes: [0x91, 0x3C, 0x40])])   // note passes
        XCTAssertEqual(io.receivedLog.count, 1)
        XCTAssertEqual(io.receivedLog.last!.packets.flatMap(\.bytes), [0x91, 0x3C, 0x40])

        engine.setMappingTypes(source: "Keys", dest: "UM-1", suppressed: [.note])
        XCTAssertEqual(engine.mappingTypes(source: "Keys", dest: "UM-1"), [.note])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x91, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.dropFirst(1).count == 0)   // note now suppressed too
        _ = engine
    }

    func testSetMappingTypesNoOpForMissingMapping() {
        let (io, engine) = boot([])
        engine.setMappingTypes(source: "Keys", dest: "UM-1", suppressed: [.clock])
        XCTAssertNil(engine.mappingTypes(source: "Keys", dest: "UM-1"))
        _ = io
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter EngineForwardTests`
Expected: FAIL — compile: no member `setMappingTypes` / `mappingTypes`.

- [ ] **Step 3: Implement**

In `Sources/MidiRouterCore/MIDIEngine.swift`:

1. Forward path: `guard var kept = applyFilter(pkt, filter, suppressed: dest.suppressed) else { continue }`.
2. Cell-ops section (next to `mappingEnabled`):

```swift
    public func mappingTypes(source: String, dest: String) -> Set<MessageType>? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.suppressed
    }

    public func setMappingTypes(source: String, dest: String, suppressed: Set<MessageType>) {
        mutateConfig { state in
            guard let routeIndex = state.currentRoutes.firstIndex(where: { $0.source == source }),
                  let destIndex = state.currentRoutes[routeIndex].destinations
                      .firstIndex(where: { $0.name == dest }) else { return }
            state.currentRoutes[routeIndex].destinations[destIndex].suppressed = suppressed
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter EngineForwardTests` — expected: PASS.

- [ ] **Step 5: Full suite**

Run: `swift test` — expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/MIDIEngine.swift Tests/MidiRouterCoreTests/EngineForwardTests.swift
git commit -m "feat(engine): forward path honors per-mapping suppressed types"
```

---

### Task 4: RouterView — `pass:` section of 8 toggles + tooltip

**Files:**
- Modify: `Sources/MidiRouterApp/RouterView.swift` (MatrixCell menu + tooltip)

**Interfaces:**
- Consumes: `engine.mappingTypes(source:dest:)`, `engine.setMappingTypes(source:dest:suppressed:)`, `MessageType` from Tasks 1-3.
- Produces: UI only. No new tests (SwiftUI); verified by compile + full suite + app build.

- [ ] **Step 1: Implement the menu section**

In `MatrixCell.body`'s `Menu`, after the `merge into` submenu (before the label), add:

```swift
                Divider()
                Section("pass") {
                    ForEach(Array(MessageType.allCases), id: \.self) { type in
                        Toggle(title(for: type), isOn: Binding(
                            get: {
                                !(engine.mappingTypes(source: source, dest: dest)?
                                    .contains(type) ?? false)
                            },
                            set: { pass in
                                var set = engine.mappingTypes(source: source, dest: dest) ?? []
                                if pass { set.remove(type) } else { set.insert(type) }
                                engine.setMappingTypes(source: source, dest: dest, suppressed: set)
                            }))
                    }
                }
```

…with a small helper in `MatrixCell`:

```swift
    private func title(for type: MessageType) -> String {
        switch type {
        case .note: return "Note"
        case .cc: return "CC"
        case .programChange: return "Program Change"
        case .pitchBend: return "Pitch Bend"
        case .aftertouch: return "Aftertouch"
        case .clock: return "Clock"
        case .sysex: return "Sysex"
        case .systemCommon: return "System Common"
        }
    }
```

- [ ] **Step 2: Tooltip suffix**

Extend the cell's `.help(...)` with a suppressed list (before any "(muted)"):

```swift
            .help("\(source) → \(dest) · \(modeText)\(suppressedText)\(routeEnabled ? "" : " (route off)")\(isMuted ? " (muted)" : "")")
```

```swift
    private var suppressedText: String {
        let types = engine.mappingTypes(source: source, dest: dest) ?? []
        guard !types.isEmpty else { return "" }
        return " (no " + types.map(title(for:)).map { $0.lowercased() }.joined(separator: ", ") + ")"
    }
```

- [ ] **Step 3: Compile check**

Run: `swift build` — expected: BUILD SUCCEEDED.

- [ ] **Step 4: Full suite + app bundle**

Run: `scripts/build.sh` — expected: all tests pass, bundle produced. Report the manual-check coverage list (menu shows the `pass:` section with 8 checked items by default; unchecking Clock stops 0xF8 while notes pass; selections persist across relaunch; `off` clears everything).

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterApp/RouterView.swift
git commit -m "feat(ui): per-mapping message-type toggles in cell menu"
```
