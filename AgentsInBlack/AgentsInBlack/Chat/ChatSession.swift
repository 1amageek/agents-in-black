import Foundation

/// A single chat conversation session with an agent service.
///
/// Each instance manages one conversation against one HTTP endpoint.
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

    private(set) var endpoint: ChatEndpoint

    init(id: UUID = UUID(), serviceID: String, endpoint: ChatEndpoint, title: String = "New Chat") {
        self.id = id
        self.serviceID = serviceID
        self.createdAt = Date()
        self.title = title
        self.endpoint = endpoint
    }

    // MARK: - Public

    func updateEndpoint(_ newEndpoint: ChatEndpoint) {
        guard endpoint != newEndpoint else { return }
        endpoint = newEndpoint
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

        guard let url = endpoint.resolvedURL else {
            appendMessage(.error("Invalid chat URL: \(endpoint.baseURL.absoluteString)\(endpoint.path)"))
            return
        }

        var payload: [String: Any] = [:]
        do {
            try Self.setJSONValue(text, path: endpoint.requestMessageJSONPath, in: &payload)
        } catch {
            appendMessage(.error("Invalid request_message_json_path: \(error.localizedDescription)"))
            return
        }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            appendMessage(.error("Failed to encode chat payload: \(error.localizedDescription)"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.httpBody = bodyData
        request.setValue(endpoint.requestContentType, forHTTPHeaderField: "Content-Type")

        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                appendMessage(.error("Invalid HTTP response"))
                return
            }
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            let requestID = httpResponse.value(forHTTPHeaderField: "X-Request-Id")
            let rawBody = String(data: data, encoding: .utf8)
            let responseJSON = try Self.decodeJSONObject(from: data)
            let message = try Self.extractJSONString(path: endpoint.responseMessageJSONPath, from: responseJSON)
            appendMessage(
                .assistant(message),
                latencyMs: latency,
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                rawResponseBody: rawBody
            )
        } catch {
            appendMessage(.error(error.localizedDescription))
        }
    }

    func reset() {
        messages = []
        composerText = ""
        isSending = false
        selectedMessageID = nil
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

    // MARK: - JSON Helpers

    private static func setJSONValue(_ value: String, path: String, in object: inout [String: Any]) throws {
        let components = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw ChatSessionError.emptyPath
        }
        try setJSONValue(value, components: components[...], in: &object)
    }

    private static func setJSONValue(_ value: String, components: ArraySlice<String>, in object: inout [String: Any]) throws {
        guard let head = components.first else { return }
        if components.count == 1 {
            object[head] = value
            return
        }
        var nested = object[head] as? [String: Any] ?? [:]
        try setJSONValue(value, components: components.dropFirst(), in: &nested)
        object[head] = nested
    }

    private static func decodeJSONObject(from data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = json as? [String: Any] else {
            throw ChatSessionError.nonObjectResponse
        }
        return object
    }

    private static func extractJSONString(path: String, from object: [String: Any]) throws -> String {
        let components = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw ChatSessionError.emptyPath
        }
        var current: Any = object
        for key in components {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                throw ChatSessionError.missingKey(key)
            }
            current = next
        }
        guard let text = current as? String else {
            throw ChatSessionError.nonStringValue(path)
        }
        return text
    }
}

// MARK: - Errors

enum ChatSessionError: LocalizedError {
    case emptyPath
    case nonObjectResponse
    case missingKey(String)
    case nonStringValue(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "JSON path must not be empty."
        case .nonObjectResponse:
            return "Chat response must be a JSON object."
        case .missingKey(let key):
            return "Response JSON is missing key: \(key)"
        case .nonStringValue(let path):
            return "Response value at path '\(path)' is not a string."
        }
    }
}
