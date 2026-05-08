import Foundation

/// Resolves a SecretRef to a plaintext value at local-emulator boot time.
///
/// Three concrete strategies live in this file: env-passthrough, local-file,
/// and gcloud-fetch. They are stacked into `ChainedLocalSecretResolver` and
/// consulted in order — the first non-nil result wins, which lets users pick
/// the strategy that matches their environment without rewiring code.
public protocol LocalSecretResolver: Sendable {
    /// Returns the resolved value, or nil if this resolver cannot serve the
    /// request. Throwing should be reserved for hard failures (e.g. malformed
    /// state file); a missing entry must not throw because later resolvers in
    /// the chain may still satisfy it.
    func resolve(secretName: String) async -> String?
}

// MARK: - Chain

/// Tries each resolver in order until one returns a value.
public struct ChainedLocalSecretResolver: LocalSecretResolver {
    private let resolvers: [any LocalSecretResolver]

    public init(_ resolvers: [any LocalSecretResolver]) {
        self.resolvers = resolvers
    }

    public func resolve(secretName: String) async -> String? {
        for resolver in resolvers {
            if let value = await resolver.resolve(secretName: secretName) {
                return value
            }
        }
        return nil
    }
}

// MARK: - Env passthrough

/// Reads from the current process's environment under `AIB_SECRET_<NAME>`,
/// where `<NAME>` is the secret name uppercased with hyphens converted to
/// underscores (Secret Manager allows hyphens; POSIX env vars don't).
///
/// Example: `gcloud secrets create openai-prod` → `AIB_SECRET_OPENAI_PROD`.
public struct EnvPassthroughSecretResolver: LocalSecretResolver {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolve(secretName: String) async -> String? {
        let normalized = secretName
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        let key = "AIB_SECRET_\(normalized)"
        return environment[key]
    }
}

// MARK: - Local file

/// Reads from `.aib/secrets.local.yaml` (gitignored). Two formats supported
/// per entry — flat string for the common case, or an object when the user
/// wants to record a version alongside the value:
///
/// ```yaml
/// openai-prod: "sk-abc123"
/// stripe-test:
///   value: "sk_test_xyz"
///   version: "2"
/// ```
///
/// This resolver ignores version pins — local always uses whichever value is
/// in the file. Version pinning is a deploy-time concern, not a local one.
public struct LocalFileSecretResolver: LocalSecretResolver {
    private let valuesByName: [String: String]

    public init(valuesByName: [String: String]) {
        self.valuesByName = valuesByName
    }

    /// Loads the file from `.aib/secrets.local.yaml` under `workspaceRoot`.
    /// Returns a resolver with no entries when the file is absent — secrets
    /// are optional locally, so missing-file is not an error here.
    public static func load(workspaceRoot: String) throws -> LocalFileSecretResolver {
        let path = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(".aib")
            .appendingPathComponent("secrets.local.yaml")
            .path
        guard FileManager.default.fileExists(atPath: path) else {
            return LocalFileSecretResolver(valuesByName: [:])
        }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let parsed = try Self.parse(raw)
        return LocalFileSecretResolver(valuesByName: parsed)
    }

    public func resolve(secretName: String) async -> String? {
        valuesByName[secretName]
    }

    /// Minimal YAML-ish parser tailored to this file's narrow shape — we only
    /// support flat `key: "value"` and the nested form with `value:` /
    /// `version:`. Pulling in a full YAML codec just for this would be
    /// overkill, and the file is human-edited so the syntax stays simple.
    static func parse(_ raw: String) throws -> [String: String] {
        var out: [String: String] = [:]
        var pendingKey: String?
        var pendingValue: String?

        let lines = raw.components(separatedBy: "\n")
        for rawLine in lines {
            let stripped = stripComment(rawLine)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Top-level entries are unindented.
            if !stripped.first!.isWhitespace {
                if let key = pendingKey, let value = pendingValue {
                    out[key] = value
                }
                pendingKey = nil
                pendingValue = nil

                guard let colonIndex = stripped.firstIndex(of: ":") else {
                    throw LocalSecretFileError(
                        message: "Invalid line in secrets.local.yaml: '\(stripped)' (expected '<name>: <value>')"
                    )
                }
                let key = String(stripped[..<colonIndex])
                    .trimmingCharacters(in: .whitespaces)
                let valuePart = String(stripped[stripped.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)

                if valuePart.isEmpty {
                    // Nested form follows on subsequent indented lines.
                    pendingKey = key
                    pendingValue = nil
                } else {
                    out[key] = unquote(valuePart)
                }
                continue
            }

            // Indented line — must belong to a pending nested entry.
            guard let key = pendingKey else {
                throw LocalSecretFileError(
                    message: "Indented line without parent in secrets.local.yaml: '\(stripped)'"
                )
            }
            let inner = stripped.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = inner.firstIndex(of: ":") else {
                throw LocalSecretFileError(
                    message: "Invalid nested line under '\(key)': '\(inner)'"
                )
            }
            let field = String(inner[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = unquote(
                String(inner[inner.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
            )
            if field == "value" {
                pendingValue = value
                out[key] = value
            }
            // version: lines are accepted but ignored — local mode uses
            // whatever value is in the file, see doc comment above.
        }

        if let key = pendingKey, let value = pendingValue, out[key] == nil {
            out[key] = value
        }

        return out
    }

    private static func stripComment(_ line: String) -> String {
        // Comments only count when `#` is at line start or follows whitespace.
        // A `#` inside a quoted value is left alone.
        var inSingle = false
        var inDouble = false
        var prev: Character = " "
        var endIndex = line.endIndex
        for index in line.indices {
            let ch = line[index]
            if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inSingle && !inDouble && (prev.isWhitespace || index == line.startIndex) {
                endIndex = index
                break
            }
            prev = ch
        }
        return String(line[..<endIndex])
    }

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first!
        let last = raw.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}

public struct LocalSecretFileError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

// MARK: - gcloud fetch

/// Shells out to `gcloud secrets versions access latest --secret=<name>` so
/// users authenticated to GCP can resolve secrets without copying values
/// into a local file. Uses whichever project gcloud has active (`gcloud
/// config get-value project`) — matches the UX users expect from gcloud.
///
/// Returns nil on any failure (gcloud missing, auth expired, secret not
/// found) so the chain falls through to other resolvers cleanly. Network
/// I/O makes this resolver the most expensive, so place it last in the
/// chain.
public struct GcloudSecretResolver: LocalSecretResolver {
    public init() {}

    public func resolve(secretName: String) async -> String? {
        // Quote the secret name so spaces / special chars can't escape into
        // the shell, even though Secret Manager naming forbids them. Cheap
        // safety belt that costs nothing at the call site.
        let quoted = "'" + secretName.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "gcloud secrets versions access latest --secret=\(quoted) --quiet"

        let result: ShellProbe.Result
        do {
            result = try await ShellProbe.run(command: command, timeout: .seconds(15))
        } catch {
            return nil
        }
        guard result.exitCode == 0 else { return nil }
        // gcloud sometimes appends a trailing newline; values themselves can
        // legitimately contain whitespace, so trim only the trailing one.
        var value = result.stdout
        if value.hasSuffix("\n") { value.removeLast() }
        return value.isEmpty ? nil : value
    }
}
