import Foundation

public struct AIBServiceUIProfile: Codable, Hashable, Sendable {
    public var primaryMode: AIBWorkbenchMode?
    public var chatProfile: AIBChatProfile?

    public init(primaryMode: AIBWorkbenchMode? = nil, chatProfile: AIBChatProfile? = nil) {
        self.primaryMode = primaryMode
        self.chatProfile = chatProfile
    }

    enum CodingKeys: String, CodingKey {
        case primaryMode = "primary_mode"
        case chatProfile = "chat"
    }
}
