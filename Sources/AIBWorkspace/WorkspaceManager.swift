import AIBRuntimeCore
import AIBConfig
import Foundation
import Yams

public enum AIBWorkspaceManager {
    public static let workspaceDirectoryName = ".aib"
    public static let workspaceConfigRelativePath = ".aib/workspace.yaml"

    public static func initWorkspace(options: WorkspaceInitOptions) throws -> WorkspaceInitResult {
        let workspaceRoot = URL(fileURLWithPath: options.workspaceRoot).standardizedFileURL.path
        let workspaceDir = URL(fileURLWithPath: workspaceDirectoryName, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        let workspaceConfigPath = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path

        let existingConfig: AIBWorkspaceConfig?
        if FileManager.default.fileExists(atPath: workspaceConfigPath) {
            if !options.force {
                throw ConfigError("Workspace already initialized", metadata: ["path": workspaceConfigPath])
            }
            existingConfig = try WorkspaceYAMLCodec.loadWorkspace(at: workspaceConfigPath)
        } else {
            existingConfig = nil
        }

        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "state", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "logs", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "environments", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: "targets", relativeTo: URL(fileURLWithPath: workspaceDir)).path, withIntermediateDirectories: true)

        let workspaceName = existingConfig?.workspaceName ?? URL(fileURLWithPath: workspaceRoot).lastPathComponent
        let repos = options.scanEnabled ? try WorkspaceDiscovery.discoverRepos(workspaceRoot: workspaceRoot, scanPath: options.scanPath) : []
        var workspace = AIBWorkspaceConfig(workspaceName: workspaceName, repos: repos)

        // Merge with existing config to preserve user-configured services,
        // connections, UI settings, and gateway config.
        if let existing = existingConfig {
            workspace = merge(existing: existing, discovered: workspace.repos)
        }

        try WorkspaceYAMLCodec.saveWorkspace(workspace, to: workspaceConfigPath)
        try ensureEnvironmentTemplates(workspaceRoot: workspaceRoot)
        try ensureTargetTemplates(workspaceRoot: workspaceRoot)
        try ensureGitignoreEntries(workspaceRoot: workspaceRoot)

        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func loadWorkspace(workspaceRoot: String) throws -> AIBWorkspaceConfig {
        let path = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        return try WorkspaceYAMLCodec.loadWorkspace(at: path)
    }

    public static func saveWorkspace(_ workspace: AIBWorkspaceConfig, workspaceRoot: String) throws {
        let path = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        try WorkspaceYAMLCodec.saveWorkspace(workspace, to: path)
    }

    public static func rescanWorkspace(workspaceRoot: String) throws -> WorkspaceInitResult {
        let existing = try loadWorkspace(workspaceRoot: workspaceRoot)
        let discovered = try WorkspaceDiscovery.discoverRepos(workspaceRoot: workspaceRoot, scanPath: workspaceRoot)
        let merged = merge(existing: existing, discovered: discovered)
        try saveWorkspace(merged, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: merged)
        return WorkspaceInitResult(workspaceConfig: merged, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func syncWorkspace(workspaceRoot: String) throws -> WorkspaceSyncResult {
        let workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        return try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
    }

    public static func updateServiceMCPProfile(
        workspaceRoot: String,
        namespacedServiceID: String,
        path: String
    ) throws {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        let parts = namespacedServiceID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ConfigError("Invalid namespaced service ID", metadata: ["id": namespacedServiceID])
        }
        let namespace = parts[0]
        let localID = parts[1]

        guard let repoIndex = workspace.repos.firstIndex(where: { $0.namespace == namespace }),
              var services = workspace.repos[repoIndex].services,
              let serviceIndex = services.firstIndex(where: { $0.id == localID })
        else {
            throw ConfigError("Service not found", metadata: ["id": namespacedServiceID])
        }

        let transport = "streamable_http"
        if services[serviceIndex].mcp == nil {
            services[serviceIndex].mcp = WorkspaceRepoMCPConfig(transport: transport, path: path)
        } else {
            services[serviceIndex].mcp?.path = path
        }
        workspace.repos[repoIndex].services = services

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
    }

    public static func updateServiceConnections(
        workspaceRoot: String,
        connectionsByNamespacedServiceID: [String: ServiceConnectionsConfig]
    ) throws {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)

        for repoIndex in workspace.repos.indices {
            let repo = workspace.repos[repoIndex]
            guard repo.enabled, let services = repo.services, !services.isEmpty else { continue }

            var updatedServices = services
            for serviceIndex in updatedServices.indices {
                let localID = updatedServices[serviceIndex].id
                let namespacedID = "\(repo.namespace)/\(localID)"
                guard let updatedConnections = connectionsByNamespacedServiceID[namespacedID] else { continue }
                updatedServices[serviceIndex].connections = localizedConnections(
                    from: updatedConnections,
                    localNamespace: repo.namespace
                )
            }
            workspace.repos[repoIndex].services = updatedServices
        }

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
    }

