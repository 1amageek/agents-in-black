import AIBCore
import CoreGraphics
import Foundation

enum FlowConnectionKind: String, Hashable {
    case mcp = "MCP"
    case a2a = "A2A"
}

enum MCPConnectionRuntimeStatus: String, Hashable {
    case connecting
    case connected
    case failed
}

struct FlowNodeModel: Identifiable, Hashable {
    let id: String
    let namespacedID: String
    /// Display name from the package manifest (e.g., package.json "name", Package.swift target name).
    let displayName: String?
    let serviceKind: AIBServiceKind
    let position: CGPoint
}

struct FlowConnectionModel: Identifiable, Hashable {
    let id: String
    let sourceServiceID: String
    let targetServiceID: String
    let kind: FlowConnectionKind
}

enum DetailSurfaceMode: String, CaseIterable, Identifiable {
    case topology = "Topology"
    case workbench = "Workbench"

    var id: String { rawValue }
}
