import Foundation

/// Abstraction for deployment plan generation operations.
/// Enables constructor injection for testability (following the
/// `ProcessController` pattern from AIBSupervisor).
public protocol DeployPlanGenerator: Sendable {
    /// Run preflight checks for the given provider.
    func preflightCheck(provider: any DeploymentProvider) async -> PreflightReport

    /// Load target configuration from `.aib/targets/{providerID}.yaml`,
    /// optionally overlaid with `.aib/environments/<environmentName>.yaml`.
    func loadTargetConfig(
        workspaceRoot: String,
        providerID: String,
        overrides: [String: String],
        environmentName: String?
    ) throws -> AIBDeployTargetConfig

    /// Generate a deployment plan from workspace topology, applying the named
    /// explicit deploy overlay (if any) to per-service env / secrets.
    func generatePlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider,
        selection: AIBDeploySelection?,
        environmentName: String?
    ) async throws -> AIBDeployPlan

    /// Write generated artifacts (Dockerfiles, deploy configs, etc.) to disk.
    func writeArtifacts(plan: AIBDeployPlan, workspaceRoot: String) throws
}

public extension DeployPlanGenerator {
    func loadTargetConfig(
        workspaceRoot: String,
        providerID: String,
        overrides: [String: String] = [:]
    ) throws -> AIBDeployTargetConfig {
        try loadTargetConfig(
            workspaceRoot: workspaceRoot,
            providerID: providerID,
            overrides: overrides,
            environmentName: nil
        )
    }

    func generatePlan(
        workspaceRoot: String,
        targetConfig: AIBDeployTargetConfig,
        provider: any DeploymentProvider,
        selection: AIBDeploySelection? = nil
    ) async throws -> AIBDeployPlan {
        try await generatePlan(
            workspaceRoot: workspaceRoot,
            targetConfig: targetConfig,
            provider: provider,
            selection: selection,
            environmentName: nil
        )
    }
}
