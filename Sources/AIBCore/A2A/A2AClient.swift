import Foundation

/// HTTP client for the A2A (Agent-to-Agent) protocol.
///
/// Communicates with A2A-compliant agents via JSON-RPC 2.0 over HTTP.
/// Thread-safe and `Sendable` — create one per agent service.
public final class A2AClient: Sendable {
    private let baseURL: URL
    private let rpcPath: String
    private let session: URLSession

    public init(baseURL: URL, rpcPath: String = "/a2a") {
        self.baseURL = baseURL
        self.rpcPath = rpcPath
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Agent Card Discovery

    /// Fetch the Agent Card from the agent's well-known endpoint.
    public func fetchAgentCard(cardPath: String = "/.well-known/agent.json") async throws -> A2AAgentCard {
        guard let url = URL(string: baseURL.absoluteString + cardPath) else {
            throw A2AClientError.invalidURL(baseURL.absoluteString + cardPath)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw A2AClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw A2AClientError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(A2AAgentCard.self, from: data)
        } catch {
            throw A2AClientError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - message/send (Synchronous)

    /// Send a text message and wait for the complete response.
    public func sendMessage(text: String, contextId: String?) async throws -> A2ASendResult {
        let messageId = UUID().uuidString
        let message = A2AMessage(
            role: "user",
            parts: [.text(text)],
            messageId: messageId,
            contextId: contextId
        )
        let params = A2ASendParams(message: message)
        let rpcRequest = A2AJSONRPCRequest(
            id: messageId,
            method: "message/send",
            params: params
        )

        guard let url = URL(string: baseURL.absoluteString + rpcPath) else {
            throw A2AClientError.invalidURL(baseURL.absoluteString + rpcPath)
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        httpRequest.httpBody = try encoder.encode(rpcRequest)

        let (data, response) = try await session.data(for: httpRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw A2AClientError.invalidResponse
        }

        let rawBody = String(data: data, encoding: .utf8)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw A2AClientError.httpError(statusCode: httpResponse.statusCode)
        }

        let rpcResponse: A2AJSONRPCResponse
        do {
            rpcResponse = try JSONDecoder().decode(A2AJSONRPCResponse.self, from: data)
        } catch {
            throw A2AClientError.decodingFailed(error.localizedDescription)
        }

        if let rpcError = rpcResponse.error {
            throw A2AClientError.rpcError(code: rpcError.code, message: rpcError.message)
        }

        guard let result = rpcResponse.result else {
            throw A2AClientError.emptyResult
        }

        let responseText = result.parts?
            .compactMap { $0.kind == "text" ? $0.text : nil }
            .joined(separator: "\n") ?? ""

        return A2ASendResult(
            responseText: responseText,
            contextId: result.contextId,
            messageId: result.messageId,
            rawResponseBody: rawBody
        )
    }

    // MARK: - message/stream (SSE) — Phase 2

    /// Stream a message response via SSE. Returns an async stream of events.
    public func streamMessage(text: String, contextId: String?) -> AsyncThrowingStream<A2AStreamEvent, Error> {
        // Placeholder for Phase 2 streaming implementation.
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: A2AClientError.streamingNotImplemented)
        }
    }
}

// MARK: - Errors

public enum A2AClientError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingFailed(String)
    case rpcError(code: Int, message: String)
    case emptyResult
    case streamingNotImplemented

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid A2A URL: \(url)"
        case .invalidResponse:
            return "Invalid HTTP response from agent"
        case .httpError(let code):
            return "Agent returned HTTP \(code)"
        case .decodingFailed(let detail):
            return "Failed to decode A2A response: \(detail)"
        case .rpcError(let code, let message):
            return "A2A RPC error (\(code)): \(message)"
        case .emptyResult:
            return "Agent returned empty result"
        case .streamingNotImplemented:
            return "A2A streaming is not yet implemented"
        }
    }
}
