import Foundation

/// Auto-resolves values for missing declared `SecretRef`s so the user does
/// not have to type them in the secretsInput phase.
///
/// Resolvers compose in a chain: the first one to return a non-nil
/// `ResolvedSecretValue` for a given secret name wins. A resolver that does
/// not know how to handle a name returns `nil` so the chain can fall through
/// to the next strategy (and ultimately to user input).
public protocol SecretValueResolver: Sendable {
    func resolveValue(
        secretName: String,
        plan: AIBDeployPlan
    ) async -> ResolvedSecretValue?
}

/// A successfully auto-resolved secret value.
public struct ResolvedSecretValue: Sendable {
    /// Raw secret content to upload to Secret Manager.
    public let value: String
    /// Human-readable source description for logs / UI ("~/.codex/auth.json",
    /// "Generated 32-byte hex", etc.).
    public let sourceDescription: String

    public init(value: String, sourceDescription: String) {
        self.value = value
        self.sourceDescription = sourceDescription
    }
}

/// Reads Codex ChatGPT auth from the local `~/.codex/auth.json`.
///
/// Only triggers for secrets backed by the codex auth mount path
/// (`/secrets/codex-auth.json`), matching how `AIBDeployService`
/// declares the SecretRef for `codex.auth.mode: chatgpt` agents. The
/// uploaded value is the raw file contents — same shape Codex CLI writes via
/// `codex login`, so deploys reuse the developer's existing authentication
/// without manual export.
public struct CodexAuthSecretValueResolver: SecretValueResolver {
    /// Mount path used by `AIBDeployService` when declaring the Codex auth
    /// SecretRef. Kept in sync with that single declaration site.
    public static let codexAuthMountPath = "/secrets/codex-auth.json"

    private let authFileURL: URL

    public init(authFileURL: URL? = nil) {
        self.authFileURL = authFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json", isDirectory: false)
    }

    public func resolveValue(
        secretName: String,
        plan: AIBDeployPlan
    ) async -> ResolvedSecretValue? {
        let isCodexAuth = plan.services.contains { service in
            service.declaredSecretRefs[Self.codexAuthMountPath]?.secret == secretName
        }
        guard isCodexAuth else { return nil }

        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: authFileURL)
        } catch {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return ResolvedSecretValue(
            value: value,
            sourceDescription: "~/.codex/auth.json"
        )
    }
}

/// Generates a 32-byte hex value for secret names that match the
/// "internally-issued signing/session/encryption" naming convention
/// (see `DeploySecretValueGenerator.canGenerate`).
///
/// Refuses externally-issued credential names (API_KEY, ACCESS_TOKEN, etc.)
/// — those must come from an external provider and cannot be invented.
public struct RandomHexSecretValueResolver: SecretValueResolver {
    public init() {}

    public func resolveValue(
        secretName: String,
        plan _: AIBDeployPlan
    ) async -> ResolvedSecretValue? {
        guard DeploySecretValueGenerator.canGenerate(name: secretName) else {
            return nil
        }
        return ResolvedSecretValue(
            value: DeploySecretValueGenerator.generateHexSecret(),
            sourceDescription: "Generated 32-byte hex"
        )
    }
}

/// Tries each child resolver in order, returning the first non-nil value.
public struct ChainedSecretValueResolver: SecretValueResolver {
    private let resolvers: [SecretValueResolver]

    public init(resolvers: [SecretValueResolver]) {
        self.resolvers = resolvers
    }

    public func resolveValue(
        secretName: String,
        plan: AIBDeployPlan
    ) async -> ResolvedSecretValue? {
        for resolver in resolvers {
            if let resolved = await resolver.resolveValue(secretName: secretName, plan: plan) {
                return resolved
            }
        }
        return nil
    }

    /// Default chain: codex auth file → random hex generator → user input.
    public static var `default`: ChainedSecretValueResolver {
        ChainedSecretValueResolver(resolvers: [
            CodexAuthSecretValueResolver(),
            RandomHexSecretValueResolver()
        ])
    }
}
