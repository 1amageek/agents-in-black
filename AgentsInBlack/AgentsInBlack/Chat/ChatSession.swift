import AIBCore
import Foundation

/// A single chat conversation session with an agent service.
///
/// Supports two execution modes:
/// - **A2A**: sends messages via HTTP/JSON-RPC to a running agent container or deployed service.
/// - **Claude Code**: runs Claude Code CLI locally using subscription auth (no API cost).
///
/// The mode is determined by the `AgentRunner` injected at creation time.
@MainActor
@Observable
final class ChatSession: Identifiable {
    let id: UUID
    let serviceID: String
    let createdAt: Date
    private(set) var title: String

    private(set) var messages: [ChatMessageItem] = []
    var composerText: String = ""
    private(set) var isSending: Bool = false
    var selectedMessageID: UUID?

    private let runner: any AgentRunner
    private var runnerContext: AgentRunnerContext
    private(set) var agentCard: A2AAgentCard?

    /// Callback to emit log lines to the service log panel.
    var logHandler: ((String) -> Void)?

    /// Streaming text buffer for the current assistant response.
    private(set) var streamingText: String?

    init(
        id: UUID = UUID(),
        serviceID: String,
        runner: any AgentRunner,
        context: AgentRunnerContext,
        agentCard: A2AAgentCard? = nil,
        title: String = "New Chat"
    ) {
        self.id = id
        self.serviceID = serviceID
        self.createdAt = Date()
        self.title = title
        self.runner = runner
        self.runnerContext = context
        self.agentCard = agentCard
    }

    // MARK: - Public

    func updateAgentCard(_ card: A2AAgentCard) {
        agentCard = card
    }

    func updateTitle(_ newTitle: String) {
        title = newTitle
    }

    func send() async {
        guard !isSending else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        appendMessage(.user(text))
        composerText = ""
        isSending = true
        streamingText = ""

        defer {
            isSending = false
            streamingText = nil
        }

        let startedAt = Date()
        var completeText: String?

        do {
            logHandler?("[claude] send prompt (\(text.count) chars)\n")
            for try await event in runner.send(message: text, context: runnerContext) {
                switch event {
                case .textDelta(let delta):
                    streamingText = (streamingText ?? "") + delta

                case .textComplete(let fullText):
                    completeText = fullText

                case .toolUse(let name):
                    logHandler?("[claude] tool_use: \(name)\n")
                    appendMessage(.info("Using tool: \(name)"))

                case .toolUseComplete(let name, let input):
                    logHandler?("[claude] tool_call: \(name) input=\(input.prefix(500))\n")

                case .toolResult(let toolUseID, let content):
                    logHandler?("[claude] tool_response: id=\(toolUseID.prefix(12)) chars=\(content.count)\n\(content.prefix(1000))\n")

                case .system(let info):
                    let mcpStatus = zip(info.mcpServerNames, info.mcpServerStatuses)
                        .map { "\($0)=\($1)" }.joined(separator: ", ")
                    logHandler?("[claude] system session=\(info.sessionID.prefix(8)) model=\(info.model) tools=\(info.tools.count) mcp=[\(mcpStatus)] mode=\(info.permissionMode)\n")
                    runnerContext.conversationID = info.sessionID

                case .done(let result):
                    let cost = result.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "-"
                    let turns = result.numTurns.map { "\($0)" } ?? "-"
                    let duration = result.durationMS.map { "\($0)ms" } ?? "-"
                    logHandler?("[claude] done turns=\(turns) cost=\(cost) duration=\(duration)\n")
                    if let cid = result.conversationID {
                        runnerContext.conversationID = cid
                    }

                case .error(let message):
                    logHandler?("[claude] error: \(message)\n")
                    appendMessage(.error(message))
                }
            }

            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            let responseText = completeText ?? streamingText ?? ""
            if !responseText.isEmpty {
                appendMessage(.assistant(responseText), latencyMs: latency)
            }
        } catch {
            appendMessage(.error(error.localizedDescription))
        }
    }

    /// Show the user's message followed by a guidance info message (no network request).
    func appendGuide(userText: String, message: String) {
        appendMessage(.user(userText))
        appendMessage(.info(message))
    }

    func reset() {
        messages = []
        composerText = ""
        isSending = false
        selectedMessageID = nil
        runnerContext.conversationID = nil
        streamingText = nil
    }

    // MARK: - Selection

    func selectMessage(_ id: UUID?) {
        selectedMessageID = (selectedMessageID == id) ? nil : id
    }

    var selectedMessage: ChatMessageItem? {
        guard let id = selectedMessageID else { return nil }
        return messages.first(where: { $0.id == id })
    }

    // MARK: - Session Metadata

    var lastMessageAt: Date? {
        messages.last?.timestamp
    }

    // MARK: - Internal

    private func appendMessage(
        _ kind: ChatMessageKind,
        latencyMs: Int? = nil,
        statusCode: Int? = nil,
        requestID: String? = nil,
        rawResponseBody: String? = nil
    ) {
        messages.append(
            ChatMessageItem(
                role: kind.defaultRole,
                text: kind.text,
                timestamp: Date(),
                latencyMs: latencyMs,
                statusCode: statusCode,
                requestID: requestID,
                kind: kind,
                rawResponseBody: rawResponseBody
            )
        )
        deriveTitleIfNeeded()
    }

    private func deriveTitleIfNeeded() {
        guard title == "New Chat" else { return }
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else { return }
        let truncated = String(firstUserMessage.text.prefix(40))
        title = truncated.count < firstUserMessage.text.count ? truncated + "..." : truncated
    }
}
