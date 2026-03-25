import Foundation

public enum AIBServiceKind: String, Codable, Sendable, Hashable, Identifiable {
    case agent
    case mcp
    case unknown

    public var id: String { rawValue }
}
