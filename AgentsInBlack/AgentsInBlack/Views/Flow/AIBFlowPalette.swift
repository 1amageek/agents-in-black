import AIBCore
import SwiftUI

// MARK: - Color Palette

enum AIBFlowPalette {
    static let agent = Color.mint
    static let mcp = Color.cyan
    static let a2a = Color.orange
    static let unknown = Color.secondary

    static func tint(for kind: AIBServiceKind) -> Color {
        switch kind {
        case .agent: agent
        case .mcp: mcp
        case .unknown: unknown
        }
    }

    static func symbol(for kind: AIBServiceKind) -> String {
        switch kind {
        case .agent: "sparkles"
        case .mcp: "wrench.and.screwdriver.fill"
        case .unknown: "square.stack.3d.up.fill"
        }
    }

    static func label(for kind: AIBServiceKind) -> String {
        switch kind {
        case .agent: "Agent"
        case .mcp: "MCP"
        case .unknown: "Other"
        }
    }

    static func connectionColor(for kind: FlowConnectionKind) -> Color {
        switch kind {
        case .mcp: mcp
        case .a2a: a2a
        }
    }
}
