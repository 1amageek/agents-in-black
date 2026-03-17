import AIBRuntimeCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ContextPropagationTests {

    @Test
    func routeEntryCarriesServiceKind() {
        let agentEntry = RouteEntry(
            serviceID: "agent-1",
            kind: .agent,
            mountPath: "/agents/chat",
            backend: .init(port: 9001),
            pathRewrite: .stripPrefix,
            cookiePathRewrite: false,
            maxInflight: 10
        )
        #expect(agentEntry.kind == .agent)

        let mcpEntry = RouteEntry(
            serviceID: "mcp-1",
            kind: .mcp,
            mountPath: "/mcp/tools",
            backend: .init(port: 9002),
            pathRewrite: .stripPrefix,
            cookiePathRewrite: false,
            maxInflight: 10
        )
        #expect(mcpEntry.kind == .mcp)
    }

    @Test
    func routeEntryDefaultsToUnknown() {
        let entry = RouteEntry(
            serviceID: "svc-1",
            mountPath: "/svc",
            backend: .init(port: 9003),
            pathRewrite: .preserve,
            cookiePathRewrite: false,
            maxInflight: 10
        )
        #expect(entry.kind == .unknown)
    }

    @Test
    func routeMatcherPreservesKind() {
        let snapshot = RouteSnapshot(
            version: 1,
            entries: [
                .init(
                    serviceID: "agent-1",
                    kind: .agent,
                    mountPath: "/agents/chat",
                    backend: .init(port: 9001),
                    pathRewrite: .stripPrefix,
                    cookiePathRewrite: false,
                    maxInflight: 10
                ),
                .init(
                    serviceID: "mcp-1",
                    kind: .mcp,
                    mountPath: "/mcp/tools",
                    backend: .init(port: 9002),
                    pathRewrite: .stripPrefix,
                    cookiePathRewrite: false,
                    maxInflight: 10
                ),
            ]
        )

        let agentMatch = RouterMatcher.match(snapshot: snapshot, uriPath: "/agents/chat/send", query: nil)
        #expect(agentMatch?.entry.kind == .agent)

        let mcpMatch = RouterMatcher.match(snapshot: snapshot, uriPath: "/mcp/tools/list", query: nil)
        #expect(mcpMatch?.entry.kind == .mcp)
    }

    @Test
    func contextPropagationConstants() {
        #expect(ContextPropagationHeaders.bodyKey == "context")
        #expect(ContextPropagationHeaders.contextHeader == "X-Context")
    }
}
