import AIBCore
import AIBRuntimeCore
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

        let result = try AIBWorkspaceCore.initWorkspace(
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
            let workspace = try AIBWorkspaceCore.loadWorkspace(workspaceRoot: cwd)
            for repo in workspace.repos {
                print("\(repo.name)\t\(repo.status.rawValue)\t\(repo.runtime.rawValue)/\(repo.framework.rawValue)\t\(repo.path)")
            }
            Foundation.exit(Int32(ExitCode.ok))
        case "scan":
            let result = try AIBWorkspaceCore.rescanWorkspace(workspaceRoot: cwd)
            logger.info("Workspace scanned", metadata: ["repos": "\(result.workspaceConfig.repos.count)", "generated_services": "\(result.generatedServices)"])
            for warning in result.warnings { logger.warning("Workspace scan warning", metadata: ["warning": "\(warning)"]) }
            Foundation.exit(Int32(ExitCode.ok))
        case "sync":
            let result = try AIBWorkspaceCore.syncWorkspace(workspaceRoot: cwd)
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
        let pidFile = URL(fileURLWithPath: ".aib/state/emulator.pid", relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path

        switch subcommand {
        case "start":
            let options = parseRuntimeFlags(
                arguments: Array(arguments.dropFirst()),
                defaultWorkspaceRoot: cwd,
                defaultStatePIDPath: pidFile
            )
            await runLegacy(command: "run", options: options, logger: logger)
        case "validate":
            let options = parseRuntimeFlags(arguments: Array(arguments.dropFirst()), defaultWorkspaceRoot: cwd)
            await runLegacy(command: "validate-config", options: options, logger: logger)
        case "status":
            switch AIBRuntimeCoreService.readEmulatorPIDStatus(path: pidFile) {
            case .running(let pid):
                print("running pid=\(pid)")
            case .stale(let pid):
                print("stale pid=\(pid)")
            case .stopped:
                print("stopped")
            }
            Foundation.exit(Int32(ExitCode.ok))
        case "stop":
            do {
                try AIBRuntimeCoreService.stopEmulatorByPIDFile(path: pidFile)
            } catch {
                logger.warning("Failed to signal emulator", metadata: ["error": "\(error)"])
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

        // Detect provider from .aib/targets/ or use default
        let provider = try DeploymentProviderRegistry.detect(workspaceRoot: cwd)

        switch subcommand {
        case "preflight":
            print("Running preflight checks for \(provider.displayName)...")
            let report = await AIBDeployService.preflightCheck(provider: provider)
            for result in report.results {
                let icon: String
                switch result.status {
                case .passed: icon = "PASS"
                case .failed: icon = "FAIL"
                case .warning: icon = "WARN"
                case .skipped: icon = "SKIP"
                case .pending, .running: icon = "..."
                }
                print("  [\(icon)] \(result.title)")
                if case .failed(let msg) = result.status {
                    print("         \(msg)")
                    if let cmd = result.remediationCommand {
                        print("         Fix: \(cmd)")
                    }
                }
                if case .warning(let msg) = result.status {
                    print("         \(msg)")
                }
            }
            if report.canProceed {
                print("\nAll preflight checks passed.")
                Foundation.exit(Int32(ExitCode.ok))
            } else {
                print("\nPreflight checks failed. Resolve issues above before deploying.")
                Foundation.exit(Int32(ExitCode.deployError))
            }

        case "plan", "diff":
            let report = await AIBDeployService.preflightCheck(provider: provider)
            guard report.canProceed else {
                logger.error("Preflight checks failed. Run 'aib deploy preflight' for details.")
                Foundation.exit(Int32(ExitCode.deployError))
            }

            var targetConfig = try AIBDeployService.loadTargetConfig(
                workspaceRoot: cwd,
                providerID: provider.providerID
            )
            // Enrich config with auto-detected values from preflight
            let detectedValues = provider.extractDetectedConfig(from: report)
            for (key, value) in detectedValues where targetConfig.providerConfig[key] == nil {
                targetConfig.providerConfig[key] = value
            }
            try provider.validateTargetConfig(targetConfig)

            let plan = try AIBDeployService.generatePlan(
                workspaceRoot: cwd,
                targetConfig: targetConfig,
                provider: provider
            )
            try AIBDeployService.writeArtifacts(plan: plan, workspaceRoot: cwd)

            print("Deploy Plan: \(plan.workspaceName)")
            print("  Provider: \(provider.displayName)")
            print("  Region: \(targetConfig.region)")
            print("  Services: \(plan.services.count)")
            for service in plan.services {
                let sourceLabel = service.artifacts.dockerfile.source == .custom ? "(custom Dockerfile)" : "(generated)"
                print("    - \(service.id) -> \(service.deployedServiceName) \(sourceLabel)")
            }
            print("  Auth Bindings: \(plan.authBindings.count)")
            print("  Warnings: \(plan.warnings.count)")
            for warning in plan.warnings {
                print("    ! \(warning)")
            }
            print("\nArtifacts written to .aib/generated/deploy/")
            print("Run 'aib deploy apply' to execute deployment.")
            Foundation.exit(Int32(ExitCode.ok))

        case "apply":
            let report = await AIBDeployService.preflightCheck(provider: provider)
            guard report.canProceed else {
                logger.error("Preflight checks failed. Run 'aib deploy preflight' for details.")
                Foundation.exit(Int32(ExitCode.deployError))
            }

            var targetConfig = try AIBDeployService.loadTargetConfig(
                workspaceRoot: cwd,
                providerID: provider.providerID
            )
            // Enrich config with auto-detected values from preflight
            let detectedApplyValues = provider.extractDetectedConfig(from: report)
            for (key, value) in detectedApplyValues where targetConfig.providerConfig[key] == nil {
                targetConfig.providerConfig[key] = value
            }
            try provider.validateTargetConfig(targetConfig)

            let plan = try AIBDeployService.generatePlan(
                workspaceRoot: cwd,
                targetConfig: targetConfig,
                provider: provider
            )
            try AIBDeployService.writeArtifacts(plan: plan, workspaceRoot: cwd)

            print("Deploying \(plan.services.count) services via \(provider.displayName)...")
            let overallProgress = Progress(totalUnitCount: Int64(plan.services.count))
            let result = try await AIBDeployExecutor.execute(
                plan: plan,
                provider: provider,
                workspaceRoot: cwd,
                overallProgress: overallProgress,
                logHandler: { entry in
                    logger.log(level: entry.level, "\(entry.message)")
                }
            )

            print("\nDeployment complete:")
            for serviceResult in result.serviceResults {
                let status = serviceResult.success ? "OK" : "FAILED"
                print("  [\(status)] \(serviceResult.id)")
                if let url = serviceResult.deployedURL {
                    print("         URL: \(url)")
                }
                if let error = serviceResult.errorMessage {
                    print("         Error: \(error)")
                }
            }
            print("  Auth Bindings applied: \(result.authBindingsApplied)")

            if result.allSucceeded {
                Foundation.exit(Int32(ExitCode.ok))
            } else {
                Foundation.exit(Int32(ExitCode.deployError))
            }

        default:
            throw ConfigError("Unknown deploy subcommand. Use: preflight, plan, apply", metadata: ["subcommand": subcommand])
        }
    }

    private static func parseRuntimeFlags(
        arguments: [String],
        defaultWorkspaceRoot: String,
        defaultStatePIDPath: String? = nil
    ) -> AIBRuntimeOptions {
        var options = AIBRuntimeOptions(workspaceRoot: defaultWorkspaceRoot, statePIDPath: defaultStatePIDPath)
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--workspace-root":
                i += 1
                if i < arguments.count { options.workspaceRoot = arguments[i] }
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

    private static func parseLegacyRuntimeOptions(arguments: [String]) -> AIBRuntimeOptions {
        let tail = Array(arguments.dropFirst())
        return parseRuntimeFlags(arguments: tail, defaultWorkspaceRoot: FileManager.default.currentDirectoryPath)
    }

    private static func runLegacy(command: String, options: AIBRuntimeOptions, logger: Logger) async {
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

    private static func validateConfig(options: AIBRuntimeOptions, logger: Logger) async {
        do {
            let summary = try await AIBRuntimeCoreService.validateConfig(options: options)
            for warning in summary.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            logger.info("Configuration valid", metadata: ["services": "\(summary.serviceCount)"])
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Configuration invalid", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func printEffectiveConfig(options: AIBRuntimeOptions, logger: Logger) async {
        do {
            let effective = try await AIBRuntimeCoreService.effectiveConfigJSON(options: options)
            print(effective.json)
            for warning in effective.warnings {
                logger.warning("Config warning", metadata: ["warning": "\(warning)"])
            }
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Failed to print effective config", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.validationError))
        }
    }

    private static func runRuntime(options: AIBRuntimeOptions, logger: Logger) async {
        do {
            if options.dryRun {
                let summary = try await AIBRuntimeCoreService.validateConfig(options: options)
                logger.info("Dry run succeeded", metadata: ["services": "\(summary.serviceCount)"])
                Foundation.exit(Int32(ExitCode.ok))
            }
            try await AIBRuntimeCoreService.runEmulatorUntilTermination(options: options, logger: logger)
            Foundation.exit(Int32(ExitCode.ok))
        } catch {
            logger.error("Runtime start failed", metadata: ["error": "\(error)"])
            Foundation.exit(Int32(ExitCode.runtimeStartError))
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
