import Foundation

public enum AIBReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    public static let defaultAgent: Self = .medium

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "XHigh"
        }
    }
}
