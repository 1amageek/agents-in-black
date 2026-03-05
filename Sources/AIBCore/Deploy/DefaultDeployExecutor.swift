import Foundation
import Logging
import Synchronization

/// Default deployment executor that uses `ProcessRunner` for async process execution.
///
/// Uses Foundation `Progress` tree for progress reporting:
/// - Receives an overall `Progress` from the controller (totalUnitCount = service count)
/// - Creates a child `Progress` per service (totalUnitCount = pipeline step count)
/// - Updates `completedUnitCount` as each step finishes
///
/// Constructor injection enables testing with a mock `ProcessRunner`.
public struct DefaultDeployExecutor: DeployExecuting {

    private let processRunner: ProcessRunner

    public init(processRunner: ProcessRunner = DefaultProcessRunner()) {
        self.processRunner = processRunner
    }

    public func execute(
        plan: AIBDeployPlan,
        provider: any DeploymentProvider,
        workspaceRoot: String,
        overallProgress: Progress,
        secrets: [String: String] = [:],
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void
    ) async throws -> AIBDeployResult {
        // One-time: configure Docker registry authentication
        let authCommands = provider.registryAuthCommands(targetConfig: plan.targetConfig)
        for command in authCommands {
            logHandler(AIBDeployLogEntry(
                level: .info,
                step: .dockerAuth,
                message: command.label
            ))
            do {
                let result = try await runCommand(
                    command,
                    logHandler: logHandler,
                    serviceID: nil,
                    step: .dockerAuth
                )
                try Task.checkCancellation()
                if result.exitCode != 0 {
                    throw AIBDeployError(
                        phase: "setup",
                        message: "Docker registry authentication failed (exit \(result.exitCode))"
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIBDeployError {
                throw error
            } catch {
                throw AIBDeployError(
                    phase: "setup",
                    message: "Docker registry authentication error: \(error.localizedDescription)"
                )
            }
        }

        // One-time: prepare build backend state (cleanup stale local artifacts if needed)
        let backendPreparationCommands = provider.buildBackendPreparationCommands(targetConfig: plan.targetConfig)
        for command in backendPreparationCommands {
            let step = AIBDeployStep(rawValue: command.stepID) ?? .dockerBuild
            logHandler(AIBDeployLogEntry(
                level: .info,
                step: step,
                message: command.label
            ))
            do {
                let result = try await runCommand(
                    command,
                    logHandler: logHandler,
                    serviceID: nil,
                    step: step
                )
                try Task.checkCancellation()
                if result.exitCode != 0 {
                    throw AIBDeployError(
                        phase: "setup",
                        message: "Build backend preparation failed (exit \(result.exitCode))"
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIBDeployError {
                throw error
            } catch {
                throw AIBDeployError(
                    phase: "setup",
                    message: "Build backend preparation error: \(error.localizedDescription)"
                )
            }
        }

        var serviceResults: [AIBDeployServiceResult] = []

        for service in plan.services {
            let imageTag = provider.registryImageTag(service: service, targetConfig: plan.targetConfig)

            let dockerfilePath = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(service.artifacts.dockerfile.relativePath)
                .path
            let buildContext = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(service.repoPath)
                .path

            // Ensure Artifact Registry repository exists (idempotent)
            let repoCommands = provider.ensureRegistryRepoCommands(
                service: service,
                targetConfig: plan.targetConfig
            )
            let buildPushCommands = provider.buildAndPushCommands(
                imageTag: imageTag,
                dockerfilePath: dockerfilePath,
                buildContext: buildContext,
                targetConfig: plan.targetConfig
            )
            // Deploy service — filter secrets to only those required by this service
            let serviceSecrets = secrets.filter { service.requiredSecrets.contains($0.key) }
            let deployCommands = provider.deployCommands(
                service: service,
                imageTag: imageTag,
                targetConfig: plan.targetConfig,
                secrets: serviceSecrets
            )

            let pipelineCommands =
                repoCommands
                    .map { ($0, AIBDeployStep.registrySetup) }
                + buildPushCommands
                    .map { ($0, AIBDeployStep(rawValue: $0.stepID) ?? .dockerBuild) }
                + deployCommands
                    .map { ($0, AIBDeployStep(rawValue: $0.stepID) ?? .serviceDeploy) }
            let pipelineCommandCount = max(
                1,
                pipelineCommands.reduce(into: Int64(0)) { partial, element in
                    partial += Self.progressUnits(for: element.1)
                }
            )
            // Child progress is derived from the provider's concrete command pipeline.
            let serviceProgress = Progress(
                totalUnitCount: Int64(pipelineCommandCount),
                parent: overallProgress,
                pendingUnitCount: 1
            )
            var serviceCompletedUnits: Int64 = 0
            var serviceFailed = false
            for command in repoCommands {
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: .registrySetup,
                    message: command.label
                ))
                let commandUnits = Self.progressUnits(for: .registrySetup)
                let commandStartUnits = serviceCompletedUnits
                let commandAutoCap = max(1, Int64(Double(commandUnits) * 0.9))
                let commandState = Mutex(CommandOutputProgressState())
                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: .registrySetup,
                        onOutput: { line in
                            let maybeAbsoluteProgress = commandState.withLock { state -> Int64? in
                                state.outputLineCount += 1
                                if let ratio = Self.extractProgressRatio(from: line.text) {
                                    let estimated = Int64(Double(commandUnits) * ratio)
                                    let next = min(commandAutoCap, max(state.commandProgressUnits, estimated))
                                    if next > state.commandProgressUnits {
                                        state.commandProgressUnits = next
                                        return commandStartUnits + next
                                    }
                                    return nil
                                }
                                let stride = Self.outputStride(for: .registrySetup)
                                guard state.outputLineCount % stride == 0 else { return nil }
                                let next = min(commandAutoCap, state.commandProgressUnits + 1)
                                if next > state.commandProgressUnits {
                                    state.commandProgressUnits = next
                                    return commandStartUnits + next
                                }
                                return nil
                            }
                            if let maybeAbsoluteProgress {
                                serviceProgress.completedUnitCount = min(
                                    serviceProgress.totalUnitCount,
                                    maybeAbsoluteProgress
                                )
                            }
                        }
                    )
                    try Task.checkCancellation()
                    // Exit code != 0 is OK if repo already exists (ALREADY_EXISTS)
                    if result.exitCode != 0, !result.stderr.contains("ALREADY_EXISTS") {
                        let errorMsg = "\(command.label) failed (exit \(result.exitCode))"
                        logHandler(AIBDeployLogEntry(
                            level: .error,
                            serviceID: service.id,
                            step: .registrySetup,
                            message: errorMsg
                        ))
                        serviceResults.append(AIBDeployServiceResult(
                            id: service.id,
                            success: false,
                            errorMessage: errorMsg
                        ))
                        serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                        serviceFailed = true
                        break
                    }
                    serviceCompletedUnits += commandUnits
                    serviceProgress.completedUnitCount = min(serviceProgress.totalUnitCount, serviceCompletedUnits)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let errorMsg = "\(command.label) error: \(error.localizedDescription)"
                    logHandler(AIBDeployLogEntry(
                        level: .error,
                        serviceID: service.id,
                        step: .registrySetup,
                        message: errorMsg
                    ))
                    serviceResults.append(AIBDeployServiceResult(
                        id: service.id,
                        success: false,
                        errorMessage: errorMsg
                    ))
                    serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                    serviceFailed = true
                    break
                }
            }

            if serviceFailed { continue }

            for command in buildPushCommands {
                let step = AIBDeployStep(rawValue: command.stepID) ?? .dockerBuild
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: step,
                    message: command.label
                ))
                let commandUnits = Self.progressUnits(for: step)
                let commandStartUnits = serviceCompletedUnits
                let commandAutoCap = max(1, Int64(Double(commandUnits) * 0.9))
                let commandState = Mutex(CommandOutputProgressState())

                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: step,
                        onOutput: { line in
                            let maybeAbsoluteProgress = commandState.withLock { state -> Int64? in
                                state.outputLineCount += 1
                                if let ratio = Self.extractProgressRatio(from: line.text) {
                                    let estimated = Int64(Double(commandUnits) * ratio)
                                    let next = min(commandAutoCap, max(state.commandProgressUnits, estimated))
                                    if next > state.commandProgressUnits {
                                        state.commandProgressUnits = next
                                        return commandStartUnits + next
                                    }
                                    return nil
                                }
                                let stride = Self.outputStride(for: step)
                                guard state.outputLineCount % stride == 0 else { return nil }
                                let next = min(commandAutoCap, state.commandProgressUnits + 1)
                                if next > state.commandProgressUnits {
                                    state.commandProgressUnits = next
                                    return commandStartUnits + next
                                }
                                return nil
                            }
                            if let maybeAbsoluteProgress {
                                serviceProgress.completedUnitCount = min(
                                    serviceProgress.totalUnitCount,
                                    maybeAbsoluteProgress
                                )
                            }
                        }
                    )
                    try Task.checkCancellation()
                    if result.exitCode != 0 {
                        let errorMsg = "\(command.label) failed (exit \(result.exitCode))"
                        logHandler(AIBDeployLogEntry(
                            level: .error,
                            serviceID: service.id,
                            step: step,
                            message: errorMsg
                        ))
                        serviceResults.append(AIBDeployServiceResult(
                            id: service.id,
                            success: false,
                            errorMessage: errorMsg
                        ))
                        // Mark this service's progress as complete so the bar advances
                        serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                        serviceFailed = true
                        break
                    }
                    serviceCompletedUnits += commandUnits
                    serviceProgress.completedUnitCount = min(serviceProgress.totalUnitCount, serviceCompletedUnits)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let errorMsg = "\(command.label) error: \(error.localizedDescription)"
                    logHandler(AIBDeployLogEntry(
                        level: .error,
                        serviceID: service.id,
                        step: step,
                        message: errorMsg
                    ))
                    serviceResults.append(AIBDeployServiceResult(
                        id: service.id,
                        success: false,
                        errorMessage: errorMsg
                    ))
                    serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                    serviceFailed = true
                    break
                }
            }

