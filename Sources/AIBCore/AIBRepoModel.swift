import Foundation

public struct AIBRepoModel: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var rootURL: URL
    public var status: String
    public var runtime: String
    public var framework: String
    public var selectedCommand: [String]
    public var namespace: String
    public var detectedRuntimes: [String]
    /// Package names detected per runtime (e.g., ["swift": "MCPServer", "node": "agent"]).
    public var detectedPackageNames: [String: String]

    public init(
        name: String,
        rootURL: URL,
        status: String,
        runtime: String,
        framework: String,
        selectedCommand: [String],
        namespace: String,
        detectedRuntimes: [String] = [],
        detectedPackageNames: [String: String] = [:]
    ) {
        self.id = rootURL.path
        self.name = name
        self.rootURL = rootURL
        self.status = status
        self.runtime = runtime
        self.framework = framework
        self.selectedCommand = selectedCommand
        self.namespace = namespace
        self.detectedRuntimes = detectedRuntimes
        self.detectedPackageNames = detectedPackageNames
    }
}
