import AIBCore
import AIBRuntimeCore
import SwiftUI

struct WorkspaceSidebarView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        List(selection: $model.selection) {
            actorTopologyRow
            if model.showIssuesInSidebar {
                issuesSection
            }
            workspaceSection
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
                Text("Open a workspace to view repositories")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Workspace")
                Spacer()
                Button {
                    model.addRepositoryPicker()
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .clipShape(Capsule())
                .help("Add Repository to Workspace")
                .disabled(model.workspace == nil)
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
        Button {
            model.selectIssue(issue)
        } label: {
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
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open issue location")
    }

    @ViewBuilder
    private func workspaceGroupedContent(workspace: AIBWorkspaceSnapshot) -> some View {
        let agents = workspace.repos.filter { repoCategory(for: $0) == .agent }
        let mcps = workspace.repos.filter { repoCategory(for: $0) == .mcp }
        let others = workspace.repos.filter { repoCategory(for: $0) == .other }

        if !agents.isEmpty {
            sidebarGroupHeader("Agents")
            repoListRows(agents)
        }

        if !mcps.isEmpty {
            if !agents.isEmpty { sidebarSeparatorRow() }
            sidebarGroupHeader("MCP")
            repoListRows(mcps)
        }

        if !others.isEmpty {
            if !agents.isEmpty || !mcps.isEmpty { sidebarSeparatorRow() }
            sidebarGroupHeader("Other")
            repoListRows(others)
        }
    }

    @ViewBuilder
    private func repoListRows(_ repos: [AIBRepoModel]) -> some View {
        ForEach(repos, id: \.id) { repo in
            repoRow(repo)
        }
    }

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

    private func repoRow(_ repo: AIBRepoModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: repo.runtime))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                Text("\(repo.runtime)/\(repo.framework)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.sidebarStatus(for: repo) == .starting {
                ProgressView()
                    .controlSize(.mini)
                    .help("Runtime status: starting")
            } else if let badge = repoStatusBadge(for: repo) {
                Image(systemName: badge.symbol)
                    .foregroundStyle(badge.color)
                    .help(badge.help)
            }

            Button {
                model.select(.repo(repo.id))
                model.openInEditor()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(repo.name) in Editor")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.repo(repo.id))
        }
        .tag(SelectionTarget.repo(repo.id))
        .contextMenu {
            Button("Open in Editor") {
                model.select(.repo(repo.id))
                model.openInEditor()
            }
        }
    }

    private func servicesForRepo(_ repo: AIBRepoModel) -> [AIBServiceModel] {
        guard let workspace = model.workspace else { return [] }
        return workspace.services
            .filter { $0.repoID == repo.id }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
    }

    private enum RepoCategory {
        case agent
        case mcp
        case other
    }

    private func repoCategory(for repo: AIBRepoModel) -> RepoCategory {
        let services = servicesForRepo(repo)
        if services.contains(where: { $0.serviceKind == .agent }) {
            return .agent
        }
        if services.contains(where: { $0.serviceKind == .mcp }) {
            return .mcp
        }

        if services.contains(where: { $0.mountPath.hasPrefix("/agents/") }) {
            return .agent
        }
        if services.contains(where: { $0.mountPath.hasPrefix("/mcp/") }) {
            return .mcp
        }
        return .other
    }

    private func normalizeSidebarSelectionIfNeeded() {
        guard case .file(let path) = model.selection else { return }
        if FileManager.default.fileExists(atPath: path) {
            return
        }
        if let service = model.primaryWorkbenchService() {
            model.selection = .service(service.id)
            return
        }
        if let repo = model.selectedRepo() {
            model.selection = .repo(repo.id)
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

    private func repoStatusBadge(for repo: AIBRepoModel) -> (symbol: String, color: Color, help: String)? {
        guard let status = model.sidebarStatus(for: repo) else { return nil }
        switch status {
        case .configured:
            return (
                symbol: "checkmark.seal.fill",
                color: .secondary,
                help: "Workspace status: configured"
            )
        case .starting:
            return nil
        case .running:
            return (
                symbol: "play.circle.fill",
                color: .secondary,
                help: "Runtime status: running"
            )
        case .warning:
            return (
                symbol: "exclamationmark.triangle.fill",
                color: .yellow,
                help: "Runtime status: warning"
            )
        case .error:
            return (
                symbol: "xmark.circle.fill",
                color: .red,
                help: "Runtime status: error"
            )
        }
    }
}
