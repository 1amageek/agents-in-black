import Darwin.POSIX.pwd
import Foundation
import Synchronization

/// Default process runner using `readabilityHandler` for real-time output streaming
/// and `terminationHandler` for async completion (never blocks with `waitUntilExit()`).
///
/// Uses a login shell (`-l -c`) so that user PATH additions
/// (e.g. Homebrew, gcloud SDK) are available when running from a GUI app.
/// Follows the LogMux pattern from AIBSupervisor for reliable I/O handling.
public struct DefaultProcessRunner: ProcessRunner {

    public init() {}

    /// Resolve the current user's login shell from the system user database.
    /// Reliable even in GUI apps where `$SHELL` may not be set.
    private static var userLoginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    public func run(
        arguments: [String],
        outputHandler: @escaping @Sendable (ProcessOutputLine) -> Void
    ) async throws -> ProcessRunResult {
        guard let executable = arguments.first else {
            throw AIBDeployError(phase: "execute", message: "Empty command")
        }

        let shellCommand = arguments.map { Self.shellEscape($0) }.joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.userLoginShell)
        process.arguments = ["-l", "-c", shellCommand]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Thread-safe accumulator for stdout/stderr data
        let accumulator = OutputAccumulator()

        // Install readabilityHandler for real-time streaming (LogMux pattern)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            accumulator.appendStdout(text)
            for line in text.split(whereSeparator: \.isNewline) {
                outputHandler(ProcessOutputLine(stream: .stdout, text: String(line)))
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            accumulator.appendStderr(text)
            for line in text.split(whereSeparator: \.isNewline) {
                outputHandler(ProcessOutputLine(stream: .stderr, text: String(line)))
            }
        }

        // Launch and await termination via continuation (no waitUntilExit)
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                // Detach readability handlers before reading residual data
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Read any residual data left in the pipe buffers
                let residualStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let residualStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if !residualStdout.isEmpty, let text = String(data: residualStdout, encoding: .utf8) {
                    accumulator.appendStdout(text)
                    for line in text.split(whereSeparator: \.isNewline) {
                        outputHandler(ProcessOutputLine(stream: .stdout, text: String(line)))
                    }
                }
                if !residualStderr.isEmpty, let text = String(data: residualStderr, encoding: .utf8) {
                    accumulator.appendStderr(text)
                    for line in text.split(whereSeparator: \.isNewline) {
                        outputHandler(ProcessOutputLine(stream: .stderr, text: String(line)))
                    }
                }

                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                // Clean up handlers on launch failure
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: AIBDeployError(
                    phase: "execute",
                    message: "Failed to run \(executable): \(error.localizedDescription)"
                ))
            }
        }

        let (stdout, stderr) = accumulator.collect()
        return ProcessRunResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// Escape a string for safe embedding in a shell command.
    /// Wraps in single quotes and escapes any embedded single quotes.
    private static func shellEscape(_ argument: String) -> String {
        guard argument.contains(where: { " \t\n\"'\\$`!#&|;(){}[]<>?*~".contains($0) }) || argument.isEmpty else {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - OutputAccumulator

/// Thread-safe accumulator for process output.
/// readabilityHandler callbacks run on arbitrary threads, so we need synchronization.
/// Uses `Mutex<State>` (same pattern as `DevGateway.phase`).
private final class OutputAccumulator: Sendable {
    private struct State: Sendable {
        var stdoutBuffer: String = ""
        var stderrBuffer: String = ""
    }

    private let state = Mutex(State())

    func appendStdout(_ text: String) {
        state.withLock { $0.stdoutBuffer += text }
    }

    func appendStderr(_ text: String) {
        state.withLock { $0.stderrBuffer += text }
    }

    func collect() -> (stdout: String, stderr: String) {
        state.withLock { ($0.stdoutBuffer, $0.stderrBuffer) }
    }
}
