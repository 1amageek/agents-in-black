import AIBConfig
import AIBRuntimeCore
import Foundation

/// Describes a single request lifecycle event observed by the gateway.
public struct GatewayRequestActivity: Sendable {
    public let serviceID: ServiceID
    public let phase: Phase

    public enum Phase: Sendable {
        case started
        case completed
    }

    public init(serviceID: ServiceID, phase: Phase) {
        self.serviceID = serviceID
        self.phase = phase
    }
}

/// Request/response types for local request handlers.
public struct LocalRequest: Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var headers: [(String, String)]
    public var body: Data

    public init(method: String, path: String, query: String? = nil, headers: [(String, String)] = [], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct LocalResponse: Sendable {
    public var statusCode: UInt
    public var headers: [(String, String)]
    public var body: Data

    public init(statusCode: UInt, headers: [(String, String)] = [], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Handler that processes a request locally. Return nil to fall through to proxy.
public typealias LocalRequestHandler = @Sendable (LocalRequest) async throws -> LocalResponse?

public actor GatewayControl {
    private var snapshot: RouteSnapshot = .init(version: 0, entries: [])
    private var unavailable: [ServiceID: UnavailableReason] = [:]
    private var inflight: [ServiceID: Int] = [:]
    private var activityContinuations: [UUID: AsyncStream<GatewayRequestActivity>.Continuation] = [:]
    private var localHandlers: [ServiceID: LocalRequestHandler] = [:]

    public init() {}

    // MARK: - Request Activity Stream

    public func requestActivities() -> AsyncStream<GatewayRequestActivity> {
        let id = UUID()
        return AsyncStream { continuation in
            activityContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeActivityContinuation(id) }
            }
        }
    }

    public func shutdownActivityStreams() {
        for continuation in activityContinuations.values {
            continuation.finish()
        }
        activityContinuations.removeAll()
    }

    private func removeActivityContinuation(_ id: UUID) {
        activityContinuations.removeValue(forKey: id)
    }

    private func emitActivity(_ activity: GatewayRequestActivity) {
        for continuation in activityContinuations.values {
            continuation.yield(activity)
        }
    }

    public func applyRouteSnapshot(_ snapshot: RouteSnapshot) async throws {
        self.snapshot = RouteSnapshot(version: snapshot.version, entries: snapshot.entries, unavailable: unavailable)
        for entry in snapshot.entries where inflight[entry.serviceID] == nil {
            inflight[entry.serviceID] = 0
        }
    }

    public func markServiceDraining(_ serviceID: ServiceID) async {
        unavailable[serviceID] = .draining
        snapshot = .init(version: snapshot.version + 1, entries: snapshot.entries, unavailable: unavailable)
    }

    public func markServiceReady(_ serviceID: ServiceID, endpoint: BackendEndpoint) async {
        unavailable.removeValue(forKey: serviceID)
        let updatedEntries = snapshot.entries.map { entry in
            guard entry.serviceID == serviceID else { return entry }
            return RouteEntry(
                serviceID: entry.serviceID,
                kind: entry.kind,
                mountPath: entry.mountPath,
                backend: endpoint,
                pathRewrite: entry.pathRewrite,
                cookiePathRewrite: entry.cookiePathRewrite,
                maxInflight: entry.maxInflight
            )
        }
        snapshot = .init(version: snapshot.version + 1, entries: updatedEntries, unavailable: unavailable)
    }

    public func markServiceUnavailable(_ serviceID: ServiceID, reason: UnavailableReason) async {
        unavailable[serviceID] = reason
        snapshot = .init(version: snapshot.version + 1, entries: snapshot.entries, unavailable: unavailable)
    }

    public func currentSnapshot() async -> RouteSnapshot {
        snapshot
    }

    public enum MatchError: Error, Sendable {
        case noRoute
        case unavailable(UnavailableReason)
    }

    public func match(path: String, query: String?) async -> Result<RouteMatch, MatchError> {
        guard let match = RouterMatcher.match(snapshot: snapshot, uriPath: path, query: query) else {
            return .failure(.noRoute)
        }
        if let reason = unavailable[match.entry.serviceID] {
            return .failure(.unavailable(reason))
        }
        return .success(match)
    }

    public func tryAcquire(serviceID: ServiceID, maxInflight: Int) async -> Bool {
        let current = inflight[serviceID, default: 0]
        guard current < maxInflight else { return false }
        inflight[serviceID] = current + 1
        emitActivity(GatewayRequestActivity(serviceID: serviceID, phase: .started))
        return true
    }

    public func release(serviceID: ServiceID) async {
        let current = inflight[serviceID, default: 0]
        inflight[serviceID] = max(current - 1, 0)
        emitActivity(GatewayRequestActivity(serviceID: serviceID, phase: .completed))
    }

    public func inflightCount(serviceID: ServiceID) async -> Int {
        inflight[serviceID, default: 0]
    }

    // MARK: - Local Handlers

    public func registerLocalHandler(serviceID: ServiceID, handler: @escaping LocalRequestHandler) {
        localHandlers[serviceID] = handler
    }

    public func localHandler(for serviceID: ServiceID) -> LocalRequestHandler? {
        localHandlers[serviceID]
    }
}

public extension RouteSnapshot {
    static func from(config: AIBConfig, backends: [ServiceID: BackendEndpoint], version: Int = 1) -> RouteSnapshot {
        let entries = config.services.map { service in
            RouteEntry(
                serviceID: service.id,
                kind: service.kind,
                mountPath: service.mountPath,
                backend: backends[service.id] ?? BackendEndpoint(port: service.port),
                pathRewrite: service.pathRewrite,
                cookiePathRewrite: service.cookiePathRewrite,
                maxInflight: service.concurrency.maxInflight
            )
        }
        return .init(version: version, entries: entries)
    }
}
