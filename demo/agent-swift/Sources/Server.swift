import Foundation
import FoundationModels
import Hummingbird
import NIOCore
import SwiftAgent

// MARK: - MCP Tool Client

struct MCPToolClient: Sendable {
    let baseURL: String

    func callTool(name: String, params: [String: String]) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw MCPClientError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["tool": name, "params": params]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MCPClientError.requestFailed
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return str
    }

    func listTools() async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw MCPClientError.invalidURL(baseURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return str
    }
}

enum MCPClientError: LocalizedError {
    case invalidURL(String)
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): "Invalid MCP URL: \(url)"
        case .requestFailed: "MCP request failed"
        case .invalidResponse: "Invalid MCP response"
        }
    }
}

// MARK: - Tools backed by MCP server

@Generable
struct CalculateArguments: Sendable {
    @Guide(description: "The arithmetic expression to evaluate, e.g. '2+3*4'")
    var expression: String
}

struct CalculateTool: Tool {
    static let name = "calculate"
    var name: String { Self.name }

    static let description = "Evaluate a simple arithmetic expression (+, -, *, /, parentheses)"
    var description: String { Self.description }

    var parameters: GenerationSchema { CalculateArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: CalculateArguments) async throws -> String {
        try await client.callTool(name: "calculate", params: ["expression": arguments.expression])
    }
}

@Generable
struct CurrentTimeArguments: Sendable {
    @Guide(description: "Output format: iso, unix, or readable")
    var format: String
}

struct CurrentTimeTool: Tool {
    static let name = "current_time"
    var name: String { Self.name }

    static let description = "Return the current date and time in the requested format"
    var description: String { Self.description }

    var parameters: GenerationSchema { CurrentTimeArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: CurrentTimeArguments) async throws -> String {
        try await client.callTool(name: "current_time", params: ["format": arguments.format])
    }
}

@Generable
struct TransformTextArguments: Sendable {
    @Guide(description: "The text to transform")
    var text: String
    @Guide(description: "Operation: uppercase, lowercase, reverse, or word_count")
    var operation: String
}

struct TransformTextTool: Tool {
    static let name = "transform_text"
    var name: String { Self.name }

    static let description = "Transform text: uppercase, lowercase, reverse, or word_count"
    var description: String { Self.description }

    var parameters: GenerationSchema { TransformTextArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: TransformTextArguments) async throws -> String {
        try await client.callTool(
            name: "transform_text",
            params: ["text": arguments.text, "operation": arguments.operation]
        )
    }
}

// MARK: - Web tools backed by mcp-web

@Generable
struct FetchURLArguments: Sendable {
    @Guide(description: "The URL to fetch")
    var url: String
    @Guide(description: "Max characters to return (default 5000)")
    var maxLength: String
}

struct FetchURLTool: Tool {
    static let name = "fetch_url"
    var name: String { Self.name }

    static let description = "Fetch a URL and return its text content (HTML tags stripped)"
    var description: String { Self.description }

    var parameters: GenerationSchema { FetchURLArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: FetchURLArguments) async throws -> String {
        try await client.callTool(
            name: "fetch_url",
            params: ["url": arguments.url, "max_length": arguments.maxLength]
        )
    }
}

@Generable
struct ExtractLinksArguments: Sendable {
    @Guide(description: "The URL to extract links from")
    var url: String
}

struct ExtractLinksTool: Tool {
    static let name = "extract_links"
    var name: String { Self.name }

    static let description = "Fetch a URL and extract all hyperlinks from the page"
    var description: String { Self.description }

    var parameters: GenerationSchema { ExtractLinksArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: ExtractLinksArguments) async throws -> String {
        try await client.callTool(name: "extract_links", params: ["url": arguments.url])
    }
}

@Generable
struct SearchPageArguments: Sendable {
    @Guide(description: "The URL to search within")
    var url: String
    @Guide(description: "The keyword or phrase to search for")
    var query: String
}

struct SearchPageTool: Tool {
    static let name = "search_page"
    var name: String { Self.name }

