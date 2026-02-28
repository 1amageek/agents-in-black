import Foundation

public struct AIBValidatedConfigSummary: Sendable {
    public var serviceCount: Int
    public var warnings: [String]

    public init(serviceCount: Int, warnings: [String]) {
        self.serviceCount = serviceCount
        self.warnings = warnings
    }
}
