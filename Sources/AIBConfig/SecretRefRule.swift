import Foundation

/// Catches structural problems in a service's `secrets:` map (declared
/// SecretRefs) before they reach the deploy pipeline. Same source-of-truth
/// pattern as `EnvScopeRule`: warnings here are surfaced at lint time,
/// errors block deploy.
///
/// Rule IDs match the spec:
/// - **S001**: empty `secret` name in a SecretRef
/// - **S002**: env-var-style key (the dict key) violates POSIX naming
/// - **S003**: backing `secret` name violates Secret Manager naming
/// - **S004**: same key declared in both `secrets` and one of
///   `env` / `local_env` / `deploy_env` (ambiguous mount source)
public enum SecretRefRule {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    public struct Violation: Sendable, Equatable {
        public let ruleID: String
        public let severity: Severity
        public let key: String
        public let reason: String
    }

    /// Inspect a service's secrets map (paired with its env maps for the
    /// collision rule) and return every violation.
    public static func violations(
        secrets: [String: SecretRef],
        env: [String: String],
        localEnv: [String: String],
        deployEnv: [String: String]
    ) -> [Violation] {
        var out: [Violation] = []

        for (key, ref) in secrets.sorted(by: { $0.key < $1.key }) {
            // S001: secret name must not be empty/whitespace.
            let trimmedSecret = ref.secret.trimmingCharacters(in: .whitespaces)
            if trimmedSecret.isEmpty {
                out.append(Violation(
                    ruleID: "S001",
                    severity: .error,
                    key: key,
                    reason: "secret name is empty — SecretRef points nowhere"
                ))
            }

            // S002: env-var-style key must follow POSIX shell conventions
            // ([A-Za-z_][A-Za-z0-9_]*) so deploy targets accept it. We warn
            // rather than error so existing services aren't broken by a
            // stricter check later.
            if !isValidEnvKey(key) {
                out.append(Violation(
                    ruleID: "S002",
                    severity: .warning,
                    key: key,
                    reason: "key '\(key)' is not a valid env var name (expected [A-Za-z_][A-Za-z0-9_]*)"
                ))
            }

            // S003: Secret Manager allows letters, digits, underscores, and
            // hyphens; max 255 chars. Empty is already covered by S001.
            if !trimmedSecret.isEmpty, !isValidSecretManagerName(trimmedSecret) {
                out.append(Violation(
                    ruleID: "S003",
                    severity: .error,
                    key: key,
                    reason: "secret name '\(ref.secret)' is invalid (allowed: letters, digits, '_', '-'; max 255 chars)"
                ))
            }

            // S004: collision with an env-map entry on the same key produces
            // ambiguous mount semantics. Flag it as an error so the user
            // chooses one source of truth.
            let collisions = collidingEnvMaps(
                key: key,
                env: env,
                localEnv: localEnv,
                deployEnv: deployEnv
            )
            if !collisions.isEmpty {
                out.append(Violation(
                    ruleID: "S004",
                    severity: .error,
                    key: key,
                    reason: "key '\(key)' is also declared in \(collisions.joined(separator: ", "))"
                        + " — declare it in only one of secrets/env/local_env/deploy_env"
                ))
            }
        }

        return out
    }

    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        for ch in key.dropFirst() {
            guard ch.isLetter || ch.isNumber || ch == "_" else { return false }
        }
        return true
    }

    private static func isValidSecretManagerName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        for ch in name {
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "-" else { return false }
        }
        return true
    }

    private static func collidingEnvMaps(
        key: String,
        env: [String: String],
        localEnv: [String: String],
        deployEnv: [String: String]
    ) -> [String] {
        var out: [String] = []
        if env[key] != nil { out.append("env") }
        if localEnv[key] != nil { out.append("local_env") }
        if deployEnv[key] != nil { out.append("deploy_env") }
        return out
    }
}
