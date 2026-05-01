import Foundation

struct GCloudAuthenticatedChecker: PreflightChecker {
    let checkID = PreflightCheckID.gcloudAuthenticated
    let title = "GCP Authentication"

    func run() async -> PreflightCheckResult {
        let command = "gcloud auth list --format='value(account)' --filter='status=ACTIVE'"
        do {
            let result = try await ShellProbe.run(command: command)
            let diagnostics = PreflightDiagnostics.lines(command: command, result: result)
            if result.exitCode == 0, !result.stdout.isEmpty {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: result.stdout)
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("No active gcloud account"),
                remediationCommand: "gcloud auth login",
                diagnostics: diagnostics
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check authentication: \(error.localizedDescription)"),
                diagnostics: PreflightDiagnostics.lines(command: command, error: error)
            )
        }
    }
}
