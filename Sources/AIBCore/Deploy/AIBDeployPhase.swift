import Foundation

/// The current phase of the deployment pipeline.
public enum AIBDeployPhase: Sendable {
    case idle
    case preflight
    case planning
    case reviewing(AIBDeployPlan)
    /// Waiting for user to provide secret values before deployment.
    /// - `unresolvedSecrets`: env vars referenced in source code that are not
    ///   pinned anywhere; entered values flow into `--set-env-vars`.
    /// - `missingDeclaredSecrets`: workspace.yaml `secrets:` bindings whose
    ///   backing Secret Manager secret does not exist yet; entered values are
    ///   uploaded via `provider.upsertSecret(...)` before `applying`.
    case secretsInput(
        AIBDeployPlan,
        unresolvedSecrets: [String],
        missingDeclaredSecrets: [String]
    )
    case applying(AIBDeployPlan)
    case completed(AIBDeployResult)
    case failed(AIBDeployError)
    case cancelled
}
