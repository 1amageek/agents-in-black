import AIBRuntimeCore
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

    public func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error> {
        var config = ClaudeCodeConfiguration()
        if let model {
            config.model = model
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
            config.mcpConfigPath = mcpPath
            config.additionalEnvironment["DISABLE_MCP_GLOBAL_CONFIG"] = "1"
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
                            continuation.yield(.sessionID(sys.sessionID))

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

                        case .assistant:
                            break

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
