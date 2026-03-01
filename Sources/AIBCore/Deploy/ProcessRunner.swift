import Foundation

/// A single line of output from a running process.
public struct ProcessOutputLine: Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public var stream: Stream
    public var text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// The result of a completed process execution.
public struct ProcessRunResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstraction for running external processes asynchronously.
/// Enables constructor injection for testability (following the
/// `ProcessController` pattern from AIBSupervisor).
public protocol ProcessRunner: Sendable {
    /// Run a command and stream output lines in real time.
    ///
    /// - Parameters:
    ///   - arguments: The command and its arguments (e.g., `["docker", "build", ...]`).
    ///   - outputHandler: Called for each line of stdout/stderr as it becomes available.
    /// - Returns: The aggregated result after the process exits.
    func run(
        arguments: [String],
        outputHandler: @escaping @Sendable (ProcessOutputLine) -> Void
    ) async throws -> ProcessRunResult
}
