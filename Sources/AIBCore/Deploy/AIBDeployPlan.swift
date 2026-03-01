import Foundation

/// The complete deploy plan generated from workspace topology.
public struct AIBDeployPlan: Sendable, Identifiable {
    public let id: UUID
    public var timestamp: Date
    public var workspaceName: String
    public var targetConfig: AIBDeployTargetConfig
    public var services: [AIBDeployServicePlan]
    public var authBindings: [AIBDeployAuthBinding]
    public var warnings: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workspaceName: String,
        targetConfig: AIBDeployTargetConfig,
        services: [AIBDeployServicePlan],
        authBindings: [AIBDeployAuthBinding] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workspaceName = workspaceName
        self.targetConfig = targetConfig
        self.services = services
        self.authBindings = authBindings
        self.warnings = warnings
    }
}

/// Per-service deployment plan.
public struct AIBDeployServicePlan: Sendable, Identifiable {
    public let id: String
    public var serviceKind: AIBServiceKind
    public var runtime: String
    public var repoPath: String
    public var deployedServiceName: String
    public var region: String
    public var artifacts: AIBDeployArtifactSet
    public var resourceConfig: AIBDeployResourceConfig
    public var envVars: [String: String]
    public var connections: AIBDeployResolvedConnections
    public var isPublic: Bool

    public init(
        id: String,
        serviceKind: AIBServiceKind,
        runtime: String,
        repoPath: String,
        deployedServiceName: String,
        region: String,
        artifacts: AIBDeployArtifactSet,
        resourceConfig: AIBDeployResourceConfig = .init(),
        envVars: [String: String] = [:],
        connections: AIBDeployResolvedConnections = .init(),
        isPublic: Bool = false
    ) {
        self.id = id
        self.serviceKind = serviceKind
        self.runtime = runtime
        self.repoPath = repoPath
        self.deployedServiceName = deployedServiceName
        self.region = region
        self.artifacts = artifacts
        self.resourceConfig = resourceConfig
        self.envVars = envVars
        self.connections = connections
        self.isPublic = isPublic
    }
}
