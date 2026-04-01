import AIBCore
import AIBRuntimeCore
import AIBWorkspace
import SwiftUI

/// Target configuration panel.
/// Accessible from the menu bar (Target > Target Settings...).
/// Validates gcloud environment using the same preflight checkers as the deploy pipeline,
/// then allows editing deploy target configuration persisted in `.aib/targets/{providerID}.yaml`.
struct CloudSettingsView: View {
    let workspaceRootPath: String
    let sourceAuthRequirements: [WorkspaceSourceAuthRequirement]
    let onDismiss: () -> Void

    // MARK: - Environment Check State

    @State private var environmentChecks: [PreflightCheckID: PreflightCheckResult] = [:]
    @State private var isCheckingEnvironment: Bool = false
    @State private var isInstallingAppleContainer: Bool = false
    @State private var isStartingBuilder: Bool = false
    @State private var appleContainerInstallMessage: String?
    @State private var appleContainerInstallFailed: Bool = false

    // MARK: - GCloud Context State

    @State private var gcloudAccounts: [GCloudAccount] = []
    @State private var gcloudProjects: [GCloudProject] = []
    @State private var activeGCloudAccount: String?
    @State private var activeGCloudProject: String?
    @State private var isRefreshingGCloudContext: Bool = false
    @State private var isSwitchingGCloudAccount: Bool = false
    @State private var isSwitchingGCloudProject: Bool = false
    @State private var gcloudContextErrorMessage: String?

    // MARK: - Config State

    @State private var providerID: String = "gcp-cloudrun"
    @State private var gcpProject: String = ""
    @State private var region: String = "us-central1"
    @State private var authMode: AIBDeployAuthMode = .private
    @State private var buildMode: AIBBuildMode = .strict
    @State private var kindDefaults: [AIBServiceKind: AIBDeployResourceConfig] = [:]
    @State private var selectedKind: AIBServiceKind = .agent
    @State private var artifactRegistryHost: String = ""
    @State private var sourceAuthHost: String = "github.com"
    @State private var localSourceAuthMethod: LocalSourceAuthMethod = .sshKey
    @State private var localPrivateKeyPath: String = ""
    @State private var localKnownHostsPath: String = ""
    @State private var localPassphraseMode: LocalSourceAuthPassphraseMode = .none
    @State private var localManagedPassphrase: String = ""
    @State private var localExternalPassphraseEnvironmentKey: String = ""
    @State private var persistedLocalPassphraseEnvironmentKey: String = ""
    @State private var persistedLocalPassphraseWasAppManaged: Bool = false
    @State private var localAccessTokenMode: LocalSourceAuthPassphraseMode = .none
    @State private var localManagedAccessToken: String = ""
    @State private var localExternalAccessTokenEnvironmentKey: String = ""
    @State private var persistedLocalAccessTokenEnvironmentKey: String = ""
    @State private var persistedLocalAccessTokenWasAppManaged: Bool = false
    @State private var persistedSourceAuthHost: String = "github.com"
    @State private var loadedSourceCredentials: [AIBSourceCredential] = []
    @State private var cloudPrivateKeySecret: String = ""
    @State private var cloudKnownHostsSecret: String = ""
    @State private var isProvisioningCloudSourceAuth: Bool = false
    @State private var cloudSourceAuthProvisionMessage: String?
    @State private var cloudSourceAuthProvisionFailed: Bool = false
    @State private var useHostCorepackCache: Bool = true
    @State private var useHostPNPMStore: Bool = true
    @State private var useRepoLocalPNPMStore: Bool = true

    @State private var errorMessage: String?
    @State private var hasLoadedInitial: Bool = false

