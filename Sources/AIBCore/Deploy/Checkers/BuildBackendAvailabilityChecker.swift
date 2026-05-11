import Foundation

/// Checks whether docker + buildx are available for the deploy build/push pipeline.
public struct BuildBackendAvailabilityChecker: PreflightChecker {
    public let checkID = PreflightCheckID.buildBackendAvailable
    public let title = "Build Backend"

    public init() {}

    public func run() async -> PreflightCheckResult {
        var diagnostics: [String] = []

        func summarized(_ output: String) -> String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "unknown error"
            }
            let maxLength = 200
            if trimmed.count <= maxLength {
                return trimmed
            }
            return String(trimmed.prefix(maxLength)) + "..."
        }

        do {
            let dockerInstalledCommand = "command -v docker"
            let dockerInstalled = try await ShellProbe.run(command: dockerInstalledCommand)
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: dockerInstalledCommand, result: dockerInstalled))
            if dockerInstalled.exitCode != 0 {
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("docker CLI is not installed."),
                    remediationCommand: "Install Docker Desktop or OrbStack (https://orbstack.dev).",
                    diagnostics: diagnostics
                )
            }

            let buildxCommand = "docker buildx version"
            let buildx = try await ShellProbe.run(command: buildxCommand)
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: buildxCommand, result: buildx))
            if buildx.exitCode != 0 {
                let detail = summarized([buildx.stdout, buildx.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("docker buildx is not available: \(detail)"),
                    remediationCommand: "Install Docker 23+ or enable the buildx plugin.",
                    diagnostics: diagnostics
                )
            }

            // `docker info` requires the daemon to be reachable. If the user has docker CLI
            // but Docker Desktop / OrbStack is not running, this is where we catch it.
            let dockerInfoCommand = "docker info"
            let dockerInfo = try await ShellProbe.run(
                command: dockerInfoCommand,
                timeout: .seconds(15)
            )
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: dockerInfoCommand, result: dockerInfo))
            if dockerInfo.exitCode != 0 {
                let detail = summarized([dockerInfo.stdout, dockerInfo.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("docker daemon is not reachable: \(detail)"),
                    remediationCommand: "Start Docker Desktop or OrbStack and retry.",
                    diagnostics: diagnostics
                )
            }

            // Materialize the active buildx builder so the deploy step doesn't pay
            // cold-start latency on first build.
            let bootstrapCommand = "docker buildx inspect --bootstrap"
            let bootstrap = try await ShellProbe.run(
                command: bootstrapCommand,
                timeout: .seconds(60)
            )
            diagnostics.append(contentsOf: PreflightDiagnostics.lines(command: bootstrapCommand, result: bootstrap))
            if bootstrap.exitCode != 0 {
                let detail = summarized([bootstrap.stdout, bootstrap.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                return PreflightCheckResult(
                    id: checkID,
                    title: title,
                    status: .failed("docker buildx failed to bootstrap a builder: \(detail)"),
                    remediationCommand: "docker buildx create --use --name aib-builder",
                    diagnostics: diagnostics
                )
            }

            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .passed(detail: "docker-buildx"),
                diagnostics: diagnostics
            )
        } catch {
            return PreflightCheckResult(
                id: checkID,
                title: title,
                status: .failed("Failed to verify build backend: \(error.localizedDescription)"),
                diagnostics: diagnostics
            )
        }
    }
}
