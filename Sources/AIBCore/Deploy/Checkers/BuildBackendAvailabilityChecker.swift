import Foundation

/// Checks whether apple/container build backend is available.
struct BuildBackendAvailabilityChecker: PreflightChecker {
    let checkID = PreflightCheckID.buildBackendAvailable
    let title = "Build Backend"

    func run() async -> PreflightCheckResult {
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
            let installed = try await ShellProbe.run(command: "command -v container >/dev/null 2>&1")
            if installed.exitCode != 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("apple/container CLI is not installed."),
                    remediationCommand: "Open Cloud Settings and click Install Latest apple/container."
                )
            }

            // Fast path when builder is already healthy.
            let builderStatus = try await ShellProbe.run(command: "container builder status >/dev/null 2>&1")
            if builderStatus.exitCode == 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: "apple-container")
                )
            }

            // Try to start builder so preflight reflects deploy-time behavior.
            let builderStart = try await ShellProbe.run(
                command: "container builder start 2>&1",
                timeout: .seconds(30)
            )
            if builderStart.exitCode == 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: "apple-container")
                )
            }

            let output = [builderStart.stdout, builderStart.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if output.localizedCaseInsensitiveContains("default kernel not configured") {
                let kernelSetup = try await ShellProbe.run(
                    command: "container system kernel set --recommended 2>&1",
                    timeout: .seconds(600)
                )
                if kernelSetup.exitCode != 0 {
                    let kernelOutput = [kernelSetup.stdout, kernelSetup.stderr]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    return PreflightCheckResult(
                        id: checkID,
                        title: title,
                        status: .failed("apple/container kernel auto-setup failed: \(summarized(kernelOutput))"),
                        remediationCommand: "container system kernel set --recommended && container builder start"
                    )
                }

                let retryStart = try await ShellProbe.run(
                    command: "container builder start 2>&1",
                    timeout: .seconds(60)
                )
                let retryStatus = try await ShellProbe.run(command: "container builder status >/dev/null 2>&1")
                if retryStart.exitCode == 0 || retryStatus.exitCode == 0 {
                    return PreflightCheckResult(
                        id: checkID,
                        title: title,
                        status: .passed(detail: "apple-container (kernel auto-configured)")
                    )
                }

                let retryOutput = [retryStart.stdout, retryStart.stderr]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("apple/container builder failed after kernel setup: \(summarized(retryOutput))"),
                    remediationCommand: "container builder start"
                )
            }

            let detail = summarized(output)
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("apple/container builder failed to start: \(detail)"),
                remediationCommand: "container system start && container builder start"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to verify build backend: \(error.localizedDescription)")
            )
        }
    }
}
