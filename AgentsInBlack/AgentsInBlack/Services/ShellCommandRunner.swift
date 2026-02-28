import Foundation

struct ShellCommandResult {
    var exitCode: Int32
}

@MainActor
final class ShellCommandRunner {
    func run(
        command: String,
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> ShellCommandResult {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = workingDirectory

                let forward: @Sendable (FileHandle) -> Void = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8) {
                        onOutput(text)
                    }
                }

                stdout.fileHandleForReading.readabilityHandler = forward
                stderr.fileHandleForReading.readabilityHandler = forward

                var exitCode: Int32 = 0
                do {
                    try process.run()
                    process.waitUntilExit()
                    exitCode = process.terminationStatus
                } catch {
                    onOutput("Failed to run command: \(error)\n")
                    exitCode = 1
                }

                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ShellCommandResult(exitCode: exitCode))
            }
        }
    }
}
