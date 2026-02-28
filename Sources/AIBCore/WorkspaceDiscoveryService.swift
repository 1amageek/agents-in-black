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
        let repos = try discoverRepos(in: rootURL)
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

    private func discoverRepos(in rootURL: URL) throws -> [AIBRepoModel] {
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
                repos.append(detectRepo(at: item))
                enumerator.skipDescendants()
            }
        }
        return uniquedRepoNames(repos)
    }

    private func detectRepo(at repoURL: URL) -> AIBRepoModel {
        let detection = RuntimeAdapterRegistry.detect(repoURL: repoURL)
        let status = detection.candidates.isEmpty ? "unresolved" : "discoverable"

        return AIBRepoModel(
            name: repoURL.lastPathComponent,
            rootURL: repoURL,
            status: status,
            runtime: detection.runtime.rawValue,
            framework: detection.framework.rawValue,
            selectedCommand: detection.candidates.first?.argv ?? [],
            namespace: repoURL.lastPathComponent
        )
    }

    private func parseAllServices(repos: [AIBRepoModel], workspaceConfig: AIBWorkspaceConfig?) -> [AIBServiceModel] {
        guard let workspaceConfig else { return [] }
        var result: [AIBServiceModel] = []
        for wsRepo in workspaceConfig.repos {
            guard let inlineServices = wsRepo.services, !inlineServices.isEmpty else { continue }
            let matchingRepo = repos.first(where: { $0.name == wsRepo.name })
            let repoID = matchingRepo?.id ?? wsRepo.name
            let repoName = matchingRepo?.name ?? wsRepo.name
            let namespace = wsRepo.servicesNamespace ?? wsRepo.name
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
                    uiProfile: uiProfile
                ))
            }
        }
        return result
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
}
