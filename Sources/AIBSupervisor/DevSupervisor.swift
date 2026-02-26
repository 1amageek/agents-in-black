import AIBConfig
import AIBGateway
import AIBRuntimeCore
import Foundation
import Logging

public actor DevSupervisor {
    public nonisolated let gatewayControl: GatewayControl

    private let processController: ProcessController
    private let healthClient: HealthProbeClient
    private let logger: Logger
    private let logMux: LogMux
    private let configPath: String
    private let overrides: ConfigOverrides
    private let gatewayPort: Int
    private let reloadEnabled: Bool

    private var currentConfig: AIBConfig?
    private var configVersion: Int = 0
    private var runtimes: [ServiceID: ServiceRuntime] = [:]
    private var configPollTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var configFileMTime: Date?

    public init(
        gatewayControl: GatewayControl,
        configPath: String,
        overrides: ConfigOverrides = .init(),
        gatewayPort: Int,
        reloadEnabled: Bool = true,
        processController: ProcessController = DefaultProcessController(),
        healthClient: HealthProbeClient = DefaultHealthProbeClient(),
        logger: Logger
    ) {
        self.gatewayControl = gatewayControl
        self.configPath = configPath
        self.overrides = overrides
        self.gatewayPort = gatewayPort
        self.reloadEnabled = reloadEnabled
        self.processController = processController
        self.healthClient = healthClient
        self.logger = logger
        self.logMux = LogMux(logger: logger)
    }

    public func startAll() async {
        do {
            let loaded = try await AIBConfigLoader.load(configPath: configPath, overrides: overrides)
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            try await applyInitialConfig(loaded.config)
            configFileMTime = fileMTime(path: loaded.configPath)
            if reloadEnabled {
                startConfigPolling()
            }
            startLivenessMonitoring()
        } catch {
            logger.error("Failed to start supervisor", metadata: ["error": "\(error)"])
        }
    }

    public func reloadConfig(trigger: ReloadTrigger) async {
        do {
            logger.info("Reloading config", metadata: ["trigger": "\(trigger.rawValue)"])
            let loaded = try await AIBConfigLoader.load(configPath: configPath, overrides: overrides)
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            try await applyReloadedConfig(loaded.config)
            configFileMTime = fileMTime(path: loaded.configPath)
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

    private func applyInitialConfig(_ config: AIBConfig) async throws {
        configVersion += 1
        currentConfig = config
        for service in config.services {
            runtimes[service.id] = ServiceRuntime(service: service, configVersion: configVersion)
        }
        for service in config.services {
            try await prepareAndStart(service: service, reason: .initialStart)
        }
        try await publishRoutes()
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
        if service.watchMode == .external {
            try await runInstallIfNeeded(service: service)
            try await runBuildIfNeeded(service: service)
        }
        try await startService(id: service.id)
        logger.info("Service started", metadata: ["service_id": .string(service.id.rawValue), "reason": .string(reason.rawValue)])
    }

    private func startService(id: ServiceID) async throws {
        guard var runtime = runtimes[id] else { return }
        runtime.lifecycleState = .starting
        runtime.desiredState = .running
        runtime.consecutiveProbeFailures = 0
        runtimes[id] = runtime

        let resolvedPort = try allocatePort(preferred: runtime.service.port)
        let handle = try await processController.spawn(
            service: runtime.service,
            resolvedPort: resolvedPort,
            gatewayPort: gatewayPort,
            configBaseDirectory: configDirectoryPath
        )
        logMux.attach(handle)

        runtime.childHandle = handle
        runtime.resolvedPort = resolvedPort
        runtime.backendEndpoint = BackendEndpoint(port: resolvedPort)
        runtimes[id] = runtime

        let ready = try await waitForReadiness(id: id)
        if ready {
            runtime = runtimes[id] ?? runtime
            runtime.lifecycleState = .ready
            runtimes[id] = runtime
            await gatewayControl.markServiceReady(id, endpoint: BackendEndpoint(port: resolvedPort))
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
        while Date() < deadline {
            if let handle = (runtimes[id]?.childHandle), !handle.process.isRunning {
                return false
            }
            let probe = await healthClient.checkReadiness(service: runtimes[id] ?? runtime)
            if probe.success { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
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
            let drain = (try? runtime.service.restart.drainTimeout.parse()) ?? .seconds(1)
            try? await Task.sleep(for: drain)
        }

        runtime.lifecycleState = .stopping
        runtimes[id] = runtime
        let grace = (try? runtime.service.restart.shutdownGracePeriod.parse()) ?? .seconds(5)
        let result = await processController.terminateGroup(handle, grace: grace)
        if !result.terminatedGracefully {
            await processController.killGroup(handle)
        }
        logMux.detach(handle)

        runtime.childHandle = nil
        runtime.backendEndpoint = nil
        runtime.resolvedPort = nil
        runtime.lastExitStatus = handle.process.terminationStatus
        runtime.lifecycleState = .stopped
        runtimes[id] = runtime
        await gatewayControl.markServiceUnavailable(id, reason: .startup)
    }

    private func runBuildIfNeeded(service: ServiceConfig) async throws {
        guard let build = service.build else { return }
        try await runOneShotCommand(argv: build, service: service, label: "build")
    }

    private func runInstallIfNeeded(service: ServiceConfig) async throws {
        guard let install = service.install else { return }
        // v1: run install on startup/restart; lockfile-specific optimization is deferred.
        try await runOneShotCommand(argv: install, service: service, label: "install")
    }

    private func runOneShotCommand(argv: [String], service: ServiceConfig, label: String) async throws {
        guard let command = argv.first else { return }
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + Array(argv.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: service.cwd.map { path in
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: configDirectoryPath)).standardizedFileURL.path
        } ?? configDirectoryPath)

        pipe.fileHandleForReading.readabilityHandler = { [logger, serviceID = service.id.rawValue] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            text.split(whereSeparator: \.isNewline).forEach { line in
                logger.info("[\(serviceID)][\(label)] \(line)")
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessSpawnError("Failed to run \(label)", metadata: [
                "service_id": service.id.rawValue,
                "command": argv.joined(separator: " "),
                "error": "\(error)",
            ])
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if process.terminationStatus != 0 {
            throw ProcessSpawnError("\(label) failed", metadata: [
                "service_id": service.id.rawValue,
                "termination_status": "\(process.terminationStatus)",
            ])
        }
    }

    private func startConfigPolling() {
        configPollTask?.cancel()
        configPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self.pollConfigFileChange()
            }
        }
    }

    private func pollConfigFileChange() async {
        let current = fileMTime(path: configPath)
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
                try? await Task.sleep(for: .seconds(2))
                await self.pollLiveness()
            }
        }
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

    private var configDirectoryPath: String {
        URL(fileURLWithPath: configPath).deletingLastPathComponent().path
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
}
