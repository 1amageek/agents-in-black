import Foundation

/// Detects environment variables that are clearly intended for the local emulator
/// but live in the universal `env` bucket. Such entries leak into deploy targets
/// (e.g. `FIRESTORE_EMULATOR_HOST=host.container.internal:8080` reaching Cloud Run)
/// and silently break production by routing traffic to nonexistent emulators.
///
/// The same rule is consulted by the lint pass (warnings) and by the deploy
/// pipeline (hard block) so that one source-of-truth governs both surfaces.
public enum EnvScopeRule {
    /// A single suspicious entry detected in a service's universal env.
    public struct Violation: Sendable, Equatable {
        public let key: String
        public let value: String
        /// Human-readable reason — surfaced in lint warnings and deploy errors.
        public let reason: String
    }

    /// Inspect a flat env map and return every entry that should not be in the
    /// universal scope. Empty result means the map is safe to ship to deploy.
    public static func violations(in env: [String: String]) -> [Violation] {
        env
            .sorted { $0.key < $1.key }
            .compactMap { key, value in
                if let keyReason = suspiciousKeyReason(key) {
                    return Violation(key: key, value: value, reason: keyReason)
                }
                if let valueReason = suspiciousValueReason(value) {
                    return Violation(key: key, value: value, reason: valueReason)
                }
                return nil
            }
    }

    private static func suspiciousKeyReason(_ key: String) -> String? {
        let upper = key.uppercased()
        if upper.hasSuffix("_EMULATOR_HOST") || upper.hasSuffix("_EMULATOR") {
            return "key '\(key)' looks like a local emulator host (move to local_env)"
        }
        return nil
    }

    private static func suspiciousValueReason(_ value: String) -> String? {
        let lower = value.lowercased()
        let localOnlyHosts = [
            "host.container.internal",
            "host.docker.internal",
            "localhost:",
            "127.0.0.1:",
            "://localhost",
            "://127.0.0.1",
        ]
        for needle in localOnlyHosts where lower.contains(needle) {
            return "value points at a local-only host ('\(needle)') — move to local_env"
        }
        return nil
    }
}
