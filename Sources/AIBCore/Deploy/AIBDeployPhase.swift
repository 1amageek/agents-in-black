import Foundation

/// The current phase of the deployment pipeline.
public enum AIBDeployPhase: Sendable {
    case idle
    case preflight
    case planning
    case reviewing(AIBDeployPlan)
    /// Waiting for user to provide secret values before deployment.
    /// The associated plan and the unresolved secret names are provided for
    /// the UI. Declared `SecretRef`s are NOT included here — they are mounted
    /// straight from the provider's secret store and need no user input.
    case secretsInput(AIBDeployPlan, unresolvedSecrets: [String])
    case applying(AIBDeployPlan)
    case completed(AIBDeployResult)
    case failed(AIBDeployError)
    case cancelled
}
