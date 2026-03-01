import Foundation

struct GCloudProjectChecker: PreflightChecker {
    let checkID = PreflightCheckID.gcloudProjectConfigured
    let title = "GCP Project"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(
                command: "gcloud config get-value project 2>/dev/null"
            )
            let project = result.stdout
            if result.exitCode == 0, !project.isEmpty, project != "(unset)" {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed(detail: project)
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("No GCP project configured"),
                remediationCommand: "gcloud config set project YOUR_PROJECT_ID"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check project: \(error.localizedDescription)")
            )
        }
    }
}
