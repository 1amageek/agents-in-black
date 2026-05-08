import AIBCore
import SwiftUI

/// View for entering secret values required by services before deployment.
struct DeploySecretsInputView: View {
    let plan: AIBDeployPlan
    let unresolvedSecrets: [String]
    @Bindable var model: AgentsInBlackAppModel
    @State private var secretValues: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    secretFieldsSection
                    servicesUsingSecrets
                }
                .padding(20)
            }
            Divider()
            bottomBar
        }
        .onAppear {
            for name in unresolvedSecrets {
                secretValues[name] = ""
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Secrets Required", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text("The following secrets were detected in source code. Enter their values to include them in the deployment.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasGeneratableSecrets {
                Text("Internal signing/session secrets can be generated here. External provider keys must be pasted from the provider.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Secret Fields

    private var secretFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(unresolvedSecrets.enumerated()), id: \.offset) { _, name in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced).weight(.medium))

                        Spacer()

                        if DeploySecretValueGenerator.canGenerate(name: name) {
                            Button {
                                secretValues[name] = DeploySecretValueGenerator.generateHexSecret()
                            } label: {
                                Label("Generate", systemImage: "sparkles")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Generate a random 32-byte hex secret")
                        }
                    }

                    SecureField("Enter value for \(name)", text: binding(for: name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Services Using Secrets

    private var servicesUsingSecrets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Services")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.services.filter { !$0.unresolvedSecrets.isEmpty }, id: \.id) { service in
                    HStack(spacing: 8) {
                        Text(service.deployedServiceName)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(service.unresolvedSecrets.joined(separator: ", "))
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
                model.deployController.cancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()

            if !allSecretsProvided {
                Text("\(missingCount) secret\(missingCount == 1 ? "" : "s") remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Deploy") {
                model.deployController.provideSecrets(secretValues)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!allSecretsProvided)
        }
        .padding()
    }

    // MARK: - Helpers

    private var allSecretsProvided: Bool {
        unresolvedSecrets.allSatisfy { name in
            guard let value = secretValues[name] else { return false }
            return !value.isEmpty
        }
    }

    private var missingCount: Int {
        unresolvedSecrets.filter { name in
            guard let value = secretValues[name] else { return true }
            return value.isEmpty
        }.count
    }

    private var hasGeneratableSecrets: Bool {
        unresolvedSecrets.contains { DeploySecretValueGenerator.canGenerate(name: $0) }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { secretValues[name] ?? "" },
            set: { secretValues[name] = $0 }
        )
    }
}
