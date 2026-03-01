import Foundation
import Logging

/// Static facade for deployment execution.
/// Delegates to `DefaultDeployExecutor` — exists for CLI backward compatibility.
/// For testable code, inject `DeployExecuting` via constructor instead.
public enum AIBDeployExecutor {

    /// Execute the full deploy pipeline for all services in the plan.
    public static func execute(
        plan: AIBDeployPlan,
        provider: any DeploymentProvider,
        workspaceRoot: String,
        overallProgress: Progress,
        logHandler: @escaping @Sendable (AIBDeployLogEntry) -> Void
    ) async throws -> AIBDeployResult {
        let executor = DefaultDeployExecutor()
        return try await executor.execute(
            plan: plan,
            provider: provider,
            workspaceRoot: workspaceRoot,
            overallProgress: overallProgress,
            logHandler: logHandler
        )
    }
}
