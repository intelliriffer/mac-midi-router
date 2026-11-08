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
        // Brief used [0x91, ...] with .channel(2), but 0x91 = ch2 per the brief's own
        // convention and would be kept; ch1 note-on filtered for ch2 drops fully.
        XCTAssertNil(applyFilter(pkt([0x90, 0x3C, 0x7F]), .channel(2)))
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
}
