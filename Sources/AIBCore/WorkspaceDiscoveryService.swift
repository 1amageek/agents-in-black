import AIBConfig
import AIBWorkspace
import Foundation
import Yams

public struct WorkspaceDiscoveryError: Error, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

@MainActor
public final class WorkspaceDiscoveryService {
    private let excludedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", ".aib", ".next", ".turbo", "dist", "build", ".venv", "__pycache__"
    ]

    public init() {}

    public func loadWorkspace(at rootURL: URL) throws -> AIBWorkspaceSnapshot {
        let rootURL = rootURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw WorkspaceDiscoveryError(message: "Workspace path does not exist")
        }

        let workspaceConfig = try loadWorkspaceConfig(at: rootURL)

        // Build lookup from workspace.yaml so configured runtime takes priority
        let configuredReposByPath: [String: WorkspaceRepo]
        if let workspaceConfig {
            var lookup: [String: WorkspaceRepo] = [:]
            for repo in workspaceConfig.repos {
                let resolvedURL = URL(fileURLWithPath: repo.path, relativeTo: rootURL).standardizedFileURL
                lookup[resolvedURL.path] = repo
            }
            configuredReposByPath = lookup
        } else {
            configuredReposByPath = [:]
        }

        var repos = try discoverRepos(in: rootURL, configuredReposByPath: configuredReposByPath)

        // Include repos from workspace.yaml that were not found by filesystem scan
        // (e.g. external references with ../ paths)
        if let workspaceConfig {
            let discoveredPaths = Set(repos.map { $0.rootURL.standardizedFileURL.path })
            for wsRepo in workspaceConfig.repos where wsRepo.enabled {
                let resolvedURL = URL(fileURLWithPath: wsRepo.path, relativeTo: rootURL).standardizedFileURL
                guard !discoveredPaths.contains(resolvedURL.path),
                      FileManager.default.fileExists(atPath: resolvedURL.path) else {
                    continue
                }
                repos.append(detectRepo(at: resolvedURL, configuredRepo: wsRepo))
            }
        }

        let fileTreesByRepoID = try Dictionary(uniqueKeysWithValues: repos.map { repo in
            (repo.id, try buildFileTree(for: repo))
        })
        let services = parseAllServices(repos: repos, workspaceConfig: workspaceConfig)

        return AIBWorkspaceSnapshot(
            rootURL: rootURL,
            displayName: rootURL.lastPathComponent,
            repos: repos.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }),
            fileTreesByRepoID: fileTreesByRepoID,
            services: services.sorted(by: { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending })
        )
    }

    private func loadWorkspaceConfig(at rootURL: URL) throws -> AIBWorkspaceConfig? {
        let configPath = rootURL.appendingPathComponent(".aib/workspace.yaml").path
        guard FileManager.default.fileExists(atPath: configPath) else { return nil }
        return try WorkspaceYAMLCodec.loadWorkspace(at: configPath)
    }

    private func discoverRepos(in rootURL: URL, configuredReposByPath: [String: WorkspaceRepo]) throws -> [AIBRepoModel] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WorkspaceDiscoveryError(message: "Failed to enumerate workspace")
        }

        var repos: [AIBRepoModel] = []
        while let item = enumerator.nextObject() as? URL {
            let last = item.lastPathComponent
            if excludedDirectoryNames.contains(last) {
                enumerator.skipDescendants()
                continue
            }
            let gitPath = item.appendingPathComponent(".git").path
            if fm.fileExists(atPath: gitPath) {
                let configured = configuredReposByPath[item.standardizedFileURL.path]
                repos.append(detectRepo(at: item, configuredRepo: configured))
                enumerator.skipDescendants()
            }
        }
        return uniquedRepoNames(repos)
    }

    private func detectRepo(at repoURL: URL, configuredRepo: WorkspaceRepo? = nil) -> AIBRepoModel {
        let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: repoURL)
        let detectedRuntimes = allDetections.map { $0.runtime.rawValue }

        // When workspace.yaml specifies a runtime, use that runtime's detection result
        let activeDetection: RuntimeDetectionResult
        if let configuredRuntime = configuredRepo?.runtime,
           let matching = allDetections.first(where: { $0.runtime == configuredRuntime }) {
            activeDetection = matching
        } else {
            activeDetection = allDetections.first ?? .unknown
        }

        let status = activeDetection.candidates.isEmpty ? "unresolved" : "discoverable"
        let selectedCommand = configuredRepo?.selectedCommand ?? activeDetection.candidates.first?.argv ?? []

        // Build runtime → package name mapping from all detection results
        var detectedPackageNames: [String: String] = [:]
        for detection in allDetections {
            if let firstName = detection.serviceNames.first, detection.serviceNames.count == 1 {
                detectedPackageNames[detection.runtime.rawValue] = firstName
            } else if detection.serviceNames.count > 1 {
                // Multi-target (e.g., Swift with multiple executables): use the first as representative
                detectedPackageNames[detection.runtime.rawValue] = detection.serviceNames.first
            }
        }

        return AIBRepoModel(
            name: repoURL.lastPathComponent,
            rootURL: repoURL,
            status: status,
            runtime: activeDetection.runtime.rawValue,
            framework: activeDetection.framework.rawValue,
            selectedCommand: selectedCommand,
            namespace: repoURL.lastPathComponent,
            detectedRuntimes: detectedRuntimes,
            detectedPackageNames: detectedPackageNames
        )
    }

    private func parseAllServices(repos: [AIBRepoModel], workspaceConfig: AIBWorkspaceConfig?) -> [AIBServiceModel] {
        guard let workspaceConfig else { return [] }
        var result: [AIBServiceModel] = []
        for wsRepo in workspaceConfig.repos where wsRepo.enabled {
            let matchingRepo = repos.first(where: { $0.name == wsRepo.name })
            let repoID = matchingRepo?.id ?? wsRepo.name
            let repoName = matchingRepo?.name ?? wsRepo.name
            let namespace = wsRepo.servicesNamespace ?? wsRepo.name

            if let inlineServices = wsRepo.services {
                // Detect package names per runtime from the repo's manifest
                let detectionsByRuntime: [RuntimeKind: RuntimeDetectionResult]
                if let repo = matchingRepo {
                    let detections = RuntimeAdapterRegistry.detectAll(repoURL: repo.rootURL)
                    detectionsByRuntime = Dictionary(uniqueKeysWithValues: detections.map { ($0.runtime, $0) })
                } else {
                    detectionsByRuntime = [:]
                }

                // Explicit services list (may be empty if all were removed)
                for service in inlineServices {
                    let kind = inferServiceKind(kind: service.kind, mountPath: service.mountPath)
                    let connections = parseConnections(service.connections, namespace: namespace)
                    let mcpProfile = service.mcp.map {
                        AIBMCPProfile(
                            transport: $0.transport ?? "streamable_http",
                            path: $0.path ?? "/mcp"
                        )
                    }
                    let a2aProfile = service.a2a.map {
                        AIBA2AProfile(
                            cardPath: $0.cardPath ?? "/.well-known/agent.json",
                            rpcPath: $0.rpcPath ?? "/a2a"
                        )
                    }
                    let uiProfile = normalizeUIProfile(service.ui)

                    // Resolve package name from the runtime matching this service's run command
                    let packageName = resolvePackageName(
                        runCommand: service.run,
                        serviceID: service.id,
                        detectionsByRuntime: detectionsByRuntime
                    )

                    result.append(AIBServiceModel(
                        repoID: repoID,
                        repoName: repoName,
                        localID: service.id,
                        namespace: namespace,
                        mountPath: service.mountPath,
                        runCommand: service.run,
                        watchMode: service.watchMode,
                        cwd: service.cwd,
                        serviceKind: kind,
                        connections: connections,
                        mcpProfile: mcpProfile,
                        a2aProfile: a2aProfile,
                        uiProfile: uiProfile,
                        packageName: packageName,
                        endpoints: service.endpoints ?? [:]
                    ))
                }
            } else {
                // No services field (nil) — auto-generate from detected runtimes
                let generated = generateAutoServices(
                    wsRepo: wsRepo,
                    matchingRepo: matchingRepo,
                    repoID: repoID,
                    repoName: repoName,
                    namespace: namespace
                )
                result.append(contentsOf: generated)
            }
        }
        return result
    }

    private func generateAutoServices(
        wsRepo: WorkspaceRepo,
        matchingRepo: AIBRepoModel?,
        repoID: String,
        repoName: String,
        namespace: String
    ) -> [AIBServiceModel] {
        guard wsRepo.status == .discoverable else { return [] }

        // Check if repo has multiple detected runtimes
        let detectedRuntimes = matchingRepo?.detectedRuntimes ?? []
        if detectedRuntimes.count > 1, let repoURL = matchingRepo?.rootURL {
            let allDetections = RuntimeAdapterRegistry.detectAll(repoURL: repoURL)
            var services: [AIBServiceModel] = []
            for detection in allDetections {
                guard let command = detection.candidates.first?.argv, !command.isEmpty else { continue }
                let localID = detection.runtime.rawValue
                let defaults = RuntimeAdapterRegistry.defaults(for: detection.runtime, packageManager: detection.packageManager)
                let resolvedKind = detection.suggestedServiceKind != .unknown
                    ? detection.suggestedServiceKind
                    : defaults.serviceKind
                let kind: AIBServiceKind = switch resolvedKind {
                case .agent: .agent
                case .mcp: .mcp
                default: .unknown
                }
                let packageName = detection.serviceNames.count == 1 ? detection.serviceNames.first : nil
                services.append(AIBServiceModel(
                    repoID: repoID,
                    repoName: repoName,
                    localID: localID,
                    namespace: namespace,
                    mountPath: "/\(namespace)/\(localID)",
                    runCommand: command,
                    watchMode: defaults.watchMode.rawValue,
                    cwd: repoURL.path,
                    serviceKind: kind,
                    packageName: packageName
                ))
            }
            return services
        }

        // Single runtime: generate one service with "main" ID
        let command = wsRepo.selectedCommand ?? []
        guard !command.isEmpty else { return [] }
        let defaults = RuntimeAdapterRegistry.defaults(for: wsRepo.runtime, packageManager: wsRepo.packageManager)

        // Detect package name and service kind from the repo manifest
        let autoPackageName: String?
        let detectedServiceKind: ServiceKind
        if let repoURL = matchingRepo?.rootURL {
            let detection = RuntimeAdapterRegistry.detectAll(repoURL: repoURL).first
            autoPackageName = detection?.serviceNames.first
            detectedServiceKind = detection?.suggestedServiceKind ?? .unknown
        } else {
            autoPackageName = nil
            detectedServiceKind = .unknown
        }

        let resolvedKind = detectedServiceKind != .unknown ? detectedServiceKind : defaults.serviceKind
        let kind: AIBServiceKind = switch resolvedKind {
        case .agent: .agent
        case .mcp: .mcp
        default: .unknown
        }
        return [AIBServiceModel(
            repoID: repoID,
            repoName: repoName,
            localID: "main",
            namespace: namespace,
            mountPath: "/\(namespace)",
            runCommand: command,
            watchMode: defaults.watchMode.rawValue,
            cwd: matchingRepo?.rootURL.path,
            serviceKind: kind,
            packageName: autoPackageName
        )]
    }

    private func normalizeUIProfile(_ ui: WorkspaceRepoUIConfig?) -> AIBServiceUIProfile? {
        guard let ui else { return nil }
        let primaryMode = ui.primaryMode.flatMap(AIBWorkbenchMode.init(rawValue:))
        let chatProfile = normalizeChatProfile(ui.chat)
        if primaryMode == nil, chatProfile == nil { return nil }
        return AIBServiceUIProfile(primaryMode: primaryMode, chatProfile: chatProfile)
    }

    private func normalizeChatProfile(_ chat: WorkspaceRepoUIChatConfig?) -> AIBChatProfile? {
        guard let chat, let responseMessageJSONPath = chat.responseMessageJSONPath, !responseMessageJSONPath.isEmpty else {
            return nil
        }
        let method = (chat.method?.isEmpty == false ? chat.method! : "POST").uppercased()
        let path = chat.path?.isEmpty == false ? chat.path! : "/"
        let requestContentType = chat.requestContentType?.isEmpty == false ? chat.requestContentType! : "application/json"
        let requestMessageJSONPath = chat.requestMessageJSONPath?.isEmpty == false ? chat.requestMessageJSONPath! : "message"
        return AIBChatProfile(
            method: method,
            path: path,
            requestContentType: requestContentType,
            requestMessageJSONPath: requestMessageJSONPath,
            requestContextJSONPath: chat.requestContextJSONPath,
            responseMessageJSONPath: responseMessageJSONPath,
            streaming: chat.streaming ?? false
        )
    }

    private func buildFileTree(for repo: AIBRepoModel) throws -> [AIBFileNode] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: repo.rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try entries
            .filter { !excludedDirectoryNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { try buildFileNode(url: $0, repoID: repo.id, depth: 0) }
    }

    private func buildFileNode(url: URL, repoID: String, depth: Int) throws -> AIBFileNode {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory ?? false
        if !isDirectory {
            return AIBFileNode(name: url.lastPathComponent, url: url, isDirectory: false, repoID: repoID)
        }
        if depth >= 4 {
            return AIBFileNode(name: url.lastPathComponent, url: url, isDirectory: true, children: [], repoID: repoID)
        }
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let children = try entries
            .filter { !excludedDirectoryNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { try buildFileNode(url: $0, repoID: repoID, depth: depth + 1) }
        return AIBFileNode(name: url.lastPathComponent, url: url, isDirectory: true, children: children, repoID: repoID)
    }

    private func uniquedRepoNames(_ repos: [AIBRepoModel]) -> [AIBRepoModel] {
        var counts: [String: Int] = [:]
        var result: [AIBRepoModel] = []
        for var repo in repos.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let count = (counts[repo.name] ?? 0) + 1
            counts[repo.name] = count
            if count > 1 {
                repo.name = "\(repo.name)-\(count)"
                repo.namespace = repo.name
            }
            result.append(repo)
        }
        return result
    }

    private func inferServiceKind(kind: String?, mountPath: String) -> AIBServiceKind {
        if let kind {
            switch kind {
            case "agent":
                return .agent
            case "mcp":
                return .mcp
            default:
                break
            }
        }
        if mountPath.hasPrefix("/agents/") {
            return .agent
        }
        if mountPath.hasPrefix("/mcp/") {
            return .mcp
        }
        return .unknown
    }

    private func parseConnections(_ config: WorkspaceRepoConnectionsConfig?, namespace: String) -> AIBServiceConnections {
        guard let config else { return .init() }
        return AIBServiceConnections(
            mcpServers: (config.mcpServers ?? []).map { parseConnectionTarget($0, namespace: namespace) },
            a2aAgents: (config.a2aAgents ?? []).map { parseConnectionTarget($0, namespace: namespace) }
        )
    }

    private func parseConnectionTarget(_ target: WorkspaceRepoConnectionTarget, namespace: String) -> AIBConnectionTarget {
        let ref: String?
        if let serviceRef = target.serviceRef, !serviceRef.isEmpty {
            ref = serviceRef.contains("/") ? serviceRef : "\(namespace)/\(serviceRef)"
        } else {
            ref = nil
        }
        return AIBConnectionTarget(serviceRef: ref, url: target.url)
    }

    // MARK: - Package Name Resolution

    /// Resolve the package manifest name for a service by matching its run command to a detected runtime.
    ///
    /// Strategy:
    /// 1. Infer which runtime the service belongs to from its run command (e.g., "swift run X" → Swift)
    /// 2. For Swift `swift run <target>`, extract the target name directly from the command
    /// 3. For 1:1 runtimes (Node, Python, Deno), use the single detected service name
    /// 4. For 1:N runtimes (Swift), match by service ID against detected executable target names
    private func resolvePackageName(
        runCommand: [String],
        serviceID: String,
        detectionsByRuntime: [RuntimeKind: RuntimeDetectionResult]
    ) -> String? {
        guard let firstArg = runCommand.first else { return nil }

        let runtime = inferRuntimeFromCommand(firstArg)
        guard let detection = detectionsByRuntime[runtime] else { return nil }

        let names = detection.serviceNames
        if names.isEmpty { return nil }

        // Swift `swift run <target>`: extract target name from command
        if runtime == .swift, runCommand.count >= 3, runCommand[1] == "run" {
            let target = runCommand[2]
            if names.contains(target) {
                return target
            }
        }

        // 1:1 runtime (single service name)
        if names.count == 1 {
            return names[0]
        }

        // 1:N runtime: match by service ID
        if names.contains(serviceID) {
            return serviceID
        }

        return nil
    }

    private func inferRuntimeFromCommand(_ command: String) -> RuntimeKind {
        RuntimeKind.fromCommand(command)
    }
}
