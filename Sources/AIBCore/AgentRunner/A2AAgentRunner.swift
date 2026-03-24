import Foundation

/// Agent runner that sends messages via A2A HTTP/JSON-RPC protocol.
///
/// Used for deployed agents (Cloud Run) and local container agents.
public struct A2AAgentRunner: AgentRunner, Sendable {
    private let baseURL: URL
    private let rpcPath: String

    public init(baseURL: URL, rpcPath: String = "/a2a") {
        self.baseURL = baseURL
        self.rpcPath = rpcPath
    }

    public func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let client = A2AClient(baseURL: baseURL, rpcPath: rpcPath)
                    let result = try await client.sendMessage(text: message, contextId: context.conversationID)

                    if let newContextId = result.contextId {
                        continuation.yield(.sessionID(newContextId))
                    }
                    continuation.yield(.textComplete(result.responseText))
                    continuation.yield(.done(AgentRunnerResult(conversationID: result.contextId)))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
