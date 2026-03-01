import AIBRuntimeCore
import Foundation

struct NodeDockerfileGenerator: DockerfileGenerator {
    let runtimeKind = RuntimeKind.node

    func generate(
        servicePath: URL,
        runCommand: [String],
        buildCommand: [String]?,
        installCommand: [String]?,
        port: Int
    ) -> String {
        let hasLockfile = FileManager.default.fileExists(
            atPath: servicePath.appendingPathComponent("package-lock.json").path
        )
        let installCmd = installCommand ?? (
            hasLockfile
                ? ["npm", "ci", "--production"]
                : ["npm", "install", "--production"]
        )
        let entryFile = extractEntryFile(from: runCommand)
        let buildStep: String
        if let buildCommand, !buildCommand.isEmpty {
            buildStep = "RUN \(buildCommand.joined(separator: " "))\n"
        } else {
            buildStep = ""
        }

        return """
        FROM node:22-slim
        WORKDIR /app
        COPY package*.json ./
        RUN \(installCmd.joined(separator: " "))
        COPY . .
        \(buildStep)ENV PORT=\(port)
        EXPOSE \(port)
        CMD ["node", "\(entryFile)"]
        """
    }

    private func extractEntryFile(from runCommand: [String]) -> String {
        if runCommand.count >= 2 {
            return runCommand[1]
        }
        return "server.js"
    }
}
