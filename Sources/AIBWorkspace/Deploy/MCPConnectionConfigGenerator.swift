import Foundation

/// Generates MCP connection configuration for agent services.
/// Produces JSON in the same format as local runtime connection artifacts,
/// but with Cloud Run URLs instead of localhost.
public enum MCPConnectionConfigGenerator {

    /// A resolved MCP server entry.
    public struct MCPServerEntry: Codable, Sendable {
        public var serviceRef: String?
        public var resolvedURL: String
        public var transport: String

        enum CodingKeys: String, CodingKey {
            case serviceRef = "service_ref"
            case resolvedURL = "resolved_url"
            case transport
        }
    }

    /// A resolved A2A agent entry.
    public struct A2AAgentEntry: Codable, Sendable {
        public var serviceRef: String?
        public var resolvedURL: String

        enum CodingKeys: String, CodingKey {
            case serviceRef = "service_ref"
            case resolvedURL = "resolved_url"
        }
    }

    /// The full connection config for an agent service.
    public struct ConnectionConfig: Codable, Sendable {
        public var serviceID: String
        public var mcpServers: [MCPServerEntry]
        public var a2aAgents: [A2AAgentEntry]

        enum CodingKeys: String, CodingKey {
            case serviceID = "service_id"
            case mcpServers = "mcp_servers"
            case a2aAgents = "a2a_agents"
        }
    }

    /// Generate connection config JSON for an agent service.
    public static func generate(
        serviceID: String,
        mcpServers: [(serviceRef: String, resolvedURL: String)],
        a2aAgents: [(serviceRef: String, resolvedURL: String)]
    ) throws -> String {
        let config = ConnectionConfig(
            serviceID: serviceID,
            mcpServers: mcpServers.map { MCPServerEntry(
                serviceRef: $0.serviceRef,
                resolvedURL: $0.resolvedURL,
                transport: "streamable_http"
            )},
            a2aAgents: a2aAgents.map { A2AAgentEntry(
                serviceRef: $0.serviceRef,
                resolvedURL: $0.resolvedURL
            )}
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MCPConnectionConfigGenerator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode connection config as UTF-8",
            ])
        }
        return json + "\n"
    }
}
