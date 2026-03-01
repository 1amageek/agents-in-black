import Foundation

/// An auth binding that grants one deployed service access to another.
public struct AIBDeployAuthBinding: Sendable, Equatable {
    public var sourceServiceName: String
    public var targetServiceName: String
    public var role: String
    public var member: String

    public init(
        sourceServiceName: String,
        targetServiceName: String,
        role: String = "roles/run.invoker",
        member: String
    ) {
        self.sourceServiceName = sourceServiceName
        self.targetServiceName = targetServiceName
        self.role = role
        self.member = member
    }
}
