import Foundation

public typealias ClaudeCodePluginTemplate = ClaudeCodePluginBundle.Template
public typealias ClaudeCodePluginBinding = ClaudeCodePluginBundle.Binding
public typealias ClaudeCodePluginRenderResult = ClaudeCodePluginBundle.RenderResult

/// Shared contract for generated Claude Code plugin bundles.
///
/// A bundle is generated per agent service and then rendered with environment-specific
/// MCP bindings for local runtime or remote deployment.
public enum ClaudeCodePluginBundle {
    public static let manifestDirectoryName = ".claude-plugin"
    public static let manifestFileName = "plugin.json"
    public static let manifestRelativePath = "\(manifestDirectoryName)/\(manifestFileName)"
    public static let templateFileName = "template.json"
    public static let bindingFileName = "binding.json"
    public static let mcpConfigFileName = ".mcp.json"
    public static let legacyClaudeConfigFileName = ".claude.json"
    public static let usageFileName = "USE_WITH_CLAUDE.md"

    public struct Template: Codable, Sendable, Equatable {
        public var serviceID: String
        public var servers: [TemplateServer]

        public init(serviceID: String, servers: [TemplateServer]) {
            self.serviceID = serviceID
            self.servers = servers
        }
    }

    public struct TemplateServer: Codable, Sendable, Equatable {
        public var name: String
        public var serviceRef: String?
        public var source: String

        public init(name: String, serviceRef: String?, source: String) {
            self.name = name
            self.serviceRef = serviceRef
            self.source = source
        }
    }

    public struct Binding: Codable, Sendable, Equatable {
        public var serviceID: String
        public var servers: [BindingServer]

        public init(serviceID: String, servers: [BindingServer]) {
            self.serviceID = serviceID
            self.servers = servers
        }
    }

    public struct BindingServer: Codable, Sendable, Equatable {
        public var name: String
        public var resolvedURL: String

        public init(name: String, resolvedURL: String) {
            self.name = name
            self.resolvedURL = resolvedURL
        }
    }

    public struct RenderResult: Sendable, Equatable {
        public var template: Template
        public var binding: Binding
        public var files: [File]

        public init(template: Template, binding: Binding, files: [File]) {
            self.template = template
            self.binding = binding
            self.files = files
        }
    }

    public struct File: Sendable, Equatable {
        public var relativePath: String
        public var content: Data

        public init(relativePath: String, content: Data) {
            self.relativePath = relativePath
            self.content = content
        }

        public init(relativePath: String, utf8 content: String) {
            self.relativePath = relativePath
            self.content = Data(content.utf8)
        }
    }

    public static func sanitizedServiceID(_ serviceID: String) -> String {
        serviceID.replacingOccurrences(of: "/", with: "__")
    }

    public static func pluginRootURL(baseURL: URL, serviceID: String) -> URL {
        baseURL
            .appendingPathComponent(sanitizedServiceID(serviceID), isDirectory: true)
            .standardizedFileURL
    }

    public static func mcpConfigPath(pluginRootPath: String) -> String {
        URL(fileURLWithPath: pluginRootPath)
            .appendingPathComponent(mcpConfigFileName)
            .standardizedFileURL
            .path
    }

    public static func manifestPath(pluginRootPath: String) -> String {
        URL(fileURLWithPath: pluginRootPath)
            .appendingPathComponent(manifestRelativePath)
            .standardizedFileURL
            .path
    }

    public static func pluginDirectoryArgument(pluginRootPath: String) -> String {
        "--plugin-dir \(shellQuoted(pluginRootPath))"
    }

    public static func manualLaunchCommand(pluginRootPath: String) -> String {
        "claude \(pluginDirectoryArgument(pluginRootPath: pluginRootPath))"
    }

    public static func usageDocument(pluginRootPath: String) -> String {
        """
        # Use With Claude Code

        Plugin root:
        `\(pluginRootPath)`

        Launch Claude Code with this plugin:
        ```bash
        \(manualLaunchCommand(pluginRootPath: pluginRootPath))
        ```
        """
    }

    public static func mcpServerName(serviceRef: String?, resolvedURL: String) -> String {
        if let serviceRef, !serviceRef.isEmpty {
            return serviceRef.replacingOccurrences(of: "/", with: "-")
        }
        guard let url = URL(string: resolvedURL) else {
            return "mcp-server"
        }
        let host = url.host ?? "unknown"
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        return path.isEmpty ? host : "\(host)-\(path)"
    }

    public static func render(template: Template, binding: Binding) throws -> RenderResult {
        let boundURLs = Dictionary(uniqueKeysWithValues: binding.servers.map { ($0.name, $0.resolvedURL) })

        let mcpServers = Dictionary(uniqueKeysWithValues: template.servers.map { server in
            let resolvedURL = boundURLs[server.name] ?? ""
            return (
                server.name,
                MCPServerConfig(type: "http", url: resolvedURL)
            )
        })

        let plugin = PluginManifest(
            name: manifestPluginName(serviceID: template.serviceID),
            version: "0.1.0",
            description: "AIB-generated Claude Code plugin for \(template.serviceID)"
        )
        let mcpConfig = MCPProjectConfig(mcpServers: mcpServers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let files = try [
            File(relativePath: manifestRelativePath, content: encoder.encode(plugin)),
            File(relativePath: templateFileName, content: encoder.encode(template)),
            File(relativePath: bindingFileName, content: encoder.encode(binding)),
            File(relativePath: mcpConfigFileName, content: encoder.encode(mcpConfig)),
            File(relativePath: legacyClaudeConfigFileName, content: encoder.encode(mcpConfig)),
        ]

        return RenderResult(template: template, binding: binding, files: files)
    }
}

private struct PluginManifest: Codable, Sendable, Equatable {
    var name: String
    var version: String
    var description: String?
}

private struct MCPProjectConfig: Codable, Sendable, Equatable {
    var mcpServers: [String: MCPServerConfig]
}

private struct MCPServerConfig: Codable, Sendable, Equatable {
    var type: String
    var url: String
}

private func manifestPluginName(serviceID: String) -> String {
    let raw = "aib-\(serviceID)"
        .lowercased()
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: "_", with: "-")
    let filteredScalars = raw.unicodeScalars.map { scalar -> Character in
        switch scalar {
        case "a"..."z", "0"..."9", "-":
            return Character(scalar)
        default:
            return "-"
        }
    }
    let collapsed = String(filteredScalars)
        .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return collapsed.isEmpty ? "aib-plugin" : collapsed
}

private func shellQuoted(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
