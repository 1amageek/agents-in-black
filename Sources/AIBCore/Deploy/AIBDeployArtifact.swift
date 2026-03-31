import Foundation

/// A set of generated artifacts for a single service.
public struct AIBDeployArtifactSet: Sendable, Equatable {
    public var dockerfile: AIBDeployArtifact
    public var deployConfig: AIBDeployArtifact
    public var mcpConnectionConfig: AIBDeployArtifact?
    /// Skill bundle files projected into runtime-specific skill directories.
    public var skillConfigs: [AIBDeployArtifact]
    /// Claude Code plugin bundle files generated per agent service.
    public var claudeCodePluginArtifacts: [AIBDeployArtifact]
    /// Execution-directory agent files projected into `/app`.
    public var executionDirectoryConfigs: [AIBDeployArtifact]

    public init(
        dockerfile: AIBDeployArtifact,
        deployConfig: AIBDeployArtifact,
        mcpConnectionConfig: AIBDeployArtifact? = nil,
        skillConfigs: [AIBDeployArtifact] = [],
        claudeCodePluginArtifacts: [AIBDeployArtifact] = [],
        executionDirectoryConfigs: [AIBDeployArtifact] = []
    ) {
        self.dockerfile = dockerfile
        self.deployConfig = deployConfig
        self.mcpConnectionConfig = mcpConnectionConfig
        self.skillConfigs = skillConfigs
        self.claudeCodePluginArtifacts = claudeCodePluginArtifacts
        self.executionDirectoryConfigs = executionDirectoryConfigs
    }
}

/// A single generated deployment artifact with its content and origin.
public struct AIBDeployArtifact: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var relativePath: String
    public var content: Data
    public var source: AIBDeployArtifactSource

    public init(
        id: UUID = UUID(),
        relativePath: String,
        content: String,
        source: AIBDeployArtifactSource
    ) {
        self.init(
            id: id,
            relativePath: relativePath,
            content: Data(content.utf8),
            source: source
        )
    }

    public init(
        id: UUID = UUID(),
        relativePath: String,
        content: Data,
        source: AIBDeployArtifactSource
    ) {
        self.id = id
        self.relativePath = relativePath
        self.content = content
        self.source = source
    }

    public var utf8String: String? {
        String(data: content, encoding: .utf8)
    }
}

/// Where a deploy artifact originated from.
public enum AIBDeployArtifactSource: String, Sendable, Equatable {
    case generated
    case custom
}
