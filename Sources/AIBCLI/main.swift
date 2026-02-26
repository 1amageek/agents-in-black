import AIBConfig
import AIBGateway
import AIBRuntimeCore
import AIBSupervisor
import AIBWorkspace
import Darwin
import Foundation
import Logging

enum ExitCode {
    static let ok = 0
    static let validationError = 2
    static let runtimeStartError = 3
    static let supervisorError = 4
    static let deployError = 5
    static let externalToolMissing = 6
}

struct RuntimeOptions {
    var configPath: String
    var gatewayPort: Int?
    var logLevel: String
    var reloadEnabled: Bool
    var dryRun: Bool
    var statePIDPath: String?

    init(
        configPath: String,
        gatewayPort: Int? = nil,
        logLevel: String = "info",
        reloadEnabled: Bool = true,
        dryRun: Bool = false,
        statePIDPath: String? = nil
    ) {
        self.configPath = configPath
        self.gatewayPort = gatewayPort
        self.logLevel = logLevel
        self.reloadEnabled = reloadEnabled
        self.dryRun = dryRun
        self.statePIDPath = statePIDPath
    }
}

@main
struct AIBDevMain {
    static func main() async {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        var logger = Logger(label: "aib")
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            printHelp()
            Foundation.exit(Int32(ExitCode.ok))
        }
        do {
            try await dispatch(arguments: args, logger: &logger)
        } catch {
            logger.error("Command failed", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func dispatch(arguments: [String], logger: inout Logger) async throws {
        switch arguments[0] {
        case "init":
            try await handleInit(arguments: Array(arguments.dropFirst()), logger: logger)
        case "workspace":
            try await handleWorkspace(arguments: Array(arguments.dropFirst()), logger: logger)
        case "emulator":
            try await handleEmulator(arguments: Array(arguments.dropFirst()), logger: logger)
        case "deploy":
            try await handleDeploy(arguments: Array(arguments.dropFirst()), logger: logger)
        case "run", "validate-config", "print-effective-config":
            let legacy = parseLegacyRuntimeOptions(arguments: arguments)
            logger.logLevel = level(from: legacy.logLevel)
            await runLegacy(command: arguments[0], options: legacy, logger: logger)
        default:
            printHelp()
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func handleInit(arguments: [String], logger: Logger) async throws {
        let cwd = FileManager.default.currentDirectoryPath
        var scanPath = cwd
        var force = false
        var scanEnabled = true
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--scan":
                i += 1
                if i < arguments.count { scanPath = arguments[i] }
            case "--no-scan":
                scanEnabled = false
            case "--force":
                force = true
            default:
                break
            }
            i += 1
        }

        let result = try AIBWorkspaceManager.initWorkspace(
            options: .init(workspaceRoot: cwd, scanPath: scanPath, force: force, scanEnabled: scanEnabled)
        )
        logger.info("Workspace initialized", metadata: [
            "workspace": "\(result.workspaceConfig.workspaceName)",
            "repos": "\(result.workspaceConfig.repos.count)",
            "generated_services": "\(result.generatedServices)",
        ])
        for warning in result.warnings {
            logger.warning("Workspace init warning", metadata: ["warning": "\(warning)"])
        }
        Foundation.exit(Int32(ExitCode.ok))
    }

    private static func handleWorkspace(arguments: [String], logger: Logger) async throws {
        guard let subcommand = arguments.first else {
            throw ConfigError("Missing workspace subcommand")
        }
        let cwd = FileManager.default.currentDirectoryPath
        switch subcommand {
        case "list":
            let workspace = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: cwd)
            for repo in workspace.repos {
                print("\(repo.name)\t\(repo.status.rawValue)\t\(repo.runtime.rawValue)/\(repo.framework.rawValue)\t\(repo.path)")
            }
            Foundation.exit(Int32(ExitCode.ok))
        case "scan":
            let result = try AIBWorkspaceManager.rescanWorkspace(workspaceRoot: cwd)
            logger.info("Workspace scanned", metadata: ["repos": "\(result.workspaceConfig.repos.count)", "generated_services": "\(result.generatedServices)"])
            for warning in result.warnings { logger.warning("Workspace scan warning", metadata: ["warning": "\(warning)"]) }
            Foundation.exit(Int32(ExitCode.ok))
        case "sync":
            let result = try AIBWorkspaceManager.syncWorkspace(workspaceRoot: cwd)
            logger.info("Workspace synced", metadata: ["generated_services": "\(result.serviceCount)"])
            for warning in result.warnings { logger.warning("Workspace sync warning", metadata: ["warning": "\(warning)"]) }
            Foundation.exit(Int32(ExitCode.ok))
        default:
            throw ConfigError("Unknown workspace subcommand", metadata: ["subcommand": subcommand])
        }
    }

    private static func handleEmulator(arguments: [String], logger: Logger) async throws {
        guard let subcommand = arguments.first else {
            throw ConfigError("Missing emulator subcommand")
        }
        let cwd = FileManager.default.currentDirectoryPath
        let servicesConfigPath = URL(fileURLWithPath: ".aib/services.yaml", relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        let pidFile = URL(fileURLWithPath: ".aib/state/emulator.pid", relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path

        switch subcommand {
        case "start":
            let options = parseRuntimeFlags(
                arguments: Array(arguments.dropFirst()),
                defaultConfigPath: servicesConfigPath,
                defaultStatePIDPath: pidFile
            )
            await runLegacy(command: "run", options: options, logger: logger)
        case "validate":
            let options = parseRuntimeFlags(arguments: Array(arguments.dropFirst()), defaultConfigPath: servicesConfigPath)
            await runLegacy(command: "validate-config", options: options, logger: logger)
        case "status":
            if let pid = readPID(path: pidFile) {
                let alive = Darwin.kill(pid, 0) == 0
                print(alive ? "running pid=\(pid)" : "stale pid=\(pid)")
                Foundation.exit(Int32(ExitCode.ok))
            }
            print("stopped")
            Foundation.exit(Int32(ExitCode.ok))
        case "stop":
            guard let pid = readPID(path: pidFile) else {
                logger.warning("Emulator not running")
                Foundation.exit(Int32(ExitCode.ok))
            }
            if Darwin.kill(pid, SIGTERM) != 0 {
                logger.warning("Failed to signal emulator", metadata: ["pid": "\(pid)", "errno": "\(errno)"])
            }
            Foundation.exit(Int32(ExitCode.ok))
        case "reload", "logs":
            throw UnsupportedFeatureError("emulator \(subcommand) is not implemented in v1")
        default:
            throw ConfigError("Unknown emulator subcommand", metadata: ["subcommand": subcommand])
        }
    }

    private static func handleDeploy(arguments: [String], logger: Logger) async throws {
        guard let subcommand = arguments.first else {
            throw ConfigError("Missing deploy subcommand")
        }
        let cwd = FileManager.default.currentDirectoryPath
        let workspace = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: cwd)
        switch subcommand {
        case "plan", "diff":
            let managed = workspace.repos.filter { $0.enabled && $0.status == .managed }
            let discoverable = workspace.repos.filter { $0.enabled && $0.status == .discoverable }
            logger.info("Deploy plan (stub)", metadata: [
                "workspace": "\(workspace.workspaceName)",
                "managed_repos": "\(managed.count)",
                "discoverable_repos": "\(discoverable.count)",
            ])
            print("Deploy plan is stubbed in v1. Use workspace sync + repo-specific deploy commands for now.")
            Foundation.exit(Int32(ExitCode.ok))
        case "apply":
            logger.error("Deploy apply is not implemented in v1")
            Foundation.exit(Int32(ExitCode.deployError))
        default:
            throw ConfigError("Unknown deploy subcommand", metadata: ["subcommand": subcommand])
        }
    }

    private static func parseRuntimeFlags(
        arguments: [String],
        defaultConfigPath: String,
        defaultStatePIDPath: String? = nil
    ) -> RuntimeOptions {
        var options = RuntimeOptions(configPath: defaultConfigPath, statePIDPath: defaultStatePIDPath)
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--config":
                i += 1
                if i < arguments.count { options.configPath = arguments[i] }
            case "--gateway-port":
                i += 1
                if i < arguments.count { options.gatewayPort = Int(arguments[i]) }
            case "--log-level":
                i += 1
                if i < arguments.count { options.logLevel = arguments[i] }
            case "--no-reload":
                options.reloadEnabled = false
            case "--dry-run":
                options.dryRun = true
            default:
                break
            }
            i += 1
        }
        return options
    }

