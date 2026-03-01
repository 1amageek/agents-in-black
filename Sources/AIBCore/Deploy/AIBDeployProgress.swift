import Foundation

/// A single step within the per-service deploy process.
public enum AIBDeployStep: String, Sendable {
    case dockerBuild
    case dockerPush
    case serviceDeploy
    case authBind

    /// Ordered pipeline steps that each service goes through.
    public static let servicePipeline: [AIBDeployStep] = [.dockerBuild, .dockerPush, .serviceDeploy]

    /// Number of steps per service.
    public static let servicePipelineCount: Int64 = Int64(servicePipeline.count)
}

/// Progress report for a single service step (used for event notifications).
public struct AIBDeployServiceProgress: Sendable {
    public var serviceID: String
    public var step: AIBDeployStep
    public var status: AIBDeployStepStatus

    public init(serviceID: String, step: AIBDeployStep, status: AIBDeployStepStatus) {
        self.serviceID = serviceID
        self.step = step
        self.status = status
    }
}

public enum AIBDeployStepStatus: Sendable {
    case started
    case completed
    case failed(String)
}
