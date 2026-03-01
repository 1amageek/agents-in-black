import Foundation

struct ArtifactRegistryChecker: PreflightChecker {
    let checkID = PreflightCheckID.artifactRegistryConfigured
    let title = "Artifact Registry"

    func run() async -> PreflightCheckResult {
        do {
            // Check ~/.docker/config.json for credHelpers with pkg.dev entries
            let configPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docker/config.json")
                .path

            if FileManager.default.fileExists(atPath: configPath) {
                let content = try String(contentsOfFile: configPath, encoding: .utf8)
                if content.contains("docker.pkg.dev") {
                    return PreflightCheckResult(
                        id: checkID,
                        title: title,
                        status: .passed()
                    )
                }
            }

            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .warning("Artifact Registry auth not configured (will be configured at deploy time)"),
                remediationCommand: "gcloud auth configure-docker REGION-docker.pkg.dev"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .warning("Could not check Artifact Registry config: \(error.localizedDescription)"),
                remediationCommand: "gcloud auth configure-docker REGION-docker.pkg.dev"
            )
        }
    }
}
