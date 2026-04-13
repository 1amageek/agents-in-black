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

        logHandler?("[claude] send prompt (\(text.count) chars)\n")

        let stream = runner.send(message: text, context: runnerContext)
        let startedAt = Date()

        do {
            try await consumeStream(stream, startedAt: startedAt)
        } catch {
            appendMessage(.error(error.localizedDescription))
        }

        isSending = false
        streamingText = nil
    }

    /// Iterate the runner stream off MainActor, dispatching UI updates individually.
    /// This prevents the stream processing loop from monopolizing the main thread.
    nonisolated private func consumeStream(
        _ stream: AsyncThrowingStream<AgentRunnerEvent, Error>,
        startedAt: Date
    ) async throws {
        var completeText: String?

        for try await event in stream {
            switch event {
            case .textDelta(let delta):
                await appendStreamingText(delta)

            case .textComplete(let fullText):
                completeText = fullText

            case .toolUse(let name):
                let log = "[claude] tool_use: \(name)\n"
                await emitLogAndAppendInfo(log: log, info: "Using tool: \(name)")

            case .toolUseComplete(let name, let input):
                let log = "[claude] tool_call: \(name) input=\(input.prefix(500))\n"
                await emitLog(log)

            case .toolResult(let toolUseID, let content):
                let log = "[claude] tool_response: id=\(toolUseID.prefix(12)) chars=\(content.count)\n\(String(content.prefix(1000)))\n"
                await emitLog(log)

            case .system(let info):
                let mcpStatus = zip(info.mcpServerNames, info.mcpServerStatuses)
                    .map { "\($0)=\($1)" }.joined(separator: ", ")
                let log = "[claude] system session=\(info.sessionID.prefix(8)) model=\(info.model) tools=\(info.tools.count) mcp=[\(mcpStatus)] mode=\(info.permissionMode)\n"
                await emitLogAndSetConversationID(log: log, conversationID: info.sessionID)

            case .done(let result):
                let cost = result.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "-"
                let turns = result.numTurns.map { "\($0)" } ?? "-"
                let duration = result.durationMS.map { "\($0)ms" } ?? "-"
                let log = "[claude] done turns=\(turns) cost=\(cost) duration=\(duration)\n"
                await emitLog(log)
                if let cid = result.conversationID {
                    await setConversationID(cid)
                }

            case .error(let message):
                let log = "[claude] error: \(message)\n"
                await emitLogAndAppendError(log: log, message: message)
            }
        }

        let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
        await finalizeResponse(completeText: completeText, latencyMs: latency)
    }

    // MARK: - Stream Event Handlers

    private func appendStreamingText(_ delta: String) {
        streamingText = (streamingText ?? "") + delta
    }

    private func emitLog(_ line: String) {
        logHandler?(line)
    }

    private func emitLogAndAppendInfo(log: String, info: String) {
        logHandler?(log)
        appendMessage(.info(info))
    }

    private func emitLogAndSetConversationID(log: String, conversationID: String) {
        logHandler?(log)
        runnerContext.conversationID = conversationID
    }

    private func setConversationID(_ id: String) {
        runnerContext.conversationID = id
    }

    private func emitLogAndAppendError(log: String, message: String) {
        logHandler?(log)
        appendMessage(.error(message))
    }

    private func finalizeResponse(completeText: String?, latencyMs: Int) {
        let responseText = completeText ?? streamingText ?? ""
        if !responseText.isEmpty {
            appendMessage(.assistant(responseText), latencyMs: latencyMs)
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
