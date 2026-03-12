import AIBConfig
import AIBRuntimeCore
import Foundation

public enum RepoStatus: String, Codable, Sendable {
    case discoverable
    case unresolved
    case ignored
}

public enum RuntimeKind: String, Codable, Sendable {
    case swift
    case node
    case deno
    case python
    case unknown

    /// Infer the runtime kind from the first argument of a run command.
    public static func fromCommand(_ command: String) -> RuntimeKind {
        switch command {
        case "swift":
            return .swift
        case _ where command.hasSuffix("/swift"):
            return .swift
        case "node":
            return .node
        case _ where command.hasSuffix("/node"):
            return .node
        case "npm", "npx", "pnpm", "bun", "yarn":
            return .node
        case "python", "python3":
            return .python
        case _ where command.hasSuffix("/python3"):
            return .python
        case "deno":
            return .deno
        case _ where command.hasSuffix("/deno"):
            return .deno
        case _ where command.contains(".build/"):
            return .swift
        default:
            return .unknown
        }
    }
}

public enum FrameworkKind: String, Codable, Sendable {
    case vapor
    case hummingbird
    case express
    case fastify
    case nestjs
    case nextjs
    case hono
    case oak
    case fresh
    case fastapi
    case flask
    case django
    case starlette
    case plain
    case unknown
}

public enum PackageManagerKind: String, Codable, Sendable {
    case swiftpm
    case npm
    case pnpm
    case yarn
    case deno
    case uv
    case poetry
    case pip
    case unknown
}

public enum DetectionConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

public struct CommandCandidate: Codable, Sendable, Equatable {
    public var argv: [String]
    public var reason: String

    public init(argv: [String], reason: String) {
        self.argv = argv
        self.reason = reason
    }
}

public struct WorkspaceRepoServiceConfig: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String?
    public var mountPath: String
    public var port: Int?
    public var cwd: String?
    public var run: [String]
    public var build: [String]?
    public var install: [String]?
    public var watchMode: String?
    public var watchPaths: [String]?
    public var restartAffects: [String]?
    public var pathRewrite: String?
    public var cookiePathRewrite: Bool?
    public var env: [String: String]?
    public var health: WorkspaceRepoHealthConfig?
    public var restart: WorkspaceRepoRestartConfig?
    public var concurrency: WorkspaceRepoConcurrencyConfig?
    public var auth: WorkspaceRepoAuthConfig?
    public var connections: WorkspaceRepoConnectionsConfig?
    public var mcp: WorkspaceRepoMCPConfig?
    public var a2a: WorkspaceRepoA2AConfig?
    public var ui: WorkspaceRepoUIConfig?
    /// Deployed endpoint URLs keyed by provider ID (e.g., `"gcp-cloudrun": "https://...run.app"`).
    public var endpoints: [String: String]?
    /// Skill IDs assigned to this service. References workspace-level skill definitions.
    public var skills: [String]?

    public init(
        id: String,
        kind: String? = nil,
        mountPath: String,
        port: Int? = nil,
        cwd: String? = nil,
        run: [String],
        build: [String]? = nil,
        install: [String]? = nil,
        watchMode: String? = nil,
        watchPaths: [String]? = nil,
        restartAffects: [String]? = nil,
        pathRewrite: String? = nil,
        cookiePathRewrite: Bool? = nil,
        env: [String: String]? = nil,
        health: WorkspaceRepoHealthConfig? = nil,
        restart: WorkspaceRepoRestartConfig? = nil,
        concurrency: WorkspaceRepoConcurrencyConfig? = nil,
        auth: WorkspaceRepoAuthConfig? = nil,
        connections: WorkspaceRepoConnectionsConfig? = nil,
        mcp: WorkspaceRepoMCPConfig? = nil,
        a2a: WorkspaceRepoA2AConfig? = nil,
        ui: WorkspaceRepoUIConfig? = nil,
        endpoints: [String: String]? = nil,
        skills: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mountPath = mountPath
        self.port = port
        self.cwd = cwd
        self.run = run
        self.build = build
        self.install = install
        self.watchMode = watchMode
        self.watchPaths = watchPaths
        self.restartAffects = restartAffects
        self.pathRewrite = pathRewrite
        self.cookiePathRewrite = cookiePathRewrite
        self.env = env
        self.health = health
        self.restart = restart
        self.concurrency = concurrency
        self.auth = auth
        self.connections = connections
        self.mcp = mcp
        self.a2a = a2a
        self.ui = ui
        self.endpoints = endpoints
        self.skills = skills
    }
}

