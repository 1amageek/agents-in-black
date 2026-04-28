import Foundation

/// Abstraction for executing agent conversations.
///
/// Two implementations:
/// - ``A2AAgentRunner``: sends messages via A2A HTTP/JSON-RPC (deployed or container agents).
/// - ``ClaudeCodeAgentRunner``: runs Claude Code CLI locally using subscription auth (no API cost).
public protocol AgentRunner: Sendable {
    /// Human-readable name shown in UI (e.g. "Claude Code", "A2A").
    static var displayName: String { get }

    /// Whether host-level prerequisites for this runner are satisfied.
    ///
    /// - Local CLI runners: whether the CLI executable is present on the host.
    /// - Remote runners (HTTP-based): always `true`. Endpoint reachability is
    ///   checked at send time, not as a precondition.
    static var isHostAvailable: Bool { get }

    func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error>
}

/// Context passed to the runner for each send.
public struct AgentRunnerContext: Sendable {
    public var serviceID: String
    /// Absolute path to the generated Claude Code plugin root for this agent.
    public var pluginRootPath: String?
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
        pluginRootPath: String? = nil,
        mcpConfigPath: String? = nil,
        executionDirectory: String? = nil,
        skillOverlayPath: String? = nil,
        conversationID: String? = nil
    ) {
        self.serviceID = serviceID
        self.pluginRootPath = pluginRootPath
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
    /// Complete tool use with input arguments.
    case toolUseComplete(name: String, input: String)
    /// Tool result data returned from a tool call.
    case toolResult(toolUseID: String, content: String)
    /// System info from the Claude Code session (session ID, model, tools, MCP servers).
    case system(AgentRunnerSystemInfo)
    /// Execution metadata on completion.
    case done(AgentRunnerResult)
    /// Error during execution.
    case error(String)
}

/// System-level information from the Claude Code session.
public struct AgentRunnerSystemInfo: Sendable {
    public var sessionID: String
    public var model: String
    public var tools: [String]
    public var mcpServerNames: [String]
    public var mcpServerStatuses: [String]
    public var permissionMode: String

    public init(
        sessionID: String,
        model: String = "",
        tools: [String] = [],
        mcpServerNames: [String] = [],
        mcpServerStatuses: [String] = [],
        permissionMode: String = ""
    ) {
        self.sessionID = sessionID
        self.model = model
        self.tools = tools
        self.mcpServerNames = mcpServerNames
        self.mcpServerStatuses = mcpServerStatuses
        self.permissionMode = permissionMode
    }
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
