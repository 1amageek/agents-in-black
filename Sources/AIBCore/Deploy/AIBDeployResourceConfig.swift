import Foundation

/// Cloud Run resource configuration for a service.
public struct AIBDeployResourceConfig: Sendable, Equatable {
    public var memory: String
    public var cpu: String
    public var maxInstances: Int
    public var minInstances: Int
    public var concurrency: Int
    public var timeout: String

    public init(
        memory: String = "512Mi",
        cpu: String = "1",
        maxInstances: Int = 10,
        minInstances: Int = 0,
        concurrency: Int = 80,
        timeout: String = "300s"
    ) {
        self.memory = memory
        self.cpu = cpu
        self.maxInstances = maxInstances
        self.minInstances = minInstances
        self.concurrency = concurrency
        self.timeout = timeout
    }
}
