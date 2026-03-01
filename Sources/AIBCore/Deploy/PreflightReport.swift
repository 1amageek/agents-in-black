import Foundation

/// Aggregated result of all preflight checks.
public struct PreflightReport: Sendable {
    public var results: [PreflightCheckResult]
    public var completedAt: Date

    public init(results: [PreflightCheckResult], completedAt: Date = Date()) {
        self.results = results
        self.completedAt = completedAt
    }

    /// Whether all checks passed (warnings are acceptable, failures are not).
    public var canProceed: Bool {
        results.allSatisfy { !$0.isFailed }
    }

    public var failedChecks: [PreflightCheckResult] {
        results.filter(\.isFailed)
    }

    public var warningChecks: [PreflightCheckResult] {
        results.filter(\.isWarning)
    }

    public var passedChecks: [PreflightCheckResult] {
        results.filter(\.isPassed)
    }

    /// Extract a detail string from a specific check result.
    /// Useful for providers to query preflight results for detected values.
    public func detail(for checkID: PreflightCheckID) -> String? {
        for result in results where result.id == checkID {
            if case .passed(let detail) = result.status {
                return detail
            }
        }
        return nil
    }
}
