import Foundation

// MARK: - Agent Card

/// Agent metadata served at `/.well-known/agent.json`.
public struct A2AAgentCard: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var url: String?
    public var protocolVersion: String?
    public var capabilities: A2ACapabilities?
    public var defaultInputModes: [String]?
    public var defaultOutputModes: [String]?
    public var skills: [A2ASkill]?

    public init(
        name: String,
        description: String? = nil,
        url: String? = nil,
        protocolVersion: String? = nil,
        capabilities: A2ACapabilities? = nil,
        defaultInputModes: [String]? = nil,
        defaultOutputModes: [String]? = nil,
        skills: [A2ASkill]? = nil
    ) {
        self.name = name
        self.description = description
        self.url = url
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.defaultInputModes = defaultInputModes
        self.defaultOutputModes = defaultOutputModes
        self.skills = skills
    }
}

public struct A2ACapabilities: Codable, Sendable, Equatable {
    public var streaming: Bool?
    public var pushNotifications: Bool?

    public init(streaming: Bool? = nil, pushNotifications: Bool? = nil) {
        self.streaming = streaming
        self.pushNotifications = pushNotifications
    }
}

public struct A2ASkill: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var tags: [String]?

    public init(id: String, name: String, description: String? = nil, tags: [String]? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
    }
}

// MARK: - Message

/// A2A protocol message exchanged between user and agent.
public struct A2AMessage: Codable, Sendable {
    public var role: String
    public var parts: [A2APart]
    public var messageId: String
    public var contextId: String?

    public init(role: String, parts: [A2APart], messageId: String, contextId: String? = nil) {
        self.role = role
        self.parts = parts
        self.messageId = messageId
        self.contextId = contextId
    }
}

/// Content unit within a message. MVP supports text only.
public struct A2APart: Codable, Sendable {
    public var kind: String
    public var text: String?

    public init(kind: String = "text", text: String? = nil) {
        self.kind = kind
        self.text = text
    }

    /// Convenience for creating a text part.
    public static func text(_ value: String) -> A2APart {
        A2APart(kind: "text", text: value)
    }
}

// MARK: - JSON-RPC 2.0

/// JSON-RPC 2.0 request envelope.
public struct A2AJSONRPCRequest<P: Encodable & Sendable>: Encodable, Sendable {
    public var jsonrpc: String
    public var id: String
    public var method: String
    public var params: P

    public init(id: String, method: String, params: P) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Parameters for `message/send` and `message/stream`.
public struct A2ASendParams: Codable, Sendable {
    public var message: A2AMessage
    public var configuration: A2ARequestConfiguration?

    public init(message: A2AMessage, configuration: A2ARequestConfiguration? = nil) {
        self.message = message
        self.configuration = configuration
    }
}

public struct A2ARequestConfiguration: Codable, Sendable {
    public var acceptedOutputModes: [String]?

    public init(acceptedOutputModes: [String]? = nil) {
        self.acceptedOutputModes = acceptedOutputModes
    }
}

/// JSON-RPC 2.0 response envelope.
public struct A2AJSONRPCResponse: Codable, Sendable {
    public var jsonrpc: String
    public var id: String?
    public var result: A2AResponseMessage?
    public var error: A2AJSONRPCError?
}

/// The `result` field of a successful `message/send` response.
public struct A2AResponseMessage: Codable, Sendable {
    public var role: String?
    public var parts: [A2APart]?
    public var messageId: String?
    public var contextId: String?
}

/// JSON-RPC 2.0 error object.
public struct A2AJSONRPCError: Codable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Client Result Types

/// Result of a synchronous `message/send` call.
public struct A2ASendResult: Sendable {
    public var responseText: String
    public var contextId: String?
    public var messageId: String?
    public var rawResponseBody: String?

    public init(responseText: String, contextId: String? = nil, messageId: String? = nil, rawResponseBody: String? = nil) {
        self.responseText = responseText
        self.contextId = contextId
        self.messageId = messageId
        self.rawResponseBody = rawResponseBody
    }
}

/// Events emitted during `message/stream` (Phase 2).
public enum A2AStreamEvent: Sendable {
    case statusUpdate(String)
    case textDelta(String)
    case messageComplete(A2ASendResult)
    case error(String)
}
