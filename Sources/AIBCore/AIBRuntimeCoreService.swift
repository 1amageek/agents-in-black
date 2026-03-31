import AIBConfig
import AIBGateway
import AIBRuntimeCore
import AIBSupervisor
import AIBWorkspace
import Darwin
import Foundation
import Logging

public enum AIBRuntimeCoreService {
    private struct PreparedNodeServiceCandidate: Sendable {
        let index: Int
        let service: ServiceConfig
        let serviceID: String
        let repoRoot: String
    }

    private struct PreparedNodeServiceResult: Sendable {
        let index: Int
        let serviceID: String
        let preparedWorkspacePath: String
    }

    public static func validateConfig(
        options: AIBRuntimeOptions
    ) async throws -> AIBValidatedConfigSummary {
        let loaded = try resolveWorkspaceConfig(options: options)
        return AIBValidatedConfigSummary(
            serviceCount: loaded.config.services.count,
            warnings: loaded.warnings
        )
    }

    public static func effectiveConfigJSON(
        options: AIBRuntimeOptions
    ) async throws -> AIBEffectiveConfigJSON {
        let loaded = try resolveWorkspaceConfig(options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(loaded.config)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError("Failed to encode effective config as UTF-8 JSON")
        }
        return AIBEffectiveConfigJSON(json: text, warnings: loaded.warnings)
    }

    public static func runEmulatorUntilTermination(
        options: AIBRuntimeOptions,
        logger: Logger
    ) async throws {
        try ContainerCLIPolicy.ensureInstalled()
        let processController = ContainerProcessController(logger: logger)
        let initial = try await resolvePreparedWorkspaceConfig(
            options: options,
            processController: processController,
            logger: logger
        )

        if options.dryRun {
            return
        }

        if let pidPath = options.statePIDPath {
            try writePIDFile(path: pidPath)
        }
        defer {
            if let pidPath = options.statePIDPath {
                do {
                    try removePIDFile(path: pidPath)
                } catch {
                    logger.warning("Failed to clean pid file", metadata: ["path": "\(pidPath)", "error": "\(error)"])
                }
            }
        }

        let gatewayControl = GatewayControl()
        let gateway = DevGateway(gatewayConfig: initial.config.gateway, control: gatewayControl, logger: logger)
        try await gateway.start()
        do {
            let workspaceRoot = options.workspaceRoot
            let gatewayPort = options.gatewayPort
            let workspacePath = workspaceYAMLPath(workspaceRoot: workspaceRoot)
            let preparedConfigCache = PreparedConfigCache(initial: initial)
            let configProvider: ConfigProvider = { @Sendable in
                if let cached = await preparedConfigCache.takeInitial() {
                    return cached
                }
                return try await Self.resolvePreparedWorkspaceConfig(
                    workspaceRoot: workspaceRoot,
                    gatewayPort: gatewayPort,
                    processController: processController,
                    logger: logger
                )
            }
            let supervisor = DevSupervisor(
                gatewayControl: gatewayControl,
                configProvider: configProvider,
                watchFilePath: workspacePath,
                gatewayPort: initial.config.gateway.port,
                reloadEnabled: options.reloadEnabled,
                processController: processController,
                logger: logger
            )
            try await supervisor.startAll()
            do {
                try await waitForTerminationSignal()
            } catch {
                await supervisor.stopAll(graceful: true)
                try await gateway.stop()
                throw error
            }
            await supervisor.stopAll(graceful: true)
            try await gateway.stop()
        } catch {
            do {
                try await gateway.stop()
            } catch {
                logger.warning("Gateway stop during startup failure also failed", metadata: ["error": "\(error)"])
            }
            throw error
        }
    }

    public static func readEmulatorPIDStatus(path: String) -> AIBEmulatorPIDStatus {
        guard let pid = readPID(path: path) else {
            return .stopped
        }
        let result = Darwin.kill(pid, 0)
        return result == 0 ? .running(pid) : .stale(pid)
    }

    public static func stopEmulatorByPIDFile(path: String) throws {
        guard let pid = readPID(path: path) else {
            return
        }
        if Darwin.kill(pid, SIGTERM) != 0 {
            throw ProcessSpawnError("Failed to signal emulator", metadata: [
                "pid": "\(pid)",
                "errno": "\(errno)",
            ])
        }
    }

    // MARK: - Workspace config resolution

    static func resolveWorkspaceConfig(options: AIBRuntimeOptions) throws -> LoadedConfig {
        try resolveWorkspaceConfig(
            workspaceRoot: options.workspaceRoot,
            gatewayPort: options.gatewayPort
        )
    }

