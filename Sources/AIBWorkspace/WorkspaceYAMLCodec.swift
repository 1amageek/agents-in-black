import AIBRuntimeCore
import Foundation
import Yams

public enum WorkspaceYAMLCodec {
    public static func loadWorkspace(at path: String) throws -> AIBWorkspaceConfig {
        do {
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            return try YAMLDecoder().decode(WorkspaceFileDTO.self, from: yaml).toModel()
        } catch {
            throw ConfigError("Failed to load workspace config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }

    public static func saveWorkspace(_ config: AIBWorkspaceConfig, to path: String) throws {
        do {
            let dto = WorkspaceFileDTO(config)
            let yaml = try YAMLEncoder().encode(dto)
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError("Failed to save workspace config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }
}

private struct WorkspaceFileDTO: Codable {
    var version: Int
    var workspaceName: String
    var gateway: Gateway
    var repos: [Repo]

    enum CodingKeys: String, CodingKey {
        case version
        case workspaceName = "workspace_name"
        case gateway
        case repos
    }

    struct Gateway: Codable {
        var port: Int
    }

    struct Repo: Codable {
        var name: String
        var path: String
        var runtime: String
        var framework: String
        var packageManager: String
        var status: String
        var detectionConfidence: String
        var commandCandidates: [CommandCandidateDTO]
        var selectedCommand: [String]?
        var servicesNamespace: String?
        var enabled: Bool
        var services: [ServiceDTO]?

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case runtime
            case framework
            case packageManager = "package_manager"
            case status
            case detectionConfidence = "detection_confidence"
            case commandCandidates = "command_candidates"
            case selectedCommand = "selected_command"
            case servicesNamespace = "services_namespace"
            case enabled
            case services
        }
    }

    struct CommandCandidateDTO: Codable {
        var argv: [String]
        var reason: String
    }

    struct ServiceDTO: Codable {
        var id: String
        var kind: String?
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
        var health: HealthDTO?
        var restart: RestartDTO?
        var concurrency: ConcurrencyDTO?
        var auth: AuthDTO?
        var connections: ConnectionsDTO?
        var mcp: MCPDTO?
        var a2a: A2ADTO?
        var ui: UIDTO?

        enum CodingKeys: String, CodingKey {
            case id, kind, port, cwd, run, build, install, env, health, restart, concurrency, auth, connections, mcp, a2a, ui
            case mountPath = "mount_path"
            case watchMode = "watch_mode"
            case watchPaths = "watch_paths"
            case restartAffects = "restart_affects"
            case pathRewrite = "path_rewrite"
            case cookiePathRewrite = "cookie_path_rewrite"
        }
    }

    struct ConnectionsDTO: Codable {
        var mcpServers: [ConnectionTargetDTO]?
        var a2aAgents: [ConnectionTargetDTO]?

        enum CodingKeys: String, CodingKey {
            case mcpServers = "mcp_servers"
            case a2aAgents = "a2a_agents"
        }
    }

    struct ConnectionTargetDTO: Codable {
        var serviceRef: String?
        var url: String?

        enum CodingKeys: String, CodingKey {
            case serviceRef = "service_ref"
            case url
        }
    }

    struct MCPDTO: Codable {
        var transport: String?
        var path: String?
    }

    struct A2ADTO: Codable {
        var cardPath: String?
        var rpcPath: String?

        enum CodingKeys: String, CodingKey {
            case cardPath = "card_path"
            case rpcPath = "rpc_path"
        }
    }

    struct HealthDTO: Codable {
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

    struct RestartDTO: Codable {
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

    struct ConcurrencyDTO: Codable {
        var maxInflight: Int?
        var overflowMode: String?
        var queueTimeout: String?

        enum CodingKeys: String, CodingKey {
            case maxInflight = "max_inflight"
            case overflowMode = "overflow_mode"
            case queueTimeout = "queue_timeout"
        }
    }

    struct AuthDTO: Codable {
        var mode: String?
    }

    struct UIDTO: Codable {
        var primaryMode: String?
        var chat: UIChatDTO?

        enum CodingKeys: String, CodingKey {
            case primaryMode = "primary_mode"
            case chat
        }
    }

    struct UIChatDTO: Codable {
        var method: String?
        var path: String?
        var requestContentType: String?
        var requestMessageJSONPath: String?
        var requestContextJSONPath: String?
        var responseMessageJSONPath: String?
        var streaming: Bool?

        enum CodingKeys: String, CodingKey {
            case method, path, streaming
            case requestContentType = "request_content_type"
            case requestMessageJSONPath = "request_message_json_path"
            case requestContextJSONPath = "request_context_json_path"
            case responseMessageJSONPath = "response_message_json_path"
        }
    }

    init(_ config: AIBWorkspaceConfig) {
        self.version = config.version
        self.workspaceName = config.workspaceName
        self.gateway = .init(port: config.gateway.port)
        self.repos = config.repos.map { repo in
            .init(
                name: repo.name,
                path: repo.path,
                runtime: repo.runtime.rawValue,
                framework: repo.framework.rawValue,
                packageManager: repo.packageManager.rawValue,
                status: repo.status.rawValue,
                detectionConfidence: repo.detectionConfidence.rawValue,
                commandCandidates: repo.commandCandidates.map { .init(argv: $0.argv, reason: $0.reason) },
                selectedCommand: repo.selectedCommand,
                servicesNamespace: repo.servicesNamespace,
                enabled: repo.enabled,
                services: repo.services.map { $0.map(Self.serviceDTO) }
            )
        }
    }

    private static func serviceDTO(from s: WorkspaceRepoServiceConfig) -> ServiceDTO {
        ServiceDTO(
            id: s.id,
            kind: s.kind,
            mountPath: s.mountPath,
            port: s.port,
            cwd: s.cwd,
            run: s.run,
            build: s.build,
            install: s.install,
            watchMode: s.watchMode,
            watchPaths: s.watchPaths,
            restartAffects: s.restartAffects,
            pathRewrite: s.pathRewrite,
            cookiePathRewrite: s.cookiePathRewrite,
            env: s.env,
            health: s.health.map { HealthDTO(livenessPath: $0.livenessPath, readinessPath: $0.readinessPath, startupReadyTimeout: $0.startupReadyTimeout, checkInterval: $0.checkInterval, failureThreshold: $0.failureThreshold) },
            restart: s.restart.map { RestartDTO(drainTimeout: $0.drainTimeout, shutdownGracePeriod: $0.shutdownGracePeriod, backoffInitial: $0.backoffInitial, backoffMax: $0.backoffMax) },
            concurrency: s.concurrency.map { ConcurrencyDTO(maxInflight: $0.maxInflight, overflowMode: $0.overflowMode, queueTimeout: $0.queueTimeout) },
            auth: s.auth.map { AuthDTO(mode: $0.mode) },
            connections: s.connections.map { ConnectionsDTO(mcpServers: $0.mcpServers?.map { ConnectionTargetDTO(serviceRef: $0.serviceRef, url: $0.url) }, a2aAgents: $0.a2aAgents?.map { ConnectionTargetDTO(serviceRef: $0.serviceRef, url: $0.url) }) },
            mcp: s.mcp.map { MCPDTO(transport: $0.transport, path: $0.path) },
            a2a: s.a2a.map { A2ADTO(cardPath: $0.cardPath, rpcPath: $0.rpcPath) },
            ui: s.ui.map { UIDTO(primaryMode: $0.primaryMode, chat: $0.chat.map { UIChatDTO(method: $0.method, path: $0.path, requestContentType: $0.requestContentType, requestMessageJSONPath: $0.requestMessageJSONPath, requestContextJSONPath: $0.requestContextJSONPath, responseMessageJSONPath: $0.responseMessageJSONPath, streaming: $0.streaming) }) }
        )
    }

    func toModel() throws -> AIBWorkspaceConfig {
        let repos = try repos.map { repo in
            guard let runtime = RuntimeKind(rawValue: repo.runtime) else {
                throw ConfigError("Invalid runtime", metadata: ["repo": repo.name, "runtime": repo.runtime])
            }
            guard let framework = FrameworkKind(rawValue: repo.framework) else {
                throw ConfigError("Invalid framework", metadata: ["repo": repo.name, "framework": repo.framework])
            }
            guard let packageManager = PackageManagerKind(rawValue: repo.packageManager) else {
                throw ConfigError("Invalid package_manager", metadata: ["repo": repo.name, "package_manager": repo.packageManager])
            }
            guard let status = RepoStatus(rawValue: repo.status) else {
                throw ConfigError("Invalid status", metadata: ["repo": repo.name, "status": repo.status])
            }
            guard let confidence = DetectionConfidence(rawValue: repo.detectionConfidence) else {
                throw ConfigError("Invalid detection_confidence", metadata: ["repo": repo.name, "detection_confidence": repo.detectionConfidence])
            }
            return WorkspaceRepo(
                name: repo.name,
                path: repo.path,
                runtime: runtime,
                framework: framework,
                packageManager: packageManager,
                status: status,
                detectionConfidence: confidence,
                commandCandidates: repo.commandCandidates.map { .init(argv: $0.argv, reason: $0.reason) },
                selectedCommand: repo.selectedCommand,
                servicesNamespace: repo.servicesNamespace,
                enabled: repo.enabled,
                services: repo.services?.map(Self.serviceConfigFromDTO)
            )
        }
        return AIBWorkspaceConfig(
            version: version,
            workspaceName: workspaceName,
            gateway: .init(port: gateway.port),
            repos: repos
        )
    }

    private static func serviceConfigFromDTO(_ s: ServiceDTO) -> WorkspaceRepoServiceConfig {
        WorkspaceRepoServiceConfig(
            id: s.id,
            kind: s.kind,
            mountPath: s.mountPath,
            port: s.port,
            cwd: s.cwd,
            run: s.run,
            build: s.build,
            install: s.install,
            watchMode: s.watchMode,
            watchPaths: s.watchPaths,
            restartAffects: s.restartAffects,
            pathRewrite: s.pathRewrite,
            cookiePathRewrite: s.cookiePathRewrite,
            env: s.env,
            health: s.health.map { WorkspaceRepoHealthConfig(livenessPath: $0.livenessPath, readinessPath: $0.readinessPath, startupReadyTimeout: $0.startupReadyTimeout, checkInterval: $0.checkInterval, failureThreshold: $0.failureThreshold) },
            restart: s.restart.map { WorkspaceRepoRestartConfig(drainTimeout: $0.drainTimeout, shutdownGracePeriod: $0.shutdownGracePeriod, backoffInitial: $0.backoffInitial, backoffMax: $0.backoffMax) },
            concurrency: s.concurrency.map { WorkspaceRepoConcurrencyConfig(maxInflight: $0.maxInflight, overflowMode: $0.overflowMode, queueTimeout: $0.queueTimeout) },
            auth: s.auth.map { WorkspaceRepoAuthConfig(mode: $0.mode) },
            connections: s.connections.map { WorkspaceRepoConnectionsConfig(mcpServers: $0.mcpServers?.map { WorkspaceRepoConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }, a2aAgents: $0.a2aAgents?.map { WorkspaceRepoConnectionTarget(serviceRef: $0.serviceRef, url: $0.url) }) },
            mcp: s.mcp.map { WorkspaceRepoMCPConfig(transport: $0.transport, path: $0.path) },
            a2a: s.a2a.map { WorkspaceRepoA2AConfig(cardPath: $0.cardPath, rpcPath: $0.rpcPath) },
            ui: s.ui.map { WorkspaceRepoUIConfig(primaryMode: $0.primaryMode, chat: $0.chat.map { WorkspaceRepoUIChatConfig(method: $0.method, path: $0.path, requestContentType: $0.requestContentType, requestMessageJSONPath: $0.requestMessageJSONPath, requestContextJSONPath: $0.requestContextJSONPath, responseMessageJSONPath: $0.responseMessageJSONPath, streaming: $0.streaming) }) }
        )
    }
}
