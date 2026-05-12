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

/// Compact deploy environment switcher for the header toolbar.
struct DeployEnvironmentToolbarMenu: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Menu {
            environmentSection
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe.asia.australia.fill")
                    .font(.system(size: 13))
                Text(model.displayDeployEnvironmentName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if model.isSwitchingDeployEnvironment || model.isRefreshingGCloudContext {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .disabled(model.workspace == nil || model.detectedProvider?.providerID != "gcp-cloudrun")
        .help(helpText)
    }

    @ViewBuilder
    private var environmentSection: some View {
        Section("Deploy Environment") {
            if model.deployEnvironmentOptions.isEmpty {
                Text("No environments")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.deployEnvironmentOptions) { option in
                    Button {
                        Task { await model.switchDeployEnvironment(to: option.name) }
                    } label: {
                        if option.name == model.selectedDeployEnvironmentName {
                            Label(option.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(option.displayTitle)
                        }
                    }
                    .disabled(model.isSwitchingDeployGCloudContext)
                }
            }
        }
    }

    private var helpText: String {
        let environment = model.displayDeployEnvironmentName
        let project = model.displayDeployGCloudProject ?? "No project"
        return "Deploy environment: \(environment), \(project)"
    }
}

/// Compact Google account and Cloud Run service account switcher for the header toolbar.
struct DeployAccountToolbarMenu: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Menu {
            googleAccountSection
            Divider()
            serviceAccountSection
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 13))
                Text(accountLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                if model.isSigningInGCloudAccount || model.isSwitchingGCloudAccount || model.isSwitchingGCloudServiceAccount {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .disabled(model.workspace == nil || model.detectedProvider?.providerID != "gcp-cloudrun")
        .help(helpText)
    }

    @ViewBuilder
    private var googleAccountSection: some View {
        Section("Google Account") {
            Button {
                Task { await model.signInGCloudAccount() }
            } label: {
                if model.isSigningInGCloudAccount {
                    Label("Signing In...", systemImage: "hourglass")
                } else {
                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                }
            }
            .disabled(model.isSwitchingDeployGCloudContext)

            if model.gcloudAccounts.isEmpty {
                Text("No accounts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.gcloudAccounts) { account in
                    Button {
                        Task { await model.switchGCloudAccount(to: account.account) }
                    } label: {
                        if account.account == model.activeGCloudAccount {
                            Label(account.account, systemImage: "checkmark")
                        } else {
                            Text(account.account)
                        }
                    }
                    .disabled(model.isSwitchingDeployGCloudContext)
                }
            }
        }
    }

    @ViewBuilder
    private var serviceAccountSection: some View {
        Section("Cloud Run Service Account") {
            Button {
                Task { await model.switchGCloudServiceAccount(to: nil) }
            } label: {
                if model.displayDeployGCloudServiceAccount == nil {
                    Label("Use Environment Default", systemImage: "checkmark")
                } else {
                    Text("Use Environment Default")
                }
            }
            .disabled(model.isSwitchingDeployGCloudContext)

            if model.gcloudServiceAccounts.isEmpty {
                Text("No service accounts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.gcloudServiceAccounts) { serviceAccount in
                    Button {
                        Task { await model.switchGCloudServiceAccount(to: serviceAccount.email) }
                    } label: {
                        let title = serviceAccountTitle(serviceAccount)
                        if serviceAccount.email == model.displayDeployGCloudServiceAccount {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                    .disabled(model.isSwitchingDeployGCloudContext)
                }
            }
        }
    }

    private var accountLabel: String {
        guard let account = model.activeGCloudAccount, !account.isEmpty else {
            return "No Account"
        }
        return account
    }

    private var helpText: String {
        let account = model.activeGCloudAccount ?? "No Google account"
        let serviceAccount = model.displayDeployGCloudServiceAccount ?? "Environment default service account"
        return "Deploy account: \(account), \(serviceAccount)"
    }

    private func serviceAccountTitle(_ serviceAccount: GCloudServiceAccount) -> String {
        guard let displayName = serviceAccount.displayName, !displayName.isEmpty else {
            return serviceAccount.email
        }
        return "\(displayName) (\(serviceAccount.email))"
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
