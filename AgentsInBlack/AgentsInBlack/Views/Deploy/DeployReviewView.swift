import AIBCore
import SwiftUI

struct DeployReviewView: View {
    let plan: AIBDeployPlan
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
        VStack(spacing: 0) {
            content()
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Services

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

            Text(service.resourceConfig.memory)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                Text(artifact.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
                            }
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
                            }
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
        }
        .padding()
    }
}
