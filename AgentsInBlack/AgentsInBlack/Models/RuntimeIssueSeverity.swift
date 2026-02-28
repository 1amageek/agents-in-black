import Foundation

enum RuntimeIssueSeverity: String, CaseIterable, Hashable, Sendable {
    case error
    case warning

    var symbol: String {
        switch self {
        case .error:
            return "xmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
}