    static func resolveWorkspaceConfig(
        workspaceRoot: String,
        gatewayPort: Int?
    ) throws -> LoadedConfig {
        let path = workspaceYAMLPath(workspaceRoot: workspaceRoot)
        let workspace = try WorkspaceYAMLCodec.loadWorkspace(at: path)
        var resolved = try WorkspaceSyncer.resolveConfig(workspaceRoot: workspaceRoot, workspace: workspace)
        if let gatewayPort {
            resolved.config.gateway.port = gatewayPort
        }
        try WorkspaceSyncer.writeRuntimeConnectionArtifacts(
            config: resolved.config,
            workspaceRoot: workspaceRoot,
            gatewayPort: resolved.config.gateway.port
        )
        try WorkspaceSyncer.writeRuntimeClaudeCodePlugins(
            resolved: resolved,
            workspaceRoot: workspaceRoot,
            workspace: workspace
        )
        return LoadedConfig(config: resolved.config, warnings: resolved.warnings, configPath: path)
    }

    static func resolvePreparedWorkspaceConfig(
        options: AIBRuntimeOptions,
        processController: ContainerProcessController,
        logger: Logger
    ) async throws -> LoadedConfig {
        try await resolvePreparedWorkspaceConfig(
            workspaceRoot: options.workspaceRoot,
            gatewayPort: options.gatewayPort,
            processController: processController,
            logger: logger
        )
    }

    static func resolvePreparedWorkspaceConfig(
        workspaceRoot: String,
        gatewayPort: Int?,
        processController: ContainerProcessController,
        logger: Logger
    ) async throws -> LoadedConfig {
        let workspacePath = workspaceYAMLPath(workspaceRoot: workspaceRoot)
        let workspace = try WorkspaceYAMLCodec.loadWorkspace(at: workspacePath)
        var resolved = try WorkspaceSyncer.resolveConfig(workspaceRoot: workspaceRoot, workspace: workspace)
        if let gatewayPort {
            resolved.config.gateway.port = gatewayPort
        }
        let localTargetConfig = try AIBDeployService.loadTargetConfig(
            workspaceRoot: workspaceRoot,
            providerID: "local"
        )

        logger.info("Preparing emulator target", metadata: [
            "target": .string("local"),
            "build_mode": .string(localTargetConfig.buildMode.rawValue),
            "workspace_root": .string(workspaceRoot),
        ])

        try await prepareLocalNodeServices(
            resolved: &resolved,
            workspaceRoot: workspaceRoot,
            targetConfig: localTargetConfig,
            processController: processController,
            logger: logger
        )

        try WorkspaceSyncer.writeRuntimeConnectionArtifacts(
            config: resolved.config,
            workspaceRoot: workspaceRoot,
            gatewayPort: resolved.config.gateway.port
        )
        try WorkspaceSyncer.writeRuntimeClaudeCodePlugins(
            resolved: resolved,
            workspaceRoot: workspaceRoot,
            workspace: workspace
        )
        return LoadedConfig(config: resolved.config, warnings: resolved.warnings, configPath: workspacePath)
    }

    static func prepareLocalNodeServices(
        resolved: inout ResolvedConfig,
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        processController: ContainerProcessController,
        logger: Logger
    ) async throws {
        let candidates: [PreparedNodeServiceCandidate] = resolved.config.services.indices.compactMap { index in
            let service = resolved.config.services[index]
            let serviceID = service.id.rawValue
            guard service.kind != .agent else {
                logger.info("Skipping prepared workspace for local agent service", metadata: [
                    "service_id": .string(serviceID),
                ])
                return nil
            }
            guard let metadata = resolved.serviceMetadata[serviceID], metadata.runtime == .node else {
                return nil
            }
            let repoRoot = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(metadata.repoPath)
                .standardizedFileURL
                .path
            return PreparedNodeServiceCandidate(
                index: index,
                service: service,
                serviceID: serviceID,
                repoRoot: repoRoot
            )
        }

        guard !candidates.isEmpty else {
            return
        }

        logger.info("Preparing local Node services in parallel", metadata: [
            "count": .stringConvertible(candidates.count),
            "build_mode": .string(targetConfig.buildMode.rawValue),
        ])

        let buildMode = targetConfig.buildMode
        let sourceCredentials = targetConfig.sourceCredentials
        let convenience = targetConfig.convenience

        let results = try await withThrowingTaskGroup(
            of: PreparedNodeServiceResult.self,
            returning: [PreparedNodeServiceResult].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    let sourceDependencies = try AIBSourceDependencyAnalyzer.nodeGitDependencies(repoRoot: candidate.repoRoot)

                    if buildMode == .strict {
                        for dependency in sourceDependencies {
                            guard AIBSourceDependencyAnalyzer.matchingLocalCredential(
                                for: dependency,
                                in: sourceCredentials
                            ) != nil else {
                                throw BuildPreparationError(
                                    "Strict local build requires explicit source credentials for private Git dependencies",
                                    metadata: [
                                        "service_id": candidate.serviceID,
                                        "host": dependency.host,
                                        "source_file": dependency.sourceFile,
                                        "requirement": dependency.requirement,
                                    ]
                                )
                            }
                        }
                    }

                    let preparedWorkspacePath = try await processController.prepareNodeWorkspace(
                        service: candidate.service,
                        repoRoot: candidate.repoRoot,
                        workspaceRoot: workspaceRoot,
                        buildMode: buildMode,
                        sourceCredentials: sourceCredentials,
                        sourceDependencies: sourceDependencies,
                        convenience: convenience
                    )

                    return PreparedNodeServiceResult(
                        index: candidate.index,
                        serviceID: candidate.serviceID,
                        preparedWorkspacePath: preparedWorkspacePath
                    )
                }
            }

