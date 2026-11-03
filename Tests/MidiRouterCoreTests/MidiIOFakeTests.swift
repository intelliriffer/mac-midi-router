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
