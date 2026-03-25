import AIBGateway
import AIBRuntimeCore
import Foundation
import Logging

/// Handles agent HTTP requests locally via ClaudeCodeAgentRunner.
///
/// Intercepts `/agent/chat` and `/a2a` endpoints and processes them
/// using Claude Code CLI (subscription auth) instead of the container.
/// Returns nil for other paths so the gateway falls through to the container proxy.
public enum LocalAgentHandler {

    /// Build a local handler for an agent service.
    public static func makeHandler(
        serviceID: ServiceID,
        mcpConfigPath: String?,
        executionDirectory: String?,
        skillOverlayPath: String?,
        model: String?,
        logger: Logger
    ) -> LocalRequestHandler {
        let runner = ClaudeCodeAgentRunner(model: model)
        let serviceIDString = serviceID.rawValue
        let log = logger

        return { request in
            let path = request.path.hasPrefix("/") ? request.path : "/\(request.path)"

            switch (request.method.uppercased(), path) {
            case ("GET", "/health"), ("GET", "/health/live"), ("GET", "/health/ready"):
                return handleHealth()

            case ("POST", "/agent/chat"):
                log.info("[local] \(request.method) \(path) → Claude Code", metadata: ["service_id": "\(serviceIDString)"])
                return try await handleChat(
                    request: request,
                    runner: runner,
                    serviceID: serviceIDString,
                    mcpConfigPath: mcpConfigPath,
                    executionDirectory: executionDirectory,
                    skillOverlayPath: skillOverlayPath,
                    logger: log
                )

            case ("POST", "/a2a"):
                log.info("[local] \(request.method) \(path) → Claude Code (A2A)", metadata: ["service_id": "\(serviceIDString)"])
                return try await handleA2A(
                    request: request,
                    runner: runner,
                    serviceID: serviceIDString,
                    mcpConfigPath: mcpConfigPath,
                    executionDirectory: executionDirectory,
                    skillOverlayPath: skillOverlayPath
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

    // MARK: - Chat

    private static func handleChat(
        request: LocalRequest,
        runner: ClaudeCodeAgentRunner,
        serviceID: String,
        mcpConfigPath: String?,
        executionDirectory: String?,
        skillOverlayPath: String?,
        logger: Logger
    ) async throws -> LocalResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let prompt = json["prompt"] as? String else {
            let errBody = try! JSONSerialization.data(withJSONObject: ["error": "prompt is required"])
            return LocalResponse(
                statusCode: 400,
                headers: [("Content-Type", "application/json")],
                body: errBody
            )
        }

        // Inject X-Context header into MCP config when context is provided
        let requestContext = json["context"] as? [String: Any]
        let effectiveMCPConfigPath: String?
        var tempMCPConfigURL: URL?
        if let requestContext, let basePath = mcpConfigPath {
            let (path, url) = try injectContextIntoMCPConfig(basePath: basePath, context: requestContext)
            effectiveMCPConfigPath = path
            tempMCPConfigURL = url
        } else {
            effectiveMCPConfigPath = mcpConfigPath
        }

        defer {
            if let url = tempMCPConfigURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        let context = AgentRunnerContext(
            serviceID: serviceID,
            mcpConfigPath: effectiveMCPConfigPath,
            executionDirectory: executionDirectory,
            skillOverlayPath: skillOverlayPath
        )

        // Collect SSE events
        var sseBody = Data()
        var eventID = 0

        func appendSSE(event: String, data: Data) {
            let dataStr = String(data: data, encoding: .utf8) ?? ""
            let line = "id: \(eventID)\nevent: \(event)\ndata: \(dataStr)\n\n"
            sseBody.append(Data(line.utf8))
            eventID += 1
        }

        for try await event in runner.send(message: prompt, context: context) {
            switch event {
            case .textDelta(let text):
                let payload = try JSONSerialization.data(withJSONObject: ["text": text])
                appendSSE(event: "text", data: payload)

            case .textComplete:
                break

            case .toolUse(let name):
                logger.info("[claude] tool_use: \(name)", metadata: ["service_id": "\(serviceID)"])
                let payload = try JSONSerialization.data(withJSONObject: ["name": name, "input": [:] as [String: Any]])
                appendSSE(event: "tool_use", data: payload)

            case .sessionID(let sid):
                logger.info("[claude] session: \(sid.prefix(8))", metadata: ["service_id": "\(serviceID)"])

            case .done(let result):
                let cost = result.totalCostUSD.map { String(format: "$%.4f", $0) } ?? "-"
                let turns = result.numTurns.map { "\($0)" } ?? "-"
                let duration = result.durationMS.map { "\($0)ms" } ?? "-"
                logger.info("[claude] done turns=\(turns) cost=\(cost) duration=\(duration)", metadata: ["service_id": "\(serviceID)"])
                let payload = try JSONSerialization.data(withJSONObject: [
                    "duration_ms": result.durationMS ?? 0,
                    "num_turns": result.numTurns ?? 0,
                    "cost": result.totalCostUSD ?? 0,
                    "is_error": false,
                ] as [String: Any])
                appendSSE(event: "result", data: payload)

            case .error(let message):
                logger.error("[claude] error: \(message)", metadata: ["service_id": "\(serviceID)"])
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

    // MARK: - A2A

    private static func handleA2A(
        request: LocalRequest,
        runner: ClaudeCodeAgentRunner,
        serviceID: String,
        mcpConfigPath: String?,
        executionDirectory: String?,
        skillOverlayPath: String?
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
            mcpConfigPath: mcpConfigPath,
            executionDirectory: executionDirectory,
            skillOverlayPath: skillOverlayPath
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

    // MARK: - Context Injection

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
                var headers = (server["headers"] as? [String: String]) ?? [:]
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
}