            var results: [PreparedNodeServiceResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        for result in results.sorted(by: { $0.index < $1.index }) {
            resolved.config.services[result.index].cwd = result.preparedWorkspacePath
            resolved.config.services[result.index].install = nil
            resolved.config.services[result.index].build = nil
            resolved.config.services[result.index].env["AIB_PREPARED_WORKSPACE"] = "1"
            resolved.config.services[result.index].env["AIB_BUILD_MODE"] = targetConfig.buildMode.rawValue
            resolved.config.services[result.index].env["AIB_ACTIVE_TARGET"] = "local"
            if targetConfig.buildMode == .convenience {
                logger.warning("Local emulator is running in convenience mode (not Cloud Run-aligned)", metadata: [
                    "service_id": .string(result.serviceID),
                ])
            }
        }
    }

    static func workspaceYAMLPath(workspaceRoot: String) -> String {
        URL(fileURLWithPath: ".aib/workspace.yaml", relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL
            .path
    }

    public static func localClaudeCodePluginRootPath(
        workspaceRoot: String,
        serviceID: String
    ) -> String {
        ClaudeCodePluginBundle.pluginRootURL(
            baseURL: URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(".aib/generated/runtime/plugins", isDirectory: true),
            serviceID: serviceID
        ).path
    }

    public static func localClaudeCodePluginBinding(
        workspaceRoot: String,
        serviceID: String
    ) throws -> ClaudeCodePluginBinding {
        let path = URL(fileURLWithPath: localClaudeCodePluginRootPath(workspaceRoot: workspaceRoot, serviceID: serviceID))
            .appendingPathComponent(ClaudeCodePluginBundle.bindingFileName)
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(ClaudeCodePluginBinding.self, from: data)
    }

    public static func localClaudeCodePluginLaunchCommand(
        workspaceRoot: String,
        serviceID: String
    ) -> String {
        ClaudeCodePluginBundle.manualLaunchCommand(
            pluginRootPath: localClaudeCodePluginRootPath(
                workspaceRoot: workspaceRoot,
                serviceID: serviceID
            )
        )
    }

    public static func deployClaudeCodePluginRootPath(
        workspaceRoot: String,
        deployedServiceName: String
    ) -> String {
        URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib/generated/deploy/services/\(deployedServiceName)/plugin", isDirectory: true)
            .standardizedFileURL
            .path
    }

    public static func deployClaudeCodePluginBinding(
        workspaceRoot: String,
        deployedServiceName: String
    ) throws -> ClaudeCodePluginBinding {
        let path = URL(fileURLWithPath: deployClaudeCodePluginRootPath(
            workspaceRoot: workspaceRoot,
            deployedServiceName: deployedServiceName
        )).appendingPathComponent(ClaudeCodePluginBundle.bindingFileName)
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(ClaudeCodePluginBinding.self, from: data)
    }

    public static func deployClaudeCodePluginLaunchCommand(
        workspaceRoot: String,
        deployedServiceName: String
    ) -> String {
        ClaudeCodePluginBundle.manualLaunchCommand(
            pluginRootPath: deployClaudeCodePluginRootPath(
                workspaceRoot: workspaceRoot,
                deployedServiceName: deployedServiceName
            )
        )
    }

    // MARK: - Signal handling

    private static func waitForTerminationSignal() async throws {
        let stream = AsyncStream<Void> { continuation in
            _ = signal(SIGINT, SIG_IGN)
            _ = signal(SIGTERM, SIG_IGN)

            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigterm.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            sigint.resume()
            sigterm.resume()

            continuation.onTermination = { _ in
                sigint.cancel()
                sigterm.cancel()
            }
        }

        for await _ in stream {
            break
        }
    }

    // MARK: - PID file management

    private static func writePIDFile(path: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "\(getpid())\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func removePIDFile(path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func readPID(path: String) -> pid_t? {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            guard let raw = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return raw
        } catch {
            return nil
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
