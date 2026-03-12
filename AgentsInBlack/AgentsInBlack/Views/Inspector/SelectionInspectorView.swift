import AIBCore
import SwiftUI

struct SelectionInspectorView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        if hasSelection {
            if let agentService = selectedAgentForSessions {
                VSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            selectionContent
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 120)

                    AgentSessionsSection(model: model, service: agentService)
                        .frame(minHeight: 100, idealHeight: 200)
                }
                .frame(maxWidth: 360, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    selectionContent
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: 360, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: 360)
        }
    }

    /// Returns the selected agent service when in topology mode (for session split).
    private var selectedAgentForSessions: AIBServiceModel? {
        guard model.detailSurfaceMode == .topology,
              model.selectedChatMessage == nil,
              let flowNode = model.selectedFlowNode(),
              flowNode.serviceKind == .agent else { return nil }
        return flowNode
    }

    private var hasSelection: Bool {
        if model.detailSurfaceMode == .topology {
            return model.selectedChatMessage != nil || model.selectedFlowNode() != nil
        } else {
            return model.selectedRepo() != nil || model.selectedService() != nil || model.selectedFileURL() != nil || model.selectedSkill() != nil
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        if model.detailSurfaceMode == .topology {
            if let message = model.selectedChatMessage {
                ChatMessageInspectorSection(message: message) {
                    model.selectedChatMessage = nil
                }
            } else if let flowNode = model.selectedFlowNode() {
                FlowNodeInspectorSection(model: model, service: flowNode)
            }
        } else {
            if let skill = model.selectedSkill() {
                SkillDetailInspectorSection(model: model, skill: skill)
            } else if let repo = model.selectedRepo(), model.selectedService() == nil, model.selectedFileURL() == nil {
                RepoInspectorSection(model: model, repo: repo, services: repoServices(for: repo.id))
            } else if let service = model.selectedService() {
                ServiceInspectorSection(model: model, service: service, runtime: model.serviceSnapshot(for: service))
            } else if let fileURL = model.selectedFileURL() {
                FileInspectorSection(fileURL: fileURL, onOpen: { model.openInEditor() })
            }
        }
    }

    private var emptyDescription: String {
        if model.detailSurfaceMode == .topology {
            "Select a node on the canvas to inspect."
        } else {
            "Select a repository, service, or file from the sidebar."
        }
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
            Text(service.packageName ?? service.localID)
                .font(.title3).bold()

            Text(service.namespacedID)
                .font(.caption)
                .foregroundStyle(.secondary)

            kindPicker
            InspectorKV(label: "Mount", value: service.mountPath)

            if service.serviceKind == .mcp {
                MCPConfigSection(model: model, service: service)
                    .id(service.id)
            } else if service.serviceKind == .agent {
                ExecutionDirectoryInspectorSection(model: model, service: service)
                SkillsInspectorSection(model: model, service: service)
                agentConnectionsSection
                if !service.runCommand.isEmpty {
                    InspectorKV(label: "Run", value: service.runCommand.joined(separator: " "))
                }
            }
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kind")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: kindBinding) {
                Text("Agent").tag(AIBServiceKind.agent)
                Text("MCP").tag(AIBServiceKind.mcp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var kindBinding: Binding<AIBServiceKind> {
        Binding(
            get: { service.serviceKind },
            set: { newKind in
                Task {
                    await model.updateServiceKind(
                        namespacedServiceID: service.namespacedID,
                        kind: newKind
                    )
                }
            }
        )
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
    @Bindable var model: AgentsInBlackAppModel
    var repo: AIBRepoModel
    var services: [AIBServiceModel]

    var body: some View {
        Group {
            Text(repo.name)
                .font(.title3).bold()
            InspectorKV(label: "Path", value: repo.rootURL.path)
            InspectorKV(label: "Status", value: repo.status)

            if repo.detectedRuntimes.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Runtime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: runtimeBinding) {
                        ForEach(repo.detectedRuntimes, id: \.self) { rt in
                            Text(rt).tag(rt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            } else {
                InspectorKV(label: "Runtime", value: "\(repo.runtime) / \(repo.framework)")
            }

            InspectorKV(label: "Services", value: "\(services.count)")
            InspectorKV(label: "Namespace", value: repo.namespace)
            InspectorKV(label: "Command", value: repo.selectedCommand.isEmpty ? "(none)" : repo.selectedCommand.joined(separator: " "))

            Divider()
            Text("Services")
                .font(.headline)
            if services.isEmpty {
                Text("No services configured")
                    .foregroundStyle(.secondary)
            }
            ForEach(services, id: \.id) { service in
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.namespacedID)
                    Text(service.mountPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            let configuredIDs = Set(services.map(\.localID))
            let uncoveredRuntimes = repo.detectedRuntimes.filter { !configuredIDs.contains($0) }
            if !uncoveredRuntimes.isEmpty {
                ForEach(uncoveredRuntimes, id: \.self) { rt in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(repo.namespace)/\(rt)")
                                .foregroundStyle(.secondary)
                            Text("Not configured")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            Task { await model.configureServices(repoID: repo.id, runtimes: [rt]) }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var runtimeBinding: Binding<String> {
        Binding(
            get: { repo.runtime },
            set: { newRuntime in
                Task { await model.switchRepoRuntime(repoID: repo.id, runtime: newRuntime) }
            }
        )
    }
}

private struct ServiceInspectorSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel
    var runtime: AIBServiceRuntimeSnapshot?

    var body: some View {
        Group {
            Text(service.namespacedID)
                .font(.title3).bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("Kind")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: serviceKindBinding) {
                    Text("Agent").tag(AIBServiceKind.agent)
                    Text("MCP").tag(AIBServiceKind.mcp)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            InspectorKV(label: "Repo", value: service.repoName)
            InspectorKV(label: "Mount", value: service.mountPath)
            InspectorKV(label: "Watch", value: service.watchMode ?? "(unspecified)")
            InspectorKV(label: "CWD", value: service.cwd ?? "(repo root)")
            InspectorKV(label: "Run", value: service.runCommand.isEmpty ? "(none)" : service.runCommand.joined(separator: " "))
            if service.serviceKind == .agent {
                ExecutionDirectoryInspectorSection(model: model, service: service)
                SkillsInspectorSection(model: model, service: service)
            }
            Divider()
            Text("Runtime")
                .font(.headline)
            InspectorKV(label: "State", value: runtime.map { "\($0.lifecycleState)" } ?? "(not running)")
            InspectorKV(label: "Backend Port", value: runtime?.backendPort.map(String.init) ?? "(none)")
            InspectorKV(label: "Probe Failures", value: runtime.map { String($0.consecutiveProbeFailures) } ?? "0")
            InspectorKV(label: "Last Exit", value: runtime?.lastExitStatus.map(String.init) ?? "(none)")
            Divider()
            Button("Remove Service", role: .destructive) {
                model.requestRemoveService(
                    namespacedServiceID: service.namespacedID,
                    displayName: service.packageName ?? service.localID
                )
            }
        }
    }

    private var serviceKindBinding: Binding<AIBServiceKind> {
        Binding(
            get: { service.serviceKind },
            set: { newKind in
                Task {
                    await model.updateServiceKind(
                        namespacedServiceID: service.namespacedID,
                        kind: newKind
                    )
                }
            }
        )
    }
}

private struct ExecutionDirectoryInspectorSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Execution Directory")
                .font(.headline)

            VStack(alignment: .leading, spacing: 3) {
                Text("Root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rootPath = service.executionDirectoryPath {
                    Button {
                        model.openExecutionDirectoryRoot(for: service)
                    } label: {
                        openablePathLabel(
                            rootPath,
                            isSecondary: false
                        )
                    }
                    .buttonStyle(.plain)
                    .help(rootPath)
                } else {
                    Text(service.cwd ?? "(repo root)")
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            let markers = AIBExecutionDirectoryInspector.topLevelMarkers(for: service.executionDirectoryEntries)
            if !markers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(markers, id: \.self) { marker in
                                Text(marker)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service.executionDirectoryEntries.isEmpty {
                    Text("(none)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(service.executionDirectoryEntries, id: \.relativePath) { entry in
                                Button {
                                    model.openExecutionDirectoryEntry(entry, for: service)
                                } label: {
                                    openablePathLabel(
                                        entry.relativePath,
                                        isSecondary: entry.kind == .directory
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(entry.relativePath)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
    }

    @ViewBuilder
    private func openablePathLabel(_ text: String, isSecondary: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            Image(systemName: "arrow.up.forward.app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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

// MARK: - Chat Message Inspector

private struct ChatMessageInspectorSection: View {
    var message: ChatMessageItem
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Response Detail")
                    .font(.title3).bold()
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let code = message.statusCode {
                InspectorKV(label: "Status", value: "\(code)")
            }
            if let ms = message.latencyMs {
                InspectorKV(label: "Latency", value: "\(ms)ms")
            }
            if let requestID = message.requestID {
                InspectorKV(label: "Request ID", value: requestID)
            }

            InspectorKV(label: "Message", value: message.text)

            if let raw = message.rawResponseBody {
                Divider()
                Text("Raw Response")
                    .font(.headline)
                ScrollView {
                    Text(prettyJSON(raw))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return raw }
        return result
    }
}

// MARK: - Agent Sessions

private struct AgentSessionsSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let deployedURL = model.deployedURL(for: service) {
                    Button {
                        let session = model.createRemoteSession(
                            for: service, deployedURL: deployedURL, activate: true
                        )
                        openPiPChat(sessionID: session.id)
                    } label: {
                        Image(systemName: "cloud")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("New Remote Session")
                }
                Button {
                    let session = model.createSession(for: service, activate: true)
                    openPiPChat(sessionID: session.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("New Session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Session list
            let sessions = model.sessions(for: service)
            let activeID = model.activeSessionIDByService[service.id]

            if sessions.isEmpty {
                Spacer()
                Text("No sessions")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            sessionRow(session, isActive: session.id == activeID)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func openPiPChat(sessionID: UUID) {
        model.openPiPChat(serviceID: service.id, sessionID: sessionID)
    }

    private func sessionRow(_ session: ChatSession, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isActive ? AnyShapeStyle(.mint) : AnyShapeStyle(.tertiary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text("\(session.messages.count) messages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let lastAt = session.lastMessageAt {
                        Text(lastAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                model.deleteSession(session.id, for: service)
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(0.5)
            .help("Delete Session")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.activateSession(session.id, for: service)
            openPiPChat(sessionID: session.id)
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

// MARK: - Skills Inspector

private struct SkillsInspectorSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var service: AIBServiceModel

    @State private var showAddSkill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Text("Skills")
                    .font(.headline)
                Spacer()
                let unassigned = model.unassignedSkills(for: service)
                if !unassigned.isEmpty {
                    Menu {
                        ForEach(unassigned, id: \.id) { skill in
                            Button {
                                Task {
                                    await model.assignSkill(
                                        skillID: skill.id,
                                        namespacedServiceID: service.namespacedID
                                    )
                                }
                            } label: {
                                VStack {
                                    Text(skill.name)
                                    if let desc = skill.description {
                                        Text(desc)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption2.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Assign Skill")
                }
            }

            let assigned = model.assignedSkills(for: service)
            if assigned.isEmpty {
                Text("No skills assigned")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(assigned, id: \.id) { skill in
                    skillRow(skill)
                }
            }
        }
    }

    private func skillRow(_ skill: AIBSkillDefinition) -> some View {
        let isExplicitlyAssigned = model.isExplicitlyAssigned(skillID: skill.id, to: service)
        let isNativelyAvailable = model.isNativelyAvailable(skillID: skill.id, for: service)
        return HStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.caption)
                .foregroundStyle(.purple)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let desc = skill.description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if isNativelyAvailable && !isExplicitlyAssigned {
                Text("Bundled")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await model.unassignSkill(
                            skillID: skill.id,
                            namespacedServiceID: service.namespacedID
                        )
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unassign \(skill.name)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Skill Detail Inspector (sidebar selection)

private struct SkillDetailInspectorSection: View {
    @Bindable var model: AgentsInBlackAppModel
    var skill: AIBSkillDefinition

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.purple)
                    .font(.title2)
                Text(skill.name)
                    .font(.title3).bold()
            }

            Text(skill.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(skill.isWorkspaceManaged ? "Workspace Skill" : "Discovered in Execution Directory")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let description = skill.description {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(description)
                        .font(.callout)
                }
            }

            if !skill.allowedTools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowed Tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(skill.allowedTools, id: \.self) { tool in
                        Text(tool)
                            .font(.callout.monospaced())
                    }
                }
            }

            if !skill.tags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(skill.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            if let instructions = skill.instructions, !instructions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(instructions)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            assignedAgentsSection

            if skill.isWorkspaceManaged {
                Divider()
                Button("Remove from Workspace", role: .destructive) {
                    Task { await model.removeSkillFromWorkspace(skillID: skill.id) }
                }
            }
        }
    }

    private var assignedAgentsSection: some View {
        let agents = model.servicesWithSkill(skill.id)
        return Group {
            Divider()
            Text("Assigned Agents")
                .font(.headline)
            if agents.isEmpty {
                Text("Not assigned to any agent")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(agents, id: \.id) { agent in
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(agent.packageName ?? agent.localID)
                            .font(.callout)
                    }
                }
            }
        }
    }
}
