import Foundation

/// A single Codex model entry surfaced to users in the model picker.
public struct ClaudeModelEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Catalog of Codex models exposed in the UI.
public enum ClaudeModelCatalog {
    /// Current generally available models.
    public static let latest: [ClaudeModelEntry] = [
        .init(id: "gpt-5.5", displayName: "GPT-5.5"),
        .init(id: "gpt-5.4", displayName: "GPT-5.4"),
        .init(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
    ]

    /// Still-available previous generations. Deprecated/retired models are
    /// intentionally omitted — users must edit workspace.yaml directly if they
    /// need one of those.
    public static let legacy: [ClaudeModelEntry] = [
        .init(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
        .init(id: "gpt-5.3-codex-spark", displayName: "GPT-5.3 Codex Spark"),
        .init(id: "gpt-5.2", displayName: "GPT-5.2"),
    ]

    public static var all: [ClaudeModelEntry] { latest + legacy }

    public static func entry(for id: String) -> ClaudeModelEntry? {
        all.first { $0.id == id }
    }
}
