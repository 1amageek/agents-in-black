import AIBConfig
import AIBRuntimeCore
import AIBWorkspace
import Foundation

public enum AIBWorkspaceCore {
    public static let workspaceDirectoryName = AIBWorkspaceManager.workspaceDirectoryName
    public static let workspaceConfigRelativePath = AIBWorkspaceManager.workspaceConfigRelativePath

    public static func initWorkspace(options: WorkspaceInitOptions) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.initWorkspace(options: options)
    }

    public static func initWorkspace(
        workspaceRoot: String,
        scanPath: String? = nil,
        force: Bool = false,
        scanEnabled: Bool = true
    ) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.initWorkspace(
            options: WorkspaceInitOptions(
                workspaceRoot: workspaceRoot,
                scanPath: scanPath ?? workspaceRoot,
                force: force,
                scanEnabled: scanEnabled
            )
        )
    }

    public static func loadWorkspace(workspaceRoot: String) throws -> AIBWorkspaceConfig {
        try AIBWorkspaceManager.loadWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func addRepo(workspaceRoot: String, repoURL: URL) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.addRepo(workspaceRoot: workspaceRoot, repoURL: repoURL)
    }

    public static func rescanWorkspace(workspaceRoot: String) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.rescanWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func syncWorkspace(workspaceRoot: String) throws -> WorkspaceSyncResult {
        try AIBWorkspaceManager.syncWorkspace(workspaceRoot: workspaceRoot)
    }

    public static func updateServiceMCPProfile(
        workspaceRoot: String,
        namespacedServiceID: String,
        path: String
    ) throws {
        try AIBWorkspaceManager.updateServiceMCPProfile(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID,
            path: path
        )
    }

    public static func updateServiceKind(
        workspaceRoot: String,
        namespacedServiceID: String,
        kind: String
    ) throws {
        try AIBWorkspaceManager.updateServiceKind(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID,
            kind: kind
        )
    }

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: ServiceConnectionsConfig]
    ) throws {
        try AIBWorkspaceManager.updateServiceConnections(
            workspaceRoot: workspaceRoot,
            connectionsByNamespacedServiceID: connectionsByNamespacedServiceID
        )
    }

    public static func configureServices(
        workspaceRoot: String,
        path: String,
        runtimes: [String]
    ) throws -> WorkspaceInitResult {
        let runtimeKinds = runtimes.compactMap { RuntimeKind(rawValue: $0) }
        guard !runtimeKinds.isEmpty else {
            throw ConfigError("No valid runtimes specified", metadata: ["runtimes": runtimes.joined(separator: ", ")])
        }
        return try AIBWorkspaceManager.configureServices(
            workspaceRoot: workspaceRoot,
            path: path,
            runtimes: runtimeKinds
        )
    }

    public static func removeService(
        workspaceRoot: String,
        namespacedServiceID: String
    ) throws -> WorkspaceInitResult {
        try AIBWorkspaceManager.removeService(
            workspaceRoot: workspaceRoot,
            namespacedServiceID: namespacedServiceID
        )
    }

    public static func updateRepoRuntime(
        workspaceRoot: String,
        repoPath: String,
        runtime: String
    ) throws -> WorkspaceInitResult {
        guard let runtimeKind = RuntimeKind(rawValue: runtime) else {
            throw ConfigError("Unknown runtime: \(runtime)", metadata: ["runtime": runtime])
        }
        return try AIBWorkspaceManager.updateRepoRuntime(
            workspaceRoot: workspaceRoot,
            repoPath: repoPath,
            runtime: runtimeKind
        )
    }

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: AIBServiceConnections]
    ) throws {
        let mapped = Dictionary(uniqueKeysWithValues: connectionsByNamespacedServiceID.map { key, value in
            (
                key,
                ServiceConnectionsConfig(
                    mcpServers: value.mcpServers.map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) },
                    a2aAgents: value.a2aAgents.map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }
                )
            )
        })
        try updateServiceConnections(
            workspaceRoot: workspaceRoot,
            connectionsByNamespacedServiceID: mapped
        )
    }
}
