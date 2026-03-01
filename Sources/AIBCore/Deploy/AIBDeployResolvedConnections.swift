import Foundation

/// Resolved connections for a service in the deployment environment.
public struct AIBDeployResolvedConnections: Sendable, Equatable {
    public var mcpServers: [AIBDeployConnectionEntry]
    public var a2aAgents: [AIBDeployConnectionEntry]

    public init(
        mcpServers: [AIBDeployConnectionEntry] = [],
        a2aAgents: [AIBDeployConnectionEntry] = []
    ) {
        self.mcpServers = mcpServers
        self.a2aAgents = a2aAgents
    }
}

/// A resolved connection entry pointing to a deployed service URL.
public struct AIBDeployConnectionEntry: Sendable, Equatable {
    public var serviceRef: String
    public var deployedServiceName: String
    public var resolvedURL: String
    public var transport: String

    public init(
        serviceRef: String,
        deployedServiceName: String,
        resolvedURL: String,
        transport: String = "streamable_http"
    ) {
        self.serviceRef = serviceRef
        self.deployedServiceName = deployedServiceName
        self.resolvedURL = resolvedURL
        self.transport = transport
    }
}