    private static func parseLegacyRuntimeOptions(arguments: [String]) -> RuntimeOptions {
        let tail = Array(arguments.dropFirst())
        return parseRuntimeFlags(arguments: tail, defaultConfigPath: "./services.yaml")
    }

    private static func runLegacy(command: String, options: RuntimeOptions, logger: Logger) async {
        switch command {
        case "validate-config":
            await validateConfig(options: options, logger: logger)
        case "print-effective-config":
            await printEffectiveConfig(options: options, logger: logger)
        case "run":
            await runRuntime(options: options, logger: logger)
        default:
            logger.error("Unknown command", metadata: ["command": "\(command)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func validateConfig(options: RuntimeOptions, logger: Logger) async {
        do {
            let loaded = try await AIBConfigLoader.load(
                configPath: options.configPath,
                overrides: .init(gatewayPort: options.gatewayPort, logLevel: options.logLevel)
            )
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            logger.info("Configuration valid", metadata: ["services": "\(loaded.config.services.count)"])
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Configuration invalid", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func printEffectiveConfig(options: RuntimeOptions, logger: Logger) async {
        do {
            let loaded = try await AIBConfigLoader.load(
                configPath: options.configPath,
                overrides: .init(gatewayPort: options.gatewayPort, logLevel: options.logLevel)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(loaded.config)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            for warning in loaded.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Failed to print effective config", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func runRuntime(options: RuntimeOptions, logger: Logger) async {
        do {
            let initial = try await AIBConfigLoader.load(
                configPath: options.configPath,
                overrides: .init(gatewayPort: options.gatewayPort, logLevel: options.logLevel, reloadEnabled: options.reloadEnabled)
            )
            if options.dryRun {
                logger.info("Dry run succeeded", metadata: ["services": "\(initial.config.services.count)"])
                Foundation.exit(Int32(ExitCode.ok))
            }

            if let pidPath = options.statePIDPath {
                try writePIDFile(path: pidPath)
            }
            defer {
                if let pidPath = options.statePIDPath {
                    removePIDFile(path: pidPath)
                }
            }

            let gatewayControl = GatewayControl()
            let gateway = DevGateway(gatewayConfig: initial.config.gateway, control: gatewayControl, logger: logger)
            try await gateway.start()

            let supervisor = DevSupervisor(
                gatewayControl: gatewayControl,
                configPath: options.configPath,
                overrides: .init(gatewayPort: options.gatewayPort, logLevel: options.logLevel, reloadEnabled: options.reloadEnabled),
                gatewayPort: initial.config.gateway.port,
                reloadEnabled: options.reloadEnabled,
                logger: logger
            )
            await supervisor.startAll()

            try await waitForTerminationSignal()

            await supervisor.stopAll(graceful: true)
            try await gateway.stop()
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Runtime start failed", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.runtimeStartError))
        }
    }

    private static func waitForTerminationSignal() async throws {
        let stream = AsyncStream<Void> { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

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

    private static func writePIDFile(path: String) throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "\(getpid())\n".write(toFile: path, atomically: true, encoding: .utf8)
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

    private static func removePIDFile(path: String) {
        do {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        } catch {
            // Best-effort cleanup.
        }
    }

    private static func printHelp() {
        print(
            """
            AIB CLI

            Commands:
              aib init [--scan <path>] [--no-scan] [--force]
              aib workspace <list|scan|sync>
              aib emulator <start|validate|status|stop>
              aib deploy <plan|diff|apply>

            Legacy compatibility:
              aib-dev <run|validate-config|print-effective-config>
            """
        )
    }

    private static func level(from raw: String) -> Logger.Level {
        switch raw.lowercased() {
        case "trace": .trace
        case "debug": .debug
        case "warn", "warning": .warning
        case "error": .error
        default: .info
        }
    }
}
