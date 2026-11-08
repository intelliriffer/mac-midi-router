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

/// Merge mode: rewrites the channel of every channel-voice message to
/// `channel` (1...16). System messages (0xF0+) carry no channel and pass
/// untouched. Data bytes are all < 0x80 so mapping only channel-status bytes
/// covers status-first wire messages without re-splitting.
public func rewriteToChannel(_ packet: MIDIPacket, _ channel: Int) -> MIDIPacket {
    let low = UInt8(channel - 1)
    let bytes = packet.bytes.map { b -> UInt8 in
        b.isChannelStatus ? (b & 0xF0) | low : b
    }
    return MIDIPacket(timestamp: packet.timestamp, bytes: bytes)
}
