import AIBCore
import SwiftUI

// MARK: - Color Palette

enum AIBFlowPalette {
    static let agent = Color(red: 0.16, green: 0.79, blue: 0.67)
    static let mcp = Color(red: 0.11, green: 0.68, blue: 0.98)
    static let a2a = Color(red: 0.96, green: 0.63, blue: 0.22)
    static let unknown = Color(red: 0.60, green: 0.63, blue: 0.69)

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

    static func canvasGridColor(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white.opacity(0.08)
        default:
            return .black.opacity(0.10)
        }
    }

    static func edgeStrokeColor(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return .white.opacity(0.72)
        default:
            return .black.opacity(0.58)
        }
    }

    static func edgeSelectedStrokeColor(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return mcp.opacity(0.98)
        default:
            return mcp.opacity(0.92)
        }
    }

    static func nodeBaseFill(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            return Color(red: 0.11, green: 0.12, blue: 0.15)
        default:
            return Color(red: 0.98, green: 0.985, blue: 0.99)
        }
    }

    static func nodeNeutralBorder(for colorScheme: ColorScheme, isHovered: Bool) -> Color {
        switch colorScheme {
        case .dark:
            return .white.opacity(isHovered ? 0.52 : 0.38)
        default:
            return .black.opacity(isHovered ? 0.30 : 0.20)
        }
    }
}
