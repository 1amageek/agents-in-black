import Foundation

enum ContainerCLIPolicyError: Error, LocalizedError {
    case notInstalled(detail: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let detail):
            return "apple/container CLI is required but not available. Install it from https://github.com/apple/container/releases. \(detail)"
        }
    }
}

enum ContainerCLIPolicy {
    private static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func ensureInstalled() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "container --version"]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = defaultPATH
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ContainerCLIPolicyError.notInstalled(detail: error.localizedDescription)
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "container --version exited \(process.terminationStatus)"
            throw ContainerCLIPolicyError.notInstalled(detail: stderr)
        }
    }
}
