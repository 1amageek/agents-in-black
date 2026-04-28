import AIBRuntimeCore
import ClaudeCode
import Foundation

/// Agent runner that executes Claude Code CLI locally using subscription auth.
///
/// No API key cost — uses the user's Claude Pro/Max subscription via OAuth.
/// MCP server connections are passed via `--mcp-config` flag or `.mcp.json` in the working directory.
public final class ClaudeCodeAgentRunner: AgentRunner, @unchecked Sendable {
    private let model: String?
    private var session: ClaudeCodeSession?

    public init(model: String? = nil) {
        self.model = model
    }

    // MARK: - AgentRunner metadata

    public static let displayName = "Claude Code"

    public static var isHostAvailable: Bool {
        ClaudeCodeConfiguration().isInstalled
    }

    /// Authentication status of the Claude Code CLI.
    ///
    /// Specific to runners that require interactive sign-in. Used by
    /// ``AIBEmulatorController`` to refuse start when agent services are
    /// configured but the CLI is not signed in via OAuth.
    public static func checkAuthStatus() async -> AgentRunnerAuthStatus {
        let raw = await ClaudeCodeConfiguration().checkAuthStatus()
        return AgentRunnerAuthStatus(
            loggedIn: raw.loggedIn,
            isOAuthAuthenticated: raw.isOAuthAuthenticated,
            authMethod: raw.authMethod
        )
    }

    public func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error> {
        var config = ClaudeCodeConfiguration()
        if let model {
            config.model = .custom(model)
        }
        if let execDir = context.executionDirectory {
            config.workingDirectory = URL(fileURLWithPath: execDir)
        }
        let effectivePluginRootPath = context.pluginRootPath
        let effectiveMCPConfigPath: String?
        if let explicitPath = context.mcpConfigPath {
            effectiveMCPConfigPath = explicitPath
        } else if let pluginRootPath = effectivePluginRootPath {
            effectiveMCPConfigPath = ClaudeCodePluginBundle.mcpConfigPath(pluginRootPath: pluginRootPath)
        } else {
            effectiveMCPConfigPath = nil
        }
        // Use AIB-generated MCP config exclusively.
        // Set DISABLE_MCP_GLOBAL_CONFIG to prevent inheriting user's global/project MCP servers.
        if let mcpPath = effectiveMCPConfigPath {
            config.mcpConfigPath = URL(fileURLWithPath: mcpPath)
            config.environment["DISABLE_MCP_GLOBAL_CONFIG"] = "1"
        }

        if let pluginRootPath = effectivePluginRootPath {
            config.pluginDirectories.append(URL(fileURLWithPath: pluginRootPath))
            config.additionalDirectories.append(URL(fileURLWithPath: pluginRootPath))
        } else if let skillPath = context.skillOverlayPath {
            config.additionalDirectories.append(URL(fileURLWithPath: skillPath))
        }

        // Reuse existing session for multi-turn, or create new one
        let codeSession: ClaudeCodeSession
        if let existing = session {
            codeSession = existing
        } else {
            codeSession = ClaudeCodeSession(configuration: config)
            session = codeSession
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var fullText = ""

                    for try await event in await codeSession.send(message) {
                        switch event {
                        case .system(let sys):
                            continuation.yield(.system(AgentRunnerSystemInfo(
                                sessionID: sys.sessionID,
                                model: sys.model,
                                tools: sys.tools,
                                mcpServerNames: sys.mcpServers.map(\.name),
                                mcpServerStatuses: sys.mcpServers.map(\.status),
                                permissionMode: sys.permissionMode
                            )))

                        case .systemStatus:
                            break

                        case .streamEvent(let delta):
                            switch delta.event {
                            case .textDelta(_, let text):
                                fullText += text
                                continuation.yield(.textDelta(text))
                            case .toolUseStart(_, _, let toolName):
                                continuation.yield(.toolUse(name: toolName))
                            default:
                                break
                            }

                        case .assistant(let msg):
                            for block in msg.content {
                                if case .toolUse(_, let name, let input) = block {
                                    continuation.yield(.toolUseComplete(name: name, input: input))
                                }
                            }

                        case .user(let msg):
                            for tr in msg.toolResults {
                                continuation.yield(.toolResult(toolUseID: tr.toolUseID, content: tr.content))
                            }

                        case .result(let res):
                            continuation.yield(.done(AgentRunnerResult(
                                conversationID: res.sessionID,
                                totalCostUSD: res.totalCostUSD,
                                durationMS: res.durationMS,
                                numTurns: res.numTurns
                            )))
                        }
                    }

                    if !fullText.isEmpty {
                        continuation.yield(.textComplete(fullText))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel() async {
        guard let session else { return }
        await session.cancel()
    }
}
