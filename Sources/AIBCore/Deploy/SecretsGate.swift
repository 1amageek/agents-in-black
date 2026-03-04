import Foundation

/// A gate that blocks the deploy pipeline until the user provides secret values.
///
/// Similar to `ApprovalGate` but carries a `[String: String]` payload (secret name → value).
/// The pipeline suspends at `wait()` and resumes when the user calls `provide(secrets:)` or `cancel()`.
@MainActor
final class SecretsGate {
    private var continuation: CheckedContinuation<[String: String]?, Never>?
    private var resolved: Bool = false

    init() {}

    /// Suspend until `provide(secrets:)` or `cancel()` is called.
    /// Returns the provided secrets dictionary, or nil if cancelled.
    func wait() async -> [String: String]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: String]?, Never>) in
            self.continuation = cont
        }
    }

    /// Resume the pipeline with the provided secret values.
    func provide(secrets: [String: String]) {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: secrets)
        continuation = nil
    }

    /// Cancel — resume the pipeline with nil.
    func cancel() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
