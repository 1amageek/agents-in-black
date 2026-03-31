import AIBCore
import AIBRuntimeCore
import SwiftUI

/// Xcode-style toolbar center with service picker (left) and activity status (right).
///
/// Left: Service picker — dropdown to select and navigate to any service.
/// Right: Activity status — emulator state + issue counts (only when > 0).
struct ToolbarActivityView: View {
    @Bindable var model: AgentsInBlackAppModel

    private var hasErrors: Bool { model.issueCount(for: .error) > 0 }
    private var hasWarnings: Bool { model.issueCount(for: .warning) > 0 }

    var body: some View {
        if model.workspace != nil {
            HStack(spacing: 12) {
                servicePicker

                Spacer()
                HStack(spacing: 8) {
                    activityLabel

                    if model.emulatorState.isRunning {
                        serviceCountBadge
                    }

                    if hasErrors {
                        issueButton(severity: .error, count: model.issueCount(for: .error))
                    }

                    if hasWarnings {
                        issueButton(severity: .warning, count: model.issueCount(for: .warning))
                    }

                    Divider()

                    EditorStatusIndicator(model: model)
                    BuildBackendStatusIndicator(model: model)
                    CloudProviderStatusIndicator(
                        result: model.cloudProviderCheckResult,
                        provider: model.detectedProvider,
                        isChecking: model.isCheckingEnvironment,
                        onTap: { model.openCloudSettings() }
                    )
                }
                .padding(.trailing, 6)
            }
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Service Picker (Left)

    private var servicePicker: some View {
        Menu {
            servicePickerContent
        } label: {
            HStack(spacing: 4) {
                if let service = model.selectedService() {
                    Image(systemName: serviceKindIcon(for: service.serviceKind))
                    Text(service.namespacedID)
                        .lineLimit(1)
                } else if let workspace = model.workspace {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(workspace.displayName)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: .bold))
        }
        .controlSize(.regular)
        .fixedSize()
    }

    @ViewBuilder
    private var servicePickerContent: some View {
        let services = model.workspace?.services ?? []
        let agents = services.filter { $0.serviceKind == .agent }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }
        let mcpServices = services.filter { $0.serviceKind == .mcp }
            .sorted { $0.namespacedID.localizedStandardCompare($1.namespacedID) == .orderedAscending }

        if !agents.isEmpty {
            Section("Agents") {
                ForEach(agents, id: \.id) { service in
                    servicePickerRow(service)
                }
            }
        }

        if !mcpServices.isEmpty {
            Section("MCP Servers") {
                ForEach(mcpServices, id: \.id) { service in
                    servicePickerRow(service)
                }
            }
        }
    }

    private func servicePickerRow(_ service: AIBServiceModel) -> some View {
        let isSelected = model.selectedService()?.id == service.id
        let snapshot = model.serviceSnapshot(for: service)
        return Button {
            model.select(.service(service.id))
        } label: {
            Label {
                HStack {
                    Text(service.namespacedID)
                    Spacer()
                    if let state = snapshot?.lifecycleState {
                        Image(systemName: lifecycleIcon(for: state))
                            .font(.caption2)
                            .foregroundStyle(lifecycleColor(for: state))
                    }
                }
            } icon: {
                if isSelected {
                    Image(systemName: "checkmark")
                } else {
                    Image(systemName: serviceKindIcon(for: service.serviceKind))
                        .foregroundStyle(serviceKindColor(for: service.serviceKind))
                }
            }
        }
    }

    // MARK: - Activity Label (Right)

    private var activityLabel: some View {
        HStack(spacing: 5) {
            activityIndicator
            Text(activityLabelText)
                .font(.caption.weight(.medium))
                .foregroundStyle(activityColor)
                .lineLimit(1)
        }
    }

    private var activityLabelText: String {
        if case .starting = model.emulatorState,
           model.kernelDownloadProgress != nil
        {
            return "Downloading kernel..."
        }
        return model.emulatorState.label
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch model.emulatorState {
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
        case .starting:
            if let progress = model.kernelDownloadProgress {
                ProgressView(progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        case .stopping:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
        case .stopped:
            EmptyView()
        }
    }

    private var activityColor: some ShapeStyle {
        switch model.emulatorState {
        case .error: AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    // MARK: - Service Count Badge

    private var serviceCountBadge: some View {
        let ready = model.serviceSnapshotsByID.values.filter { $0.lifecycleState == .ready }.count
        let total = model.workspace?.services.count ?? 0
        return Text("\(ready)/\(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: - Issue Buttons

    private func issueButton(severity: RuntimeIssueSeverity, count: Int) -> some View {
        Button {
            model.showIssueList(filter: severity)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: severity.symbol)
                    .font(.caption)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(severity == .error ? .red : .yellow)
        }
        .buttonStyle(.plain)
        .help("Show \(severity == .error ? "errors" : "warnings") in sidebar")
    }

    // MARK: - Styling Helpers

    private func serviceKindIcon(for kind: AIBServiceKind) -> String {
        switch kind {
        case .agent: "sparkles"
        case .mcp: "wrench.and.screwdriver"
        case .unknown: "square.stack.3d.up"
        }
    }

    private func serviceKindColor(for kind: AIBServiceKind) -> Color {
        switch kind {
        case .agent: .mint
        case .mcp: .cyan
        case .unknown: .secondary
        }
    }

    private func lifecycleIcon(for state: LifecycleState?) -> String {
        switch state {
        case .ready: "circle.fill"
        case .starting, .draining, .stopping: "circle.dotted"
        case .unhealthy, .backoff: "exclamationmark.circle.fill"
        case .stopped, .none: "circle"
        }
    }

    private func lifecycleColor(for state: LifecycleState?) -> Color {
        switch state {
        case .ready: .green
        case .starting, .draining, .stopping: .orange
        case .unhealthy, .backoff: .red
        case .stopped, .none: .secondary
        }
    }
}
