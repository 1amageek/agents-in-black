import AIBRuntimeCore
import Foundation
import Logging

public final class CodexAppServerAgentRunner: AgentRunner {
    private let model: String?
    private let reasoningEffort: String?
    private let logger: Logger?
    private let state = CodexAppServerRunnerState()

    public init(model: String? = nil, reasoningEffort: String? = nil, logger: Logger? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.logger = logger
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
                    let environment = try CodexAppServerEnvironment.processEnvironment(context: context)
                    logger?.info(
                        "[codex/app-server] launching transport",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "codex_binary": "\(codexBinary)",
                            "mcp_servers": "\(config.mcpServerNames.joined(separator: ","))",
                            "override_count": "\(config.configOverrides.count)",
                            "codex_home": "\(environment["CODEX_HOME"] ?? "-")",
                            "cwd": "\(context.executionDirectory ?? FileManager.default.currentDirectoryPath)",
                        ]
                    )
                    let runtime = try CodexAppServerTransport(
                        codexBinary: codexBinary,
                        configOverrides: config.configOverrides,
                        environment: environment
                    )
                    transport = runtime
                    await state.setTransport(runtime)

                    logger?.info("[codex/app-server] request initialize", metadata: ["service_id": "\(context.serviceID)"])
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
                    logger?.info("[codex/app-server] response initialize", metadata: ["service_id": "\(context.serviceID)"])
                    logger?.info("[codex/app-server] notify initialized", metadata: ["service_id": "\(context.serviceID)"])
                    await runtime.notify(method: "initialized", paramsJSON: "{}")

