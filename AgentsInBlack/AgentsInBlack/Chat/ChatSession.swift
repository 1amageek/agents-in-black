import AIBCore
import Foundation

/// A single chat conversation session with an agent service via A2A protocol.
///
/// Each instance manages one conversation against one A2A-compliant agent.
/// It is independent of `AgentsInBlackAppModel` and can be used in any context
/// (PiP panel, workbench, inspector, etc.).
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

    private let a2aClient: A2AClient
    private(set) var agentCard: A2AAgentCard?
    private var contextId: String?

    init(
        id: UUID = UUID(),
        serviceID: String,
        baseURL: URL,
        rpcPath: String = "/a2a",
        agentCard: A2AAgentCard? = nil,
        title: String = "New Chat"
    ) {
        self.id = id
        self.serviceID = serviceID
        self.createdAt = Date()
        self.title = title
        self.a2aClient = A2AClient(baseURL: baseURL, rpcPath: rpcPath)
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

        defer { isSending = false }

        let startedAt = Date()
        do {
            let result = try await a2aClient.sendMessage(text: text, contextId: contextId)
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)

            // Maintain conversation context
            if let newContextId = result.contextId {
                contextId = newContextId
            }

            appendMessage(
                .assistant(result.responseText),
                latencyMs: latency,
                rawResponseBody: result.rawResponseBody
            )
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
        contextId = nil
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
