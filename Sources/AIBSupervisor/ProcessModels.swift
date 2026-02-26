import AIBConfig
import AIBRuntimeCore
import Foundation

public struct ChildHandle: @unchecked Sendable {
    public let serviceID: ServiceID
    public let process: Process
    public let stdoutPipe: Pipe
    public let stderrPipe: Pipe
    public let startedAt: Date
    public let resolvedPort: Int
    public let usesDedicatedProcessGroup: Bool
}

public struct TerminationResult: Sendable {
    public let terminatedGracefully: Bool
    public let exitCode: Int32?
}

public protocol ProcessController: Sendable {
    func spawn(service: ServiceConfig, resolvedPort: Int, gatewayPort: Int, configBaseDirectory: String) async throws -> ChildHandle
    func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult
    func killGroup(_ handle: ChildHandle) async
}

public protocol HealthProbeClient: Sendable {
    func checkLiveness(service: ServiceRuntime) async -> ProbeResult
    func checkReadiness(service: ServiceRuntime) async -> ProbeResult
}

public struct ProbeResult: Sendable {
    public let success: Bool
    public let statusCode: Int?
    public let errorDescription: String?

    public init(success: Bool, statusCode: Int? = nil, errorDescription: String? = nil) {
        self.success = success
        self.statusCode = statusCode
        self.errorDescription = errorDescription
    }
}

public struct ServiceRuntime: Sendable {
    public var service: ServiceConfig
    public var lifecycleState: LifecycleState
    public var desiredState: DesiredState
    public var configVersion: Int
    public var childHandle: ChildHandle?
    public var resolvedPort: Int?
    public var backendEndpoint: BackendEndpoint?
    public var consecutiveProbeFailures: Int
    public var backoffAttempt: Int
    public var lastExitStatus: Int32?
    public var pendingRestartReason: RestartReason?
    public var drainStartedAt: Date?

    public init(service: ServiceConfig, configVersion: Int) {
        self.service = service
        self.lifecycleState = .stopped
        self.desiredState = .running
        self.configVersion = configVersion
        self.childHandle = nil
        self.resolvedPort = nil
        self.backendEndpoint = nil
        self.consecutiveProbeFailures = 0
        self.backoffAttempt = 0
        self.lastExitStatus = nil
        self.pendingRestartReason = nil
        self.drainStartedAt = nil
    }
}
