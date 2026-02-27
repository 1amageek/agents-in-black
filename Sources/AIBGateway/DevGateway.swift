import AIBConfig
import AIBRuntimeCore
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// Type alias for the per-connection async channel used by the gateway.
///
/// Inbound: HTTP request parts from the client.
/// Outbound: HTTP response parts written back to the client (ByteBuffer variant,
/// converted to IOData by ``HTTPByteBufferResponsePartHandler``).
typealias HTTPRequestChannel = NIOAsyncChannel<
    HTTPServerRequestPart,
    HTTPPart<HTTPResponseHead, ByteBuffer>
>

public final class DevGateway: Sendable {
    public let control: GatewayControl
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let httpClient: HTTPClient
    private let gatewayConfig: GatewayConfig
    private let phase: Mutex<LifecyclePhase>

    enum LifecyclePhase: Sendable {
        case idle
        case starting
        case running(acceptTask: Task<Void, Never>)
        case stopped
    }

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
        self.phase = Mutex(.idle)
    }

    public func start() async throws {
        let canStart = phase.withLock { p -> Bool in
            guard case .idle = p else { return false }
            p = .starting
            return true
        }
        guard canStart else {
            logger.warning("DevGateway start called but not in idle phase")
            return
        }

        let serverChannel: NIOAsyncChannel<HTTPRequestChannel, Never>
        do {
            serverChannel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(.backlog, value: 256)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(
                    host: "127.0.0.1",
                    port: gatewayConfig.port
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPByteBufferResponsePartHandler()
                        )
                        return try HTTPRequestChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            phase.withLock { $0 = .idle }
            throw error
        }

        let connectionHandler = HTTPConnectionHandler(
            control: control,
            httpClient: httpClient,
            logger: logger,
            gatewayConfig: gatewayConfig
        )

        let acceptTask = Task { [logger] in
            do {
                try await withThrowingDiscardingTaskGroup { group in
                    try await serverChannel.executeThenClose { inbound in
                        for try await clientChannel in inbound {
                            group.addTask {
                                await connectionHandler.handle(clientChannel)
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Server accept loop error", metadata: ["error": "\(error)"])
            }
        }

        phase.withLock { $0 = .running(acceptTask: acceptTask) }
        logger.info("DevGateway started", metadata: ["port": "\(gatewayConfig.port)"])
    }

    public func stop() async throws {
        let acceptTask = phase.withLock { p -> Task<Void, Never>? in
            guard case .running(let task) = p else { return nil }
            p = .stopped
            return task
        }
        guard let acceptTask else { return }
        acceptTask.cancel()
        await acceptTask.value
        try await httpClient.shutdown()
        try await eventLoopGroup.shutdownGracefully()
    }
}
