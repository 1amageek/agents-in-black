import AIBConfig
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

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: ServiceConnectionsConfig]
    ) throws {
        try AIBWorkspaceManager.updateServiceConnections(
            workspaceRoot: workspaceRoot,
            connectionsByNamespacedServiceID: connectionsByNamespacedServiceID
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
