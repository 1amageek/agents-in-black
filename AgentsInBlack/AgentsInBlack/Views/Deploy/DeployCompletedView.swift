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
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
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

    private var authBindingsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("\(result.authBindingsApplied) auth bindings applied")
                .font(.subheadline)
        }
    }
}
