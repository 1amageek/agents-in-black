import Foundation
import os.log

private let logger = Logger(subsystem: "com.aib.ClaudeCode", category: "Configuration")

/// Configuration for spawning a Claude Code CLI process.
public struct ClaudeCodeConfiguration: Sendable {

    /// Path to the `claude` executable. Defaults to the standard install location.
    public var executablePath: String

    /// Working directory for the Claude session.
    public var workingDirectory: URL?

    /// Model override (e.g. "sonnet", "opus", "claude-sonnet-4-6").
    public var model: String?

    /// Tools to auto-approve without prompting.
    public var allowedTools: [String]

    /// Maximum agentic turns per invocation.
    public var maxTurns: Int?

    /// System prompt override.
    public var systemPrompt: String?

    /// Additional system prompt appended to the default.
    public var appendSystemPrompt: String?

    /// Permission mode (e.g. "default", "acceptEdits", "plan").
    public var permissionMode: String?

    /// Additional directories to allow tool access to (passed as --add-dir).
    public var additionalDirectories: [URL]

    /// Plugin roots to load for this session (passed as --plugin-dir).
    /// Each path must point to a directory containing `.claude-plugin/plugin.json`.
    public var pluginDirectories: [URL]

    /// Additional CLI flags passed verbatim.
    public var additionalFlags: [String]

    /// Isolated MCP config path. When set, only this file is used for MCP servers.
    /// Prevents Claude Code from inheriting global/project MCP configurations.
    public var mcpConfigPath: String?

    /// Additional environment variables to set on the CLI process.
    public var additionalEnvironment: [String: String]

    public init(
        executablePath: String? = nil,
        workingDirectory: URL? = nil,
        model: String? = nil,
        allowedTools: [String] = [],
        maxTurns: Int? = nil,
        systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil,
        permissionMode: String? = nil,
        dangerouslySkipPermissions: Bool = true,
        additionalDirectories: [URL] = [],
        pluginDirectories: [URL] = [],
        additionalFlags: [String] = [],
        mcpConfigPath: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        self.executablePath = executablePath ?? Self.defaultExecutablePath
        self.workingDirectory = workingDirectory
        self.model = model
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.appendSystemPrompt = appendSystemPrompt
        self.permissionMode = permissionMode
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.additionalDirectories = additionalDirectories
        self.pluginDirectories = pluginDirectories
        self.additionalFlags = additionalFlags
        self.mcpConfigPath = mcpConfigPath
        self.additionalEnvironment = additionalEnvironment
    }

    /// Skip all permission checks (tools run without approval).
    public var dangerouslySkipPermissions: Bool

    /// The user's login shell.
    static let loginShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    /// Builds the CLI arguments for a single prompt invocation.
    func arguments(prompt: String, resumeSessionID: String? = nil) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]

        if dangerouslySkipPermissions {
            args += ["--dangerously-skip-permissions"]
        }

        if let sessionID = resumeSessionID {
            args += ["--resume", sessionID]
        }

        if let model {
            args += ["--model", model]
        }

        if !allowedTools.isEmpty {
            args += ["--allowedTools"] + allowedTools
        }

        if let maxTurns {
            args += ["--max-turns", String(maxTurns)]
        }

        if let systemPrompt {
            args += ["--system-prompt", systemPrompt]
        }

        if let appendSystemPrompt {
            args += ["--append-system-prompt", appendSystemPrompt]
        }

        if let permissionMode {
            args += ["--permission-mode", permissionMode]
        }

        if let mcpConfigPath {
            args += ["--mcp-config", mcpConfigPath]
        }

        if !additionalDirectories.isEmpty {
            args += ["--add-dir"] + additionalDirectories.map(\.path)
        }

        for pluginDirectory in pluginDirectories {
            args += ["--plugin-dir", pluginDirectory.path]
        }

        args += additionalFlags

        return args
    }

    /// Build a shell command string that launches claude via login shell.
    /// This reproduces the same environment as Terminal.app.
    func shellCommand(prompt: String, resumeSessionID: String? = nil) -> String {
        let args = arguments(prompt: prompt, resumeSessionID: resumeSessionID)
        let escaped = args.map { shellEscape($0) }
        // unset Claude nesting vars, then exec claude
        return "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT; exec \(shellEscape(executablePath)) \(escaped.joined(separator: " "))"
    }

    /// Shell-escape a string using single quotes.
    private func shellEscape(_ value: String) -> String {
        // Wrap in single quotes; escape internal single quotes as '\''
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Default Path

    private static var defaultExecutablePath: String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "claude"
    }

    // MARK: - Status

    /// Whether the claude executable exists at the configured path.
    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Allowed OAuth-based auth methods. API key auth is rejected.
    private static let allowedAuthMethods: Set<String> = ["claude.ai"]

    /// Auth status returned by `claude auth status`.
    public struct AuthStatus: Sendable {
        public let loggedIn: Bool
        public let authMethod: String?

        /// Whether the auth method is OAuth-based (not API key).
        public var isOAuthAuthenticated: Bool {
            loggedIn && authMethod.map { ClaudeCodeConfiguration.allowedAuthMethods.contains($0) } ?? false
        }
    }

    /// Check login status by running `claude auth status --json`.
    ///
    /// API key env vars are stripped from the subprocess environment so the
    /// status reflects OAuth authentication only.
    public func checkAuthStatus() async -> AuthStatus {
        logger.info("[auth] checkAuthStatus: executable=\(executablePath, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["auth", "status", "--json"]

        // Strip API key env vars to check OAuth-only status.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let status = process.terminationStatus
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let rawOutput = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let rawError = String(data: errData, encoding: .utf8) ?? ""

            logger.info("[auth] exit=\(status) stdout=\(rawOutput, privacy: .public)")
            if !rawError.isEmpty {
                logger.warning("[auth] stderr=\(rawError, privacy: .public)")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("[auth] Failed to parse JSON from stdout")
                return AuthStatus(loggedIn: false, authMethod: nil)
            }

            let loggedIn = json["loggedIn"] as? Bool ?? false
            let authMethod = json["authMethod"] as? String
            logger.info("[auth] loggedIn=\(loggedIn) authMethod=\(authMethod ?? "nil", privacy: .public)")

            return AuthStatus(loggedIn: loggedIn, authMethod: authMethod)
        } catch {
            logger.error("[auth] Process launch failed: \(error.localizedDescription, privacy: .public)")
            return AuthStatus(loggedIn: false, authMethod: nil)
        }
    }
}
