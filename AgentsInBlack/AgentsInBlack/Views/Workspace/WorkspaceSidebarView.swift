import AIBCore
import AIBRuntimeCore
import AIBWorkspace
import os
import SwiftSkill
import SwiftUI
import UniformTypeIdentifiers

private let sidebarDropLogger = os.Logger(subsystem: "com.aib.app", category: "SidebarDrop")

struct WorkspaceSidebarView: View {
    @Bindable var model: AgentsInBlackAppModel
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: $model.selection) {
            actorTopologyRow
            if model.showIssuesInSidebar {
                issuesSection
            }
            workspaceSection
            if model.workspace != nil {
                skillsSection(model.workspace?.skills ?? [])
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            sidebarDropLogger.info("[DROP] onDrop called, providers=\(providers.count), workspace=\(model.workspace != nil)")
            guard model.workspace != nil else {
                sidebarDropLogger.warning("[DROP] No workspace open, rejecting drop")
                return false
            }
            for (index, provider) in providers.enumerated() {
                sidebarDropLogger.info("[DROP] Provider \(index): registeredTypes=\(provider.registeredTypeIdentifiers)")
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                    if let error {
                        sidebarDropLogger.error("[DROP] loadItem error: \(error.localizedDescription)")
                        return
                    }
                    sidebarDropLogger.info("[DROP] loadItem data type: \(String(describing: type(of: data)))")
                    guard let data = data as? Data else {
                        sidebarDropLogger.error("[DROP] data is not Data, actual: \(String(describing: data))")
                        return
                    }
                    guard let path = String(data: data, encoding: .utf8) else {
                        sidebarDropLogger.error("[DROP] Failed to decode data as UTF-8 string")
                        return
                    }
                    sidebarDropLogger.info("[DROP] Decoded path string: \(path)")
                    guard let url = URL(string: path) else {
                        sidebarDropLogger.error("[DROP] Failed to create URL from: \(path)")
                        return
                    }
                    let fileURL = url.standardizedFileURL
                    sidebarDropLogger.info("[DROP] Resolved fileURL: \(fileURL.path)")
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                    sidebarDropLogger.info("[DROP] exists=\(exists), isDir=\(isDir.boolValue)")
                    guard exists, isDir.boolValue else {
                        sidebarDropLogger.warning("[DROP] Not a directory or does not exist: \(fileURL.path)")
                        return
                    }
                    sidebarDropLogger.info("[DROP] Dispatching addDroppedRepositories for: \(fileURL.path)")
                    Task { @MainActor in
                        await model.addDroppedRepositories([fileURL])
                    }
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted && model.workspace != nil {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onCopyCommand {
            guard case .issue(let issueID) = model.selection,
                  let issue = model.runtimeIssues.first(where: { $0.id == issueID }) else {
                return []
            }
            let text = "\(issue.sourceTitle): \(issue.message)"
            return [NSItemProvider(object: text as NSString)]
        }
        .onAppear {
            normalizeSidebarSelectionIfNeeded()
        }
        .onChange(of: model.selection) { _, newValue in
            if let newValue {
                model.applySelectionSideEffects(newValue)
            }
            normalizeSidebarSelectionIfNeeded()
        }
    }

    private var workspaceSection: some View {
        Section {
            if let workspace = model.workspace {
                workspaceGroupedContent(workspace: workspace)
            } else {
                Text("Open a workspace to view services")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Workspace")
                Spacer()
                Menu {
                    Button("New Workspace…", systemImage: "folder.badge.plus") {
                        model.createWorkspacePicker()
                    }
                    Button("Open Workspace…", systemImage: "folder") {
                        model.openWorkspacePicker()
                    }
                    Divider()
                    Button("Clone Repository…", systemImage: "square.and.arrow.down") {
                        model.showCloneSheet = true
                    }
                    .disabled(model.workspace == nil)
                    Button("Create New Service…", systemImage: "plus.rectangle.on.folder") {
                        model.showCreateServiceSheet = true
                    }
                    .disabled(model.workspace == nil)
                    Divider()
                    Button("Add Directory…", systemImage: "folder.badge.plus") {
                        model.addDirectoryPicker()
                    }
                    .disabled(model.workspace == nil)
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help(model.workspace == nil ? "Create or open a workspace" : "Add Directory to Workspace")
            }
            .padding(.trailing, 8)
        }
    }

    private var actorTopologyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.cyan)
                .frame(width: 16)
            Text("Actor Topology")
            Spacer(minLength: 8)
            let connectionCount = model.flowConnections().count
            if connectionCount > 0 {
                Text("\(connectionCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.topology)
        }
        .tag(SelectionTarget.topology)
    }

    private var issuesSection: some View {
        Section {
            let issues = model.filteredRuntimeIssues()
            if issues.isEmpty {
                Text("No issues in this filter")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(issues) { issue in
                    issueRow(issue)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Issues")
                if let filter = model.issueListFilter {
                    Text(filter.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.hideIssueList()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Hide Issues")
            }
        }
    }

    private func issueRow(_ issue: RuntimeIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: issue.severity.symbol)
                    .foregroundStyle(issue.severity == .error ? .red : .yellow)
                Text(issue.sourceTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if issue.count > 1 {
                    Text("×\(issue.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SelectionTarget.issue(issue.id))
    }

    // MARK: - Service-Centric Workspace Content

    @ViewBuilder
    private func workspaceGroupedContent(workspace: AIBWorkspaceSnapshot) -> some View {
        let agents = workspace.services
            .filter { $0.serviceKind == .agent }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        let mcps = workspace.services
            .filter { $0.serviceKind == .mcp }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        let others = workspace.services
            .filter { $0.serviceKind == .unknown }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }

        let servicesByRepoID = Dictionary(grouping: workspace.services, by: \.repoID)
        let unconfiguredServices: [(id: String, runtime: String, repo: AIBRepoModel)] = workspace.repos
            .flatMap { repo -> [(id: String, runtime: String, repo: AIBRepoModel)] in
                let repoServices = servicesByRepoID[repo.id] ?? []
                // Build set of runtimes covered by configured services:
                // match by localID (auto-generated uses runtime as ID) or by inferring runtime from runCommand
                var configuredRuntimes = Set(repoServices.map(\.localID))
                for service in repoServices {
                    if let first = service.runCommand.first {
                        let inferred = RuntimeKind.fromCommand(first)
                        if inferred != .unknown {
                            configuredRuntimes.insert(inferred.rawValue)
                        }
                    }
                }
                return repo.detectedRuntimes
                    .filter { !configuredRuntimes.contains($0) }
                    .map { rt in (id: "\(repo.id)__\(rt)", runtime: rt, repo: repo) }
            }
            .sorted { $0.repo.name.localizedStandardCompare($1.repo.name) == .orderedAscending }

        if !agents.isEmpty {
            sidebarGroupHeader("Agents")
            ForEach(agents, id: \.id) { service in
                serviceRow(service)
            }
        }

        if !mcps.isEmpty {
            if !agents.isEmpty { sidebarSeparatorRow() }
            sidebarGroupHeader("MCP")
            ForEach(mcps, id: \.id) { service in
                serviceRow(service)
            }
        }

        if !others.isEmpty {
            if !agents.isEmpty || !mcps.isEmpty { sidebarSeparatorRow() }
            sidebarGroupHeader("Other")
            ForEach(others, id: \.id) { service in
                serviceRow(service)
            }
        }

        if !unconfiguredServices.isEmpty {
            if !agents.isEmpty || !mcps.isEmpty || !others.isEmpty { sidebarSeparatorRow() }
            sidebarGroupHeader("Unconfigured")
            ForEach(unconfiguredServices, id: \.id) { item in
                unconfiguredServiceRow(runtime: item.runtime, repo: item.repo)
            }
        }
    }

    private func serviceRow(_ service: AIBServiceModel) -> some View {
        let parentRepo = parentRepo(of: service)
        let runtime = parentRepo?.runtime ?? "unknown"
        return HStack(spacing: 8) {
            Image(systemName: iconName(for: runtime))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.packageName ?? service.localID)
                Text(service.namespacedID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.sidebarServiceStatus(for: service) == .starting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Service status: starting")
            } else if let badge = serviceStatusBadge(for: service) {
                StatusBadgeButton(badge: badge)
            }

            Button {
                model.select(.service(service.id))
                model.openInEditor()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(service.repoName) in Editor")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.service(service.id))
        }
        .tag(SelectionTarget.service(service.id))
        .contextMenu {
            Button("Open in Editor") {
                model.select(.service(service.id))
                model.openInEditor()
            }
            Divider()
            Button("Remove Service", role: .destructive) {
                model.requestRemoveService(
                    namespacedServiceID: service.namespacedID,
                    displayName: service.packageName ?? service.localID
                )
            }
        }
    }

    private func unconfiguredServiceRow(runtime: String, repo: AIBRepoModel) -> some View {
        let namespace = repo.name
        let namespacedID = "\(namespace)/\(runtime)"
        let displayName = repo.detectedPackageNames[runtime] ?? runtime
        return HStack(spacing: 8) {
            Image(systemName: iconName(for: runtime))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .foregroundStyle(.secondary)
                Text(namespacedID)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button {
                Task { await model.configureServices(repoID: repo.id, runtimes: [runtime]) }
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Configure \(displayName)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.repo(repo.id))
        }
        .tag(SelectionTarget.repo(repo.id))
        .contextMenu {
            Button("Configure Service") {
                Task { await model.configureServices(repoID: repo.id, runtimes: [runtime]) }
            }
            Button("Open in Editor") {
                model.select(.repo(repo.id))
                model.openInEditor()
            }
        }
    }

    // MARK: - Skills Section

    private func skillsSection(_ skills: [AIBSkillDefinition]) -> some View {
        Section {
            if skills.isEmpty {
                Text("No skills defined")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(skills, id: \.id) { skill in
                    skillRow(skill)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Skills")
                Spacer()
                Menu {
                    Button("New Skill") {
                        model.showAddSkillSheet = true
                    }
                    Button("Browse Registry…") {
                        model.showSkillRegistrySheet = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .help("Add Skill")
                .disabled(model.workspace == nil)
            }
            .padding(.trailing, 8)
        }
    }

    private func skillRow(_ skill: AIBSkillDefinition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.purple)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                if let desc = skill.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if skill.source == .executionDirectory {
                    Text("Discovered from execution directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tag(SelectionTarget.skill(skill.id))
        .draggable(Skill(
            name: skill.id,
            description: skill.description ?? "",
            allowedTools: skill.allowedTools.isEmpty ? nil : skill.allowedTools,
            body: skill.instructions ?? ""
        ))
        .contextMenu {
            if skill.isWorkspaceManaged {
                Button("Remove from Workspace", role: .destructive) {
                    Task { await model.removeSkillFromWorkspace(skillID: skill.id) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sidebarGroupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func sidebarSeparatorRow() -> some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func parentRepo(of service: AIBServiceModel) -> AIBRepoModel? {
        model.workspace?.repos.first(where: { $0.id == service.repoID })
    }

    private func normalizeSidebarSelectionIfNeeded() {
        guard case .file(let path) = model.selection else { return }
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        if let service = model.primaryWorkbenchService() {
            model.selection = .service(service.id)
        }
    }

    private func iconName(for runtime: String) -> String {
        switch runtime {
        case "swift": return "swift"
        case "node": return "server.rack"
        case "python": return "terminal"
        case "deno": return "network"
        default: return "questionmark.folder"
        }
    }

    private func serviceStatusBadge(for service: AIBServiceModel) -> (symbol: String, color: Color, help: String)? {
        guard let status = model.sidebarServiceStatus(for: service) else { return nil }
        let reason = model.sidebarServiceStatusReason(for: service)
        switch status {
        case .configured:
            return (
                symbol: "checkmark.seal.fill",
                color: .secondary,
                help: reason ?? "Configured"
            )
        case .starting:
            return nil
        case .running:
            return (
                symbol: "play.circle.fill",
                color: .secondary,
                help: reason ?? "Running"
            )
        case .warning:
            return (
                symbol: "exclamationmark.triangle.fill",
                color: .yellow,
                help: reason ?? "Warning"
            )
        case .error:
            return (
                symbol: "xmark.circle.fill",
                color: .red,
                help: reason ?? "Error"
            )
        }
    }
}

private struct StatusBadgeButton: View {
    var badge: (symbol: String, color: Color, help: String)
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: badge.symbol)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .foregroundStyle(badge.color)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            Text(badge.help)
                .font(.callout)
                .padding(8)
                .frame(minWidth: 160, maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
