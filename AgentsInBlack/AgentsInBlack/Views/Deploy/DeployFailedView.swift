import AIBCore
import SwiftUI

struct DeployFailedView: View {
    let error: AIBDeployError
    let preflightReport: PreflightReport?
    let onDismiss: () -> Void
    @State private var isInstallingAppleContainer: Bool = false
    @State private var appleContainerInstallMessage: String?
    @State private var appleContainerInstallFailed: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text("Deployment Failed")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Phase:")
                            .font(.caption.bold())
                        Text(error.phase)
                            .font(.caption.monospaced())
                    }
                    if let serviceID = error.serviceID {
                        HStack {
                            Text("Service:")
                                .font(.caption.bold())
                            Text(serviceID)
                                .font(.caption.monospaced())
                        }
                    }
                    Text(error.message)
                        .font(.body)
                        .padding(12)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: 500)

                // Preflight check details
                if error.phase == "preflight", let report = preflightReport {
                    preflightResultsSection(report: report)
                }

                if let appleContainerInstallMessage {
                    Text(appleContainerInstallMessage)
                        .font(.caption)
                        .foregroundStyle(appleContainerInstallFailed ? .red : .secondary)
                        .frame(maxWidth: 500, alignment: .leading)
                }

                Button("Close") {
                    onDismiss()
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preflight Results

    private func preflightResultsSection(report: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Results")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 0) {
                ForEach(Array(report.results.enumerated()), id: \.element.id) { index, result in
                    if index > 0 {
                        Divider().padding(.leading, 28)
                    }
                    preflightCheckRow(result)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 500)
    }

    private func preflightCheckRow(_ result: PreflightCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                checkStatusIcon(for: result)
                    .frame(width: 16)

                Text(result.title)
                    .font(.callout)

                Spacer()

                if case .passed(let detail) = result.status, let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            switch result.status {
            case .failed(let message):
                failureDetail(message: message, result: result)
            case .skipped(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func checkStatusIcon(for result: PreflightCheckResult) -> some View {
        switch result.status {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .pending, .running:
            ProgressView()
                .controlSize(.small)
        }
    }

    private func failureDetail(message: String, result: PreflightCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, 24)

            if let command = result.remediationCommand {
                HStack(spacing: 0) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy command")
                    .padding(.trailing, 6)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .padding(.leading, 24)
            }

            if result.id == .buildBackendAvailable {
                Button {
                    Task { await installLatestAppleContainer() }
                } label: {
                    if isInstallingAppleContainer {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing latest apple/container...")
                                .font(.caption)
                        }
                    } else {
                        Text("Install Latest apple/container")
                            .font(.caption)
                    }
                }
                .disabled(isInstallingAppleContainer)
                .padding(.leading, 24)
            }

            if let url = result.remediationURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Installation guide")
                            .font(.caption)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    @MainActor
    private func installLatestAppleContainer() async {
        guard !isInstallingAppleContainer else { return }
        isInstallingAppleContainer = true
        appleContainerInstallMessage = nil
        appleContainerInstallFailed = false

        do {
            let version = try await Task.detached(priority: .userInitiated) {
                try await AppleContainerInstaller.installLatest()
            }.value
            appleContainerInstallMessage = "apple/container \(version) was installed and builder startup was attempted. Run preflight again."
            appleContainerInstallFailed = false
        } catch {
            appleContainerInstallMessage = "Install failed: \(error.localizedDescription)"
            appleContainerInstallFailed = true
        }

        isInstallingAppleContainer = false
    }
}
