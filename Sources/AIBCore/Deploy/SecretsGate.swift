import Foundation

/// Values collected from the user during the `secretsInput` phase.
///
/// Two distinct buckets:
/// - `unresolvedEnv`: env vars referenced in source but not pinned anywhere.
///   These are injected directly via `--set-env-vars KEY=value` at deploy
///   time (never uploaded to Secret Manager).
/// - `declared`: workspace.yaml `secrets:` bindings whose backing Secret
///   Manager secret is missing. The pipeline uploads these via
///   `provider.upsertSecret(...)` *before* `applying`, then mounts them with
///   `--set-secrets KEY=secret:version` like any other declared SecretRef.
public struct SecretsGateResult: Sendable {
    public var unresolvedEnv: [String: String]
    public var declared: [String: String]

    public init(
        unresolvedEnv: [String: String] = [:],
        declared: [String: String] = [:]
    ) {
        self.unresolvedEnv = unresolvedEnv
        self.declared = declared
    }
}

/// A gate that blocks the deploy pipeline until the user provides secret values.
///
/// Similar to `ApprovalGate` but carries a `SecretsGateResult` payload.
/// The pipeline suspends at `wait()` and resumes when the user calls
/// `provide(result:)` or `cancel()`.
@MainActor
final class SecretsGate {
    private var continuation: CheckedContinuation<SecretsGateResult?, Never>?
    private var resolved: Bool = false

    init() {}

    /// Suspend until `provide(result:)` or `cancel()` is called.
    /// Returns the provided secrets, or nil if cancelled.
    func wait() async -> SecretsGateResult? {
        await withCheckedContinuation { (cont: CheckedContinuation<SecretsGateResult?, Never>) in
            self.continuation = cont
        }
    }

    /// Resume the pipeline with the provided secret values.
    func provide(result: SecretsGateResult) {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: result)
        continuation = nil
    }

    /// Cancel — resume the pipeline with nil.
    func cancel() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