            if serviceFailed { continue }

            for command in deployCommands {
                let step = AIBDeployStep(rawValue: command.stepID) ?? .serviceDeploy
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: step,
                    message: command.label
                ))
                let commandUnits = Self.progressUnits(for: step)
                let commandStartUnits = serviceCompletedUnits
                let commandAutoCap = max(1, Int64(Double(commandUnits) * 0.9))
                let commandState = Mutex(CommandOutputProgressState())

                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: step,
                        onOutput: { line in
                            let maybeAbsoluteProgress = commandState.withLock { state -> Int64? in
                                state.outputLineCount += 1
                                if let ratio = Self.extractProgressRatio(from: line.text) {
                                    let estimated = Int64(Double(commandUnits) * ratio)
                                    let next = min(commandAutoCap, max(state.commandProgressUnits, estimated))
                                    if next > state.commandProgressUnits {
                                        state.commandProgressUnits = next
                                        return commandStartUnits + next
                                    }
                                    return nil
                                }
                                let stride = Self.outputStride(for: step)
                                guard state.outputLineCount % stride == 0 else { return nil }
                                let next = min(commandAutoCap, state.commandProgressUnits + 1)
                                if next > state.commandProgressUnits {
                                    state.commandProgressUnits = next
                                    return commandStartUnits + next
                                }
                                return nil
                            }
                            if let maybeAbsoluteProgress {
                                serviceProgress.completedUnitCount = min(
                                    serviceProgress.totalUnitCount,
                                    maybeAbsoluteProgress
                                )
                            }
                        }
                    )
                    try Task.checkCancellation()

                    if result.exitCode != 0 {
                        let errorMsg = "\(command.label) failed (exit \(result.exitCode))"
                        logHandler(AIBDeployLogEntry(
                            level: .error,
                            serviceID: service.id,
                            step: step,
                            message: errorMsg
                        ))
                        serviceResults.append(AIBDeployServiceResult(
                            id: service.id,
                            success: false,
                            errorMessage: errorMsg
                        ))
                        serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                        serviceFailed = true
                        break
                    }

                    let deployedURL = provider.parseDeployedURL(from: result.stdout)
                    serviceCompletedUnits += commandUnits
                    serviceProgress.completedUnitCount = min(serviceProgress.totalUnitCount, serviceCompletedUnits)
                    serviceResults.append(AIBDeployServiceResult(
                        id: service.id,
                        deployedURL: deployedURL,
                        success: true
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let errorMsg = "\(command.label) error: \(error.localizedDescription)"
                    logHandler(AIBDeployLogEntry(
                        level: .error,
                        serviceID: service.id,
                        step: step,
                        message: errorMsg
                    ))
                    serviceResults.append(AIBDeployServiceResult(
                        id: service.id,
                        success: false,
                        errorMessage: errorMsg
                    ))
                    serviceProgress.completedUnitCount = serviceProgress.totalUnitCount
                    serviceFailed = true
                    break
                }
            }

            if serviceFailed { continue }
        }

        // Auth bindings — only for successfully deployed services
        let deployedServiceNames = Set(
            serviceResults
                .filter(\.success)
                .compactMap { result in
                    plan.services.first(where: { $0.id == result.id })?.deployedServiceName
                }
        )

        var authBindingsApplied = 0
        for binding in plan.authBindings {
            let sourceDeployed = deployedServiceNames.contains(binding.sourceServiceName)
            let targetDeployed = deployedServiceNames.contains(binding.targetServiceName)

            guard sourceDeployed && targetDeployed else {
                let missing = [
                    sourceDeployed ? nil : binding.sourceServiceName,
                    targetDeployed ? nil : binding.targetServiceName,
                ].compactMap { $0 }.joined(separator: ", ")
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    step: .authBind,
                    message: "Skipping IAM binding \(binding.sourceServiceName) → \(binding.targetServiceName): "
                        + "not deployed (\(missing))"
                ))
                continue
            }

            let commands = provider.authBindingCommands(
                binding: binding,
                targetConfig: plan.targetConfig
            )

            for command in commands {
                let step = AIBDeployStep(rawValue: command.stepID) ?? .authBind
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    step: step,
                    message: command.label
                ))

                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: nil,
                        step: step
                    )
                    try Task.checkCancellation()
                    if result.exitCode == 0 {
                        authBindingsApplied += 1
                    } else {
                        logHandler(AIBDeployLogEntry(
                            level: .warning,
                            step: step,
                            message: "Auth binding failed: \(result.stderr)"
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logHandler(AIBDeployLogEntry(
                        level: .warning,
                        step: step,
                        message: "Auth binding error: \(error.localizedDescription)"
                    ))
                }
            }
        }

        return AIBDeployResult(
            plan: plan,
            serviceResults: serviceResults,
            authBindingsApplied: authBindingsApplied
        )
    }

    // MARK: - Private

    private func runCommand(
        _ command: DeployCommand,
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void,
        serviceID: String?,
        step: AIBDeployStep,
        onOutput: (@Sendable (ProcessOutputLine) -> Void)? = nil
    ) async throws -> ProcessRunResult {
        try Task.checkCancellation()
        let startedAt = Date()
        let result = try await processRunner.run(
            arguments: command.arguments,
            outputHandler: { line in
                onOutput?(line)
                // Docker sends all build progress to stderr; use line content to determine level.
                let level: Logger.Level = Self.detectLogLevel(line.text)
                logHandler(AIBDeployLogEntry(
                    level: level,
                    serviceID: serviceID,
                    step: step,
                    message: line.text
                ))
            }
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let elapsedText = String(format: "%.1fs", elapsed)
        let completionLevel: Logger.Level = result.exitCode == 0 ? .info : .warning
        logHandler(AIBDeployLogEntry(
            level: completionLevel,
            serviceID: serviceID,
            step: step,
            message: "Command completed in \(elapsedText) (exit \(result.exitCode))"
        ))
        return result
    }

    private static func detectLogLevel(_ text: String) -> Logger.Level {
        let prefix = String(text.prefix(80))
        if prefix.contains("ERROR") || prefix.contains("error:") {
            return .error
        }
        if prefix.contains("WARN") || prefix.contains("warning:") {
            return .warning
        }
        return .info
    }

    private static func progressUnits(for step: AIBDeployStep) -> Int64 {
        switch step {
        case .registrySetup:
            return 80
        case .dockerBuild:
            return 650
        case .dockerPush:
            return 260
        case .serviceDeploy:
            return 120
        case .dockerAuth:
            return 100
        case .authBind:
            return 40
        }
    }

    private static func outputStride(for step: AIBDeployStep) -> Int {
        switch step {
        case .dockerBuild:
            return 8
        case .dockerPush:
            return 5
        default:
            return 10
        }
    }

    private static func extractProgressRatio(from line: String) -> Double? {
        // Build step counters like "[37/98]"
        if let range = line.range(of: #"(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let token = String(line[range])
            let parts = token.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let lhs = Double(parts[0]),
               let rhs = Double(parts[1]),
               rhs > 0
            {
                let ratio = lhs / rhs
                if ratio.isFinite {
                    return min(1.0, max(0.0, ratio))
                }
            }
        }

        // Transfer logs like "24.12MB / 49.47MB"
        if let range = line.range(of: #"([0-9]+(?:\.[0-9]+)?)([KMGTP]B)\s*/\s*([0-9]+(?:\.[0-9]+)?)([KMGTP]B)"#, options: .regularExpression) {
            let token = String(line[range])
            do {
                let regex = try NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)([KMGTP]B)"#)
                let nsRange = NSRange(token.startIndex..<token.endIndex, in: token)
                let matches = regex.matches(in: token, options: [], range: nsRange)
                if matches.count >= 2,
                   matches[0].numberOfRanges >= 3,
                   matches[1].numberOfRanges >= 3,
                   let lhsValueRange = Range(matches[0].range(at: 1), in: token),
                   let lhsUnitRange = Range(matches[0].range(at: 2), in: token),
                   let rhsValueRange = Range(matches[1].range(at: 1), in: token),
                   let rhsUnitRange = Range(matches[1].range(at: 2), in: token)
                {
                    let lhsValue = Double(token[lhsValueRange]) ?? 0
                    let lhsUnit = String(token[lhsUnitRange])
                    let rhsValue = Double(token[rhsValueRange]) ?? 0
                    let rhsUnit = String(token[rhsUnitRange])
                    let lhsBytes = lhsValue * Self.byteUnitMultiplier(lhsUnit)
                    let rhsBytes = rhsValue * Self.byteUnitMultiplier(rhsUnit)
                    if rhsBytes > 0 {
                        let ratio = lhsBytes / rhsBytes
                        if ratio.isFinite {
                            return min(1.0, max(0.0, ratio))
                        }
                    }
                }
            } catch {
                return nil
            }
        }
        return nil
    }

    private static func byteUnitMultiplier(_ unit: String) -> Double {
        switch unit {
        case "KB": return 1024
        case "MB": return 1024 * 1024
        case "GB": return 1024 * 1024 * 1024
        case "TB": return 1024 * 1024 * 1024 * 1024
        case "PB": return 1024 * 1024 * 1024 * 1024 * 1024
        default: return 1
        }
    }
}

private struct CommandOutputProgressState: Sendable {
    var outputLineCount: Int = 0
    var commandProgressUnits: Int64 = 0
}
