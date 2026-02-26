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

    public var baseURLString: String {
        "http://\(host):\(port)"
    }
}
