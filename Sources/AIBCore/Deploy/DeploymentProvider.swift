import AIBConfig
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
    /// - Parameter existingServiceURLs: Live base URLs of already-deployed services (serviceRef → URL).
    func resolveURL(
        serviceRef: String,
        region: String,
        path: String?,
        serviceNameMap: [String: String],
        existingServiceURLs: [String: String]
    ) -> String

    /// Generate provider-specific deploy config content (e.g., clouddeploy.yaml).
    func generateDeployConfig(service: AIBDeployServicePlan) -> String

    /// Run plan-specific readiness checks before the user approves deployment.
    /// Generic preflight checks validate tools and broad provider context; readiness
    /// checks validate the concrete target project, region, repositories, and IAM
    /// surfaces that this plan will use.
    func deploymentReadinessChecks(plan: AIBDeployPlan) async -> [PreflightCheckResult]

    /// Build the container registry image tag for a service.
    func registryImageTag(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> String

    /// Return shell commands to configure registry authentication (run once before all services).
    func registryAuthCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand]

    /// Return shell commands to prepare build backend state (run once before all services).
    /// Useful for best-effort cleanup of stale local artifacts before image builds.
    func buildBackendPreparationCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand]

    /// Return shell commands to ensure the registry repository exists for a service (idempotent).
    func ensureRegistryRepoCommands(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand]

    /// Return shell commands for container build + push.
    func buildAndPushCommands(
        imageTag: String,
        dockerfilePath: String,
        buildContext: String,
        targetConfig: AIBDeployTargetConfig
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

    /// Query the live URL of an already-deployed service.
    /// Returns nil if the service does not exist.
    func existingServiceURL(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> String?

    /// Query existing environment variable names already configured on a deployed service.
    /// Returns an empty set if the service does not exist or has no env vars.
    func existingEnvVarNames(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> Set<String>

    /// Query existing environment variable name → value pairs configured on a deployed service.
    /// Returns an empty dict if the service does not exist or has no env vars. Used by the
    /// deploy pipeline to pre-populate secret values from the live service so users are not
    /// re-prompted for secrets that were previously entered, and so the authoritative
    /// `--set-env-vars` does not wipe values the user can no longer easily re-enter
    /// (e.g. one-time API keys pasted from an external provider).
    func existingEnvVars(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> [String: String]

    // MARK: - Secrets

    /// Translate declared secret refs (workspace.yaml `secrets:` block) into
    /// provider-specific CLI args that mount them as env vars at runtime.
    /// Cloud Run: returns `["--set-secrets", "KEY1=secret1:latest,KEY2=secret2:7"]`.
    /// Returns an empty array when there are no secrets to mount.
    func setSecretsArgs(
        declaredSecretRefs: [String: SecretRef],
        targetConfig: AIBDeployTargetConfig
    ) -> [String]

    /// Create the secret if missing and add a new version with `value`.
    /// Idempotent: re-creating an existing secret is treated as success.
    /// Throws `AIBDeployError` on tool / auth / quota failure.
    func upsertSecret(
        name: String,
        value: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws

    /// List every secret name currently configured in the provider's secret
    /// store for this project. Used to decide whether to upload a fresh value
    /// or rely on the value already in the store.
    /// Throws `AIBDeployError` on tool / auth failure.
    func listSecrets(
        targetConfig: AIBDeployTargetConfig
    ) async throws -> Set<String>

    /// Verify that `runtimeServiceAccount` has the accessor role on `name`.
    /// Returns true on confirmed access, false if the binding is missing.
    /// Throws `AIBDeployError` on tool / auth failure so callers can surface it.
    func validateSecretAccess(
        name: String,
        runtimeServiceAccount: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws -> Bool

    /// Grant `runtimeServiceAccount` the accessor role on `name`. Idempotent:
    /// re-binding an already-granted role is treated as success.
    /// Throws `AIBDeployError` on tool / auth / permission failure.
    func grantSecretAccess(
        name: String,
        runtimeServiceAccount: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws

    /// List every service currently deployed under this provider/project.
    /// Includes services in any region — drift detection compares against `targetConfig.region`.
    /// Throws `AIBDeployError` on tool / auth failure so callers can surface it in the UI.
    func listDeployedServices(
        targetConfig: AIBDeployTargetConfig
    ) async throws -> [DeployedServiceInfo]

    /// Delete a deployed service by name in the given region.
    /// Idempotent: succeeds quietly if the service is already gone.
    /// Throws `AIBDeployError` on tool / auth failure or unexpected provider error.
    func deleteDeployedService(
        serviceName: String,
        region: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws

    /// Fetch a snapshot of the most-recent log entries for a deployed service,
    /// newest first. Used for the "Latest" mode of the logs viewer.
    /// Throws `AIBDeployError` on tool / auth failure.
    func fetchServiceLogs(
        serviceName: String,
        region: String,
        limit: Int,
        targetConfig: AIBDeployTargetConfig
    ) async throws -> [CloudLogEntry]

    /// Stream live log entries for a deployed service. Each yielded entry corresponds
    /// to one structured log line. The stream completes (or throws) when the underlying
    /// tail process exits, and terminates when the consumer cancels its task.
    func tailServiceLogs(
        serviceName: String,
        region: String,
        targetConfig: AIBDeployTargetConfig
    ) -> AsyncThrowingStream<CloudLogEntry, any Error>

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
    public func buildBackendPreparationCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }
    public func ensureRegistryRepoCommands(service: AIBDeployServicePlan, targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }
    public func deploymentReadinessChecks(plan: AIBDeployPlan) async -> [PreflightCheckResult] { [] }

    public func existingEnvVarNames(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> Set<String> { [] }

    public func existingEnvVars(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> [String: String] { [:] }

    public func listDeployedServices(
        targetConfig: AIBDeployTargetConfig
    ) async throws -> [DeployedServiceInfo] {
        throw AIBDeployError(
            phase: "deployments",
            message: "Provider '\(providerID)' does not support listing deployed services."
        )
    }

    public func deleteDeployedService(
        serviceName: String,
        region: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws {
        throw AIBDeployError(
            phase: "deployments",
            message: "Provider '\(providerID)' does not support deleting deployed services."
        )
    }

    public func fetchServiceLogs(
        serviceName: String,
        region: String,
        limit: Int,
        targetConfig: AIBDeployTargetConfig
    ) async throws -> [CloudLogEntry] {
        throw AIBDeployError(
            phase: "logs",
            message: "Provider '\(providerID)' does not support fetching service logs."
        )
    }

    public func tailServiceLogs(
        serviceName: String,
        region: String,
        targetConfig: AIBDeployTargetConfig
    ) -> AsyncThrowingStream<CloudLogEntry, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIBDeployError(
                phase: "logs",
                message: "Provider '\(providerID)' does not support tailing service logs."
            ))
        }
    }

    // MARK: - Secrets (default no-op implementations)
    //
    // Providers without a managed secret store treat declared `SecretRef`s as
    // unsupported. The default `setSecretsArgs` returns an empty arg list
    // (silently dropping mounts), and the upload / access methods throw so the
    // pipeline halts before attempting an unsupported operation.

    public func setSecretsArgs(
        declaredSecretRefs: [String: SecretRef],
        targetConfig: AIBDeployTargetConfig
    ) -> [String] { [] }

    public func upsertSecret(
        name: String,
        value: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws {
        throw AIBDeployError(
            phase: "secrets",
            message: "Provider '\(providerID)' does not support managed secrets."
        )
    }

    public func listSecrets(
        targetConfig: AIBDeployTargetConfig
    ) async throws -> Set<String> { [] }

    public func validateSecretAccess(
        name: String,
        runtimeServiceAccount: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws -> Bool { true }

    public func grantSecretAccess(
        name: String,
        runtimeServiceAccount: String,
        targetConfig: AIBDeployTargetConfig
    ) async throws {
        throw AIBDeployError(
            phase: "secrets",
            message: "Provider '\(providerID)' does not support granting secret access."
        )
    }
}
