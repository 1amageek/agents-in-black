@testable import AIBGateway
import AIBConfig
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GatewayHTTPClientConfigurationTests {

    @Test
    func usesGatewayTimeoutsAndExpandedConnectionPool() {
        let gatewayConfig = GatewayConfig(
            port: 9090,
            timeouts: .init(
                backendConnect: .seconds(7),
                idle: .seconds(90),
                request: .seconds(300)
            )
        )

        let configuration = GatewayHTTPClientConfiguration.make(from: gatewayConfig)

        #expect(configuration.timeout.connect == .seconds(7))
        #expect(configuration.connectionPool.idleTimeout == .seconds(90))
        #expect(
            configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit
                == GatewayHTTPClientConfiguration.concurrentHTTP1ConnectionsPerHostSoftLimit
        )
        #expect(
            configuration.connectionPool.preWarmedHTTP1ConnectionCount
                == GatewayHTTPClientConfiguration.preWarmedHTTP1ConnectionCount
        )
    }
}
