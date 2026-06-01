import AIBGateway
import AIBRuntimeCore
import Foundation
import Logging

/// Handles agent HTTP requests locally via CodexAppServerAgentRunner.
///
/// Intercepts `/agent/chat` and `/a2a` endpoints and processes them
/// using Codex App Server CLI (subscription auth) instead of the container.
/// Returns nil for other paths so the gateway falls through to the container proxy.
public enum LocalAgentHandler {
    public static func cancelAllAsyncRuns() async {
        await LocalAgentAsyncRunRegistry.shared.cancelAll()
    }


    /// Build a local handler for an agent service.
    public static func makeHandler(
        serviceID: ServiceID,
        pluginRootPath: String?,
        executionDirectory: String?,
        model: String?,
        reasoningEffort: String?,
        logger: Logger
    ) -> LocalRequestHandler {
        let runner = CodexAppServerAgentRunner(model: model, reasoningEffort: reasoningEffort, logger: logger)
        let serviceIDString = serviceID.rawValue
        let log = logger

        return { request in
            let path = request.path.hasPrefix("/") ? request.path : "/\(request.path)"

            switch (request.method.uppercased(), path) {
            case ("GET", "/health"), ("GET", "/health/live"), ("GET", "/health/ready"):
                return handleHealth()

            case ("GET", "/.well-known/agent.json"):
                log.info("[local] \(request.method) \(path) → Codex App Server (Agent Card)", metadata: ["service_id": "\(serviceIDString)"])
                return handleAgentCard(serviceID: serviceIDString, pluginRootPath: pluginRootPath)

            case ("POST", "/agent/chat"):
                log.info("[local] \(request.method) \(path) → Codex App Server", metadata: ["service_id": "\(serviceIDString)"])
                if prefersAsyncResponse(request.headers) {
                    return try await handleAsyncChat(
                        request: request,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        serviceID: serviceIDString,
                        pluginRootPath: pluginRootPath,
                        executionDirectory: executionDirectory,
                        logger: log
                    )
                }
                return try await handleChat(
                    request: request,
                    runner: runner,
                    serviceID: serviceIDString,
                    pluginRootPath: pluginRootPath,
                    executionDirectory: executionDirectory,
                    logger: log
                )

            case ("POST", "/a2a"):
                log.info("[local] \(request.method) \(path) → Codex App Server (A2A)", metadata: ["service_id": "\(serviceIDString)"])
                return try await handleA2A(
                    request: request,
                    runner: runner,
                    serviceID: serviceIDString,
                    pluginRootPath: pluginRootPath,
                    executionDirectory: executionDirectory
                )

            default:
                return nil
            }
        }
    }

    // MARK: - Health

    private static func handleHealth() -> LocalResponse {
        let body = try! JSONSerialization.data(withJSONObject: ["status": "ok"])
        return LocalResponse(
            statusCode: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        )
    }

    private static func handleAgentCard(serviceID: String, pluginRootPath: String?) -> LocalResponse {
        let pluginSkills = (try? CodexSkillInputResolver.agentCardSkills(pluginRootPath: pluginRootPath)) ?? []
        let card = A2AAgentCard(
            name: serviceID,
            description: "Local Codex App Server agent",
            capabilities: A2ACapabilities(streaming: false, pushNotifications: false),
            defaultInputModes: ["text"],
            defaultOutputModes: ["text"],
            skills: [
                A2ASkill(
                    id: serviceID,
                    name: serviceID,
                    description: "Local Codex App Server-backed agent"
                ),
            ] + pluginSkills
        )

        do {
            let body = try JSONEncoder().encode(card)
            return LocalResponse(
                statusCode: 200,
                headers: [("Content-Type", "application/json")],
                body: body
            )
        } catch {
            let fallback = """
            {"error":"failed_to_encode_agent_card","service_id":"\(serviceID)"}
            """
            return LocalResponse(
                statusCode: 500,
                headers: [("Content-Type", "application/json")],
                body: Data(fallback.utf8)
            )
        }
    }

    // MARK: - Chat

