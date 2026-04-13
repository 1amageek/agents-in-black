import Foundation
import os.log

private let logger = Logger(subsystem: "com.aib.ClaudeCode", category: "Session")

/// Manages a conversation with Claude Code via CLI subprocess.
///
/// Each `send` call spawns `claude -p` with `--output-format stream-json`.
/// Multi-turn conversations are maintained via `--resume <sessionID>`.
public actor ClaudeCodeSession {
    public let configuration: ClaudeCodeConfiguration

    /// Session ID obtained from the first `system/init` event.
    /// Used for `--resume` on subsequent turns.
    public private(set) var sessionID: String?

    /// Session metadata from the most recent `system/init` event.
    public private(set) var metadata: SystemEvent?

    private var runningProcess: Process?

    public init(configuration: ClaudeCodeConfiguration = ClaudeCodeConfiguration()) {
        self.configuration = configuration
    }

    /// Send a prompt and receive a stream of events.
    ///
    /// The first call starts a new session. Subsequent calls automatically
    /// resume the existing session via `--resume`.
    public func send(_ prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        let shell = ClaudeCodeConfiguration.loginShell
        let config = configuration
        let command = config.shellCommand(prompt: prompt, resumeSessionID: sessionID)
        let cwd = config.workingDirectory

        if let sid = sessionID {
            logger.info("[claude] resume session=\(sid.prefix(8), privacy: .public) cwd=\(cwd?.path ?? "-", privacy: .public)")
        } else {
            logger.info("[claude] new session cwd=\(cwd?.path ?? "-", privacy: .public)")
        }
        logger.debug("[claude] shell=\(shell, privacy: .public) command=\(command.prefix(200), privacy: .public)")

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-lic", command]
                    process.standardInput = FileHandle.nullDevice
                    if let cwd {
                        process.currentDirectoryURL = cwd
                    }

                    // Strip API key env vars to force OAuth-only authentication.
                    var env = ProcessInfo.processInfo.environment
                    env.removeValue(forKey: "ANTHROPIC_API_KEY")
                    env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                    // Apply additional environment variables from configuration.
                    for (key, value) in config.additionalEnvironment {
                        env[key] = value
                    }
                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    await self?.setRunningProcess(process)

                    do {
                        try process.run()
                    } catch {
                        logger.error("Failed to launch: \(error.localizedDescription)")
                        throw SessionError.launchFailed(underlying: error)
                    }

                    let parser = StreamEventParser()
                    let handle = stdout.fileHandleForReading

                    for try await line in handle.asyncLines {
                        if Task.isCancelled {
                            logger.info("Stream cancelled")
                            break
                        }
                        guard !line.isEmpty else { continue }

                        let event: StreamEvent
                        do {
                            event = try parser.parse(line)
                        } catch {
                            if case StreamEventParser.ParserError.ignoredType = error {
                                continue
                            }
                            logger.warning("Unparseable line: \(line.prefix(200), privacy: .public)")
                            continue
                        }

                        switch event {
                        case .system(let sys):
                            await self?.updateMetadata(sys)
                        case .streamEvent:
                            break
                        case .assistant:
                            break
                        case .user:
                            break
                        case .result(let res):
                            logger.info("[claude] done turns=\(res.numTurns) cost=$\(String(format: "%.4f", res.totalCostUSD)) duration=\(res.durationMS)ms")
                        }

                        continuation.yield(event)
                    }

                    process.waitUntilExit()
                    let status = process.terminationStatus
                    await self?.clearRunningProcess()

                    if status != 0 {
                        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let errString = String(data: errData, encoding: .utf8) ?? ""
                        logger.error("stderr: \(errString, privacy: .public)")
                        throw SessionError.processExited(status: status, stderr: errString)
                    }

                    continuation.finish()
                } catch {
                    logger.error("Session error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Cancel the currently running process, if any.
    public func cancel() {
        if let pid = runningProcess?.processIdentifier {
            logger.info("Cancelling process (pid=\(pid))")
        }
        runningProcess?.terminate()
        runningProcess = nil
    }

    // MARK: - Private

    private func setRunningProcess(_ process: Process) {
        runningProcess = process
    }

    private func clearRunningProcess() {
        runningProcess = nil
    }

    private func updateMetadata(_ event: SystemEvent) {
        sessionID = event.sessionID
        metadata = event
    }

    // MARK: - Errors

    public enum SessionError: Error, LocalizedError {
        case launchFailed(underlying: Error)
        case processExited(status: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let err):
                "Failed to launch claude: \(err.localizedDescription)"
            case .processExited(let status, let stderr):
                "claude exited with status \(status): \(stderr)"
            }
        }
    }
}

// MARK: - FileHandle Async Lines

extension FileHandle {
    /// Yields lines (UTF-8, newline-delimited) as they arrive from the file handle.
    var asyncLines: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                var buffer = Data()
                let newline = UInt8(ascii: "\n")

                while !Task.isCancelled {
                    let chunk = self.availableData
                    if chunk.isEmpty {
                        // EOF
                        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                            continuation.yield(line)
                        }
                        break
                    }

                    buffer.append(chunk)

                    while let range = buffer.firstIndex(of: newline) {
                        let lineData = buffer[buffer.startIndex..<range]
                        buffer = Data(buffer[buffer.index(after: range)...])
                        if let line = String(data: lineData, encoding: .utf8) {
                            continuation.yield(line)
                        }
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
