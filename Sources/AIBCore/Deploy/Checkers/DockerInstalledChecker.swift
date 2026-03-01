import Foundation

struct DockerInstalledChecker: PreflightChecker {
    let checkID = PreflightCheckID.dockerInstalled
    let title = "Docker CLI"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(command: "docker --version 2>/dev/null")
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
                status: .failed("Docker is not installed"),
                remediationURL: URL(string: "https://docs.docker.com/desktop/install/mac-install/"),
                remediationCommand: "brew install --cask docker"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check Docker: \(error.localizedDescription)")
            )
        }
    }
}
