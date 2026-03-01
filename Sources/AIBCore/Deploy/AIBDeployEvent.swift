import Foundation

/// Events emitted by AIBDeployController during the deployment pipeline.
public enum AIBDeployEvent: Sendable {
    case phaseChanged(AIBDeployPhase)
    case log(AIBDeployLogEntry)
}
