import AIBConfig
import AIBGateway
import AIBRuntimeCore
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
        let gatewayToStop = gateway
        Task { [weak self, gatewayToStop] in
            await LocalAgentHandler.cancelAllAsyncRuns()
            await gatewayToStop?.control.shutdownActivityStreams()
            do {
                try await gatewayToStop?.stop()
            } catch {
                // shutdown() is best-effort and cannot throw. stop(graceful:)
                // remains the reporting path for explicit user-initiated stops.
            }
            await MainActor.run {
                if self?.gateway === gatewayToStop {
                    self?.gateway = nil
                }
            }
        }
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
        await LocalAgentHandler.cancelAllAsyncRuns()
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

            let loaded = try await AIBRuntimeCoreService.resolvePreparedWorkspaceConfig(
                workspaceRoot: workspaceRoot,
                gatewayPort: gatewayPort,
                processController: pc,
                logger: logger
            )
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }

            let gatewayControl = GatewayControl()
            let gateway = DevGateway(gatewayConfig: loaded.config.gateway, control: gatewayControl, logger: logger)
            do {
                try await gateway.start()
            } catch {
                do {
                    try await gateway.stop()
                } catch {
                    logger.warning("Gateway stop after start failure also failed", metadata: ["error": "\(error)"])
                }
                throw error
            }

            let preparedConfigCache = PreparedConfigCache(initial: loaded)
            let configLogger = logger
            let configProvider: ConfigProvider = { @Sendable in
                if let cached = await preparedConfigCache.takeInitial() {
                    return cached
                }
                return try await AIBRuntimeCoreService.resolvePreparedWorkspaceConfig(
                    workspaceRoot: workspaceRoot,
                    gatewayPort: gatewayPort,
                    processController: pc,
                    logger: configLogger
                )
            }

            let hasAgentServices = loaded.config.services.contains { $0.kind == .agent }
            if hasAgentServices {
                let authStatus = await CodexAppServerAgentRunner.checkAuthStatus()
                guard authStatus.isOAuthAuthenticated else {
                    throw NSError(
                        domain: "AIBEmulatorController",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "codex CLI must be installed and authenticated for local agent execution."
                        ]
                    )
                }
            }

            // Register local handlers for agent services so requests are processed
            // by Codex App Server CLI (subscription auth) instead of the container.
            var diagnosticTargets: [CodexPluginStartupDiagnosticTarget] = []
            for service in loaded.config.services where service.kind == .agent {
                let resolvedPluginRootPath = CodexAppServerPluginBundle.pluginRootURL(
                    baseURL: URL(fileURLWithPath: workspaceRoot)
                        .appendingPathComponent(".aib/generated/runtime/plugins", isDirectory: true),
                    serviceID: service.id.rawValue
                ).path
                let pluginRootPath = FileManager.default.fileExists(atPath: resolvedPluginRootPath)
                    ? resolvedPluginRootPath
                    : nil
                let executionDirectory = service.cwd
                let resolvedLocalEnv = service.resolvedEnv(for: .local)
                let resolvedModel = resolvedLocalEnv["MODEL"]
                let resolvedReasoningEffort = resolvedLocalEnv["MODEL_REASONING_EFFORT"]
                let handler = LocalAgentHandler.makeHandler(
                    serviceID: service.id,
                    pluginRootPath: pluginRootPath,
                    executionDirectory: executionDirectory,
                    model: resolvedModel,
                    reasoningEffort: resolvedReasoningEffort,
                    logger: logger
                )
                await gatewayControl.registerLocalHandler(serviceID: service.id, handler: handler)
                var metadata: Logger.Metadata = ["service_id": "\(service.id.rawValue)"]
                if let pluginRootPath {
                    metadata["plugin_root"] = "\(pluginRootPath)"
                    metadata["codex_mcp_config"] = "\(CodexAppServerPluginBundle.mcpConfigPath(pluginRootPath: pluginRootPath))"
                }
                if let resolvedModel {
                    metadata["model"] = "\(resolvedModel)"
                }
                if let resolvedReasoningEffort {
                    metadata["reasoning_effort"] = "\(resolvedReasoningEffort)"
                }
                logger.info("Registered local Codex App Server handler", metadata: metadata)
                diagnosticTargets.append(CodexPluginStartupDiagnosticTarget(
                    serviceID: service.id.rawValue,
                    pluginRootPath: pluginRootPath,
                    model: resolvedModel,
                    reasoningEffort: resolvedReasoningEffort
                ))
            }

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
            await CodexPluginStartupDiagnostics.run(
                targets: diagnosticTargets,
                logger: logger
            )

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
            await LocalAgentHandler.cancelAllAsyncRuns()
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
        await LocalAgentHandler.cancelAllAsyncRuns()
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

