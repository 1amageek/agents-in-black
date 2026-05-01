import Darwin.POSIX.pwd
import Foundation

extension ShellProbe {

    /// Run a shell command and yield its stdout one line at a time as it arrives.
    /// The stream completes when the process exits successfully, throws on non-zero exit,
    /// and terminates the underlying process if the consumer cancels its task.
    /// - Note: Uses the user's login shell so PATH additions (Homebrew, gcloud SDK) resolve.
    public static func streamLines(
        command: String
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: userLoginShell)
            process.arguments = ["-l", "-c", command]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stderrCollector = StreamStderrCollector()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else if let chunk = String(data: data, encoding: .utf8) {
                    stderrCollector.append(chunk)
                }
            }

            let buffer = StreamLineBuffer { line in
                continuation.yield(line)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else if let chunk = String(data: data, encoding: .utf8) {
                    buffer.feed(chunk)
                }
            }

            process.terminationHandler = { proc in
                buffer.flush()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: AIBDeployError(
                        phase: "logs",
                        message: "Command exited with status \(proc.terminationStatus). \(stderrCollector.contents)"
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: AIBDeployError(
                    phase: "logs",
                    message: "Failed to run command: \(command) — \(error.localizedDescription)"
                ))
                return
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

}

private final class StreamStderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

private final class StreamLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ chunk: String) {
        var ready: [String] = []
        lock.lock()
        pending += chunk
        while let nl = pending.firstIndex(of: "\n") {
            ready.append(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        lock.unlock()
        for line in ready { onLine(line) }
    }

    func flush() {
        lock.lock()
        let remainder = pending
        pending = ""
        lock.unlock()
        if !remainder.isEmpty { onLine(remainder) }
    }
}