    private static func handleChat(
        request: LocalRequest,
        runner: CodexAppServerAgentRunner,
        serviceID: String,
        pluginRootPath: String?,
        executionDirectory: String?,
        logger: Logger
    ) async throws -> LocalResponse {
        let preparedRun: PreparedChatRun
        do {
            preparedRun = try prepareChatRun(
                request: request,
                serviceID: serviceID,
                pluginRootPath: pluginRootPath,
                executionDirectory: executionDirectory,
                logger: logger
            )
        } catch let error as ChatRequestPreparationError {
            return error.response
        }

        defer {
            cleanupPreparedChatRun(preparedRun)
        }

        // Collect SSE events
        var sseBody = Data()
        var eventID = 0

        func appendSSE(event: String, data: Data) {
            let dataStr = String(data: data, encoding: .utf8) ?? ""
            let line = "id: \(eventID)\nevent: \(event)\ndata: \(dataStr)\n\n"
            sseBody.append(Data(line.utf8))
            eventID += 1
        }

        for try await event in runner.send(message: preparedRun.prompt, context: preparedRun.context) {
            switch event {
            case .textDelta(let text):
                let payload = try JSONSerialization.data(withJSONObject: ["text": text])
                appendSSE(event: "text", data: payload)

            case .textComplete(let fullText):
                logger.info(
                    "[codex] text complete chars=\(fullText.count)\n\(fullText)",
                    metadata: ["service_id": "\(serviceID)"]
                )

            case .toolUse(let name):
                logger.info("[codex] tool_use: \(name)", metadata: ["service_id": "\(serviceID)"])
                let payload = try JSONSerialization.data(withJSONObject: ["name": name, "input": [:] as [String: Any]])
                appendSSE(event: "tool_use", data: payload)

            case .toolUseComplete(let name, let input):
                logger.info("[codex] tool_call: \(name)\n\(formatToolInput(input))", metadata: ["service_id": "\(serviceID)"])

            case .toolResult(let toolUseID, let content):
                logger.info("[codex] tool_response: id=\(toolUseID.prefix(12)) chars=\(content.count)\n\(content.prefix(1000))", metadata: ["service_id": "\(serviceID)"])

            case .system(let info):
                let mcpStatus = zip(info.mcpServerNames, info.mcpServerStatuses)
                    .map { "\($0)=\($1)" }.joined(separator: ", ")
                logger.info(
                    "[codex] system session=\(info.sessionID.prefix(8)) model=\(info.model) tools=\(info.tools.count) mcp=[\(mcpStatus)] mode=\(info.permissionMode)",
                    metadata: ["service_id": "\(serviceID)"]
                )

            case .done(let result):
                let cost = result.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "-"
                let turns = result.numTurns.map { "\($0)" } ?? "-"
                let duration = result.durationMS.map { "\($0)ms" } ?? "-"
                logger.info("[codex] done turns=\(turns) cost=\(cost) duration=\(duration)", metadata: ["service_id": "\(serviceID)"])
                let payload = try JSONSerialization.data(withJSONObject: [
                    "duration_ms": result.durationMS ?? 0,
                    "num_turns": result.numTurns ?? 0,
                    "cost": result.totalCostUSD ?? 0,
                    "is_error": false,
                ] as [String: Any])
                appendSSE(event: "result", data: payload)

            case .error(let message):
                logger.error("[codex] error: \(message)", metadata: ["service_id": "\(serviceID)"])
                let payload = try JSONSerialization.data(withJSONObject: ["message": message])
                appendSSE(event: "error", data: payload)
            }
        }

        return LocalResponse(
            statusCode: 200,
            headers: [
                ("Content-Type", "text/event-stream"),
                ("Cache-Control", "no-cache"),
                ("Connection", "keep-alive"),
            ],
            body: sseBody
        )
    }

