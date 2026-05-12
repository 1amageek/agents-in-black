import AIBCore
import SwiftUI

struct DeployCompletedView: View {
    let result: AIBDeployResult
    let onOpenChat: ((_ serviceResultID: String, _ deployedURL: URL) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    serviceResultsSection
                    if result.authBindingsApplied > 0 {
                        authBindingsSection
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: result.allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(result.allSucceeded ? .green : .yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.allSucceeded ? "Deployment Complete" : "Deployment Partially Complete")
                    .font(.headline)
                let succeeded = result.serviceResults.filter(\.success).count
                Text("\(succeeded)/\(result.serviceResults.count) services deployed successfully")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serviceResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Services", systemImage: "server.rack")
                .font(.headline)

            ForEach(result.serviceResults, id: \.id) { serviceResult in
                HStack {
                    Image(systemName: serviceResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(serviceResult.success ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(serviceResult.id)
                            .font(.body.monospaced())
                        if let url = serviceResult.deployedURL {
                            Link(url, destination: URL(string: url)!)
                                .font(.caption)
                        }
                        if let error = serviceResult.errorMessage {
                            errorDetails(error)
                        }
                    }
                    Spacer()
                    if serviceResult.success,
                       isAgentService(serviceResult.id),
                       let urlString = serviceResult.deployedURL,
                       let url = URL(string: urlString) {
                        Button {
                            onOpenChat?(serviceResult.id, url)
                        } label: {
                            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func isAgentService(_ serviceResultID: String) -> Bool {
        result.plan.services.first(where: { $0.id == serviceResultID })?.serviceKind == .agent
    }

    @ViewBuilder
    private func errorDetails(_ error: String) -> some View {
        let parts = splitErrorMessage(error)
        VStack(alignment: .leading, spacing: 6) {
            Text(parts.summary)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if let details = parts.details {
                DisclosureGroup {
                    ScrollView(.horizontal) {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text("Show error details")
                        .font(.caption)
                }
                .controlSize(.small)
            }
        }
    }

    private func splitErrorMessage(_ error: String) -> (summary: String, details: String?) {
        let lines = error.components(separatedBy: .newlines)
        guard let firstLine = lines.first, lines.count > 1 else {
            return (error, nil)
        }
        let details = lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (firstLine, details.isEmpty ? nil : details)
    }

    private var authBindingsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("\(result.authBindingsApplied) auth bindings applied")
                .font(.subheadline)
        }
    }
}
