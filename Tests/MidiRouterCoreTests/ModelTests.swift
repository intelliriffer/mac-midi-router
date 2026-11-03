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
