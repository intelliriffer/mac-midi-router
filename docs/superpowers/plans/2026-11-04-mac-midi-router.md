# mac-midi-router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that routes MIDI input ports to output ports with per-destination channel filters, name-based auto-reconnect, and JSON presets.

**Architecture:** One SwiftPM package with two targets: `MidiRouterCore` (route model, filter kernel, `MIDIIO` protocol + fake, engine, preset store — fully unit-testable without hardware) and `MidiRouterApp` (SwiftUI menu-bar app + real CoreMIDI backend). Only the real CoreMIDI layer lacks unit tests; everything above it runs against the fake.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, CoreMIDI classic `MIDIPacketList` API (byte-identical with our `MIDIPacket` model; still supported on all macOS), XCTest via `swift test`.

**Spec:** `docs/superpowers/specs/2026-11-04-mac-midi-router-design.md`

## Global Constraints

- Pure Swift + SwiftUI; no third-party dependencies.
- The app must not create virtual MIDI ports.
- Routes and destinations are matched and stored **by name**, never by uniqueID or index.
- Channel filters are `.all` or exactly one channel `1...16` (UI labels: `off`, `all`, `ch n`).
- Channel-less messages (`0xF0`–`0xFF`) always pass, even on single-channel routes.
- Run tests per task with `swift test --filter <TestName>`; run the whole suite before marking a task done.
- Every commit: `git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "..."`.

## File Structure (final layout)

```
Package.swift
Sources/MidiRouterCore/
  Model.swift          ChannelFilter, Destination, Route, AppState, BindingState
  MidiData.swift       MIDIPacket, splitMessages, messageKept, applyFilter
  PresetStore.swift    load/save state.json (corrupt-safe) + AppState preset ops
  MIDIIO.swift         MIDIIO/MIDIIODelegate protocols + FakeMIDIIO
  MIDIEngine.swift     reconcile, setCell, forward/filter/fan-out/merge
Sources/MidiRouterApp/
  main.swift           NSApplication bootstrap (menu-bar only)
  MenuBarController.swift   status item, popover, router window
  PopoverView.swift    per-route quick toggles + Open Router
  RouterView.swift     matrix grid + channel picker + preset controls
  RealMIDIIO.swift     CoreMIDI: client, ports, read proc, notifications
  Persistence.swift    support dir + debounced autosave
scripts/make-app.sh   release build + .app bundle + ad-hoc codesign
docs/manual-smoke.md  pre-release manual checklist (from spec)
Tests/MidiRouterCoreTests/
  ModelTests.swift
  FilterTests.swift
  PresetStoreTests.swift
  MidiIOFakeTests.swift
  EngineReconcileTests.swift
  EngineForwardTests.swift
```

---

### Task 1: Package scaffold + route data model

**Files:**
- Create: `Package.swift`
- Create: `Sources/MidiRouterCore/Model.swift`
- Test: `Tests/MidiRouterCoreTests/ModelTests.swift`

**Interfaces:**
- Produces for later tasks: `ChannelFilter` (`all` / `channel(Int)` 1...16), `Destination { name, filter }`, `Route { source, enabled, destinations }`, `AppState { currentRoutes, presets: [String: [Route]] }`, `BindingState { connectedSources, connectedDestinations: Set<String> }` — all public, `Codable, Equatable, Hashable` where the struct has no Sets.

**Steps:**

- [ ] **Step 1: Create `Package.swift`** (exactly this)

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMidiRouter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MidiRouterCore"),
        .executableTarget(
            name: "MidiRouterApp",
            dependencies: ["MidiRouterCore"]
        ),
        .testTarget(
            name: "MidiRouterCoreTests",
            dependencies: ["MidiRouterCore"]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/MidiRouterCoreTests/ModelTests.swift
import XCTest
import MidiRouterCore

final class ModelTests: XCTestCase {
    func testRouteCodableRoundTrip() throws {
        let route = Route(
            source: "Keystation 88", enabled: true,
            destinations: [Destination(name: "UM-1", filter: .channel(1)),
                           Destination(name: "IAC", filter: .all)])
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(Route.self, from: data), route)
    }

    func testAppStateCodableRoundTrip() throws {
        var state = AppState()
        state.currentRoutes = [Route(source: "A", enabled: false,
                                     destinations: [Destination(name: "B", filter: .all)])]
        state.presets = ["gig": state.currentRoutes]
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: data), state)
    }

    func testChannelFilterValidation() {
        XCTAssertNil(ChannelFilter.validate(0))
        XCTAssertEqual(ChannelFilter.validate(16), .channel(16))
        XCTAssertNil(ChannelFilter.validate(17))
        XCTAssertEqual(ChannelFilter.channel(5).label, "ch 5")
        XCTAssertEqual(ChannelFilter.all.label, "all")
    }
}
```

- [ ] **Step 3: Verify `Package.swift` builds as an executable target by creating a stub main** (the executable target will not compile until Task 8 otherwise, which blocks `swift test`)

Create `Sources/MidiRouterApp/main.swift` with just this line for now:

```swift
print("midi-router placeholder main — replaced in Task 8")
```

- [ ] **Step 4: Run test to verify it fails for the right reason (types missing, not compile chaos)**

Run: `swift test --filter ModelTests`
Expected: FAIL — compile errors naming the missing types (`ChannelFilter`, `Route`, `Destination`, `AppState`). If errors are unrelated, fix before moving on.

- [ ] **Step 5: Implement `Sources/MidiRouterCore/Model.swift`** (exactly this)

```swift
import Foundation

public enum ChannelFilter: Codable, Equatable, Hashable {
    case all
    case channel(Int)

    public static func validate(_ n: Int) -> ChannelFilter? {
        (1...16).contains(n) ? .channel(n) : nil
    }

    public var label: String {
        switch self {
        case .all: return "all"
        case .channel(let c): return "ch \(c)"
        }
    }
}

public struct Destination: Codable, Equatable, Hashable {
    public var name: String
    public var filter: ChannelFilter

    public init(name: String, filter: ChannelFilter) {
        self.name = name
        self.filter = filter
    }
}

public struct Route: Codable, Equatable, Hashable {
    public var source: String
    public var enabled: Bool
    public var destinations: [Destination]

    public init(source: String, enabled: Bool = true, destinations: [Destination] = []) {
        self.source = source
        self.enabled = enabled
        self.destinations = destinations
    }
}

public struct AppState: Codable, Equatable {
    public var currentRoutes: [Route]
    public var presets: [String: [Route]]

    public init(currentRoutes: [Route] = [], presets: [String: [Route]] = [:]) {
        self.currentRoutes = currentRoutes
        self.presets = presets
    }
}

public struct BindingState: Equatable {
    public var connectedSources: Set<String>
    public var connectedDestinations: Set<String>

