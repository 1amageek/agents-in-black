import Foundation

struct CloudRunAPIChecker: PreflightChecker {
    let checkID = PreflightCheckID.cloudRunAPIEnabled
    let title = "Cloud Run API"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(
                command: "gcloud services list --enabled --filter='name:run.googleapis.com' --format='value(name)' 2>/dev/null"
            )
            if result.exitCode == 0, result.stdout.contains("run.googleapis.com") {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed()
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Cloud Run API is not enabled"),
                remediationCommand: "gcloud services enable run.googleapis.com"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check Cloud Run API: \(error.localizedDescription)")
            )
        }
    }
}
