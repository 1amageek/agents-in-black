import Foundation

/// Parses newline-delimited JSON from Claude Code's stream-json output.
struct StreamEventParser {

    func parse(_ line: String) throws -> StreamEvent {
        guard let data = line.data(using: .utf8) else {
            throw ParserError.invalidUTF8
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let type = json["type"] as? String else {
            throw ParserError.missingType
        }

        switch type {
        case "system":
            return .system(parseSystem(json))
        case "stream_event":
            return try .streamEvent(parseStreamDelta(json))
        case "assistant":
            return .assistant(parseAssistant(json))
        case "result":
            return .result(parseResult(json))
        case "user":
            return .user(parseUser(json))
        case "rate_limit_event":
            throw ParserError.ignoredType(type)
        default:
            throw ParserError.unknownType(type)
        }
    }

    // MARK: - System

    private func parseSystem(_ json: [String: Any]) -> SystemEvent {
        let servers = (json["mcp_servers"] as? [[String: Any]] ?? []).map { server in
            MCPServerStatus(
                name: server["name"] as? String ?? "",
                status: server["status"] as? String ?? ""
            )
        }
        return SystemEvent(
            sessionID: json["session_id"] as? String ?? "",
            cwd: json["cwd"] as? String ?? "",
            model: json["model"] as? String ?? "",
            tools: json["tools"] as? [String] ?? [],
            mcpServers: servers,
            permissionMode: json["permissionMode"] as? String ?? ""
        )
    }

    // MARK: - Stream Delta

    private func parseStreamDelta(_ json: [String: Any]) throws -> StreamDelta {
        guard let event = json["event"] as? [String: Any],
              let eventType = event["type"] as? String else {
            throw ParserError.malformedEvent
        }

        let deltaEvent: DeltaEvent = switch eventType {
        case "message_start":
            .messageStart
        case "content_block_start":
            if let contentBlock = event["content_block"] as? [String: Any],
               contentBlock["type"] as? String == "tool_use" {
                .toolUseStart(
                    index: event["index"] as? Int ?? 0,
                    toolID: contentBlock["id"] as? String ?? "",
                    toolName: contentBlock["name"] as? String ?? ""
                )
            } else {
                .contentBlockStart(index: event["index"] as? Int ?? 0)
            }
        case "content_block_delta":
            parseTextDelta(event)
        case "content_block_stop":
            .contentBlockStop(index: event["index"] as? Int ?? 0)
        case "message_delta":
            .messageDelta(
                stopReason: (event["delta"] as? [String: Any])?["stop_reason"] as? String
            )
        case "message_stop":
            .messageStop
        default:
            throw ParserError.unknownType(eventType)
        }

        return StreamDelta(
            sessionID: json["session_id"] as? String ?? "",
            parentToolUseID: json["parent_tool_use_id"] as? String,
            event: deltaEvent
        )
    }

    private func parseTextDelta(_ event: [String: Any]) -> DeltaEvent {
        let index = event["index"] as? Int ?? 0
        let delta = event["delta"] as? [String: Any] ?? [:]
        let text = delta["text"] as? String ?? ""
        return .textDelta(index: index, text: text)
    }

    // MARK: - Assistant

    private func parseAssistant(_ json: [String: Any]) -> AssistantMessage {
        let message = json["message"] as? [String: Any] ?? [:]
        let rawContent = message["content"] as? [[String: Any]] ?? []

        let content: [ContentBlock] = rawContent.compactMap { block in
            switch block["type"] as? String {
            case "text":
                .text(block["text"] as? String ?? "")
            case "tool_use":
                .toolUse(
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "",
                    input: {
                        guard let input = block["input"],
                              let data = try? JSONSerialization.data(withJSONObject: input),
                              let str = String(data: data, encoding: .utf8) else { return "{}" }
                        return str
                    }()
                )
            default:
                nil
            }
        }

        return AssistantMessage(
            sessionID: json["session_id"] as? String ?? "",
            messageID: message["id"] as? String ?? "",
            model: message["model"] as? String ?? "",
            content: content,
            parentToolUseID: json["parent_tool_use_id"] as? String
        )
    }

    // MARK: - User (Tool Results)

    private func parseUser(_ json: [String: Any]) -> UserMessage {
        let message = json["message"] as? [String: Any] ?? [:]
        let rawContent = message["content"] as? [[String: Any]] ?? []

        let toolResults: [ToolResult] = rawContent.compactMap { block in
            guard block["type"] as? String == "tool_result" else { return nil }
            let toolUseID = block["tool_use_id"] as? String ?? ""
            let content: String
            if let text = block["content"] as? String {
                content = text
            } else if let parts = block["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined()
            } else {
                content = ""
            }
            return ToolResult(toolUseID: toolUseID, content: content)
        }

        return UserMessage(
            sessionID: json["session_id"] as? String ?? "",
            toolResults: toolResults
        )
    }

    // MARK: - Result

    private func parseResult(_ json: [String: Any]) -> ResultEvent {
        ResultEvent(
            sessionID: json["session_id"] as? String ?? "",
            result: json["result"] as? String ?? "",
            isError: json["is_error"] as? Bool ?? false,
            stopReason: json["stop_reason"] as? String ?? "",
            totalCostUSD: json["total_cost_usd"] as? Double ?? 0,
            durationMS: json["duration_ms"] as? Int ?? 0,
            numTurns: json["num_turns"] as? Int ?? 0
        )
    }

    // MARK: - Errors

    enum ParserError: Error {
        case invalidUTF8
        case missingType
        case malformedEvent
        case unknownType(String)
        case ignoredType(String)
    }
}
