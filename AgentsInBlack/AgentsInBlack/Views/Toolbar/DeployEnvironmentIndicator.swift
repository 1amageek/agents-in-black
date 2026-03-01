import AIBCore
import SwiftUI

/// Docker status indicator with runtime selector dropdown.
/// Shows the selected Docker runtime icon and status color.
/// Menu lists installed runtimes for selection and a launch action when Docker is not running.
struct DockerStatusIndicator: View {
    @Bindable var model: AgentsInBlackAppModel

    private var result: PreflightCheckResult? { model.dockerCheckResult }
    private var isChecking: Bool { model.isCheckingEnvironment }

    private var isFailed: Bool {
        guard let result else { return false }
        return result.isFailed
    }

    var body: some View {
        Menu {
            Section("Docker Runtime") {
                ForEach(model.installedDockerRuntimes) { runtime in
                    Button {
                        model.selectDockerRuntime(runtime)
                    } label: {
                        Label {
                            Text(runtime.name)
                        } icon: {
                            if let icon = runtime.icon {
                                Image(nsImage: icon)
                            }
                        }
                    }
                }
            }

            if model.installedDockerRuntimes.isEmpty {
                Text("No Docker runtime found")
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 4) {
                if let runtime = model.preferredDockerRuntime, let icon = runtime.icon {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 13))
                }
                statusDot
            }
            .symbolEffect(.pulse, isActive: isChecking)
        } primaryAction: {
            if isFailed {
                model.launchDockerRuntime()
            }
        }
        .menuStyle(.borderlessButton)
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
        let runtimeName = model.preferredDockerRuntime?.name ?? "Docker"
        if isChecking { return "\(runtimeName): Checking..." }
        guard let result else { return runtimeName }
        if isFailed { return "\(runtimeName): Not Running" }
        return "\(runtimeName): \(statusLabel(for: result))"
    }
}

/// Cloud provider status indicator for the toolbar.
/// Shown when a provider is detected. Clicking opens Cloud Settings.
struct CloudProviderStatusIndicator: View {
    let result: PreflightCheckResult?
    let provider: (any DeploymentProvider)?
    let isChecking: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "cloud")
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
        let name = provider?.displayName ?? "Cloud"
        if isChecking { return "\(name): Checking..." }
        guard let result else { return name }
        return "\(name): \(statusLabel(for: result))"
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
