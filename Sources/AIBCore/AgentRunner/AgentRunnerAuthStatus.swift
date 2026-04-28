import Foundation

/// Authentication status for a runner that requires sign-in (e.g. Claude Code OAuth).
///
/// AIBCore-owned translation of runner-specific auth status types so callers
/// (CLI, App) do not depend on the underlying SDK's auth status type.
public struct AgentRunnerAuthStatus: Sendable {
    public let loggedIn: Bool
    public let isOAuthAuthenticated: Bool
    public let authMethod: String?

    public init(loggedIn: Bool, isOAuthAuthenticated: Bool, authMethod: String?) {
        self.loggedIn = loggedIn
        self.isOAuthAuthenticated = isOAuthAuthenticated
        self.authMethod = authMethod
    }
}
