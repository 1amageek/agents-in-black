import Foundation

public struct AIBServiceModel: Identifiable, Hashable, Sendable {
    public let id: String
    public var repoID: String
    public var repoName: String
    public var localID: String
    public var namespacedID: String
    public var mountPath: String
    public var runCommand: [String]
    public var watchMode: String?
    public var cwd: String?
    public var serviceKind: AIBServiceKind
    public var connections: AIBServiceConnections
    public var mcpProfile: AIBMCPProfile?
    public var a2aProfile: AIBA2AProfile?
    public var uiProfile: AIBServiceUIProfile?

    public init(
        repoID: String,
        repoName: String,
        localID: String,
        namespace: String,
        mountPath: String,
        runCommand: [String],
        watchMode: String?,
        cwd: String?,
        serviceKind: AIBServiceKind = .unknown,
        connections: AIBServiceConnections = .init(),
        mcpProfile: AIBMCPProfile? = nil,
        a2aProfile: AIBA2AProfile? = nil,
        uiProfile: AIBServiceUIProfile? = nil
    ) {
        self.repoID = repoID
        self.repoName = repoName
        self.localID = localID
        self.namespacedID = "\(namespace)/\(localID)"
        self.id = "\(repoID)::\(localID)"
        self.mountPath = mountPath
        self.runCommand = runCommand
        self.watchMode = watchMode
        self.cwd = cwd
        self.serviceKind = serviceKind
        self.connections = connections
        self.mcpProfile = mcpProfile
        self.a2aProfile = a2aProfile
        self.uiProfile = uiProfile
    }
}
