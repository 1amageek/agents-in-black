import Foundation

public struct RouteEntry: Sendable, Hashable {
    public let serviceID: ServiceID
    public let kind: ServiceKind
    public let mountPath: String
    public let backend: BackendEndpoint
    public let pathRewrite: PathRewriteMode
    public let cookiePathRewrite: Bool
    public let maxInflight: Int

    public init(
        serviceID: ServiceID,
        kind: ServiceKind = .unknown,
        mountPath: String,
        backend: BackendEndpoint,
        pathRewrite: PathRewriteMode,
        cookiePathRewrite: Bool,
        maxInflight: Int
    ) {
        self.serviceID = serviceID
        self.kind = kind
        self.mountPath = mountPath
        self.backend = backend
        self.pathRewrite = pathRewrite
        self.cookiePathRewrite = cookiePathRewrite
        self.maxInflight = maxInflight
    }
}

public struct RouteSnapshot: Sendable {
    public let version: Int
    public let entries: [RouteEntry]
    public let unavailable: [ServiceID: UnavailableReason]

    public init(version: Int, entries: [RouteEntry], unavailable: [ServiceID: UnavailableReason] = [:]) {
        self.version = version
        self.entries = entries.sorted { lhs, rhs in
            if lhs.mountPath.count == rhs.mountPath.count {
                return lhs.mountPath < rhs.mountPath
            }
            return lhs.mountPath.count > rhs.mountPath.count
        }
        self.unavailable = unavailable
    }
}

public struct RouteMatch: Sendable {
    public let entry: RouteEntry
    public let backendPath: String
    public let originalPath: String
    public let query: String?
}

public enum RouterMatcher {
    public static func match(snapshot: RouteSnapshot, uriPath: String, query: String?) -> RouteMatch? {
        for entry in snapshot.entries {
            guard matchesPath(uriPath, mountPath: entry.mountPath) else { continue }
            let backendPath: String
            switch entry.pathRewrite {
            case .preserve:
                backendPath = uriPath.isEmpty ? "/" : uriPath
            case .stripPrefix:
                let suffix = String(uriPath.dropFirst(entry.mountPath.count))
                backendPath = suffix.isEmpty ? "/" : suffix
            }
            return RouteMatch(entry: entry, backendPath: backendPath, originalPath: uriPath, query: query)
        }
        return nil
    }

    private static func matchesPath(_ path: String, mountPath: String) -> Bool {
        guard path.hasPrefix(mountPath) else { return false }
        if path.count == mountPath.count {
            return true
        }
        let idx = path.index(path.startIndex, offsetBy: mountPath.count)
        return path[idx] == "/"
    }
}
