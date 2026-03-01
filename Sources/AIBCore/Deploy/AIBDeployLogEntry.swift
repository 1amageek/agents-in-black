import Foundation
import Logging

/// A single log entry produced during the deployment process.
/// Uses `Logger.Level` from swift-log for consistency with the emulator's logging pattern.
public struct AIBDeployLogEntry: Sendable, Identifiable {
    public let id: UUID
    public var timestamp: Date
    public var level: Logger.Level
    public var serviceID: String?
    public var step: AIBDeployStep?
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: Logger.Level,
        serviceID: String? = nil,
        step: AIBDeployStep? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.serviceID = serviceID
        self.step = step
        self.message = message
    }

    public var formattedLine: String {
        let formatter = ISO8601DateFormatter()
        let prefix = serviceID.map { "[\($0)] " } ?? ""
        let stepLabel = step.map { "(\($0.rawValue)) " } ?? ""
        return "\(formatter.string(from: timestamp)) \(level) \(prefix)\(stepLabel)\(message)"
    }
}
