import Foundation

public struct AIBChatProfile: Codable, Hashable, Sendable {
    public var method: String
    public var path: String
    public var requestContentType: String
    public var requestMessageJSONPath: String
    public var requestContextJSONPath: String?
    public var responseMessageJSONPath: String
    public var streaming: Bool

    public init(
        method: String = "POST",
        path: String = "/",
        requestContentType: String = "application/json",
        requestMessageJSONPath: String = "message",
        requestContextJSONPath: String? = nil,
        responseMessageJSONPath: String = "message",
        streaming: Bool = false
    ) {
        self.method = method
        self.path = path
        self.requestContentType = requestContentType
        self.requestMessageJSONPath = requestMessageJSONPath
        self.requestContextJSONPath = requestContextJSONPath
        self.responseMessageJSONPath = responseMessageJSONPath
        self.streaming = streaming
    }
}