    private static func merge(existing: AIBWorkspaceConfig, discovered: [WorkspaceRepo]) -> AIBWorkspaceConfig {
        let existingByPath = Dictionary(uniqueKeysWithValues: existing.repos.map { ($0.path, $0) })
        let mergedRepos = discovered.map { repo -> WorkspaceRepo in
            guard let prior = existingByPath[repo.path] else { return repo }
            var updated = repo
            updated.enabled = prior.enabled
            updated.servicesNamespace = prior.servicesNamespace
            if let priorSelected = prior.selectedCommand, !priorSelected.isEmpty {
                updated.selectedCommand = priorSelected
            }
            if !prior.commandCandidates.isEmpty {
                updated.commandCandidates = prior.commandCandidates
            }
            // Preserve user-configured services (definitions, connections, UI, health, etc.)
            if let priorServices = prior.services, !priorServices.isEmpty {
                updated.services = priorServices
            }
            return updated
        }
        return AIBWorkspaceConfig(
            version: existing.version,
            workspaceName: existing.workspaceName,
            gateway: existing.gateway,
            repos: mergedRepos
        )
    }

    private static func ensureEnvironmentTemplates(workspaceRoot: String) throws {
        let files: [(String, String)] = [
            (".aib/environments/local.yaml", "version: 1\nname: local\n"),
            (".aib/environments/staging.yaml", "version: 1\nname: staging\n"),
            (".aib/environments/prod.yaml", "version: 1\nname: prod\n"),
        ]
        for (relativePath, content) in files {
            let path = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func ensureTargetTemplates(workspaceRoot: String) throws {
        let files: [(String, String)] = [
            (
                ".aib/targets/gcp-cloudrun.yaml",
                """
                version: 1
                target: gcp-cloudrun
                defaults:
                  region: us-central1
                  auth: private
                  transport:
                    mcp: streamable_http
                    a2a_card_path: /.well-known/agent.json
                services: {}
                """
            ),
            (
                ".aib/targets/aws-template.yaml",
                """
                version: 1
                target: aws-template
                notes: Placeholder for future AWS renderer support.
                services: {}
                """
            ),
        ]
        for (relativePath, content) in files {
            let path = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func ensureGitignoreEntries(workspaceRoot: String) throws {
        let gitignorePath = URL(fileURLWithPath: ".gitignore", relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        let required = [".aib/state/", ".aib/logs/"]

        let existing: String
        if FileManager.default.fileExists(atPath: gitignorePath) {
            existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        } else {
            existing = ""
        }

        var toAppend: [String] = []
        for item in required where !existing.contains(item) {
            toAppend.append(item)
        }
        if toAppend.isEmpty { return }

        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let block = prefix + toAppend.joined(separator: "\n") + "\n"

        if FileManager.default.fileExists(atPath: gitignorePath) {
            if let handle = FileHandle(forWritingAtPath: gitignorePath) {
                defer {
                    do {
                        try handle.close()
                    } catch {
                        // Best-effort close after append.
                    }
                }
                try handle.seekToEnd()
                if let data = block.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            }
        } else {
            try block.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }
    }

    private static func localizedConnections(
        from connections: ServiceConnectionsConfig,
        localNamespace: String
    ) -> WorkspaceRepoConnectionsConfig {
        WorkspaceRepoConnectionsConfig(
            mcpServers: connections.mcpServers.map { localizedConnectionTarget(from: $0, localNamespace: localNamespace) },
            a2aAgents: connections.a2aAgents.map { localizedConnectionTarget(from: $0, localNamespace: localNamespace) }
        )
    }

    private static func localizedConnectionTarget(
        from target: ServiceConnectionTarget,
        localNamespace: String
    ) -> WorkspaceRepoConnectionTarget {
        var normalizedServiceRef = target.serviceRef
        if let serviceRef = normalizedServiceRef, serviceRef.hasPrefix(localNamespace + "/") {
            normalizedServiceRef = String(serviceRef.dropFirst(localNamespace.count + 1))
        }
        return WorkspaceRepoConnectionTarget(serviceRef: normalizedServiceRef, url: target.url)
    }
}
