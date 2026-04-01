import AIBRuntimeCore
import AIBWorkspace
import SwiftUI

struct CloudSourceAuthQuickSetupSheet: View {
    let requirement: WorkspaceSourceAuthRequirement
    let projectID: String?
    let isProvisioning: Bool
    let errorMessage: String?
    let onConfirm: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud Source Auth Detected")
                    .font(.title3.weight(.semibold))
                Text("AIB found a private Git dependency while syncing this workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                keyValueRow("Host", requirement.host)
                keyValueRow("Services", requirement.serviceIDs.joined(separator: ", "))
                keyValueRow("Repo", requirement.repoPath)
                keyValueRow("Project", projectID ?? "Not selected")
                keyValueRow("Private Key Secret", requirement.suggestedPrivateKeySecretName)
                if let knownHostsSecret = requirement.suggestedKnownHostsSecretName {
                    keyValueRow("known_hosts Secret", knownHostsSecret)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text("Referenced By")
                    .font(.caption.weight(.semibold))
                ForEach(Array(requirement.findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.sourceFile)
                            .font(.caption.weight(.medium))
                        Text(finding.requirement)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Text("Create / Update Cloud Source Auth uploads the SSH key configured in the local target, creates new Secret Manager versions when needed, and saves the secret names into `.aib/targets/gcp-cloudrun.yaml`.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Later") {
                    onLater()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onConfirm()
                } label: {
                    if isProvisioning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Creating...")
                        }
                    } else {
                        Text("Create / Update Cloud Source Auth")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isProvisioning || (projectID?.isEmpty ?? true))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func keyValueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
