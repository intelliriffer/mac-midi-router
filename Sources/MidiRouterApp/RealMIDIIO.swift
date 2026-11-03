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
    let callbackQueue = DispatchQueue(label: "mac-midi-router.readproc")

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
        (0..<MIDIGetNumberOfSources()).filter { n in
            MIDIGetSource(n) != 0
        }.map { self.endpointName(MIDIGetSource($0)) }.sorted().filter { !$0.isEmpty }
    }

    public func destinationNames() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).filter { n in
            MIDIGetDestination(n) != 0
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

    public func send(packets: [MidiRouterCore.MIDIPacket], to destination: String) {
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

private let notificationProc: MIDINotifyProc = { notification, refCon in
    guard let refCon = refCon else { return }
    let io = Unmanaged<RealMIDIIO>.fromOpaque(refCon).takeUnretainedValue()
    switch notification.pointee.messageID {
    case .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged, .msgSetupChanged:
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
    guard let readRefCon = readRefCon, let sourceRefCon = sourceRefCon else { return }
    let io = Unmanaged<RealMIDIIO>.fromOpaque(readRefCon).takeUnretainedValue()
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
private func collectPacket(_ p: CoreMIDI.MIDIPacket) -> MidiRouterCore.MIDIPacket {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(Int(p.length))
    for i in 0..<Int(p.length) {
        withUnsafeBytes(of: p.data) { raw in
            bytes.append(raw.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return MidiRouterCore.MIDIPacket(timestamp: p.timeStamp, bytes: bytes)
}
