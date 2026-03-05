import AIBRuntimeCore
import Foundation

struct SwiftDockerfileGenerator: DockerfileGenerator {
    let runtimeKind = RuntimeKind.swift

    func generate(
        servicePath: URL,
        runCommand: [String],
        buildCommand: [String]?,
        installCommand: [String]?,
        port: Int
    ) -> String {
        let buildCmd = buildCommand ?? ["swift", "build", "-c", "release"]
        let executableName = extractExecutableName(from: runCommand)

        return """
        FROM swift:6.2-jammy AS builder
        WORKDIR /app
        COPY . .
        RUN \(buildCmd.joined(separator: " "))

        FROM swift:6.2-jammy-slim AS runtime
        COPY --from=builder /app/.build/release/\(executableName) /usr/local/bin/server
        ENV PORT=\(port)
        EXPOSE \(port)
        CMD ["server"]
        """
    }

    private func extractExecutableName(from runCommand: [String]) -> String {
        // Extract executable name from run command like [".build/debug/AgentSwift"]
        guard let last = runCommand.last else { return "App" }
        return URL(fileURLWithPath: last).lastPathComponent
    }
}
