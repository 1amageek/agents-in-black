import Foundation

/// The current phase of the deployment pipeline.
public enum AIBDeployPhase: Sendable {
    case idle
    case preflight
    case planning
    case reviewing(AIBDeployPlan)
    /// Waiting for user to provide secret values before deployment.
    /// The associated plan and required secret names are provided for the UI.
    case secretsInput(AIBDeployPlan, requiredSecrets: [String])
    case applying(AIBDeployPlan)
    case completed(AIBDeployResult)
    case failed(AIBDeployError)
    case cancelled
}
