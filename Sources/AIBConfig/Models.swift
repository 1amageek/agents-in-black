import AIBRuntimeCore
import Foundation

public struct AIBConfig: Sendable, Codable {
    public var version: Int
    public var gateway: GatewayConfig
    public var services: [ServiceConfig]
    public var logLevel: String

    public init(version: Int, gateway: GatewayConfig, services: [ServiceConfig], logLevel: String = "info") {
        self.version = version
        self.gateway = gateway
        self.services = services
        self.logLevel = logLevel
    }
}

public struct GatewayConfig: Sendable, Codable, Equatable {
    public struct Timeouts: Sendable, Codable, Equatable {
        public var header: DurationString
        public var backendConnect: DurationString
        public var backendResponseHeader: DurationString
        public var idle: DurationString
        public var request: DurationString

        public init(
            header: DurationString = .seconds(10),
            backendConnect: DurationString = .seconds(5),
            backendResponseHeader: DurationString = .seconds(30),
            idle: DurationString = .seconds(60),
            request: DurationString = .seconds(300)
        ) {
            self.header = header
            self.backendConnect = backendConnect
            self.backendResponseHeader = backendResponseHeader
            self.idle = idle
            self.request = request
        }
    }

    public struct WebSocket: Sendable, Codable, Equatable {
        public var enabled: Bool
        public init(enabled: Bool = false) { self.enabled = enabled }
    }

    public var port: Int
    public var timeouts: Timeouts
    public var websocket: WebSocket

    public init(port: Int = 9090, timeouts: Timeouts = .init(), websocket: WebSocket = .init()) {
        self.port = port
        self.timeouts = timeouts
        self.websocket = websocket
    }
}

/// Selects which environment variable bucket(s) to merge when materialising
/// the final env map for a service. `env` is always included; `localEnv` /
/// `deployEnv` are added only for the matching target.
public enum EnvTarget: Sendable, Equatable {
    case local
    case deploy
}

public struct ServiceConfig: Sendable, Codable, Equatable {
    public var id: ServiceID
    public var kind: ServiceKind
    public var mountPath: String
    public var port: Int
    public var cwd: String?
    public var run: [String]
    public var build: [String]?
    public var install: [String]?
    public var watchMode: WatchMode
    public var watchPaths: [String]
    public var restartAffects: [ServiceID]
    public var pathRewrite: PathRewriteMode
    public var cookiePathRewrite: Bool
    /// Environment variables applied in BOTH local emulator and deploy targets.
    /// Universal vars only — never put `*_EMULATOR_HOST` style dev-only values
    /// here, or they will leak into production. Use `localEnv` instead.
    public var env: [String: String]
    /// Local-only environment variables (emulator hosts, debug flags, etc.).
    /// Merged on top of `env` for `EnvTarget.local`. Never sent to deploy.
    public var localEnv: [String: String]
    /// Deploy-only environment variables (production-specific overrides).
    /// Merged on top of `env` for `EnvTarget.deploy`. Never used locally.
    public var deployEnv: [String: String]
    /// Secret references mounted as env vars at deploy time. The literal value
    /// lives in a provider-managed secret store (Cloud Run: Secret Manager);
    /// only the reference is committed to `workspace.yaml`. Keys are the env
    /// var names exposed to the container; values describe which secret/version
    /// to mount. At local runtime the value is resolved via
    /// `.aib/secrets.local.yaml` or by fetching from the provider.
    public var secrets: [String: SecretRef]
    public var health: ServiceHealthConfig
    public var restart: ServiceRestartConfig
    public var concurrency: ServiceConcurrencyConfig
    public var auth: ServiceAuthConfig
    public var connections: ServiceConnectionsConfig
    public var mcp: MCPServiceConfig?
    public var a2a: A2AServiceConfig?
    public var codex: CodexServiceConfig?

    public init(
        id: ServiceID,
        kind: ServiceKind = .unknown,
        mountPath: String,
        port: Int,
        cwd: String? = nil,
        run: [String],
        build: [String]? = nil,
        install: [String]? = nil,
        watchMode: WatchMode,
        watchPaths: [String] = [],
        restartAffects: [ServiceID] = [],
        pathRewrite: PathRewriteMode = .stripPrefix,
        cookiePathRewrite: Bool = true,
        env: [String: String] = [:],
        localEnv: [String: String] = [:],
        deployEnv: [String: String] = [:],
        secrets: [String: SecretRef] = [:],
        health: ServiceHealthConfig,
        restart: ServiceRestartConfig,
        concurrency: ServiceConcurrencyConfig = .init(),
        auth: ServiceAuthConfig = .init(),
        connections: ServiceConnectionsConfig = .init(),
        mcp: MCPServiceConfig? = nil,
        a2a: A2AServiceConfig? = nil,
        codex: CodexServiceConfig? = nil
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
        self.localEnv = localEnv
        self.deployEnv = deployEnv
        self.secrets = secrets
        self.health = health
        self.restart = restart
        self.concurrency = concurrency
        self.auth = auth
        self.connections = connections
        self.mcp = mcp
        self.a2a = a2a
        self.codex = codex
    }

    /// Materialises the effective env map for the given target by merging
    /// `env` with the target-specific bucket. The target bucket wins on key
    /// collisions, allowing per-environment overrides.
    public func resolvedEnv(for target: EnvTarget) -> [String: String] {
        switch target {
        case .local:
            return env.merging(localEnv) { _, new in new }
        case .deploy:
            return env.merging(deployEnv) { _, new in new }
        }
    }
}

