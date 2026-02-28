import Foundation

public struct AIBRuntimeOptions: Sendable {
    public var workspaceRoot: String
    public var gatewayPort: Int?
    public var logLevel: String
    public var reloadEnabled: Bool
    public var dryRun: Bool
    public var statePIDPath: String?

    public init(
        workspaceRoot: String,
        gatewayPort: Int? = nil,
        logLevel: String = "info",
        reloadEnabled: Bool = true,
        dryRun: Bool = false,
        statePIDPath: String? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.gatewayPort = gatewayPort
        self.logLevel = logLevel
        self.reloadEnabled = reloadEnabled
        self.dryRun = dryRun
        self.statePIDPath = statePIDPath
    }
}