private struct CodexPluginStartupDiagnosticTarget {
    var serviceID: String
    var pluginRootPath: String?
    var model: String?
    var reasoningEffort: String?
}

private enum CodexPluginStartupDiagnostics {
    static func run(
        targets: [CodexPluginStartupDiagnosticTarget],
        logger: Logger
    ) async {
        for target in targets {
            await run(target: target, logger: logger)
        }
    }

    private static func run(
        target: CodexPluginStartupDiagnosticTarget,
        logger: Logger
    ) async {
        guard let pluginRootPath = target.pluginRootPath else {
            logger.warning("Codex plugin startup diagnostic failed", metadata: [
                "service_id": "\(target.serviceID)",
                "reason": "plugin_root_missing",
            ])
            return
        }

        let pluginRootURL = URL(fileURLWithPath: pluginRootPath, isDirectory: true)
        let skills = skillNames(pluginRootURL: pluginRootURL)
        logger.info("Codex plugin startup diagnostic: skills", metadata: [
            "service_id": "\(target.serviceID)",
            "plugin_root": "\(pluginRootPath)",
            "model": "\(target.model ?? "")",
            "reasoning_effort": "\(target.reasoningEffort ?? "")",
            "skill_count": "\(skills.count)",
            "skills": "\(skills.joined(separator: ","))",
        ])

        let mcpConfigURL = pluginRootURL.appendingPathComponent(CodexAppServerPluginBundle.mcpConfigFileName)
        guard FileManager.default.fileExists(atPath: mcpConfigURL.path) else {
            logger.warning("Codex plugin startup diagnostic failed", metadata: [
                "service_id": "\(target.serviceID)",
                "reason": "mcp_config_missing",
                "path": "\(mcpConfigURL.path)",
            ])
            return
        }

        do {
            let config = try loadMCPConfig(mcpConfigURL)
            logger.info("Codex plugin startup diagnostic: MCP config", metadata: [
                "service_id": "\(target.serviceID)",
                "mcp_config": "\(mcpConfigURL.path)",
                "server_count": "\(config.mcpServers.count)",
                "servers": "\(config.mcpServers.keys.sorted().joined(separator: ","))",
            ])
            for (name, server) in config.mcpServers.sorted(by: { $0.key < $1.key }) {
                await diagnoseMCPServer(
                    serviceID: target.serviceID,
                    name: name,
                    server: server,
                    logger: logger
                )
            }
        } catch {
            logger.warning("Codex plugin startup diagnostic failed", metadata: [
                "service_id": "\(target.serviceID)",
                "reason": "mcp_config_invalid",
                "path": "\(mcpConfigURL.path)",
                "error": "\(error)",
            ])
        }
    }

    private static func skillNames(pluginRootURL: URL) -> [String] {
        let pluginName = pluginName(pluginRootURL: pluginRootURL)
        let skillsURL = pluginRootURL.appendingPathComponent("skills", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { return nil }
            let raw = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
            let skillName = frontmatterValue(raw, key: "name") ?? entry.lastPathComponent
            guard let pluginName, !pluginName.isEmpty else {
                return skillName
            }
            return "\(pluginName):\(skillName)"
        }
        .sorted()
    }

