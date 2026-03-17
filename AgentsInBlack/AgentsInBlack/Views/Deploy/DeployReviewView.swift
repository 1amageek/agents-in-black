import AIBCore
import SwiftUI

struct DeployReviewView: View {
    let plan: AIBDeployPlan
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    googleCloudSection
                    servicesSection
                    secretsInfoSection
                    connectionsSection
                    authBindingsSection
                    artifactsSection
                    warningsSection
                    envWarningsSection
                }
                .padding(20)
            }
            Divider()
            bottomBar
        }
        .task(id: plan.id) {
            model.refreshGCloudDeployContext()
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    // MARK: - Card Background

    private func cardBackground<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Services

    @ViewBuilder
    private var googleCloudSection: some View {
        if plan.targetConfig.providerID == "gcp-cloudrun" {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Google Cloud")

                cardBackground {
                    contextRow(
                        title: "Account",
                        value: model.activeGCloudAccount ?? "No active Google account"
                    ) {
                        Menu("Switch") {
                            ForEach(model.gcloudAccounts) { account in
                                Button {
                                    Task {
                                        await model.switchGCloudAccount(to: account.account)
                                    }
                                } label: {
                                    if account.account == model.activeGCloudAccount {
                                        Label(account.account, systemImage: "checkmark")
                                    } else {
                                        Text(account.account)
                                    }
                                }
                            }
                        }
                        .disabled(
                            !model.canSwitchDeployGCloudContext
                                || model.isRefreshingGCloudContext
                                || model.isSwitchingDeployGCloudContext
                                || model.gcloudAccounts.isEmpty
                        )
                    }

                    Divider().padding(.leading, 12)

                    contextRow(
                        title: "Project",
                        value: model.displayDeployGCloudProject ?? "No project selected",
                        detail: activeProjectDetail
                    ) {
                        Menu("Switch") {
                            ForEach(model.gcloudProjects) { project in
                                Button {
                                    Task {
                                        await model.switchGCloudProject(to: project.projectID)
                                    }
                                } label: {
                                    let label = project.name ?? project.projectID
                                    if project.projectID == model.displayDeployGCloudProject {
                                        Label("\(label) (\(project.projectID))", systemImage: "checkmark")
                                    } else {
                                        Text("\(label) (\(project.projectID))")
                                    }
                                }
                            }
                        }
                        .disabled(
                            !model.canSwitchDeployGCloudContext
                                || model.isRefreshingGCloudContext
                                || model.isSwitchingDeployGCloudContext
                                || model.gcloudProjects.isEmpty
                        )
                    }

                    Divider().padding(.leading, 12)

                    contextRow(title: "Region", value: plan.targetConfig.region) {
                        Button("Refresh") {
                            model.refreshGCloudDeployContext()
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRefreshingGCloudContext || model.isSwitchingDeployGCloudContext)
                    }
                }

                if model.isRefreshingGCloudContext {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing Google Cloud context...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Changing account or project refreshes the deploy plan before deployment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let gcloudContextErrorMessage = model.gcloudContextErrorMessage {
                    Text(gcloudContextErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeProjectDetail: String? {
        guard let activeProject = model.activeGCloudProject else { return nil }
        guard activeProject != model.displayDeployGCloudProject else { return nil }
        return "gcloud active project: \(activeProject)"
    }

    private func contextRow<Control: View>(
        title: String,
        value: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Services", count: plan.services.count)

            cardBackground {
                ForEach(Array(plan.services.enumerated()), id: \.element.id) { index, service in
                    if index > 0 {
                        Divider().padding(.leading, 12)
                    }
                    serviceRow(service)
                }
            }
        }
    }

    private func serviceRow(_ service: AIBDeployServicePlan) -> some View {
        HStack(spacing: 10) {
            kindBadge(service.serviceKind)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.id)
                    .font(.system(.body, design: .monospaced))
                Text("\(service.runtime) \u{2022} \(service.deployedServiceName) \u{2022} \(service.region)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                resourceTag(service.resourceConfig.memory, icon: "memorychip")
                resourceTag(service.resourceConfig.cpu + " CPU", icon: "cpu")
                resourceTag(service.resourceConfig.timeout, icon: "clock")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func resourceTag(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func kindBadge(_ kind: AIBServiceKind) -> some View {
        Text(kind == .agent ? "Agent" : "MCP")
            .font(.caption2.weight(.medium))
            .foregroundStyle(kind == .agent ? .blue : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (kind == .agent ? Color.blue : Color.orange).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .frame(width: 46)
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        let connections: [(source: String, target: String, type: String)] = plan.services.flatMap { service in
            service.connections.mcpServers.map { (source: service.id, target: $0.serviceRef, type: "MCP") }
                + service.connections.a2aAgents.map { (source: service.id, target: $0.serviceRef, type: "A2A") }
        }

        return Group {
            if !connections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Connections", count: connections.count)

                    cardBackground {
                        ForEach(Array(connections.enumerated()), id: \.offset) { index, conn in
                            if index > 0 {
                                Divider().padding(.leading, 12)
                            }
                            HStack(spacing: 8) {
                                Text(conn.source)
                                    .font(.system(.caption, design: .monospaced))
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(conn.target)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer(minLength: 8)
                                Text(conn.type)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Auth Bindings

    private var authBindingsSection: some View {
        Group {
            if !plan.authBindings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Auth Bindings", count: plan.authBindings.count)

                    cardBackground {
                        ForEach(Array(plan.authBindings.enumerated()), id: \.offset) { index, binding in
                            if index > 0 {
                                Divider().padding(.leading, 12)
                            }
                            HStack(spacing: 8) {
                                Text(binding.sourceServiceName)
                                    .font(.system(.caption, design: .monospaced))
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(binding.targetServiceName)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer(minLength: 8)
                                Text(binding.role)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Artifacts

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Generated Artifacts")

            cardBackground {
                ForEach(Array(plan.services.enumerated()), id: \.element.id) { index, service in
                    if index > 0 {
                        Divider().padding(.leading, 12)
                    }
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            artifactContent(service.artifacts.dockerfile, label: "Dockerfile")
                            artifactContent(service.artifacts.deployConfig, label: "deploy.yaml")
                            if let mcpConfig = service.artifacts.mcpConnectionConfig {
                                artifactContent(mcpConfig, label: "connections.json")
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text(service.deployedServiceName)
                                .font(.system(.callout, design: .monospaced))
                            if service.artifacts.dockerfile.source == .custom {
                                Text("Custom")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func artifactContent(_ artifact: AIBDeployArtifact, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(artifact.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(artifactDisplayText(artifact))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func artifactDisplayText(_ artifact: AIBDeployArtifact) -> String {
        if let text = artifact.utf8String {
            return text
        }
        return "Binary artifact (\(artifact.content.count) bytes)"
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        Group {
            if !plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Warnings")

                    cardBackground {
                        ForEach(plan.warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Secrets Info

    private var secretsInfoSection: some View {
        Group {
            if plan.hasRequiredSecrets {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Secrets Required", count: plan.allRequiredSecrets.count)

                    cardBackground {
                        ForEach(Array(plan.allRequiredSecrets.enumerated()), id: \.element) { index, name in
                            if index > 0 {
                                Divider().padding(.leading, 12)
                            }
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(name)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }

                    Text("You will be prompted to enter secret values before deployment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Env Warnings

    private var envWarningsSection: some View {
        Group {
            if !plan.allEnvWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Environment Warnings")

                    cardBackground {
                        ForEach(plan.allEnvWarnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button("Cancel") {
                model.deployController.cancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Text("\(plan.targetConfig.providerID) / \(plan.targetConfig.region)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Deploy \(plan.services.count) Services") {
                model.deployController.approve(plan: plan)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.isSwitchingDeployGCloudContext)
        }
        .padding()
    }
}
