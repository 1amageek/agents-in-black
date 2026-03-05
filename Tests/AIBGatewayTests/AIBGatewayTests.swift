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

@Test(.timeLimit(.minutes(1)))
func backendEndpointTCPURLAndHostHeader() {
    let endpoint = BackendEndpoint(host: "127.0.0.1", port: 8080)

    #expect(endpoint.transport == .tcp)
    #expect(endpoint.baseURLString == "http://127.0.0.1:8080")
    #expect(endpoint.requestURL(path: "/health") == "http://127.0.0.1:8080/health")
    #expect(endpoint.requestURL(path: "/health", query: "a=1") == "http://127.0.0.1:8080/health?a=1")
    #expect(endpoint.hostHeaderValue == "127.0.0.1:8080")
}

@Test(.timeLimit(.minutes(1)))
func backendEndpointUnixSocketURLAndHostHeader() {
    let endpoint = BackendEndpoint(host: "localhost", port: 8080, unixSocketPath: "/tmp/aib-svc.sock")

    #expect(endpoint.transport == .unixSocket)
    #expect(endpoint.baseURLString == "http+unix://%2Ftmp%2Faib-svc.sock")
    #expect(endpoint.requestURL(path: "/health") == "http+unix://%2Ftmp%2Faib-svc.sock/health")
    #expect(endpoint.hostHeaderValue == "localhost")
}
