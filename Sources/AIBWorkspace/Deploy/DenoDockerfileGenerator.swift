import AIBRuntimeCore
import Foundation

struct DenoDockerfileGenerator: DockerfileGenerator {
    let runtimeKind = RuntimeKind.deno

    func generate(
        servicePath: URL,
        runCommand: [String],
        buildCommand: [String]?,
        installCommand: [String]?,
        port: Int
    ) -> String {
        let entryFile = extractEntryFile(from: runCommand)

        return """
        FROM denoland/deno:latest
        WORKDIR /app
        COPY . .
        RUN deno cache \(entryFile)
        ENV PORT=\(port)
        EXPOSE \(port)
        CMD ["deno", "run", "--allow-net", "--allow-env", "--allow-read", "\(entryFile)"]
        """
    }

    private func extractEntryFile(from runCommand: [String]) -> String {
        if runCommand.count >= 2 {
            return runCommand.last ?? "server.ts"
        }
        return "server.ts"
    }
}
