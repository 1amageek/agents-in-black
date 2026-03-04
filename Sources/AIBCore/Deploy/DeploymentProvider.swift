import Foundation

/// Protocol defining cloud deployment operations.
/// Each provider (GCP Cloud Run, AWS ECS, etc.) implements this protocol
/// to supply provider-specific preflight checks, URL resolution,
/// config generation, and deploy commands.
public protocol DeploymentProvider: Sendable {

    /// Unique identifier for this provider (e.g., "gcp-cloudrun", "aws-ecs").
    var providerID: String { get }

    /// Human-readable display name for UI presentation.
    var displayName: String { get }

    /// Return the preflight checkers specific to this provider.
    func preflightCheckers() -> [any PreflightChecker]

    /// Return preflight check dependency mappings.
    /// Key: prerequisite check ID. Value: check IDs that depend on the prerequisite.
    /// If the prerequisite fails, dependent checks are skipped.
    func preflightDependencies() -> [PreflightCheckID: [PreflightCheckID]]

    /// Extract provider-specific detected values from a preflight report.
    /// For example, GCP extracts `gcpProject` from the gcloud project checker result.
    /// Returns key-value pairs to merge into `AIBDeployTargetConfig.providerConfig`.
    func extractDetectedConfig(from report: PreflightReport) -> [String: String]

    /// Validate that the target config contains all required provider-specific fields.
    /// Throws `AIBDeployError` if a required field is missing.
    func validateTargetConfig(_ config: AIBDeployTargetConfig) throws

    /// Sanitize a package-derived service name into a valid deployed service name.
    /// For example, Cloud Run requires lowercase letters, hyphens, max 63 chars.
    func deployedServiceName(from namespacedID: String) -> String

    /// Resolve a service_ref to a deployed URL at plan time.
    func resolveURL(
        serviceRef: String,
        region: String,
        path: String?,
        serviceNameMap: [String: String]
    ) -> String

    /// Generate provider-specific deploy config content (e.g., clouddeploy.yaml).
    func generateDeployConfig(service: AIBDeployServicePlan) -> String

    /// Build the container registry image tag for a service.
    func registryImageTag(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> String

    /// Return shell commands to configure registry authentication (run once before all services).
    func registryAuthCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand]

    /// Return shell commands to ensure the registry repository exists for a service (idempotent).
    func ensureRegistryRepoCommands(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand]

    /// Return shell commands for container build + push.
    func buildAndPushCommands(
        imageTag: String,
        dockerfilePath: String,
        buildContext: String
    ) -> [DeployCommand]

    /// Return shell commands for deploying a service.
    /// - Parameter secrets: User-provided secret values (name → value) for this service.
    func deployCommands(
        service: AIBDeployServicePlan,
        imageTag: String,
        targetConfig: AIBDeployTargetConfig,
        secrets: [String: String]
    ) -> [DeployCommand]

    /// Return shell commands for auth/access bindings.
    func authBindingCommands(
        binding: AIBDeployAuthBinding,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand]

    /// Query existing environment variable names already configured on a deployed service.
    /// Returns an empty set if the service does not exist or has no env vars.
    func existingEnvVarNames(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> Set<String>

    /// Parse the deployed URL from command output.
    func parseDeployedURL(from output: String) -> String?

    /// Generate the auth binding member string for a source service.
    func authBindingMember(
        sourceServiceName: String,
        targetConfig: AIBDeployTargetConfig
    ) -> String
}

// MARK: - Default Implementations

extension DeploymentProvider {

    /// Prerequisite check IDs derived from `preflightDependencies()` keys.
    /// These represent the tool-installation checks (Phase 1) that gate dependent checks.
    public var prerequisiteCheckIDs: Set<PreflightCheckID> {
        Set(preflightDependencies().keys)
    }

    public func registryAuthCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }
    public func ensureRegistryRepoCommands(service: AIBDeployServicePlan, targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }

    public func existingEnvVarNames(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> Set<String> { [] }
}
