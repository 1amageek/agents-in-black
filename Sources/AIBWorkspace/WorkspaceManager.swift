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

    public static func addRepo(workspaceRoot: String, repoURL: URL) throws -> WorkspaceInitResult {
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let repoStandardized = repoURL.standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoStandardized.path, isDirectory: &isDir), isDir.boolValue else {
            throw ConfigError("Path is not a directory", metadata: ["path": repoStandardized.path])
        }

        // Auto-initialize workspace if workspace.yaml does not exist yet
        let configPath = URL(fileURLWithPath: workspaceConfigRelativePath, relativeTo: rootURL).standardizedFileURL.path
        if !FileManager.default.fileExists(atPath: configPath) {
            _ = try initWorkspace(options: WorkspaceInitOptions(workspaceRoot: rootURL.path, scanPath: rootURL.path, force: false, scanEnabled: true))
        }

        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)

        let relPath = WorkspaceDiscovery.relativePath(from: rootURL, to: repoStandardized)
        guard !workspace.repos.contains(where: { $0.path == relPath }) else {
            throw ConfigError("Repository already exists in workspace", metadata: ["path": relPath])
        }

        let inspected = WorkspaceDiscovery.inspectSingleRepo(at: repoStandardized, workspaceRoot: rootURL)
        workspace.repos.append(inspected)

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func updateRepoRuntime(
        workspaceRoot: String,
        repoPath: String,
        runtime: RuntimeKind
    ) throws -> WorkspaceInitResult {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL

        guard let repoIndex = workspace.repos.firstIndex(where: { $0.path == repoPath }) else {
            throw ConfigError("Repository not found in workspace", metadata: ["path": repoPath])
        }

        // Resolve the repo URL and run detection for the requested runtime
        let resolvedURL = URL(fileURLWithPath: workspace.repos[repoIndex].path, relativeTo: rootURL).standardizedFileURL
        let targetAdapter = RuntimeAdapterRegistry.adapters.first { $0.runtimeKind == runtime }
        guard let adapter = targetAdapter, adapter.canHandle(repoURL: resolvedURL) else {
            throw ConfigError("Runtime '\(runtime.rawValue)' is not available for this repository", metadata: ["path": repoPath])
        }

        let detection = adapter.detect(repoURL: resolvedURL)
        workspace.repos[repoIndex].runtime = detection.runtime
        workspace.repos[repoIndex].framework = detection.framework
        workspace.repos[repoIndex].packageManager = detection.packageManager
        workspace.repos[repoIndex].detectionConfidence = detection.confidence
        workspace.repos[repoIndex].commandCandidates = detection.candidates
        workspace.repos[repoIndex].selectedCommand = detection.candidates.first?.argv

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func configureServices(
        workspaceRoot: String,
        path: String,
        runtimes: [RuntimeKind]
    ) throws -> WorkspaceInitResult {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL

        guard let index = workspace.repos.firstIndex(where: { $0.path == path }) else {
            throw ConfigError("Repository not found in workspace", metadata: ["path": path])
        }

        let resolvedURL = URL(fileURLWithPath: workspace.repos[index].path, relativeTo: rootURL).standardizedFileURL
        let namespace = workspace.repos[index].namespace
        let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: resolvedURL)
        let hasMultipleRuntimes = allDetections.count > 1

        // Merge into existing services
        var services = workspace.repos[index].services ?? []
        let existingIDs = Set(services.map(\.id))

        for runtime in runtimes {
            let localID = hasMultipleRuntimes ? runtime.rawValue : "main"
            guard !existingIDs.contains(localID) else { continue }

            guard let adapter = RuntimeAdapterRegistry.adapters.first(where: { $0.runtimeKind == runtime }),
                  adapter.canHandle(repoURL: resolvedURL) else { continue }
            let detection = adapter.detect(repoURL: resolvedURL)
            guard let command = detection.candidates.first?.argv, !command.isEmpty else { continue }
            let defaults = adapter.defaults(packageManager: detection.packageManager)
            let mountPath = hasMultipleRuntimes ? "/\(namespace)/\(runtime.rawValue)" : "/\(namespace)"

            // Use detection-based kind (from dependency analysis) with fallback to runtime defaults
            let resolvedKind: ServiceKind = detection.suggestedServiceKind != .unknown
                ? detection.suggestedServiceKind
                : defaults.serviceKind
            let kind: String = switch resolvedKind {
            case .agent: "agent"
            case .mcp: "mcp"
            default: "agent"
            }
            services.append(WorkspaceRepoServiceConfig(
                id: localID,
                kind: kind,
                mountPath: mountPath,
                run: command,
                build: defaults.buildCommand,
                install: defaults.installCommand,
                watchMode: defaults.watchMode.rawValue,
                watchPaths: defaults.watchPaths
            ))
        }

        workspace.repos[index].services = services
        workspace.repos[index].status = .discoverable

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
    }

    public static func removeService(
        workspaceRoot: String,
        namespacedServiceID: String
    ) throws -> WorkspaceInitResult {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let parts = namespacedServiceID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ConfigError("Invalid namespaced service ID", metadata: ["id": namespacedServiceID])
        }
        let namespace = parts[0]
        let localID = parts[1]

        guard let index = workspace.repos.firstIndex(where: { $0.namespace == namespace }) else {
            throw ConfigError("Service not found", metadata: ["id": namespacedServiceID])
        }

        var services: [WorkspaceRepoServiceConfig]
        if let existing = workspace.repos[index].services, !existing.isEmpty {
            services = existing
        } else {
            // Materialize auto-generated services so we can selectively remove one
            let resolvedURL = URL(fileURLWithPath: workspace.repos[index].path, relativeTo: rootURL).standardizedFileURL
            let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: resolvedURL)
            services = allDetections.compactMap { detection -> WorkspaceRepoServiceConfig? in
                guard let command = detection.candidates.first?.argv, !command.isEmpty else { return nil }
                let defaults = RuntimeAdapterRegistry.defaults(for: detection.runtime, packageManager: detection.packageManager)
                let id = allDetections.count > 1 ? detection.runtime.rawValue : "main"
                let mountPath = allDetections.count > 1 ? "/\(namespace)/\(detection.runtime.rawValue)" : "/\(namespace)"
                let kind: String = switch defaults.serviceKind {
                case .agent: "agent"
                case .mcp: "mcp"
                default: "agent"
                }
                return WorkspaceRepoServiceConfig(
                    id: id,
                    kind: kind,
                    mountPath: mountPath,
                    run: command,
                    build: defaults.buildCommand,
                    install: defaults.installCommand,
                    watchMode: defaults.watchMode.rawValue,
                    watchPaths: defaults.watchPaths
                )
            }
        }

        services.removeAll { $0.id == localID }
        // Keep empty array (not nil) to prevent auto-generation fallback
        workspace.repos[index].services = services

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
        let syncResult = try WorkspaceSyncer.sync(workspaceRoot: workspaceRoot, workspace: workspace)
        return WorkspaceInitResult(workspaceConfig: workspace, generatedServices: syncResult.serviceCount, warnings: syncResult.warnings)
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

    /// Update the `kind` field of a service in workspace.yaml.
    public static func updateServiceKind(
        workspaceRoot: String,
        namespacedServiceID: String,
        kind: String
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

        services[serviceIndex].kind = kind
        workspace.repos[repoIndex].services = services

        try saveWorkspace(workspace, workspaceRoot: workspaceRoot)
    }

    public static func updateServiceChatConfig(
        workspaceRoot: String,
        namespacedServiceID: String,
        chatConfig: WorkspaceRepoUIChatConfig?
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

        if let chatConfig {
            if services[serviceIndex].ui == nil {
                services[serviceIndex].ui = WorkspaceRepoUIConfig()
            }
            services[serviceIndex].ui?.chat = chatConfig
        } else {
            services[serviceIndex].ui?.chat = nil
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

    /// Update deployed endpoint URLs for services in workspace.yaml.
    /// - Parameter endpointsByNamespacedServiceID: Maps `namespacedID` to `[providerID: url]`.
    public static func updateServiceEndpoints(
        workspaceRoot: String,
        endpointsByNamespacedServiceID: [String: [String: String]]
    ) throws {
        var workspace = try loadWorkspace(workspaceRoot: workspaceRoot)

        for repoIndex in workspace.repos.indices {
            let repo = workspace.repos[repoIndex]
            guard repo.enabled, let services = repo.services, !services.isEmpty else { continue }

            var updatedServices = services
            for serviceIndex in updatedServices.indices {
                let localID = updatedServices[serviceIndex].id
                let namespacedID = "\(repo.namespace)/\(localID)"
                guard let newEndpoints = endpointsByNamespacedServiceID[namespacedID] else { continue }
                var merged = updatedServices[serviceIndex].endpoints ?? [:]
                for (providerID, url) in newEndpoints {
                    merged[providerID] = url
                }
                updatedServices[serviceIndex].endpoints = merged
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
                buildBackend: auto
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
