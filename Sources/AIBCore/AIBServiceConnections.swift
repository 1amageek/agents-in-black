import Foundation

public struct AIBServiceConnections: Hashable, Sendable {
    public var mcpServers: [AIBConnectionTarget]
    public var a2aAgents: [AIBConnectionTarget]

    public init(mcpServers: [AIBConnectionTarget] = [], a2aAgents: [AIBConnectionTarget] = []) {
        self.mcpServers = mcpServers
        self.a2aAgents = a2aAgents
    }
}

public struct AIBConnectionTarget: Hashable, Sendable {
    public var serviceRef: String?
    public var url: String?

    public init(serviceRef: String? = nil, url: String? = nil) {
        self.serviceRef = serviceRef
        self.url = url
    }
}

public struct AIBMCPProfile: Hashable, Sendable {
    public var transport: String
    public var path: String

    public init(transport: String = "streamable_http", path: String = "/mcp") {
        self.transport = transport
        self.path = path
    }
}

public struct AIBA2AProfile: Hashable, Sendable {
    public var cardPath: String
    public var rpcPath: String

    public init(cardPath: String = "/.well-known/agent.json", rpcPath: String = "/a2a") {
        self.cardPath = cardPath
        self.rpcPath = rpcPath
    }
}
