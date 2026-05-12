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

/// Compact Google account switcher for the header toolbar.
struct DeployGoogleAccountToolbarMenu: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Menu {
            googleAccountSection
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 13))
                Text(accountLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                if model.isSigningInGCloudAccount || model.isSwitchingGCloudAccount {
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

    private var accountLabel: String {
        guard let account = model.activeGCloudAccount, !account.isEmpty else {
            return "No Account"
        }
        return account
    }

    private var helpText: String {
        let account = model.activeGCloudAccount ?? "No Google account"
        return "Google account: \(account)"
    }
}

/// Compact deploy project switcher for the header toolbar.
struct DeployProfileToolbarMenu: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Menu {
            deployProfileSection
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13))
                Text(profileLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                if model.isSwitchingDeployProfile {
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
    private var deployProfileSection: some View {
        Section("Deploy Project") {
            if model.deployProfiles.isEmpty {
                Text("No deploy projects")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.deployProfiles) { profile in
                    Button {
                        Task { await model.switchDeployProfile(to: profile.name) }
                    } label: {
                        let title = profileTitle(profile)
                        if profile.name == model.activeDeployProfile?.name {
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

    private var profileLabel: String {
        if let profile = model.activeDeployProfile {
            return profile.gcpProject
        }
        return model.displayDeployGCloudProject ?? "No Project"
    }

    private var helpText: String {
        if let profile = model.activeDeployProfile {
            return "Deploy project: \(profile.gcpProject), region: \(profile.region)"
        }
        return "Deploy project: \(model.displayDeployGCloudProject ?? "none")"
    }

    private func profileTitle(_ profile: AIBDeployProfile) -> String {
        if let firebaseProject = profile.firebaseProject, firebaseProject != profile.gcpProject {
            return "\(profile.name) (\(profile.gcpProject), Firebase: \(firebaseProject))"
        }
        return "\(profile.name) (\(profile.gcpProject))"
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
