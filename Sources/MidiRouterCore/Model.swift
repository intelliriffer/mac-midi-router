import Foundation

public enum ChannelFilter: Codable, Equatable, Hashable {
    case all
    case channel(Int)

    public static func validate(_ n: Int) -> ChannelFilter? {
        (1...16).contains(n) ? .channel(n) : nil
    }

    public var label: String {
        switch self {
        case .all: return "all"
        case .channel(let c): return "ch \(c)"
        }
    }
}

public struct Destination: Codable, Equatable, Hashable {
    public var name: String
    public var filter: ChannelFilter

    public init(name: String, filter: ChannelFilter) {
        self.name = name
        self.filter = filter
    }
}

public struct Route: Codable, Equatable, Hashable {
    public var source: String
    public var enabled: Bool
    public var destinations: [Destination]

    public init(source: String, enabled: Bool = true, destinations: [Destination] = []) {
        self.source = source
        self.enabled = enabled
        self.destinations = destinations
    }
}

public struct AppState: Codable, Equatable {
    public var currentRoutes: [Route]
    public var presets: [String: [Route]]

    public init(currentRoutes: [Route] = [], presets: [String: [Route]] = [:]) {
        self.currentRoutes = currentRoutes
        self.presets = presets
    }
}

public struct BindingState: Equatable {
    public var connectedSources: Set<String>
    public var connectedDestinations: Set<String>

    public init(connectedSources: Set<String> = [],
                connectedDestinations: Set<String> = []) {
        self.connectedSources = connectedSources
        self.connectedDestinations = connectedDestinations
    }
}
