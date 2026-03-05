import AIBCore
import SwiftUI

struct DeployProgressView: View {
    let phase: AIBDeployPhase
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(statusText)
                .font(.headline)
            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let onCancel {
                Button("Cancel Deployment") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch phase {
        case .idle: return "Preparing..."
        case .preflight: return "Checking dependencies..."
        case .planning: return "Generating deploy plan..."
        default: return "Working..."
        }
    }

    private var detailText: String {
        switch phase {
        case .preflight: return "Verifying gcloud CLI, Cloud APIs, and project configuration"
        case .planning: return "Analyzing workspace topology and generating artifacts"
        default: return ""
        }
    }
}
