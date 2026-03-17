import Foundation

/// Constants for the AIB context propagation protocol.
///
/// Client sends `"context"` in the JSON request body. Agent-side middleware
/// extracts it, stores it in request-scoped storage, and injects it as
/// `X-Context` header on outgoing MCP calls. Agent logic never sees context.
public enum ContextPropagationHeaders {

    /// The JSON body key that holds the context object.
    public static let bodyKey = "context"

    /// The HTTP header used to inject context into MCP requests.
    /// Value is a JSON-encoded string of the context object.
    public static let contextHeader = "X-Context"
}
