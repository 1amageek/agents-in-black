import Foundation

/// Workspace-level skill definition stored in `.aib/workspace.yaml`.
/// Skills are instruction-based prompt packages following the Agent Skills standard.
/// Each skill provides reusable instructions that extend an agent's capabilities.
public struct WorkspaceSkillConfig: Codable, Sendable, Equatable {
    /// Unique identifier within the workspace (e.g., "web-tools").
    public var id: String
    /// Display name (e.g., "Web Tools").
    public var name: String
    /// What the skill does and when to use it.
    public var description: String?
    /// The skill's instruction content (markdown). Loaded into the agent's context when the skill is active.
    public var instructions: String?
    /// Tools the agent is allowed to use when this skill is active.
    public var allowedTools: [String]?
    /// Categorization tags for filtering and display.
    public var tags: [String]?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        instructions: String? = nil,
        allowedTools: [String]? = nil,
        tags: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.allowedTools = allowedTools
        self.tags = tags
    }

    /// Generate a slug ID from a display name.
    /// "Web Tools" → "web-tools", "DB / Query" → "db-query"
    public static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            .reduce(into: "") { $0.append(String($1)) }
            .split(separator: "-").joined(separator: "-") // collapse consecutive hyphens
    }
}
