import AIBRuntimeCore
import Foundation

public final class CodexAppServerAgentRunner: AgentRunner {
    private let model: String?
    private let state = CodexAppServerRunnerState()

    public init(model: String? = nil) {
        self.model = model
    }

    public static let displayName = "Codex App Server"

    public static var isHostAvailable: Bool {
        CodexAppServerCommandLocator.findCodexBinary() != nil
    }

    public static func checkAuthStatus() async -> AgentRunnerAuthStatus {
        AgentRunnerAuthStatus(
            loggedIn: isHostAvailable,
            isOAuthAuthenticated: isHostAvailable,
            authMethod: "codex"
        )
    }

    public func send(
        message: String,
        context: AgentRunnerContext
    ) -> AsyncThrowingStream<AgentRunnerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var transport: CodexAppServerTransport?
                do {
                    let codexBinary = try CodexAppServerCommandLocator.requireCodexBinary()
                    let config = try CodexAppServerRuntimeConfig(context: context)
                    let runtime = try CodexAppServerTransport(
                        codexBinary: codexBinary,
                        configOverrides: config.configOverrides
                    )
                    transport = runtime
                    await state.setTransport(runtime)

                    _ = try await runtime.send(
                        method: "initialize",
                        paramsJSON: try CodexJSON.stringify([
                            "clientInfo": [
                                "name": "aib_local_agent",
                                "title": "AIB Local Agent",
                                "version": "0.1.0",
                            ],
                            "capabilities": [
                                "experimentalApi": true,
                            ],
                        ])
                    )
                    await runtime.notify(method: "initialized", paramsJSON: "{}")

                    let effectiveModel = model ?? ProcessInfo.processInfo.environment["MODEL"] ?? "gpt-5.5"
                    let threadResponseJSON = try await runtime.send(
                        method: "thread/start",
                        paramsJSON: try CodexJSON.stringify([
                            "model": effectiveModel,
                            "cwd": context.executionDirectory ?? FileManager.default.currentDirectoryPath,
                            "approvalPolicy": "never",
                            "sandbox": "danger-full-access",
                            "serviceName": "aib_local_agent",
                        ])
                    )
                    let threadResponse = try CodexJSON.object(from: threadResponseJSON)
                    guard
                        let thread = threadResponse["thread"] as? [String: Any],
                        let threadID = thread["id"] as? String
                    else {
                        throw CodexAppServerRunnerError.missingThreadID
                    }

                    continuation.yield(.system(AgentRunnerSystemInfo(
                        sessionID: threadID,
                        model: effectiveModel,
                        tools: [],
                        mcpServerNames: config.mcpServerNames,
                        mcpServerStatuses: config.mcpServerNames.map { _ in "configured" },
                        permissionMode: "never"
                    )))

                    var input: [[String: Any]] = [["type": "text", "text": message]]
                    input.append(contentsOf: try CodexSkillInputResolver.skillInputs(
                        pluginRootPath: context.pluginRootPath,
                        prompt: message
                    ))

                    _ = try await runtime.send(
                        method: "turn/start",
                        paramsJSON: try CodexJSON.stringify([
                            "threadId": threadID,
                            "input": input,
                            "cwd": context.executionDirectory ?? FileManager.default.currentDirectoryPath,
                            "model": effectiveModel,
                            "effort": resolveReasoningEffort(),
                            "approvalPolicy": "never",
                            "sandboxPolicy": ["type": "dangerFullAccess"],
                        ])
                    )

                    var finalText = ""
                    var completed = false
                    while !completed {
                        guard let notificationJSON = await runtime.nextNotification() else {
                            break
                        }
                        let notification = try CodexJSON.object(from: notificationJSON)
                        let method = notification["method"] as? String
                        let params = notification["params"] as? [String: Any] ?? [:]

                        switch method {
                        case "item/agentMessage/delta":
                            if let delta = params["delta"] as? String {
                                finalText += delta
                                continuation.yield(.textDelta(delta))
                            }
                        case "item/started":
                            guard let item = params["item"] as? [String: Any] else { break }
                            if item["type"] as? String == "commandExecution" {
                                continuation.yield(.toolUse(name: "commandExecution"))
                            } else if item["type"] as? String == "mcpToolCall" {
                                let server = item["server"] as? String ?? "mcp"
                                let tool = item["tool"] as? String ?? "tool"
                                continuation.yield(.toolUse(name: "\(server).\(tool)"))
                            }
                        case "item/completed":
                            guard let item = params["item"] as? [String: Any] else { break }
                            if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                                finalText = text
                            } else if item["type"] as? String == "mcpToolCall" {
                                let content = try CodexJSON.stringify(item["result"] ?? item["error"] ?? [:])
                                continuation.yield(.toolResult(
                                    toolUseID: item["id"] as? String ?? "",
                                    content: content
                                ))
                            }
                        case "turn/completed":
                            let turn = params["turn"] as? [String: Any]
                            let status = turn?["status"] as? String
                            if status == "failed" {
                                let error = turn?["error"] as? [String: Any]
                                continuation.yield(.error(error?["message"] as? String ?? "Codex turn failed"))
                            }
                            continuation.yield(.done(AgentRunnerResult(
                                conversationID: threadID,
                                totalCostUSD: nil,
                                durationMS: nil,
                                numTurns: nil
                            )))
                            completed = true
                        case "error":
                            let error = params["error"] as? [String: Any]
                            continuation.yield(.error(error?["message"] as? String ?? "Codex app-server error"))
                        default:
                            break
                        }
                    }

