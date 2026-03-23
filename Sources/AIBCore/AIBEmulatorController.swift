import AIBConfig
import AIBGateway
import AIBSupervisor
import AIBWorkspace
import Darwin
import Foundation
import Logging

public struct EmulatorStartResult: Sendable {
    public var pid: Int32?

    public init(pid: Int32?) {
        self.pid = pid
    }
}

public enum EmulatorControllerError: Error, LocalizedError {
    case alreadyRunning
    case notRunning
    case failedToStart(String)
    case failedToStop(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Emulator is already running"
        case .notRunning:
            return "Emulator is not running"
        case .failedToStart(let message):
            return "Failed to start emulator: \(message)"
        case .failedToStop(let message):
            return "Failed to stop emulator: \(message)"
        }
    }
}

private struct AIBClosureLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let sink: @Sendable (AIBEmulatorLogEntry) -> Void

    init(label: String, sink: @escaping @Sendable (AIBEmulatorLogEntry) -> Void) {
        self.label = label
        self.sink = sink
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata localMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel else { return }
        let mergedMetadata: Logger.Metadata
        if let localMetadata {
            mergedMetadata = metadata.merging(localMetadata, uniquingKeysWith: { _, new in new })
        } else {
            mergedMetadata = metadata
        }
        let normalizedMetadata = mergedMetadata.reduce(into: [String: String]()) { partial, pair in
            partial[pair.key] = pair.value.description
        }
        sink(
            AIBEmulatorLogEntry(
                timestamp: Date(),
                level: level,
                loggerLabel: label,
                message: message.description,
                metadata: normalizedMetadata
            )
        )
    }
}

@MainActor
public final class AIBEmulatorController {
    private var gateway: DevGateway?
    private var supervisor: DevSupervisor?
    /// Long-lived process controller reused across start/stop cycles.
    /// Keeps the ContainerManager (and its vmnet network) alive to avoid
    /// leaking vmnet_network_ref resources that the OS cannot reclaim.
    private var processController: ContainerProcessController?
    private var state: State = .stopped
    private var eventContinuations: [UUID: AsyncStream<AIBEmulatorEvent>.Continuation] = [:]
    private var serviceSnapshotPollTask: Task<Void, Never>?
    private var latestServiceSnapshots: [AIBServiceRuntimeSnapshot] = []
    private var requestActivityTask: Task<Void, Never>?
    private var activeServiceIDs: Set<String> = []
    private var inactiveTimers: [String: Task<Void, Never>] = [:]

    private enum State {
        case stopped
        case running(workspaceURL: URL, workspacePath: String, gatewayPort: Int)
    }

    public init() {}

    public func events() -> AsyncStream<AIBEmulatorEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.yield(.lifecycleChanged(currentLifecycleState()))
            continuation.yield(.serviceSnapshotsChanged(latestServiceSnapshots))
            continuation.yield(.activeServicesChanged(activeServiceIDs))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func shutdown() {
        requestActivityTask?.cancel()
        requestActivityTask = nil
        cancelAllInactiveTimers()
        serviceSnapshotPollTask?.cancel()
        serviceSnapshotPollTask = nil
        finishEventStreams()

        // Synchronously stop all containers.
        // This does not require `await` because `forceTerminateAll()` is
        // nonisolated and uses a Mutex-protected container registry internally.
        supervisor?.forceTerminateAll()
        supervisor = nil
        gateway = nil
        // Release the process controller and its vmnet network on app termination.
        processController = nil
        state = .stopped
    }

