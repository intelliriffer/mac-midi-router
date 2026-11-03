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
    // Guards inputPorts/outputPorts/connectionBoxes: mutated on the main
    // thread (bind/unbind) and read from the CoreMIDI read thread (send()).
    private let midiLock = NSLock()
    private var inputPorts: [String: MIDIPortRef] = [:]
    private var outputPorts: [String: MIDIPortRef] = [:]
    // MIDIPortConnectSource's per-connection refCon carries the source name;
    // we retain an NSString for each connection for as long as it exists.
    private var connectionBoxes: [String: Unmanaged<NSString>] = [:]
    let callbackQueue = DispatchQueue(label: "mac-midi-router.readproc")

    public override init() {
        super.init()
        var client = self.client
        let status = MIDIClientCreate("mac-midi-router" as CFString,
                                      notificationProc,
                                      Unmanaged.passUnretained(self).toOpaque(),
                                      &client)
        if status != noErr {
            // CoreMIDI client creation failed: keep client at 0 so every
            // subsequent bind call fails and ports stay disconnected.
            NSLog("RealMIDIIO: MIDIClientCreate failed (OSStatus %d) — binds will fail")
            client = 0
        }
        self.client = client
    }

    deinit {
        midiLock.lock()
        let inputs = inputPorts
        let outputs = outputPorts
        let boxes = connectionBoxes
        inputPorts = [:]
        outputPorts = [:]
        connectionBoxes = [:]
        midiLock.unlock()
        for (_, port) in inputs { MIDIPortDispose(port) }
        for (_, port) in outputs { MIDIPortDispose(port) }
        for (_, box) in boxes { box.release() }
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
        midiLock.lock()
        defer { midiLock.unlock() }
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
        midiLock.lock()
        defer { midiLock.unlock() }
        guard outputPorts[name] == nil else { return true }   // idempotent
        var port: MIDIPortRef = 0
        guard MIDIOutputPortCreate(client, name as CFString, &port) == noErr
        else { return false }
        outputPorts[name] = port
        return true
    }

    public func unbind(source name: String) {
        midiLock.lock()
        defer { midiLock.unlock() }
        if let port = inputPorts.removeValue(forKey: name) {
            MIDIPortDispose(port)
        }
        connectionBoxes.removeValue(forKey: name)?.release()
    }

    public func unbind(destination name: String) {
        midiLock.lock()
        defer { midiLock.unlock() }
        if let port = outputPorts.removeValue(forKey: name) {
            MIDIPortDispose(port)
        }
    }

    // MARK: Sending

    public func send(packets: [MidiRouterCore.MIDIPacket], to destination: String) {
        // Snapshot the port + endpoint under the lock into locals, then release
        // before building/sending: MIDISend must never run while midiLock is
        // held (it can block and the read thread may be waiting).
        midiLock.lock()
        let foundPort = outputPorts[destination]
        let endpoint = destinationEndpointRef(named: destination)
        midiLock.unlock()
        guard let port = foundPort, let endpoint = endpoint else { return }

        // Build the packet list in a properly sized heap buffer (max packet
        // list size), never in a stack struct claiming 64 KiB capacity.
        let capacity = 65536
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { buffer.deallocate() }
        let list = buffer.assumingMemoryBound(to: MIDIPacketList.self)
        var cursor = MIDIPacketListInit(list)
        for packet in packets {
            let next: UnsafeMutablePointer<CoreMIDI.MIDIPacket>? =
                MIDIPacketListAdd(list, capacity, cursor,
                                  packet.timestamp,
                                  packet.bytes.count,
                                  packet.bytes)
            guard let next = next else {
                // List is full: drop the remainder silently (defensive; one
                // list never legitimately exceeds 64 KiB).
                break
            }
            cursor = next
        }
        MIDISend(port, endpoint, list)
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
    // Walk the packets IN THE ORIGINAL list: MIDIPacketNext(p) advances within
    // the caller's variable-length memory, so the walk pointer must move over
    // the real bytes of packetList — never over a local struct copy.
    if let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) {
        var p = UnsafeRawPointer(packetList).advanced(by: packetOffset)
        for _ in 0..<Int(packetList.pointee.numPackets) {
            let pkt = p.assumingMemoryBound(to: CoreMIDI.MIDIPacket.self)
            packets.append(collectPacket(pkt.pointee))
            p = UnsafeRawPointer(MIDIPacketNext(pkt))
        }
    }
    io.callbackQueue.async {
        io.delegate?.midi(io, source: name, received: packets)
    }
}

/// A MIDIPacket is a heterogeneous struct; copy `p.length` bytes out of the
/// fixed data tuple, clamping the length field so a malformed packet can never
/// read past the 256 data bytes.
private func collectPacket(_ p: CoreMIDI.MIDIPacket) -> MidiRouterCore.MIDIPacket {
    let dataBytes = MemoryLayout.size(ofValue: p.data)
    let n = min(Int(p.length), dataBytes)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(n)
    for i in 0..<n {
        withUnsafeBytes(of: p.data) { raw in
            bytes.append(raw.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return MidiRouterCore.MIDIPacket(timestamp: p.timeStamp, bytes: bytes)
}
