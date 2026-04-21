import Foundation

/// A single Claude model entry surfaced to users in the model picker.
public struct ClaudeModelEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Catalog of Claude models exposed in the UI.
///
/// IDs use the public Claude API aliases. Source:
/// https://platform.claude.com/docs/en/about-claude/models/overview
public enum ClaudeModelCatalog {
    /// Current generally available models.
    public static let latest: [ClaudeModelEntry] = [
        .init(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    /// Still-available previous generations. Deprecated/retired models are
    /// intentionally omitted — users must edit workspace.yaml directly if they
    /// need one of those.
    public static let legacy: [ClaudeModelEntry] = [
        .init(id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
        .init(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
        .init(id: "claude-opus-4-5", displayName: "Claude Opus 4.5"),
        .init(id: "claude-opus-4-1", displayName: "Claude Opus 4.1"),
    ]

    public static var all: [ClaudeModelEntry] { latest + legacy }

    public static func entry(for id: String) -> ClaudeModelEntry? {
        all.first { $0.id == id }
    }
}
