import Foundation

struct GCloudAuthenticatedChecker: PreflightChecker {
    let checkID = PreflightCheckID.gcloudAuthenticated
    let title = "GCP Authentication"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(
                command: "gcloud auth list --format='value(account)' --filter='status=ACTIVE' 2>/dev/null"
            )
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
                remediationCommand: "gcloud auth login"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check authentication: \(error.localizedDescription)")
            )
        }
    }
}
