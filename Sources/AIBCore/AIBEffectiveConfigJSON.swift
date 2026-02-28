import Foundation

public struct AIBEffectiveConfigJSON: Sendable {
    public var json: String
    public var warnings: [String]

    public init(json: String, warnings: [String]) {
        self.json = json
        self.warnings = warnings
    }
}
