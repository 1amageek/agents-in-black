import AIBConfig
import AIBRuntimeCore
import Foundation
import Synchronization

/// Shared mutable state for a container-backed process.
/// Uses reference semantics so `ChildHandle` (a struct) can be copied
/// while sharing the same state across the supervisor and monitor task.
/// `Mutex<T>` is `~Copyable` so it must live inside a class, not a struct.
public final class ContainerState: Sendable {
    let isAlive: Mutex<Bool>
    let exitCode: Mutex<Int32?>

    public init() {
        self.isAlive = Mutex(true)
        self.exitCode = Mutex(nil)
    }
}

public struct ChildHandle: @unchecked Sendable {
    public let serviceID: ServiceID
    public let containerID: String
    public let containerState: ContainerState
    public let startedAt: Date
    public let resolvedPort: Int

    /// Path to the host-side Unix domain socket exposed via vsock relay.
    /// Used by the gateway and health probes to reach the container service.
    public let unixSocketPath: String?

    /// Host-side directory containing generated entrypoint scripts.
    /// Cleaned up on container termination.
    public let scriptDir: URL?

    /// Background task that monitors container exit status.
    let monitorTask: Task<Void, Never>?
    /// Background task that streams container logs.
    let logTask: Task<Void, Never>?

    public init(
        serviceID: ServiceID,
        containerID: String,
        containerState: ContainerState,
        startedAt: Date,
        resolvedPort: Int,
        unixSocketPath: String? = nil,
        scriptDir: URL? = nil,
        monitorTask: Task<Void, Never>?,
        logTask: Task<Void, Never>?
    ) {
        self.serviceID = serviceID
        self.containerID = containerID
        self.containerState = containerState
        self.startedAt = startedAt
        self.resolvedPort = resolvedPort
        self.unixSocketPath = unixSocketPath
        self.scriptDir = scriptDir
        self.monitorTask = monitorTask
        self.logTask = logTask
    }

    /// Whether the container is still running.
    public var isRunning: Bool {
        containerState.isAlive.withLock { $0 }
    }

    /// Exit code from the container process, or 0 if still running.
    public var terminationStatus: Int32 {
        containerState.exitCode.withLock { $0 ?? 0 }
    }
}

public struct TerminationResult: Sendable {
    public let terminatedGracefully: Bool
    public let exitCode: Int32?

    public init(terminatedGracefully: Bool, exitCode: Int32?) {
        self.terminatedGracefully = terminatedGracefully
        self.exitCode = exitCode
    }
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

public struct SupervisorServiceStatusSnapshot: Sendable, Equatable {
    public let serviceID: ServiceID
    public let lifecycleState: LifecycleState
    public let desiredState: DesiredState
    public let mountPath: String
    public let backendPort: Int?
    public let consecutiveProbeFailures: Int
    public let lastExitStatus: Int32?

    public init(
        serviceID: ServiceID,
        lifecycleState: LifecycleState,
        desiredState: DesiredState,
        mountPath: String,
        backendPort: Int?,
        consecutiveProbeFailures: Int,
        lastExitStatus: Int32?
    ) {
        self.serviceID = serviceID
        self.lifecycleState = lifecycleState
        self.desiredState = desiredState
        self.mountPath = mountPath
        self.backendPort = backendPort
        self.consecutiveProbeFailures = consecutiveProbeFailures
        self.lastExitStatus = lastExitStatus
    }
}