    private static func handleAsyncChat(
        request: LocalRequest,
        model: String?,
        reasoningEffort: String?,
        serviceID: String,
        pluginRootPath: String?,
        executionDirectory: String?,
        logger: Logger
    ) async throws -> LocalResponse {
        let preparedRun: PreparedChatRun
        do {
            preparedRun = try prepareChatRun(
                request: request,
                serviceID: serviceID,
                pluginRootPath: pluginRootPath,
                executionDirectory: executionDirectory,
                logger: logger
            )
        } catch let error as ChatRequestPreparationError {
            return error.response
        }

        logger.info(
            "[local] accepted async chat request",
            metadata: [
                "service_id": "\(serviceID)",
                "prompt_chars": "\(preparedRun.prompt.count)",
            ]
        )

        let runID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            let runner = CodexAppServerAgentRunner(model: model, reasoningEffort: reasoningEffort, logger: logger)

            defer {
                cleanupPreparedChatRun(preparedRun)
                Task {
                    await LocalAgentAsyncRunRegistry.shared.finish(runID: runID)
                }
            }

            await withTaskCancellationHandler {
                do {
                    for try await event in runner.send(message: preparedRun.prompt, context: preparedRun.context) {
                        switch event {
                        case .textDelta:
                            break
                        case .textComplete(let fullText):
                            logger.info(
                                "[codex] async text complete chars=\(fullText.count)\n\(fullText)",
                                metadata: ["service_id": "\(serviceID)"]
                            )
                        case .toolUse(let name):
                            logger.info("[codex] tool_use: \(name)", metadata: ["service_id": "\(serviceID)"])
                        case .toolUseComplete(let name, let input):
                            logger.info("[codex] tool_call: \(name)\n\(formatToolInput(input))", metadata: ["service_id": "\(serviceID)"])
                        case .toolResult(let toolUseID, let content):
                            logger.info("[codex] tool_response: id=\(toolUseID.prefix(12)) chars=\(content.count)\n\(content.prefix(1000))", metadata: ["service_id": "\(serviceID)"])
                        case .system(let info):
                            let mcpStatus = zip(info.mcpServerNames, info.mcpServerStatuses)
                                .map { "\($0)=\($1)" }.joined(separator: ", ")
                            logger.info(
                                "[codex] system session=\(info.sessionID.prefix(8)) model=\(info.model) tools=\(info.tools.count) mcp=[\(mcpStatus)] mode=\(info.permissionMode)",
                                metadata: ["service_id": "\(serviceID)"]
                            )
                        case .done(let result):
                            let cost = result.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "-"
                            let turns = result.numTurns.map { "\($0)" } ?? "-"
                            let duration = result.durationMS.map { "\($0)ms" } ?? "-"
                            logger.info(
                                "[codex] async done turns=\(turns) cost=\(cost) duration=\(duration)",
                                metadata: ["service_id": "\(serviceID)"]
                            )
                        case .error(let message):
                            logger.error("[codex] async error: \(message)", metadata: ["service_id": "\(serviceID)"])
                        }
                    }
                } catch {
                    logger.error(
                        "[codex] async run failed: \(error.localizedDescription)",
                        metadata: ["service_id": "\(serviceID)"]
                    )
                }
            } onCancel: {
                Task {
                    await runner.cancel()
                }
            }
        }

        let registration = await LocalAgentAsyncRunRegistry.shared.register(
            runID: runID,
            serviceID: serviceID,
            duplicateKey: preparedRun.duplicateRunKey,
            task: task
        )
        if registration.replacedRunID != nil {
            logger.warning(
                "[local] replaced existing async chat run",
                metadata: [
                    "service_id": "\(serviceID)",
                    "run_key": "\(preparedRun.duplicateRunKey ?? "-")",
                ]
            )
        }

