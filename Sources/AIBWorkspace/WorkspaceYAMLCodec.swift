import AIBRuntimeCore
import Foundation
import os
import YAML

public enum WorkspaceYAMLCodec {
    private static let logger = os.Logger(subsystem: "com.aib.workspace", category: "YAMLCodec")

    public static func loadWorkspace(at path: String) throws -> AIBWorkspaceConfig {
        do {
            logger.info("loadWorkspace: reading \(path)")
            let yamlString = try String(contentsOfFile: path, encoding: .utf8)
            logger.info("loadWorkspace: YAML length=\(yamlString.count)")
            guard let node = try compose(yaml: yamlString) else {
                throw ConfigError("Empty workspace config", metadata: ["path": path])
            }
            logger.info("loadWorkspace: YAML parsed successfully")
            let anyDict = YAMLUtility.nodeToAny(node)
            let jsonData = try JSONSerialization.data(withJSONObject: anyDict, options: [])
            logger.info("loadWorkspace: JSON data size=\(jsonData.count)")
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                logger.info("loadWorkspace: JSON=\(jsonStr)")
            }
            let dto = try JSONDecoder().decode(WorkspaceFileDTO.self, from: jsonData)
            logger.info("loadWorkspace: DTO decoded, repos=\(dto.repos.count)")
            let model = try dto.toModel()
            logger.info("loadWorkspace: model created, repos=\(model.repos.count)")
            return model
        } catch let e as ConfigError {
            logger.error("loadWorkspace: ConfigError: \(e.message)")
            throw e
        } catch {
            logger.error("loadWorkspace: error: \(error)")
            throw ConfigError("Failed to load workspace config", metadata: ["path": path, "underlying_error": "\(error)"])
        }
    }

    public static func saveWorkspace(_ config: AIBWorkspaceConfig, to path: String) throws {
        do {
            let dto = WorkspaceFileDTO(config)
            let jsonData = try JSONEncoder().encode(dto)
            let anyObj = try JSONSerialization.jsonObject(with: jsonData, options: [])
            let yaml = YAMLUtility.emitYAML(anyObj) + "\n"
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
    var skills: [SkillDTO]?

    enum CodingKeys: String, CodingKey {
        case version
        case workspaceName = "workspace_name"
        case gateway
        case repos
        case skills
    }

    struct SkillDTO: Codable {
        var id: String
        var name: String
        var description: String?
        var instructions: String?
        var allowedTools: [String]?
        var tags: [String]?

        enum CodingKeys: String, CodingKey {
            case id, name, description, instructions, tags
            case allowedTools = "allowed_tools"
        }
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
        var endpoints: [String: String]?
        var skills: [String]?
        var model: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, port, cwd, run, build, install, env, health, restart, concurrency, auth, connections, mcp, a2a, ui, endpoints, skills, model
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
        self.skills = config.skills.map { $0.map { skill in
            SkillDTO(
                id: skill.id,
                name: skill.name,
                description: skill.description,
                instructions: skill.instructions,
                allowedTools: skill.allowedTools,
                tags: skill.tags
            )
        }}
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
            ui: s.ui.map { UIDTO(primaryMode: $0.primaryMode, chat: $0.chat.map { UIChatDTO(method: $0.method, path: $0.path, requestContentType: $0.requestContentType, requestMessageJSONPath: $0.requestMessageJSONPath, requestContextJSONPath: $0.requestContextJSONPath, responseMessageJSONPath: $0.responseMessageJSONPath, streaming: $0.streaming) }) },
            endpoints: s.endpoints,
            skills: s.skills,
            model: s.model
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
        let parsedSkills = skills?.map { skill in
            WorkspaceSkillConfig(
                id: skill.id,
                name: skill.name,
                description: skill.description,
                instructions: skill.instructions,
                allowedTools: skill.allowedTools,
                tags: skill.tags
            )
        }
        return AIBWorkspaceConfig(
            version: version,
            workspaceName: workspaceName,
            gateway: .init(port: gateway.port),
            repos: repos,
            skills: parsedSkills
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
            ui: s.ui.map { WorkspaceRepoUIConfig(primaryMode: $0.primaryMode, chat: $0.chat.map { WorkspaceRepoUIChatConfig(method: $0.method, path: $0.path, requestContentType: $0.requestContentType, requestMessageJSONPath: $0.requestMessageJSONPath, requestContextJSONPath: $0.requestContextJSONPath, responseMessageJSONPath: $0.responseMessageJSONPath, streaming: $0.streaming) }) },
            endpoints: s.endpoints,
            skills: s.skills,
            model: s.model
        )
    }
}
