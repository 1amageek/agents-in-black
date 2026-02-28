import Foundation

public enum AIBServiceKind: String, Codable, Sendable, Hashable {
    case agent
    case mcp
    case unknown
}
