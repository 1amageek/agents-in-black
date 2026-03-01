import Foundation

// MARK: - Chat Message

struct ChatMessageItem: Identifiable {
    var id: UUID = UUID()
    var role: ChatMessageRole
    var text: String
    var timestamp: Date
    var latencyMs: Int?
    var statusCode: Int?
    var requestID: String?
    var kind: ChatMessageKind
    var rawResponseBody: String?
}

enum ChatMessageRole: String {
    case user
    case assistant
    case system
    case error
    case info
}

enum ChatMessageKind {
    case user(String)
    case assistant(String)
    case system(String)
    case error(String)
    case info(String)

    var text: String {
        switch self {
        case .user(let value), .assistant(let value), .system(let value), .error(let value), .info(let value):
            return value
        }
    }

    var defaultRole: ChatMessageRole {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system:
            return .system
        case .error:
            return .error
        case .info:
            return .info
        }
    }
}
