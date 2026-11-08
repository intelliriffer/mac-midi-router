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

    func testMergeCodableRoundTrip() throws {
        let route = Route(
            source: "Keys", enabled: true,
            destinations: [Destination(name: "UM-1", filter: .all, merge: 10)])
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(Route.self, from: data), route)
    }

    func testLegacyJSONWithoutMergeDecodesToNil() throws {
        // Shape of the JSON the app writes today (no "merge" key). The filter
        // channel uses the synthesized Codable form for enum cases with an
        // associated value ("_0" payload key), matching real state.json files.
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

    func testInitNullsInvalidMerge() {
        XCTAssertNil(Destination(name: "UM-1", filter: .all, merge: 0).merge)
        XCTAssertNil(Destination(name: "UM-1", filter: .all, merge: 17).merge)
        XCTAssertEqual(Destination(name: "UM-1", filter: .all, merge: 16).merge, 16)
    }

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
}