                    if !finalText.isEmpty {
                        continuation.yield(.textComplete(finalText))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }

                await state.clearTransport(transport)
                await transport?.terminate()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.state.cancel()
                }
            }
        }
    }

    public func cancel() async {
        await state.cancel()
    }

    private func resolveReasoningEffort() -> String {
        let value = ProcessInfo.processInfo.environment["CODEX_REASONING_EFFORT"]
            ?? ProcessInfo.processInfo.environment["MODEL_REASONING_EFFORT"]
        switch value {
        case "low", "medium", "high", "xhigh":
            return value ?? "medium"
        default:
            return "medium"
        }
    }
}

private actor CodexAppServerRunnerState {
    private var transport: CodexAppServerTransport?

    func setTransport(_ transport: CodexAppServerTransport) {
        self.transport = transport
    }

    func clearTransport(_ candidate: CodexAppServerTransport?) {
        guard transport === candidate else { return }
        transport = nil
    }

    func cancel() async {
        await transport?.terminate()
        transport = nil
    }
}

private enum CodexAppServerRunnerError: LocalizedError {
    case codexNotFound
    case missingThreadID
    case invalidMCPConfig(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "codex CLI is not installed or not in PATH."
        case .missingThreadID:
            return "Codex app-server did not return a thread id."
        case .invalidMCPConfig(let path):
            return "Invalid MCP config: \(path)"
        }
    }
}

private enum CodexAppServerCommandLocator {
    static func requireCodexBinary() throws -> String {
        guard let path = findCodexBinary() else {
            throw CodexAppServerRunnerError.codexNotFound
        }
        return path
    }

    static func findCodexBinary() -> String? {
        if let configured = ProcessInfo.processInfo.environment["CODEX_BIN"],
           FileManager.default.isExecutableFile(atPath: configured)
        {
            return configured
        }

        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct CodexAppServerRuntimeConfig {
    var configOverrides: [String]
    var mcpServerNames: [String]

    init(context: AgentRunnerContext) throws {
        guard let mcpConfigPath = context.mcpConfigPath else {
            self.configOverrides = []
            self.mcpServerNames = []
            return
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: mcpConfigPath))
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let servers = root["mcpServers"] as? [String: Any]
        else {
            throw CodexAppServerRunnerError.invalidMCPConfig(mcpConfigPath)
        }

        var overrides: [String] = []
        var names: [String] = []
        for (name, rawServer) in servers.sorted(by: { $0.key < $1.key }) {
            guard
                let server = rawServer as? [String: Any],
                let url = server["url"] as? String
            else {
                continue
            }
            let normalizedName = Self.normalizeMCPName(name)
            names.append(normalizedName)
            overrides.append("mcp_servers.\(normalizedName).type=\"http\"")
            overrides.append("mcp_servers.\(normalizedName).url=\(CodexTOML.string(url))")
            if let headers = server["headers"] as? [String: String], !headers.isEmpty {
                overrides.append("mcp_servers.\(normalizedName).headers=\(CodexTOML.inlineTable(headers))")
            }
        }
        overrides.append("tools.web_search=true")
        self.configOverrides = overrides
        self.mcpServerNames = names
    }

    private static func normalizeMCPName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars)
        return result.isEmpty ? "mcp-server" : result
    }
}

private enum CodexTOML {
    static func string(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            .dropFirst()
            .dropLast()
            .description
    }

    static func inlineTable(_ value: [String: String]) -> String {
        let pairs = value
            .sorted(by: { $0.key < $1.key })
            .map { "\(string($0.key)) = \(string($0.value))" }
            .joined(separator: ", ")
        return "{ \(pairs) }"
    }
}

