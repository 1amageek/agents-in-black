import Foundation

/// Describes the HTTP endpoint and JSON paths for a chat service.
struct ChatEndpoint: Sendable, Equatable {
    let baseURL: URL
    let method: String
    let path: String
    let requestContentType: String
    let requestMessageJSONPath: String
    let requestContextJSONPath: String?
    let responseMessageJSONPath: String

    /// Fully resolved URL for sending chat messages.
    var resolvedURL: URL? {
        let normalized = normalizedPath(path)
        return URL(string: baseURL.absoluteString + normalized)
    }

    private func normalizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }
}
