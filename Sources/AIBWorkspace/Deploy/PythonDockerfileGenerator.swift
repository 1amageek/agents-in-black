import AIBRuntimeCore
import Foundation

struct PythonDockerfileGenerator: DockerfileGenerator {
    let runtimeKind = RuntimeKind.python

    func generate(
        servicePath: URL,
        runCommand: [String],
        buildCommand: [String]?,
        installCommand: [String]?,
        port: Int
    ) -> String {
        let entryFile = extractEntryFile(from: runCommand)
        let hasRequirementsTxt = FileManager.default.fileExists(
            atPath: servicePath.appendingPathComponent("requirements.txt").path
        )
        let hasPyprojectToml = FileManager.default.fileExists(
            atPath: servicePath.appendingPathComponent("pyproject.toml").path
        )

        let installCmd = installCommand ?? (
            hasRequirementsTxt
                ? ["pip", "install", "--no-cache-dir", "-r", "requirements.txt"]
                : ["pip", "install", "--no-cache-dir", "."]
        )
        let copyDeps: String = hasRequirementsTxt
            ? "COPY requirements.txt ./"
            : hasPyprojectToml
                ? "COPY pyproject.toml ./"
                : ""

        return """
        FROM python:3.12-slim
        WORKDIR /app
        \(copyDeps)
        RUN \(installCmd.joined(separator: " "))
        COPY . .
        ENV PORT=\(port)
        EXPOSE \(port)
        CMD ["python3", "\(entryFile)"]
        """
    }

    private func extractEntryFile(from runCommand: [String]) -> String {
        if runCommand.count >= 2 {
            return runCommand.last ?? "server.py"
        }
        return "server.py"
    }
}