private enum CodexJSON {
    static func stringify(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return String(describing: value)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func object(from json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

private actor CodexAppServerTransport {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var nextID = 1
    private var buffer = ""
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var notifications: [String] = []
    private var notificationWaiters: [CheckedContinuation<String?, Never>] = []
    private var terminated = false

    init(codexBinary: String, configOverrides: [String]) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: codexBinary)
        process.arguments = ["app-server"] + configOverrides.flatMap { ["-c", $0] }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.stdout = output.fileHandleForReading
        self.stderr = error.fileHandleForReading

        self.stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task {
                await self?.handleStdout(data)
            }
        }
        self.stderr.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FileHandle.standardError.write(Data("[codex/app-server:stderr] \(text)".utf8))
            }
        }
        self.process.terminationHandler = { [weak self] _ in
            Task {
                await self?.finish()
            }
        }
        try process.run()
    }

    func send(method: String, paramsJSON: String? = nil) async throws -> String {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try writeRequest(method: method, id: id, paramsJSON: paramsJSON)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(method: String, paramsJSON: String) async {
        try? writeRaw(#"{"method":\#(CodexTOML.string(method)),"params":\#(paramsJSON)}"#)
    }

    func nextNotification() async -> String? {
        if !notifications.isEmpty {
            let next = notifications.removeFirst()
            return next
        }
        if terminated {
            return nil
        }

        return await withCheckedContinuation { continuation in
            if !notifications.isEmpty {
                continuation.resume(returning: notifications.removeFirst())
            } else if terminated {
                continuation.resume(returning: nil)
            } else {
                notificationWaiters.append(continuation)
            }
        }
    }

    func terminate() async {
        finish()
        if process.isRunning {
            process.terminate()
        }
    }

    private func handleStdout(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk
        let parts = buffer.components(separatedBy: "\n")
        buffer = parts.last ?? ""
        let lines = Array(parts.dropLast())

        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let message = try? CodexJSON.object(from: line) else {
            return
        }

        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: NSError(
                    domain: "CodexAppServer",
                    code: error["code"] as? Int ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex app-server request failed"]
                ))
            } else {
                continuation.resume(returning: try! CodexJSON.stringify(message["result"] ?? [:]))
            }
            return
        }

        if message["id"] != nil, message["method"] is String {
            respondToServerRequest(message)
            return
        }

        if let waiter = notificationWaiters.first {
            notificationWaiters.removeFirst()
            waiter.resume(returning: line)
        } else {
            notifications.append(line)
        }
    }

    private func respondToServerRequest(_ message: [String: Any]) {
        guard let id = message["id"] else { return }
        let method = message["method"] as? String
        let result: Any
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = "accept"
        case "tool/requestUserInput":
            result = ["selectedOptionId": "accept"]
        default:
            result = NSNull()
        }
        let idJSON = (id as? String).map(CodexTOML.string) ?? "\(id)"
        let resultJSON = (try? CodexJSON.stringify(result)) ?? "null"
        try? writeRaw(#"{"id":\#(idJSON),"result":\#(resultJSON)}"#)
    }

    private func writeRequest(method: String, id: Int, paramsJSON: String?) throws {
        let payload: String
        if let paramsJSON {
            payload = #"{"method":\#(CodexTOML.string(method)),"id":\#(id),"params":\#(paramsJSON)}"#
        } else {
            payload = #"{"method":\#(CodexTOML.string(method)),"id":\#(id)}"#
        }
        try writeRaw(payload)
    }

    private func writeRaw(_ payload: String) throws {
        stdin.write(Data(payload.utf8))
        stdin.write(Data("\n".utf8))
    }

    private func finish() {
        guard !terminated else { return }
        terminated = true
        let waiters = notificationWaiters
        notificationWaiters = []
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

private enum CodexSkillInputResolver {
    static func skillInputs(pluginRootPath: String?, prompt: String) throws -> [[String: Any]] {
        guard let pluginRootPath else { return [] }
        let skillsURL = URL(fileURLWithPath: pluginRootPath).appendingPathComponent("skills", isDirectory: true)
        guard FileManager.default.fileExists(atPath: skillsURL.path) else { return [] }

        let entries = try FileManager.default.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let loweredPrompt = prompt.lowercased()
        return try entries.compactMap { entry in
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            guard isDirectory else { return nil }
            let skillPath = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillPath.path) else { return nil }
            let raw = try String(contentsOf: skillPath, encoding: .utf8)
            let name = parseName(raw) ?? entry.lastPathComponent
            guard loweredPrompt.contains(entry.lastPathComponent.lowercased()) || loweredPrompt.contains(name.lowercased()) else {
                return nil
            }
            return ["type": "skill", "name": name, "path": skillPath.path]
        }
    }

    private static func parseName(_ raw: String) -> String? {
        guard raw.hasPrefix("---"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) else {
            return nil
        }
        let frontmatter = raw[raw.index(raw.startIndex, offsetBy: 3)..<end.lowerBound]
        return frontmatter
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("name:") }?
            .replacingOccurrences(of: "name:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    }
}
