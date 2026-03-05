import Foundation

struct CloudBuildAPIChecker: PreflightChecker {
    let checkID = PreflightCheckID.cloudBuildAPIEnabled
    let title = "Cloud Build API"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(
                command: "gcloud services list --enabled --filter='name:cloudbuild.googleapis.com' --format='value(name)' 2>/dev/null"
            )
            if result.exitCode == 0, result.stdout.contains("cloudbuild.googleapis.com") {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed()
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Cloud Build API is not enabled"),
                remediationCommand: "gcloud services enable cloudbuild.googleapis.com"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check Cloud Build API: \(error.localizedDescription)")
            )
        }
    }
}
