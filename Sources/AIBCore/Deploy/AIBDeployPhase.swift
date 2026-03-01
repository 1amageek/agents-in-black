import Foundation

/// The current phase of the deployment pipeline.
public enum AIBDeployPhase: Sendable {
    case idle
    case preflight
    case planning
    case reviewing(AIBDeployPlan)
    case applying(AIBDeployPlan)
    case completed(AIBDeployResult)
    case failed(AIBDeployError)
    case cancelled
}
