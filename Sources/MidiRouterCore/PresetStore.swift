import Foundation

public enum PresetStore {
    public static func stateURL(in dir: URL) -> URL {
        dir.appendingPathComponent("state.json")
    }

    public static func save(_ state: AppState, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL(in: dir), options: [.atomic])
    }

    /// Missing or corrupt files yield an empty state — the app never crashes
    /// on bad disk contents (spec: "corrupt file → log it, start empty").
    public static func load(in dir: URL) -> AppState {
        guard let data = try? Data(contentsOf: stateURL(in: dir)),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else {
            NSLog("PresetStore: state.json missing or corrupt — starting empty")
            return AppState()
        }
        var clean = state
        // Sanitize persisted routes: disk contents may still carry duplicate
        // source entries; collapse them keeping the FIRST ("first match wins").
        var seen = Set<String>()
        clean.currentRoutes = clean.currentRoutes.filter { seen.insert($0.source).inserted }
        return clean
    }
}

public extension AppState {
    /// Snapshot the current routes under a preset name. Empty names rejected.
    @discardableResult
    mutating func savePreset(as name: String) -> Bool {
        guard !name.isEmpty else { return false }
        presets[name] = currentRoutes          // value-type snapshot copy
        return true
    }

    /// Replace current routes with the named preset's routes, keeping each
    /// currently-known source's enabled flag (day-to-day on/off survives loads).
    @discardableResult
    mutating func loadPreset(_ name: String) -> Bool {
        guard let routes = presets[name] else { return false }
        // Duplicate sources in currentRoutes are possible (hand-edited or older
        // state); "first match wins" — keep the FIRST entry's flag, never trap.
        let currentFlags = Dictionary(
            currentRoutes.map { ($0.source, $0.enabled) },
            uniquingKeysWith: { first, _ in first })
        currentRoutes = routes.map { route in
            var r = route
            if let flag = currentFlags[r.source] { r.enabled = flag }
            return r
        }
        return true
    }

    @discardableResult
    mutating func deletePreset(_ name: String) -> Bool {
        presets.removeValue(forKey: name) != nil
    }
}
