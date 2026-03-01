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
    private var cachedPreflightReport: PreflightReport?

    public private(set) var phase: AIBDeployPhase = .idle

    /// Foundation `Progress` for the current deployment.
    /// Created at the start of the apply phase; nil otherwise.
    /// Observe this from SwiftUI via `ProgressView(progress)`.
    public private(set) var deployProgress: Progress?

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
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
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

                let plan = try self.planGenerator.generatePlan(
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
                    logHandler: { [weak self] logEntry in
                        Task { @MainActor in
                            self?.emit(.log(logEntry))
                        }
                    }
                )

                self.transitionTo(.completed(result))
            } catch {
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

    /// Cancel the current deployment pipeline.
    public func cancel() {
        approvalGate?.deny()
        approvalGate = nil
        currentTask?.cancel()
        currentTask = nil
    }

    /// Reset to idle state after completion, failure, or cancellation.
    public func reset() {
        currentTask?.cancel()
        currentTask = nil
        approvalGate?.deny()
        approvalGate = nil
        deployProgress = nil
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
