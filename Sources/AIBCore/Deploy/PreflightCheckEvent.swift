import Foundation

/// Event emitted during preflight check execution for real-time UI updates.
public enum PreflightCheckEvent: Sendable {
    case checkStarted(PreflightCheckID)
    case checkCompleted(PreflightCheckResult)
    case allCompleted(PreflightReport)
}
