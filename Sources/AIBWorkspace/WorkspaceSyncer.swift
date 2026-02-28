import AIBConfig
import AIBRuntimeCore
import Foundation
import Yams

public struct ResolvedConfig: Sendable {
    public var config: AIBConfig
    public var warnings: [String]

    public init(config: AIBConfig, warnings: [String]) {
        self.config = config
        self.warnings = warnings
    }
}

public enum WorkspaceSyncer {
    /// Flatten workspace repos into a validated AIBConfig.
    /// This is the primary entry point for resolving workspace.yaml into runtime config.
    public static func resolveConfig(workspaceRoot: String, workspace: AIBWorkspaceConfig) throws -> ResolvedConfig {
        var services: [ServiceConfig] = []
        var warnings: [String] = []

        for repo in workspace.repos where repo.enabled {
            let repoRoot = URL(fileURLWithPath: repo.path, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            if let inlineServices = repo.services, !inlineServices.isEmpty {
                let converted = try inlineServices.map { try convertInlineService($0, repo: repo, repoRoot: repoRoot) }
                services.append(contentsOf: namespacedServices(from: converted, repo: repo, repoRoot: repoRoot))
            } else {
                switch repo.status {
                case .discoverable:
                    if let generated = generateDiscoverableService(repo: repo, repoRoot: repoRoot) {
                        services.append(generated)
                    } else {
                        warnings.append("repo \(repo.name): discoverable but no selected command")
                    }
                case .unresolved:
                    warnings.append("repo \(repo.name): unresolved (skipped)")
                case .ignored:
                    continue
                }
            }
        }

        let gateway = GatewayConfig(port: workspace.gateway.port)
        let config = AIBConfig(version: 1, gateway: gateway, services: services, logLevel: "info")
        let validation = try AIBConfigValidator.validate(config)
        if !validation.errors.isEmpty {
            throw ValidationError("Generated services config invalid", metadata: ["errors": validation.errors.joined(separator: " | ")])
        }
        warnings.append(contentsOf: validation.warnings)

        return ResolvedConfig(config: config, warnings: warnings)
    }

    /// Sync workspace: resolve config and write runtime connection artifacts.
    /// Does NOT write services.yaml — workspace.yaml is the sole source of truth.
    public static func sync(workspaceRoot: String, workspace: AIBWorkspaceConfig) throws -> WorkspaceSyncResult {
        let resolved = try resolveConfig(workspaceRoot: workspaceRoot, workspace: workspace)
        try writeRuntimeConnectionArtifacts(
            config: resolved.config,
            workspaceRoot: workspaceRoot,
            gatewayPort: workspace.gateway.port
        )
        return WorkspaceSyncResult(serviceCount: resolved.config.services.count, warnings: resolved.warnings)
    }

    /// Write runtime connection JSON artifacts for agent services.
    public static func writeRuntimeConnectionArtifacts(
        config: AIBConfig,
        workspaceRoot: String,
        gatewayPort: Int
    ) throws {
        let outputRoot = URL(fileURLWithPath: ".aib/generated/runtime/connections", relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL

        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            throw ConfigError(
                "Failed to create runtime connection output directory",
                metadata: ["path": outputRoot.path, "underlying_error": "\(error)"]
            )
        }

        let servicesByID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for service in config.services where service.kind == .agent {
            let artifact = RuntimeConnectionArtifact(
                serviceID: service.id.rawValue,
                mcpServers: resolveConnectionTargets(
                    service.connections.mcpServers,
                    servicesByID: servicesByID,
                    gatewayPort: gatewayPort,
                    defaultPathProvider: { target in target.mcp?.path ?? "/mcp" }
                ),
                a2aAgents: resolveConnectionTargets(
                    service.connections.a2aAgents,
                    servicesByID: servicesByID,
                    gatewayPort: gatewayPort,
                    defaultPathProvider: { target in target.a2a?.rpcPath ?? "/a2a" }
                )
            )

            let filename = sanitizedServiceFilename(service.id.rawValue) + ".json"
            let outputURL = outputRoot.appendingPathComponent(filename)
            do {
                let data = try encoder.encode(artifact)
                try data.write(to: outputURL, options: .atomic)
            } catch {
                throw ConfigError(
                    "Failed to write runtime connection artifact",
                    metadata: ["path": outputURL.path, "underlying_error": "\(error)"]
                )
            }
        }
    }

    private static func namespacedServices(from repoServices: [ServiceConfig], repo: WorkspaceRepo, repoRoot: String) -> [ServiceConfig] {
        repoServices.map { service in
            var updated = service
            updated.id = ServiceID("\(repo.namespace)/\(service.id.rawValue)")
            if let cwd = service.cwd {
                updated.cwd = URL(fileURLWithPath: cwd, relativeTo: URL(fileURLWithPath: repoRoot)).standardizedFileURL.path
            } else {
                updated.cwd = repoRoot
            }
            updated.restartAffects = service.restartAffects.map { ServiceID("\(repo.namespace)/\($0.rawValue)") }
            updated.connections = namespacedConnections(service.connections, repoNamespace: repo.namespace)
            return updated
        }
    }

    private static func namespacedConnections(_ connections: ServiceConnectionsConfig, repoNamespace: String) -> ServiceConnectionsConfig {
        ServiceConnectionsConfig(
            mcpServers: connections.mcpServers.map { namespacedConnectionTarget($0, repoNamespace: repoNamespace) },
            a2aAgents: connections.a2aAgents.map { namespacedConnectionTarget($0, repoNamespace: repoNamespace) }
        )
    }

    private static func namespacedConnectionTarget(_ target: ServiceConnectionTarget, repoNamespace: String) -> ServiceConnectionTarget {
        guard let serviceRef = target.serviceRef, !serviceRef.isEmpty else {
            return target
        }
        if serviceRef.contains("/") {
            return target
        }
        return ServiceConnectionTarget(serviceRef: "\(repoNamespace)/\(serviceRef)", url: target.url)
    }

    private static func generateDiscoverableService(repo: WorkspaceRepo, repoRoot: String) -> ServiceConfig? {
        guard let selected = repo.selectedCommand, !selected.isEmpty else { return nil }
        let defaults = RuntimeAdapterRegistry.defaults(for: repo.runtime, packageManager: repo.packageManager)
        return ServiceConfig(
            id: ServiceID("\(repo.namespace)/main"),
            kind: defaults.serviceKind,
            mountPath: "/\(repo.namespace)",
            port: 0,
            cwd: repoRoot,
            run: selected,
            build: defaults.buildCommand,
            install: defaults.installCommand,
            watchMode: defaults.watchMode,
            watchPaths: defaults.watchPaths,
            restartAffects: [],
            pathRewrite: .stripPrefix,
            cookiePathRewrite: true,
            env: [:],
            health: .init(),
            restart: .init(),
            concurrency: .init(),
            auth: .init()
        )
    }

    private static func convertInlineService(_ inline: WorkspaceRepoServiceConfig, repo: WorkspaceRepo, repoRoot: String) throws -> ServiceConfig {
        let watchMode = WatchMode(rawValue: inline.watchMode ?? "external") ?? .external
        let pathRewrite = PathRewriteMode(rawValue: inline.pathRewrite ?? "strip_prefix") ?? .stripPrefix
        let overflowMode = OverflowMode(rawValue: inline.concurrency?.overflowMode ?? "reject") ?? .reject
        let authMode = AuthMode(rawValue: inline.auth?.mode ?? "off") ?? .off
        let resolvedKind = inline.kind.flatMap(ServiceKind.init(rawValue:))
            ?? inferServiceKind(from: inline.mountPath)
        let connectionConfig = ServiceConnectionsConfig(
            mcpServers: (inline.connections?.mcpServers ?? []).map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) },
            a2aAgents: (inline.connections?.a2aAgents ?? []).map { ServiceConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }
        )
        let mcpConfig: MCPServiceConfig?
        if let mcp = inline.mcp {
            let transport = MCPTransport(rawValue: mcp.transport ?? "streamable_http") ?? .streamableHTTP
            mcpConfig = MCPServiceConfig(transport: transport, path: mcp.path ?? "/mcp")
        } else {
            mcpConfig = nil
        }
        let a2aConfig = inline.a2a.map { A2AServiceConfig(cardPath: $0.cardPath ?? "/.well-known/agent.json", rpcPath: $0.rpcPath ?? "/a2a") }

