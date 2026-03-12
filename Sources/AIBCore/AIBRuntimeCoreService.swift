import AIBConfig
import AIBGateway
import AIBRuntimeCore
import AIBSupervisor
import AIBWorkspace
import Darwin
import Foundation
import Logging

public enum AIBRuntimeCoreService {
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
        let initial = try resolveWorkspaceConfig(options: options)

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
            let configProvider: ConfigProvider = { @Sendable in
                try Self.resolveWorkspaceConfig(
                    workspaceRoot: workspaceRoot,
                    gatewayPort: gatewayPort
                )
            }
            let supervisor = DevSupervisor(
                gatewayControl: gatewayControl,
                configProvider: configProvider,
                watchFilePath: workspacePath,
                gatewayPort: initial.config.gateway.port,
                reloadEnabled: options.reloadEnabled,
                processController: ContainerProcessController(logger: logger),
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
        try WorkspaceSyncer.writeRuntimeSkillArtifacts(
            resolved: resolved,
            workspaceRoot: workspaceRoot,
            workspace: workspace
        )
        return LoadedConfig(config: resolved.config, warnings: resolved.warnings, configPath: path)
    }

    static func workspaceYAMLPath(workspaceRoot: String) -> String {
        URL(fileURLWithPath: ".aib/workspace.yaml", relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL
            .path
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
