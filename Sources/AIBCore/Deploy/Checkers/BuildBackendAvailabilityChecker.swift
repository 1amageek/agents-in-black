import Foundation

/// Checks whether apple/container build backend is available.
public struct BuildBackendAvailabilityChecker: PreflightChecker {
    public let checkID = PreflightCheckID.buildBackendAvailable
    public let title = "Build Backend"

    public init() {}

    public func run() async -> PreflightCheckResult {
        var diagnostics: [String] = []

        func summarized(_ output: String) -> String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "unknown error"
            }
            let maxLength = 200
            if trimmed.count <= maxLength {
                return trimmed
            }
            return String(trimmed.prefix(maxLength)) + "..."
        }

        do {
            let installedCommand = "command -v container"
            let installed = try await ShellProbe.run(command: installedCommand)
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: installedCommand, result: installed))
            if installed.exitCode != 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("apple/container CLI is not installed."),
                    remediationCommand: "Open Target Settings and click Install Latest apple/container.",
                    diagnostics: diagnostics
                )
            }

            // Fast path when builder is already healthy.
            let builderStatusCommand = "container builder status"
            let builderStatus = try await ShellProbe.run(command: builderStatusCommand)
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: builderStatusCommand, result: builderStatus))
            if builderStatus.exitCode == 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: "apple-container"),
                    diagnostics: diagnostics
                )
            }

            // Try to start builder so preflight reflects deploy-time behavior.
            let builderStartCommand = "container builder start"
            let builderStart = try await ShellProbe.run(
                command: builderStartCommand,
                timeout: .seconds(30)
            )
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: builderStartCommand, result: builderStart))
            if builderStart.exitCode == 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: "apple-container"),
                    diagnostics: diagnostics
                )
            }

            let output = [builderStart.stdout, builderStart.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if output.localizedCaseInsensitiveContains("default kernel not configured") {
                let kernelSetupCommand = "container system kernel set --recommended"
                let kernelSetup = try await ShellProbe.run(
                    command: kernelSetupCommand,
                    timeout: .seconds(600)
                )
                diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: kernelSetupCommand, result: kernelSetup))
                if kernelSetup.exitCode != 0 {
                    let kernelOutput = [kernelSetup.stdout, kernelSetup.stderr]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    return PreflightCheckResult(
                        id: checkID,
                        title: title,
                        status: .failed("apple/container kernel auto-setup failed: \(summarized(kernelOutput))"),
                        remediationCommand: "container system kernel set --recommended && container builder start",
                        diagnostics: diagnostics
                    )
                }

                let retryStartCommand = "container builder start"
                let retryStart = try await ShellProbe.run(
                    command: retryStartCommand,
                    timeout: .seconds(60)
                )
                diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: retryStartCommand, result: retryStart))
                let retryStatusCommand = "container builder status"
                let retryStatus = try await ShellProbe.run(command: retryStatusCommand)
                diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: retryStatusCommand, result: retryStatus))
                if retryStart.exitCode == 0 || retryStatus.exitCode == 0 {
                    return PreflightCheckResult(
                        id: checkID,
                        title: title,
                        status: .passed(detail: "apple-container (kernel auto-configured)"),
                        diagnostics: diagnostics
                    )
                }

                let retryOutput = [retryStart.stdout, retryStart.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("apple/container builder failed after kernel setup: \(summarized(retryOutput))"),
                    remediationCommand: "container builder start",
                    diagnostics: diagnostics
                )
            }

            let detail = summarized(output)
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("apple/container builder failed to start: \(detail)"),
                remediationCommand: "container system start && container builder start",
                diagnostics: diagnostics
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to verify build backend: \(error.localizedDescription)"),
                diagnostics: diagnostics
            )
        }
    }
}
