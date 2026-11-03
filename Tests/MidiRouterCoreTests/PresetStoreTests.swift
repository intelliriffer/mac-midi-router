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
