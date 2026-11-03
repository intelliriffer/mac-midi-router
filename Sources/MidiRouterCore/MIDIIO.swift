import Foundation

public protocol MIDIIODelegate: AnyObject {
    func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket])
    func midiEndpointsChanged(_ io: MIDIIO)
}

public protocol MIDIIO: AnyObject {
    var delegate: MIDIIODelegate? { get set }
    func sourceNames() -> [String]
    func destinationNames() -> [String]
    @discardableResult func bind(source: String) -> Bool
    @discardableResult func bind(destination: String) -> Bool
    func unbind(source: String)
    func unbind(destination: String)
    func send(packets: [MIDIPacket], to destination: String)
}

/// Dictionary-backed MIDI test double. All deliveries are synchronous.
/// Endpoint lists are arrays so duplicate-name scenarios stay drivable.
public final class FakeMIDIIO: MIDIIO {
    public struct MIDIOutEvent: Equatable {
        public let to: String
        public let packets: [MIDIPacket]

        public init(to: String, packets: [MIDIPacket]) {
            self.to = to
            self.packets = packets
        }
    }

    public weak var delegate: MIDIIODelegate?
    public private(set) var receivedLog: [MIDIOutEvent] = []
    public private(set) var sourceBindings: Set<String> = []
    public private(set) var destinationBindings: Set<String> = []
    private var sources: [String]
    private var destinations: [String]

    public init(presentSources: [String] = [], presentDestinations: [String] = []) {
        self.sources = presentSources
        self.destinations = presentDestinations
    }

    public func sourceNames() -> [String] { sources.sorted() }
    public func destinationNames() -> [String] { destinations.sorted() }

    @discardableResult public func bind(source: String) -> Bool {
        guard sources.contains(source) else { return false }
        sourceBindings.insert(source)
        return true
    }

    @discardableResult public func bind(destination: String) -> Bool {
        guard destinations.contains(destination) else { return false }
        destinationBindings.insert(destination)
        return true
    }

    public func unbind(source name: String) {
        sourceBindings.remove(name)
    }

    public func unbind(destination name: String) {
        destinationBindings.remove(name)
    }

    public func send(packets: [MIDIPacket], to destination: String) {
        receivedLog.append(MIDIOutEvent(to: destination, packets: packets))
    }

    // MARK: Test-driven hardware SIMULATION endpoints

    public func fakePlugSource(_ name: String) {
        sources.append(name)
        delegate?.midiEndpointsChanged(self)
    }

    public func fakePlugDestination(_ name: String) {
        destinations.append(name)
        delegate?.midiEndpointsChanged(self)
    }

    public func fakeUnplug(_ name: String) {
        sources.removeAll { $0 == name }
        destinations.removeAll { $0 == name }
        delegate?.midiEndpointsChanged(self)
    }

    /// Deliver packets into the engine exactly like a real read callback would
    /// — but only if that source is currently bound (unbound ports emit nothing).
    public func fakeSend(source: String, packets: [MIDIPacket]) {
        guard sourceBindings.contains(source) else { return }
        delegate?.midi(self, source: source, received: packets)
    }
}
