import Foundation
import Combine

/// Central routing engine.
///
/// Threading model (spec §threading): all *mutation* of `config` happens on the
/// main actor (UI callbacks / reconcile calls), all *reads* from the MIDI read
/// thread pass through `lock`, so the callback never races a concurrently
/// saving/preset-loading path. `performReconcile()` is idempotent and always
/// called from the main actor.
final public class MIDIEngine: ObservableObject {
    private let io: MIDIIO
    private let lock = NSLock()
    private var boundSources: Set<String> = []
    private var boundDestinations: Set<String> = []

    @Published public private(set) var config: AppState
    @Published public private(set) var connected: BindingState = BindingState()
    @Published public private(set) var warning: String?

    public init(io: MIDIIO, initialState: AppState = .init()) {
        self.io = io
        self.config = initialState
        io.delegate = self
    }

    // MARK: Configuration edits (main thread only)

    public func setRoutes(_ routes: [Route]) {
        mutateConfig { $0.currentRoutes = routes }
    }

    /// Toggling an unknown source on creates an enabled route for it,
    /// which matches the popover's checkbox semantics.
    public func setRouteEnabled(source: String, enabled: Bool) {
        mutateConfig { state in
            if let index = state.currentRoutes.firstIndex(where: { $0.source == source }) {
                state.currentRoutes[index].enabled = enabled
            } else if enabled {
                state.currentRoutes.append(Route(source: source, enabled: true))
            }
        }
    }

    public func setRoute(source: String, destinations: [Destination]) {
        mutateConfig { state in
            if let index = state.currentRoutes.firstIndex(where: { $0.source == source }) {
                state.currentRoutes[index].destinations = destinations
            } else {
                state.currentRoutes.append(
                    Route(source: source, enabled: true, destinations: destinations))
            }
        }
    }

    public var duplicateSourceNames: [String] {
        duplicates(in: io.sourceNames())
    }

    public var duplicateDestinationNames: [String] {
        duplicates(in: io.destinationNames())
    }

    private func duplicates(in names: [String]) -> [String] {
        Dictionary(grouping: names, by: { $0 })
            .filter { $1.count > 1 }
            .keys
            .sorted()
    }

    internal func mutateConfig(_ mutate: (inout AppState) -> Void) {
        lock.lock()
        var state = config
        mutate(&state)
        lock.unlock()
        config = state
        performReconcile()
    }

    // MARK: Reconcile

    /// Single binding algorithm (spec §hotplug): everything configured and
    /// currently present gets re-bound; everything not present keeps its
    /// configuration but shows as disconnected. Idempotent.
    public func performReconcile() {
        lock.lock(); defer { lock.unlock() }

        let presentSources = Set(io.sourceNames())
        let presentDestinations = Set(io.destinationNames())

        var wantSources: Set<String> = []
        var wantDestinations: Set<String> = []
        for route in config.currentRoutes where route.enabled {
            if presentSources.contains(route.source) {
                wantSources.insert(route.source)
            }
            for dest in route.destinations where presentDestinations.contains(dest.name) {
                wantDestinations.insert(dest.name)
            }
        }

        for name in boundSources.subtracting(wantSources) {
            io.unbind(source: name)
        }
        for name in wantSources.subtracting(boundSources) {
            _ = io.bind(source: name)
        }
        for name in boundDestinations.subtracting(wantDestinations) {
            io.unbind(destination: name)
        }
        for name in wantDestinations.subtracting(boundDestinations) {
            _ = io.bind(destination: name)
        }
        boundSources = wantSources
        boundDestinations = wantDestinations

        let next = BindingState(connectedSources: wantSources,
                                connectedDestinations: wantDestinations)
        connected = next

        let dup = (duplicateSourceNames + duplicateDestinationNames).sorted()
        warning = dup.isEmpty ? nil : "Duplicate port names: \(dup.joined(separator: ", ")). First match wins."
    }
}

extension MIDIEngine: MIDIIODelegate {
    /// Fan-out path. Runs on CoreMIDI's read thread (or the fake's call site):
    /// only reads immutable snapshots under `lock`, writes through `io.send`.
    public func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]) {
        lock.lock()
        var route: Route?
        for r in config.currentRoutes where r.source == name && r.enabled {
            route = r
        }
        let connectedTargets = connected.connectedDestinations
        lock.unlock()
        guard let route = route else { return }

        for dest in route.destinations where connectedTargets.contains(dest.name) {
            var filtered: [MIDIPacket] = []
            filtered.reserveCapacity(packets.count)
            for pkt in packets {
                if let kept = applyFilter(pkt, dest.filter) {
                    filtered.append(kept)
                }
            }
            guard !filtered.isEmpty else { continue }
            io.send(packets: filtered, to: dest.name)
        }
    }

    /// Endpoint hotplug: CoreMIDI gives us the event, we just re-run the single
    /// reconciler on the main actor (spec §hotplug: same code path as cold start).
    public func midiEndpointsChanged(_ io: MIDIIO) {
        DispatchQueue.main.async { [weak self] in self?.performReconcile() }
    }
}
