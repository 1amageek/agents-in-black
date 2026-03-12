import AIBCore
import SwiftUI

/// Sheet for browsing and downloading skills from the remote registry.
struct SkillRegistrySheet: View {
    @Bindable var model: AgentsInBlackAppModel

    @State private var registrySkills: [AIBWorkspaceCore.RegistrySkillEntry] = []
    @State private var librarySkillIDs: Set<String> = []
    @State private var workspaceSkillIDs: Set<String> = []
    @State private var isLoading: Bool = true
    @State private var downloadingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var selectedEntry: AIBWorkspaceCore.RegistrySkillEntry?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading registry...")
                        Spacer()
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadData() }
                        }
                        Spacer()
                    }
                    .padding()
                } else {
                    skillList
                }
            }
            .navigationTitle("Skill Registry")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.showSkillRegistrySheet = false
                    }
                }
            }
            .navigationDestination(item: $selectedEntry) { entry in
                SkillRegistryDetailView(
                    entry: entry,
                    inWorkspace: workspaceSkillIDs.contains(entry.id),
                    isDownloading: downloadingIDs.contains(entry.id),
                    onAdd: {
                        await addToWorkspace(
                            id: entry.id,
                            needsDownload: !librarySkillIDs.contains(entry.id)
                        )
                    }
                )
            }
        }
        .frame(width: 560, height: 520)
        .task { await loadData() }
    }

    // MARK: - List

    private var skillList: some View {
        List {
            ForEach(registrySkills) { entry in
                registryRow(entry)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Row

    private func registryRow(_ entry: AIBWorkspaceCore.RegistrySkillEntry) -> some View {
        let inLibrary = librarySkillIDs.contains(entry.id)
        let inWorkspace = workspaceSkillIDs.contains(entry.id)
        let isDownloading = downloadingIDs.contains(entry.id)

        return HStack(spacing: 10) {
            // Clickable info area → navigates to detail
            Button {
                selectedEntry = entry
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(inLibrary || inWorkspace ? .purple : .secondary)
                        .font(.title3)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)

                        if let description = entry.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Action area
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else if inWorkspace {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Add") {
                    Task { await addToWorkspace(id: entry.id, needsDownload: !inLibrary) }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            registrySkills = try await model.listRegistrySkills()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }

        refreshLocalState()
        isLoading = false
    }

    private func refreshLocalState() {
        librarySkillIDs = Set(model.librarySkills().map(\.id))
        workspaceSkillIDs = Set(model.workspaceSkills().map(\.id))
    }

    private func addToWorkspace(id: String, needsDownload: Bool) async {
        downloadingIDs.insert(id)
        if needsDownload {
            await model.downloadRegistrySkill(id: id)
        }
        await model.importSkill(skillID: id)
        downloadingIDs.remove(id)
        refreshLocalState()
    }
}

// MARK: - Detail View

private struct SkillRegistryDetailView: View {
    let entry: AIBWorkspaceCore.RegistrySkillEntry
    let inWorkspace: Bool
    let isDownloading: Bool
    let onAdd: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(.purple)
                        .font(.largeTitle)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.title3.weight(.semibold))

                        Text(entry.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Status + Action
                actionSection

                Divider()

                // Description
                if let description = entry.description {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(description)
                            .font(.body)
                    }
                }

                // Tags
                if !entry.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(entry.name)
        .toolbarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var actionSection: some View {
        if isDownloading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Adding…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if inWorkspace {
            Label("Added to workspace", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Button {
                Task { await onAdd() }
            } label: {
                Label("Add to Workspace", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Hashable conformance for navigationDestination

extension AIBWorkspaceCore.RegistrySkillEntry: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}
