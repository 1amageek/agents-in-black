import Foundation
import Logging

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
                if result.exitCode != 0 {
                    throw AIBDeployError(
                        phase: "setup",
                        message: "Docker registry authentication failed (exit \(result.exitCode))"
                    )
                }
            } catch let error as AIBDeployError {
                throw error
            } catch {
                throw AIBDeployError(
                    phase: "setup",
                    message: "Docker registry authentication error: \(error.localizedDescription)"
                )
            }
        }

        var serviceResults: [AIBDeployServiceResult] = []

        for service in plan.services {
            // Child progress: each service owns `servicePipelineCount` units internally,
            // and contributes 1 unit to the parent when complete.
            let serviceProgress = Progress(
                totalUnitCount: AIBDeployStep.servicePipelineCount,
                parent: overallProgress,
                pendingUnitCount: 1
            )

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
            var serviceFailed = false
            for command in repoCommands {
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: .registrySetup,
                    message: command.label
                ))
                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: .registrySetup
                    )
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
                    serviceProgress.completedUnitCount += 1
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

            // Build & Push
            let buildPushCommands = provider.buildAndPushCommands(
                imageTag: imageTag,
                dockerfilePath: dockerfilePath,
                buildContext: buildContext
            )

            for command in buildPushCommands {
                let step = AIBDeployStep(rawValue: command.stepID) ?? .dockerBuild
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: step,
                    message: command.label
                ))

                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: step
                    )
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
                    serviceProgress.completedUnitCount += 1
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

            // Deploy service — filter secrets to only those required by this service
            let serviceSecrets = secrets.filter { service.requiredSecrets.contains($0.key) }
            let deployCommands = provider.deployCommands(
                service: service,
                imageTag: imageTag,
                targetConfig: plan.targetConfig,
                secrets: serviceSecrets
            )

            for command in deployCommands {
                let step = AIBDeployStep(rawValue: command.stepID) ?? .serviceDeploy
                logHandler(AIBDeployLogEntry(
                    level: .info,
                    serviceID: service.id,
                    step: step,
                    message: command.label
                ))

                do {
                    let result = try await runCommand(
                        command,
                        logHandler: logHandler,
                        serviceID: service.id,
                        step: step
                    )

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
                    serviceProgress.completedUnitCount += 1
                    serviceResults.append(AIBDeployServiceResult(
                        id: service.id,
                        deployedURL: deployedURL,
                        success: true
                    ))
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
                    if result.exitCode == 0 {
                        authBindingsApplied += 1
                    } else {
                        logHandler(AIBDeployLogEntry(
                            level: .warning,
                            step: step,
                            message: "Auth binding failed: \(result.stderr)"
                        ))
                    }
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
        step: AIBDeployStep
    ) async throws -> ProcessRunResult {
        try await processRunner.run(
            arguments: command.arguments,
            outputHandler: { line in
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
}
