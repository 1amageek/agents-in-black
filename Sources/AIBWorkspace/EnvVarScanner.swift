import Foundation

/// Classification of a detected environment variable reference.
public enum EnvVarKind: String, Sendable, Codable {
    /// Secret: contains KEY, SECRET, TOKEN, PASSWORD, CREDENTIAL, etc.
    case secret
    /// Automatic: managed by the runtime (PORT, NODE_ENV, K_SERVICE, etc.)
    case automatic
    /// Regular: user-defined, non-secret.
    case regular
}

/// A detected environment variable reference from source code.
public struct DetectedEnvVar: Sendable, Equatable, Hashable {
    public var name: String
    public var kind: EnvVarKind

    public init(name: String, kind: EnvVarKind) {
        self.name = name
        self.kind = kind
    }
}

/// Scans source code to detect environment variable references.
/// Per-runtime regex patterns extract variable names from common access patterns.
public enum EnvVarScanner {

    // MARK: - Public

    /// Scan a service's source directory for environment variable references.
    /// Returns deduplicated detected variables classified by kind.
    public static func scan(
        repoPath: String,
        workspaceRoot: String,
        runtime: RuntimeKind
    ) -> [DetectedEnvVar] {
        let repoURL = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent(repoPath)

        let patterns = regexPatterns(for: runtime)
        let extensions = fileExtensions(for: runtime)

        guard !patterns.isEmpty else { return [] }

        let sourceFiles = collectSourceFiles(at: repoURL, extensions: extensions)
        var names: Set<String> = []

        for fileURL in sourceFiles {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
                let range = NSRange(content.startIndex..., in: content)
                let matches = regex.matches(in: content, options: [], range: range)
                for match in matches {
                    if match.numberOfRanges > 1,
                       let captureRange = Range(match.range(at: 1), in: content)
                    {
                        let name = String(content[captureRange])
                        if isValidEnvVarName(name) {
                            names.insert(name)
                        }
                    }
                }
            }
        }

        return names.map { DetectedEnvVar(name: $0, kind: classify($0)) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Classification

    /// Classify an environment variable name by its likely purpose.
    public static func classify(_ name: String) -> EnvVarKind {
        let upper = name.uppercased()

        // Automatic: managed by the platform/runtime
        if automaticKeys.contains(upper) {
            return .automatic
        }

        // Secret: name suggests sensitive data
        for keyword in secretKeywords {
            if upper.contains(keyword) {
                return .secret
            }
        }

        return .regular
    }

    // MARK: - Private

    private static let secretKeywords: [String] = [
        "KEY", "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL",
        "API_KEY", "APIKEY", "PRIVATE", "AUTH",
    ]

    private static let automaticKeys: Set<String> = [
        "PORT", "HOST", "NODE_ENV", "K_SERVICE", "K_REVISION",
        "K_CONFIGURATION", "CLOUD_RUN_JOB", "CLOUD_RUN_EXECUTION",
        "CLOUD_RUN_TASK_INDEX", "CLOUD_RUN_TASK_COUNT",
        "HOME", "PATH", "USER", "SHELL", "LANG", "PWD", "HOSTNAME",
        "TERM", "TMPDIR", "TZ",
    ]

    /// Regex patterns per runtime to extract env var names.
    /// Each pattern must have a capture group (1) for the variable name.
    private static func regexPatterns(for runtime: RuntimeKind) -> [String] {
        switch runtime {
        case .node:
            return [
                // process.env.VAR_NAME or process.env["VAR_NAME"] or process.env['VAR_NAME']
                #"process\.env\.([A-Z_][A-Z0-9_]*)"#,
                #"process\.env\[['"]([A-Z_][A-Z0-9_]*)['"]\]"#,
                // Deno.env.get("VAR") pattern (sometimes used in Node-compatible code)
                #"env\.get\(['"]([A-Z_][A-Z0-9_]*)['"]\)"#,
            ]
        case .python:
            return [
                // os.environ["VAR"] or os.environ.get("VAR") or os.getenv("VAR")
                #"os\.environ\[['"]([A-Z_][A-Z0-9_]*)['"]\]"#,
                #"os\.environ\.get\(['"]([A-Z_][A-Z0-9_]*)['"]\)"#,
                #"os\.getenv\(['"]([A-Z_][A-Z0-9_]*)['"]\)"#,
            ]
        case .deno:
            return [
                // Deno.env.get("VAR")
                #"Deno\.env\.get\(['"]([A-Z_][A-Z0-9_]*)['"]\)"#,
            ]
        case .swift:
            return [
                // ProcessInfo.processInfo.environment["VAR"]
                #"environment\[['"]([A-Z_][A-Z0-9_]*)['"]\]"#,
            ]
        case .unknown:
            return []
        }
    }

    /// File extensions to scan per runtime.
    private static func fileExtensions(for runtime: RuntimeKind) -> Set<String> {
        switch runtime {
        case .node: return ["js", "ts", "mjs", "mts", "cjs", "cts", "jsx", "tsx"]
        case .python: return ["py"]
        case .deno: return ["ts", "js", "mts", "mjs"]
        case .swift: return ["swift"]
        case .unknown: return []
        }
    }

    /// Collect source files recursively, skipping common non-source directories.
    private static func collectSourceFiles(at directory: URL, extensions: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let skipDirs: Set<String> = [
            "node_modules", ".build", "dist", "build", "__pycache__",
            ".git", ".venv", "venv", ".tox", "coverage",
        ]

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let pathComponents = fileURL.pathComponents
            if pathComponents.contains(where: { skipDirs.contains($0) }) {
                continue
            }
            if extensions.contains(fileURL.pathExtension) {
                files.append(fileURL)
            }
        }
        return files
    }

    private static func isValidEnvVarName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256
    }
}