public struct WorkspaceRepoConnectionsConfig: Codable, Sendable, Equatable {
    public var mcpServers: [WorkspaceRepoConnectionTarget]?
    public var a2aAgents: [WorkspaceRepoConnectionTarget]?

    public init(mcpServers: [WorkspaceRepoConnectionTarget]? = nil, a2aAgents: [WorkspaceRepoConnectionTarget]? = nil) {
        self.mcpServers = mcpServers
        self.a2aAgents = a2aAgents
    }
}

public struct WorkspaceRepoConnectionTarget: Codable, Sendable, Equatable {
    public var serviceRef: String?
    public var url: String?

    public init(serviceRef: String? = nil, url: String? = nil) {
        self.serviceRef = serviceRef
        self.url = url
    }
}

public struct WorkspaceRepoMCPConfig: Codable, Sendable, Equatable {
    public var transport: String?
    public var path: String?

    public init(transport: String? = nil, path: String? = nil) {
        self.transport = transport
        self.path = path
    }
}

public struct WorkspaceRepoA2AConfig: Codable, Sendable, Equatable {
    public var cardPath: String?
    public var rpcPath: String?

    public init(cardPath: String? = nil, rpcPath: String? = nil) {
        self.cardPath = cardPath
        self.rpcPath = rpcPath
    }
}

public struct WorkspaceRepoHealthConfig: Codable, Sendable, Equatable {
    public var livenessPath: String?
    public var readinessPath: String?
    public var startupReadyTimeout: String?
    public var checkInterval: String?
    public var failureThreshold: Int?

    public init(
        livenessPath: String? = nil,
        readinessPath: String? = nil,
        startupReadyTimeout: String? = nil,
        checkInterval: String? = nil,
        failureThreshold: Int? = nil
    ) {
        self.livenessPath = livenessPath
        self.readinessPath = readinessPath
        self.startupReadyTimeout = startupReadyTimeout
        self.checkInterval = checkInterval
        self.failureThreshold = failureThreshold
    }
}

public struct WorkspaceRepoRestartConfig: Codable, Sendable, Equatable {
    public var drainTimeout: String?
    public var shutdownGracePeriod: String?
    public var backoffInitial: String?
    public var backoffMax: String?

    public init(
        drainTimeout: String? = nil,
        shutdownGracePeriod: String? = nil,
        backoffInitial: String? = nil,
        backoffMax: String? = nil
    ) {
        self.drainTimeout = drainTimeout
        self.shutdownGracePeriod = shutdownGracePeriod
        self.backoffInitial = backoffInitial
        self.backoffMax = backoffMax
    }
}

public struct WorkspaceRepoConcurrencyConfig: Codable, Sendable, Equatable {
    public var maxInflight: Int?
    public var overflowMode: String?
    public var queueTimeout: String?

    public init(maxInflight: Int? = nil, overflowMode: String? = nil, queueTimeout: String? = nil) {
        self.maxInflight = maxInflight
        self.overflowMode = overflowMode
        self.queueTimeout = queueTimeout
    }
}

public struct WorkspaceRepoAuthConfig: Codable, Sendable, Equatable {
    public var mode: String?

    public init(mode: String? = nil) {
        self.mode = mode
    }
}

public struct WorkspaceRepoUIConfig: Codable, Sendable, Equatable {
    public var primaryMode: String?
    public var chat: WorkspaceRepoUIChatConfig?

    public init(primaryMode: String? = nil, chat: WorkspaceRepoUIChatConfig? = nil) {
        self.primaryMode = primaryMode
        self.chat = chat
    }
}

public struct WorkspaceRepoUIChatConfig: Codable, Sendable, Equatable {
    public var method: String?
    public var path: String?
    public var requestContentType: String?
    public var requestMessageJSONPath: String?
    public var requestContextJSONPath: String?
    public var responseMessageJSONPath: String?
    public var streaming: Bool?

    public init(
        method: String? = nil,
        path: String? = nil,
        requestContentType: String? = nil,
        requestMessageJSONPath: String? = nil,
        requestContextJSONPath: String? = nil,
        responseMessageJSONPath: String? = nil,
        streaming: Bool? = nil
    ) {
        self.method = method
        self.path = path
        self.requestContentType = requestContentType
        self.requestMessageJSONPath = requestMessageJSONPath
        self.requestContextJSONPath = requestContextJSONPath
        self.responseMessageJSONPath = responseMessageJSONPath
        self.streaming = streaming
    }
}

