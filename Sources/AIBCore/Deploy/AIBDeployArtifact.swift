import Foundation

/// A set of generated artifacts for a single service.
public struct AIBDeployArtifactSet: Sendable, Equatable {
    public var dockerfile: AIBDeployArtifact
    public var deployConfig: AIBDeployArtifact
    public var mcpConnectionConfig: AIBDeployArtifact?

    public init(
        dockerfile: AIBDeployArtifact,
        deployConfig: AIBDeployArtifact,
        mcpConnectionConfig: AIBDeployArtifact? = nil
    ) {
        self.dockerfile = dockerfile
        self.deployConfig = deployConfig
        self.mcpConnectionConfig = mcpConnectionConfig
    }
}

/// A single generated deployment artifact with its content and origin.
public struct AIBDeployArtifact: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var relativePath: String
    public var content: String
    public var source: AIBDeployArtifactSource

    public init(
        id: UUID = UUID(),
        relativePath: String,
        content: String,
        source: AIBDeployArtifactSource
    ) {
        self.id = id
        self.relativePath = relativePath
        self.content = content
        self.source = source
    }
}

/// Where a deploy artifact originated from.
public enum AIBDeployArtifactSource: String, Sendable, Equatable {
    case generated
    case custom
}
