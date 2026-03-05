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

    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        self.port = port
    }

    /// Authority used for HTTP/1.1 Host header.
    public var hostHeaderValue: String {
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
        return "http://\(authorityHost):\(port)"
    }

    private var authorityHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "localhost" : trimmed
    }
}
