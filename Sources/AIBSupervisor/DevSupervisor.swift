import AIBConfig
import AIBGateway
import AIBRuntimeCore
import Foundation
import Logging
import Synchronization

public typealias ConfigProvider = @Sendable () async throws -> LoadedConfig

/// Entry in the container registry for synchronous emergency cleanup.
private struct ChildEntry: Sendable {
    let containerID: String
}

public actor DevSupervisor {
    public nonisolated let gatewayControl: GatewayControl

    private let processController: ProcessController
    private let healthClient: HealthProbeClient
    private let logger: Logger
    private let logMux: LogMux
    private let configProvider: ConfigProvider
    private let watchFilePath: String
    private let gatewayPort: Int
    private let reloadEnabled: Bool
    private let additionalEnvironment: [String: String]

    /// Thread-safe container ID registry for synchronous emergency cleanup.
    /// Accessible from any isolation domain via `nonisolated` methods.
    private nonisolated let _activeChildren = Mutex<[ChildEntry]>([])

    private var currentConfig: AIBConfig?
    private var configVersion: Int = 0
    private var runtimes: [ServiceID: ServiceRuntime] = [:]
    private var configPollTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var configFileMTime: Date?

    public init(
        gatewayControl: GatewayControl,
        configProvider: @escaping ConfigProvider,
        watchFilePath: String,
        gatewayPort: Int,
        reloadEnabled: Bool = true,
        additionalEnvironment: [String: String] = [:],
        processController: ProcessController,
        healthClient: HealthProbeClient = DefaultHealthProbeClient(),
        logger: Logger
    ) {
        self.gatewayControl = gatewayControl
        self.configProvider = configProvider
        self.watchFilePath = watchFilePath
        self.gatewayPort = gatewayPort
        self.reloadEnabled = reloadEnabled
        self.additionalEnvironment = additionalEnvironment
        self.processController = processController
        self.healthClient = healthClient
        self.logger = logger
        self.logMux = LogMux(logger: logger)
    }

    public func startAll() async throws {
        let loaded = try await configProvider()
        for warning in loaded.warnings {
            logger.warning("Config warning", metadata: ["warning": "\(warning)"])
        }
        try await applyInitialConfig(loaded.config)
        configFileMTime = fileMTime(path: watchFilePath)
        if reloadEnabled {
            startConfigPolling()
        }
        startLivenessMonitoring()
    }

    public func reloadConfig(trigger: ReloadTrigger) async {
        do {
            logger.info("Reloading config", metadata: ["trigger": "\(trigger.rawValue)"])
            let loaded = try await configProvider()
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            try await applyReloadedConfig(loaded.config)
            configFileMTime = fileMTime(path: watchFilePath)
        } catch {
            logger.error("Config reload failed", metadata: ["error": "\(error)", "trigger": "\(trigger.rawValue)"])
        }
    }

    public func restartService(_ id: ServiceID, reason: RestartReason) async {
        guard var runtime = runtimes[id] else { return }
        logger.info("Restarting service", metadata: ["service_id": "\(id)", "reason": "\(reason.rawValue)"])
        runtime.pendingRestartReason = reason
        runtimes[id] = runtime
        await stopRuntime(id: id, draining: true)
        do {
            try await startService(id: id)
            try await publishRoutes()
        } catch {
            logger.error("Service restart failed", metadata: ["service_id": "\(id)", "error": "\(error)"])
        }
    }

    public func stopAll(graceful: Bool) async {
        configPollTask?.cancel()
        livenessTask?.cancel()
        for id in Array(runtimes.keys) {
            await stopRuntime(id: id, draining: graceful)
        }
        runtimes.removeAll()
        do {
            try await gatewayControl.applyRouteSnapshot(.init(version: configVersion + 1, entries: []))
        } catch {
            logger.error("Failed to clear routes", metadata: ["error": "\(error)"])
        }
    }

    public func serviceStatusSnapshots() -> [SupervisorServiceStatusSnapshot] {
        runtimes.values
            .map { runtime in
                SupervisorServiceStatusSnapshot(
                    serviceID: runtime.service.id,
                    lifecycleState: runtime.lifecycleState,
                    desiredState: runtime.desiredState,
                    mountPath: runtime.service.mountPath,
                    backendPort: runtime.resolvedPort,
                    consecutiveProbeFailures: runtime.consecutiveProbeFailures,
                    lastExitStatus: runtime.lastExitStatus
                )
            }
            .sorted { $0.serviceID.rawValue < $1.serviceID.rawValue }
    }

    private func applyInitialConfig(_ config: AIBConfig) async throws {
        configVersion += 1
        currentConfig = config
        for service in config.services {
            runtimes[service.id] = ServiceRuntime(service: service, configVersion: configVersion)
        }
        // Publish mount paths immediately so early requests get service_unavailable (not no_route)
        // while the remaining services are still booting.
        try await publishRoutes()
        for service in config.services {
            try await prepareAndStart(service: service, reason: .initialStart)
        }
    }

    private func applyReloadedConfig(_ newConfig: AIBConfig) async throws {
        guard let oldConfig = currentConfig else {
            try await applyInitialConfig(newConfig)
            return
        }

        let oldByID = Dictionary(uniqueKeysWithValues: oldConfig.services.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newConfig.services.map { ($0.id, $0) })

        let removed = Set(oldByID.keys).subtracting(newByID.keys)
        let added = Set(newByID.keys).subtracting(oldByID.keys)
        let shared = Set(oldByID.keys).intersection(newByID.keys)

        var changed: [ServiceID] = []
        for id in shared {
            if oldByID[id] != newByID[id] {
                changed.append(id)
            }
        }

        for id in removed {
            await stopRuntime(id: id, draining: true)
            runtimes.removeValue(forKey: id)
        }

        configVersion += 1
        currentConfig = newConfig

        for id in changed {
            if let service = newByID[id] {
                await stopRuntime(id: id, draining: true)
                runtimes[id] = ServiceRuntime(service: service, configVersion: configVersion)
                try await prepareAndStart(service: service, reason: .configReload)
            }
        }

        for id in added {
            if let service = newByID[id] {
                runtimes[id] = ServiceRuntime(service: service, configVersion: configVersion)
                try await prepareAndStart(service: service, reason: .configReload)
            }
        }

        for id in shared.subtracting(Set(changed)) {
            if let existing = runtimes[id] {
                var updated = existing
                updated.service = newByID[id] ?? existing.service
                updated.configVersion = configVersion
                runtimes[id] = updated
            }
        }

        try await publishRoutes()
    }

    private func prepareAndStart(service: ServiceConfig, reason: RestartReason) async throws {
        // install/build commands are handled by the container entrypoint
        // (chained by ContainerProcessController.spawn)
        try await startService(id: service.id)
        logger.info("Service started", metadata: ["service_id": .string(service.id.rawValue), "reason": .string(reason.rawValue)])
    }

    private func startService(id: ServiceID) async throws {
        guard var runtime = runtimes[id] else { return }
        runtime.lifecycleState = .starting
        runtime.desiredState = .running
        runtime.consecutiveProbeFailures = 0
        runtimes[id] = runtime

        var service = runtime.service
        for (key, value) in additionalEnvironment where service.env[key] == nil {
            service.env[key] = value
        }

        let resolvedPort = try allocatePort(preferred: service.port)
        let handle = try await processController.spawn(
            service: service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            configBaseDirectory: configBaseDirectory
        )
        registerContainer(handle)
        logMux.attach(handle)

        runtime.childHandle = handle
        runtime.resolvedPort = resolvedPort
        let endpoint = BackendEndpoint(
            host: "127.0.0.1",
            port: resolvedPort,
            unixSocketPath: handle.unixSocketPath
        )
        runtime.backendEndpoint = endpoint
        runtimes[id] = runtime

        let ready = try await waitForReadiness(id: id)
        if ready {
            runtime = runtimes[id] ?? runtime
            runtime.lifecycleState = .ready
            runtimes[id] = runtime
            await gatewayControl.markServiceReady(id, endpoint: endpoint)
        } else {
            runtime = runtimes[id] ?? runtime
            runtime.lifecycleState = .backoff
            runtimes[id] = runtime
            await gatewayControl.markServiceUnavailable(id, reason: .startup)
            throw ReloadApplyError("Service failed readiness", metadata: ["service_id": id.rawValue])
        }
    }

    private func waitForReadiness(id: ServiceID) async throws -> Bool {
        guard let runtime = runtimes[id] else { return false }
        let timeout = try runtime.service.health.startupReadyTimeout.parse().timeInterval
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: String?
        while Date() < deadline {
            if let handle = runtimes[id]?.childHandle, !handle.isRunning {
                logger.warning("Container exited before becoming ready", metadata: [
                    "service_id": .string(id.rawValue),
                ])
                return false
            }
            let currentRuntime = runtimes[id] ?? runtime
            let probe = await healthClient.checkReadiness(service: currentRuntime)
            if probe.success { return true }
            // Log probe failure details (deduplicated by error message)
            let error = probe.errorDescription ?? "status=\(probe.statusCode ?? -1)"
            if error != lastError {
                let endpoint = currentRuntime.backendEndpoint
                logger.debug("Readiness probe failed", metadata: [
                    "service_id": .string(id.rawValue),
                    "endpoint": .string(endpoint?.baseURLString ?? "none"),
                    "error": .string(error),
                ])
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        logger.warning("Readiness timeout exceeded", metadata: [
            "service_id": .string(id.rawValue),
            "timeout_seconds": .string("\(timeout)"),
            "last_error": .string(lastError ?? "unknown"),
        ])
        return false
    }

    private func publishRoutes() async throws {
        guard let currentConfig else { return }
        let backends = runtimes.reduce(into: [ServiceID: BackendEndpoint]()) { partial, pair in
            if let endpoint = pair.value.backendEndpoint {
                partial[pair.key] = endpoint
            }
        }
        try await gatewayControl.applyRouteSnapshot(RouteSnapshot.from(config: currentConfig, backends: backends, version: configVersion))
        for (id, runtime) in runtimes {
            if runtime.lifecycleState != .ready {
                await gatewayControl.markServiceUnavailable(id, reason: .notReady)
            }
        }
    }

    private func stopRuntime(id: ServiceID, draining: Bool) async {
        guard var runtime = runtimes[id], let handle = runtime.childHandle else { return }
        if draining {
            runtime.lifecycleState = .draining
            runtimes[id] = runtime
            await gatewayControl.markServiceDraining(id)
            let drain: Duration
            do {
                drain = try runtime.service.restart.drainTimeout.parse()
            } catch {
                logger.warning("Invalid drain_timeout, using 1s", metadata: [
                    "service_id": .string(id.rawValue),
                    "error": .string("\(error)"),
                ])
                drain = .seconds(1)
            }
            do {
                try await Task.sleep(for: drain)
            } catch {
                // Cancelled — proceed to stop immediately.
            }
        }

        runtime.lifecycleState = .stopping
        runtimes[id] = runtime
        let grace: Duration
        do {
            grace = try runtime.service.restart.shutdownGracePeriod.parse()
        } catch {
            logger.warning("Invalid shutdown_grace_period, using 5s", metadata: [
                "service_id": .string(id.rawValue),
                "error": .string("\(error)"),
            ])
            grace = .seconds(5)
        }
        let result = await processController.terminateGroup(handle, grace: grace)
        if !result.terminatedGracefully {
            await processController.killGroup(handle)
        }
        unregisterContainer(handle)
        logMux.detach(handle)

        runtime.childHandle = nil
        runtime.backendEndpoint = nil
        runtime.resolvedPort = nil
        runtime.lastExitStatus = handle.terminationStatus
        runtime.lifecycleState = .stopped
        runtimes[id] = runtime
        await gatewayControl.markServiceUnavailable(id, reason: .startup)
    }

    private func startConfigPolling() {
        configPollTask?.cancel()
        configPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    break
                }
                await self.pollConfigFileChange()
            }
        }
    }

    private func pollConfigFileChange() async {
        let current = fileMTime(path: watchFilePath)
        guard let current else { return }
        if let previous = configFileMTime, current > previous {
            await reloadConfig(trigger: .configFileChanged)
        } else if configFileMTime == nil {
            configFileMTime = current
        }
    }

    private func startLivenessMonitoring() {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = await self.livenessCheckInterval()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                await self.pollLiveness()
            }
        }
    }

    private func livenessCheckInterval() -> Duration {
        var minimum: Duration = .seconds(2)
        for runtime in runtimes.values where runtime.lifecycleState == .ready {
            do {
                let interval = try runtime.service.health.checkInterval.parse()
                if interval < minimum {
                    minimum = interval
                }
            } catch {
                logger.warning("Invalid check_interval", metadata: [
                    "service_id": .string(runtime.service.id.rawValue),
                    "error": .string("\(error)"),
                ])
            }
        }
        return minimum
    }

    private func pollLiveness() async {
        for id in runtimes.keys {
            guard var runtime = runtimes[id], runtime.lifecycleState == .ready else { continue }
            let probe = await healthClient.checkLiveness(service: runtime)
            if probe.success {
                runtime.consecutiveProbeFailures = 0
                runtimes[id] = runtime
                continue
            }
            runtime.consecutiveProbeFailures += 1
            runtimes[id] = runtime
            if runtime.consecutiveProbeFailures >= runtime.service.health.failureThreshold {
                logger.warning("Liveness failed threshold", metadata: ["service_id": .string(id.rawValue)])
                await restartService(id, reason: .livenessFailed)
            }
        }
    }

    private var configBaseDirectory: String {
        URL(fileURLWithPath: watchFilePath).deletingLastPathComponent().path
    }

    private func fileMTime(path: String) -> Date? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return attrs[.modificationDate] as? Date
        } catch {
            return nil
        }
    }

    private func allocatePort(preferred: Int) throws -> Int {
        if preferred != 0 {
            return preferred
        }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw ProcessSpawnError("Failed to allocate port", metadata: ["reason": "socket"])
        }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            throw ProcessSpawnError("Failed to bind ephemeral port", metadata: ["errno": "\(errno)"])
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                getsockname(socketFD, ptr, &len)
            }
        }
        if getsocknameResult != 0 {
            throw ProcessSpawnError("Failed to inspect ephemeral port", metadata: ["errno": "\(errno)"])
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: - Container Registry (thread-safe, synchronous access)

    private func registerContainer(_ handle: ChildHandle) {
        _activeChildren.withLock { entries in
            entries.append(ChildEntry(containerID: handle.containerID))
        }
    }

    private func unregisterContainer(_ handle: ChildHandle) {
        _activeChildren.withLock { entries in
            entries.removeAll { $0.containerID == handle.containerID }
        }
    }

    /// Synchronously mark all tracked containers as abandoned.
    /// Safe to call from any isolation domain — does not require `await`.
    /// Used for emergency cleanup when the app is about to terminate.
    ///
    /// With the Containerization library, VMs run in-process. When the host
    /// process exits, all VMs are automatically terminated by the hypervisor.
    /// This method just clears the registry to prevent double-cleanup.
    public nonisolated func forceTerminateAll() {
        _activeChildren.withLock { $0.removeAll() }
    }
}
