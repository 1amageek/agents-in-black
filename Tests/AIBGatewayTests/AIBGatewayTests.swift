import AIBRuntimeCore
import Testing

@Test(.timeLimit(.minutes(1)))
func routeMatcherLongestPrefix() {
    let snapshot = RouteSnapshot(
        version: 1,
        entries: [
            .init(serviceID: "a", mountPath: "/agents", backend: .init(port: 9001), pathRewrite: .stripPrefix, cookiePathRewrite: true, maxInflight: 80),
            .init(serviceID: "b", mountPath: "/agents/a", backend: .init(port: 9002), pathRewrite: .stripPrefix, cookiePathRewrite: true, maxInflight: 80),
        ]
    )
    let match = RouterMatcher.match(snapshot: snapshot, uriPath: "/agents/a/test", query: nil)
    #expect(match?.entry.serviceID.rawValue == "b")
    #expect(match?.backendPath == "/test")
}
