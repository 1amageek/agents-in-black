import Foundation

struct DockerDaemonChecker: PreflightChecker {
    let checkID = PreflightCheckID.dockerDaemonRunning
    let title = "Docker Daemon"

    func run() async -> PreflightCheckResult {
        do {
            let result = try await ShellProbe.run(command: "docker info > /dev/null 2>&1 && echo ok")
            if result.exitCode == 0, result.stdout.contains("ok") {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .passed()
                )
            }
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Docker daemon is not running"),
                remediationCommand: "open -a Docker"
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to check Docker daemon: \(error.localizedDescription)")
            )
        }
    }
}
