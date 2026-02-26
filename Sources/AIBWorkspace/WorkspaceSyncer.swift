import AIBConfig
import AIBRuntimeCore
import Foundation
import Yams

public enum WorkspaceSyncer {
    public static func sync(workspaceRoot: String, workspace: AIBWorkspaceConfig) throws -> WorkspaceSyncResult {
        let servicesConfigPath = URL(fileURLWithPath: workspace.generatedServicesPath, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
        var services: [ServiceConfig] = []
        var warnings: [String] = []

        for repo in workspace.repos where repo.enabled {
            let repoRoot = URL(fileURLWithPath: repo.path, relativeTo: URL(fileURLWithPath: workspaceRoot)).standardizedFileURL.path
            switch repo.status {
            case .managed:
                guard let manifestPath = repo.manifestPath else {
                    warnings.append("repo \(repo.name): status=managed but manifest_path missing")
                    continue
                }
                let manifestAbs = URL(fileURLWithPath: manifestPath, relativeTo: URL(fileURLWithPath: repoRoot)).standardizedFileURL.path
                let repoServices = try loadRepoServicesManifest(path: manifestAbs)
                services.append(contentsOf: namespacedServices(from: repoServices, repo: repo, repoRoot: repoRoot))
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

        let gateway = GatewayConfig(port: workspace.gateway.port)
        let config = AIBConfig(version: 1, gateway: gateway, services: services, logLevel: "info")
        let validation = try AIBConfigValidator.validate(config)
        if !validation.errors.isEmpty {
            throw ValidationError("Generated services config invalid", metadata: ["errors": validation.errors.joined(separator: " | ")])
        }
        warnings.append(contentsOf: validation.warnings)

        try writeServicesConfig(config, path: servicesConfigPath)
        return WorkspaceSyncResult(serviceCount: services.count, warnings: warnings)
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
            return updated
        }
    }

    private static func generateDiscoverableService(repo: WorkspaceRepo, repoRoot: String) -> ServiceConfig? {
        guard let selected = repo.selectedCommand, !selected.isEmpty else { return nil }
        let watchMode = defaultWatchMode(for: repo.runtime)
        return ServiceConfig(
            id: ServiceID("\(repo.namespace)/main"),
            mountPath: "/\(repo.namespace)",
            port: 0,
            cwd: repoRoot,
            run: selected,
            build: defaultBuildCommand(for: repo.runtime),
            install: defaultInstallCommand(for: repo.packageManager),
            watchMode: watchMode,
            watchPaths: defaultWatchPaths(for: repo.runtime),
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

    private static func defaultWatchMode(for runtime: RuntimeKind) -> WatchMode {
        switch runtime {
        case .swift:
            return .external
        case .node, .deno, .python:
            return .internal
        case .unknown:
            return .external
        }
    }

    private static func defaultBuildCommand(for runtime: RuntimeKind) -> [String]? {
        switch runtime {
        case .swift: ["swift", "build"]
        default: nil
        }
    }

    private static func defaultInstallCommand(for packageManager: PackageManagerKind) -> [String]? {
        switch packageManager {
        case .npm: ["npm", "install"]
        case .pnpm: ["pnpm", "install"]
        case .yarn: ["yarn", "install"]
        case .uv: ["uv", "sync"]
        case .poetry: ["poetry", "install"]
        default: nil
        }
    }

    private static func defaultWatchPaths(for runtime: RuntimeKind) -> [String] {
        switch runtime {
        case .swift:
            return ["Sources/**", "Package.swift", "Package.resolved"]
        case .node:
            return ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"]
        case .python:
            return ["pyproject.toml", "requirements.txt", "uv.lock", "poetry.lock"]
        case .deno:
            return ["deno.json", "deno.jsonc", "deno.lock"]
        case .unknown:
            return []
        }
    }

    private static func writeServicesConfig(_ config: AIBConfig, path: String) throws {
        let dto = GeneratedServicesFile(config)
        do {
            let yaml = try YAMLEncoder().encode(dto)
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError("Failed to write generated services config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }

    private static func loadRepoServicesManifest(path: String) throws -> [ServiceConfig] {
        let yaml: String
        do {
            yaml = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError("Failed to read repo services manifest", metadata: ["path": path, "underlying_error": "\(error)"])
        }

        let dto: RepoServicesManifestDTO
        do {
            dto = try YAMLDecoder().decode(RepoServicesManifestDTO.self, from: yaml)
        } catch {
            throw ConfigError("Failed to parse repo services manifest", metadata: ["path": path, "underlying_error": "\(error)"])
        }
        return try dto.services.map { try $0.toServiceConfig() }
    }
}

private struct RepoServicesManifestDTO: Codable {
    var version: Int?
    var services: [RepoServiceDTO]
}

private struct RepoServiceDTO: Codable {
    var id: String
    var mountPath: String
    var port: Int?
    var cwd: String?
    var run: [String]
    var build: [String]?
    var install: [String]?
    var watchMode: String?
    var watchPaths: [String]?
    var restartAffects: [String]?
    var pathRewrite: String?
    var cookiePathRewrite: Bool?
    var env: [String: String]?
    var health: RepoHealthDTO?
    var restart: RepoRestartDTO?
    var concurrency: RepoConcurrencyDTO?
    var auth: RepoAuthDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case mountPath = "mount_path"
        case port
        case cwd
        case run
        case build
        case install
        case watchMode = "watch_mode"
        case watchPaths = "watch_paths"
        case restartAffects = "restart_affects"
        case pathRewrite = "path_rewrite"
        case cookiePathRewrite = "cookie_path_rewrite"
        case env
        case health
        case restart
        case concurrency
        case auth
    }

    func toServiceConfig() throws -> ServiceConfig {
        guard let watchMode = WatchMode(rawValue: watchMode ?? "external") else {
            throw ConfigError("Invalid watch_mode", metadata: ["service": id])
        }
        guard let pathRewrite = PathRewriteMode(rawValue: pathRewrite ?? "strip_prefix") else {
            throw ConfigError("Invalid path_rewrite", metadata: ["service": id])
        }
        guard let overflowMode = OverflowMode(rawValue: concurrency?.overflowMode ?? "reject") else {
            throw ConfigError("Invalid overflow_mode", metadata: ["service": id])
        }
        guard let authMode = AuthMode(rawValue: auth?.mode ?? "off") else {
            throw ConfigError("Invalid auth.mode", metadata: ["service": id])
        }

        return ServiceConfig(
            id: ServiceID(id),
            mountPath: mountPath,
            port: port ?? 0,
            cwd: cwd,
            run: run,
            build: build,
            install: install,
            watchMode: watchMode,
            watchPaths: watchPaths ?? [],
            restartAffects: (restartAffects ?? []).map { ServiceID($0) },
            pathRewrite: pathRewrite,
            cookiePathRewrite: cookiePathRewrite ?? true,
            env: env ?? [:],
            health: .init(
                livenessPath: health?.livenessPath ?? "/health/live",
                readinessPath: health?.readinessPath ?? "/health/ready",
                startupReadyTimeout: .init(health?.startupReadyTimeout ?? "30s"),
                checkInterval: .init(health?.checkInterval ?? "2s"),
                failureThreshold: health?.failureThreshold ?? 3
            ),
            restart: .init(
                drainTimeout: .init(restart?.drainTimeout ?? "10s"),
                shutdownGracePeriod: .init(restart?.shutdownGracePeriod ?? "10s"),
                backoffInitial: .init(restart?.backoffInitial ?? "1s"),
                backoffMax: .init(restart?.backoffMax ?? "30s")
            ),
            concurrency: .init(
                maxInflight: concurrency?.maxInflight ?? 80,
                overflowMode: overflowMode,
                queueTimeout: concurrency?.queueTimeout.map { DurationString($0) }
            ),
            auth: .init(mode: authMode)
        )
    }
}

private struct RepoHealthDTO: Codable {
    var livenessPath: String?
    var readinessPath: String?
    var startupReadyTimeout: String?
    var checkInterval: String?
    var failureThreshold: Int?

    enum CodingKeys: String, CodingKey {
        case livenessPath = "liveness_path"
        case readinessPath = "readiness_path"
        case startupReadyTimeout = "startup_ready_timeout"
        case checkInterval = "check_interval"
        case failureThreshold = "failure_threshold"
    }
}

private struct RepoRestartDTO: Codable {
    var drainTimeout: String?
    var shutdownGracePeriod: String?
    var backoffInitial: String?
    var backoffMax: String?

    enum CodingKeys: String, CodingKey {
        case drainTimeout = "drain_timeout"
        case shutdownGracePeriod = "shutdown_grace_period"
        case backoffInitial = "backoff_initial"
        case backoffMax = "backoff_max"
    }
}

private struct RepoConcurrencyDTO: Codable {
    var maxInflight: Int?
    var overflowMode: String?
    var queueTimeout: String?

    enum CodingKeys: String, CodingKey {
        case maxInflight = "max_inflight"
        case overflowMode = "overflow_mode"
        case queueTimeout = "queue_timeout"
    }
}

private struct RepoAuthDTO: Codable {
    var mode: String?
}

private struct GeneratedServicesFile: Codable {
    var version: Int
    var gateway: GeneratedGateway
    var services: [GeneratedService]
    var logLevel: String

    enum CodingKeys: String, CodingKey {
        case version
        case gateway
        case services
        case logLevel = "log_level"
    }

    init(_ config: AIBConfig) {
        version = config.version
        gateway = .init(port: config.gateway.port, timeouts: .init(config.gateway.timeouts), websocket: .init(enabled: config.gateway.websocket.enabled))
        services = config.services.map(GeneratedService.init)
        logLevel = config.logLevel
    }
}

private struct GeneratedGateway: Codable {
    var port: Int
    var timeouts: GeneratedTimeouts
    var websocket: GeneratedWebSocket
}

private struct GeneratedTimeouts: Codable {
    var header: String
    var backendConnect: String
    var backendResponseHeader: String
    var idle: String
    var request: String

    enum CodingKeys: String, CodingKey {
        case header
        case backendConnect = "backend_connect"
        case backendResponseHeader = "backend_response_header"
        case idle
        case request
    }

    init(_ t: GatewayConfig.Timeouts) {
        header = t.header.rawValue
        backendConnect = t.backendConnect.rawValue
        backendResponseHeader = t.backendResponseHeader.rawValue
        idle = t.idle.rawValue
        request = t.request.rawValue
    }
}

private struct GeneratedWebSocket: Codable { var enabled: Bool }

private struct GeneratedService: Codable {
    var id: String
    var mountPath: String
    var port: Int
    var cwd: String?
    var run: [String]
    var build: [String]?
    var install: [String]?
    var watchMode: String
    var watchPaths: [String]
    var restartAffects: [String]
    var pathRewrite: String
    var cookiePathRewrite: Bool
    var env: [String: String]
    var health: GeneratedHealth
    var restart: GeneratedRestart
    var concurrency: GeneratedConcurrency
    var auth: GeneratedAuth

    enum CodingKeys: String, CodingKey {
        case id
        case mountPath = "mount_path"
        case port
        case cwd
        case run
        case build
        case install
        case watchMode = "watch_mode"
        case watchPaths = "watch_paths"
        case restartAffects = "restart_affects"
        case pathRewrite = "path_rewrite"
        case cookiePathRewrite = "cookie_path_rewrite"
        case env
        case health
        case restart
        case concurrency
        case auth
    }

    init(_ service: ServiceConfig) {
        id = service.id.rawValue
        mountPath = service.mountPath
        port = service.port
        cwd = service.cwd
        run = service.run
        build = service.build
        install = service.install
        watchMode = service.watchMode.rawValue
        watchPaths = service.watchPaths
        restartAffects = service.restartAffects.map(\.rawValue)
        pathRewrite = service.pathRewrite.rawValue
        cookiePathRewrite = service.cookiePathRewrite
        env = service.env
        health = .init(service.health)
        restart = .init(service.restart)
        concurrency = .init(service.concurrency)
        auth = .init(mode: service.auth.mode.rawValue)
    }
}

private struct GeneratedHealth: Codable {
    var livenessPath: String
    var readinessPath: String
    var startupReadyTimeout: String
    var checkInterval: String
    var failureThreshold: Int

    enum CodingKeys: String, CodingKey {
        case livenessPath = "liveness_path"
        case readinessPath = "readiness_path"
        case startupReadyTimeout = "startup_ready_timeout"
        case checkInterval = "check_interval"
        case failureThreshold = "failure_threshold"
    }

    init(_ health: ServiceHealthConfig) {
        livenessPath = health.livenessPath
        readinessPath = health.readinessPath
        startupReadyTimeout = health.startupReadyTimeout.rawValue
        checkInterval = health.checkInterval.rawValue
        failureThreshold = health.failureThreshold
    }
}

private struct GeneratedRestart: Codable {
    var drainTimeout: String
    var shutdownGracePeriod: String
    var backoffInitial: String
    var backoffMax: String

    enum CodingKeys: String, CodingKey {
        case drainTimeout = "drain_timeout"
        case shutdownGracePeriod = "shutdown_grace_period"
        case backoffInitial = "backoff_initial"
        case backoffMax = "backoff_max"
    }

    init(_ restart: ServiceRestartConfig) {
        drainTimeout = restart.drainTimeout.rawValue
        shutdownGracePeriod = restart.shutdownGracePeriod.rawValue
        backoffInitial = restart.backoffInitial.rawValue
        backoffMax = restart.backoffMax.rawValue
    }
}

private struct GeneratedConcurrency: Codable {
    var maxInflight: Int
    var overflowMode: String
    var queueTimeout: String?

    enum CodingKeys: String, CodingKey {
        case maxInflight = "max_inflight"
        case overflowMode = "overflow_mode"
        case queueTimeout = "queue_timeout"
    }

    init(_ c: ServiceConcurrencyConfig) {
        maxInflight = c.maxInflight
        overflowMode = c.overflowMode.rawValue
        queueTimeout = c.queueTimeout?.rawValue
    }
}

private struct GeneratedAuth: Codable {
    var mode: String
}
