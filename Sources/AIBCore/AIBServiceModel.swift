import Foundation

public struct AIBServiceModel: Identifiable, Hashable, Sendable {
    public let id: String
    public var repoID: String
    public var repoName: String
    public var localID: String
    public var namespacedID: String
    public var mountPath: String
    public var runCommand: [String]
    public var watchMode: String?
    public var cwd: String?
    public var serviceKind: AIBServiceKind
    public var connections: AIBServiceConnections
    public var mcpProfile: AIBMCPProfile?
    public var a2aProfile: AIBA2AProfile?
    public var uiProfile: AIBServiceUIProfile?
    /// Display name derived from the package manifest (e.g., package.json "name", Package.swift executableTarget name).
    /// Falls back to `localID` when not available.
    public var packageName: String?
    /// Deployed endpoint URLs keyed by provider ID (e.g., `"gcp-cloudrun": "https://...run.app"`).
    public var endpoints: [String: String]
    /// Skill IDs assigned to this service. References workspace-level skill definitions.
    public var assignedSkillIDs: [String]
    /// Skill IDs discovered directly under the execution directory (e.g. `.claude/skills`).
    public var nativeSkillIDs: [String]
    /// Absolute path of the execution directory mounted as `/app` for local runtime.
    public var executionDirectoryPath: String?
    /// Relevant agent-runtime files discovered under the execution directory.
    public var executionDirectoryEntries: [AIBExecutionDirectoryEntry]

    public init(
        repoID: String,
        repoName: String,
        localID: String,
        namespace: String,
        mountPath: String,
        runCommand: [String],
        watchMode: String?,
        cwd: String?,
        serviceKind: AIBServiceKind = .unknown,
        connections: AIBServiceConnections = .init(),
        mcpProfile: AIBMCPProfile? = nil,
        a2aProfile: AIBA2AProfile? = nil,
        uiProfile: AIBServiceUIProfile? = nil,
        packageName: String? = nil,
        endpoints: [String: String] = [:],
        assignedSkillIDs: [String] = [],
        nativeSkillIDs: [String] = [],
        executionDirectoryPath: String? = nil,
        executionDirectoryEntries: [AIBExecutionDirectoryEntry] = []
    ) {
        self.repoID = repoID
        self.repoName = repoName
        self.localID = localID
        self.namespacedID = "\(namespace)/\(localID)"
        self.id = "\(repoID)::\(localID)"
        self.mountPath = mountPath
        self.runCommand = runCommand
        self.watchMode = watchMode
        self.cwd = cwd
        self.serviceKind = serviceKind
        self.connections = connections
        self.mcpProfile = mcpProfile
        self.a2aProfile = a2aProfile
        self.uiProfile = uiProfile
        self.packageName = packageName
        self.endpoints = endpoints
        self.assignedSkillIDs = assignedSkillIDs
        self.nativeSkillIDs = nativeSkillIDs
        self.executionDirectoryPath = executionDirectoryPath
        self.executionDirectoryEntries = executionDirectoryEntries
    }
}
