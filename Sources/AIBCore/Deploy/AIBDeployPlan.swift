import AIBConfig
import AIBRuntimeCore
import Foundation

/// The complete deploy plan generated from workspace topology.
public struct AIBDeployPlan: Sendable, Identifiable {
    public let id: UUID
    public var timestamp: Date
    public var workspaceName: String
    public var targetConfig: AIBDeployTargetConfig
    public var services: [AIBDeployServicePlan]
    public var authBindings: [AIBDeployAuthBinding]
    public var warnings: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workspaceName: String,
        targetConfig: AIBDeployTargetConfig,
        services: [AIBDeployServicePlan],
        authBindings: [AIBDeployAuthBinding] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workspaceName = workspaceName
        self.targetConfig = targetConfig
        self.services = services
        self.authBindings = authBindings
        self.warnings = warnings
    }

    /// All unique secret names that must be provided by the user before
    /// deploy can proceed. These are env vars referenced in source code that
    /// are neither already in `envVars` nor declared as `SecretRef`s in
    /// workspace.yaml — they require an explicit value at deploy time.
    public var allUnresolvedSecrets: [String] {
        Array(Set(services.flatMap(\.unresolvedSecrets))).sorted()
    }

    /// Whether any service has unresolved secrets that block deployment.
    public var hasUnresolvedSecrets: Bool {
        services.contains { !$0.unresolvedSecrets.isEmpty }
    }

    /// Every distinct secret reference declared across all services. Used by
    /// the deploy pipeline to drive the Secret Manager upload pre-step
    /// (when a value is provided via the local file or pre-existing) and the
    /// `--set-secrets` mount on the resulting Cloud Run service.
    public var allDeclaredSecretRefs: [String: SecretRef] {
        var merged: [String: SecretRef] = [:]
        for service in services {
            for (key, ref) in service.declaredSecretRefs where merged[key] == nil {
                merged[key] = ref
            }
        }
        return merged
    }

    /// All env warnings across all services.
    public var allEnvWarnings: [String] {
        services.flatMap(\.envWarnings)
    }
}

/// Per-service deployment plan.
public struct AIBDeployServicePlan: Sendable, Identifiable {
    public let id: String
    public var serviceKind: AIBServiceKind
    public var runtime: String
    public var repoPath: String
    public var deployedServiceName: String
    public var region: String
    public var artifacts: AIBDeployArtifactSet
    public var resourceConfig: AIBDeployResourceConfig
    public var envVars: [String: String]
    public var connections: AIBDeployResolvedConnections
    public var isPublic: Bool
    public var sourceDependencies: [AIBSourceDependencyFinding]
    public var sourceCredential: AIBSourceCredential?

    /// Secret references declared by the user in workspace.yaml's `secrets:`
    /// block. The value lives in the provider's secret store; only the
    /// reference (name + version) is committed to git. At deploy time these
    /// are mounted as env vars via the provider's `setSecretsArgs`.
    public var declaredSecretRefs: [String: SecretRef]

    /// Env var names detected from source code that are NOT yet pinned —
    /// neither present in `envVars` (workspace.yaml `env`/`deploy_env`) nor
    /// declared as `SecretRef`s. The user must supply values at deploy time
    /// (and the pipeline either uploads them to Secret Manager or sets them
    /// directly via `--set-env-vars`).
    public var unresolvedSecrets: [String]

    /// Warnings about missing non-secret environment variables.
    public var envWarnings: [String]

    public init(
        id: String,
        serviceKind: AIBServiceKind,
        runtime: String,
        repoPath: String,
        deployedServiceName: String,
        region: String,
        artifacts: AIBDeployArtifactSet,
        resourceConfig: AIBDeployResourceConfig = .init(),
        envVars: [String: String] = [:],
        connections: AIBDeployResolvedConnections = .init(),
        isPublic: Bool = false,
        sourceDependencies: [AIBSourceDependencyFinding] = [],
        sourceCredential: AIBSourceCredential? = nil,
        declaredSecretRefs: [String: SecretRef] = [:],
        unresolvedSecrets: [String] = [],
        envWarnings: [String] = []
    ) {
        self.id = id
        self.serviceKind = serviceKind
        self.runtime = runtime
        self.repoPath = repoPath
        self.deployedServiceName = deployedServiceName
        self.region = region
        self.artifacts = artifacts
        self.resourceConfig = resourceConfig
        self.envVars = envVars
        self.connections = connections
        self.isPublic = isPublic
        self.sourceDependencies = sourceDependencies
        self.sourceCredential = sourceCredential
        self.declaredSecretRefs = declaredSecretRefs
        self.unresolvedSecrets = unresolvedSecrets
        self.envWarnings = envWarnings
    }
}