    private static func frontmatterValue(_ raw: String, key: String) -> String? {
        guard raw.hasPrefix("---\n"), let endRange = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) else {
            return nil
        }
        let frontmatter = raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound]
        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func pluginName(pluginRootURL: URL) -> String? {
        let metadataURL = pluginRootURL
            .appendingPathComponent(CodexAppServerPluginBundle.manifestRelativePath, isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadMCPConfig(_ url: URL) throws -> StartupMCPProjectConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StartupMCPProjectConfig.self, from: data)
    }

    private static func diagnoseMCPServer(
        serviceID: String,
        name: String,
        server: StartupMCPServerConfig,
        logger: Logger
    ) async {
        guard server.type == nil || server.type == "http" else {
            logger.warning("Codex plugin startup diagnostic: MCP server skipped", metadata: [
                "service_id": "\(serviceID)",
                "server": "\(name)",
                "reason": "unsupported_type",
                "type": "\(server.type ?? "")",
            ])
            return
        }
        guard let urlString = server.url, let url = URL(string: urlString) else {
            logger.warning("Codex plugin startup diagnostic: MCP server skipped", metadata: [
                "service_id": "\(serviceID)",
                "server": "\(name)",
                "reason": "invalid_url",
                "url": "\(server.url ?? "")",
            ])
            return
        }

        do {
            _ = try await postJSONRPC(
                url: url,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": "2024-11-05",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "aib-startup-diagnostics",
                            "version": "0.1.0",
                        ],
                    ],
                ]
            )
            _ = try? await postJSONRPC(
                url: url,
                payload: [
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": [:],
                ]
            )
            let toolsResponse = try await postJSONRPC(
                url: url,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                    "params": [:],
                ]
            )
            let tools = ((toolsResponse["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let toolNames = tools.compactMap { $0["name"] as? String }.sorted()
            logger.info("Codex plugin startup diagnostic: MCP tools/list succeeded", metadata: [
                "service_id": "\(serviceID)",
                "server": "\(name)",
                "url": "\(urlString)",
                "tool_count": "\(tools.count)",
                "tools": "\(toolNames.joined(separator: ","))",
            ])
        } catch {
            logger.warning("Codex plugin startup diagnostic: MCP tools/list failed", metadata: [
                "service_id": "\(serviceID)",
                "server": "\(name)",
                "url": "\(urlString)",
                "error": "\(error)",
            ])
        }
    }

    private static func postJSONRPC(
        url: URL,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StartupDiagnosticError.httpStatus(status, body)
        }
        if data.isEmpty {
            return [:]
        }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let jsonData = Self.jsonPayloadData(from: data, contentType: contentType)
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw StartupDiagnosticError.invalidJSON
        }
        return object
    }

    private static func jsonPayloadData(from data: Data, contentType: String) -> Data {
        let loweredContentType = contentType.lowercased()
        guard loweredContentType.contains("text/event-stream"),
              let text = String(data: data, encoding: .utf8) else {
            return data
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            return Data(payload.utf8)
        }
        return data
    }
}

private struct StartupMCPProjectConfig: Decodable {
    var mcpServers: [String: StartupMCPServerConfig]
}

private struct StartupMCPServerConfig: Decodable {
    var type: String?
    var url: String?
}

private enum StartupDiagnosticError: Error, CustomStringConvertible {
    case httpStatus(Int, String)
    case invalidJSON

    var description: String {
        switch self {
        case .httpStatus(let status, let body):
            return "HTTP \(status): \(body)"
        case .invalidJSON:
            return "Invalid JSON response"
        }
    }
}

private actor PreparedConfigCache {
    private var initial: LoadedConfig?

    init(initial: LoadedConfig) {
        self.initial = initial
    }

    func takeInitial() -> LoadedConfig? {
        defer { initial = nil }
        return initial
    }
}
