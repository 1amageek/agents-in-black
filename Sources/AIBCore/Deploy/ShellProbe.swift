import Darwin.POSIX.pwd
import Foundation

/// Runs shell commands to probe for installed tools.
/// Used by preflight checkers to verify external dependencies.
public enum ShellProbe {

    public struct Result: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Resolve the current user's login shell from the system user database.
    /// This is reliable even in GUI apps where `$SHELL` may not be set.
    private static var userLoginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    /// Runs a shell command and captures output.
    /// - Parameters:
    ///   - command: The shell command to execute via the user's login shell.
    ///   - timeout: Maximum execution time before the process is terminated.
    /// - Returns: The captured result including exit code and output.
    /// - Note: Uses a login shell (`-l -c`) so that user PATH additions
    ///   (e.g. Homebrew, gcloud SDK) are available when running from a GUI app.
    public static func run(
        command: String,
        timeout: Duration = .seconds(10)
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userLoginShell)
        process.arguments = ["-l", "-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Await termination via continuation (never block with waitUntilExit)
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AIBDeployError(
                    phase: "preflight",
                    message: "Failed to run command: \(command) — \(error.localizedDescription)"
                ))
                return
            }

            // Timeout: terminate after deadline
            Task {
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return Result(
            exitCode: exitCode,
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
