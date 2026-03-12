import Foundation

/// A workspace-level skill definition for App/UI consumption.
/// Represents an instruction-based prompt package following the Agent Skills standard.
public struct AIBSkillDefinition: Identifiable, Hashable, Sendable {
    public enum Source: String, Hashable, Sendable, Codable {
        case workspace
        case executionDirectory
    }

    /// Unique identifier within the workspace (e.g., "web-tools").
    public let id: String
    /// Display name (e.g., "Web Tools").
    public var name: String
    /// What the skill does and when to use it.
    public var description: String?
    /// The skill's instruction content (markdown).
    public var instructions: String?
    /// Tools the agent is allowed to use when this skill is active.
    public var allowedTools: [String]
    /// Categorization tags for filtering and display.
    public var tags: [String]
    /// Where this skill came from.
    public var source: Source
    /// Whether the skill has been imported into workspace-managed storage.
    public var isWorkspaceManaged: Bool
    /// Absolute path to the skill bundle directory when known.
    public var bundleRootPath: String?
    /// Services whose execution directories currently expose this skill.
    public var discoveredInServices: [String]

    public init(
        id: String,
        name: String,
        description: String? = nil,
        instructions: String? = nil,
        allowedTools: [String] = [],
        tags: [String] = [],
        source: Source = .workspace,
        isWorkspaceManaged: Bool = true,
        bundleRootPath: String? = nil,
        discoveredInServices: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.allowedTools = allowedTools
        self.tags = tags
        self.source = source
        self.isWorkspaceManaged = isWorkspaceManaged
        self.bundleRootPath = bundleRootPath
        self.discoveredInServices = discoveredInServices
    }
}
