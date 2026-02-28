import Foundation

public struct AIBWorkspaceSnapshot: Sendable {
    public var rootURL: URL
    public var displayName: String
    public var repos: [AIBRepoModel]
    public var fileTreesByRepoID: [String: [AIBFileNode]]
    public var services: [AIBServiceModel]

    public init(rootURL: URL, displayName: String, repos: [AIBRepoModel], fileTreesByRepoID: [String: [AIBFileNode]], services: [AIBServiceModel]) {
        self.rootURL = rootURL
        self.displayName = displayName
        self.repos = repos
        self.fileTreesByRepoID = fileTreesByRepoID
        self.services = services
    }
}