                    let effectiveModel = model ?? ProcessInfo.processInfo.environment["MODEL"] ?? "gpt-5.5"
                    logger?.info(
                        "[codex/app-server] request thread/start",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "model": "\(effectiveModel)",
                        ]
                    )
                    let threadResponseJSON = try await runtime.send(
                        method: "thread/start",
                        paramsJSON: try CodexJSON.stringify([
                            "model": effectiveModel,
                            "cwd": context.executionDirectory ?? FileManager.default.currentDirectoryPath,
                            "approvalPolicy": "never",
                            "sandbox": "workspace-write",
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
                    logger?.info(
                        "[codex/app-server] response thread/start",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "thread_id": "\(threadID)",
                        ]
                    )

                    continuation.yield(.system(AgentRunnerSystemInfo(
                        sessionID: threadID,
                        model: effectiveModel,
                        tools: [],
                        mcpServerNames: config.mcpServerNames,
                        mcpServerStatuses: config.mcpServerNames.map { _ in "configured" },
                        permissionMode: "never"
                    )))

                    let skillInputs = try CodexSkillInputResolver.skillInputs(
                        pluginRootPath: context.pluginRootPath,
                        prompt: message,
                        requestedSkillID: context.requestedSkillID
                    )
                    if let requiredSkill = context.requestedSkillID ?? CodexSkillInputResolver.requiredSkillID(prompt: message),
                       !skillInputs.contains(where: {
                           guard let name = $0["name"] as? String else { return false }
                           return CodexSkillInputResolver.matchesRequiredSkill(name, requiredSkill: requiredSkill)
                       })
                    {
                        throw CodexAppServerRunnerError.requiredSkillUnavailable(requiredSkill)
                    }

                    if !skillInputs.isEmpty {
                        let skillNames = skillInputs.compactMap { $0["name"] as? String }.joined(separator: ",")
                        FileHandle.standardError.write(Data("[codex/app-server:skills] attached=\(skillNames)\n".utf8))
                    }

                    var input: [[String: Any]] = [["type": "text", "text": message]]
                    input.append(contentsOf: skillInputs)

                    logger?.info(
                        "[codex/app-server] request turn/start",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "thread_id": "\(threadID)",
                            "input_count": "\(input.count)",
                            "mcp_servers": "\(config.mcpServerNames.joined(separator: ","))",
                        ]
                    )
                    _ = try await runtime.send(
                        method: "turn/start",
                        paramsJSON: try CodexJSON.stringify([
                            "threadId": threadID,
                            "input": input,
                            "cwd": context.executionDirectory ?? FileManager.default.currentDirectoryPath,
                            "model": effectiveModel,
                            "effort": resolveReasoningEffort(),
                            "approvalPolicy": "never",
                            "sandboxPolicy": CodexAppServerSandboxPolicy.workspaceWrite(
                                executionDirectory: context.executionDirectory
                            ),
                        ])
                    )
                    logger?.info(
                        "[codex/app-server] response turn/start",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "thread_id": "\(threadID)",
                        ]
                    )

                    var finalText = ""
                    var completed = false
                    while !completed {
                        guard let notificationJSON = await runtime.nextNotification() else {
                            logger?.warning(
                                "[codex/app-server] notification stream ended before turn completion",
                                metadata: [
                                    "service_id": "\(context.serviceID)",
                                    "thread_id": "\(threadID)",
                                ]
                            )
                            break
                        }
                        let notification = try CodexJSON.object(from: notificationJSON)
                        let method = notification["method"] as? String
                        let params = notification["params"] as? [String: Any] ?? [:]
                        logger?.info(
                            "[codex/app-server] notification",
                            metadata: notificationMetadata(
                                serviceID: context.serviceID,
                                threadID: threadID,
                                method: method,
                                params: params
                            )
                        )

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
                                logger?.info(
                                    "[codex/app-server] mcp tool started",
                                    metadata: itemMetadata(
                                        serviceID: context.serviceID,
                                        threadID: threadID,
                                        item: item
                                    )
                                )
                                continuation.yield(.toolUse(name: "\(server).\(tool)"))
                            }
                        case "item/completed":
                            guard let item = params["item"] as? [String: Any] else { break }
                            if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                                finalText = text
                            } else if item["type"] as? String == "mcpToolCall" {
                                logger?.info(
                                    "[codex/app-server] mcp tool completed",
                                    metadata: itemMetadata(
                                        serviceID: context.serviceID,
                                        threadID: threadID,
                                        item: item
                                    )
                                )
                                let content = try CodexJSON.stringify(item["result"] ?? item["error"] ?? [:])
                                continuation.yield(.toolResult(
                                    toolUseID: item["id"] as? String ?? "",
                                    content: content
                                ))
                            }
                        case "turn/completed":
                            let turn = params["turn"] as? [String: Any]
                            let status = turn?["status"] as? String
                            logger?.info(
                                "[codex/app-server] turn completed",
                                metadata: [
                                    "service_id": "\(context.serviceID)",
                                    "thread_id": "\(threadID)",
                                    "status": "\(status ?? "-")",
                                ]
                            )
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
                            logger?.error(
                                "[codex/app-server] error notification",
                                metadata: [
                                    "service_id": "\(context.serviceID)",
                                    "thread_id": "\(threadID)",
                                    "message": "\(error?["message"] as? String ?? "Codex app-server error")",
                                ]
                            )
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
                    logger?.error(
                        "[codex/app-server] send failed",
                        metadata: [
                            "service_id": "\(context.serviceID)",
                            "error": "\(error.localizedDescription)",
                        ]
                    )
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
        let value = reasoningEffort
            ?? ProcessInfo.processInfo.environment["CODEX_REASONING_EFFORT"]
            ?? ProcessInfo.processInfo.environment["MODEL_REASONING_EFFORT"]
        guard let value, let effort = AIBReasoningEffort(rawValue: value) else {
            return AIBReasoningEffort.defaultAgent.rawValue
        }
        return effort.rawValue
    }

    private func notificationMetadata(
        serviceID: String,
        threadID: String,
        method: String?,
        params: [String: Any]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "service_id": "\(serviceID)",
            "thread_id": "\(threadID)",
            "method": "\(method ?? "-")",
        ]
        if let item = params["item"] as? [String: Any] {
            for (key, value) in itemMetadata(serviceID: serviceID, threadID: threadID, item: item) {
                metadata[key] = value
            }
        }
        if let turn = params["turn"] as? [String: Any], let status = turn["status"] {
            metadata["turn_status"] = "\(status)"
        }
        return metadata
    }

    private func itemMetadata(
        serviceID: String,
        threadID: String,
        item: [String: Any]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "service_id": "\(serviceID)",
            "thread_id": "\(threadID)",
            "item_type": "\(item["type"] as? String ?? "-")",
            "item_id": "\(item["id"] as? String ?? "-")",
            "has_result": "\(item["result"] != nil)",
            "has_error": "\(item["error"] != nil)",
        ]
        if let server = item["server"] as? String {
            metadata["mcp_server"] = "\(server)"
        }
        if let tool = item["tool"] as? String {
            metadata["mcp_tool"] = "\(tool)"
        }
        if let status = item["status"] as? String {
            metadata["item_status"] = "\(status)"
        }
        return metadata
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
    case requiredSkillUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "codex CLI is not installed or not in PATH."
        case .missingThreadID:
            return "Codex app-server did not return a thread id."
        case .invalidMCPConfig(let path):
            return "Invalid MCP config: \(path)"
        case .requiredSkillUnavailable(let skillID):
            return "Required skill is unavailable before execution: \(skillID)"
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

