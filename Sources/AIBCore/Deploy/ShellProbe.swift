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

        // Drain pipes concurrently with process execution. The Pipe OS buffer is
        // ~64 KB on macOS — once the child fills it, write() blocks until someone
        // reads. Reading only after `terminationHandler` fires deadlocks on any
        // large output (e.g. `gcloud run services list --format=json` ~ 700 KB).
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutTask = Task.detached(priority: .userInitiated) {
            stdoutHandle.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            stderrHandle.readDataToEndOfFile()
        }

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: AIBDeployError(
                        phase: "preflight",
                        message: "Failed to run command: \(command) — \(error.localizedDescription)"
                    ))
                    return
                }

                // Timeout: terminate after deadline
                Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        } catch {
            // Process never started — close the write ends so the read tasks see
            // EOF and we can rejoin them before propagating the original error.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        return Result(
            exitCode: exitCode,
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
