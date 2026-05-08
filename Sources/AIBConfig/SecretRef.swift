import Foundation

/// Reference to a secret value stored in a provider-managed secret store
/// (e.g. GCP Secret Manager). Secrets are addressed by name, not by literal
/// value — the value lives in the provider, not in `workspace.yaml`.
///
/// At deploy time the provider mounts the referenced version into the
/// container as an environment variable (Cloud Run: `--set-secrets KEY=name:version`).
/// At local runtime the value is resolved through `.aib/secrets.local.yaml`
/// or by fetching the live version from the provider — never persisted in
/// the committed config.
public struct SecretRef: Sendable, Codable, Hashable, Equatable {
    /// Provider-side secret name (e.g. `ANTHROPIC_API_KEY`). Must match the
    /// name registered in the secret store; AIB does not auto-rename.
    public var secret: String

    /// Specific version to mount, or nil to track `latest`.
    /// Pinning to a numeric version is the safer default for production —
    /// `latest` is only resolved at deploy time and silently rolls forward.
    public var version: String?

    public init(secret: String, version: String? = nil) {
        self.secret = secret
        self.version = version
    }

    /// Concrete version string for provider commands. Falls back to "latest".
    public var resolvedVersion: String { version ?? "latest" }

    enum CodingKeys: String, CodingKey {
        case secret
        case version
    }
}
