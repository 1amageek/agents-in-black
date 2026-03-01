import Foundation

/// Deployment target configuration.
/// Contains provider-agnostic resource defaults and provider-specific config in `providerConfig`.
public struct AIBDeployTargetConfig: Sendable, Equatable {
    /// Provider identifier (e.g., "gcp-cloudrun", "aws-ecs")
    public var providerID: String
    public var region: String
    public var defaultAuth: AIBDeployAuthMode
    public var defaultMemory: String
    public var defaultCPU: String
    public var defaultMaxInstances: Int
    public var defaultConcurrency: Int
    public var defaultTimeout: String
    /// Provider-specific key-value config (e.g., "gcpProject", "artifactRegistryHost")
    public var providerConfig: [String: String]

    public init(
        providerID: String,
        region: String,
        defaultAuth: AIBDeployAuthMode = .private,
        defaultMemory: String = "512Mi",
        defaultCPU: String = "1",
        defaultMaxInstances: Int = 10,
        defaultConcurrency: Int = 80,
        defaultTimeout: String = "300s",
        providerConfig: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.region = region
        self.defaultAuth = defaultAuth
        self.defaultMemory = defaultMemory
        self.defaultCPU = defaultCPU
        self.defaultMaxInstances = defaultMaxInstances
        self.defaultConcurrency = defaultConcurrency
        self.defaultTimeout = defaultTimeout
        self.providerConfig = providerConfig
    }
}

public enum AIBDeployAuthMode: String, Sendable, Equatable, Codable {
    case `private`
    case `public`
}
