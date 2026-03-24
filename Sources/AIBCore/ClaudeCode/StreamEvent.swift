import Foundation

// MARK: - Top-Level Envelope

/// A single line from Claude Code's `--output-format stream-json` stdout.
public enum StreamEvent: Sendable {
    case system(SystemEvent)
    case streamEvent(StreamDelta)
    case assistant(AssistantMessage)
    case result(ResultEvent)
}

// MARK: - System Init

public struct SystemEvent: Sendable {
    public var sessionID: String
    public var cwd: String
    public var model: String
    public var tools: [String]
    public var mcpServers: [MCPServerStatus]
    public var permissionMode: String
}

public struct MCPServerStatus: Sendable {
    public var name: String
    public var status: String
}

// MARK: - Stream Delta

public struct StreamDelta: Sendable {
    public var sessionID: String
    public var parentToolUseID: String?
    public var event: DeltaEvent
}

public enum DeltaEvent: Sendable {
    case messageStart
    case contentBlockStart(index: Int)
    case toolUseStart(index: Int, toolID: String, toolName: String)
    case textDelta(index: Int, text: String)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
}

// MARK: - Assistant Message

public struct AssistantMessage: Sendable {
    public var sessionID: String
    public var messageID: String
    public var model: String
    public var content: [ContentBlock]
    public var parentToolUseID: String?
}

public enum ContentBlock: Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: String)
}

// MARK: - Result

public struct ResultEvent: Sendable {
    public var sessionID: String
    public var result: String
    public var isError: Bool
    public var stopReason: String
    public var totalCostUSD: Double
    public var durationMS: Int
    public var numTurns: Int
}
