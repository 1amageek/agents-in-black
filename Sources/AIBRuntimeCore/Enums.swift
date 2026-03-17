import Foundation

public enum WatchMode: String, Codable, Sendable {
    case external
    case `internal`
}

public enum PathRewriteMode: String, Codable, Sendable {
    case stripPrefix = "strip_prefix"
    case preserve
}

public enum OverflowMode: String, Codable, Sendable {
    case reject
    case queue
}

public enum AuthMode: String, Codable, Sendable {
    case off
    case bearerAny = "bearer-any"
    case staticToken = "static-token"
    case mockJWT = "mock-jwt"
}

public enum LifecycleState: String, Codable, Sendable {
    case stopped
    case starting
    case ready
    case unhealthy
    case draining
    case stopping
    case backoff
}

public enum DesiredState: String, Codable, Sendable {
    case running
    case stopped
}

public enum UnavailableReason: String, Sendable {
    case notReady
    case draining
    case missingRoute
    case startup
    case unhealthy
}

public enum RestartReason: String, Sendable {
    case initialStart
    case configReload
    case fileChanged
    case livenessFailed
    case childExit
    case manual
}

public enum ReloadTrigger: String, Sendable {
    case startup
    case configFileChanged
    case manual
    case fileWatcher
}

public enum TimeoutKind: String, Sendable, Codable {
    case header
    case backendConnect = "backend_connect"
    case backendResponseHeader = "backend_response_header"
    case idle
    case request
}

public enum ServiceKind: String, Sendable, Codable, Equatable {
    case agent
    case mcp
    case unknown
}