        return ServiceConfig(
            id: ServiceID(inline.id),
            kind: resolvedKind,
            mountPath: inline.mountPath,
            port: inline.port ?? 0,
            cwd: inline.cwd,
            run: inline.run,
            build: inline.build,
            install: inline.install,
            watchMode: watchMode,
            watchPaths: inline.watchPaths ?? [],
            restartAffects: (inline.restartAffects ?? []).map { ServiceID($0) },
            pathRewrite: pathRewrite,
            cookiePathRewrite: inline.cookiePathRewrite ?? true,
            env: inline.env ?? [:],
            health: .init(
                livenessPath: inline.health?.livenessPath ?? "/health/live",
                readinessPath: inline.health?.readinessPath ?? "/health/ready",
                startupReadyTimeout: .init(inline.health?.startupReadyTimeout ?? "30s"),
                checkInterval: .init(inline.health?.checkInterval ?? "2s"),
                failureThreshold: inline.health?.failureThreshold ?? 3
            ),
            restart: .init(
                drainTimeout: .init(inline.restart?.drainTimeout ?? "10s"),
                shutdownGracePeriod: .init(inline.restart?.shutdownGracePeriod ?? "10s"),
                backoffInitial: .init(inline.restart?.backoffInitial ?? "1s"),
                backoffMax: .init(inline.restart?.backoffMax ?? "30s")
            ),
            concurrency: .init(
                maxInflight: inline.concurrency?.maxInflight ?? 80,
                overflowMode: overflowMode,
                queueTimeout: inline.concurrency?.queueTimeout.map { DurationString($0) }
            ),
            auth: .init(mode: authMode),
            connections: connectionConfig,
            mcp: mcpConfig,
            a2a: a2aConfig
        )
    }

    private static func inferServiceKind(from mountPath: String) -> ServiceKind {
        if mountPath.hasPrefix("/agents/") {
            return .agent
        }
        if mountPath.hasPrefix("/mcp/") {
            return .mcp
        }
        return .unknown
    }

    private static func resolveConnectionTargets(
        _ targets: [ServiceConnectionTarget],
        servicesByID: [ServiceID: ServiceConfig],
        gatewayPort: Int,
        defaultPathProvider: (ServiceConfig) -> String
    ) -> [ResolvedConnectionTarget] {
        targets.compactMap { target in
            if let url = target.url, !url.isEmpty {
                return ResolvedConnectionTarget(
                    serviceRef: nil,
                    resolvedURL: url,
                    source: "url"
                )
            }
            guard let serviceRef = target.serviceRef, !serviceRef.isEmpty else {
                return nil
            }
            guard let resolvedService = servicesByID[ServiceID(serviceRef)] else {
                return nil
            }
            let base = "http://127.0.0.1:\(gatewayPort)\(resolvedService.mountPath)"
            let suffix = normalizedPath(defaultPathProvider(resolvedService))
            return ResolvedConnectionTarget(
                serviceRef: serviceRef,
                resolvedURL: base + suffix,
                source: "service_ref"
            )
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        if path.isEmpty {
            return ""
        }
        if path.hasPrefix("/") {
            return path
        }
        return "/" + path
    }

    private static func sanitizedServiceFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "__")
    }
}

private struct RuntimeConnectionArtifact: Codable {
    var serviceID: String
    var mcpServers: [ResolvedConnectionTarget]
    var a2aAgents: [ResolvedConnectionTarget]

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case mcpServers = "mcp_servers"
        case a2aAgents = "a2a_agents"
    }
}

private struct ResolvedConnectionTarget: Codable {
    var serviceRef: String?
    var resolvedURL: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case serviceRef = "service_ref"
        case resolvedURL = "resolved_url"
        case source
    }
}
