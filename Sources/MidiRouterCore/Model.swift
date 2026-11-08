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

public enum MessageType: String, Codable, CaseIterable, Hashable {
    case note, cc, programChange, pitchBend, aftertouch, clock, sysex, systemCommon
}

public struct Destination: Codable, Equatable, Hashable {
    public var name: String
    public var filter: ChannelFilter
    public var merge: Int?
    public var enabled: Bool
    public var suppressed: Set<MessageType>

    public init(name: String, filter: ChannelFilter, merge: Int? = nil, enabled: Bool = true,
                suppressed: Set<MessageType> = []) {
        self.name = name
        self.filter = filter
        self.merge = merge.flatMap(Self.validateMerge)
        self.enabled = enabled
        self.suppressed = suppressed
    }

    public static func validateMerge(_ n: Int) -> Int? {
        (1...16).contains(n) ? n : nil
    }

    private enum CodingKeys: String, CodingKey { case name, filter, merge, enabled, suppressed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        filter = try c.decode(ChannelFilter.self, forKey: .filter)
        merge = try c.decodeIfPresent(Int.self, forKey: .merge)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        suppressed = try c.decodeIfPresent(Set<MessageType>.self, forKey: .suppressed) ?? []
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