    static let description = "Fetch a URL and search for a keyword, returning matching lines"
    var description: String { Self.description }

    var parameters: GenerationSchema { SearchPageArguments.generationSchema }

    let client: MCPToolClient

    func call(arguments: SearchPageArguments) async throws -> String {
        try await client.callTool(
            name: "search_page",
            params: ["url": arguments.url, "query": arguments.query]
        )
    }
}

// MARK: - HTTP Server

@main
struct AgentSwiftServer {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "9003") ?? 9003
        let serviceID = ProcessInfo.processInfo.environment["AIB_SERVICE_ID"] ?? "agent-swift"

        let mcpClients = loadMCPClients()

        var tools: [any Tool] = []
        for (ref, client) in mcpClients {
            if ref.contains("mcp-node") {
                tools.append(contentsOf: [
                    CalculateTool(client: client),
                    CurrentTimeTool(client: client),
                    TransformTextTool(client: client),
                ] as [any Tool])
            } else if ref.contains("mcp-web") {
                tools.append(contentsOf: [
                    FetchURLTool(client: client),
                    ExtractLinksTool(client: client),
                    SearchPageTool(client: client),
                ] as [any Tool])
            }
        }

        let router = Router()

        router.get("/health/live") { _, _ in
            return try encodedResponse(HealthResponse(ok: true, service: serviceID))
        }

        router.get("/health/ready") { _, _ in
            return try encodedResponse(HealthResponse(ok: true, service: serviceID))
        }

        let capturedClients = mcpClients
        router.get("/tools") { _, _ in
            guard !capturedClients.isEmpty else {
                struct NoToolsResponse: Encodable { let tools: [String]; let error: String }
                return try encodedResponse(NoToolsResponse(tools: [], error: "No MCP servers configured"))
            }
            var allTools: [[String: Any]] = []
            for (ref, client) in capturedClients {
                do {
                    let raw = try await client.listTools()
                    if let data = raw.data(using: .utf8),
                       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tools = json["tools"] as? [[String: Any]]
                    {
                        for var t in tools {
                            t["mcp_server"] = ref
                            allTools.append(t)
                        }
                    }
                } catch {
                    allTools.append(["error": error.localizedDescription, "mcp_server": ref])
                }
            }
            let responseData = try JSONSerialization.data(
                withJSONObject: ["tools": allTools, "server_count": capturedClients.count]
            )
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: responseData))
            )
        }

        let capturedTools = tools
        router.post("/") { request, context in
            let chatReq: ChatRequest = try await request.decode(
                as: ChatRequest.self,
                context: context
            )

            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: capturedTools
            ) {
                Instructions(
                    "You are a helpful assistant. Use the available tools to help users with calculations, time queries, text transformations, and web page fetching. Always respond concisely."
                )
            }

            let response = try await session.respond(to: chatReq.message)
            return try encodedResponse(
                ChatResponse(body: response.content, service: serviceID)
            )
        }

        print("\(serviceID) listening on \(port) (mcp_servers=\(mcpClients.count))")

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
        try await app.run()
    }

    // MARK: - Connections file loader

    static func loadMCPClients() -> [(String, MCPToolClient)] {
        guard let path = ProcessInfo.processInfo.environment["AIB_CONNECTIONS_FILE"] else {
            return []
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let servers = json["mcp_servers"] as? [[String: Any]]
            else { return [] }
            return servers.compactMap { entry in
                guard let url = entry["resolved_url"] as? String,
                      let ref = entry["service_ref"] as? String
                else { return nil }
                return (ref, MCPToolClient(baseURL: url))
            }
        } catch {
            print("Failed to load connections file: \(error)")
            return []
        }
    }

    // MARK: - Response helpers

    static func encodedResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}

// MARK: - Request / Response models

struct ChatRequest: Decodable, Sendable {
    let message: String
}

struct ChatResponse: Encodable, Sendable {
    let body: String
    let service: String
}

struct HealthResponse: Encodable, Sendable {
    let ok: Bool
    let service: String
}
