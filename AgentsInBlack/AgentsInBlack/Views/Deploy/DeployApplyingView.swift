import AIBCore
import SwiftUI

struct DeployApplyingView: View {
    let plan: AIBDeployPlan
    let progress: Progress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deploying...")
                .font(.headline)

            ProgressView(progress)

            Spacer()

            Label("Detailed logs are available in the AIB Logs panel.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel Deployment") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