    public init(connectedSources: Set<String> = [],
                connectedDestinations: Set<String> = []) {
        self.connectedSources = connectedSources
        self.connectedDestinations = connectedDestinations
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS (3 tests), and `swift build` succeeds overall.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: package scaffold and route data model"
```

---

### Task 2: MIDI packet filtering kernel

**Files:**
- Create: `Sources/MidiRouterCore/MidiData.swift`
- Test: `Tests/MidiRouterCoreTests/FilterTests.swift`

**Interfaces:**
- Consumes: `ChannelFilter` (Task 1).
- Produces for later tasks: `struct MIDIPacket { timestamp: UInt64, bytes: [UInt8] }` (public, Equatable), `public func splitMessages(_ bytes: [UInt8]) -> [[UInt8]]`, `public func applyFilter(_ packet: MIDIPacket, _ filter: ChannelFilter) -> MIDIPacket?`.

**Steps:**

- [ ] **Step 1: Write the failing test** (`Tests/MidiRouterCoreTests/FilterTests.swift`, full content)

```swift
import XCTest
import MidiRouterCore

final class FilterTests: XCTestCase {
    private func pkt(_ bytes: [UInt8]) -> MIDIPacket {
        MIDIPacket(timestamp: 7, bytes: bytes)
    }

    func testSplitChannelMessagesByLength() {
        XCTAssertEqual(splitMessages([0x90, 0x3C, 0x7F, 0x80, 0x3C, 0x00]),
                       [[0x90, 0x3C, 0x7F], [0x80, 0x3C, 0x00]])
        XCTAssertEqual(splitMessages([0xD9, 0x7F]), [[0xD9, 0x7F]])          // ch-pressure: 2 bytes
    }

    func testSplitSystemAndSysex() {
        XCTAssertEqual(splitMessages([0xF8, 0x90, 0x3C, 0x40]),
                       [[0xF8], [0x90, 0x3C, 0x40]])
        XCTAssertEqual(splitMessages([0xF2, 0x03, 0x00, 0xF0, 0x7E, 0xF7]),
                       [[0xF2, 0x03, 0x00], [0xF0, 0x7E, 0xF7]])
    }

    func testSingleChannelFilter() {
        XCTAssertEqual(applyFilter(pkt([0x90, 0x3C, 0x40]), .channel(1)),
                       pkt([0x90, 0x3C, 0x40]))
        XCTAssertEqual(applyFilter(pkt([0x90, 0x3C, 0x40]), .all),
                       pkt([0x90, 0x3C, 0x40]))
        XCTAssertNil(applyFilter(pkt([0x90, 0x3C, 0x40]), .channel(5)))
        XCTAssertEqual(applyFilter(pkt([0xD9, 0x7F]), .channel(10)), pkt([0xD9, 0x7F]))
        XCTAssertNil(applyFilter(pkt([0xD9, 0x7F]), .channel(1)))
    }

    func testSystemMessagesAlwaysPassOnSingleChannelFilters() {
        XCTAssertEqual(applyFilter(pkt([0xF0, 0x7E, 0xF7]), .channel(5)),
                       pkt([0xF0, 0x7E, 0xF7]))
        XCTAssertEqual(applyFilter(pkt([0xF8]), .channel(5)), pkt([0xF8]))
        XCTAssertEqual(applyFilter(pkt([0xF2, 0x03, 0x00]), .channel(3)),
                       pkt([0xF2, 0x03, 0x00]))
    }

    func testMixedPacketReturnsNilWhenAllDropped() {
        XCTAssertNil(applyFilter(pkt([0x91, 0x3C, 0x7F]), .channel(2)))
    }

    func testMixedMultiMessageFiltering() {
        let mixed = pkt([0x90, 0x3C, 0x40,      // ch1 note on — kept
                         0x94, 0x40, 0x40,      // ch5 note on — dropped
                         0xF8,                  // clock — always passes
                         0xB5, 0x07, 0x64,      // ch6 CC — dropped
                         0x81, 0x3C, 0x00,      // ch2 note off — dropped
                         0xF0, 0x7E, 0xF7])     // sysex — always passes
        XCTAssertEqual(applyFilter(mixed, .channel(1))?.bytes,
                       [0x90, 0x3C, 0x40, 0xF8, 0xF0, 0x7E, 0xF7])
        XCTAssertEqual(applyFilter(mixed, .all), mixed)   // .all is identity
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FilterTests`
Expected: FAIL — unresolved `MIDIPacket` / `splitMessages` / `applyFilter`.

- [ ] **Step 3: Implement `Sources/MidiRouterCore/MidiData.swift`** (exactly this)

```swift
import Foundation

public struct MIDIPacket: Equatable {
    public var timestamp: UInt64
    public var bytes: [UInt8]

    public init(timestamp: UInt64 = 0, bytes: [UInt8]) {
        self.timestamp = timestamp
        self.bytes = bytes
    }
}

extension UInt8 {
    var isChannelStatus: Bool { (0x80...0xEF).contains(self) }

    /// Wire length of the message whose status byte this is.
    var messageLength: Int {
        switch self & 0xF0 {
        case 0xC0, 0xD0: return 2
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 3
        default: return 1              // system common/realtime single bytes
        }
    }
}

/// Splits a raw MIDI byte stream into individual wire messages.
public func splitMessages(_ bytes: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0xF0 {
            // Sysex runs until 0xF7 (inclusive); unterminated sysex keeps what's left.
            var j = i
            while j < bytes.count, bytes[j] != 0xF7 { j += 1 }
            if j < bytes.count { j += 1 }
            out.append(Array(bytes[i..<j]))
            i = j
        } else if b == 0xF2 {
            // Song Position Pointer carries two data bytes.
            let end = min(i + 3, bytes.count)
            out.append(Array(bytes[i..<end]))
            i = end
        } else {
            let end = min(i + b.messageLength, bytes.count)
            out.append(Array(bytes[i..<end]))
            i = end
        }
    }
    return out
}

func messageKept(_ status: UInt8, _ filter: ChannelFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .channel(let ch):
        guard status.isChannelStatus else { return true }   // sysex + system always pass
        return (status & 0x0F) == UInt8(ch - 1)
    }
}

/// Channel-filters one packet. Returns nil when every byte drops out.
/// `.all` is the identity (no re-copy).
public func applyFilter(_ packet: MIDIPacket, _ filter: ChannelFilter) -> MIDIPacket? {
    if case .all = filter { return packet }
    var out: [UInt8] = []
    for msg in splitMessages(packet.bytes) where messageKept(msg[0], filter) {
        out.append(contentsOf: msg)
    }
    return out.isEmpty ? nil : MIDIPacket(timestamp: packet.timestamp, bytes: out)
}
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS — ModelTests (3) + FilterTests (6).

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterCore/MidiData.swift Tests/MidiRouterCoreTests/FilterTests.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: channel filter kernel (splitMessages + applyFilter)"
```

---

### Task 3: PresetStore — corrupt-safe persistence + preset ops

**Files:**
- Create: `Sources/MidiRouterCore/PresetStore.swift`
- Test: `Tests/MidiRouterCoreTests/PresetStoreTests.swift`

**Interfaces:**
- Consumes: `AppState` et al. (Task 1).
- Produces for Task 8: `enum PresetStore { static func stateURL(in: URL) -> URL; static func save(_: AppState, in: URL) throws; static func load(in: URL) -> AppState }`; `extension AppState { mutating func savePreset(as: String) -> Bool; mutating func loadPreset(_ name: String) -> Bool; mutating func deletePreset(_ name: String) -> Bool }` (`loadPreset` keeps current enabled flags, snapshot per spec).

**Steps:**

- [ ] **Step 1: Write the failing test** (`Tests/MidiRouterCoreTests/PresetStoreTests.swift`, full content)

```swift
import XCTest
import MidiRouterCore

final class PresetStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveLoadRoundTrip() throws {
        var state = AppState(
            currentRoutes: [Route(source: "A", enabled: true,
                destinations: [Destination(name: "B", filter: .channel(3))])],
            presets: [:])
        state.savePreset(as: "gig")
        try PresetStore.save(state, in: dir)
        XCTAssertEqual(PresetStore.load(in: dir), state)
    }

    func testMissingFileLoadsEmptyState() {
        XCTAssertEqual(PresetStore.load(in: dir), AppState())
    }

    func testCorruptFileLoadsEmptyState() throws {
        try Data("not valid json {".utf8).write(to: PresetStore.stateURL(in: dir))
        XCTAssertEqual(PresetStore.load(in: dir), AppState())
    }

    func testPresetLifecycle() {
        var state = AppState()
        let routes = [Route(source: "K", enabled: true,
                            destinations: [Destination(name: "P", filter: .all)])]

        state.currentRoutes = routes
        XCTAssertTrue(state.savePreset(as: "gig"))
        XCTAssertEqual(state.presets["gig"], routes)
        XCTAssertFalse(state.savePreset(as: ""))

        state.currentRoutes = [Route(source: "unrelated")]
        XCTAssertTrue(state.loadPreset("gig"))
        XCTAssertEqual(state.currentRoutes, routes)          // Snapshot replaces routes

        state.currentRoutes = [Route(source: "gone")]
        XCTAssertTrue(state.deletePreset("gig"))
        XCTAssertNil(state.presets["gig"])
        XCTAssertFalse(state.deletePreset("gig"))            // second delete fails
        XCTAssertFalse(state.loadPreset("never existed"))    // unknown preset is a no-op
    }

    func testLoadPresetKeepsCurrentEnabledFlags() {
        var state = AppState()
        let saved = [Route(source: "K", enabled: true,
                           destinations: [Destination(name: "P", filter: .all)])]
        state.currentRoutes = saved
        state.savePreset(as: "gig")

        state.currentRoutes = [Route(source: "K", enabled: false,
                                     destinations: saved[0].destinations)]
        state.loadPreset("gig")
        // Current enabled=false wins over the snapshot's true (per spec: keep flags).
        XCTAssertEqual(state.currentRoutes[0].enabled, false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PresetStoreTests`
Expected: FAIL — unresolved `PresetStore`.

- [ ] **Step 3: Implement `Sources/MidiRouterCore/PresetStore.swift`** (exactly this)

```swift
import Foundation

public enum PresetStore {
    public static func stateURL(in dir: URL) -> URL {
        dir.appendingPathComponent("state.json")
    }

    public static func save(_ state: AppState, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL(in: dir), options: [.atomic])
    }

    /// Missing or corrupt files yield an empty state — the app never crashes
    /// on bad disk contents (spec: "corrupt file → log it, start empty").
    public static func load(in dir: URL) -> AppState {
        guard let data = try? Data(contentsOf: stateURL(in: dir)),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else {
            NSLog("PresetStore: state.json missing or corrupt — starting empty")
            return AppState()
        }
        return state
    }
}

public extension AppState {
    /// Snapshot the current routes under a preset name. Empty names rejected.
    @discardableResult
    mutating func savePreset(as name: String) -> Bool {
        guard !name.isEmpty else { return false }
        presets[name] = currentRoutes          // value-type snapshot copy
        return true
    }

    /// Replace current routes with the named preset's routes, keeping each
    /// currently-known source's enabled flag (day-to-day on/off survives loads).
    @discardableResult
    mutating func loadPreset(_ name: String) -> Bool {
        guard let routes = presets[name] else { return false }
        let currentFlags = Dictionary(
            uniqueKeysWithValues: currentRoutes.map { ($0.source, $0.enabled) })
        currentRoutes = routes.map { route in
            var r = route
            if let flag = currentFlags[r.source] { r.enabled = flag }
            return r
        }
        return true
    }

    @discardableResult
    mutating func deletePreset(_ name: String) -> Bool {
        presets.removeValue(forKey: name) != nil
    }
}
```

- [ ] **Step 4: Run full suite**

Run: `swift test`
Expected: PASS — 13 tests so far.

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterCore/PresetStore.swift Tests/MidiRouterCoreTests/PresetStoreTests.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: preset store with corrupt-safe JSON persistence"
```

---

### Task 4: `MIDIIO` protocol + `FakeMIDIIO`

**Files:**
- Create: `Sources/MidiRouterCore/MIDIIO.swift`
- Test: `Tests/MidiRouterCoreTests/MidiIOFakeTests.swift`

**Interfaces:**
- Produces for Tasks 5–8:
  - `public protocol MIDIIODelegate: AnyObject { func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]); func midiEndpointsChanged(_ io: MIDIIO) }`
  - `public protocol MIDIIO: AnyObject { weak var delegate: MIDIIODelegate? { get set }; func sourceNames() -> [String]; func destinationNames() -> [String]; @discardableResult func bind(source: String) -> Bool; @discardableResult func bind(destination: String) -> Bool; func unbind(source: String); func unbind(destination: String); func send(packets: [MIDIPacket], to destination: String) }`
  - `public final class FakeMIDIIO` — init takes endpoint-name arrays (arrays, not Sets, so duplicate-name scenarios are drivable); `presentSources: [String]`, `presentDestinations: [String]`, `sourceBindings: Set<String>`, `destinationBindings: Set<String>`, `receivedLog: [MIDIOutEvent]`; `MIDIOutEvent { to: String, packets: [MIDIPacket] }` (Equatable); drivers: `fakePlugSource(_:)`, `fakePlugDestination(_:)`, `fakeUnplug(_:)`, `fakeSend(source:packets:)`.

**Steps:**

- [ ] **Step 1: Write the failing test** (`Tests/MidiRouterCoreTests/MidiIOFakeTests.swift`, full content)

```swift
import XCTest
import MidiRouterCore

final class MidiIOFakeTests: XCTestCase {
    func testBindSucceedsOnlyForPresentPorts() {
        let io = FakeMIDIIO(presentSources: ["K88"],
                            presentDestinations: ["UM-1", "IAC"])
        XCTAssertTrue(io.bind(source: "K88"))
        XCTAssertTrue(io.bind(destination: "UM-1"))
        XCTAssertFalse(io.bind(source: "ghost"))
        XCTAssertFalse(io.bind(destination: "ghost"))
        XCTAssertEqual(io.sourceNames(), ["K88"])
        XCTAssertEqual(io.destinationNames(), ["IAC", "UM-1"])   // sorted
        XCTAssertEqual(io.sourceBindings, Set(["K88"]))
        XCTAssertEqual(io.destinationBindings, Set(["UM-1"]))
    }

    func testUnbindClearsBinding() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: [])
        io.bind(source: "K88")
        io.unbind(source: "K88")
        XCTAssertTrue(io.sourceBindings.isEmpty)
        io.unbind(source: "never-bound")                         // idempotent
    }

    func testFakeSendOnlyDeliversWhenSourceBound() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: [])
        io.delegate = nil
        io.fakeSend(source: "K88", packets: [MIDIPacket(bytes: [0x90])])
        XCTAssertTrue(io.receivedLog.isEmpty)                    // unbound: no delivery
        io.bind(source: "K88")

        var delivered: String?
        final class Echo: MIDIIODelegate {
            var got: String?
            func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]) {
                got = name
            }
            func midiEndpointsChanged(_ io: MIDIIO) {}
        }
        let d = Echo()
        io.delegate = d
        io.fakeSend(source: "K88", packets: [MIDIPacket(bytes: [0x90])])
        XCTAssertEqual(d.got, "K88")
        delivered = d.got
        XCTAssertEqual(delivered, "K88")
    }

    func testPlugUnplugFiresEndpointsChangedAndUpdatesLists() {
        final class Counter: MIDIIODelegate {
            var changed = 0
            func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]) {}
            func midiEndpointsChanged(_ io: MIDIIO) { changed += 1 }
        }
        let c = Counter()
        let io = FakeMIDIIO(presentSources: [], presentDestinations: [])
        io.delegate = c

        io.fakePlugDestination("UM-1")
        XCTAssertEqual(io.destinationNames(), ["UM-1"])
        XCTAssertEqual(c.changed, 1)

        io.fakePlugSource("K88")
        XCTAssertEqual(io.sourceNames(), ["K88"])
        XCTAssertEqual(c.changed, 2)

        io.fakeUnplug("UM-1")
        XCTAssertEqual(io.destinationNames(), [])
        XCTAssertEqual(c.changed, 3)
        io.fakeUnplug("K88")
        XCTAssertEqual(c.changed, 4)
    }

    func testDuplicateNamesSurviveInList() {
        let io = FakeMIDIIO(presentSources: ["Duo", "Duo"], presentDestinations: [])
        XCTAssertEqual(io.sourceNames(), ["Duo", "Duo"])
    }

    func testSendLogsForEachCall() {
        let io = FakeMIDIIO(presentSources: [], presentDestinations: ["D"])
        io.bind(destination: "D")
        io.send(packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])], to: "D")
        XCTAssertEqual(io.receivedLog,
                       [.init(to: "D", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MidiIOFakeTests`
Expected: FAIL — unresolved `MIDIIO` / `FakeMIDIIO`.

- [ ] **Step 3: Implement `Sources/MidiRouterCore/MIDIIO.swift`** (exactly this)

```swift
import Foundation

public protocol MIDIIODelegate: AnyObject {
    func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket])
    func midiEndpointsChanged(_ io: MIDIIO)
}

public protocol MIDIIO: AnyObject {
    weak var delegate: MIDIIODelegate? { get set }
    func sourceNames() -> [String]
    func destinationNames() -> [String]
    @discardableResult func bind(source: String) -> Bool
    @discardableResult func bind(destination: String) -> Bool
    func unbind(source: String)
    func unbind(destination: String)
    func send(packets: [MIDIPacket], to destination: String)
}

/// Dictionary-backed MIDI test double. All deliveries are synchronous.
/// Endpoint lists are arrays so duplicate-name scenarios stay drivable.
public final class FakeMIDIIO: MIDIIO {
    public struct MIDIOutEvent: Equatable {
        public let to: String
        public let packets: [MIDIPacket]
    }

    public weak var delegate: MIDIIODelegate?
    public private(set) var receivedLog: [MIDIOutEvent] = []
    public private(set) var sourceBindings: Set<String> = []
    public private(set) var destinationBindings: Set<String> = []
    private var sources: [String]
    private var destinations: [String]

    public init(presentSources: [String] = [], presentDestinations: [String] = []) {
        self.sources = presentSources
        self.destinations = presentDestinations
    }

    public func sourceNames() -> [String] { sources.sorted() }
    public func destinationNames() -> [String] { destinations.sorted() }

    @discardableResult public func bind(source: String) -> Bool {
        guard sources.contains(source) else { return false }
        sourceBindings.insert(source)
        return true
    }

    @discardableResult public func bind(destination: String) -> Bool {
        guard destinations.contains(destination) else { return false }
        destinationBindings.insert(destination)
        return true
    }

    public func unbind(source name: String) {
        sourceBindings.remove(name)
    }

    public func unbind(destination name: String) {
        destinationBindings.remove(name)
    }

    public func send(packets: [MIDIPacket], to destination: String) {
        receivedLog.append(MIDIOutEvent(to: destination, packets: packets))
    }

    // MARK: Test-driven hardware SIMULATION endpoints

    public func fakePlugSource(_ name: String) {
        sources.append(name)
        delegate?.midiEndpointsChanged(self)
    }

    public func fakePlugDestination(_ name: String) {
        destinations.append(name)
        delegate?.midiEndpointsChanged(self)
    }

    public func fakeUnplug(_ name: String) {
        sources.removeAll { $0 == name }
        destinations.removeAll { $0 == name }
        delegate?.midiEndpointsChanged(self)
    }

    /// Deliver packets into the engine exactly like a real read callback would
    /// — but only if that source is currently bound (unbound ports emit nothing).
    public func fakeSend(source: String, packets: [MIDIPacket]) {
        guard sourceBindings.contains(source) else { return }
        delegate?.midi(self, source: source, received: packets)
    }
}
```

- [ ] **Step 4: Run full suite**

Run: `swift test`
Expected: PASS — 19 tests so far.

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterCore/MIDIIO.swift Tests/MidiRouterCoreTests/MidiIOFakeTests.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: MIDIIO protocol and fake test double"
```

---

### Task 5: `MIDIEngine` — configuration + reconcile (name-based reconnect)

**Files:**
- Create: `Sources/MidiRouterCore/MIDIEngine.swift`
- Test: `Tests/MidiRouterCoreTests/EngineReconcileTests.swift`

**Interfaces:**
- Consumes: `Route`, `AppState`, `BindingState` (Task 1); `MIDIIO`, `FakeMIDIIO` (Task 4).
- Produces for Tasks 6 and 8 (public API of `MIDIEngine`):
  - `public final class MIDIEngine: ObservableObject` — `init(io: MIDIIO, initialState: AppState = .init())`; `var objectWillChange` free from `ObservableObject`.
  - `@Published public private(set) var config: AppState`; `@Published public private(set) var connected: BindingState`; `@Published public private(set) var warning: String?`
  - `public func performReconcile()` — the single binding/derivation function (spec: called on launch, every endpoint add/remove notification, and after any config change).
  - `public func setRoutes(_ routes: [Route])`; `public func setRouteEnabled(source: String, enabled: Bool)` (append an enabled empty route when toggling an unknown source on); `public func setRoute(source: String, destinations: [Destination])`.
  - `public var duplicateSourceNames: [String]`; `public var duplicateDestinationNames: [String]`.
  - Internal (used by Task 6): `private let lock = NSLock()`; `func reconcileLocked()`.

NOTE: In this task the class does **not** yet declare `MIDIIODelegate` conformance and does **not** set `io.delegate` — Task 6 adds that (`extension MIDIEngine: MIDIIODelegate` + one line in `init`). Keeping the conformance out means this task compiles standalone without a forward declaration of the read path.

**Steps:**

- [ ] **Step 1: Write the failing test** (`Tests/MidiRouterCoreTests/EngineReconcileTests.swift`, full content)

```swift
import XCTest
import MidiRouterCore

final class EngineReconcileTests: XCTestCase {
    private func boot(io: FakeMIDIIO, _ routes: [Route]) -> MIDIEngine {
        let engine = MIDIEngine(io: io, initialState: AppState(currentRoutes: routes))
        engine.performReconcile()          // tests drive the reconcile path directly
        return engine
    }

    func testColdStartBindsConfiguredAndPresent() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [
            Route(source: "K88", destinations: [Destination(name: "UM-1", filter: .all)])])
        XCTAssertEqual(engine.connected.connectedSources, ["K88"])
        XCTAssertEqual(engine.connected.connectedDestinations, ["UM-1"])
        XCTAssertEqual(io.sourceBindings, Set(["K88"]))
        XCTAssertEqual(io.destinationBindings, Set(["UM-1"]))
    }

    func testConfiguredButUnpluggedStaysDisconnected() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: [])
        let engine = boot(io: io, [
            Route(source: "Ghost", destinations: [Destination(name: "nope", filter: .all)])])
        XCTAssertTrue(engine.connected.connectedSources.isEmpty)
        XCTAssertTrue(engine.connected.connectedDestinations.isEmpty)
        XCTAssertEqual(io.sourceBindings, Set([]))
        XCTAssertEqual(io.destinationBindings, Set([]))
    }

    func testSetRoutesReconcilesAndUnbindsOldRoutes() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [
            Route(source: "K88", destinations: [Destination(name: "UM-1", filter: .all)])])
        engine.setRoutes([])
        XCTAssertTrue(io.sourceBindings.isEmpty)
        XCTAssertTrue(io.destinationBindings.isEmpty)
        XCTAssertTrue(engine.connected.connectedSources.isEmpty)
    }

    func testHotplugReconnectAfterUnplugAndReplug() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [
            Route(source: "K88", destinations: [Destination(name: "UM-1", filter: .all)])])

        io.fakeUnplug("UM-1")
        engine.performReconcile()
        XCTAssertTrue(engine.connected.connectedDestinations.isEmpty)
        XCTAssertTrue(io.destinationBindings.isEmpty)

        io.fakePlugDestination("UM-1")
        engine.performReconcile()
        XCTAssertEqual(engine.connected.connectedDestinations, ["UM-1"])
        XCTAssertEqual(io.destinationBindings, Set(["UM-1"]))
    }

    func testDisabledSourceRouteDoesNotBindAndReEnableBinds() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [
            Route(source: "K88", enabled: false,
                  destinations: [Destination(name: "UM-1", filter: .all)])])
        XCTAssertTrue(io.sourceBindings.isEmpty)         // disabled routes stay idle

        engine.setRouteEnabled(source: "K88", enabled: true)
        XCTAssertEqual(io.sourceBindings, Set(["K88"]))
        XCTAssertEqual(engine.connected.connectedDestinations, ["UM-1"])
    }

    func testEnabledToggleOnUnknownSourceCreatesRoute() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [])
        engine.setRouteEnabled(source: "K88", enabled: true)
        let route = engine.config.currentRoutes.first { $0.source == "K88" }
        XCTAssertEqual(route?.enabled, true)
        XCTAssertEqual(io.sourceBindings, Set(["K88"]))
    }

    func testDuplicateNamesFlagged() {
        let io = FakeMIDIIO(presentSources: ["Duo", "Duo"],
                            presentDestinations: ["K", "K"])
        let engine = boot(io: io, [
            Route(source: "Duo", destinations: [Destination(name: "K", filter: .all)])])
        XCTAssertEqual(engine.duplicateSourceNames, ["Duo"])
        XCTAssertEqual(engine.duplicateDestinationNames, ["K"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineReconcileTests`
Expected: FAIL — unresolved `MIDIEngine`.

- [ ] **Step 3: Implement `Sources/MidiRouterCore/MIDIEngine.swift`** (exactly this)

```swift
import Foundation
import Combine

/// Central routing engine.
///
/// Threading model (spec §threading): all *mutation* of `config` happens on the
/// main actor (UI callbacks / reconcile calls), all *reads* from the MIDI read
/// thread pass through `lock`, so the callback never races a concurrently
/// saving/preset-loading path. `performReconcile()` is idempotent and always
/// called from the main actor.
final public class MIDIEngine: ObservableObject {
    private let io: MIDIIO
    private let lock = NSLock()
    private var boundSources: Set<String> = []
    private var boundDestinations: Set<String> = []

    @Published public private(set) var config: AppState
    @Published public private(set) var connected: BindingState = BindingState()
    @Published public private(set) var warning: String?

    public init(io: MIDIIO, initialState: AppState = .init()) {
        self.io = io
        self.config = initialState
    }

    // MARK: Configuration edits (main thread only)

    public func setRoutes(_ routes: [Route]) {
        mutateConfig { $0.currentRoutes = routes }
    }

    /// Toggling an unknown source on creates an enabled route for it,
    /// which matches the popover's checkbox semantics.
    public func setRouteEnabled(source: String, enabled: Bool) {
        mutateConfig { state in
            if let index = state.currentRoutes.firstIndex(where: { $0.source == source }) {
                state.currentRoutes[index].enabled = enabled
            } else if enabled {
                state.currentRoutes.append(Route(source: source, enabled: true))
            }
        }
    }

    public func setRoute(source: String, destinations: [Destination]) {
        mutateConfig { state in
            if let index = state.currentRoutes.firstIndex(where: { $0.source == source }) {
                state.currentRoutes[index].destinations = destinations
            } else {
                state.currentRoutes.append(
                    Route(source: source, enabled: true, destinations: destinations))
            }
        }
    }

    public var duplicateSourceNames: [String] {
        duplicates(in: io.sourceNames())
    }

    public var duplicateDestinationNames: [String] {
        duplicates(in: io.destinationNames())
    }

    private func duplicates(in names: [String]) -> [String] {
        Dictionary(grouping: names, by: { $0 })
            .filter { $1.count > 1 }
            .keys
            .sorted()
    }

    internal func mutateConfig(_ mutate: (inout AppState) -> Void) {
        lock.lock()
        var state = config
        mutate(&state)
        lock.unlock()
        config = state
        performReconcile()
    }

    // MARK: Reconcile

    /// Single binding algorithm (spec §hotplug): everything configured and
    /// currently present gets re-bound; everything not present keeps its
    /// configuration but shows as disconnected. Idempotent.
    public func performReconcile() {
        lock.lock(); defer { lock.unlock() }

        let presentSources = Set(io.sourceNames())
        let presentDestinations = Set(io.destinationNames())

        var wantSources: Set<String> = []
        var wantDestinations: Set<String> = []
        for route in config.currentRoutes where route.enabled {
            if presentSources.contains(route.source) {
                wantSources.insert(route.source)
            }
            for dest in route.destinations where presentDestinations.contains(dest.name) {
                wantDestinations.insert(dest.name)
            }
        }

        for name in boundSources.subtracting(wantSources) {
            io.unbind(source: name)
        }
        for name in wantSources.subtracting(boundSources) {
            _ = io.bind(source: name)
        }
        for name in boundDestinations.subtracting(wantDestinations) {
            io.unbind(destination: name)
        }
        for name in wantDestinations.subtracting(boundDestinations) {
            _ = io.bind(destination: name)
        }
        boundSources = wantSources
        boundDestinations = wantDestinations

        let next = BindingState(connectedSources: wantSources,
                                connectedDestinations: wantDestinations)
        connected = next

        let dup = (duplicateSourceNames + duplicateDestinationNames).sorted()
        warning = dup.isEmpty ? nil : "Duplicate port names: \(dup.joined(separator: ", ")). First match wins."
    }
}
```

- [ ] **Step 4: Run full suite**

Run: `swift test`
Expected: PASS — 29 tests so far (EngineReconcileTests adds 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterCore/MIDIEngine.swift Tests/MidiRouterCoreTests/EngineReconcileTests.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: MIDIEngine reconcile with name-based bindings"
```

---

### Task 6: `MIDIEngine` forward path (filter → fan-out → merge)

**Files:**
- Modify: `Sources/MidiRouterCore/MIDIEngine.swift`
- Test: `Tests/MidiRouterCoreTests/EngineForwardTests.swift`

**Interfaces:**
- Consumes: `applyFilter` (Task 2), `FakeMIDIIO.fakeSend` (Task 4), engine API (Task 5).
- Produces for Task 8: same public API, plus `MIDIIODelegate` conformance:
  - `public func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket])` (forward path, called from CoreMIDI's read thread or the fake's synthetic thread).
  - `public func midiEndpointsChanged(_ io: MIDIIO)` → schedules `performReconcile()` on the main queue (spec: reconcile always from main actor).
  - `init` now also wires `io.delegate = self`.

**Steps:**

- [ ] **Step 1: Write the failing test** (`Tests/MidiRouterCoreTests/EngineForwardTests.swift`, full content)

```swift
import XCTest
import MidiRouterCore

final class EngineForwardTests: XCTestCase {
    private func boot(_ routes: [Route]) -> (FakeMIDIIO, MIDIEngine) {
        let io = FakeMIDIIO(presentSources: ["Keys", "Drums"],
                            presentDestinations: ["UM-1", "IAC", "Bass"])
        let engine = MIDIEngine(io: io, initialState: AppState(currentRoutes: routes))
        engine.performReconcile()
        return (io, engine)
    }

    func testFanOutWithMixedFilters() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .channel(1)),
                Destination(name: "Bass", filter: .all)])])

        io.fakeSend(source: "Keys", packets: [
            MIDIPacket(bytes: [0x90, 0x3C, 0x40]),    // ch1 → survives both
            MIDIPacket(bytes: [0x95, 0x60, 0x60])])   // ch6 → only .all dest

        XCTAssertEqual(io.receivedLog.count, 3)
        XCTAssertEqual(Set(io.receivedLog.map(\.to)), Set(["UM-1", "Bass"]))
        let um1 = io.receivedLog.last { $0.to == "UM-1" }!.packets
        XCTAssertEqual(um1.flatMap(\.bytes), [0x90, 0x3C, 0x40])
        let bass = io.receivedLog.last { $0.to == "Bass" }!.packets
        XCTAssertEqual(bass.flatMap(\.bytes), [0x90, 0x3C, 0x40, 0x95, 0x60, 0x60])
        _ = engine
    }

    func testDisabledRouteSwallowsTraffic() {
        let (io, _) = boot([
            Route(source: "Keys", enabled: false,
                  destinations: [Destination(name: "UM-1", filter: .all)])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)
    }

    func testUnboundSourceNeverDelivers() {
        let (io, _) = boot([])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)
    }

    func testAllFilteredOutDeliversNothing() {
        let (io, _) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .channel(9))])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)       // filtered out entirely → no send
    }

    func testMergeTwoSourcesIntoOneDestination() {
        let (io, _) = boot([
            Route(source: "Keys", enabled: true, destinations: [Destination(name: "IAC", filter: .all)]),
            Route(source: "Drums", enabled: true, destinations: [Destination(name: "IAC", filter: .all)])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0xC0, 0x00])])
        io.fakeSend(source: "Drums", packets: [MIDIPacket(bytes: [0xC1, 0x01])])
        XCTAssertEqual(io.receivedLog.filter { $0.to == "IAC" }.count, 2)
    }

    func testSystemMessagesViaSingleChannelRoute() {
        let (io, _) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .channel(3))])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0xF8])])
        XCTAssertEqual(io.receivedLog.count, 1)
        XCTAssertEqual(io.receivedLog[0].to, "UM-1")
        XCTAssertEqual(io.receivedLog[0].packets.flatMap(\.bytes), [0xF8])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineForwardTests`
Expected: FAIL — engine does not delegate to `MIDIIODelegate`, so `fakeSend` no-ops into no log (all 6 tests fail with empty `receivedLog`).

- [ ] **Step 3: Implement the delegate conformance and wire the fake.**

Add to `Sources/MidiRouterCore/MIDIEngine.swift` (and change `init` to set `io.delegate = self`):

```swift
extension MIDIEngine: MIDIIODelegate {
    /// Fan-out path. Runs on CoreMIDI's read thread (or the fake's call site):
    /// only reads immutable snapshots under `lock`, writes through `io.send`.
    public func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]) {
        lock.lock()
        var route: Route?
        for r in config.currentRoutes where r.source == name && r.enabled {
            route = r
        }
        let connectedTargets = connected.connectedDestinations
        lock.unlock()
        guard let route = route else { return }

        for dest in route.destinations where connectedTargets.contains(dest.name) {
            var filtered: [MIDIPacket] = []
            filtered.reserveCapacity(packets.count)
            for pkt in packets {
                if let kept = applyFilter(pkt, dest.filter) {
                    filtered.append(kept)
                }
            }
            guard !filtered.isEmpty else { continue }
            io.send(packets: filtered, to: dest.name)
        }
    }

    /// Endpoint hotplug: CoreMIDI gives us the event, we just re-run the single
    /// reconciler on the main actor (spec §hotplug: same code path as cold start).
    public func midiEndpointsChanged(_ io: MIDIIO) {
        DispatchQueue.main.async { [weak self] in self?.performReconcile() }
    }
}
```

Change the `init` in `MIDIEngine` to:

```swift
    public init(io: MIDIIO, initialState: AppState = .init()) {
        self.io = io
        self.config = initialState
        io.delegate = self
    }
```

- [ ] **Step 4: Run full suite**

Run: `swift test`
Expected: PASS — 35+ tests (6 forward tests now pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterCore/MIDIEngine.swift Tests/MidiRouterCoreTests/EngineForwardTests.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: engine forward path with filter, fan-out, merge"
```

---

### Task 7: Real CoreMIDI backend (`RealMIDIIO`)

**Files:**
- Create: `Sources/MidiRouterApp/RealMIDIIO.swift`
- (No unit tests for this file — it requires live CoreMIDI. Its correctness is covered by (a) the fake-engine integration tests for the same protocol above it, and (b) the manual checklist in Task 9. The only automated gate here is a clean `swift build`.)

**Interfaces:**
- Consumes: `MIDIIO`, `MIDIIODelegate`, `MIDIPacket` from `MidiRouterCore`.
- Produces for Task 8: `final class RealMIDIIO: NSObject, MIDIIO` — `let io = RealMIDIIO()` from `main.swift`.

**Steps:**

- [ ] **Step 1: Implement `Sources/MidiRouterApp/RealMIDIIO.swift`** (exactly this)

```swift
import Foundation
import CoreMIDI
import MidiRouterCore

/// The real CoreMIDI backend (single client, one input port per bound source,
/// one output port per bound destination). Uses the classic MIDIPacketList
/// API: it is byte-identical with our `MIDIPacket` model and still supported
/// on every macOS version, so no UMP translation is needed.
final public class RealMIDIIO: NSObject, MIDIIO {
    public weak var delegate: MIDIIODelegate?

    private var client: MIDIClientRef = 0
    private var inputPorts: [String: MIDIPortRef] = [:]
    private var outputPorts: [String: MIDIPortRef] = [:]
    // MIDIPortConnectSource's per-connection refCon carries the source name;
    // we retain an NSString for each connection for as long as it exists.
    private var connectionBoxes: [String: Unmanaged<NSString>] = [:]
    private let callbackQueue = DispatchQueue(label: "mac-midi-router.readproc")

    public override init() {
        super.init()
        var client = self.client
        MIDIClientCreate("mac-midi-router" as CFString,
                         notificationProc,
                         Unmanaged.passUnretained(self).toOpaque(),
                         &client)
        self.client = client
    }

    deinit {
        for (_, port) in inputPorts { MIDIPortDispose(port) }
        for (_, port) in outputPorts { MIDIPortDispose(port) }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    // MARK: Enumeration

    public func sourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).filter { $0 in
            MIDIGetSource($0) != 0
        }.map { self.endpointName(MIDIGetSource($0)) }.sorted().filter { !$0.isEmpty }
    }

    public func destinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).filter { $0 in
            MIDIGetDestination($0) != 0
        }.map { self.endpointName(MIDIGetDestination($0)) }
         .sorted()
         .filter { !$0.isEmpty }
    }

    private func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var unmanaged: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanaged)
        return unmanaged?.takeRetainedValue() as String? ?? ""
    }

    private func sourceEndpointRef(named name: String) -> MIDIEndpointRef? {
        (0..<MIDIGetNumberOfSources()).first { endpointName(MIDIGetSource($0)) == name }
            .map { MIDIGetSource($0) }
    }

    private func destinationEndpointRef(named name: String) -> MIDIEndpointRef? {
        (0..<MIDIGetNumberOfDestinations()).first { endpointName(MIDIGetDestination($0)) == name }
            .map { MIDIGetDestination($0) }
    }

    // MARK: Binding

    @discardableResult
    public func bind(source name: String) -> Bool {
        guard inputPorts[name] == nil, let endpoint = sourceEndpointRef(named: name)
        else { return false }
        var port: MIDIPortRef = 0
        guard MIDIInputPortCreate(client, name as CFString,
                                  readProc,
                                  Unmanaged.passUnretained(self).toOpaque(),
                                  &port) == noErr
        else { return false }
        let box = Unmanaged.passRetained(name as NSString)
        guard MIDIPortConnectSource(port, endpoint, box.toOpaque()) == noErr else {
            box.release()
            return false
        }
        inputPorts[name] = port
        connectionBoxes[name] = box
        return true
    }

    @discardableResult
    public func bind(destination name: String) -> Bool {
        guard outputPorts[name] == nil else { return true }   // idempotent
        var port: MIDIPortRef = 0
        guard MIDIOutputPortCreate(client, name as CFString, &port) == noErr
        else { return false }
        outputPorts[name] = port
        return true
    }

    public func unbind(source name: String) {
        if let port = inputPorts.removeValue(forKey: name) {
            MIDIPortDispose(port)
        }
        connectionBoxes.removeValue(forKey: name)?.release()
    }

    public func unbind(destination name: String) {
        if let port = outputPorts.removeValue(forKey: name) {
            MIDIPortDispose(port)
        }
    }

    // MARK: Sending

    public func send(packets: [MIDIPacket], to destination: String) {
        guard let port = outputPorts[destination],
              let endpoint = destinationEndpointRef(named: destination)
        else { return }

        var list = MIDIPacketList(numPackets: 0, packet: MIDIPacket())
        var cursor = MIDIPacketListInit(&list)
        for packet in packets {
            cursor = MIDIPacketListAdd(&list, 65536, cursor,
                                       packet.timestamp,
                                       packet.bytes.count,
                                       packet.bytes)
        }
        MIDISend(port, endpoint, &list)
    }
}
```

Callbacks and byte extraction are also file scope, same file:

```swift
private let notificationProc: MIDINotifyProc = { notification, refCon in
    guard let notification = notification, let refCon = refCon else { return }
    let io = Unmanaged<RealMIDIIO>.fromOpaque(refCon).takeUnretainedValue()
    switch notification.pointee.messageID {
    case .msgAdded, .msgRemoved, .msgPropertyChanged, .msgSetupChanged:
        io.callbackQueue.async { io.delegate?.midiEndpointsChanged(io) }
    default:
        break
    }
}

