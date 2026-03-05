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

    public enum Transport: String, Sendable, Codable {
        case tcp
        case unixSocket
    }

    public init(host: String = "127.0.0.1", port: Int, unixSocketPath: String? = nil) {
        self.host = host
        self.port = port
        self.unixSocketPath = unixSocketPath
    }

    public var transport: Transport {
        unixSocketPath == nil ? .tcp : .unixSocket
    }

    /// Authority used for HTTP/1.1 Host header.
    ///
    /// For TCP endpoints this includes the non-default port.
    /// For Unix socket endpoints this is host-only because the socket path
    /// already determines the destination.
    public var hostHeaderValue: String {
        switch transport {
        case .tcp:
            if port == 80 {
                return authorityHost
            }
            return "\(authorityHost):\(port)"
        case .unixSocket:
            return authorityHost
        }
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
            // Percent-encode the socket path into the host position.
            // AsyncHTTPClient's DeconstructedURL extracts url.host to get the socket path.
            // Without encoding, "http+unix:///tmp/x.sock" produces host=nil → missingSocketPath.
            // Matches AsyncHTTPClient's URL(httpURLWithSocketPath:uri:) encoding.
            let encoded = uds.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? uds
            return "http+unix://\(encoded)"
        }
        return "http://\(authorityHost):\(port)"
    }

    private var authorityHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "localhost" : trimmed
    }
}
