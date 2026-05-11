import AIBCore
import SwiftUI

/// View for entering secret values required before deployment.
///
/// Two distinct buckets share a single screen so the user can resolve every
/// blocker in one pass:
///
///   1. **Unresolved env secrets** — env vars referenced in source code that
///      are not pinned anywhere. Values are injected at deploy time via
///      `--set-env-vars`. Single-line input.
///
///   2. **Missing declared SecretRefs** — workspace.yaml `secrets:` bindings
///      whose backing Secret Manager secret does not yet exist. Values are
///      uploaded to Secret Manager via `provider.upsertSecret(...)` before
///      the apply phase. Multi-line input (e.g. ChatGPT auth JSON).
struct DeploySecretsInputView: View {
    let plan: AIBDeployPlan
    let unresolvedSecrets: [String]
    let missingDeclaredSecrets: [String]
    @Bindable var model: AgentsInBlackAppModel
    @State private var envValues: [String: String] = [:]
    @State private var declaredValues: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    if !unresolvedSecrets.isEmpty {
                        unresolvedEnvSection
                    }
                    if !missingDeclaredSecrets.isEmpty {
                        declaredSecretsSection
                    }
                    servicesUsingSecrets
                }
                .padding(20)
            }
            Divider()
            bottomBar
        }
        .onAppear {
            for name in unresolvedSecrets where envValues[name] == nil {
                envValues[name] = ""
            }
            for name in missingDeclaredSecrets where declaredValues[name] == nil {
                declaredValues[name] = ""
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Secrets Required", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            if !unresolvedSecrets.isEmpty && !missingDeclaredSecrets.isEmpty {
                Text("Two kinds of secrets need values before this deploy can proceed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !unresolvedSecrets.isEmpty {
                Text("The following env vars were detected in source code. Enter their values to include them in the deployment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The following Secret Manager secrets are declared in workspace.yaml but do not exist yet in the target project. Enter their values to create them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Unresolved Env Secrets

    private var unresolvedEnvSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment Variables")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if hasGeneratableSecrets {
                Text("Internal signing/session secrets can be generated. External provider keys must be pasted from the provider.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(unresolvedSecrets.enumerated()), id: \.offset) { _, name in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced).weight(.medium))

                        Spacer()

                        if DeploySecretValueGenerator.canGenerate(name: name) {
                            Button {
                                envValues[name] = DeploySecretValueGenerator.generateHexSecret()
                            } label: {
                                Label("Generate", systemImage: "sparkles")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Generate a random 32-byte hex secret")
                        }
                    }

                    SecureField("Enter value for \(name)", text: envBinding(for: name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Missing Declared SecretRefs

    private var declaredSecretsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Secret Manager Secrets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("These will be created in the target project's Secret Manager before deploying. JSON / multi-line values are supported.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(Array(missingDeclaredSecrets.enumerated()), id: \.offset) { _, name in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced).weight(.medium))

                        Spacer()

                        if DeploySecretValueGenerator.canGenerate(name: name) {
                            Button {
                                declaredValues[name] = DeploySecretValueGenerator.generateHexSecret()
                            } label: {
                                Label("Generate", systemImage: "sparkles")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Generate a random 32-byte hex secret")
                        }
                    }

                    TextEditor(text: declaredBinding(for: name))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 220)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: - Services Using Secrets

    private var servicesUsingSecrets: some View {
        VStack(alignment: .leading, spacing: 8) {
            let envUsers = plan.services.filter { !$0.unresolvedSecrets.isEmpty }
            let declaredUserNames = declaredUsingServices()

            if envUsers.isEmpty && declaredUserNames.isEmpty { EmptyView() }

            Text("Services")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(envUsers, id: \.id) { service in
                    HStack(spacing: 8) {
                        Text(service.deployedServiceName)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(service.unresolvedSecrets.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(declaredUserNames, id: \.serviceID) { entry in
                    HStack(spacing: 8) {
                        Text(entry.serviceName)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(entry.secrets.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button("Cancel") {
                Task { await model.deployController.cancel() }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()

            if !allSecretsProvided {
                Text("\(missingCount) secret\(missingCount == 1 ? "" : "s") remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Deploy") {
                model.deployController.provideSecrets(
                    unresolvedEnv: envValues,
                    declared: declaredValues
                )
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!allSecretsProvided)
        }
        .padding()
    }

    // MARK: - Helpers

    private var allSecretsProvided: Bool {
        let envOK = unresolvedSecrets.allSatisfy { !(envValues[$0]?.isEmpty ?? true) }
        let declaredOK = missingDeclaredSecrets.allSatisfy { !(declaredValues[$0]?.isEmpty ?? true) }
        return envOK && declaredOK
    }

    private var missingCount: Int {
        let envMissing = unresolvedSecrets.filter { envValues[$0]?.isEmpty ?? true }.count
        let declaredMissing = missingDeclaredSecrets.filter { declaredValues[$0]?.isEmpty ?? true }.count
        return envMissing + declaredMissing
    }

    private var hasGeneratableSecrets: Bool {
        unresolvedSecrets.contains { DeploySecretValueGenerator.canGenerate(name: $0) }
    }

    private func envBinding(for name: String) -> Binding<String> {
        Binding(
            get: { envValues[name] ?? "" },
            set: { envValues[name] = $0 }
        )
    }

    private func declaredBinding(for name: String) -> Binding<String> {
        Binding(
            get: { declaredValues[name] ?? "" },
            set: { declaredValues[name] = $0 }
        )
    }

    private struct DeclaredUsageEntry {
        let serviceID: String
        let serviceName: String
        let secrets: [String]
    }

    private func declaredUsingServices() -> [DeclaredUsageEntry] {
        guard !missingDeclaredSecrets.isEmpty else { return [] }
        let missingSet = Set(missingDeclaredSecrets)
        var rows: [DeclaredUsageEntry] = []
        for service in plan.services {
            let used = service.declaredSecretRefs.values
                .map(\.secret)
                .filter { missingSet.contains($0) }
                .sorted()
            guard !used.isEmpty else { continue }
            rows.append(DeclaredUsageEntry(
                serviceID: service.id,
                serviceName: service.deployedServiceName,
                secrets: used
            ))
        }
        return rows
    }
}
