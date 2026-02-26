import Foundation

public protocol AIBErrorPayload: Error {
    var message: String { get }
    var metadata: [String: String] { get }
}

public struct ConfigError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public struct ValidationError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public struct UnsupportedFeatureError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public struct ProcessSpawnError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public struct ReloadApplyError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}

public struct GatewayRoutingError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]
    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}