public struct CodexServiceConfig: Sendable, Codable, Equatable {
    public var auth: CodexAuthConfig?

    public init(auth: CodexAuthConfig? = nil) {
        self.auth = auth
    }

    public static var defaultChatGPTAuth: CodexServiceConfig {
        CodexServiceConfig(
            auth: CodexAuthConfig(
                mode: .chatgpt,
                secret: "codex-auth-json",
                version: "latest"
            )
        )
    }
}

public struct CodexAuthConfig: Sendable, Codable, Equatable {
    public var mode: CodexAuthMode
    public var secret: String
    public var version: String?

    public init(mode: CodexAuthMode, secret: String, version: String? = nil) {
        self.mode = mode
        self.secret = secret
        self.version = version
    }
}

public enum CodexAuthMode: String, Sendable, Codable, Equatable {
    case chatgpt
}

public struct ServiceConnectionsConfig: Sendable, Codable, Equatable {
    public var mcpServers: [ServiceConnectionTarget]
    public var a2aAgents: [ServiceConnectionTarget]

    public init(mcpServers: [ServiceConnectionTarget] = [], a2aAgents: [ServiceConnectionTarget] = []) {
        self.mcpServers = mcpServers
        self.a2aAgents = a2aAgents
    }

    enum CodingKeys: String, CodingKey {
        case mcpServers = "mcp_servers"
        case a2aAgents = "a2a_agents"
    }
}

public struct ServiceConnectionTarget: Sendable, Codable, Equatable, Hashable {
    public var serviceRef: String?
    public var url: String?

    public init(serviceRef: String? = nil, url: String? = nil) {
        self.serviceRef = serviceRef
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case serviceRef = "service_ref"
        case url
    }
}

public enum MCPTransport: String, Sendable, Codable, Equatable {
    case streamableHTTP = "streamable_http"
    case unknown
}

public struct MCPServiceConfig: Sendable, Codable, Equatable {
    public var transport: MCPTransport
    public var path: String

    public init(transport: MCPTransport = .streamableHTTP, path: String = "/mcp") {
        self.transport = transport
        self.path = path
    }
}

public struct A2AServiceConfig: Sendable, Codable, Equatable {
    public var cardPath: String
    public var rpcPath: String

    public init(cardPath: String = "/.well-known/agent.json", rpcPath: String = "/a2a") {
        self.cardPath = cardPath
        self.rpcPath = rpcPath
    }

    enum CodingKeys: String, CodingKey {
        case cardPath = "card_path"
        case rpcPath = "rpc_path"
    }
}

public struct ServiceHealthConfig: Sendable, Codable, Equatable {
    public var livenessPath: String
    public var readinessPath: String
    public var startupReadyTimeout: DurationString
    public var checkInterval: DurationString
    public var failureThreshold: Int

    public init(
        livenessPath: String = "/health/live",
        readinessPath: String = "/health/ready",
        startupReadyTimeout: DurationString = .seconds(30),
        checkInterval: DurationString = .seconds(2),
        failureThreshold: Int = 3
    ) {
        self.livenessPath = livenessPath
        self.readinessPath = readinessPath
        self.startupReadyTimeout = startupReadyTimeout
        self.checkInterval = checkInterval
        self.failureThreshold = failureThreshold
    }
}

public struct ServiceRestartConfig: Sendable, Codable, Equatable {
    public var drainTimeout: DurationString
    public var shutdownGracePeriod: DurationString
    public var backoffInitial: DurationString
    public var backoffMax: DurationString

    public init(
        drainTimeout: DurationString = .seconds(10),
        shutdownGracePeriod: DurationString = .seconds(10),
        backoffInitial: DurationString = .seconds(1),
        backoffMax: DurationString = .seconds(30)
    ) {
        self.drainTimeout = drainTimeout
        self.shutdownGracePeriod = shutdownGracePeriod
        self.backoffInitial = backoffInitial
        self.backoffMax = backoffMax
    }
}

public struct ServiceConcurrencyConfig: Sendable, Codable, Equatable {
    public var maxInflight: Int
    public var overflowMode: OverflowMode
    public var queueTimeout: DurationString?

    public init(maxInflight: Int = 80, overflowMode: OverflowMode = .reject, queueTimeout: DurationString? = nil) {
        self.maxInflight = maxInflight
        self.overflowMode = overflowMode
        self.queueTimeout = queueTimeout
    }
}

public struct ServiceAuthConfig: Sendable, Codable, Equatable {
    public var mode: AuthMode
    public init(mode: AuthMode = .off) { self.mode = mode }
}

public struct DurationString: Sendable, Codable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    public static func seconds(_ value: Int) -> Self { .init("\(value)s") }
    public static func minutes(_ value: Int) -> Self { .init("\(value)m") }
    public static func milliseconds(_ value: Int) -> Self { .init("\(value)ms") }
    public func parse() throws -> Duration { try DurationParser.parse(rawValue) }
}

public struct LoadedConfig: Sendable {
    public var config: AIBConfig
    public var warnings: [String]
    public var configPath: String

    public init(config: AIBConfig, warnings: [String], configPath: String) {
        self.config = config
        self.warnings = warnings
        self.configPath = configPath
    }
}