    private let configStore: DeployTargetConfigStore = DefaultDeployTargetConfigStore()
    private let gcloudContextService = GCloudContextService()
    private let targetSourceAuthKeychainStore = TargetSourceAuthKeychainStore()
    private let localSourceAuthValidationService = LocalSourceAuthValidationService()
    private let cloudSourceAuthBootstrapService = CloudSourceAuthBootstrapService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    providerSection
                    if providerID != "local" {
                        environmentSection
                    }
                    configSection
                    resourceDefaultsSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .task {
            loadConfig()
            async let checks: Void = runEnvironmentChecks()
            async let context: Void = refreshGCloudContext()
            _ = await (checks, context)
        }
        .onChange(of: providerID) { _, _ in
            resetFormDefaults(for: providerID)
            loadConfig(force: true)
            Task {
                await runEnvironmentChecks()
                await refreshGCloudContext()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Target Settings")
                    .font(.headline)
                Text("Target configuration for local runtime and cloud deploy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider")
                .font(.subheadline.weight(.medium))

            Picker("Provider", selection: $providerID) {
                Text("Local Emulator").tag("local")
                ForEach(DeploymentProviderRegistry.providers, id: \.providerID) { provider in
                    Text(provider.displayName).tag(provider.providerID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: - Environment

    /// Ordered check IDs for display.
    private var environmentCheckIDs: [PreflightCheckID] {
        guard let provider = DeploymentProviderRegistry.provider(for: providerID) else { return [] }
        return provider.preflightCheckers()
            .map(\.checkID)
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isCheckingEnvironment {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Recheck") {
                        Task { await runEnvironmentChecks() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(environmentCheckIDs.enumerated()), id: \.element) { index, checkID in
                    if index > 0 {
                        Divider().padding(.leading, 28)
                    }
                    environmentCheckRow(id: checkID)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let appleContainerInstallMessage {
                Text(appleContainerInstallMessage)
                    .font(.caption)
                    .foregroundStyle(appleContainerInstallFailed ? .red : .secondary)
                    .padding(.leading, 2)
            }
        }
    }

    private func environmentCheckRow(id: PreflightCheckID) -> some View {
        let result = environmentChecks[id]

        return VStack(alignment: .leading, spacing: 6) {
            // Status line: icon + title + detail
            HStack(spacing: 8) {
                checkStatusIcon(for: id)
                    .frame(width: 16)

                Text(result?.title ?? id.rawValue)
                    .font(.callout)

                Spacer()

                // Show detected value for passed checks
                if let result, case .passed(let detail) = result.status, let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Failure detail: error message + remediation
            if let result {
                switch result.status {
                case .failed(let message):
                    failureDetail(message: message, result: result)
                case .skipped(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func failureDetail(message: String, result: PreflightCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Error description
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, 24)

            // Remediation command (shown inline, not hidden)
            if let command = result.remediationCommand {
                HStack(spacing: 0) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy command")
                    .padding(.trailing, 6)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .padding(.leading, 24)
            }

            if result.id == .buildBackendAvailable {
                let isCLINotInstalled: Bool = {
                    if case .failed(let msg) = result.status {
                        return msg.contains("not installed")
                    }
                    return false
                }()

                if isCLINotInstalled {
                    Button {
                        Task { await installLatestAppleContainer() }
                    } label: {
                        if isInstallingAppleContainer {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing latest apple/container...")
                                    .font(.caption)
                            }
                        } else {
                            Text("Install Latest apple/container")
                                .font(.caption)
                        }
                    }
                    .disabled(isInstallingAppleContainer)
                    .padding(.leading, 24)
                } else {
                    Button {
                        Task { await startBuilder() }
                    } label: {
                        if isStartingBuilder {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Starting builder...")
                                    .font(.caption)
                            }
                        } else {
                            Text("Start Builder")
                                .font(.caption)
                        }
                    }
                    .disabled(isStartingBuilder)
                    .padding(.leading, 24)
                }
            }

            // Documentation link
            if let url = result.remediationURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Installation guide")
                            .font(.caption)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private func checkStatusIcon(for id: PreflightCheckID) -> some View {
        if let result = environmentChecks[id] {
            switch result.status {
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            case .skipped:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .pending, .running:
                ProgressView()
                    .controlSize(.small)
            }
        } else if isCheckingEnvironment {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Config

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(providerID == "local" ? "Local Target" : "Configuration")
                .font(.subheadline.weight(.medium))

            LabeledContent("Build Mode") {
                Picker("Build Mode", selection: $buildMode) {
                    Text("Strict").tag(AIBBuildMode.strict)
                    Text("Convenience").tag(AIBBuildMode.convenience)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            if buildMode == .convenience {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Reuse host corepack cache", isOn: $useHostCorepackCache)
                    Toggle("Reuse host pnpm store", isOn: $useHostPNPMStore)
                    Toggle("Reuse repo-local .pnpm-store", isOn: $useRepoLocalPNPMStore)
                    Text("Convenience mode is local-only and not Cloud Run-aligned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if providerID == "local" {
                localSourceAuthSection
            } else {
                cloudSourceAuthSection
            }

            if providerID == "gcp-cloudrun" {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        configContextRow(
                            title: "Account",
                            value: activeGCloudAccount ?? "No active Google account"
                        ) {
                            Menu("Switch") {
                                ForEach(gcloudAccounts) { account in
                                    Button {
                                        Task { await switchAccount(to: account.account) }
                                    } label: {
                                        if account.account == activeGCloudAccount {
                                            Label(account.account, systemImage: "checkmark")
                                        } else {
                                            Text(account.account)
                                        }
                                    }
                                }
                            }
                            .disabled(
                                isRefreshingGCloudContext
                                || isSwitchingGCloudAccount
                                || isSwitchingGCloudProject
                                || gcloudAccounts.isEmpty
                            )
                        }

                        Divider().padding(.leading, 12)

                        configContextRow(
                            title: "Project",
                            value: gcpProject.isEmpty ? "No project selected" : gcpProject
                        ) {
                            Menu("Switch") {
                                ForEach(gcloudProjects) { project in
                                    Button {
                                        Task { await switchProject(to: project.projectID) }
                                    } label: {
                                        let label = project.name ?? project.projectID
                                        if project.projectID == gcpProject {
                                            Label("\(label) (\(project.projectID))", systemImage: "checkmark")
                                        } else {
                                            Text("\(label) (\(project.projectID))")
                                        }
                                    }
                                }
                            }
                            .disabled(
                                isRefreshingGCloudContext
                                || isSwitchingGCloudAccount
                                || isSwitchingGCloudProject
                                || gcloudProjects.isEmpty
                            )
                        }

                        Divider().padding(.leading, 12)

                        configContextRow(title: "Region", value: region) {
                            EmptyView()
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    if let gcloudContextErrorMessage {
                        Text(gcloudContextErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Default Auth") {
                        Picker("Auth", selection: $authMode) {
                            Text("Private").tag(AIBDeployAuthMode.private)
                            Text("Public").tag(AIBDeployAuthMode.public)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    }

                    LabeledContent("Artifact Registry") {
                        TextField("Auto (region-docker.pkg.dev)", text: $artifactRegistryHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                }
            } else {
                Text("Strict mode builds services in an isolated local builder before runtime startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localSourceAuthSection: some View {
        let sshValidation = localSourceAuthValidationState

        return VStack(alignment: .leading, spacing: 12) {
            Text("Source Auth")
                .font(.callout.weight(.medium))

            TextField("Host", text: $sourceAuthHost)
                .textFieldStyle(.roundedBorder)

            Picker("Authentication Method", selection: $localSourceAuthMethod) {
                ForEach(LocalSourceAuthMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch localSourceAuthMethod {
            case .sshKey:
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Private key path", text: $localPrivateKeyPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("known_hosts path", text: $localKnownHostsPath)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Passphrase Management")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Passphrase Management", selection: $localPassphraseMode) {
                        ForEach(LocalSourceAuthPassphraseMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    switch localPassphraseMode {
                    case .appManaged:
                        SecureField("Private key passphrase", text: $localManagedPassphrase)
                            .textFieldStyle(.roundedBorder)
                        Text("Stored in Keychain and injected into local strict builds automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .external:
                        TextField("Environment variable name", text: $localExternalPassphraseEnvironmentKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Use this only when another process manages the passphrase outside the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .none:
                        Text("Use this when the key has no passphrase or you do not want AIB to manage it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Passphrase Status") {
                        Text(localPassphraseStorageStatusMessage)
                            .foregroundStyle(localPassphraseStorageStatusColor)
                    }

                    Text(sshValidation.message)
                        .font(.caption)
                        .foregroundStyle(color(for: sshValidation.level))
                }
            case .githubToken:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Token Management")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Token Management", selection: $localAccessTokenMode) {
                        ForEach(LocalSourceAuthPassphraseMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    switch localAccessTokenMode {
                    case .appManaged:
                        SecureField("GitHub personal access token", text: $localManagedAccessToken)
                            .textFieldStyle(.roundedBorder)
                        Text("Stored in Keychain and used only on the host to mirror private GitHub dependencies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .external:
                        TextField("Environment variable name", text: $localExternalAccessTokenEnvironmentKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Use this only when another process manages the GitHub token outside the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .none:
                        Text("Use this only when all GitHub dependencies are public.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Token Status") {
                        Text(localAccessTokenStorageStatusMessage)
                            .foregroundStyle(localAccessTokenStorageStatusColor)
                    }

                    Text(localAccessTokenValidationMessage)
                        .font(.caption)
                        .foregroundStyle(localAccessTokenValidationColor)
                }
            }

            Text("Target Settings is the primary place to configure private Git access for the local builder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cloudSourceAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Auth")
                .font(.callout.weight(.medium))

            if providerID == "gcp-cloudrun", !pendingCloudSourceAuthRequirements.isEmpty {
                pendingCloudSourceAuthRequirementsView
            }

            TextField("Host", text: $sourceAuthHost)
                .textFieldStyle(.roundedBorder)
            TextField("Cloud private key secret", text: $cloudPrivateKeySecret)
                .textFieldStyle(.roundedBorder)
            TextField("Cloud known_hosts secret", text: $cloudKnownHostsSecret)
                .textFieldStyle(.roundedBorder)

            Text("These secret names are used only for explicit private Git dependencies during cloud-aligned builds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    Task { await provisionCloudSourceSecretsFromLocalSSH() }
                } label: {
                    if isProvisioningCloudSourceAuth {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating secrets...")
                        }
                    } else {
                        Text("Create / Update Secrets from Local SSH Key")
                    }
                }
                .disabled(isProvisioningCloudSourceAuth)

                Spacer()
            }

            Text("Imports the SSH key configured in the local target, uploads it to Secret Manager, and saves the secret names back into this target.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cloudSourceAuthProvisionMessage {
                Text(cloudSourceAuthProvisionMessage)
                    .font(.caption)
                    .foregroundStyle(cloudSourceAuthProvisionFailed ? .red : .secondary)
            }
        }
    }

    private var pendingCloudSourceAuthRequirements: [WorkspaceSourceAuthRequirement] {
        sourceAuthRequirements
            .filter { !$0.hasCloudCredential }
            .sorted {
                if $0.repoPath == $1.repoPath {
                    return $0.host.localizedStandardCompare($1.host) == .orderedAscending
                }
                return $0.repoPath.localizedStandardCompare($1.repoPath) == .orderedAscending
            }
    }

    private var pendingCloudSourceAuthRequirementsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected Private Git Dependencies")
                .font(.caption.weight(.semibold))

            ForEach(pendingCloudSourceAuthRequirements) { requirement in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(requirement.host) · \(requirement.serviceIDs.joined(separator: ", "))")
                        .font(.caption.weight(.medium))
                    Text(requirement.findings.map(\.sourceFile).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if requirement.hasLocalCredential {
                        Text("Ready for 1-click provisioning. Suggested secret: \(requirement.suggestedPrivateKeySecretName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Add a matching local SSH credential in the local target before creating cloud source auth.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func configContextRow<Control: View>(
        title: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.callout, design: .monospaced))
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Resource Defaults

    private func resourceConfigBinding(for kind: AIBServiceKind) -> AIBDeployResourceConfig {
        kindDefaults[kind] ?? .defaults(for: kind)
    }

    private func updateResourceField(for kind: AIBServiceKind, _ update: (inout AIBDeployResourceConfig) -> Void) {
        var config = kindDefaults[kind] ?? .defaults(for: kind)
        update(&config)
        kindDefaults[kind] = config
    }

    private var resourceDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resource Defaults")
                .font(.subheadline.weight(.medium))

            Picker("Service Kind", selection: $selectedKind) {
                Text("Agent").tag(AIBServiceKind.agent)
                Text("MCP").tag(AIBServiceKind.mcp)
                Text("Other").tag(AIBServiceKind.unknown)
            }
            .pickerStyle(.segmented)

            let config = resourceConfigBinding(for: selectedKind)

            LabeledContent("Memory") {
                TextField("512Mi", text: Binding(
                    get: { config.memory },
                    set: { newValue in updateResourceField(for: selectedKind) { $0.memory = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }

            LabeledContent("CPU") {
                TextField("1", text: Binding(
                    get: { config.cpu },
                    set: { newValue in updateResourceField(for: selectedKind) { $0.cpu = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }

            LabeledContent("Max Instances") {
                TextField("10", value: Binding(
                    get: { config.maxInstances },
                    set: { newValue in updateResourceField(for: selectedKind) { $0.maxInstances = newValue } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }

            LabeledContent("Concurrency") {
                TextField("80", value: Binding(
                    get: { config.concurrency },
                    set: { newValue in updateResourceField(for: selectedKind) { $0.concurrency = newValue } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }

            LabeledContent("Timeout") {
                TextField("300s", text: Binding(
                    get: { config.timeout },
                    set: { newValue in updateResourceField(for: selectedKind) { $0.timeout = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                saveConfig()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(providerID == "gcp-cloudrun" && gcpProject.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func loadConfig(force: Bool = false) {
        guard force || !hasLoadedInitial else { return }
        hasLoadedInitial = true

        do {
            let config = try configStore.load(workspaceRoot: workspaceRootPath, providerID: providerID)
            loadedSourceCredentials = config.sourceCredentials
            region = config.region
            authMode = config.defaultAuth
            buildMode = config.buildMode
            kindDefaults = config.kindDefaults
            gcpProject = config.providerConfig["gcpProject"] ?? ""
            artifactRegistryHost = config.providerConfig["artifactRegistryHost"] ?? ""
            if let credential = config.sourceCredentials.first(where: {
                $0.type == .ssh || $0.type == .githubToken
            }) {
                sourceAuthHost = credential.host
                persistedSourceAuthHost = credential.host
                cloudPrivateKeySecret = credential.cloudPrivateKeySecret ?? ""
                cloudKnownHostsSecret = credential.cloudKnownHostsSecret ?? ""
                loadLocalSourceCredentialState(from: credential)
            } else {
                let suggestedRequirement = pendingCloudSourceAuthRequirements.first
                sourceAuthHost = suggestedRequirement?.host ?? "github.com"
                persistedSourceAuthHost = suggestedRequirement?.host ?? "github.com"
                resetLocalSourceCredentialState()
                cloudPrivateKeySecret = suggestedRequirement?.suggestedPrivateKeySecretName ?? ""
                cloudKnownHostsSecret = suggestedRequirement?.suggestedKnownHostsSecretName ?? ""
            }
            if let convenience = config.convenience {
                useHostCorepackCache = convenience.useHostCorepackCache
                useHostPNPMStore = convenience.useHostPNPMStore
                useRepoLocalPNPMStore = convenience.useRepoLocalPNPMStore
            }
        } catch {
            loadedSourceCredentials = []
            resetFormDefaults(for: providerID)
        }
    }

    private func runEnvironmentChecks() async {
        guard let provider = DeploymentProviderRegistry.provider(for: providerID) else { return }

        isCheckingEnvironment = true
        environmentChecks = [:]

        let checkers: [any PreflightChecker] = provider.preflightCheckers()
        let dependencies = provider.preflightDependencies()
        let runner = PreflightRunner(checkers: checkers, dependencies: dependencies)

        for await event in runner.run() {
            switch event {
            case .checkStarted(let id):
                environmentChecks[id] = PreflightCheckResult(
                    id: id,
                    title: environmentChecks[id]?.title ?? id.rawValue,
                    status: .running
                )
            case .checkCompleted(let result):
                environmentChecks[result.id] = result

                // Auto-populate project from detected gcloud config when field is empty
                if result.id == .gcloudProjectConfigured,
                   case .passed(let detail) = result.status,
                   let project = detail, !project.isEmpty,
                   gcpProject.isEmpty
                {
                    gcpProject = project
                }
            case .allCompleted:
                break
            }
        }

        isCheckingEnvironment = false
    }

    private func saveConfig() {
        _ = persistConfig(dismissOnSuccess: true)
    }

    @discardableResult
    private func persistConfig(dismissOnSuccess: Bool) -> Bool {
        let trimmedSourceAuthHost = trimmed(sourceAuthHost)
        let trimmedLocalPrivateKeyPath = trimmed(localPrivateKeyPath)
        let trimmedLocalKnownHostsPath = trimmed(localKnownHostsPath)
        let trimmedCloudPrivateKeySecret = trimmed(cloudPrivateKeySecret)
        let trimmedCloudKnownHostsSecret = trimmed(cloudKnownHostsSecret)

        let hasLocalSSHInput =
            !trimmedLocalPrivateKeyPath.isEmpty
            || !trimmedLocalKnownHostsPath.isEmpty
            || localPassphraseMode != .none
        let hasLocalGitHubTokenInput =
            localAccessTokenMode != .none
        let hasCloudSourceAuthInput =
            !trimmedCloudPrivateKeySecret.isEmpty
            || !trimmedCloudKnownHostsSecret.isEmpty

        if ((localSourceAuthMethod == .sshKey && hasLocalSSHInput)
            || (localSourceAuthMethod == .githubToken && hasLocalGitHubTokenInput)
            || hasCloudSourceAuthInput) && trimmedSourceAuthHost.isEmpty
        {
            errorMessage = "Set a source auth host before saving credentials."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .sshKey, localPassphraseMode == .external,
           trimmed(localExternalPassphraseEnvironmentKey).isEmpty
        {
            errorMessage = "Provide the external environment variable name or switch passphrase management to None."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .sshKey, localPassphraseMode == .appManaged, localManagedPassphrase.isEmpty {
            errorMessage = "Enter a passphrase to store in Keychain or switch passphrase management to None or External Env."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .sshKey, localPassphraseMode != .none, trimmedLocalPrivateKeyPath.isEmpty {
            errorMessage = "Set a private key path before configuring local passphrase management."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .githubToken,
           trimmedSourceAuthHost.caseInsensitiveCompare("github.com") != .orderedSame
        {
            errorMessage = "GitHub token source auth currently supports github.com only."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .githubToken,
           localAccessTokenMode == .external,
           trimmed(localExternalAccessTokenEnvironmentKey).isEmpty
        {
            errorMessage = "Provide the external environment variable name or switch token management to None."
            return false
        }

        if providerID == "local", localSourceAuthMethod == .githubToken,
           localAccessTokenMode == .appManaged,
           localManagedAccessToken.isEmpty
        {
            errorMessage = "Enter a GitHub token to store in Keychain or switch token management to None or External Env."
            return false
        }

        var providerConfig: [String: String] = [:]
        if !gcpProject.isEmpty {
            providerConfig["gcpProject"] = gcpProject
        }
        if !artifactRegistryHost.isEmpty {
            providerConfig["artifactRegistryHost"] = artifactRegistryHost
        }

        do {
            let sourceCredentials = try saveSourceCredentials(
                host: trimmedSourceAuthHost,
                localPrivateKeyPath: trimmedLocalPrivateKeyPath,
                localKnownHostsPath: trimmedLocalKnownHostsPath,
                cloudPrivateKeySecret: trimmedCloudPrivateKeySecret,
                cloudKnownHostsSecret: trimmedCloudKnownHostsSecret
            )

            let config = AIBDeployTargetConfig(
                providerID: providerID,
                region: region,
                defaultAuth: authMode,
                buildMode: buildMode,
                sourceCredentials: sourceCredentials,
                convenience: buildMode == .convenience
                    ? AIBConvenienceOptions(
                        useHostCorepackCache: useHostCorepackCache,
                        useHostPNPMStore: useHostPNPMStore,
                        useRepoLocalPNPMStore: useRepoLocalPNPMStore
                    )
                    : nil,
                kindDefaults: kindDefaults,
                providerConfig: providerConfig
            )

            try configStore.save(workspaceRoot: workspaceRootPath, config: config)
            errorMessage = nil
            if dismissOnSuccess {
                onDismiss()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resetFormDefaults(for providerID: String) {
        if providerID == "local" {
            region = "local"
        } else {
            region = "us-central1"
        }
        authMode = .private
        buildMode = providerID == "local" ? .convenience : .strict
        kindDefaults = [:]
        gcpProject = ""
        artifactRegistryHost = ""
        sourceAuthHost = "github.com"
        persistedSourceAuthHost = "github.com"
        resetLocalSourceCredentialState()
        cloudPrivateKeySecret = ""
        cloudKnownHostsSecret = ""
        useHostCorepackCache = true
        useHostPNPMStore = true
        useRepoLocalPNPMStore = true
    }

    @MainActor
    private func startBuilder() async {
        guard !isStartingBuilder else { return }
        isStartingBuilder = true
        appleContainerInstallMessage = nil
        appleContainerInstallFailed = false

        do {
            try await Task.detached(priority: .userInitiated) {
                try await AppleContainerInstaller.startBuilder()
            }.value
            let recheckResult = await BuildBackendAvailabilityChecker().run()
            environmentChecks[.buildBackendAvailable] = recheckResult
            appleContainerInstallMessage = nil
            appleContainerInstallFailed = false
        } catch {
            appleContainerInstallMessage = "Failed to start builder: \(error.localizedDescription)"
            appleContainerInstallFailed = true
        }

        isStartingBuilder = false
    }

    @MainActor
    private func provisionCloudSourceSecretsFromLocalSSH() async {
        guard !isProvisioningCloudSourceAuth else { return }
        isProvisioningCloudSourceAuth = true
        cloudSourceAuthProvisionMessage = nil
        cloudSourceAuthProvisionFailed = false

        do {
            let host = trimmed(sourceAuthHost)
            guard !host.isEmpty else {
                throw AIBDeployError(phase: "gcloud-secrets", message: "Set a source auth host before creating cloud source auth secrets.")
            }

            let projectID = trimmed(gcpProject.isEmpty ? (activeGCloudProject ?? "") : gcpProject)
            guard !projectID.isEmpty else {
                throw AIBDeployError(phase: "gcloud-secrets", message: "Set a Google Cloud project before creating cloud source auth secrets.")
            }

            let result = try await cloudSourceAuthBootstrapService.provisionGCPCloudRunSourceAuth(
                workspaceRoot: workspaceRootPath,
                projectID: projectID,
                host: host,
                preferredPrivateKeySecretName: trimmed(cloudPrivateKeySecret).isEmpty ? nil : trimmed(cloudPrivateKeySecret),
                preferredKnownHostsSecretName: trimmed(cloudKnownHostsSecret).isEmpty ? nil : trimmed(cloudKnownHostsSecret)
            ) { [targetSourceAuthKeychainStore] environmentKey in
                try targetSourceAuthKeychainStore.passphrase(for: environmentKey)
            }

            cloudPrivateKeySecret = result.privateKeySecretName
            cloudKnownHostsSecret = result.knownHostsSecretName ?? ""
            gcpProject = projectID

            loadConfig(force: true)

            let privateKeyVerb = result.createdPrivateKeySecret ? "Created" : "Updated"
            let knownHostsVerb = result.createdKnownHostsSecret ? "created" : "updated"
            if let knownHostsSecretName = result.knownHostsSecretName, !knownHostsSecretName.isEmpty {
                cloudSourceAuthProvisionMessage = "\(privateKeyVerb) '\(result.privateKeySecretName)' and \(knownHostsVerb) '\(knownHostsSecretName)'. Target config saved."
            } else {
                cloudSourceAuthProvisionMessage = "\(privateKeyVerb) '\(result.privateKeySecretName)'. Target config saved."
            }
            cloudSourceAuthProvisionFailed = false
        } catch {
            cloudSourceAuthProvisionMessage = error.localizedDescription
            cloudSourceAuthProvisionFailed = true
        }

        isProvisioningCloudSourceAuth = false
    }

    private func refreshGCloudContext() async {
        guard providerID == "gcp-cloudrun" else { return }
        isRefreshingGCloudContext = true
        gcloudContextErrorMessage = nil
        defer { isRefreshingGCloudContext = false }

        do {
            let context = try await gcloudContextService.fetchContext()
            gcloudAccounts = context.accounts
            gcloudProjects = context.projects
            activeGCloudAccount = context.activeAccount
            activeGCloudProject = context.activeProject
            if gcpProject.isEmpty, let active = context.activeProject {
                gcpProject = active
            }
        } catch {
            gcloudContextErrorMessage = error.localizedDescription
        }
    }

    private func switchAccount(to account: String) async {
        guard activeGCloudAccount != account else { return }
        isSwitchingGCloudAccount = true
        gcloudContextErrorMessage = nil
        defer { isSwitchingGCloudAccount = false }

        do {
            try await gcloudContextService.switchAccount(to: account)
            await refreshGCloudContext()
        } catch {
            gcloudContextErrorMessage = "Failed to switch account: \(error.localizedDescription)"
        }
    }

    private func switchProject(to projectID: String) async {
        guard gcpProject != projectID else { return }
        isSwitchingGCloudProject = true
        gcloudContextErrorMessage = nil
        defer { isSwitchingGCloudProject = false }

        do {
            try await gcloudContextService.switchProject(to: projectID)
            gcpProject = projectID
            await refreshGCloudContext()
        } catch {
            gcloudContextErrorMessage = "Failed to switch project: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func installLatestAppleContainer() async {
        guard !isInstallingAppleContainer else { return }
        isInstallingAppleContainer = true
        appleContainerInstallMessage = nil
        appleContainerInstallFailed = false

        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try await AppleContainerInstaller.installLatest()
            }.value
            let recheckResult = await BuildBackendAvailabilityChecker().run()
            environmentChecks[.buildBackendAvailable] = recheckResult
            appleContainerInstallMessage = nil
            appleContainerInstallFailed = false
        } catch {
            appleContainerInstallMessage = "Install failed: \(error.localizedDescription)"
            appleContainerInstallFailed = true
        }

        isInstallingAppleContainer = false
    }

    private var localSourceAuthValidationState: LocalSourceAuthValidationState {
        localSourceAuthValidationService.validate(
            privateKeyPath: localPrivateKeyPath,
            passphraseMode: localPassphraseMode,
            managedPassphrase: localManagedPassphrase,
            externalEnvironmentKey: localExternalPassphraseEnvironmentKey
        )
    }

    private var localPassphraseStorageStatusMessage: String {
        switch localPassphraseMode {
        case .none:
            return "No passphrase stored"
        case .appManaged:
            return localManagedPassphrase.isEmpty ? "No passphrase stored" : "Stored in Keychain"
        case .external:
            return "Managed externally"
        }
    }

    private var localPassphraseStorageStatusColor: Color {
        switch localPassphraseMode {
        case .none:
            return .secondary
        case .appManaged:
            return localManagedPassphrase.isEmpty ? .secondary : .green
        case .external:
            return .yellow
        }
    }

    private var localAccessTokenStorageStatusMessage: String {
        switch localAccessTokenMode {
        case .none:
            return "No token stored"
        case .appManaged:
            return localManagedAccessToken.isEmpty ? "No token stored" : "Stored in Keychain"
        case .external:
            return "Managed externally"
        }
    }

    private var localAccessTokenStorageStatusColor: Color {
        switch localAccessTokenMode {
        case .none:
            return .secondary
        case .appManaged:
            return localManagedAccessToken.isEmpty ? .secondary : .green
        case .external:
            return .yellow
        }
    }

    private var localAccessTokenValidationMessage: String {
        switch localAccessTokenMode {
        case .none:
            return "No GitHub token is configured."
        case .appManaged:
            return localManagedAccessToken.isEmpty
                ? "Enter a token to mirror private GitHub dependencies."
                : "GitHub token will be used on the host to mirror private dependencies."
        case .external:
            let envName = trimmed(localExternalAccessTokenEnvironmentKey)
            return envName.isEmpty
                ? "Provide the external environment variable name used for the GitHub token."
                : "GitHub token will be read from external env '\(envName)'."
        }
    }

    private var localAccessTokenValidationColor: Color {
        switch localAccessTokenMode {
        case .none:
            return .secondary
        case .appManaged:
            return localManagedAccessToken.isEmpty ? .yellow : .green
        case .external:
            return trimmed(localExternalAccessTokenEnvironmentKey).isEmpty ? .yellow : .yellow
        }
    }

    private func color(for level: LocalSourceAuthValidationState.Level) -> Color {
        switch level {
        case .neutral:
            .secondary
        case .success:
            .green
        case .warning:
            .yellow
        case .failure:
            .red
        }
    }

    private func loadLocalSourceCredentialState(from credential: AIBSourceCredential) {
        localSourceAuthMethod = credential.type == .githubToken ? .githubToken : .sshKey
        localPrivateKeyPath = credential.localPrivateKeyPath ?? ""
        localKnownHostsPath = credential.localKnownHostsPath ?? ""
        loadLocalPassphraseState(from: credential)
        loadLocalAccessTokenState(from: credential)
    }

    private func loadLocalPassphraseState(from credential: AIBSourceCredential) {
        persistedLocalPassphraseEnvironmentKey = trimmed(credential.localPrivateKeyPassphraseEnv ?? "")
        localManagedPassphrase = ""
        localExternalPassphraseEnvironmentKey = ""
        persistedLocalPassphraseWasAppManaged = false

        guard !persistedLocalPassphraseEnvironmentKey.isEmpty else {
            localPassphraseMode = .none
            return
        }

        do {
            if let stored = try targetSourceAuthKeychainStore.passphrase(for: persistedLocalPassphraseEnvironmentKey),
               !stored.isEmpty
            {
                localPassphraseMode = .appManaged
                localManagedPassphrase = stored
                persistedLocalPassphraseWasAppManaged = true
            } else {
                localPassphraseMode = .external
                localExternalPassphraseEnvironmentKey = persistedLocalPassphraseEnvironmentKey
            }
        } catch {
            localPassphraseMode = .external
            localExternalPassphraseEnvironmentKey = persistedLocalPassphraseEnvironmentKey
            errorMessage = error.localizedDescription
        }
    }

    private func loadLocalAccessTokenState(from credential: AIBSourceCredential) {
        persistedLocalAccessTokenEnvironmentKey = trimmed(credential.localAccessTokenEnv ?? "")
        localManagedAccessToken = ""
        localExternalAccessTokenEnvironmentKey = ""
        persistedLocalAccessTokenWasAppManaged = false

        guard !persistedLocalAccessTokenEnvironmentKey.isEmpty else {
            localAccessTokenMode = .none
            return
        }

        do {
            if let stored = try targetSourceAuthKeychainStore.passphrase(for: persistedLocalAccessTokenEnvironmentKey),
               !stored.isEmpty
            {
                localAccessTokenMode = .appManaged
                localManagedAccessToken = stored
                persistedLocalAccessTokenWasAppManaged = true
            } else {
                localAccessTokenMode = .external
                localExternalAccessTokenEnvironmentKey = persistedLocalAccessTokenEnvironmentKey
            }
        } catch {
            localAccessTokenMode = .external
            localExternalAccessTokenEnvironmentKey = persistedLocalAccessTokenEnvironmentKey
            errorMessage = error.localizedDescription
        }
    }

    private func resetLocalSourceCredentialState() {
        localSourceAuthMethod = .sshKey
        localPrivateKeyPath = ""
        localKnownHostsPath = ""
        resetLocalPassphraseState()
        resetLocalAccessTokenState()
        loadedSourceCredentials = []
    }

    private func resetLocalPassphraseState() {
        localPassphraseMode = .none
        localManagedPassphrase = ""
        localExternalPassphraseEnvironmentKey = ""
        persistedLocalPassphraseEnvironmentKey = ""
        persistedLocalPassphraseWasAppManaged = false
    }

    private func resetLocalAccessTokenState() {
        localAccessTokenMode = .none
        localManagedAccessToken = ""
        localExternalAccessTokenEnvironmentKey = ""
        persistedLocalAccessTokenEnvironmentKey = ""
        persistedLocalAccessTokenWasAppManaged = false
    }

    private func saveSourceCredentials(
        host: String,
        localPrivateKeyPath: String,
        localKnownHostsPath: String,
        cloudPrivateKeySecret: String,
        cloudKnownHostsSecret: String
    ) throws -> [AIBSourceCredential] {
        let previousEnvironmentKey = persistedLocalPassphraseEnvironmentKey
        let previousEnvironmentWasAppManaged = persistedLocalPassphraseWasAppManaged
        let previousAccessTokenEnvironmentKey = persistedLocalAccessTokenEnvironmentKey
        let previousAccessTokenWasAppManaged = persistedLocalAccessTokenWasAppManaged

        var localPassphraseEnvironmentKey: String?
        var shouldPersistAppManagedPassphrase = false
        var localAccessTokenEnvironmentKey: String?
        var shouldPersistAppManagedAccessToken = false

        if providerID == "local" {
            switch localSourceAuthMethod {
            case .sshKey:
                switch localPassphraseMode {
                case .none:
                    localPassphraseEnvironmentKey = nil
                case .appManaged:
                    if !localManagedPassphrase.isEmpty {
                        let generatedEnvironmentKey = AIBLocalSourceAuthEnvironmentResolver.appManagedPassphraseEnvironmentKey(
                            workspaceRoot: workspaceRootPath,
                            providerID: providerID,
                            host: host,
                            privateKeyPath: localPrivateKeyPath
                        )
                        try targetSourceAuthKeychainStore.setPassphrase(localManagedPassphrase, for: generatedEnvironmentKey)
                        localPassphraseEnvironmentKey = generatedEnvironmentKey
                        shouldPersistAppManagedPassphrase = true
                    }
                case .external:
                    localPassphraseEnvironmentKey = trimmed(localExternalPassphraseEnvironmentKey)
                }
                localAccessTokenEnvironmentKey = nil
            case .githubToken:
                localPassphraseEnvironmentKey = nil
                switch localAccessTokenMode {
                case .none:
                    localAccessTokenEnvironmentKey = nil
                case .appManaged:
                    if !localManagedAccessToken.isEmpty {
                        let generatedEnvironmentKey = AIBLocalSourceAuthEnvironmentResolver.appManagedAccessTokenEnvironmentKey(
                            workspaceRoot: workspaceRootPath,
                            providerID: providerID,
                            host: host
                        )
                        try targetSourceAuthKeychainStore.setPassphrase(localManagedAccessToken, for: generatedEnvironmentKey)
                        localAccessTokenEnvironmentKey = generatedEnvironmentKey
                        shouldPersistAppManagedAccessToken = true
                    }
                case .external:
                    localAccessTokenEnvironmentKey = trimmed(localExternalAccessTokenEnvironmentKey)
                }
            }
        }

        if previousEnvironmentWasAppManaged {
            let currentEnvironmentKey = localPassphraseEnvironmentKey ?? ""
            if previousEnvironmentKey != currentEnvironmentKey || !shouldPersistAppManagedPassphrase {
                try targetSourceAuthKeychainStore.removePassphrase(for: previousEnvironmentKey)
            }
        }

        if previousAccessTokenWasAppManaged {
            let currentEnvironmentKey = localAccessTokenEnvironmentKey ?? ""
            if previousAccessTokenEnvironmentKey != currentEnvironmentKey || !shouldPersistAppManagedAccessToken {
                try targetSourceAuthKeychainStore.removePassphrase(for: previousAccessTokenEnvironmentKey)
            }
        }

        persistedLocalPassphraseEnvironmentKey = localPassphraseEnvironmentKey ?? ""
        persistedLocalPassphraseWasAppManaged = shouldPersistAppManagedPassphrase
        persistedLocalAccessTokenEnvironmentKey = localAccessTokenEnvironmentKey ?? ""
        persistedLocalAccessTokenWasAppManaged = shouldPersistAppManagedAccessToken

        let sourceAuthHostsToReplace = Set(
            [persistedSourceAuthHost, host]
                .map { trimmed($0).lowercased() }
                .filter { !$0.isEmpty }
        )
        var sourceCredentials = loadedSourceCredentials.filter { credential in
            guard credential.type == .ssh || credential.type == .githubToken else { return true }
            return !sourceAuthHostsToReplace.contains(credential.host.lowercased())
        }

        let shouldSaveLocalCredential = providerID == "local"
            && (
                (localSourceAuthMethod == .sshKey && !localPrivateKeyPath.isEmpty)
                || (localSourceAuthMethod == .githubToken && localAccessTokenMode != .none)
            )
        let shouldSaveCloudCredential = providerID != "local"
            && !cloudPrivateKeySecret.isEmpty

        if shouldSaveLocalCredential || shouldSaveCloudCredential {
            sourceCredentials.append(AIBSourceCredential(
                type: providerID == "local"
                    ? (localSourceAuthMethod == .sshKey ? .ssh : .githubToken)
                    : .ssh,
                host: host,
                localPrivateKeyPath: providerID == "local" && localSourceAuthMethod == .sshKey ? localPrivateKeyPath : nil,
                localKnownHostsPath: providerID == "local" && localSourceAuthMethod == .sshKey && !localKnownHostsPath.isEmpty ? localKnownHostsPath : nil,
                localPrivateKeyPassphraseEnv: providerID == "local" && localSourceAuthMethod == .sshKey ? localPassphraseEnvironmentKey : nil,
                localAccessTokenEnv: providerID == "local" && localSourceAuthMethod == .githubToken ? localAccessTokenEnvironmentKey : nil,
                cloudPrivateKeySecret: providerID != "local" ? cloudPrivateKeySecret : nil,
                cloudKnownHostsSecret: providerID != "local" && !cloudKnownHostsSecret.isEmpty ? cloudKnownHostsSecret : nil
            ))
        }

        loadedSourceCredentials = sourceCredentials
        if !host.isEmpty {
            persistedSourceAuthHost = host
        }

        return sourceCredentials
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
