import AIBConfig
import AIBRuntimeCore
import Foundation

public struct SwiftRuntimeAdapter: RuntimeAdapter, Sendable {
    public var runtimeKind: RuntimeKind { .swift }

    public init() {}

    public func canHandle(repoURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("Package.swift").path)
    }

    public func detect(repoURL: URL) -> RuntimeDetectionResult {
        let content = readTextFileOrEmpty(path: repoURL.appendingPathComponent("Package.swift").path)
        let framework: FrameworkKind
        if content.localizedCaseInsensitiveContains("vapor") {
            framework = .vapor
        } else if content.localizedCaseInsensitiveContains("hummingbird") {
            framework = .hummingbird
        } else {
            framework = .plain
        }
        let executableNames = Self.parseExecutableTargetNames(from: content)
        let candidates = executableNames.map { name in
            CommandCandidate(argv: ["swift", "run", name], reason: "executableTarget \(name)")
        }
        let fallbackCandidates = candidates.isEmpty
            ? [CommandCandidate(argv: ["swift", "run"], reason: "SwiftPM repository")]
            : candidates

        // Infer service kind from MCP SDK dependency
        let serviceKind: ServiceKind = Self.hasMCPDependency(in: content) ? .mcp : .agent

        return RuntimeDetectionResult(
            runtime: .swift,
            framework: framework,
            packageManager: .swiftpm,
            confidence: .medium,
            candidates: fallbackCandidates,
            serviceNames: executableNames,
            suggestedServiceKind: serviceKind
        )
    }

    /// Check if Package.swift contains MCP-related dependencies.
    static func hasMCPDependency(in content: String) -> Bool {
        let mcpIndicators = [
            "swift-mcp", "SwiftMCP",
            "mcp-swift", "MCPServer",
            "model-context-protocol", "ModelContextProtocol",
        ]
        return mcpIndicators.contains { content.contains($0) }
    }

    /// Extract `.executableTarget(name: "...")` names from Package.swift content.
    static func parseExecutableTargetNames(from content: String) -> [String] {
        // Match .executableTarget(name: "xxx") or .executableTarget(name:"xxx")
        let pattern = #"\.executableTarget\s*\(\s*name\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[nameRange])
        }
    }

    public func defaults(packageManager: PackageManagerKind) -> RuntimeDefaults {
        RuntimeDefaults(
            watchMode: .external,
            buildCommand: ["swift", "build"],
            installCommand: nil,
            watchPaths: ["Sources/**", "Package.swift", "Package.resolved"],
            serviceKind: .agent
        )
    }
}
