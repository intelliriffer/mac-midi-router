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

    /// Toggling a source with no route is a no-op — the popover only controls
    /// routes that exist (routes are created from the matrix cells, never from
    /// the popover; ghost "enabled, zero destinations" rows are not allowed).
    public func setRouteEnabled(source: String, enabled: Bool) {
        mutateConfig { state in
            if let index = state.currentRoutes.firstIndex(where: { $0.source == source }) {
                state.currentRoutes[index].enabled = enabled
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
    /// configuration but shows as disconnected. Idempotent. The engine lock is
    /// never held across `io` calls: we take one snapshot at the start, run all
    /// CoreMIDI work unlocked, then take the lock again to commit results.
    public func performReconcile() {
        lock.lock()
        var routes = config.currentRoutes
        // Ghost-route sweep: a route with zero destinations does nothing and
        // must never linger (user feedback; popover no longer creates them).
        if routes.contains(where: { $0.destinations.isEmpty }) {
            routes.removeAll { $0.destinations.isEmpty }
            config = AppState(currentRoutes: routes, presets: config.presets)
        }
        let oldBoundSources = boundSources
        let oldBoundDestinations = boundDestinations
        lock.unlock()

        let presentSources = Set(io.sourceNames())
        let presentDestinations = Set(io.destinationNames())

        var wantSources: Set<String> = []
        var wantDestinations: Set<String> = []
        for route in routes where route.enabled {
            if presentSources.contains(route.source) {
                wantSources.insert(route.source)
            }
            for dest in route.destinations where presentDestinations.contains(dest.name) {
                wantDestinations.insert(dest.name)
            }
        }

        var nextBoundSources = oldBoundSources.intersection(wantSources)
        var nextBoundDestinations = oldBoundDestinations.intersection(wantDestinations)

        for name in oldBoundSources.subtracting(wantSources) {
            io.unbind(source: name)
        }
        // A failed bind is NOT recorded as bound/connected, so the next
        // reconcile retries it naturally.
        for name in wantSources.subtracting(oldBoundSources) {
            if io.bind(source: name) {
                nextBoundSources.insert(name)
            }
        }
        for name in oldBoundDestinations.subtracting(wantDestinations) {
            io.unbind(destination: name)
        }
        for name in wantDestinations.subtracting(oldBoundDestinations) {
            if io.bind(destination: name) {
                nextBoundDestinations.insert(name)
            }
        }

        lock.lock()
        boundSources = nextBoundSources
        boundDestinations = nextBoundDestinations
        connected = BindingState(connectedSources: nextBoundSources,
                                 connectedDestinations: nextBoundDestinations)
        lock.unlock()

        // @Published properties are written here and performReconcile() is
        // always called from the main actor (spec §threading); `connected`
        // is written under `lock` since midi(_:source:received:) reads it
        // on the CoreMIDI read thread.

        let dup = (duplicateSourceNames + duplicateDestinationNames).sorted()
        warning = dup.isEmpty ? nil : "Duplicate port names: \(dup.joined(separator: ", ")). First match wins."
    }
}

extension MIDIEngine: MIDIIODelegate {    /// Fan-out path. Runs on CoreMIDI's read thread (or the fake's call site):
    /// only reads immutable snapshots under `lock`, writes through `io.send`.
    public func midi(_ io: MIDIIO, source name: String, received packets: [MIDIPacket]) {
        lock.lock()
        let route = config.currentRoutes.first(where: { $0.source == name && $0.enabled })
        let connectedTargets = connected.connectedDestinations
        lock.unlock()
        guard let route = route else { return }

        for dest in route.destinations
              where connectedTargets.contains(dest.name) && dest.enabled {
            // Re-validate `merge` at the use-site: Codable decode bypasses
            // init-time validation, so disk contents can carry out-of-range
            // values. Bad values fall back to plain filter mode.
            let merge = dest.merge.flatMap(Destination.validateMerge)
            let filter: ChannelFilter = merge == nil ? dest.filter : .all
            var filtered: [MIDIPacket] = []
            filtered.reserveCapacity(packets.count)
            for pkt in packets {
                guard var kept = applyFilter(pkt, filter, suppressed: dest.suppressed) else { continue }
                if let merge = merge {
                    kept = rewriteToChannel(kept, merge)
                }
                filtered.append(kept)
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

extension MIDIEngine {
    // MARK: Data for the matrix view

    public var matrixSources: [String] {
        Array(Set(io.sourceNames()).union(config.currentRoutes.map(\.source))).sorted()
    }

    public var matrixDestinations: [String] {
        let configured = Set(config.currentRoutes.flatMap { $0.destinations.map(\.name) })
        return Array(Set(io.destinationNames()).union(configured)).sorted()
    }

    public var matrixConnectedSources: Set<String> {
        connected.connectedSources
    }

    public var matrixConnectedDestinations: Set<String> {
        connected.connectedDestinations
    }

    public func cellMerge(source: String, dest: String) -> Int? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.merge
    }

    // MARK: Grid-cell operations

    /// Cell edit: nil filter removes (clears both modes); `.all`/`.channel(n)`
    /// sets the route entry; merge != nil turns the cell into a merged mapping.
    public func setCell(source: String, dest: String, filter: ChannelFilter?, merge: Int? = nil) {
        mutateConfig { state in
            let routeIndex =
                state.currentRoutes.firstIndex(where: { $0.source == source })
            ?? {
                state.currentRoutes.append(Route(source: source, enabled: true))
                return state.currentRoutes.count - 1
            }()

            if let filter = filter {
                let merge = merge.flatMap(Destination.validateMerge)
                let destinations = state.currentRoutes[routeIndex].destinations
                if let destIndex = destinations.firstIndex(where: { $0.name == dest }) {
                    state.currentRoutes[routeIndex].destinations[destIndex].filter = filter
                    state.currentRoutes[routeIndex].destinations[destIndex].merge = merge
                    state.currentRoutes[routeIndex].destinations[destIndex].enabled = true
                } else {
                    state.currentRoutes[routeIndex].destinations
                        .append(Destination(name: dest, filter: filter, merge: merge))
                }
            } else if let destIndex = state.currentRoutes[routeIndex].destinations
                          .firstIndex(where: { $0.name == dest }) {
                state.currentRoutes[routeIndex].destinations.remove(at: destIndex)
            }
        }
    }

    public func cellLabel(source: String, dest: String) -> String {
        let d = config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })
        if let merge = d?.merge { return "M:\(merge)" }
        return d?.filter.label ?? "—"
    }

    /// Per-mapping mute state, for the popover; nil when no mapping exists.
    public func mappingEnabled(source: String, dest: String) -> Bool? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.enabled
    }

    /// Toggling a mapping that doesn't exist is a no-op (no creation — the
    /// popover only edits cells that already exist in the matrix).
    public func setMappingEnabled(source: String, dest: String, enabled: Bool) {
        mutateConfig { state in
            guard let routeIndex = state.currentRoutes.firstIndex(where: { $0.source == source }),
                  let destIndex = state.currentRoutes[routeIndex].destinations
                      .firstIndex(where: { $0.name == dest }) else { return }
            state.currentRoutes[routeIndex].destinations[destIndex].enabled = enabled
        }
    }

    /// Per-mapping suppressed message types, for the popover; nil when no
    /// mapping exists.
    public func mappingTypes(source: String, dest: String) -> Set<MessageType>? {
        config.currentRoutes.first(where: { $0.source == source })?
            .destinations.first(where: { $0.name == dest })?.suppressed
    }

    /// Editing the suppressed set of a mapping that doesn't exist is a no-op
    /// (no creation — the popover only edits cells that already exist in the
    /// matrix).
    public func setMappingTypes(source: String, dest: String, suppressed: Set<MessageType>) {
        mutateConfig { state in
            guard let routeIndex = state.currentRoutes.firstIndex(where: { $0.source == source }),
                  let destIndex = state.currentRoutes[routeIndex].destinations
                      .firstIndex(where: { $0.name == dest }) else { return }
            state.currentRoutes[routeIndex].destinations[destIndex].suppressed = suppressed
        }
    }

    // MARK: Presets (thin forwards into AppState, per spec §persistence)

    public func savePreset(as name: String) {
        mutateConfig { $0.savePreset(as: name) }
    }

    @discardableResult
    public func loadPreset(_ name: String) -> Bool {
        var ok = false
        mutateConfig { ok = $0.loadPreset(name) }
        return ok
    }

    @discardableResult
    public func deletePreset(_ name: String) -> Bool {
        var ok = false
        mutateConfig { ok = $0.deletePreset(name) }
        return ok
    }
}
