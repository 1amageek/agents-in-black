import AIBConfig
import AIBRuntimeCore
import Foundation

public enum RepoStatus: String, Codable, Sendable {
    case managed
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

public struct WorkspaceRepo: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var manifestPath: String?
    public var runtime: RuntimeKind
    public var framework: FrameworkKind
    public var packageManager: PackageManagerKind
    public var status: RepoStatus
    public var detectionConfidence: DetectionConfidence
    public var commandCandidates: [CommandCandidate]
    public var selectedCommand: [String]?
    public var servicesNamespace: String?
    public var enabled: Bool

    public init(
        name: String,
        path: String,
        manifestPath: String? = nil,
        runtime: RuntimeKind,
        framework: FrameworkKind = .unknown,
        packageManager: PackageManagerKind = .unknown,
        status: RepoStatus,
        detectionConfidence: DetectionConfidence,
        commandCandidates: [CommandCandidate] = [],
        selectedCommand: [String]? = nil,
        servicesNamespace: String? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.path = path
        self.manifestPath = manifestPath
        self.runtime = runtime
        self.framework = framework
        self.packageManager = packageManager
        self.status = status
        self.detectionConfidence = detectionConfidence
        self.commandCandidates = commandCandidates
        self.selectedCommand = selectedCommand
        self.servicesNamespace = servicesNamespace
        self.enabled = enabled
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
    public var generatedServicesPath: String
    public var gateway: WorkspaceGatewayDefaults
    public var repos: [WorkspaceRepo]

    public init(
        version: Int = 1,
        workspaceName: String,
        generatedServicesPath: String = ".aib/services.yaml",
        gateway: WorkspaceGatewayDefaults = .init(),
        repos: [WorkspaceRepo]
    ) {
        self.version = version
        self.workspaceName = workspaceName
        self.generatedServicesPath = generatedServicesPath
        self.gateway = gateway
        self.repos = repos
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
