import AIBCore
import SwiftUI

/// Build backend status indicator for apple/container.
struct BuildBackendStatusIndicator: View {
    @Bindable var model: AgentsInBlackAppModel

    private var result: PreflightCheckResult? { model.buildBackendCheckResult }
    private var isChecking: Bool { model.isCheckingEnvironment }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
            statusDot
        }
        .symbolEffect(.pulse, isActive: isChecking)
        .fixedSize()
        .help(tooltipText)
    }

    // MARK: - Status Dot

    @ViewBuilder
    private var statusDot: some View {
        if !isChecking, result != nil {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
        }
    }

    private var dotColor: Color {
        guard let result else { return .secondary }
        switch result.status {
        case .passed: return .green
        case .failed: return .red
        case .warning: return .yellow
        case .skipped, .pending, .running: return .secondary
        }
    }

    // MARK: - Tooltip

    private var tooltipText: String {
        let backendName = "apple/container"
        if isChecking { return "\(backendName): Checking..." }
        guard let result else { return backendName }
        return "\(backendName): \(statusLabel(for: result))"
    }
}

struct EditorStatusIndicator: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Menu {
            Section("Editor") {
                ForEach(model.installedEditorApps) { editor in
                    Button {
                        model.selectEditorApp(editor)
                    } label: {
                        Label {
                            Text(editor.name)
                        } icon: {
                            if let icon = editor.icon {
                                Image(nsImage: icon)
                            }
                        }
                    }
                }
            }

            if model.installedEditorApps.isEmpty {
                Text("No editor found")
                    .foregroundStyle(.secondary)
            }
        } label: {
            if let editor = model.preferredEditorApp,
               let icon = editor.icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
            }
        } primaryAction: {
            model.launchEditorApp()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltipText)
    }

    private var tooltipText: String {
        let editorName = model.preferredEditorApp?.name ?? "Editor"
        return "Open with \(editorName)"
    }
}

/// Target settings status indicator for the toolbar.
/// Clicking opens Target Settings.
struct CloudProviderStatusIndicator: View {
    let result: PreflightCheckResult?
    let provider: (any DeploymentProvider)?
    let isChecking: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
                .frame(width: 20, height: 20)
                .foregroundStyle(statusColor(for: result, isChecking: isChecking))
                .symbolEffect(.pulse, isActive: isChecking)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipText)
    }

    private var tooltipText: String {
        let name = provider?.displayName ?? "Target Settings"
        if isChecking { return "\(name): Checking..." }
        guard let result else { return "Target Settings" }
        return "Target Settings: \(statusLabel(for: result))"
    }
}

// MARK: - Shared

private func statusColor(for result: PreflightCheckResult?, isChecking: Bool) -> some ShapeStyle {
    if isChecking { return AnyShapeStyle(.secondary) }
    guard let result else { return AnyShapeStyle(.tertiary) }
    switch result.status {
    case .passed: return AnyShapeStyle(.green)
    case .failed: return AnyShapeStyle(.red)
    case .warning: return AnyShapeStyle(.yellow)
    case .skipped, .pending, .running: return AnyShapeStyle(.secondary)
    }
}

private func statusLabel(for result: PreflightCheckResult) -> String {
    switch result.status {
    case .passed: "Ready"
    case .failed: "Not Available"
    case .warning: "Warning"
    case .skipped: "Skipped"
    case .pending, .running: "Checking..."
    }
}
