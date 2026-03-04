import AIBCore
import SwiftUI

struct DeploySheet: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        VStack(spacing: 0) {
            DeploySheetHeader(phase: model.deployPhase)
            Divider()
            content
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder
    private var content: some View {
        switch model.deployPhase {
        case .idle, .preflight, .planning:
            DeployProgressView(phase: model.deployPhase)
        case .reviewing(let plan):
            DeployReviewView(plan: plan, model: model)
        case .secretsInput(let plan, let requiredSecrets):
            DeploySecretsInputView(plan: plan, requiredSecrets: requiredSecrets, model: model)
        case .applying(let plan):
            if let progress = model.deployController.deployProgress {
                DeployApplyingView(plan: plan, progress: progress)
            } else {
                DeployProgressView(phase: model.deployPhase)
            }
        case .completed(let result):
            DeployCompletedView(result: result) {
                model.dismissDeploySheet()
            }
        case .failed(let error):
            DeployFailedView(
                error: error,
                preflightReport: model.deployController.latestPreflightReport
            ) {
                model.dismissDeploySheet()
            }
        case .cancelled:
            VStack(spacing: 16) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Deployment cancelled.")
                    .font(.headline)
                Button("Close") {
                    model.dismissDeploySheet()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
