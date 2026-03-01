import Foundation

/// Abstraction for deployment plan generation operations.
/// Enables constructor injection for testability (following the
/// `ProcessController` pattern from AIBSupervisor).
public protocol DeployPlanGenerator: Sendable {
    /// Run preflight checks for the given provider.
    func preflightCheck(provider: any DeploymentProvider) async -> PreflightReport

    /// Load target configuration from `.aib/targets/{providerID}.yaml`.
    func loadTargetConfig(
        workspaceRoot: String,
        providerID: String,
        overrides: [String: String]
    ) throws -> AIBDeployTargetConfig

    /// Generate a deployment plan from workspace topology.
    func generatePlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider
    ) throws -> AIBDeployPlan

    /// Write generated artifacts (Dockerfiles, deploy configs, etc.) to disk.
    func writeArtifacts(plan: AIBDeployPlan, workspaceRoot: String) throws
}
