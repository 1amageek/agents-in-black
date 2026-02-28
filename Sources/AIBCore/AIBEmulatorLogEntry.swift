import Foundation
import Logging

public struct AIBEmulatorLogEntry: Sendable {
    public var timestamp: Date
    public var level: Logger.Level
    public var loggerLabel: String
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date,
        level: Logger.Level,
        loggerLabel: String,
        message: String,
        metadata: [String: String]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.loggerLabel = loggerLabel
        self.message = message
        self.metadata = metadata
    }

    public var formattedLine: String {
        let formatter = ISO8601DateFormatter()
        let metadataText: String
        if metadata.isEmpty {
            metadataText = ""
        } else {
            metadataText = " " + metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        }
        return "\(formatter.string(from: timestamp)) \(level) \(loggerLabel): \(message)\(metadataText)\n"
    }
}
