import Foundation

public struct AIBWorkspaceSnapshot: Sendable {
    public var rootURL: URL
    public var displayName: String
    public var repos: [AIBRepoModel]
    public var fileTreesByRepoID: [String: [AIBFileNode]]
    public var services: [AIBServiceModel]
    /// Workspace-level skill definitions.
    public var skills: [AIBSkillDefinition]
    /// Gateway port configured in workspace.yaml.
    public var gatewayPort: Int
    /// Directories referenced in workspace.yaml that do not exist on disk.
    public var missingDirectories: [MissingDirectory]

    public struct MissingDirectory: Sendable, Identifiable {
        public var id: String { path }
        public var name: String
        public var path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public init(rootURL: URL, displayName: String, repos: [AIBRepoModel], fileTreesByRepoID: [String: [AIBFileNode]], services: [AIBServiceModel], skills: [AIBSkillDefinition] = [], gatewayPort: Int = 9090, missingDirectories: [MissingDirectory] = []) {
        self.rootURL = rootURL
        self.displayName = displayName
        self.repos = repos
        self.fileTreesByRepoID = fileTreesByRepoID
        self.services = services
        self.skills = skills
        self.gatewayPort = gatewayPort
        self.missingDirectories = missingDirectories
    }
}