/// MIDI read callback. Argument order per CoreMIDI: the first refCon is the
/// value passed to MIDIInputPortCreate (this instance); the second
/// (srcConnRefCon) is the value passed to MIDIPortConnectSource (a retained
/// NSString carrying the source name).
private let readProc: MIDIReadProc = { packetList, readRefCon, sourceRefCon in
    guard let packetList = packetList, let readRefCon = readRefCon,
          let sourceRefCon = sourceRefCon,
          let io = Unmanaged<RealMIDIIO>.fromOpaque(readRefCon).takeUnretainedValue()
    else { return }
    let name = unsafeBitCast(sourceRefCon, to: NSString.self) as String
    var packets: [MidiRouterCore.MIDIPacket] = []
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        packets.append(collectPacket(packet))
        packet = MIDIPacketNext(&packet).pointee
    }
    io.callbackQueue.async {
        io.delegate?.midi(io, source: name, received: packets)
    }
}

/// A MIDIPacket is a heterogeneous struct; copy `p.length` bytes out of the
/// fixed 256-byte `p.data` tuple.
private func collectPacket(_ p: MIDIPacket) -> MidiRouterCore.MIDIPacket {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(Int(p.length))
    for i in 0..<Int(p.length) {
        withUnsafeBytes(of: p.data) { raw in
            bytes.append(raw.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return MidiRouterCore.MIDIPacket(timestamp: p.timeStamp, bytes: bytes)
}
```

- [ ] **Step 2: `swift build` compiles clean**

Run: `swift build`
Expected: BUILD SUCCEEDED. If CoreMIDI SPI keyed-error appears for packet fields, verify `p.length: UInt16` mapping and the tuple subscripts; do not alter `MidiRouterCore`.

- [ ] **Step 3: Temporary endpoint enumerator smoke**

Temporarily replace `Sources/MidiRouterApp/main.swift` with a one-shot endpoint enumerator (this code is replaced again in Task 8's real main):

```swift
import Foundation
import MidiRouterCore

let io = RealMIDIIO()
print("SOURCES:      \(io.sourceNames())")
print("DESTINATIONS: \(io.destinationNames())")
RunLoop.main.run()
```

Run: `swift run` (Ctrl-C to exit)
Expected: prints real endpoint names present on this Mac (possibly empty).

- [ ] **Step 4: Commit**

```bash
git add Sources/MidiRouterApp/RealMIDIIO.swift Sources/MidiRouterApp/main.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: real CoreMIDI backend (enumerate, bind, send, read proc)"
```

Task 8 rewrites `main.swift` with the real app entry point.

---

### Task 8: SwiftUI app — popover, router matrix, presets, persistence

**Files:**
- Modify: `Sources/MidiRouterApp/main.swift`
- Create: `Sources/MidiRouterApp/MenuBarController.swift`
- Create: `Sources/MidiRouterApp/PopoverView.swift`
- Create: `Sources/MidiRouterApp/RouterView.swift`
- Create: `Sources/MidiRouterApp/Persistence.swift`

**Interfaces:**
- Consumes: `MIDIEngine`, `preset ops` (Tasks 5/6 + Task 3 helpers added here), `RealMIDIIO` (Task 7), `PresetStore` (Task 3).
- Produces: runnable app (`swift run`) — `main.swift` must end in `app.run()` without exiting early.

**Steps:**

- [ ] **Step 1: `Persistence.swift`** (full content)

```swift
import Foundation
import Combine
import MidiRouterCore

/// Debounced autosave of engine config + app-support directory helper.
/// Launch loads via PresetStore.load in main.swift (spec §persistence).
final class Persistence {
    private var cancellable: AnyCancellable?

    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("mac-midi-router", isDirectory: true)
    }

    init(engine: MIDIEngine, directory: URL) {
        cancellable = engine.$config
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { state in
                do {
                    try PresetStore.save(state, in: directory)
                } catch {
                    NSLog("PresetStore save failed: \(error)")
                }
            }
    }
}
```

- [ ] **Step 2: Extend `MIDIEngine` with the remaining UI-facing operations**

Add this block to `Sources/MidiRouterCore/MIDIEngine.swift`:

```swift
extension MIDIEngine {
    // MARK: Data for the matrix view

    public var matrixSources: [String] {
        Array(Set(io.sourceNames()).union(config.currentRoutes.map(\.source))).sorted()
    }

    public var matrixDestinations: [String] {
        let configured = Set(config.currentRoutes.flatMap { $0.destinations.map(\.name) })
        return Array(Set(io.destinationNames()).union(configured)).sorted()
    }

    public var matrixConnectedSources: Set<String> {
        connected.connectedSources
    }

    public var matrixConnectedDestinations: Set<String> {
        connected.connectedDestinations
    }

    // MARK: Grid-cell operations

    /// Cell edit: nil filter removes, `.all`/`.channel(n)` sets the route entry.
    public func setCell(source: String, dest: String, filter: ChannelFilter?) {
        mutateConfig { state in
            let routeIndex =
                state.currentRoutes.firstIndex(where: { $0.source == source })
            ?? {
                state.currentRoutes.append(Route(source: source, enabled: true))
                return state.currentRoutes.count - 1
            }()

            if let filter = filter {
                let destinations = state.currentRoutes[routeIndex].destinations
                if let destIndex = destinations.firstIndex(where: { $0.name == dest }) {
                    state.currentRoutes[routeIndex].destinations[destIndex].filter = filter
                } else {
                    state.currentRoutes[routeIndex].destinations
                        .append(Destination(name: dest, filter: filter))
                }
            } else if let destIndex = state.currentRoutes[routeIndex].destinations
                          .firstIndex(where: { $0.name == dest }) {
                state.currentRoutes[routeIndex].destinations.remove(at: destIndex)
            }
        }
    }

    public func cellLabel(source: String, dest: String) -> String {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.filter.label ?? "—"
    }

    // MARK: Presets (thin forwards into AppState, per spec §persistence)

    public func savePreset(as name: String) {
        mutateConfig { $0.savePreset(as: name) }
    }

    @discardableResult
    public func loadPreset(_ name: String) -> Bool {
        mutateConfig { $0.loadPreset(name) }
        return true
    }

    @discardableResult
    public func deletePreset(_ name: String) -> Bool {
        mutateConfig { $0.deletePreset(name) }
        return true
    }
}
```

- [ ] **Step 3: `main.swift`** (full content, replaces the Task 7 enumerator)

```swift
import AppKit
import MidiRouterCore

let supportDir = Persistence.supportDirectory
let engine = MIDIEngine(io: RealMIDIIO(), initialState: PresetStore.load(in: supportDir))
engine.performReconcile()                      // spec: reconcile on launch
let persistence = Persistence(engine: engine, directory: supportDir)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)            // menu bar only, no Dock icon
let controller = MenuBarController(engine: engine)
app.delegate = controller
controller.installStatusItem()
_ = persistence                                 // keeps dealloc sink alive for the run
app.run()
```

- [ ] **Step 4: `MenuBarController.swift`** (full content)

```swift
import AppKit
import SwiftUI
import MidiRouterCore

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let engine: MIDIEngine
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var routerWindow: NSWindow?

    init(engine: MIDIEngine) {
        self.engine = engine
        super.init()
        popover.contentSize = NSSize(width: 360, height: 340)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            engine: engine,
            openRouter: { [weak self] in self?.openRouterWindow() },
            closePopover: { [weak self] in self?.popover.performClose(nil) }
        ))
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.image = NSImage(systemSymbolName: "cable.audio",
                                     accessibilityDescription: "mac-midi-router")
        statusItem = item
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Called from the popover's "Open Router" button.
    func openRouterWindow() {
        if routerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                styleMask: [.titled, .resizable, .closable],
                backing: .buffered, defer: false)
            window.title = "MIDI Router"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RouterView(engine: engine))
            routerWindow = window
        }
        routerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 5: `PopoverView.swift`** (full content)

