import AIBCore
import SwiftUI

struct SelectionInspectorView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.detailSurfaceMode == .topology {
                if let flowNode = model.selectedFlowNode() {
                    FlowNodeInspectorSection(model: model, service: flowNode)
                }
            }

            if model.detailSurfaceMode != .topology {
                if let repo = model.selectedRepo(), model.selectedService() == nil, model.selectedFileURL() == nil {
                    RepoInspectorSection(repo: repo, services: repoServices(for: repo.id))
                } else if let service = model.selectedService() {
                    ServiceInspectorSection(service: service, runtime: model.serviceSnapshot(for: service))
                } else if let fileURL = model.selectedFileURL() {
                    FileInspectorSection(fileURL: fileURL, onOpen: { model.openInEditor() })
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Select a repository, service, or file from the sidebar.")
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func repoServices(for repoID: String) -> [AIBServiceModel] {
        guard let workspace = model.workspace else { return [] }
        return workspace.services.filter { $0.repoID == repoID }
    }
}

// MARK: - Flow Node Inspector

private struct FlowNodeInspectorSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.namespacedID)
                .font(.title3).bold()

            kindBadge
            InspectorKV(label: "Mount", value: service.mountPath)

            if service.serviceKind == .mcp {
                MCPConfigSection(model: model, service: service)
                    .id(service.id)
            } else if service.serviceKind == .agent {
                if model.canOpenChat(for: service) {
                    Button {
                        let pos = PiPGeometry.initialExpandedPosition(
                            in: model.flowCanvasSize,
                            panelSize: PiPChatPanel.panelSize,
                            avoiding: model.openPiPChats.map(\.position)
                        )
                        model.openPiPChat(for: service, initialPosition: pos)
                    } label: {
                        Label("Open Chat", systemImage: "bubble.left.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
                }
                agentConnectionsSection
                if !service.runCommand.isEmpty {
                    InspectorKV(label: "Run", value: service.runCommand.joined(separator: " "))
                }
            }
        }
    }

    private var kindBadge: some View {
        let (label, color): (String, Color) = switch service.serviceKind {
        case .agent: ("Agent", .mint)
        case .mcp: ("MCP", .cyan)
        case .unknown: ("Other", .secondary)
        }
        return Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Agent Connections

    private func resolvedMCPService(for target: AIBConnectionTarget) -> AIBServiceModel? {
        guard let ref = target.serviceRef, let workspace = model.workspace else { return nil }
        return workspace.services.first(where: { $0.namespacedID == ref })
    }

    private func mcpResolvedURL(for mcpService: AIBServiceModel) -> String {
        let port = model.gatewayPort
        let path = mcpService.mcpProfile?.path ?? "/mcp"
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "http://localhost:\(port)\(mcpService.mountPath)\(normalizedPath)"
    }

    private var agentConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Connections")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("MCP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.connections.mcpServers.isEmpty {
                    Text("(none)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(service.connections.mcpServers, id: \.serviceRef) { target in
                        mcpConnectionDetail(target)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("A2A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.connections.a2aAgents.isEmpty {
                    Text("(none)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(service.connections.a2aAgents, id: \.serviceRef) { target in
                        Text(target.serviceRef ?? target.url ?? "(unknown)")
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func mcpConnectionDetail(_ target: AIBConnectionTarget) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(target.serviceRef ?? target.url ?? "(unknown)")
                .font(.callout.weight(.medium))
            if let mcpService = resolvedMCPService(for: target) {
                let command = mcpService.runCommand.first ?? "(none)"
                let args = Array(mcpService.runCommand.dropFirst())
                let argsText = args.isEmpty ? "" : " " + args.joined(separator: " ")
                HStack(spacing: 4) {
                    Text("Streamable HTTP")
                        .font(.caption2)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(mcpService.mcpProfile?.path ?? "/mcp")
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.secondary)
                Text(command + argsText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(mcpResolvedURL(for: mcpService))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - MCP Config

private struct MCPConfigSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel

    @State private var editPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("MCP Configuration")
                .font(.headline)

            InspectorKV(label: "Transport", value: "Streamable HTTP")
            InspectorKV(label: "Command", value: service.runCommand.first ?? "(none)")
            InspectorKV(label: "Args", value: argsDisplay)

            VStack(alignment: .leading, spacing: 4) {
                Text("Path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/mcp", text: $editPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            InspectorKV(label: "Resolved URL", value: resolvedURL)

            Button("Save") {
                Task {
                    await model.updateMCPProfile(
                        namespacedServiceID: service.namespacedID,
                        path: editPath
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges)
        }
        .onAppear {
            editPath = service.mcpProfile?.path ?? "/mcp"
        }
    }

    private var argsDisplay: String {
        let args = Array(service.runCommand.dropFirst())
        return args.isEmpty ? "(none)" : args.joined(separator: " ")
    }

    private var hasChanges: Bool {
        let currentPath = service.mcpProfile?.path ?? "/mcp"
        return editPath != currentPath
    }

    private var resolvedURL: String {
        let port = model.gatewayPort
        let path = editPath.hasPrefix("/") ? editPath : "/\(editPath)"
        return "http://localhost:\(port)\(service.mountPath)\(path)"
    }
}

// MARK: - Repo Inspector

private struct RepoInspectorSection: View {
    var repo: AIBRepoModel
    var services: [AIBServiceModel]

    var body: some View {
        Group {
            Text(repo.name)
                .font(.title3).bold()
            InspectorKV(label: "Path", value: repo.rootURL.path)
            InspectorKV(label: "Status", value: repo.status)
            InspectorKV(label: "Runtime", value: "\(repo.runtime) / \(repo.framework)")
            InspectorKV(label: "Services", value: "\(services.count)")
            InspectorKV(label: "Namespace", value: repo.namespace)
            InspectorKV(label: "Command", value: repo.selectedCommand.isEmpty ? "(none)" : repo.selectedCommand.joined(separator: " "))

            Divider()
            Text("Services")
                .font(.headline)
            if services.isEmpty {
                Text("No services detected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(services, id: \.id) { service in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.namespacedID)
                        Text(service.mountPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ServiceInspectorSection: View {
    var service: AIBServiceModel
    var runtime: AIBServiceRuntimeSnapshot?

    var body: some View {
        Group {
            Text(service.namespacedID)
                .font(.title3).bold()
            InspectorKV(label: "Repo", value: service.repoName)
            InspectorKV(label: "Mount", value: service.mountPath)
            InspectorKV(label: "Watch", value: service.watchMode ?? "(unspecified)")
            InspectorKV(label: "CWD", value: service.cwd ?? "(repo root)")
            InspectorKV(label: "Run", value: service.runCommand.isEmpty ? "(none)" : service.runCommand.joined(separator: " "))
            Divider()
            Text("Runtime")
                .font(.headline)
            InspectorKV(label: "State", value: runtime.map { "\($0.lifecycleState)" } ?? "(not running)")
            InspectorKV(label: "Backend Port", value: runtime?.backendPort.map(String.init) ?? "(none)")
            InspectorKV(label: "Probe Failures", value: runtime.map { String($0.consecutiveProbeFailures) } ?? "0")
            InspectorKV(label: "Last Exit", value: runtime?.lastExitStatus.map(String.init) ?? "(none)")
        }
    }
}

private struct FileInspectorSection: View {
    var fileURL: URL
    var onOpen: () -> Void

    var body: some View {
        Group {
            Text(fileURL.lastPathComponent)
                .font(.title3).bold()
            InspectorKV(label: "Path", value: fileURL.path)
            Button("Open in Editor", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct InspectorKV: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
        }
    }
}
