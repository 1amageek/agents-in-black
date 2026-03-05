import Foundation
import Logging

/// A single log entry produced during the deployment process.
/// Uses `Logger.Level` from swift-log for consistency with the emulator's logging pattern.
public struct AIBDeployLogEntry: Sendable, Identifiable {
    public let id: UUID
    public var timestamp: Date
    public var elapsedSeconds: TimeInterval?
    public var level: Logger.Level
    public var serviceID: String?
    public var step: AIBDeployStep?
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        elapsedSeconds: TimeInterval? = nil,
        level: Logger.Level,
        serviceID: String? = nil,
        step: AIBDeployStep? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.elapsedSeconds = elapsedSeconds
        self.level = level
        self.serviceID = serviceID
        self.step = step
        self.message = message
    }

    public var formattedLine: String {
        let formatter = ISO8601DateFormatter()
        let prefix = serviceID.map { "[\($0)] " } ?? ""
        let stepLabel = step.map { "(\($0.rawValue)) " } ?? ""
        let elapsedLabel: String
        if let elapsedSeconds {
            elapsedLabel = String(format: " [t+%.1fs]", elapsedSeconds)
        } else {
            elapsedLabel = ""
        }
        return "\(formatter.string(from: timestamp))\(elapsedLabel) \(level) \(prefix)\(stepLabel)\(message)"
    }
}
