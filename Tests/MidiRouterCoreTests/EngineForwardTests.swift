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

        XCTAssertEqual(io.receivedLog.count, 2)
        XCTAssertEqual(Set(io.receivedLog.map(\.to)), Set(["UM-1", "Bass"]))
        let um1 = io.receivedLog.last { $0.to == "UM-1" }!.packets
        XCTAssertEqual(um1.flatMap(\.bytes), [0x90, 0x3C, 0x40])
        let bass = io.receivedLog.last { $0.to == "Bass" }!.packets
        XCTAssertEqual(bass.flatMap(\.bytes), [0x90, 0x3C, 0x40, 0x95, 0x60, 0x60])
        _ = engine
    }

    func testDisabledRouteSwallowsTraffic() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: false,
                  destinations: [Destination(name: "UM-1", filter: .all)])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)
        _ = engine
    }

    func testUnboundSourceNeverDelivers() {
        let (io, engine) = boot([])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)
        _ = engine
    }

    func testAllFilteredOutDeliversNothing() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .channel(9))])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0x90, 0x3C, 0x40])])
        XCTAssertTrue(io.receivedLog.isEmpty)       // filtered out entirely → no send
        _ = engine
    }

    func testMergeTwoSourcesIntoOneDestination() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: true, destinations: [Destination(name: "IAC", filter: .all)]),
            Route(source: "Drums", enabled: true, destinations: [Destination(name: "IAC", filter: .all)])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0xC0, 0x00])])
        io.fakeSend(source: "Drums", packets: [MIDIPacket(bytes: [0xC1, 0x01])])
        XCTAssertEqual(io.receivedLog.filter { $0.to == "IAC" }.count, 2)
        _ = engine
    }

    func testSystemMessagesViaSingleChannelRoute() {
        let (io, engine) = boot([
            Route(source: "Keys", enabled: true, destinations: [
                Destination(name: "UM-1", filter: .channel(3))])])
        io.fakeSend(source: "Keys", packets: [MIDIPacket(bytes: [0xF8])])
        XCTAssertEqual(io.receivedLog.count, 1)
        XCTAssertEqual(io.receivedLog[0].to, "UM-1")
        XCTAssertEqual(io.receivedLog[0].packets.flatMap(\.bytes), [0xF8])
        _ = engine
    }
}
