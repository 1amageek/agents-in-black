import AIBConfig
import AIBRuntimeCore
import Foundation

public actor GatewayControl {
    private var snapshot: RouteSnapshot = .init(version: 0, entries: [])
    private var unavailable: [ServiceID: UnavailableReason] = [:]
    private var inflight: [ServiceID: Int] = [:]

    public init() {}

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
        return true
    }

    public func release(serviceID: ServiceID) async {
        let current = inflight[serviceID, default: 0]
        inflight[serviceID] = max(current - 1, 0)
    }

    public func inflightCount(serviceID: ServiceID) async -> Int {
        inflight[serviceID, default: 0]
    }
}

public extension RouteSnapshot {
    static func from(config: AIBConfig, backends: [ServiceID: BackendEndpoint], version: Int = 1) -> RouteSnapshot {
        let entries = config.services.map { service in
            RouteEntry(
                serviceID: service.id,
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
