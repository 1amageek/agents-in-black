import AIBRuntimeCore
import Configuration
import Foundation
import Yams

public enum AIBConfigLoader {
    public static func load(
        configPath: String,
        overrides: ConfigOverrides = .init()
    ) async throws -> LoadedConfig {
        let effectivePath = overrides.configPath ?? configPath

        let fileConfig: YAMLFileConfig
        do {
            let yaml = try String(contentsOfFile: effectivePath, encoding: .utf8)
            fileConfig = try YAMLDecoder().decode(YAMLFileConfig.self, from: yaml)
        } catch {
            throw ConfigError(
                "Failed to load config file",
                metadata: ["path": effectivePath, "underlying_error": "\(error)"]
            )
        }

        // `swift-configuration` is used for layered override inputs (CLI/env) in v1.
        let overrideReader = ConfigReader(providers: [
            CommandLineArgumentsProvider(),
            EnvironmentVariablesProvider(),
        ])

        let config = try buildConfig(
            fileConfig: fileConfig,
            overrideReader: overrideReader,
            explicitOverrides: overrides
        )
        let validation = try AIBConfigValidator.validate(config)
        if !validation.errors.isEmpty {
            throw ValidationError(
                "Configuration validation failed",
                metadata: [
                    "errors": validation.errors.joined(separator: " | "),
                    "path": effectivePath,
                ]
            )
        }
        return LoadedConfig(config: config, warnings: validation.warnings, configPath: effectivePath)
    }

    private static func buildConfig(
        fileConfig: YAMLFileConfig,
        overrideReader: ConfigReader,
        explicitOverrides: ConfigOverrides
    ) throws -> AIBConfig {
        let gatewayPort = explicitOverrides.gatewayPort
            ?? overrideReader.int(forKey: "gateway.port")
            ?? fileConfig.gateway?.port
            ?? 8080

        let gateway = GatewayConfig(
            port: gatewayPort,
            timeouts: .init(
                header: .init(fileConfig.gateway?.timeouts?.header ?? "10s"),
                backendConnect: .init(fileConfig.gateway?.timeouts?.backendConnect ?? "5s"),
                backendResponseHeader: .init(fileConfig.gateway?.timeouts?.backendResponseHeader ?? "30s"),
                idle: .init(fileConfig.gateway?.timeouts?.idle ?? "60s"),
                request: .init(fileConfig.gateway?.timeouts?.request ?? "300s")
            ),
            websocket: .init(enabled: fileConfig.gateway?.websocket?.enabled ?? false)
        )

        let services = try fileConfig.services.map { yaml in
            guard let watchMode = WatchMode(rawValue: yaml.watchMode ?? "external") else {
                throw ConfigError("Invalid watch_mode", metadata: ["service": yaml.id, "value": yaml.watchMode ?? ""])
            }
            guard let pathRewrite = PathRewriteMode(rawValue: yaml.pathRewrite ?? "strip_prefix") else {
                throw ConfigError("Invalid path_rewrite", metadata: ["service": yaml.id, "value": yaml.pathRewrite ?? ""])
            }
            guard let overflowMode = OverflowMode(rawValue: yaml.concurrency?.overflowMode ?? "reject") else {
                throw ConfigError("Invalid overflow_mode", metadata: ["service": yaml.id, "value": yaml.concurrency?.overflowMode ?? ""])
            }
            guard let authMode = AuthMode(rawValue: yaml.auth?.mode ?? "off") else {
                throw ConfigError("Invalid auth.mode", metadata: ["service": yaml.id, "value": yaml.auth?.mode ?? ""])
            }

            return ServiceConfig(
                id: ServiceID(yaml.id),
                mountPath: yaml.mountPath,
                port: yaml.port,
                cwd: yaml.cwd,
                run: yaml.run,
                build: yaml.build,
                install: yaml.install,
                watchMode: watchMode,
                watchPaths: yaml.watchPaths ?? [],
                restartAffects: (yaml.restartAffects ?? []).map { ServiceID($0) },
                pathRewrite: pathRewrite,
                cookiePathRewrite: yaml.cookiePathRewrite ?? true,
                env: yaml.env ?? [:],
                health: .init(
                    livenessPath: yaml.health?.livenessPath ?? "/health/live",
                    readinessPath: yaml.health?.readinessPath ?? "/health/ready",
                    startupReadyTimeout: .init(yaml.health?.startupReadyTimeout ?? "30s"),
                    checkInterval: .init(yaml.health?.checkInterval ?? "2s"),
                    failureThreshold: yaml.health?.failureThreshold ?? 3
                ),
                restart: .init(
                    drainTimeout: .init(yaml.restart?.drainTimeout ?? "10s"),
                    shutdownGracePeriod: .init(yaml.restart?.shutdownGracePeriod ?? "10s"),
                    backoffInitial: .init(yaml.restart?.backoffInitial ?? "1s"),
                    backoffMax: .init(yaml.restart?.backoffMax ?? "30s")
                ),
                concurrency: .init(
                    maxInflight: yaml.concurrency?.maxInflight ?? 80,
                    overflowMode: overflowMode,
                    queueTimeout: yaml.concurrency?.queueTimeout.map { DurationString($0) }
                ),
                auth: .init(mode: authMode)
            )
        }

        let logLevel = explicitOverrides.logLevel
            ?? overrideReader.string(forKey: "log_level")
            ?? fileConfig.logLevel
            ?? "info"

        return AIBConfig(
            version: fileConfig.version ?? 1,
            gateway: gateway,
            services: services,
            logLevel: logLevel
        )
    }
}

private struct YAMLFileConfig: Decodable {
    var version: Int?
    var gateway: Gateway?
    var services: [Service]
    var logLevel: String?

    enum CodingKeys: String, CodingKey {
        case version
        case gateway
        case services
        case logLevel = "log_level"
    }

    struct Gateway: Decodable {
        var port: Int?
        var timeouts: Timeouts?
        var websocket: WebSocket?
    }

    struct Timeouts: Decodable {
        var header: String?
        var backendConnect: String?
        var backendResponseHeader: String?
        var idle: String?
        var request: String?

        enum CodingKeys: String, CodingKey {
            case header
            case backendConnect = "backend_connect"
            case backendResponseHeader = "backend_response_header"
            case idle
            case request
        }
    }

    struct WebSocket: Decodable {
        var enabled: Bool?
    }

    struct Service: Decodable {
        var id: String
        var mountPath: String
        var port: Int
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
        var health: Health?
        var restart: Restart?
        var concurrency: Concurrency?
        var auth: Auth?

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
    }

    struct Health: Decodable {
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

    struct Restart: Decodable {
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

    struct Concurrency: Decodable {
        var maxInflight: Int?
        var overflowMode: String?
        var queueTimeout: String?

        enum CodingKeys: String, CodingKey {
            case maxInflight = "max_inflight"
            case overflowMode = "overflow_mode"
            case queueTimeout = "queue_timeout"
        }
    }

    struct Auth: Decodable {
        var mode: String?
    }
}
