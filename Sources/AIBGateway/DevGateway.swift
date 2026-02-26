import AIBConfig
import AIBRuntimeCore
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public final class DevGateway: @unchecked Sendable {
    public let control: GatewayControl
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let httpClient: HTTPClient
    private var channel: Channel?
    private let gatewayConfig: GatewayConfig

    public init(
        gatewayConfig: GatewayConfig,
        control: GatewayControl = GatewayControl(),
        logger: Logger
    ) {
        self.gatewayConfig = gatewayConfig
        self.control = control
        self.logger = logger
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.eventLoopGroup))
    }

    deinit {
        try? httpClient.syncShutdown()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [control, logger, httpClient, gatewayConfig] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPProxyHandler(
                            control: control,
                            httpClient: httpClient,
                            logger: logger,
                            gatewayConfig: gatewayConfig
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: gatewayConfig.port).get()
        self.channel = channel
        logger.info("DevGateway started", metadata: ["port": "\(gatewayConfig.port)"])
    }

    public func stop() async throws {
        if let channel {
            try await channel.close().get()
        }
        try await httpClient.shutdown()
        try await eventLoopGroup.shutdownGracefully()
    }
}
