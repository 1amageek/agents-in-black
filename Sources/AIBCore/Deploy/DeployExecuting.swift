import Foundation

/// Abstraction for deployment execution.
/// Enables constructor injection of `ProcessRunner` for testability.
public protocol DeployExecuting: Sendable {
    /// Execute the full deploy pipeline for all services in the plan.
    ///
    /// - Parameters:
    ///   - plan: The deployment plan to execute.
    ///   - provider: The cloud provider handling deployment commands.
    ///   - workspaceRoot: Absolute path to the workspace root directory.
    ///   - overallProgress: Foundation `Progress` tree root. The executor creates
    ///     child `Progress` per service and updates `completedUnitCount` as steps finish.
    ///   - secrets: User-provided secret values (name → value) to pass to deploy commands.
    ///   - logHandler: Called for each log line as it becomes available.
    /// - Returns: The aggregated result after all services are processed.
    func execute(
        plan: AIBDeployPlan,
        provider: any DeploymentProvider,
        workspaceRoot: String,
        overallProgress: Progress,
        secrets: [String: String],
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void
    ) async throws -> AIBDeployResult
}
