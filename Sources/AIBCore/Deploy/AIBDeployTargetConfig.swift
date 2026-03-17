import Foundation

/// Deployment target configuration.
/// Contains provider-agnostic resource defaults and provider-specific config in `providerConfig`.
public struct AIBDeployTargetConfig: Sendable, Equatable {
    /// Provider identifier (e.g., "gcp-cloudrun", "aws-ecs")
    public var providerID: String
    public var region: String
    public var defaultAuth: AIBDeployAuthMode
    /// Per-kind resource overrides. When a kind has no entry, `AIBDeployResourceConfig.defaults(for:)` is used.
    public var kindDefaults: [AIBServiceKind: AIBDeployResourceConfig]
    /// Provider-specific key-value config (e.g., "gcpProject", "artifactRegistryHost")
    public var providerConfig: [String: String]

    public init(
        providerID: String,
        region: String,
        defaultAuth: AIBDeployAuthMode = .private,
        kindDefaults: [AIBServiceKind: AIBDeployResourceConfig] = [:],
        providerConfig: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.region = region
        self.defaultAuth = defaultAuth
        self.kindDefaults = kindDefaults
        self.providerConfig = providerConfig
    }

    /// Resolve resource configuration for a given service kind.
    /// Returns user override if present, otherwise kind-aware smart defaults.
    public func resourceConfig(for kind: AIBServiceKind) -> AIBDeployResourceConfig {
        kindDefaults[kind] ?? .defaults(for: kind)
    }
}

public enum AIBDeployAuthMode: String, Sendable, Equatable, Codable {
    case `private`
    case `public`
}
