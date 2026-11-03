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

    func testEnabledToggleOnUnknownSourceIsANoOp() {
        let io = FakeMIDIIO(presentSources: ["K88"], presentDestinations: ["UM-1"])
        let engine = boot(io: io, [])
        engine.setRouteEnabled(source: "K88", enabled: true)
        XCTAssertTrue(engine.config.currentRoutes.isEmpty)   // no ghost routes
        XCTAssertTrue(io.sourceBindings.isEmpty)
    }

    func testReconcilePurgesExistingGhostRoutes() {
        let io = FakeMIDIIO(presentSources: [], presentDestinations: [])
        let engine = MIDIEngine(io: io, initialState: AppState(
            currentRoutes: [Route(source: "Ghost", enabled: true)]))
        engine.performReconcile()
        XCTAssertTrue(engine.config.currentRoutes.isEmpty)   // sweep removes them
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
