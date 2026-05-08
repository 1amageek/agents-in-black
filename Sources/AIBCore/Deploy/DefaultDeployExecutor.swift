import AIBConfig
import AIBRuntimeCore
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

        // Validate declared SecretRefs exist in Secret Manager up front.
        // --set-secrets fails mid-deploy with a less informative error if the
        // secret is missing, leaving services in a partially-applied state.
        // Catch it here so users get a single clear remediation step.
        if !plan.allDeclaredSecretRefs.isEmpty {
            let declaredNames = Set(plan.allDeclaredSecretRefs.values.map(\.secret))
            logHandler(AIBDeployLogEntry(
                level: .info,
                step: .serviceDeploy,
                message: "Validating \(declaredNames.count) declared SecretRef(s) against Secret Manager"
            ))
            let existingSecrets: Set<String>
            do {
                existingSecrets = try await provider.listSecrets(targetConfig: plan.targetConfig)
            } catch let error as AIBDeployError {
                throw error
            } catch {
                throw AIBDeployError(
                    phase: "secrets",
                    message: "Failed to list Secret Manager secrets: \(error.localizedDescription)"
                )
            }
            let missing = declaredNames.subtracting(existingSecrets).sorted()
            if !missing.isEmpty {
                throw AIBDeployError(
                    phase: "secrets",
                    message: "Declared SecretRefs missing in Secret Manager: "
                        + missing.joined(separator: ", ")
                        + ". Create them with `gcloud secrets create <name>` or via the AIB Inspector before deploying."
                )
            }
        }

        var serviceResults: [AIBDeployServiceResult] = []

        for service in plan.services {
            let imageTag = provider.registryImageTag(service: service, targetConfig: plan.targetConfig)

            var dockerfilePath = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(service.artifacts.dockerfile.relativePath)
                .path
            let buildContext = URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(service.repoPath)
                .path
            // Top-stage instructions land right after the first FROM; they
            // intentionally appear in the base/deps stage so build-time RUNs
            // (e.g. `pnpm install` over SSH) can use them.
            var topStageInstructions: [String] = []
            // Runtime-stage instructions land in the final FROM stage, after
            // its last WORKDIR — so files end up at the configured WORKDIR
            // (typically `/app`) of the image that actually runs.
            var runtimeStageInstructions: [String] = []
            var preUserDockerfileInstructions: [String] = []
            var preEntrypointDockerfileInstructions: [String] = []
            let appendedDockerfileInstructions: [String] = []

            if let mcpConfig = service.artifacts.mcpConnectionConfig {
                let connectionsFileName = ".aib-connections.json"
                let targetPath = URL(fileURLWithPath: buildContext)
                    .appendingPathComponent(connectionsFileName)
                try mcpConfig.content.write(to: targetPath, options: .atomic)
                runtimeStageInstructions.append("COPY \(connectionsFileName) ./")
            }

            let projectedArtifacts = service.artifacts.skillConfigs
                + service.artifacts.executionDirectoryConfigs
                + service.artifacts.claudeCodePluginArtifacts
            if !projectedArtifacts.isEmpty {
                let stagedRoots = try Self.stageProjectedArtifacts(
                    projectedArtifacts,
                    buildContext: buildContext
                )
                runtimeStageInstructions.append(contentsOf: Self.copyInstructionsForStagedRuntimeRoots(stagedRoots))
            }

            if let sourceAuthInstructions = try await stageCloudBuildSourceAuthIfNeeded(
                service: service,
                buildContext: buildContext,
                logHandler: logHandler
            ) {
                topStageInstructions.append(contentsOf: sourceAuthInstructions.injectedInstructions)
                preUserDockerfileInstructions.append(contentsOf: sourceAuthInstructions.appendedInstructions)
            }

            if service.serviceKind == .agent && service.runtime == "node" {
                preEntrypointDockerfileInstructions.append(
                    contentsOf: try Self.nodeAgentNonRootRuntimeInstructions(dockerfilePath: dockerfilePath)
                )
            }

            if !topStageInstructions.isEmpty
                || !runtimeStageInstructions.isEmpty
                || !preUserDockerfileInstructions.isEmpty
                || !preEntrypointDockerfileInstructions.isEmpty
                || !appendedDockerfileInstructions.isEmpty
            {
                dockerfilePath = try Self.patchedDockerfilePath(
                    dockerfilePath: dockerfilePath,
                    buildContext: buildContext,
                    topStageInstructions: topStageInstructions,
                    runtimeStageInstructions: runtimeStageInstructions,
                    preUserInstructions: preUserDockerfileInstructions,
                    preEntrypointInstructions: preEntrypointDockerfileInstructions,
                    appendedInstructions: appendedDockerfileInstructions
                )
            }

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
            // Deploy service — filter secrets to only those this service
            // explicitly asked for (from EnvVarScanner). Declared SecretRefs
            // are NOT in this set; they are mounted via --set-secrets in
            // Phase 4, not via --set-env-vars.
            let serviceSecrets = secrets.filter { service.unresolvedSecrets.contains($0.key) }
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

            cleanupTemporaryArtifacts(
                buildContext: buildContext,
                logHandler: logHandler,
                serviceID: service.id
            )

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

    private static func stageProjectedArtifacts(
        _ artifacts: [AIBDeployArtifact],
        buildContext: String
    ) throws -> Set<String> {
        let fm = FileManager.default
        let buildContextURL = URL(fileURLWithPath: buildContext)
        var stagedRoots = Set<String>()

        for artifact in artifacts {
            let destinationURL = buildContextURL.appendingPathComponent(artifact.relativePath)
            try fm.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try artifact.content.write(to: destinationURL, options: .atomic)

            if let root = Self.stagedRuntimeRoot(for: artifact.relativePath) {
                stagedRoots.insert(root)
            }
        }

        return stagedRoots
    }

    /// Patch a Dockerfile with two distinct insertion points:
    ///
    /// - `topStageInstructions` go right after the **first** `FROM` so they
    ///   land in the base/deps stage. Used for build-time concerns like
    ///   provisioning SSH keys before `pnpm install` fetches private deps.
    /// - `runtimeStageInstructions` go in the **final** `FROM` stage, after
    ///   that stage's last `WORKDIR`. Used for files the running container
    ///   needs to read at the configured working directory (e.g. `/app`).
    ///   In a single-stage Dockerfile this is the same stage as the top.
    /// - `appendedInstructions` are appended verbatim to the very end (used
    ///   for runtime cleanup like deleting SSH keys before the image is
    ///   committed).
    static func patchedDockerfilePath(
        dockerfilePath: String,
        buildContext: String,
        topStageInstructions: [String],
        runtimeStageInstructions: [String],
        preUserInstructions: [String] = [],
        preEntrypointInstructions: [String] = [],
        appendedInstructions: [String]
    ) throws -> String {
        let originalContent = try String(contentsOfFile: dockerfilePath, encoding: .utf8)
        let missingTopStage = topStageInstructions.filter { !originalContent.contains($0) }
        let missingRuntimeStage = runtimeStageInstructions.filter { !originalContent.contains($0) }
        let missingPreUser = preUserInstructions.filter { !originalContent.contains($0) }
        let missingPreEntrypoint = preEntrypointInstructions.filter { !originalContent.contains($0) }
        let missingAppended = appendedInstructions.filter { !originalContent.contains($0) }
        guard !missingTopStage.isEmpty
            || !missingRuntimeStage.isEmpty
            || !missingPreUser.isEmpty
            || !missingPreEntrypoint.isEmpty
            || !missingAppended.isEmpty
        else {
            return dockerfilePath
        }

        let patchedPath = URL(fileURLWithPath: buildContext)
            .appendingPathComponent("Dockerfile.aib")
            .path(percentEncoded: false)
        var lines = originalContent.components(separatedBy: "\n")

        // Apply runtime-stage instructions first, walking from the bottom of the
        // file. Doing top-stage second keeps the top-stage `firstIndex(of: FROM)`
        // anchor stable; if we did it the other way around, inserting near the
        // top would invalidate the runtime-stage index we computed earlier.
        if !missingRuntimeStage.isEmpty {
            let insertionIndex = Self.runtimeStageInsertionIndex(in: lines)
                ?? lines.endIndex
            lines.insert(contentsOf: missingRuntimeStage, at: insertionIndex)
        }

        if !missingPreUser.isEmpty {
            let insertionIndex = Self.preUserInsertionIndex(in: lines)
                ?? Self.preEntrypointInsertionIndex(in: lines)
                ?? lines.endIndex
            lines.insert(contentsOf: missingPreUser, at: insertionIndex)
        }

        if !missingPreEntrypoint.isEmpty {
            let insertionIndex = Self.preEntrypointInsertionIndex(in: lines)
                ?? lines.endIndex
            lines.insert(contentsOf: missingPreEntrypoint, at: insertionIndex)
        }

        if !missingTopStage.isEmpty {
            if let firstFromIndex = lines.firstIndex(where: { Self.isFromLine($0) }) {
                lines.insert(contentsOf: missingTopStage, at: firstFromIndex + 1)
            } else {
                lines.append(contentsOf: missingTopStage)
            }
        }

        if !missingAppended.isEmpty {
            lines.append(contentsOf: missingAppended)
        }

        let patchedContent = lines.joined(separator: "\n") + "\n"
        try patchedContent.write(toFile: patchedPath, atomically: true, encoding: .utf8)
        return patchedPath
    }

    /// Pick the line index where runtime-stage COPY instructions should be
    /// inserted. Prefers the line after the last `WORKDIR` inside the final
    /// `FROM` stage so COPY targets resolve under the configured WORKDIR
    /// (typically `/app`). Falls back to the line right after the final
    /// `FROM` if that stage has no `WORKDIR`.
    static func runtimeStageInsertionIndex(in lines: [String]) -> Int? {
        guard let lastFromIndex = lines.lastIndex(where: { isFromLine($0) }) else {
            return nil
        }
        let finalStageRange = (lastFromIndex + 1)..<lines.endIndex
        if finalStageRange.lowerBound < lines.endIndex,
           let lastWorkdirIndex = lines[finalStageRange].lastIndex(where: { isWorkdirLine($0) })
        {
            return lastWorkdirIndex + 1
        }
        return lastFromIndex + 1
    }

    static func preUserInsertionIndex(in lines: [String]) -> Int? {
        guard let lastFromIndex = lines.lastIndex(where: { isFromLine($0) }) else {
            return nil
        }
        let finalStageRange = (lastFromIndex + 1)..<lines.endIndex
        guard finalStageRange.lowerBound < lines.endIndex else {
            return nil
        }
        return lines[finalStageRange].firstIndex(where: { isUserLine($0) })
    }

    static func preEntrypointInsertionIndex(in lines: [String]) -> Int? {
        guard let lastFromIndex = lines.lastIndex(where: { isFromLine($0) }) else {
            return nil
        }
        let finalStageRange = (lastFromIndex + 1)..<lines.endIndex
        guard finalStageRange.lowerBound < lines.endIndex else {
            return nil
        }
        if let entrypointIndex = lines[finalStageRange].lastIndex(where: { isRuntimeEntrypointLine($0) }) {
            return entrypointIndex
        }
        return lines.endIndex
    }

    static func nodeAgentNonRootRuntimeInstructions(dockerfilePath: String) throws -> [String] {
        let content = try String(contentsOfFile: dockerfilePath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        guard let lastFromIndex = lines.lastIndex(where: { isFromLine($0) }) else {
            return ["RUN chown -R node:node /app", "ENV HOME=/home/node", "USER node"]
        }
        let finalStageRange = (lastFromIndex + 1)..<lines.endIndex
        let finalStageLines = finalStageRange.lowerBound < lines.endIndex
            ? Array(lines[finalStageRange])
            : []
        let lastUser = finalStageLines
            .last(where: { isUserLine($0) })
            .flatMap(runtimeUserValue)

        if let lastUser {
            if lastUser == "node" {
                return content.contains("ENV HOME=/home/node") ? [] : ["ENV HOME=/home/node"]
            }
            if lastUser != "root" && lastUser != "0" {
                return []
            }
        }

        return ["RUN chown -R node:node /app", "ENV HOME=/home/node", "USER node"]
    }

    private static func isFromLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("FROM ")
    }

    private static func isWorkdirLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("WORKDIR ")
    }

    private static func isUserLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("USER ")
    }

    private static func isRuntimeEntrypointLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.hasPrefix("CMD ") || trimmed.hasPrefix("ENTRYPOINT ")
    }

    private static func runtimeUserValue(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("USER ") else {
            return nil
        }
        return trimmed
            .dropFirst(5)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).lowercased() }
    }

    private static func copyInstructionsForStagedRuntimeRoots(_ roots: Set<String>) -> [String] {
        var instructions: [String] = []
        if roots.contains("__aib_deploy/claude") {
            instructions.append("COPY __aib_deploy/claude/ ./.claude/")
        }
        if roots.contains("__aib_deploy/codex") {
            instructions.append("COPY __aib_deploy/codex/ ./.codex/")
        }
        if roots.contains("__aib_deploy/agents") {
            instructions.append("COPY __aib_deploy/agents/ ./.agents/")
        }
        if roots.contains("__aib_deploy/skills") {
            instructions.append("COPY __aib_deploy/skills/ ./skills/")
        }
        if roots.contains("__aib_deploy/plugin") {
            // Mounts the Claude Code plugin bundle at /app/.aib-plugin so the agent
            // runtime can pass it to SDK's `plugins: [{ type: 'local', path }]`.
            instructions.append("COPY __aib_deploy/plugin/ ./.aib-plugin/")
        }
        if roots.contains("__aib_deploy/root") {
            instructions.append("COPY __aib_deploy/root/ ./")
        }
        return instructions
    }

    private static func stagedRuntimeRoot(for relativePath: String) -> String? {
        let prefixes = [
            "__aib_deploy/claude/",
            "__aib_deploy/codex/",
            "__aib_deploy/agents/",
            "__aib_deploy/skills/",
            "__aib_deploy/plugin/",
            "__aib_deploy/root/",
        ]
        for prefix in prefixes where relativePath.hasPrefix(prefix) {
            return String(prefix.dropLast())
        }
        return nil
    }

    private func cleanupTemporaryArtifacts(
        buildContext: String,
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void,
        serviceID: String
    ) {
        let cleanupTargets = [
            "__aib_deploy",
            ".aib-build-auth",
            ".aib-connections.json",
            "Dockerfile.aib",
        ]

        for relativePath in cleanupTargets {
            let targetURL = URL(fileURLWithPath: buildContext).appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: targetURL)
            } catch {
                logHandler(AIBDeployLogEntry(
                    level: .warning,
                    serviceID: serviceID,
                    step: .dockerBuild,
                    message: "Failed to clean temporary deploy artifact \(relativePath): \(error.localizedDescription)"
                ))
            }
        }
    }

    private func stageCloudBuildSourceAuthIfNeeded(
        service: AIBDeployServicePlan,
        buildContext: String,
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void
    ) async throws -> SourceAuthDockerfileInstructions? {
        guard !service.sourceDependencies.isEmpty else { return nil }
        guard let credential = service.sourceCredential else {
            throw AIBDeployError(
                phase: "build",
                message: "Missing resolved cloud source credential for service '\(service.id)'."
            )
        }
        guard let privateKeySecret = credential.cloudPrivateKeySecret, !privateKeySecret.isEmpty else {
            throw AIBDeployError(
                phase: "build",
                message: "Cloud source credential for service '\(service.id)' is missing cloudPrivateKeySecret."
            )
        }

        let authRoot = URL(fileURLWithPath: buildContext).appendingPathComponent(".aib-build-auth")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: authRoot.path(percentEncoded: false)) {
            try fileManager.removeItem(at: authRoot)
        }
        try fileManager.createDirectory(at: authRoot, withIntermediateDirectories: true)

        let privateKey = try await fetchSecretValue(secretName: privateKeySecret)
        try privateKey.write(
            to: authRoot.appendingPathComponent("id_ed25519"),
            atomically: true,
            encoding: .utf8
        )

        let knownHosts: String
        if let cloudKnownHostsSecret = credential.cloudKnownHostsSecret, !cloudKnownHostsSecret.isEmpty {
            knownHosts = try await fetchSecretValue(secretName: cloudKnownHostsSecret)
        } else {
            knownHosts = AIBSourceDependencyAnalyzer.defaultKnownHosts(for: credential.host) ?? ""
        }
        if !knownHosts.isEmpty {
            try knownHosts.write(
                to: authRoot.appendingPathComponent("known_hosts"),
                atomically: true,
                encoding: .utf8
            )
        }

        logHandler(AIBDeployLogEntry(
            level: .info,
            serviceID: service.id,
            step: .dockerBuild,
            message: "Materialized explicit source auth for \(credential.host)"
        ))

        return SourceAuthDockerfileInstructions(
            injectedInstructions: [
                "COPY .aib-build-auth/ /tmp/.aib-build-auth/",
                "RUN mkdir -p /root/.ssh && cp /tmp/.aib-build-auth/id_ed25519 /root/.ssh/id_ed25519 && chmod 700 /root/.ssh && chmod 600 /root/.ssh/id_ed25519 && if [ -f /tmp/.aib-build-auth/known_hosts ]; then cp /tmp/.aib-build-auth/known_hosts /root/.ssh/known_hosts && chmod 644 /root/.ssh/known_hosts; fi",
                "ENV GIT_SSH_COMMAND=\"ssh -i /root/.ssh/id_ed25519 -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes\"",
            ],
            appendedInstructions: [
                "RUN rm -rf /root/.ssh /tmp/.aib-build-auth || true",
            ]
        )
    }

    private func fetchSecretValue(secretName: String) async throws -> String {
        let result = try await processRunner.run(
            arguments: [
                "bash", "-lc",
                "gcloud secrets versions access latest --secret=\(shellQuoted(secretName))",
            ],
            outputHandler: { _ in }
        )
        guard result.exitCode == 0 else {
            throw AIBDeployError(
                phase: "build",
                message: "Failed to fetch source auth secret '\(secretName)'."
            )
        }
        return result.stdout
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

private struct SourceAuthDockerfileInstructions: Sendable {
    let injectedInstructions: [String]
    let appendedInstructions: [String]
}

private struct CommandOutputProgressState: Sendable {
    var outputLineCount: Int = 0
    var commandProgressUnits: Int64 = 0
}
