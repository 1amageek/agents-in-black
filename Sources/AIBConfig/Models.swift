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

    public init(port: Int = 8080, timeouts: Timeouts = .init(), websocket: WebSocket = .init()) {
        self.port = port
        self.timeouts = timeouts
        self.websocket = websocket
    }
}

public struct ServiceConfig: Sendable, Codable, Equatable {
    public var id: ServiceID
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
    public var env: [String: String]
    public var health: ServiceHealthConfig
    public var restart: ServiceRestartConfig
    public var concurrency: ServiceConcurrencyConfig
    public var auth: ServiceAuthConfig

    public init(
        id: ServiceID,
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
        health: ServiceHealthConfig,
        restart: ServiceRestartConfig,
        concurrency: ServiceConcurrencyConfig = .init(),
        auth: ServiceAuthConfig = .init()
    ) {
        self.id = id
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

public struct ConfigOverrides: Sendable {
    public var gatewayPort: Int?
    public var logLevel: String?
    public var configPath: String?
    public var reloadEnabled: Bool?

    public init(gatewayPort: Int? = nil, logLevel: String? = nil, configPath: String? = nil, reloadEnabled: Bool? = nil) {
        self.gatewayPort = gatewayPort
        self.logLevel = logLevel
        self.configPath = configPath
        self.reloadEnabled = reloadEnabled
    }
}

public struct LoadedConfig: Sendable {
    public var config: AIBConfig
    public var warnings: [String]
    public var configPath: String
}
