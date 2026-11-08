# Popover Per-Mapping Toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-mapping on/off inside the menu-bar popover (`2 →` becomes a toggle menu), persisted via a new `Destination.enabled` flag, with a light-red muted tint on the matrix cell.

**Architecture:** Add `enabled: Bool = true` to `Destination` (custom tolerant decode, old files = on); the engine's forward path skips disabled mappings and a new `setMappingEnabled` writes the flag; `PopoverView` renders per-source toggle menus; `MatrixCell` tints muted cells light red and appends `(muted)` to the tooltip.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 13+), SwiftPM, XCTest (`swift test`).

**Spec:** `docs/superpowers/specs/2026-11-08-popover-per-mapping-toggles-design.md`

## Global Constraints

- macOS 13+ target; Swift 5.9; SwiftPM only — no new dependencies.
- Back-compat: existing `state.json` and old presets must decode unchanged; missing `enabled` key decodes as `true`. New files readable by older builds (unknown key ignored).
- All existing tests must keep passing after each task; run full suite at the end of each task: `swift test`. Focused: `swift test --filter <Name>`.
- Do not run `scripts/build.sh` until the final task.
- The matrix keeps all existing visuals except the muted-cell tint and tooltip suffix; no new matrix menu entries.
- Popover master route switch semantics unchanged (route off ⇒ nothing flows for that source).

---

### Task 1: `Destination.enabled` data model + tolerant decode

**Files:**
- Modify: `Sources/MidiRouterCore/Model.swift:19-40` (Destination)
- Test: `Tests/MidiRouterCoreTests/ModelTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Destination.enabled: Bool` (default `true` in init; old JSON missing the key decodes as `true`), init signature `Destination(name:filter:merge:enabled:)` with `merge: Int? = nil`, `enabled: Bool = true` defaults. Later tasks read `.enabled` and construct destinations unchanged apart from the new defaults.

- [ ] **Step 1: Write the failing tests**

Append inside `final class ModelTests: XCTestCase` in `Tests/MidiRouterCoreTests/ModelTests.swift`:

```swift
    func testEnabledRoundTrip() throws {
        var d = Destination(name: "UM-1", filter: .all, merge: 7)
        XCTAssertEqual(d.enabled, true)
        d.enabled = false
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(Destination.self, from: data), d)
    }

    func testLegacyJSONWithoutEnabledDecodesTrue() throws {
        // On-disk shape today (synthesized enum Codable: {"all":{}}),
        // plus a merge key from the previous feature: no "enabled" at all.
        let json = """
        {"name":"UM-1","filter":{"all":{}},"merge":10}
        """
        let d = try JSONDecoder().decode(Destination.self, from: Data(json.utf8))
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.merge, 10)
    }

    func testExplicitEnabledDecodesFalse() throws {
        let json = """
        {"name":"UM-1","filter":{"all":{}},"enabled":false}
        """
        let d = try JSONDecoder().decode(Destination.self, from: Data(json.utf8))
        XCTAssertFalse(d.enabled)
        XCTAssertNil(d.merge)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelTests`
Expected: FAIL with compile error "value of type 'Destination' has no member 'enabled'".

- [ ] **Step 3: Implement**

In `Sources/MidiRouterCore/Model.swift` replace the `Destination` struct with:

```swift
public struct Destination: Codable, Equatable, Hashable {
    public var name: String
    public var filter: ChannelFilter
    public var merge: Int?
    public var enabled: Bool

    public init(name: String, filter: ChannelFilter, merge: Int? = nil, enabled: Bool = true) {
        self.name = name
        self.filter = filter
        self.merge = merge.flatMap(Self.validateMerge)
        self.enabled = enabled
    }

    public static func validateMerge(_ n: Int) -> Int? {
        (1...16).contains(n) ? n : nil
    }

    private enum CodingKeys: String, CodingKey { case name, filter, merge, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        filter = try c.decode(ChannelFilter.self, forKey: .filter)
        merge = try c.decodeIfPresent(Int.self, forKey: .merge)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
```