```swift
import SwiftUI
import MidiRouterCore

/// Quick route on/off + Open Router (spec §UI details).
struct PopoverView: View {
    @ObservedObject var engine: MIDIEngine
    let openRouter: () -> Void
    let closePopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(engine.config.currentRoutes, id: \.source) { route in
                HStack {
                    Toggle(route.source, isOn: Binding(
                        get: {
                            engine.config.currentRoutes
                                .first { $0.source == route.source }?.enabled ?? false
                        },
                        set: {
                            engine.setRouteEnabled(source: route.source, enabled: $0)
                        }))
                    .toggleStyle(.switch)
                    Spacer()
                    Text("\(route.destinations.count) →")
                        .foregroundStyle(.secondary)
                        .opacity(route.enabled ? 1 : 0.4)
                }
            }

            if engine.config.currentRoutes.isEmpty {
                Text("No routes yet — open the Router.")
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("Open Router…") {
                closePopover()
                openRouter()
            }
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 6: `RouterView.swift`** (full content)

```swift
import SwiftUI
import MidiRouterCore

/// Full matrix: sources × destinations (spec §UI details). Cell picker is the
/// ONLY way to create a routing: off / all / ch 1…16.
struct RouterView: View {
    @ObservedObject var engine: MIDIEngine
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 10) {
            if let warning = engine.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("").frame(width: 150, alignment: .leading)
                        ForEach(engine.matrixDestinations, id: \.self) { dest in
                            Text(dest)
                                .font(.footnote)
                                .frame(width: 70)
                                .lineLimit(1)
                        }
                    }
                    ForEach(engine.matrixSources, id: \.self) { source in
                        GridRow {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(engine.matrixConnectedSources.contains(source)
                                          ? .green : .gray)
                                    .frame(width: 8, height: 8)
                                Text(source)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 140, alignment: .leading)
                            }
                            ForEach(engine.matrixDestinations, id: \.self) { dest in
                                MatrixCell(engine: engine, source: source, dest: dest)
                            }
                        }
                    }
                }
                .padding()
            }

            HStack {
                TextField("Preset name", text: $presetName)
                    .frame(width: 220)
                Button("Save Preset") {
                    engine.savePreset(as: presetName)
                    presetName = ""
                }
                Menu("Load Preset") {
                    let names = engine.config.presets.keys.sorted()
                    if names.isEmpty { Text("None yet") }
                    ForEach(names, id: \.self) { name in
                        Button(name) { engine.loadPreset(name) }
                    }
                }
                Menu("Delete Preset") {
                    let names = engine.config.presets.keys.sorted()
                    if names.isEmpty { Text("None yet") }
                    ForEach(names, id: \.self) { name in
                        Button(name) { engine.deletePreset(name) }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

struct MatrixCell: View {
    @ObservedObject var engine: MIDIEngine
    let source: String
    let dest: String

    var body: some View {
        Menu {
            Button("off") {
                engine.setCell(source: source, dest: dest, filter: nil)
            }
            Button("all channels") {
                engine.setCell(source: source, dest: dest, filter: .all)
            }
            Divider()
            ForEach(1...16, id: \.self) { channel in
                Button("ch \(channel)") {
                    engine.setCell(source: source, dest: dest, filter: .channel(channel))
                }
            }
        } label: {
            Text(engine.cellLabel(source: source, dest: dest))
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 66, height: 22)
                .background(cellColor)
                .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
    }

    private var cellColor: Color {
        if engine.cellLabel(source: source, dest: dest) == "—" {
            return Color(nsColor: .controlBackgroundColor)
        }
        if !engine.matrixConnectedDestinations.contains(dest) {
            return .gray.opacity(0.45)             // configured, device missing
        }
        return .accentColor.opacity(0.7)           // routed + connected
    }
}
```

- [ ] **Step 7: Run full test suite and build**

Run: `swift test && swift build`
Expected: all tests PASS; BUILD SUCCEEDED. Run `swift run` briefly — the menu-bar icon should appear.

- [ ] **Step 8: Commit**

```bash
git add Sources/MidiRouterApp Sources/MidiRouterCore/MIDIEngine.swift
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "feat: menu bar app UI (popover, matrix, presets) with autosave persistence"
```

---

### Task 9: App bundle script + manual smoke checklist

**Files:**
- Create: `scripts/make-app.sh`
- Create: `docs/manual-smoke.md`

**Steps:**

- [ ] **Step 1: Create `scripts/make-app.sh`** (exactly this)

```sh
#!/bin/sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/mac-midi-router.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp build/release/MidiRouterApp "$APP/Contents/MacOS/mac-midi-router"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>mac-midi-router</string>
    <key>CFBundleIdentifier</key><string>local.mac-midi-router</string>
    <key>CFBundleExecutable</key><string>mac-midi-router</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
```

- [ ] **Step 2: Create `docs/manual-smoke.md`** (exactly this)

```markdown
# Manual smoke checklist (before release)

Run with real MIDI gear, or loopback sources (e.g. configure one hardware
controller plus IAC-style loopback software ports).

1. Launch app: menu-bar icon appears, no Dock icon.
2. Router window shows every current source/destination; missing gear shows a
   gray connected-dot.
3. Cell → "all channels": keys play on destination immediately.
4. Cell → "ch 5": ch-1 notes do NOT reach the destination, ch-5 notes do, and
   MIDI clock still flows (system messages always pass).
5. One source → two destinations: both get traffic.
   Two sources → one destination: merged, no drops.
6. Popover toggle OFF kills that route instantly; ON restores it.
7. Unplug a device: route stays listed, dot goes gray, no error spam.
   Re-plug: auto-reconnects, dot green, traffic resumes.
8. Rearrange ports (change USB order / different port index): routing is
   unchanged — because it is name-based.
9. Save preset "gig", change routes, load "gig": exactly the saved routes come
   back (current enabled flags kept). Delete removes it.
10. Relaunch: last configuration restored automatically without any manual save.
11. Duplicate port names show the ⚠️ warning banner.
```

- [ ] **Step 3: Run it all**

Run: `swift test && ./scripts/make-app.sh`
Expected: all tests PASS; script prints `Built build/mac-midi-router.app`.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-app.sh docs/manual-smoke.md
git -c user.name="Dr. OC" -c user.email="opencode@internal.local" commit -m "chore: app bundle script and manual smoke checklist"
```

---

## Task dependency graph

```
Task 1 (model) ─→ Task 2 (filter) ─→ Task 4 (MIDIIO + fake) ─→ Task 5 (reconcile) ─→ Task 6 (forward) ─┐
Task 1 ─→ Task 3 (presets) ─────────────────────────────────────────────────────────────────────────────┤
Task 4 ─→ Task 5 ─→ Task 6 ─→ Task 7 (RealMIDIIO) ─────────────────────────────────────────────────────┤
Task 8 (UI + persistence) needs 1 + 3 + 5 + 6 + 7 ─────────────────────────────────────────────────────┤
Task 9 (bundle + smoke) needs everything ───────────────────────────────────────────────────────────────┘
```

## Self-review summary

- **Spec coverage:** req.1/6 → Task 5/6 fan-out; req.2 → Task 2 filter kernel; req.3 → Task 5 reconcile + Task 6 `midiEndpointsChanged` + Task 7 notification proc; req.4 → Task 5 name-only binding + Task 7 name lookup; req.5 → Task 3 + Task 8 preset UIs; req.7 → Task 6 merge test; tests required by user → Tasks 1–6 TDD steps and manual checklist Task 9.
- **No placeholders** — every step carries final code (earlier draft sketch/duplicate-language remnants were removed).
- **Type consistency** — `FakeMIDIIO` arrays, `MIDIEngine.io` private, `mutateConfig` internal, task-visible interfaces documented per task.
