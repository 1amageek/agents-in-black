import AIBCore
import SwiftUI

struct DeploySheetHeader: View {
    let phase: AIBDeployPhase

    var body: some View {
        HStack(spacing: 20) {
            stepIndicator("Preflight", step: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            stepIndicator("Plan", step: 1)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            stepIndicator("Review", step: 2)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            stepIndicator("Deploy", step: 3)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
            stepIndicator("Done", step: 4)
        }
        .padding()
    }

    private var currentStep: Int {
        switch phase {
        case .idle, .preflight: return 0
        case .planning: return 1
        case .reviewing: return 2
        case .applying: return 3
        case .completed: return 4
        case .failed, .cancelled: return -1
        }
    }

    private func stepIndicator(_ title: String, step: Int) -> some View {
        HStack(spacing: 6) {
            if step < currentStep {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if step == currentStep {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.caption)
                .fontWeight(step == currentStep ? .semibold : .regular)
                .foregroundStyle(step <= currentStep ? .primary : .tertiary)
        }
    }
}
