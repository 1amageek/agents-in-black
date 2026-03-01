import Foundation

/// A safe wrapper around `CheckedContinuation` that guarantees exactly-once resume.
///
/// `@MainActor` isolation eliminates the need for a Mutex — all access is serialized
/// on the main thread. Each deployment pipeline creates a fresh `ApprovalGate`,
/// so there is no stale state to worry about.
///
/// Usage:
/// ```
/// let gate = ApprovalGate()
/// let approved = await gate.wait()   // suspends
/// // later, from UI:
/// gate.approve()                     // resumes with true
/// // or:
/// gate.deny()                        // resumes with false
/// ```
@MainActor
final class ApprovalGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved: Bool = false

    init() {}

    /// Suspend until `approve()` or `deny()` is called.
    /// Returns `true` if approved, `false` if denied.
    func wait() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
        }
    }

    /// Resume the waiting pipeline with approval.
    /// No-op if already resolved (prevents double-resume crash).
    func approve() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: true)
        continuation = nil
    }

    /// Resume the waiting pipeline with denial/cancellation.
    /// No-op if already resolved (prevents double-resume crash).
    func deny() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: false)
        continuation = nil
    }
}
