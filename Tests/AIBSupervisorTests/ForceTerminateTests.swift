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

/// Health probe client that marks only one service as ready.
private struct SelectiveReadyHealthClient: HealthProbeClient {
    let readyServiceID: ServiceID

    func checkLiveness(service: ServiceRuntime) async -> ProbeResult {
        ProbeResult(success: true, statusCode: 200)
    }

    func checkReadiness(service: ServiceRuntime) async -> ProbeResult {
        if service.service.id == readyServiceID {
            return ProbeResult(success: true, statusCode: 200)
        }
        return ProbeResult(success: false, statusCode: 503)
    }
}

/// Process controller that creates mock container handles without real containers.
private final class MockProcessController: ProcessController, Sendable {
    private let _spawnedIDs = Mutex<[String]>([])

    var spawnedIDs: [String] {
        _spawnedIDs.withLock { $0 }
    }

    func spawn(
        service: ServiceConfig,
        resolvedPort: Int,
        gatewayPort: Int,
        configBaseDirectory: String
    ) async throws -> ChildHandle {
        let id = "test-\(service.id.rawValue.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString.prefix(4))"
        _spawnedIDs.withLock { $0.append(id) }
        return ChildHandle(
            serviceID: service.id,
            containerID: id,
            containerState: ContainerState(),
            startedAt: Date(),
            resolvedPort: resolvedPort,
            monitorTask: nil,
            logTask: nil
        )
    }

    func terminateGroup(_ handle: ChildHandle, grace: Duration) async -> TerminationResult {
        handle.containerState.isAlive.withLock { $0 = false }
        return TerminationResult(terminatedGracefully: true, exitCode: 0)
    }

    func killGroup(_ handle: ChildHandle) async {
        handle.containerState.isAlive.withLock { $0 = false }
    }
}

// MARK: - Helpers

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

private func makeServiceConfig(
    id: String,
    mountPath: String,
    startupReadyTimeout: DurationString
) -> ServiceConfig {
    ServiceConfig(
        id: ServiceID(id),
        mountPath: mountPath,
        port: 0,
        run: ["sleep", "9999"],
        watchMode: .external,
        health: ServiceHealthConfig(startupReadyTimeout: startupReadyTimeout),
        restart: ServiceRestartConfig()
    )
}

// MARK: - Tests

@Test(.timeLimit(.minutes(1)))
func forceTerminateAllDoesNotCrashWithMockContainers() async throws {
    let controller = MockProcessController()
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

    try await supervisor.startAll()

    let snapshots = await supervisor.serviceStatusSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots[0].lifecycleState == .ready)

    let ids = controller.spawnedIDs
    #expect(ids.count == 1)

    // forceTerminateAll is nonisolated — no await required.
    // With mock containers, the CLI `container stop` will fail silently (best-effort).
    supervisor.forceTerminateAll()

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
    let controller = MockProcessController()
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

    try await supervisor.startAll()

    // Call twice — second call must not crash.
    supervisor.forceTerminateAll()
    supervisor.forceTerminateAll()

    await supervisor.stopAll(graceful: false)
}

@Test(.timeLimit(.minutes(1)))
func forceTerminateAllOnEmptySupervisorDoesNotCrash() {
    let controller = MockProcessController()
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
        processController: controller,
        logger: Logger(label: "test")
    )

    // Must not crash when called with no registered containers.
    supervisor.forceTerminateAll()
}

@Test(.timeLimit(.minutes(1)))
func normalStopClearsContainerRegistry() async throws {
    let controller = MockProcessController()
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

    try await supervisor.startAll()

    let ids = controller.spawnedIDs
    #expect(ids.count == 1)

    // Normal graceful stop should clear the container registry.
    await supervisor.stopAll(graceful: true)

    // After normal stop, forceTerminateAll should be a no-op (no crash).
    supervisor.forceTerminateAll()
}

@Test(.timeLimit(.minutes(1)))
func initialStartPublishesRoutesBeforeAllServicesBecomeReady() async throws {
    let controller = MockProcessController()
    let gatewayControl = GatewayControl()
    let readyServiceID = ServiceID("agent/ready")
    let blockedServiceID = ServiceID("agent/blocked")
    let config = AIBConfig(
        version: 1,
        gateway: GatewayConfig(port: 0),
        services: [
            makeServiceConfig(id: readyServiceID.rawValue, mountPath: "/agent/ready", startupReadyTimeout: .seconds(2)),
            makeServiceConfig(id: blockedServiceID.rawValue, mountPath: "/agent/blocked", startupReadyTimeout: .seconds(2)),
        ]
    )
    let configProvider: ConfigProvider = {
        LoadedConfig(config: config, warnings: [], configPath: "/tmp")
    }
    let supervisor = DevSupervisor(
        gatewayControl: gatewayControl,
        configProvider: configProvider,
        watchFilePath: "/tmp/workspace.yaml",
        gatewayPort: 0,
        reloadEnabled: false,
        processController: controller,
        healthClient: SelectiveReadyHealthClient(readyServiceID: readyServiceID),
        logger: Logger(label: "test")
    )

    let startTask = Task {
        try await supervisor.startAll()
    }
    try await Task.sleep(for: .milliseconds(200))

    let matchResult = await gatewayControl.match(path: "/agent/ready/", query: nil)
    switch matchResult {
    case .success(let match):
        #expect(match.entry.serviceID == readyServiceID)
    case .failure(let error):
        Issue.record("Expected /agent/ready route to be available during startup, got \(error)")
    }

    do {
        _ = try await startTask.value
        Issue.record("Expected startup to fail because agent/blocked never becomes ready")
    } catch {
        // Expected.
    }
    await supervisor.stopAll(graceful: false)
}
