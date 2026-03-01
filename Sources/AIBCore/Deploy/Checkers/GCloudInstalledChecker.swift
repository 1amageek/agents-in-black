import Foundation

struct GCloudInstalledChecker: PreflightChecker {
    let checkID = PreflightCheckID.gcloudInstalled
    let title = "gcloud CLI"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(command: "gcloud --version 2>/dev/null | head -1")
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
                status: .failed("gcloud CLI is not installed"),
                remediationURL: URL(string: "https://cloud.google.com/sdk/docs/install"),
                remediationCommand: "brew install --cask google-cloud-sdk"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check gcloud: \(error.localizedDescription)")
            )
        }
    }
}
