import Darwin
import Foundation
import Logging
import Synchronization
import Testing

@testable import AIBConfig
@testable import AIBGateway
@testable import AIBRuntimeCore
@testable import AIBSupervisor

// MARK: - Test Doubles

/// Health probe client that always reports success immediately.
private struct AlwaysReadyHealthClient: HealthProbeClient {
    func checkLiveness(service: ServiceRuntime) async -> ProbeResult {
        ProbeResult(success: true, statusCode: 200)
    }

    func checkReadiness(service: ServiceRuntime) async -> ProbeResult {
        ProbeResult(success: true, statusCode: 200)
    }
}

/// Process controller that records spawned PIDs for post-test verification.
private final class RecordingProcessController: ProcessController, Sendable {
    private let real = DefaultProcessController()
    private let _spawnedPIDs = Mutex<[pid_t]>([])

    var spawnedPIDs: [pid_t] {
        _spawnedPIDs.withLock { $0 }
    }

    func spawn(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String
    ) async throws -> ChildHandle {
        let handle = try await real.spawn(
            service: service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            configBaseDirectory: configBaseDirectory
        )
        let pid = handle.process.processIdentifier
        _spawnedPIDs.withLock { $0.append(pid) }
        return handle
    }

    func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult {
        await real.terminateGroup(handle, grace: grace)
    }

    func killGroup(_ handle: ChildHandle) async {
        await real.killGroup(handle)
    }
}

// MARK: - Helpers

private func isProcessAlive(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0
}

private func makeSleepServiceConfig(id: String = "test/sleeper") -> ServiceConfig {
    ServiceConfig(
        id: ServiceID(id),
        mountPath: "/test/sleeper",
        port: 0,
        run: ["sleep", "9999"],
        watchMode: .external,
        health: ServiceHealthConfig(startupReadyTimeout: .seconds(5)),
        restart: ServiceRestartConfig()
    )
}

// MARK: - Tests

@Test(.timeLimit(.minutes(1)))
func forceTerminateAllKillsChildProcesses() async throws {
    let controller = RecordingProcessController()
    let config = AIBConfig(
        version: 1,
        gateway: GatewayConfig(port: 0),
        services: [makeSleepServiceConfig()]
    )
    let configProvider: ConfigProvider = {
        LoadedConfig(config: config, warnings: [], configPath: "/tmp")
    }
    let supervisor = DevSupervisor(
        gatewayControl: GatewayControl(),
        configProvider: configProvider,
        watchFilePath: "/tmp/workspace.yaml",
        gatewayPort: 0,
        reloadEnabled: false,
        processController: controller,
        healthClient: AlwaysReadyHealthClient(),
        logger: Logger(label: "test")
    )

    await supervisor.startAll()

    let snapshots = await supervisor.serviceStatusSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots[0].lifecycleState == .ready)

    let pids = controller.spawnedPIDs
    #expect(pids.count == 1)
    let pid = pids[0]
    #expect(isProcessAlive(pid))

    // forceTerminateAll is nonisolated — no await required.
    supervisor.forceTerminateAll()

    // Allow time for SIGKILL to take effect.
    try await Task.sleep(for: .milliseconds(200))

    #expect(!isProcessAlive(pid))

    // Cleanup: stop the supervisor to cancel internal tasks.
    await supervisor.stopAll(graceful: false)
}

@Test(.timeLimit(.minutes(1)))
func forceTerminateAllIsIdempotent() async throws {
    let config = AIBConfig(
        version: 1,
        gateway: GatewayConfig(port: 0),
        services: [makeSleepServiceConfig()]
    )
    let controller = RecordingProcessController()
    let configProvider: ConfigProvider = {
        LoadedConfig(config: config, warnings: [], configPath: "/tmp")
    }
    let supervisor = DevSupervisor(
        gatewayControl: GatewayControl(),
        configProvider: configProvider,
        watchFilePath: "/tmp/workspace.yaml",
        gatewayPort: 0,
        reloadEnabled: false,
        processController: controller,
        healthClient: AlwaysReadyHealthClient(),
        logger: Logger(label: "test")
    )

    await supervisor.startAll()

    let pid = controller.spawnedPIDs[0]
    #expect(isProcessAlive(pid))

    // Call twice — second call must not crash.
    supervisor.forceTerminateAll()
    try await Task.sleep(for: .milliseconds(100))
    supervisor.forceTerminateAll()

    #expect(!isProcessAlive(pid))

    await supervisor.stopAll(graceful: false)
}

@Test(.timeLimit(.minutes(1)))
func forceTerminateAllOnEmptySupervisorDoesNotCrash() {
    let configProvider: ConfigProvider = {
        LoadedConfig(
            config: AIBConfig(version: 1, gateway: GatewayConfig(port: 0), services: []),
            warnings: [],
            configPath: "/tmp"
        )
    }
    let supervisor = DevSupervisor(
        gatewayControl: GatewayControl(),
        configProvider: configProvider,
        watchFilePath: "/tmp/workspace.yaml",
        gatewayPort: 0,
        reloadEnabled: false,
        logger: Logger(label: "test")
    )

    // Must not crash when called with no registered processes.
    supervisor.forceTerminateAll()
}

@Test(.timeLimit(.minutes(1)))
func normalStopClearsPIDRegistry() async throws {
    let controller = RecordingProcessController()
    let config = AIBConfig(
        version: 1,
        gateway: GatewayConfig(port: 0),
        services: [makeSleepServiceConfig()]
    )
    let configProvider: ConfigProvider = {
        LoadedConfig(config: config, warnings: [], configPath: "/tmp")
    }
    let supervisor = DevSupervisor(
        gatewayControl: GatewayControl(),
        configProvider: configProvider,
        watchFilePath: "/tmp/workspace.yaml",
        gatewayPort: 0,
        reloadEnabled: false,
        processController: controller,
        healthClient: AlwaysReadyHealthClient(),
        logger: Logger(label: "test")
    )

    await supervisor.startAll()

    let pid = controller.spawnedPIDs[0]
    #expect(isProcessAlive(pid))

    // Normal graceful stop should kill the process and clear the registry.
    await supervisor.stopAll(graceful: true)

    try await Task.sleep(for: .milliseconds(200))
    #expect(!isProcessAlive(pid))

    // After normal stop, forceTerminateAll should be a no-op (no crash, no kill calls).
    supervisor.forceTerminateAll()
}
