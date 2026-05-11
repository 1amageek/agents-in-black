import Foundation

/// Default implementation that delegates to `AIBDeployService` static methods.
/// Exists solely to satisfy the `DeployPlanGenerator` protocol for DI,
/// while preserving the static facade for CLI backward compatibility.
public struct DefaultDeployPlanGenerator: DeployPlanGenerator {

    public init() {}

    public func preflightCheck(provider: any DeploymentProvider) async -> PreflightReport {
        await AIBDeployService.preflightCheck(provider: provider)
    }

    public func loadTargetConfig(
        workspaceRoot: String,
        providerID: String,
        overrides: [String: String],
        environmentName: String?
    ) throws -> AIBDeployTargetConfig {
        try AIBDeployService.loadTargetConfig(
            workspaceRoot: workspaceRoot,
            providerID: providerID,
            overrides: overrides,
            environmentName: environmentName
        )
    }

    public func generatePlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider,
        selection: AIBDeploySelection?,
        environmentName: String?
    ) async throws -> AIBDeployPlan {
        try await AIBDeployService.generatePlan(
            workspaceRoot: workspaceRoot,
            targetConfig: targetConfig,
            provider: provider,
            selection: selection,
            environmentName: environmentName
        )
    }

    public func writeArtifacts(plan: AIBDeployPlan, workspaceRoot: String) throws {
        try AIBDeployService.writeArtifacts(plan: plan, workspaceRoot: workspaceRoot)
    }
}
