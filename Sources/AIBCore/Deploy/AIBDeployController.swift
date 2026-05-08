import Foundation

/// Controls the deployment pipeline.
/// Provider-agnostic: delegates cloud-specific operations to DeploymentProvider.
/// Follows the same event-driven pattern as AIBEmulatorController.
///
/// Dependencies are injected via constructor (following the `DevSupervisor` pattern
/// from AIBSupervisor: `protocol + default + constructor injection`).
@MainActor
public final class AIBDeployController {
    private let planGenerator: DeployPlanGenerator
    private let executor: DeployExecuting
    private var eventContinuations: [UUID: AsyncStream<AIBDeployEvent>.Continuation] = [:]
    private var currentTask: Task<Void, Never>?
    private var approvalGate: ApprovalGate?
    private var secretsGate: SecretsGate?
    private var cachedPreflightReport: PreflightReport?
    private var cancellationRequested = false
    private var deployStartedAt: Date?

    public private(set) var phase: AIBDeployPhase = .idle

    /// Foundation `Progress` for the current deployment.
    /// Created at the start of the apply phase; nil otherwise.
    /// Observe this from SwiftUI via `ProgressView(progress)`.
    public private(set) var deployProgress: Progress?

    /// Secrets provided by the user during the secretsInput phase.
    /// Passed to the provider's deploy commands.
    public private(set) var providedSecrets: [String: String] = [:]

    public init(
        planGenerator: DeployPlanGenerator = DefaultDeployPlanGenerator(),
        executor: DeployExecuting = DefaultDeployExecutor()
    ) {
        self.planGenerator = planGenerator
        self.executor = executor
    }

    // MARK: - Event Stream

    public func events() -> AsyncStream<AIBDeployEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.eventContinuations[id] = continuation
            continuation.yield(.phaseChanged(self.phase))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func shutdown() {
        cancellationRequested = true
        deployStartedAt = nil
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil
        finishEventStreams()
    }

    // MARK: - Pipeline Control

