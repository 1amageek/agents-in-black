import Foundation

public protocol AIBErrorPayload: Error, LocalizedError {
    var message: String { get }
    var metadata: [String: String] { get }
}

extension AIBErrorPayload {
    public var errorDescription: String? { message }
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
