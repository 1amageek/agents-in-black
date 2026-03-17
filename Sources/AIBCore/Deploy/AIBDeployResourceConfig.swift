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

    /// Kind-aware smart defaults.
    /// Agent services need more resources and longer timeouts for LLM inference + tool execution.
    /// MCP services are lightweight stateless tool servers.
    public static func defaults(for kind: AIBServiceKind) -> AIBDeployResourceConfig {
        switch kind {
        case .agent:
            return AIBDeployResourceConfig(
                memory: "1Gi",
                cpu: "1",
                maxInstances: 10,
                minInstances: 0,
                concurrency: 10,
                timeout: "900s"
            )
        case .mcp:
            return AIBDeployResourceConfig(
                memory: "256Mi",
                cpu: "1",
                maxInstances: 20,
                minInstances: 0,
                concurrency: 80,
                timeout: "300s"
            )
        case .unknown:
            return AIBDeployResourceConfig()
        }
    }
}
