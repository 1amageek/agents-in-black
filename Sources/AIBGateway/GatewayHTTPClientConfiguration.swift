import AIBConfig
import AsyncHTTPClient

struct GatewayHTTPClientConfiguration {
    static let concurrentHTTP1ConnectionsPerHostSoftLimit = 64
    static let preWarmedHTTP1ConnectionCount = 4

    static func make(from gatewayConfig: GatewayConfig) -> HTTPClient.Configuration {
        var configuration = HTTPClient.Configuration()
        configuration.timeout.connect = gatewayConfig.timeouts.backendConnect.asTimeAmount
        configuration.connectionPool.idleTimeout = gatewayConfig.timeouts.idle.asTimeAmount
        configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit =
            concurrentHTTP1ConnectionsPerHostSoftLimit
        configuration.connectionPool.preWarmedHTTP1ConnectionCount =
            preWarmedHTTP1ConnectionCount
        return configuration
    }
}
