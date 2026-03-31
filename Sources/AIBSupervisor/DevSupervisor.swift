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

private struct ServiceStartupAttemptResult: Sendable {
    let serviceID: ServiceID
    let errorDescription: String?
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
        if isLocallyHandled(runtime.service) {
            do {
                try materializeConnectionArtifactsIfNeeded(for: runtime.service)
                runtime.lifecycleState = .ready
                runtime.desiredState = .running
                runtime.consecutiveProbeFailures = 0
                runtimes[id] = runtime
                try await publishRoutes()
                logger.info("Refreshed local agent service", metadata: ["service_id": "\(id)"])
            } catch {
                logger.error("Local agent refresh failed", metadata: ["service_id": "\(id)", "error": "\(error)"])
            }
            return
        }
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
        // Release containers and forwarders but keep vmnet network alive for reuse.
        await processController.stopAll()
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
        try prepareLocalHandledServices(config.services)
        // Publish mount paths immediately so early requests get service_unavailable (not no_route)
        // while the remaining services are still booting.
        try await publishRoutes()
        let startupBatches = try startupBatches(from: containerManagedServices(config.services))
        let failedServices = await startServicesInBatches(
            startupBatches,
            allServices: containerManagedServices(config.services),
            reason: .initialStart,
            continueOnFailure: true
        )
        if !failedServices.isEmpty {
            logger.warning("Some services failed to start", metadata: [
                "failed": .string(failedServices.map(\.rawValue).sorted().joined(separator: ", ")),
                "total": .stringConvertible(config.services.count),
                "running": .stringConvertible(config.services.count - failedServices.count),
            ])
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
            }
        }

        for id in added {
            if let service = newByID[id] {
                runtimes[id] = ServiceRuntime(service: service, configVersion: configVersion)
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

        try prepareLocalHandledServices(newConfig.services)

        let servicesToStart = Set(changed).union(added)
        if !servicesToStart.isEmpty {
            let startupBatches = try startupBatches(from: containerManagedServices(newConfig.services))
            let failedServices = await startServicesInBatches(
                startupBatches,
                allServices: containerManagedServices(newConfig.services),
                reason: .configReload,
                limitTo: servicesToStart,
                continueOnFailure: false
            )
            if let failedService = failedServices.sorted(by: { $0.rawValue < $1.rawValue }).first {
                throw ReloadApplyError("Service failed to start during reload", metadata: [
                    "service_id": failedService.rawValue,
                ])
            }
        }

        try await publishRoutes()
    }

    private func startServicesInBatches(
        _ batches: [[ServiceConfig]],
        allServices: [ServiceConfig],
        reason: RestartReason,
        limitTo selectedServices: Set<ServiceID>? = nil,
        continueOnFailure: Bool
    ) async -> Set<ServiceID> {
        let knownServiceIDs = Set(allServices.map(\.id))
        var failedServices: Set<ServiceID> = []

        for batch in batches {
            let eligibleServices = batch.filter { service in
                selectedServices?.contains(service.id) ?? true
            }
            guard !eligibleServices.isEmpty else {
                continue
            }

            let runnableServices = eligibleServices.filter { service in
                serviceConnectionDependencies(for: service, knownServiceIDs: knownServiceIDs)
                    .isDisjoint(with: failedServices)
            }
            let skippedServices = eligibleServices.filter { service in
                !serviceConnectionDependencies(for: service, knownServiceIDs: knownServiceIDs)
                    .isDisjoint(with: failedServices)
            }

            for service in skippedServices {
                logger.error("Skipping service start because dependency failed", metadata: [
                    "service_id": .string(service.id.rawValue),
                    "failed_dependencies": .string(
                        serviceConnectionDependencies(for: service, knownServiceIDs: knownServiceIDs)
                            .intersection(failedServices)
                            .map(\.rawValue)
                            .sorted()
                            .joined(separator: ", ")
                    ),
                ])
                failedServices.insert(service.id)
            }

            guard !runnableServices.isEmpty else {
                continue
            }

            logger.info("Starting service batch", metadata: [
                "reason": .string(reason.rawValue),
                "service_ids": .string(runnableServices.map { $0.id.rawValue }.sorted().joined(separator: ", ")),
                "count": .stringConvertible(runnableServices.count),
            ])

            let batchFailures = await withTaskGroup(
                of: ServiceStartupAttemptResult.self,
                returning: Set<ServiceID>.self
            ) { group in
                for service in runnableServices {
                    group.addTask {
                        do {
                            try await self.prepareAndStart(service: service, reason: reason)
                            return ServiceStartupAttemptResult(serviceID: service.id, errorDescription: nil)
                        } catch {
                            return ServiceStartupAttemptResult(serviceID: service.id, errorDescription: "\(error)")
                        }
                    }
                }

                var failures: Set<ServiceID> = []
                for await result in group {
                    guard let errorDescription = result.errorDescription else {
                        continue
                    }
                    self.logger.error("Service failed to start — continuing with remaining services", metadata: [
                        "service_id": .string(result.serviceID.rawValue),
                        "error": .string(errorDescription),
                    ])
                    failures.insert(result.serviceID)
                }
                return failures
            }

            failedServices.formUnion(batchFailures)
            if !continueOnFailure, !batchFailures.isEmpty {
                break
            }
        }

        return failedServices
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
            // Agent services use local Claude Code CLI (subscription auth) in dev mode.
            // Do not inject API keys into agent containers to avoid API billing.
            if service.kind == .agent && (key == "ANTHROPIC_API_KEY" || key == "ANTHROPIC_AUTH_TOKEN") {
                continue
            }
            service.env[key] = value
        }

        // Log API key prefixes for debugging
        for (key, value) in service.env where key.contains("API_KEY") || key.contains("APIKEY") {
            let prefix = String(value.prefix(20))
            logger.info("Env \(key)=\(prefix)…", metadata: ["service_id": .string(id.rawValue)])
        }

        try materializeConnectionArtifactsIfNeeded(for: service)

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
        let endpoint = handle.backendEndpoint
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
        var waitingRunPhaseLogged = false
        var appliedRunPhaseSettlingDelay = false
        while Date() < deadline {
            guard let handle = runtimes[id]?.childHandle else {
                return false
            }

            if !handle.isRunning {
                logger.warning("Container exited before becoming ready", metadata: [
                    "service_id": .string(id.rawValue),
                ])
                return false
            }

            if handle.usesRunPhaseSignal && !handle.hasStartedRunPhase {
                if !waitingRunPhaseLogged {
                    logger.debug("Waiting for service run phase before readiness probing", metadata: [
                        "service_id": .string(id.rawValue),
                    ])
                    waitingRunPhaseLogged = true
                }
                try await Task.sleep(for: .milliseconds(500))
                continue
            }

            if handle.usesRunPhaseSignal && !appliedRunPhaseSettlingDelay {
                appliedRunPhaseSettlingDelay = true
                logger.debug("Applying post-run-phase settling delay before readiness probing", metadata: [
                    "service_id": .string(id.rawValue),
                    "delay_ms": .string("500"),
                ])
                try await Task.sleep(for: .milliseconds(500))
                continue
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
            "readiness_target": .string("\(runtime.backendEndpoint?.baseURLString ?? "none")\(runtime.service.health.readinessPath)"),
            "container_running": .string("\(runtime.childHandle?.isRunning ?? false)"),
            "run_phase_started": .string("\(runtime.childHandle?.hasStartedRunPhase ?? false)"),
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
            if runtime.lifecycleState != .ready && !isLocallyHandled(runtime.service) {
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
        if draining {
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
        } else {
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
        for runtime in runtimes.values where runtime.lifecycleState == .ready && !isLocallyHandled(runtime.service) {
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
            guard var runtime = runtimes[id], runtime.lifecycleState == .ready, !isLocallyHandled(runtime.service) else { continue }
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

    private func startupBatches(from services: [ServiceConfig]) throws -> [[ServiceConfig]] {
        if services.isEmpty {
            return []
        }

        let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let serviceOrderIndex = Dictionary(uniqueKeysWithValues: services.enumerated().map { ($1.id, $0) })
        let knownServiceIDs = Set(servicesByID.keys)

        var indegree = Dictionary(uniqueKeysWithValues: services.map { ($0.id, 0) })
        var dependents: [ServiceID: [ServiceID]] = [:]

        for service in services {
            let dependencies = serviceConnectionDependencies(for: service, knownServiceIDs: knownServiceIDs)
            for dependencyID in dependencies {
                indegree[service.id, default: 0] += 1
                dependents[dependencyID, default: []].append(service.id)
            }
        }

        var queue = services
            .map(\.id)
            .filter { indegree[$0] == 0 }
            .sorted { (serviceOrderIndex[$0] ?? 0) < (serviceOrderIndex[$1] ?? 0) }
        var batches: [[ServiceConfig]] = []

        while !queue.isEmpty {
            let currentLevel = queue
            queue.removeAll(keepingCapacity: true)

            let batch = currentLevel.compactMap { servicesByID[$0] }
            batches.append(batch)

            for currentID in currentLevel {
                let nextDependents = (dependents[currentID] ?? [])
                    .sorted { (serviceOrderIndex[$0] ?? 0) < (serviceOrderIndex[$1] ?? 0) }
                for dependentID in nextDependents {
                    let updated = (indegree[dependentID] ?? 0) - 1
                    indegree[dependentID] = updated
                    if updated == 0 {
                        queue.append(dependentID)
                    }
                }
            }
            queue.sort { (serviceOrderIndex[$0] ?? 0) < (serviceOrderIndex[$1] ?? 0) }
        }

        let scheduledCount = batches.reduce(into: 0) { partial, batch in
            partial += batch.count
        }
        if scheduledCount != services.count {
            let blocked = indegree
                .filter { $0.value > 0 }
                .map { $0.key.rawValue }
                .sorted()
                .joined(separator: ",")
            throw ReloadApplyError(
                "Service dependency cycle detected",
                metadata: ["blocked_services": blocked]
            )
        }

        return batches
    }

    private func serviceConnectionDependencies(
        for service: ServiceConfig,
        knownServiceIDs: Set<ServiceID>
    ) -> Set<ServiceID> {
        _ = knownServiceIDs
        // Service-ref targets are resolved through the local gateway, so startup
        // does not need to wait for the target container to become ready.
        return []
    }

    private func prepareLocalHandledServices(_ services: [ServiceConfig]) throws {
        for service in services where isLocallyHandled(service) {
            try materializeConnectionArtifactsIfNeeded(for: service)
            guard var runtime = runtimes[service.id] else {
                throw ReloadApplyError(
                    "Local handled service missing in runtime map",
                    metadata: ["service_id": service.id.rawValue]
                )
            }
            runtime.lifecycleState = .ready
            runtime.desiredState = .running
            runtime.consecutiveProbeFailures = 0
            runtimes[service.id] = runtime
        }
    }

    private func containerManagedServices(_ services: [ServiceConfig]) -> [ServiceConfig] {
        services.filter { !isLocallyHandled($0) }
    }

    private func isLocallyHandled(_ service: ServiceConfig) -> Bool {
        service.kind == .agent
    }

    private func materializeConnectionArtifactsIfNeeded(for service: ServiceConfig) throws {
        guard service.kind == .agent else {
            return
        }

        let mcpTargets = try resolveRuntimeConnectionTargets(
            service.connections.mcpServers,
            defaultPathProvider: { target in target.mcp?.path ?? "/mcp" }
        )
        let a2aTargets = try resolveRuntimeConnectionTargets(
            service.connections.a2aAgents,
            defaultPathProvider: { target in target.a2a?.rpcPath ?? "/a2a" }
        )

        try writeRuntimeConnectionArtifact(
            serviceID: service.id.rawValue,
            mcpTargets: mcpTargets,
            a2aTargets: a2aTargets
        )
    }

    private func resolveRuntimeConnectionTargets(
        _ targets: [ServiceConnectionTarget],
        defaultPathProvider: (ServiceConfig) -> String
    ) throws -> [RuntimeResolvedConnectionTarget] {
        var resolved: [RuntimeResolvedConnectionTarget] = []
        for target in targets {
            if let url = target.url, !url.isEmpty {
                resolved.append(RuntimeResolvedConnectionTarget(
                    serviceRef: nil,
                    resolvedURL: url,
                    source: "url"
                ))
                continue
            }

            guard let serviceRef = target.serviceRef, !serviceRef.isEmpty else {
                continue
            }
            let targetID = ServiceID(serviceRef)
            guard let targetRuntime = runtimes[targetID] else {
                throw ReloadApplyError(
                    "Connection target service missing in runtime map",
                    metadata: [
                        "service_ref": serviceRef,
                    ]
                )
            }

            let suffix = normalizedPath(defaultPathProvider(targetRuntime.service))
            let resolvedURL = "http://localhost:\(gatewayPort)\(targetRuntime.service.mountPath)\(suffix)"
            resolved.append(RuntimeResolvedConnectionTarget(
                serviceRef: serviceRef,
                resolvedURL: resolvedURL,
                source: "service_ref"
            ))
        }
        return resolved
    }

    private func writeRuntimeConnectionArtifact(
        serviceID: String,
        mcpTargets: [RuntimeResolvedConnectionTarget],
        a2aTargets: [RuntimeResolvedConnectionTarget]
    ) throws {
        let outputRoot = URL(fileURLWithPath: configBaseDirectory)
            .appendingPathComponent("generated/runtime/connections")
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            throw ProcessSpawnError(
                "Failed to create runtime connection output directory",
                metadata: [
                    "path": outputRoot.path,
                    "underlying_error": "\(error)",
                ]
            )
        }

        let artifact = RuntimeConnectionArtifact(
            serviceID: serviceID,
            mcpServers: mcpTargets,
            a2aAgents: a2aTargets
        )
        let outputURL = outputRoot
            .appendingPathComponent("\(sanitizedServiceID(serviceID)).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(artifact)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw ProcessSpawnError(
                "Failed to write runtime connection artifact",
                metadata: [
                    "path": outputURL.path,
                    "underlying_error": "\(error)",
                ]
            )
        }
    }

    private func sanitizedServiceID(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "__")
    }

    private func normalizedPath(_ path: String) -> String {
        if path.isEmpty {
            return ""
        }
        if path.hasPrefix("/") {
            return path
        }
        return "/" + path
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

private struct RuntimeConnectionArtifact: Codable {
    var serviceID: String
    var mcpServers: [RuntimeResolvedConnectionTarget]
    var a2aAgents: [RuntimeResolvedConnectionTarget]

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case mcpServers = "mcp_servers"
        case a2aAgents = "a2a_agents"
    }
}

private struct RuntimeResolvedConnectionTarget: Codable {
    var serviceRef: String?
    var resolvedURL: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case serviceRef = "service_ref"
        case resolvedURL = "resolved_url"
        case source
    }
}
