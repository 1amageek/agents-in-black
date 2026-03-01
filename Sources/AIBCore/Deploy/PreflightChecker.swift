import Foundation

/// Protocol for executing a single preflight check.
public protocol PreflightChecker: Sendable {
    var checkID: PreflightCheckID { get }
    var title: String { get }
    func run() async -> PreflightCheckResult
}
