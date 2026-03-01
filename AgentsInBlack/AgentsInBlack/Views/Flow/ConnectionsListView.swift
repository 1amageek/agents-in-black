import AIBCore
import SwiftUI

/// Displays the list of flow connections between services in the utility panel.
struct ConnectionsListView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        let connections = filteredConnections(model.flowConnections())
        if connections.isEmpty {
            ContentUnavailableView(
                "No Connections",
                systemImage: "arrow.triangle.branch",
                description: Text("Connect agents to MCP servers or other agents in the topology canvas.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(connections) { connection in
                        connectionRow(connection)
                        if connection.id != connections.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func connectionRow(_ connection: FlowConnectionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connection.kind == .mcp ? "wrench.and.screwdriver" : "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(AIBFlowPalette.connectionColor(for: connection.kind))
                .frame(width: 20, alignment: .center)

            Text(connection.kind.rawValue)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AIBFlowPalette.connectionColor(for: connection.kind))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AIBFlowPalette.connectionColor(for: connection.kind).opacity(0.12), in: Capsule())

            Text(connectionSummary(connection))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button {
                model.removeFlowConnection(connection)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove connection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func connectionSummary(_ connection: FlowConnectionModel) -> String {
        let source = model.service(by: connection.sourceServiceID)?.namespacedID ?? connection.sourceServiceID
        let target = model.service(by: connection.targetServiceID)?.namespacedID ?? connection.targetServiceID
        return "\(source)  \u{2192}  \(target)"
    }

    private func filteredConnections(_ connections: [FlowConnectionModel]) -> [FlowConnectionModel] {
        let filterText = model.utilityPanelFilterText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !filterText.isEmpty else { return connections }
        return connections.filter { connection in
            connectionSummary(connection).lowercased().contains(filterText)
                || connection.kind.rawValue.lowercased().contains(filterText)
        }
    }
}