    /// Start the deploy pipeline: preflight -> plan -> wait for review.
    public func startPlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider
    ) {
        guard case .idle = phase else { return }
        cancellationRequested = false
        deployStartedAt = Date()

        currentTask = Task { [weak self] in
            guard let self else { return }

            // Phase 1: Preflight
            self.transitionTo(.preflight)
            let report = await self.planGenerator.preflightCheck(provider: provider)
            self.cachedPreflightReport = report

            guard report.canProceed else {
                let failedNames = report.failedChecks.map(\.title).joined(separator: ", ")
                self.transitionTo(.failed(AIBDeployError(
                    phase: "preflight",
                    message: "Preflight failed: \(failedNames)"
                )))
                return
            }

            // Enrich target config with auto-detected values from preflight
            var enrichedConfig = targetConfig
            let detectedValues = provider.extractDetectedConfig(from: report)
            for (key, value) in detectedValues where enrichedConfig.providerConfig[key] == nil {
                enrichedConfig.providerConfig[key] = value
            }

            // Phase 2: Planning
            self.transitionTo(.planning)
            do {
                // Validate that all required provider config is present
                try provider.validateTargetConfig(enrichedConfig)

                let plan = try await self.planGenerator.generatePlan(
                    workspaceRoot: workspaceRoot,
                    targetConfig: enrichedConfig,
                    provider: provider
                )

                // Phase 3: Review — block until user approves or cancels
                self.transitionTo(.reviewing(plan))

                let gate = ApprovalGate()
                self.approvalGate = gate
                let approved = await gate.wait()

                guard approved else {
                    self.transitionTo(.cancelled)
                    return
                }

                // Phase 3.5: Secrets Input — pre-populate from the live service so
                // values entered on a previous deploy are reused. Only prompt for
                // ones that are not yet on the remote.
                //
                // Why pre-populate: deploy uses authoritative `--set-env-vars`,
                // which replaces the env wholesale. If we skipped already-set
                // secrets but did NOT carry their values forward, the deploy
                // would wipe them from the live service. So we fetch the
                // existing values, merge them into `secretValues`, and only
                // prompt the user for the names we couldn't fetch.
                //
                // Declared SecretRefs are mounted via `--set-secrets` (Secret
                // Manager-backed) and never appear in `unresolvedSecrets`, so
                // they are not part of this flow.
                var secretValues: [String: String] = [:]
                if plan.hasUnresolvedSecrets {
                    var aggregatedExistingEnv: [String: String] = [:]
                    for service in plan.services where !service.unresolvedSecrets.isEmpty {
                        let existing = await provider.existingEnvVars(
                            serviceName: service.deployedServiceName,
                            targetConfig: enrichedConfig
                        )
                        // Last writer wins on collisions across services. The
                        // SecretsInput dialog deduplicates by name (one input
                        // per secret name across all services), so we only
                        // need a single value per name.
                        for (key, value) in existing {
                            aggregatedExistingEnv[key] = value
                        }
                    }

                    for name in plan.allUnresolvedSecrets {
                        if let existingValue = aggregatedExistingEnv[name], !existingValue.isEmpty {
                            secretValues[name] = existingValue
                        }
                    }

                    let stillMissing = plan.allUnresolvedSecrets
                        .filter { secretValues[$0] == nil }

                    if !stillMissing.isEmpty {
                        self.transitionTo(.secretsInput(plan, unresolvedSecrets: stillMissing))

                        let sGate = SecretsGate()
                        self.secretsGate = sGate
                        let result = await sGate.wait()

                        guard let userSecrets = result else {
                            self.transitionTo(.cancelled)
                            return
                        }
                        // Merge user-provided values on top of remote values.
                        // User input takes precedence so a user can rotate a
                        // secret by re-entering it (the prompt only fires for
                        // missing names today, but this keeps the contract
                        // forward-compatible if the UI gains an "override"
                        // flow later).
                        for (key, value) in userSecrets {
                            secretValues[key] = value
                        }
                    }
                }
                self.providedSecrets = secretValues

                // Phase 4: Apply
                let progress = Progress(totalUnitCount: Int64(plan.services.count))
                self.deployProgress = progress
                self.transitionTo(.applying(plan))

                try self.planGenerator.writeArtifacts(plan: plan, workspaceRoot: workspaceRoot)

                let result = try await self.executor.execute(
                    plan: plan,
                    provider: provider,
                    workspaceRoot: workspaceRoot,
                    overallProgress: progress,
                    secrets: secretValues,
                    logHandler: { [weak self] logEntry in
                        Task { @MainActor in
                            guard let self else { return }
                            var enriched = logEntry
                            if let startedAt = self.deployStartedAt {
                                let elapsed = logEntry.timestamp.timeIntervalSince(startedAt)
                                enriched.elapsedSeconds = max(0, elapsed)
                            }
                            self.emit(.log(enriched))
                        }
                    }
                )

                if Task.isCancelled || self.cancellationRequested {
                    self.transitionTo(.cancelled)
                    return
                }
                self.transitionTo(.completed(result))
            } catch is CancellationError {
                self.transitionTo(.cancelled)
            } catch {
                if Task.isCancelled || self.cancellationRequested {
                    self.transitionTo(.cancelled)
                    return
                }
                self.transitionTo(.failed(AIBDeployError(
                    phase: "deploy",
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Approve the current plan and proceed to deployment.
    public func approve(plan: AIBDeployPlan) {
        approvalGate?.approve()
    }

    /// Provide secrets and proceed to deployment.
    public func provideSecrets(_ secrets: [String: String]) {
        secretsGate?.provide(secrets: secrets)
    }

    /// Cancel the current deployment pipeline.
    public func cancel() {
        cancellationRequested = true
        deployStartedAt = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil
        currentTask?.cancel()
        currentTask = nil
        if !phase.isTerminal {
            transitionTo(.cancelled)
        }
    }

    /// Reset to idle state after completion, failure, or cancellation.
    public func reset() {
        cancellationRequested = false
        deployStartedAt = nil
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
        secretsGate?.cancel()
        secretsGate = nil
        deployProgress = nil
        providedSecrets = [:]
        phase = .idle
        emit(.phaseChanged(.idle))
    }

    /// Returns the cached preflight report, if available.
    public var latestPreflightReport: PreflightReport? {
        cachedPreflightReport
    }

    /// Invalidate cached preflight report (e.g., on workspace reload).
    public func invalidatePreflightCache() {
        cachedPreflightReport = nil
    }

    // MARK: - Private

    private func transitionTo(_ newPhase: AIBDeployPhase) {
        phase = newPhase
        emit(.phaseChanged(newPhase))
    }

    private func emit(_ event: AIBDeployEvent) {
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
}

private extension AIBDeployPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}