        let body = try JSONSerialization.data(withJSONObject: ["accepted": true])
        return LocalResponse(
            statusCode: 202,
            headers: [
                ("Content-Type", "application/json"),
                ("Preference-Applied", "respond-async"),
            ],
            body: body
        )
    }

    // MARK: - A2A

    private static func handleA2A(
        request: LocalRequest,
        runner: CodexAppServerAgentRunner,
        serviceID: String,
        pluginRootPath: String?,
        executionDirectory: String?,
    ) async throws -> LocalResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return jsonRPCError(id: nil, code: -32700, message: "Parse error")
        }

        let rpcID = json["id"]
        let method = json["method"] as? String

        guard json["jsonrpc"] as? String == "2.0", method == "message/send" else {
            return jsonRPCError(id: rpcID, code: -32601, message: "Method not found: \(method ?? "nil")")
        }

        guard let params = json["params"] as? [String: Any],
              let message = params["message"] as? [String: Any],
              let parts = message["parts"] as? [[String: Any]] else {
            return jsonRPCError(id: rpcID, code: -32602, message: "Invalid params")
        }

        let userText = parts
            .filter { ($0["kind"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard !userText.isEmpty else {
            return jsonRPCError(id: rpcID, code: -32602, message: "No text content in message")
        }

        let context = AgentRunnerContext(
            serviceID: serviceID,
            pluginRootPath: pluginRootPath,
            mcpConfigPath: pluginRootPath.map { CodexAppServerPluginBundle.mcpConfigPath(pluginRootPath: $0) },
            executionDirectory: executionDirectory
        )

        var textParts: [String] = []

        for try await event in runner.send(message: userText, context: context) {
            switch event {
            case .textDelta(let text):
                textParts.append(text)
            case .textComplete(let full):
                textParts = [full]
            default:
                break
            }
        }

        let responseText = textParts.joined()
        let contextId = (message["contextId"] as? String) ?? UUID().uuidString

        let result: [String: Any] = [
            "jsonrpc": "2.0",
            "id": rpcID ?? NSNull(),
            "result": [
                "role": "agent",
                "parts": [["kind": "text", "text": responseText]],
                "messageId": UUID().uuidString,
                "contextId": contextId,
            ] as [String: Any],
        ]
        let body = try JSONSerialization.data(withJSONObject: result)
        return LocalResponse(
            statusCode: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        )
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> LocalResponse {
        let result: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message] as [String: Any],
        ]
        let body = try! JSONSerialization.data(withJSONObject: result)
        return LocalResponse(
            statusCode: 200,
            headers: [("Content-Type", "application/json")],
            body: body
        )
    }

    private struct PreparedChatRun {
        var prompt: String
        var context: AgentRunnerContext
        var tempMCPConfigURL: URL?
        var duplicateRunKey: String?
    }

    private struct ChatRequestPreparationError: Error {
        var response: LocalResponse
    }

    private static func prepareChatRun(
        request: LocalRequest,
        serviceID: String,
        pluginRootPath: String?,
        executionDirectory: String?,
        logger: Logger
    ) throws -> PreparedChatRun {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            let errBody = try JSONSerialization.data(withJSONObject: ["error": "prompt is required"])
            throw ChatRequestPreparationError(
                response: LocalResponse(
                    statusCode: 400,
                    headers: [("Content-Type", "application/json")],
                    body: errBody
                )
            )
        }

        let rawRequestContext = json["context"] as? [String: Any]
        let requestContext = rawRequestContext.map(normalizedMCPContext)
        let baseMCPConfigPath = pluginRootPath.map { CodexAppServerPluginBundle.mcpConfigPath(pluginRootPath: $0) }
        let effectiveMCPConfigPath: String?
        let tempMCPConfigURL: URL?
        if let requestContext, let basePath = baseMCPConfigPath {
            let injected = try injectContextIntoMCPConfig(basePath: basePath, context: requestContext)
            effectiveMCPConfigPath = injected.path
            tempMCPConfigURL = injected.tempURL
        } else {
            effectiveMCPConfigPath = baseMCPConfigPath
            tempMCPConfigURL = nil
        }

        logger.info(
            "[local] prepared chat MCP context",
            metadata: [
                "service_id": "\(serviceID)",
                "has_context": "\(rawRequestContext != nil)",
                "context_keys": "\(rawRequestContext?.keys.sorted().joined(separator: ",") ?? "-")",
                "normalized_context_keys": "\(requestContext?.keys.sorted().joined(separator: ",") ?? "-")",
                "mcp_context_injected": "\(tempMCPConfigURL != nil)",
                "mcp_config": "\(effectiveMCPConfigPath ?? "-")",
            ]
        )

        let requestedSkillID = stringContextValue(requestContext, keys: ["skill", "skillName", "job"])
        let requiredSkill = requestedSkillID ?? CodexSkillInputResolver.requiredSkillID(prompt: prompt)
        let selectedSkillIDs = (try? CodexSkillInputResolver.selectedSkillIDs(
            pluginRootPath: pluginRootPath,
            prompt: prompt,
            requestedSkillID: requestedSkillID
        )) ?? []
        logger.info(
            "[local] prepared chat Codex skills",
            metadata: [
                "service_id": "\(serviceID)",
                "required_skill": "\(requiredSkill ?? "-")",
                "selected_skill_count": "\(selectedSkillIDs.count)",
                "selected_skills": "\(selectedSkillIDs.isEmpty ? "-" : selectedSkillIDs.joined(separator: ","))",
            ]
        )
        if let requiredSkill, selectedSkillIDs.isEmpty {
            let message = "Required Codex skill is unavailable before execution: \(requiredSkill)"
            logger.error(
                "[local] prepared chat Codex skills failed",
                metadata: [
                    "service_id": "\(serviceID)",
                    "required_skill": "\(requiredSkill)",
                ]
            )
            let errBody = try JSONSerialization.data(withJSONObject: ["error": message])
            throw ChatRequestPreparationError(
                response: LocalResponse(
                    statusCode: 422,
                    headers: [("Content-Type", "application/json")],
                    body: errBody
                )
            )
        }

        return PreparedChatRun(
            prompt: prompt,
            context: AgentRunnerContext(
                serviceID: serviceID,
                pluginRootPath: pluginRootPath,
                mcpConfigPath: effectiveMCPConfigPath,
                executionDirectory: executionDirectory,
                requestedSkillID: requestedSkillID
            ),
            tempMCPConfigURL: tempMCPConfigURL,
            duplicateRunKey: duplicateRunKey(
                serviceID: serviceID,
                requestContext: requestContext,
                prompt: prompt
            )
        )
    }

    private static func cleanupPreparedChatRun(_ preparedRun: PreparedChatRun) {
        if let url = preparedRun.tempMCPConfigURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private static func prefersAsyncResponse(_ headers: [(String, String)]) -> Bool {
        headers.contains { name, value in
            name.caseInsensitiveCompare("Prefer") == .orderedSame
                && value.localizedCaseInsensitiveContains("respond-async")
        }
    }

    private static func duplicateRunKey(
        serviceID: String,
        requestContext: [String: Any]?,
        prompt: String
    ) -> String? {
        if let proposalID = stringContextValue(requestContext, keys: ["proposal_id", "proposalId"]),
           !proposalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(serviceID):proposal:\(proposalID)"
        }

        if let organizationID = stringContextValue(requestContext, keys: ["organization_id", "organizationId", "orgId"]),
           !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(serviceID):organization:\(organizationID):prompt:\(prompt.hashValue)"
        }

        return nil
    }

    // MARK: - Context Injection

    private static func normalizedMCPContext(_ context: [String: Any]) -> [String: Any] {
        var normalized = context

        assignStringContextValue(&normalized, targetKey: "user_id", sourceKeys: ["user_id", "userId"])
        assignStringContextValue(&normalized, targetKey: "organization_id", sourceKeys: ["organization_id", "organizationId", "orgId"])
        assignStringContextValue(&normalized, targetKey: "proposal_id", sourceKeys: ["proposal_id", "proposalId"])
        assignStringContextValue(&normalized, targetKey: "target_id", sourceKeys: ["target_id", "targetId"])
        assignStringContextValue(&normalized, targetKey: "research_run_id", sourceKeys: ["research_run_id", "researchRunId"])

        return normalized
    }

    private static func assignStringContextValue(
        _ context: inout [String: Any],
        targetKey: String,
        sourceKeys: [String]
    ) {
        guard let value = stringContextValue(context, keys: sourceKeys) else {
            return
        }
        context[targetKey] = value
    }

    private static func stringContextValue(_ context: [String: Any]?, keys: [String]) -> String? {
        guard let context else {
            return nil
        }
        for key in keys {
            if let value = context[key] as? String {
                return value
            }
        }
        return nil
    }

    /// Read the base .mcp.json, inject X-Context header into all HTTP servers,
    /// write to a temp file, and return the temp path.
    private static func injectContextIntoMCPConfig(
        basePath: String,
        context: [String: Any]
    ) throws -> (path: String, tempURL: URL) {
        let baseData = try Data(contentsOf: URL(fileURLWithPath: basePath))
        guard var config = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            throw NSError(domain: "LocalAgentHandler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid MCP config"])
        }

        let contextJSON = try JSONSerialization.data(withJSONObject: context)
        let contextString = String(data: contextJSON, encoding: .utf8) ?? "{}"

        if var servers = config["mcpServers"] as? [String: Any] {
            for (name, serverAny) in servers {
                guard var server = serverAny as? [String: Any],
                      (server["type"] as? String) == "http" else { continue }
                var headers = stringHeaders(server["headers"])
                headers["X-Context"] = contextString
                server["headers"] = headers
                servers[name] = server
            }
            config["mcpServers"] = servers
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aib-mcp-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(".mcp.json")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: tempFile)

        // Log is handled by the caller
        return (tempFile.path, tempFile)
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

    /// Format a JSON input string for readable log output.
    /// Parses the JSON and re-serializes with pretty printing and unescaped slashes.
    private static func formatToolInput(_ input: String, maxLength: Int = 500) -> String {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return String(input.prefix(maxLength))
        }
        let result = String(str.prefix(maxLength))
        return result
    }
}
