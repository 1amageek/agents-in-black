import Foundation

struct CloudBuildAPIChecker: PreflightChecker {
    let checkID = PreflightCheckID.cloudBuildAPIEnabled
    let title = "Cloud Build API"

    func run() async -> PreflightCheckResult {
        let command = "gcloud services list --enabled --filter='name:cloudbuild.googleapis.com' --format='value(name)'"
        do {
            let result = try await ShellProbe.run(command: command)
            let diagnostics = PreflightDiagnostics.lines(command: command, result: result)
            if result.exitCode == 0, result.stdout.contains("cloudbuild.googleapis.com") {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(),
                    diagnostics: diagnostics
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Cloud Build API is not enabled"),
                remediationCommand: "gcloud services enable cloudbuild.googleapis.com",
                diagnostics: diagnostics
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check Cloud Build API: \(error.localizedDescription)"),
                diagnostics: PreflightDiagnostics.lines(command: command, error: error)
            )
        }
    }
}
