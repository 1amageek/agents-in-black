import Foundation

public struct ServiceID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct BackendEndpoint: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int

    /// Path to a host-side Unix domain socket exposed via vsock relay.
    /// When set, connections go through UDS instead of TCP.
    public var unixSocketPath: String?

    public init(host: String = "127.0.0.1", port: Int, unixSocketPath: String? = nil) {
        self.host = host
        self.port = port
        self.unixSocketPath = unixSocketPath
    }

    /// Authority used for HTTP/1.1 Host header.
    public var hostHeaderValue: String {
        if unixSocketPath != nil {
            return "localhost"
        }
        if port == 80 {
            return authorityHost
        }
        return "\(authorityHost):\(port)"
    }

    /// Build a full request URL for this endpoint.
    public func requestURL(path: String, query: String? = nil) -> String {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        var url = "\(baseURLString)\(normalizedPath)"
        if let query, !query.isEmpty {
            url += "?\(query)"
        }
        return url
    }

    public var baseURLString: String {
        if let uds = unixSocketPath {
            let encoded = uds.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? uds
            return "http+unix://\(encoded)"
        }
        return "http://\(authorityHost):\(port)"
    }

    private var authorityHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "localhost"
        }
        switch trimmed {
        case "127.0.0.1", "::1":
            return "localhost"
        default:
            return trimmed
        }
    }
}