Note: with a custom `init(from:)`, the compiler still synthesizes `encode(to:)` for the remaining members; explicit `enabled` is always written, and older builds ignore the unknown key.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS (all ModelTests green).

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: PASS (no regression; existing call sites use the defaulted init params).

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/Model.swift Tests/MidiRouterCoreTests/ModelTests.swift
git commit -m "feat(model): per-mapping enabled flag with tolerant decode"
```

---

### Task 2: Engine — skip disabled mappings, `setMappingEnabled`, `setCell` reset

**Files:**
- Modify: `Sources/MidiRouterCore/MIDIEngine.swift` (forward path `midi(_:source:received:)`, `setCell`, new funcs near the cell-ops section)
- Test: `Tests/MidiRouterCoreTests/EngineForwardTests.swift`

**Interfaces:**
- Consumes: `Destination.enabled` from Task 1.
- Produces:
  - `public func setMappingEnabled(source: String, dest: String, enabled: Bool)` — no-op if the mapping doesn't exist (no creation).
  - `public func mappingEnabled(source: String, dest: String) -> Bool?` — nil when no mapping exists (UI accessor).
  - `setCell(source:dest:filter:merge:)` now also sets `enabled = true` on the update and append branches (fresh/re-set mapping is active).

- [ ] **Step 1: Write the failing tests**

Append inside `final class EngineForwardTests: XCTestCase`:

```swift
    func testDisabledMappingNotForwarded() {
        var route = Route(source: "Keys", enabled: true,
                          destinations: [Destination(name: "UM-1", filter: .all)])
        route.destinations[0].enabled = false      // construct-time mute (bypasses engine API)
        let (io, engine) = boot([route])
        io.fakeSend(source: "Keys", packets: [
            MIDIPacket(bytes: [0x90, 0x3C, 0x40]),
            MIDIPacket(bytes: [0xF8])])
        XCTAssertTrue(io.receivedLog.isEmpty)
        XCTAssertNil(engine.mappingEnabled(source: "Keys", dest: "Bass"))
        XCTAssertEqual(engine.mappingEnabled(source: "Keys", dest: "UM-1"), false)
        _ = engine
    }

    func testSetMappingEnabledRestoresForwarding() {
        var route = Route(source: "Keys", enabled: true,
                          destinations: [Destination(name: "UM-1", filter: .channel(2))])
        route.destinations[0].enabled = false
        let (io, engine) = boot([route])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x91, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)          // muted

        engine.setMappingEnabled(source: "Keys", dest: "UM-1", enabled: true)
        XCTAssertEqual(engine.mappingEnabled(source: "Keys", dest: "UM-1"), true)
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x91, 0x3C, 0x40])])
        XCTAssertEqual(io.receivedLog.count, 1)        // ch2 note-on passes again
        XCTAssertEqual(io.receivedLog.last!.packets.flatMap(\.bytes), [0x91, 0x3C, 0x40])
        _ = engine
    }

    func testSetCellResetsEnabledToTrue() {
        let (io, engine) = boot([])
        engine.setCell(source: "Keys", dest: "UM-1", filter: .all)
        engine.setMappingEnabled(source: "Keys", dest: "UM-1", enabled: false)
        XCTAssertEqual(engine.mappingEnabled(source: "Keys", dest: "UM-1"), false)

        engine.setCell(source: "Keys", dest: "UM-1", filter: .all, merge: 7)   // re-set resets
        XCTAssertEqual(engine.mappingEnabled(source: "Keys", dest: "UM-1"), true)
        XCTAssertEqual(engine.cellLabel(source: "Keys", dest: "UM-1"), "M:7")
        _ = io
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EngineForwardTests`
Expected: FAIL with compile error "has no member 'setMappingEnabled' / 'mappingEnabled'" (and test 1 fails on `XCTAssertNil(... "Bass")`? no — compile-first).

- [ ] **Step 3: Implement**

In `Sources/MidiRouterCore/MIDIEngine.swift`:

1. Forward path — change the destinations loop condition (currently
   `for dest in route.destinations where connectedTargets.contains(dest.name) {`)
   to include the mute check:

```swift
        for dest in route.destinations
              where connectedTargets.contains(dest.name) && dest.enabled {
```

2. Add to the Grid-cell operations section (after `cellMerge`):

```swift
    public func mappingEnabled(source: String, dest: String) -> Bool? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.enabled
    }

    public func setMappingEnabled(source: String, dest: String, enabled: Bool) {
        mutateConfig { state in
            guard let routeIndex = state.currentRoutes.firstIndex(where: { $0.source == source }),
                  let destIndex = state.currentRoutes[routeIndex].destinations
                      .firstIndex(where: { $0.name == dest }) else { return }
            state.currentRoutes[routeIndex].destinations[destIndex].enabled = enabled
        }
    }
```

3. In `setCell`, the update branch gains `enabled = true` reset:

```swift
                if let destIndex = destinations.firstIndex(where: { $0.name == dest }) {
                    state.currentRoutes[routeIndex].destinations[destIndex].filter = filter
                    state.currentRoutes[routeIndex].destinations[destIndex].merge = merge
                    state.currentRoutes[routeIndex].destinations[destIndex].enabled = true
                } else {
                    state.currentRoutes[routeIndex].destinations
                        .append(Destination(name: dest, filter: filter, merge: merge))
                }
```

(the else branch's `Destination(...)` already defaults `enabled: true`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EngineForwardTests`
Expected: PASS (all green incl. pre-existing tests like `testDisabledRouteSwallowsTraffic`).

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MidiRouterCore/MIDIEngine.swift Tests/MidiRouterCoreTests/EngineForwardTests.swift
git commit -m "feat(engine): per-mapping mute support in forward path and cell ops"
```

---

### Task 3: Popover toggle menu + muted cell tint

**Files:**
- Modify: `Sources/MidiRouterApp/PopoverView.swift` (routeListContent rows)
- Modify: `Sources/MidiRouterApp/RouterView.swift` (MatrixCell `cellColor` + tooltip only)
- Test: none new (SwiftUI); full suite + app build verify.

**Interfaces:**
- Consumes: `engine.mappingEnabled(source:dest:) -> Bool?`, `engine.setMappingEnabled(source:dest:enabled:)`, `engine.cellLabel(source:dest:)` from Tasks/earlier; `Destination.enabled` state.
- Produces: UI only.

- [ ] **Step 1: Implement the popover per-mapping menu**

In `Sources/MidiRouterApp/PopoverView.swift`, inside `routeListContent`, replace the trailing counter

```swift
                    Text("\(route.destinations.count) →")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(route.enabled ? 1 : 0.4)
                        .help("Route \"\(route.source)\" on/off")
```

with a menu of the source's mappings:

```swift
                    Menu {
                        if route.destinations.isEmpty {
                            Button("no mappings") { }
                                .disabled(true)
                        }
                        ForEach(route.destinations, id: \.name) { dest in
                            Toggle("\(dest.name) (\(engine.cellLabel(source: route.source, dest: dest.name)))",
                                   isOn: Binding(
                                       get: {
                                           engine.mappingEnabled(source: route.source, dest: dest.name) ?? false
                                       },
                                       set: {
                                           engine.setMappingEnabled(source: route.source,
                                                                    dest: dest.name, enabled: $0)
                                       }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!route.enabled)
                        }
                    } label: {
                        Text("\(route.destinations.count) →")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .opacity(route.enabled ? 1 : 0.4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Toggle mappings of \"\(route.source)\"")
```

- [ ] **Step 2: Implement the muted cell indication**

In `Sources/MidiRouterApp/RouterView.swift`, inside `MatrixCell` above `cellColor`:

```swift
    private var isMuted: Bool {
        engine.mappingEnabled(source: source, dest: dest) == false
    }
```

Replace `cellColor` with the muted branch inserted after the `isEmpty`/route-disabled cases:

```swift
    private var cellColor: Color {
        if isEmpty {
            return Color.primary.opacity(0.03)
        }
        if !routeEnabled {
            return .gray.opacity(0.2)              // route muted off in router
        }
        if isMuted {
            if !engine.matrixConnectedDestinations.contains(dest) {
                return .red.opacity(0.25)          // muted, device missing
            }
            return .red.opacity(0.45)              // muted
        }
        if !engine.matrixConnectedDestinations.contains(dest) {
            return isMerged ? .indigo.opacity(0.35) : .gray.opacity(0.45)   // configured, device missing
        }
        return isMerged ? .indigo.opacity(0.7) : .accentColor.opacity(0.7)  // routed + connected
    }
```

Add the tooltip suffix in the existing `.help(...)`:

```swift
            .help("\(source) → \(dest) · \(modeText)\(routeEnabled ? "" : " (route off)")\(isMuted ? " (muted)" : "")")
```

- [ ] **Step 3: Compile check**

Run: `swift build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Full suite + app bundle**

Run: `scripts/build.sh`
Expected: all tests pass, bundle at `build/mac-midi-router.app`.

Manual verification checklist (report what the checks would cover; no human present):
1. Popover: `2 →` opens a menu listing each mapping with a switch and label `dest (ch 3)` etc.
2. Toggling a mapping stops its traffic; toggling back restores; state survives relaunch (state.json).
3. Muted cell shows the light-red tint, tooltip shows `(muted)`.
4. Source master switch still mutes the whole source; menu entries disabled while the master is off.

- [ ] **Step 5: Commit**

```bash
git add Sources/MidiRouterApp/PopoverView.swift Sources/MidiRouterApp/RouterView.swift
git commit -m "feat(ui): per-mapping toggles in popover with muted cell tint"
```
