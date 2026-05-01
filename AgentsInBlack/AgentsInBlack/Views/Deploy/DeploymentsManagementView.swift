import AIBCore
import SwiftUI

struct DeploymentsManagementView: View {
    @Bindable var model: AgentsInBlackAppModel
    @State private var pendingDelete: PendingDelete?

    private struct PendingDelete: Identifiable {
        let id: String
        let serviceName: String
        let region: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            model.refreshDeploymentsInventory()
        }
        .confirmationDialog(
            "Delete Deployed Service",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { newValue in if !newValue { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("Delete \(target.serviceName) (\(target.region))", role: .destructive) {
                model.deleteDeployment(serviceName: target.serviceName, region: target.region)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { target in
            Text("This permanently removes the Cloud Run service \"\(target.serviceName)\" in \(target.region). This action cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Deployments", systemImage: "icloud.fill")
                .font(.title3.weight(.semibold))
            Spacer()
            if let last = model.deploymentsController.lastRefreshedAt {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                model.refreshDeploymentsInventory()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.deploymentsController.state.isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.deploymentsController.state {
        case .idle:
            placeholder("Select Refresh to load deployments.", systemImage: "icloud")
        case .loading where model.deploymentsController.services.isEmpty:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading deployments…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Label("Failed to load deployments", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Retry") {
                    model.refreshDeploymentsInventory()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .loaded:
            tableContent
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        ContentUnavailableView(text, systemImage: systemImage)
    }

    @ViewBuilder
    private var tableContent: some View {
        let entries = sortedEntries
        if entries.isEmpty {
            ContentUnavailableView(
                "No Deployments",
                systemImage: "icloud.slash",
                description: Text("This Google Cloud project has no Cloud Run services deployed yet.")
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    tableHeaderRow
                    Divider()
                    ForEach(entries) { entry in
                        Divider().opacity(entry == entries.first ? 0 : 1)
                        row(for: entry)
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    /// Drift entries sorted by status severity, then service name, then region
    /// (for stable ordering across multi-region deployments of the same name).
    private var sortedEntries: [DeploymentDriftEntry] {
        model.deploymentsController.drift.entries
            .sorted { lhs, rhs in
                let lhsRank = severityRank(lhs.status)
                let rhsRank = severityRank(rhs.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let nameOrder = lhs.serviceName.localizedStandardCompare(rhs.serviceName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                let lhsRegion = lhs.deployed?.region ?? ""
                let rhsRegion = rhs.deployed?.region ?? ""
                return lhsRegion.localizedStandardCompare(rhsRegion) == .orderedAscending
            }
    }

    private func severityRank(_ status: DeploymentDriftStatus) -> Int {
        switch status {
        case .imageStale: return 0
        case .regionMismatch: return 1
        case .orphan: return 2
        case .missing: return 3
        case .inSync: return 4
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 12) {
            Text("Service").frame(width: 220, alignment: .leading)
            Text("Region").frame(width: 130, alignment: .leading)
            Text("Image").frame(maxWidth: .infinity, alignment: .leading)
            Text("Updated").frame(width: 160, alignment: .leading)
            Text("Status").frame(width: 160, alignment: .leading)
            Spacer().frame(width: 80)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func row(for entry: DeploymentDriftEntry) -> some View {
        let live = entry.deployed
        let region = live?.region ?? "—"
        let image = live?.image ?? "—"
        let updatedText: String = {
            guard let date = live?.lastDeployedAt else { return "—" }
            return date.formatted(date: .abbreviated, time: .shortened)
        }()
        let deletionState: AIBDeploymentsController.DeletionState = {
            guard let live else { return .idle }
            return model.deploymentsController.deletionState(
                serviceName: live.name,
                region: live.region
            )
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.serviceName)
                        .font(.system(.body, design: .monospaced))
                    if let ref = entry.serviceRef {
                        Text(ref)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 220, alignment: .leading)

                Text(region)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 130, alignment: .leading)

                Text(image)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(image)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)

                statusPill(for: entry.status)
                    .frame(width: 160, alignment: .leading)

                deleteButton(entry: entry, deletionState: deletionState)
                    .frame(width: 80, alignment: .trailing)
            }

            if let live, let url = live.url {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 232)
                    .help(url)
            }

            if case .failed(let message) = deletionState, let live {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") {
                        model.deploymentsController.dismissDeletionError(
                            serviceName: live.name,
                            region: live.region
                        )
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 232)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusPill(for status: DeploymentDriftStatus) -> some View {
        switch status {
        case .inSync:
            pill("In sync", color: .green, icon: "checkmark.circle.fill")
        case .orphan:
            pill("Orphan", color: .orange, icon: "questionmark.circle.fill")
        case .missing:
            pill("Missing", color: .gray, icon: "minus.circle.fill")
        case .regionMismatch(let deployedRegion, let expected):
            pill("Region: \(deployedRegion)→\(expected)", color: .red, icon: "arrow.triangle.2.circlepath")
        case .imageStale:
            pill("Image stale", color: .yellow, icon: "clock.badge.exclamationmark.fill")
        }
    }

    private func pill(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func deleteButton(entry: DeploymentDriftEntry, deletionState: AIBDeploymentsController.DeletionState) -> some View {
        if let live = entry.deployed {
            Button {
                pendingDelete = PendingDelete(
                    id: "\(live.region)/\(live.name)",
                    serviceName: live.name,
                    region: live.region
                )
            } label: {
                if deletionState == .deleting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .disabled(deletionState == .deleting)
            .help("Delete \(live.name) in \(live.region)")
        } else {
            EmptyView()
        }
    }
}