    public func start(
        workspaceURL: URL,
        gatewayPort: Int,
        additionalEnvironment: [String: String] = [:]
    ) async throws -> EmulatorStartResult {
        guard gateway == nil, supervisor == nil else {
            throw EmulatorControllerError.alreadyRunning
        }
        try ContainerCLIPolicy.ensureInstalled()
        emit(.lifecycleChanged(.starting))

        let workspaceRoot = workspaceURL.standardizedFileURL.path
        let workspacePath = AIBRuntimeCoreService.workspaceYAMLPath(workspaceRoot: workspaceRoot)

        var logger = Logger(label: "aib.app-emulator") { label in
            AIBClosureLogHandler(label: label) { [weak self] entry in
                Task { @MainActor in
                    self?.emit(.log(entry))
                }
            }
        }
        logger.logLevel = .info

        do {
            logger.info(
                "Starting emulator",
                metadata: [
                    "workspace_path": "\(workspaceRoot)",
                    "workspace_yaml": "\(workspacePath)",
                    "gateway_port": "\(gatewayPort)"
                ]
            )
            let loaded = try AIBRuntimeCoreService.resolveWorkspaceConfig(
                workspaceRoot: workspaceRoot,
                gatewayPort: gatewayPort
            )
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }

            let gatewayControl = GatewayControl()
            let gateway = DevGateway(gatewayConfig: loaded.config.gateway, control: gatewayControl, logger: logger)
            try await gateway.start()

            let configProvider: ConfigProvider = { @Sendable in
                try AIBRuntimeCoreService.resolveWorkspaceConfig(
                    workspaceRoot: workspaceRoot,
                    gatewayPort: gatewayPort
                )
            }
            // Reuse the existing process controller (and its vmnet network) across restarts.
            // Create a new one only on first start or after explicit teardown.
            let pc: ContainerProcessController
            if let existing = self.processController {
                pc = existing
                logger.info("Reusing existing ContainerProcessController (vmnet network preserved)")
            } else {
                pc = ContainerProcessController(logger: logger)
                self.processController = pc
                logger.info("Created new ContainerProcessController")
            }
            emit(.kernelDownloadStarted(pc.setupProgress))

            let supervisor = DevSupervisor(
                gatewayControl: gatewayControl,
                configProvider: configProvider,
                watchFilePath: workspacePath,
                gatewayPort: loaded.config.gateway.port,
                reloadEnabled: true,
                additionalEnvironment: additionalEnvironment,
                processController: pc,
                logger: logger
            )
            try await supervisor.startAll()

            self.gateway = gateway
            self.supervisor = supervisor
            self.state = .running(
                workspaceURL: workspaceURL.standardizedFileURL,
                workspacePath: workspacePath,
                gatewayPort: loaded.config.gateway.port
            )
            startServiceSnapshotPolling(supervisor: supervisor)
            startRequestActivitySubscription(control: gatewayControl)
            emit(.lifecycleChanged(.running(pid: getpid(), port: loaded.config.gateway.port)))

            return EmulatorStartResult(pid: getpid())
        } catch {
            logger.error(
                "Emulator start failed",
                metadata: [
                    "workspace_yaml": "\(workspacePath)",
                    "gateway_port": "\(gatewayPort)",
                    "error": "\(error)"
                ]
            )
            requestActivityTask?.cancel()
            requestActivityTask = nil
            cancelAllInactiveTimers()
            activeServiceIDs = []
            serviceSnapshotPollTask?.cancel()
            serviceSnapshotPollTask = nil
            latestServiceSnapshots = []
            if let supervisor {
                await supervisor.stopAll(graceful: true)
                self.supervisor = nil
            }
            if let gateway {
                do {
                    try await gateway.stop()
                } catch {
                    emit(
                        .log(
                            AIBEmulatorLogEntry(
                                timestamp: Date(),
                                level: .warning,
                                loggerLabel: "aib.app-emulator",
                                message: "gateway stop failed during rollback: \(error)",
                                metadata: [:]
                            )
                        )
                    )
                }
                self.gateway = nil
            }
            self.state = .stopped
            emit(.lifecycleChanged(.failed(error.localizedDescription)))
            throw EmulatorControllerError.failedToStart(error.localizedDescription)
        }
    }

    public func stop(graceful: Bool = false) async throws {
        guard let gateway, let supervisor else {
            throw EmulatorControllerError.notRunning
        }
        emit(.lifecycleChanged(.stopping))

        requestActivityTask?.cancel()
        requestActivityTask = nil
        cancelAllInactiveTimers()
        activeServiceIDs = []
        emit(.activeServicesChanged([]))
        await gateway.control.shutdownActivityStreams()

        serviceSnapshotPollTask?.cancel()
        serviceSnapshotPollTask = nil
        await supervisor.stopAll(graceful: graceful)

        var stopFailure: Error?
        do {
            try await gateway.stop()
        } catch {
            stopFailure = error
            emit(
                .log(
                    AIBEmulatorLogEntry(
                        timestamp: Date(),
                        level: .error,
                        loggerLabel: "aib.app-emulator",
                        message: "Emulator stop failed: \(error)",
                        metadata: [:]
                    )
                )
            )
        }

        // Always release runtime references so the next start can proceed,
        // even if shutdown reported an error.
        self.supervisor = nil
        self.gateway = nil
        self.state = .stopped
        latestServiceSnapshots = []
        emit(.serviceSnapshotsChanged([]))
        emit(.lifecycleChanged(.stopped))

        if let stopFailure {
            throw EmulatorControllerError.failedToStop(stopFailure.localizedDescription)
        }
    }

    private func emit(_ event: AIBEmulatorEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func startServiceSnapshotPolling(supervisor: DevSupervisor) {
        serviceSnapshotPollTask?.cancel()
        serviceSnapshotPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshots = await supervisor.serviceStatusSnapshots().map { snapshot in
                    AIBServiceRuntimeSnapshot(
                        serviceID: snapshot.serviceID.rawValue,
                        lifecycleState: snapshot.lifecycleState,
                        desiredState: snapshot.desiredState,
                        mountPath: snapshot.mountPath,
                        backendPort: snapshot.backendPort,
                        consecutiveProbeFailures: snapshot.consecutiveProbeFailures,
                        lastExitStatus: snapshot.lastExitStatus
                    )
                }

                if snapshots != latestServiceSnapshots {
                    latestServiceSnapshots = snapshots
                    emit(.serviceSnapshotsChanged(snapshots))
                }

                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    break
                }
            }
        }
    }

    private func currentLifecycleState() -> AIBEmulatorLifecycleState {
        switch state {
        case .stopped:
            return .stopped
        case .running(_, _, let gatewayPort):
            return .running(pid: getpid(), port: gatewayPort)
        }
    }

    // MARK: - Request Activity Subscription

    private func startRequestActivitySubscription(control: GatewayControl) {
        requestActivityTask?.cancel()
        requestActivityTask = Task { [weak self] in
            for await activity in await control.requestActivities() {
                guard let self, !Task.isCancelled else { break }
                await self.handleRequestActivity(activity, control: control)
            }
        }
    }

    private func handleRequestActivity(_ activity: GatewayRequestActivity, control: GatewayControl) async {
        let serviceKey = activity.serviceID.rawValue
        switch activity.phase {
        case .started:
            inactiveTimers[serviceKey]?.cancel()
            inactiveTimers.removeValue(forKey: serviceKey)
            let changed = activeServiceIDs.insert(serviceKey).inserted
            if changed {
                emit(.activeServicesChanged(activeServiceIDs))
            }
        case .completed:
            let inflight = await control.inflightCount(serviceID: activity.serviceID)
            if inflight == 0 {
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.activeServiceIDs.remove(serviceKey)
                    self.inactiveTimers.removeValue(forKey: serviceKey)
                    self.emit(.activeServicesChanged(self.activeServiceIDs))
                }
                inactiveTimers[serviceKey] = timer
            }
        }
    }

    private func cancelAllInactiveTimers() {
        for timer in inactiveTimers.values {
            timer.cancel()
        }
        inactiveTimers.removeAll()
    }
}
