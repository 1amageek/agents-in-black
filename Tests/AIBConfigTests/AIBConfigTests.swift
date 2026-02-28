import Foundation
import Testing
@testable import AIBConfig

@Test(.timeLimit(.minutes(1)))
func durationParserParsesSeconds() throws {
    let duration = try DurationString("5s").parse()
    #expect(duration.components.seconds == 5)
}

@Test(.timeLimit(.minutes(1)))
func validatorRejectsInvalidConnectionReferences() throws {
    let config = AIBConfig(
        version: 1,
        gateway: .init(),
        services: [
            ServiceConfig(
                id: "agent-a",
                kind: .agent,
                mountPath: "/agents/a",
                port: 0,
                run: ["swift", "run"],
                watchMode: .external,
                health: .init(),
                restart: .init(),
                connections: .init(
                    mcpServers: [.init(serviceRef: "agent-b")], // invalid: points to agent
                    a2aAgents: [.init(serviceRef: "mcp-c")] // invalid: points to mcp
                )
            ),
            ServiceConfig(
                id: "agent-b",
                kind: .agent,
                mountPath: "/agents/b",
                port: 0,
                run: ["swift", "run"],
                watchMode: .external,
                health: .init(),
                restart: .init()
            ),
            ServiceConfig(
                id: "mcp-c",
                kind: .mcp,
                mountPath: "/mcp/c",
                port: 0,
                run: ["node", "server.js"],
                watchMode: .internal,
                health: .init(),
                restart: .init()
            ),
        ]
    )

    let result = try AIBConfigValidator.validate(config)
    #expect(!result.errors.isEmpty)
    #expect(result.errors.contains(where: { $0.contains("must be kind=mcp") }))
    #expect(result.errors.contains(where: { $0.contains("must be kind=agent") }))
}