struct CodexAppServerRuntimeConfig {
    var configOverrides: [String]
    var mcpServerNames: [String]

    init(context: AgentRunnerContext) throws {
        var overrides = CodexAppServerRuntimePolicy.closedEnvironmentOverrides

        guard let mcpConfigPath = Self.resolvedMCPConfigPath(context: context) else {
            self.configOverrides = overrides
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
            let headers = Self.stringHeaders(server["headers"])
            if !headers.isEmpty {
                overrides.append("mcp_servers.\(normalizedName).http_headers=\(CodexTOML.inlineTable(headers))")
            }
        }
        self.configOverrides = overrides
        self.mcpServerNames = names
    }

    private static func normalizeMCPName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(scalars)
        return result.isEmpty ? "mcp-server" : result
    }

    private static func resolvedMCPConfigPath(context: AgentRunnerContext) -> String? {
        if let mcpConfigPath = context.mcpConfigPath, !mcpConfigPath.isEmpty {
            return mcpConfigPath
        }

        guard let pluginRootPath = context.pluginRootPath, !pluginRootPath.isEmpty else {
            return nil
        }

        let pluginMCPConfigPath = CodexAppServerPluginBundle.mcpConfigPath(pluginRootPath: pluginRootPath)
        guard FileManager.default.fileExists(atPath: pluginMCPConfigPath) else {
            return nil
        }
        return pluginMCPConfigPath
    }

    private static func stringHeaders(_ rawHeaders: Any?) -> [String: String] {
        guard let rawHeaders = rawHeaders as? [String: Any] else {
            return [:]
        }
        return rawHeaders.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }
}

enum CodexAppServerRuntimePolicy {
    static let closedEnvironmentOverrides = [
        "include_apps_instructions=false",
        "include_environment_context=false",
        "include_permissions_instructions=false",
        "project_doc_max_bytes=0",
        "features.apps=false",
        "features.plugins=false",
        "features.tool_search=false",
        "features.tool_suggest=false",
        "features.image_generation=false",
        "features.browser_use=false",
        "features.computer_use=false",
        "features.enable_mcp_apps=false",
        "features.remote_plugin=false",
        "skills.bundled={enabled=false}",
    ]
}

enum CodexAppServerSandboxPolicy {
    static func workspaceWrite(executionDirectory: String?) -> [String: Any] {
        var policy: [String: Any] = [
            "type": "workspaceWrite",
            "networkAccess": true,
        ]
        if let executionDirectory, !executionDirectory.isEmpty {
            policy["writableRoots"] = [executionDirectory]
        }
        return policy
    }
}

enum CodexAppServerEnvironment {
    static func processEnvironment(
        context: AgentRunnerContext,
        authSourceRoot: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        var environment = baseEnvironment
        let codexHomeURL = writableCodexHomeURL(context: context, baseEnvironment: baseEnvironment)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        if let mountedAuthJSONURL = mountedAuthJSONURL(baseEnvironment: baseEnvironment) {
            try copyAuthJSONFile(from: mountedAuthJSONURL, to: codexHomeURL)
        } else {
            try copyAuthJSON(
                from: authSourceRoot ?? defaultAuthSourceRoot(baseEnvironment: baseEnvironment),
                to: codexHomeURL
            )
        }

        environment["CODEX_HOME"] = codexHomeURL.path
        environment["HOME"] = codexHomeURL.path
        if let pluginRootPath = context.pluginRootPath {
            environment["AIB_PLUGIN_DIR"] = pluginRootPath
            environment["AIB_PLUGIN_SKILLS_DIR"] = CodexAppServerPluginBundle.skillsDirectoryPath(
                pluginRootPath: pluginRootPath
            )
            environment["AIB_SKILL_DISCOVERY_MODE"] = CodexAppServerPluginBundle.closedSkillDiscoveryMode
        }
        return environment
    }

