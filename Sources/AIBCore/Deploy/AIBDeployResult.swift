import Foundation

/// The result of a completed deployment.
public struct AIBDeployResult: Sendable {
    public var plan: AIBDeployPlan
    public var serviceResults: [AIBDeployServiceResult]
    public var authBindingsApplied: Int

    public init(
        plan: AIBDeployPlan,
        serviceResults: [AIBDeployServiceResult],
        authBindingsApplied: Int = 0
    ) {
        self.plan = plan
        self.serviceResults = serviceResults
        self.authBindingsApplied = authBindingsApplied
    }

    public var allSucceeded: Bool {
        serviceResults.allSatisfy(\.success)
    }
}

/// The result of deploying a single service.
public struct AIBDeployServiceResult: Sendable, Identifiable {
    public let id: String
    public var deployedURL: String?
    public var success: Bool
    public var errorMessage: String?

    public init(
        id: String,
        deployedURL: String? = nil,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.deployedURL = deployedURL
        self.success = success
        self.errorMessage = errorMessage
    }
}