public struct WorkspaceRepo: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var runtime: RuntimeKind
    public var framework: FrameworkKind
    public var packageManager: PackageManagerKind
    public var status: RepoStatus
    public var detectionConfidence: DetectionConfidence
    public var commandCandidates: [CommandCandidate]
    public var selectedCommand: [String]?
    public var servicesNamespace: String?
    public var enabled: Bool
    public var services: [WorkspaceRepoServiceConfig]?

    public init(
        name: String,
        path: String,
        runtime: RuntimeKind,
        framework: FrameworkKind = .unknown,
        packageManager: PackageManagerKind = .unknown,
        status: RepoStatus,
        detectionConfidence: DetectionConfidence,
        commandCandidates: [CommandCandidate] = [],
        selectedCommand: [String]? = nil,
        servicesNamespace: String? = nil,
        enabled: Bool = true,
        services: [WorkspaceRepoServiceConfig]? = nil
    ) {
        self.name = name
        self.path = path
        self.runtime = runtime
        self.framework = framework
        self.packageManager = packageManager
        self.status = status
        self.detectionConfidence = detectionConfidence
        self.commandCandidates = commandCandidates
        self.selectedCommand = selectedCommand
        self.servicesNamespace = servicesNamespace
        self.enabled = enabled
        self.services = services
    }

    public var namespace: String { servicesNamespace ?? name }
}

public struct WorkspaceGatewayDefaults: Codable, Sendable, Equatable {
    public var port: Int
    public init(port: Int = 8080) { self.port = port }
}

public struct AIBWorkspaceConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var workspaceName: String
    public var gateway: WorkspaceGatewayDefaults
    public var repos: [WorkspaceRepo]
    /// Workspace-level skill definitions. Skills are reusable capability packages
    /// that can be assigned to agent services.
    public var skills: [WorkspaceSkillConfig]?

    public init(
        version: Int = 1,
        workspaceName: String,
        gateway: WorkspaceGatewayDefaults = .init(),
        repos: [WorkspaceRepo],
        skills: [WorkspaceSkillConfig]? = nil
    ) {
        self.version = version
        self.workspaceName = workspaceName
        self.gateway = gateway
        self.repos = repos
        self.skills = skills
    }
}

public struct WorkspaceInitOptions: Sendable {
    public var workspaceRoot: String
    public var scanPath: String
    public var force: Bool
    public var scanEnabled: Bool

    public init(workspaceRoot: String, scanPath: String, force: Bool = false, scanEnabled: Bool = true) {
        self.workspaceRoot = workspaceRoot
        self.scanPath = scanPath
        self.force = force
        self.scanEnabled = scanEnabled
    }
}

public struct WorkspaceInitResult: Sendable {
    public var workspaceConfig: AIBWorkspaceConfig
    public var generatedServices: Int
    public var warnings: [String]

    public init(workspaceConfig: AIBWorkspaceConfig, generatedServices: Int, warnings: [String]) {
        self.workspaceConfig = workspaceConfig
        self.generatedServices = generatedServices
        self.warnings = warnings
    }
}

public struct WorkspaceSyncResult: Sendable {
    public var serviceCount: Int
    public var warnings: [String]

    public init(serviceCount: Int, warnings: [String] = []) {
        self.serviceCount = serviceCount
        self.warnings = warnings
    }
}

/// Per-service metadata resolved during workspace config resolution.
/// Carries runtime detection results from WorkspaceSyncer to the deploy pipeline,
/// eliminating the need for duplicate detection.
public struct ServiceDeployMetadata: Sendable, Equatable {
    /// Detected runtime for this service.
    public var runtime: RuntimeKind
    /// Detected package manager for this service.
    public var packageManager: PackageManagerKind
    /// Package manifest name (e.g., "agent" from package.json, "MCPServer" from Package.swift target).
    public var packageName: String
    /// Relative path from workspace root to the repo directory.
    public var repoPath: String
    /// Relative path to a custom Dockerfile, if one exists (e.g., "agent/Dockerfile.node").
    public var dockerfilePath: String?
    /// Absolute path of the execution directory that will be mounted as `/app`.
    public var executionRootPath: String

    public init(
        runtime: RuntimeKind,
        packageManager: PackageManagerKind,
        packageName: String,
        repoPath: String,
        dockerfilePath: String? = nil,
        executionRootPath: String
    ) {
        self.runtime = runtime
        self.packageManager = packageManager
        self.packageName = packageName
        self.repoPath = repoPath
        self.dockerfilePath = dockerfilePath
        self.executionRootPath = executionRootPath
    }
}
