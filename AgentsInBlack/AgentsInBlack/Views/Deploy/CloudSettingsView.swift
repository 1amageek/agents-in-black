import AIBCore
import SwiftUI

/// Cloud deploy target configuration panel.
/// Accessible from the menu bar (Cloud > Cloud Settings...).
/// Validates gcloud environment using the same preflight checkers as the deploy pipeline,
/// then allows editing deploy target configuration persisted in `.aib/targets/{providerID}.yaml`.
struct CloudSettingsView: View {
    let workspaceRootPath: String
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
    @State private var kindDefaults: [AIBServiceKind: AIBDeployResourceConfig] = [:]
    @State private var selectedKind: AIBServiceKind = .agent
    @State private var artifactRegistryHost: String = ""

    @State private var errorMessage: String?
    @State private var hasLoadedInitial: Bool = false

    private let configStore: DeployTargetConfigStore = DefaultDeployTargetConfigStore()
    private let gcloudContextService = GCloudContextService()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    providerSection
                    environmentSection
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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud Settings")
                    .font(.headline)
                Text("Deploy target configuration for this workspace")
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
        if providerID == "gcp-cloudrun" {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configuration")
                    .font(.subheadline.weight(.medium))

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

    private func loadConfig() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true

        do {
            let config = try configStore.load(workspaceRoot: workspaceRootPath, providerID: providerID)
            region = config.region
            authMode = config.defaultAuth
            kindDefaults = config.kindDefaults
            gcpProject = config.providerConfig["gcpProject"] ?? ""
            artifactRegistryHost = config.providerConfig["artifactRegistryHost"] ?? ""
        } catch {
            // No existing config — use defaults
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
        var providerConfig: [String: String] = [:]
        if !gcpProject.isEmpty {
            providerConfig["gcpProject"] = gcpProject
        }
        if !artifactRegistryHost.isEmpty {
            providerConfig["artifactRegistryHost"] = artifactRegistryHost
        }

        let config = AIBDeployTargetConfig(
            providerID: providerID,
            region: region,
            defaultAuth: authMode,
            kindDefaults: kindDefaults,
            providerConfig: providerConfig
        )

        do {
            try configStore.save(workspaceRoot: workspaceRootPath, config: config)
            errorMessage = nil
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
