import Foundation

public struct BuildPreparationError: AIBErrorPayload, Sendable {
    public let message: String
    public let metadata: [String: String]

    public init(_ message: String, metadata: [String: String] = [:]) {
        self.message = message
        self.metadata = metadata
    }
}
