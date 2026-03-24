import Foundation

/// Abstraction for executing agent conversations.
///
/// Two implementations:
/// - ``A2AAgentRunner``: sends messages via A2A HTTP/JSON-RPC (deployed or container agents).
/// - ``ClaudeCodeAgentRunner``: runs Claude Code CLI locally using subscription auth (no API cost).
public protocol AgentRunner: Sendable {
    func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error>
}

/// Context passed to the runner for each send.
public struct AgentRunnerContext: Sendable {
    public var serviceID: String
    /// Absolute path to `.mcp.json` for the agent's MCP connections.
    public var mcpConfigPath: String?
    /// Absolute path to the agent's execution directory (project root).
    public var executionDirectory: String?
    /// Absolute path to the staged skill overlay directory for this agent.
    /// Contains `.claude/`, `.agents/`, `skills/` subdirectories.
    public var skillOverlayPath: String?
    /// Conversation ID for multi-turn. Interpretation varies by runner.
    public var conversationID: String?

    public init(
        serviceID: String,
        mcpConfigPath: String? = nil,
        executionDirectory: String? = nil,
        skillOverlayPath: String? = nil,
        conversationID: String? = nil
    ) {
        self.serviceID = serviceID
        self.mcpConfigPath = mcpConfigPath
        self.executionDirectory = executionDirectory
        self.skillOverlayPath = skillOverlayPath
        self.conversationID = conversationID
    }
}

/// Events streamed from the runner during a send.
public enum AgentRunnerEvent: Sendable {
    /// Incremental text output from the assistant.
    case textDelta(String)
    /// Complete assistant response text.
    case textComplete(String)
    /// Tool use started (for display in UI).
    case toolUse(name: String)
    /// Session/conversation ID for multi-turn continuation.
    case sessionID(String)
    /// Execution metadata on completion.
    case done(AgentRunnerResult)
    /// Error during execution.
    case error(String)
}

/// Summary of a completed agent run.
public struct AgentRunnerResult: Sendable {
    public var conversationID: String?
    public var totalCostUSD: Double?
    public var durationMS: Int?
    public var numTurns: Int?

    public init(
        conversationID: String? = nil,
        totalCostUSD: Double? = nil,
        durationMS: Int? = nil,
        numTurns: Int? = nil
    ) {
        self.conversationID = conversationID
        self.totalCostUSD = totalCostUSD
        self.durationMS = durationMS
        self.numTurns = numTurns
    }
}