    static func writableCodexHomeURL(
        context: AgentRunnerContext,
        baseEnvironment: [String: String]
    ) -> URL {
        if mountedAuthJSONURL(baseEnvironment: baseEnvironment) != nil,
           let configured = baseEnvironment["CODEX_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return isolatedCodexHomeURL(context: context)
    }

    static func isolatedCodexHomeURL(context: AgentRunnerContext) -> URL {
        if let pluginRootPath = context.pluginRootPath {
            let aibRootURL = URL(fileURLWithPath: pluginRootPath, isDirectory: true)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return aibRootURL
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("codex-home", isDirectory: true)
                .appendingPathComponent(CodexAppServerPluginBundle.sanitizedServiceID(context.serviceID), isDirectory: true)
                .standardizedFileURL
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("aib-codex-home", isDirectory: true)
            .appendingPathComponent(CodexAppServerPluginBundle.sanitizedServiceID(context.serviceID), isDirectory: true)
            .standardizedFileURL
    }

    private static func mountedAuthJSONURL(baseEnvironment: [String: String]) -> URL? {
        guard let configured = baseEnvironment["AIB_CODEX_AUTH_JSON"], !configured.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: configured, isDirectory: false).standardizedFileURL
    }

    private static func defaultAuthSourceRoot(baseEnvironment: [String: String]) -> URL {
        if let configured = baseEnvironment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        let home = baseEnvironment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }

    private static func copyAuthJSON(from sourceRoot: URL, to codexHomeURL: URL) throws {
        let sourceURL = sourceRoot.appendingPathComponent("auth.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        try copyAuthJSONFile(from: sourceURL, to: codexHomeURL)
    }

    private static func copyAuthJSONFile(from sourceURL: URL, to codexHomeURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CodexAppServerEnvironmentError.missingAuthJSON(sourceURL.path)
        }
        let destinationURL = codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

private enum CodexAppServerEnvironmentError: LocalizedError {
    case missingAuthJSON(String)

    var errorDescription: String? {
        switch self {
        case let .missingAuthJSON(path):
            return "Codex auth.json was configured but not found at \(path)"
        }
    }
}

private enum CodexTOML {
    static func string(_ value: String) -> String {
        let escaped = value.map { character -> String in
            switch character {
            case "\\":
                return "\\\\"
            case "\"":
                return "\\\""
            case "\n":
                return "\\n"
            case "\r":
                return "\\r"
            case "\t":
                return "\\t"
            default:
                return String(character)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    static func inlineTable(_ value: [String: String]) -> String {
        let pairs = value
            .sorted(by: { $0.key < $1.key })
            .map { "\(string($0.key)) = \(string($0.value))" }
            .joined(separator: ", ")
        return "{ \(pairs) }"
    }
}

enum CodexJSON {
    static func stringify(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
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

    init(codexBinary: String, configOverrides: [String], environment: [String: String]) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: codexBinary)
        process.arguments = ["app-server"] + configOverrides.flatMap { ["-c", $0] }
        process.environment = environment
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
        do {
            try writeRaw(#"{"method":\#(CodexTOML.string(method)),"params":\#(paramsJSON)}"#)
        } catch {
            finish()
        }
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
        let message: [String: Any]
        do {
            message = try CodexJSON.object(from: line)
        } catch {
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
                do {
                    continuation.resume(returning: try CodexJSON.stringify(message["result"] ?? [:]))
                } catch {
                    continuation.resume(throwing: error)
                }
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
        let params = message["params"] as? [String: Any]
        let result = CodexAppServerServerRequestResponder.result(for: method, params: params)
        let idJSON = (id as? String).map(CodexTOML.string) ?? "\(id)"
        do {
            let resultJSON = try CodexJSON.stringify(result)
            try writeRaw(#"{"id":\#(idJSON),"result":\#(resultJSON)}"#)
        } catch {
            do {
                let messageJSON = CodexTOML.string("Failed to encode app-server response")
                try writeRaw(#"{"id":\#(idJSON),"error":{"code":-32603,"message":\#(messageJSON)}}"#)
            } catch {
                finish()
            }
        }
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

enum CodexAppServerServerRequestResponder {
    static func result(for method: String?, params: [String: Any]? = nil) -> Any {
        switch method {
        case "item/commandExecution/requestApproval":
            return ["decision": "accept"]
        case "item/fileChange/requestApproval":
            return ["decision": "accept"]
        case "applyPatchApproval", "execCommandApproval":
            return ["decision": "approved"]
        case "item/tool/requestUserInput", "tool/requestUserInput":
            return ["answers": [:]]
        case "mcpServer/elicitation/request":
            return mcpElicitationResult(params: params)
        default:
            return NSNull()
        }
    }

    private static func mcpElicitationResult(params: [String: Any]?) -> [String: Any] {
        guard params?["mode"] as? String == "form" else {
            return [
                "action": "decline",
                "content": NSNull(),
            ]
        }

        let schema = params?["requestedSchema"] as? [String: Any]
        return [
            "action": "accept",
            "content": elicitationContent(from: schema),
        ]
    }

    private static func elicitationContent(from schema: [String: Any]?) -> [String: Any] {
        guard let properties = schema?["properties"] as? [String: Any] else {
            return [:]
        }

        let required = Set(schema?["required"] as? [String] ?? [])
        var content: [String: Any] = [:]
        for (key, rawProperty) in properties {
            guard let property = rawProperty as? [String: Any] else { continue }
            if let defaultValue = property["default"], !(defaultValue is NSNull) {
                content[key] = defaultValue
            } else if required.contains(key) {
                content[key] = fallbackValue(for: property)
            }
        }
        return content
    }

    private static func fallbackValue(for property: [String: Any]) -> Any {
        if let enumValues = property["enum"] as? [Any], let first = enumValues.first {
            return first
        }

        switch property["type"] as? String {
        case "boolean":
            return true
        case "integer":
            return 0
        case "number":
            return 0
        case "array":
            return []
        default:
            return ""
        }
    }
}

enum CodexSkillInputResolver {
    static func skillInputs(
        pluginRootPath: String?,
        prompt: String,
        requestedSkillID: String? = nil
    ) throws -> [[String: Any]] {
        try selectedSkillDescriptors(
            pluginRootPath: pluginRootPath,
            prompt: prompt,
            requestedSkillID: requestedSkillID
        ).map { skill in
            [
                "type": "skill",
                "name": skill.appServerName,
                "path": skill.path,
            ]
        }
    }

    static func selectedSkillIDs(
        pluginRootPath: String?,
        prompt: String,
        requestedSkillID: String? = nil
    ) throws -> [String] {
        try selectedSkillDescriptors(
            pluginRootPath: pluginRootPath,
            prompt: prompt,
            requestedSkillID: requestedSkillID
        ).map(\.skillID)
    }

    static func agentCardSkills(pluginRootPath: String?) throws -> [A2ASkill] {
        try discoverSkillDescriptors(pluginRootPath: pluginRootPath).map { skill in
            A2ASkill(
                id: skill.appServerName,
                name: skill.name,
                description: skill.description.isEmpty ? nil : skill.description,
                tags: skill.tags.isEmpty ? nil : skill.tags
            )
        }
    }

    private static func selectedSkillDescriptors(
        pluginRootPath: String?,
        prompt: String,
        requestedSkillID: String?
    ) throws -> [CodexSkillDescriptor] {
        let skills = try discoverSkillDescriptors(pluginRootPath: pluginRootPath)
        guard !skills.isEmpty else { return [] }

        let loweredPrompt = prompt.lowercased()
        let requiredSkill = requestedSkillID ?? requiredSkillID(prompt: prompt)
        if let requiredSkill {
            return skills.filter { skill in
                matchesRequiredSkill(skill.skillID, requiredSkill: requiredSkill) ||
                    matchesRequiredSkill(skill.appServerName, requiredSkill: requiredSkill) ||
                    matchesRequiredSkill(skill.name, requiredSkill: requiredSkill)
            }
        }

        return skills.filter { skill in
            let aliases = [
                skill.skillID,
                skill.appServerName,
                skill.name,
            ] + skill.tags

            return aliases
                .map { $0.lowercased() }
                .contains(where: { !$0.isEmpty && loweredPrompt.contains($0) })
        }
    }

    private static func discoverSkillDescriptors(pluginRootPath: String?) throws -> [CodexSkillDescriptor] {
        guard let pluginRootPath else { return [] }
        let skillsURL = URL(fileURLWithPath: pluginRootPath).appendingPathComponent("skills", isDirectory: true)
        guard FileManager.default.fileExists(atPath: skillsURL.path) else { return [] }

        let entries = try FileManager.default.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let pluginName = pluginName(pluginRootPath: pluginRootPath)
        return try entries.compactMap { entry in
            let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            guard isDirectory else { return nil }
            let skillID = entry.lastPathComponent
            let skillPath = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillPath.path) else { return nil }
            let raw = try String(contentsOf: skillPath, encoding: .utf8)
            let name = parseName(raw) ?? skillID
            let description = parseFrontmatterValue(raw, key: "description") ?? ""
            let tags = parseTags(raw)
            return CodexSkillDescriptor(
                skillID: skillID,
                appServerName: qualifiedSkillName(pluginName: pluginName, skillID: skillID),
                name: name,
                description: description,
                tags: Array(Set([skillID] + tags)).sorted(),
                path: skillPath.path
            )
        }
        .sorted { $0.appServerName < $1.appServerName }
    }

    static func matchesRequiredSkill(_ skillName: String, requiredSkill: String) -> Bool {
        skillName == requiredSkill ||
            skillName.hasSuffix(":\(requiredSkill)") ||
            normalizedSkillKey(skillName) == normalizedSkillKey(requiredSkill)
    }

    static func requiredSkillID(prompt: String) -> String? {
        let patterns = [
            #"(?i)\b(?:MUST\s+)?use\s+the\s+`([^`]+)`\s+skill"#,
            #"(?i)\b(?:required|required\s+specified|mandatory)\s+skill\s*[:=]?\s*`?([A-Za-z0-9:_-]+)`?"#,
            #"(?i)`([^`]+)`\s+skill"#,
            #"(?i)\b([A-Za-z0-9]+[-_:][A-Za-z0-9:_-]+)\s+skill\b"#,
            #"「([^」]+)」skill"#,
            #"「([^」]+)」スキル"#,
            #"([A-Za-z0-9]+[-_:][A-Za-z0-9:_-]+)\s*スキル"#,
        ]
        for pattern in patterns {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                continue
            }
            let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
            guard let match = regex.firstMatch(in: prompt, range: range),
                  match.numberOfRanges > 1,
                  let skillRange = Range(match.range(at: 1), in: prompt) else {
                continue
            }
            let value = String(prompt[skillRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private struct CodexSkillDescriptor {
        var skillID: String
        var appServerName: String
        var name: String
        var description: String
        var tags: [String]
        var path: String
    }

    private static func parseName(_ raw: String) -> String? {
        parseFrontmatterValue(raw, key: "name")
    }

    private static func parseTags(_ raw: String) -> [String] {
        let tags = parseFrontmatterValue(raw, key: "tags") ?? ""
        return tags
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'")) }
            .filter { !$0.isEmpty }
    }

    private static func qualifiedSkillName(pluginName: String?, skillID: String) -> String {
        guard let pluginName, !pluginName.isEmpty else {
            return skillID
        }
        return "\(pluginName):\(skillID)"
    }

    private static func normalizedSkillKey(_ value: String) -> String {
        let localName = value.split(separator: ":").last.map(String.init) ?? value
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var previousWasDash = false
        for scalar in localName.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func pluginName(pluginRootPath: String) -> String? {
        let metadataURL = URL(fileURLWithPath: pluginRootPath)
            .appendingPathComponent(".codex-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let object: [String: Any]
        do {
            let data = try Data(contentsOf: metadataURL)
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            return nil
        }
        guard let name = object["name"] as? String else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseFrontmatterValue(_ raw: String, key: String) -> String? {
        guard raw.hasPrefix("---"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) else {
            return nil
        }
        let frontmatter = raw[raw.index(raw.startIndex, offsetBy: 3)..<end.lowerBound]
        return frontmatter
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("\(key):") }?
            .replacingOccurrences(of: "\(key):", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    }
}
