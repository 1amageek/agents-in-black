import AIBConfig
import AIBRuntimeCore
import Foundation

public struct NodeRuntimeAdapter: RuntimeAdapter, Sendable {
    public var runtimeKind: RuntimeKind { .node }

    public init() {}

    public func canHandle(repoURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("package.json").path)
    }

    public func detect(repoURL: URL) -> RuntimeDetectionResult {
        let packagePath = repoURL.appendingPathComponent("package.json")
        var scripts: [String: String] = [:]
        var deps = Set<String>()
        var packageName: String?
        do {
            let data = try Data(contentsOf: packagePath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                packageName = json["name"] as? String
                if let scriptsJSON = json["scripts"] as? [String: String] {
                    scripts = scriptsJSON
                }
                if let dependencies = json["dependencies"] as? [String: Any] {
                    deps.formUnion(dependencies.keys)
                }
                if let devDependencies = json["devDependencies"] as? [String: Any] {
                    deps.formUnion(devDependencies.keys)
                }
            }
        } catch {
            // Best-effort detection only.
        }

        let framework: FrameworkKind
        if deps.contains("express") {
            framework = .express
        } else if deps.contains("fastify") {
            framework = .fastify
        } else if deps.contains("@nestjs/core") {
            framework = .nestjs
        } else if deps.contains("next") {
            framework = .nextjs
        } else if deps.contains("hono") {
            framework = .hono
        } else {
            framework = .plain
        }

        let packageManager = detectPackageManager(repoURL: repoURL)
        let candidates = nodeCandidates(packageManager: packageManager, scripts: scripts)
        let confidence: DetectionConfidence = candidates.isEmpty ? .low : .medium
        let serviceNames = packageName.map { [$0] } ?? []

        // Infer service kind from MCP SDK dependency
        let mcpPackages: Set<String> = ["@modelcontextprotocol/sdk", "mcp-framework"]
        let serviceKind: ServiceKind = deps.contains(where: { mcpPackages.contains($0) }) ? .mcp : .agent

        return RuntimeDetectionResult(
            runtime: .node,
            framework: framework,
            packageManager: packageManager,
            confidence: confidence,
            candidates: candidates,
            serviceNames: serviceNames,
            suggestedServiceKind: serviceKind
        )
    }

    public func defaults(packageManager: PackageManagerKind) -> RuntimeDefaults {
        let installCommand: [String]?
        switch packageManager {
        case .npm: installCommand = ["npm", "install"]
        case .pnpm: installCommand = ["pnpm", "install"]
        case .yarn: installCommand = ["yarn", "install"]
        default: installCommand = ["npm", "install"]
        }
        return RuntimeDefaults(
            watchMode: .internal,
            buildCommand: nil,
            installCommand: installCommand,
            watchPaths: ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"],
            serviceKind: .agent
        )
    }

    private func detectPackageManager(repoURL: URL) -> PackageManagerKind {
        let fm = FileManager.default
        if fm.fileExists(atPath: repoURL.appendingPathComponent("pnpm-lock.yaml").path) { return .pnpm }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("yarn.lock").path) { return .yarn }
        if fm.fileExists(atPath: repoURL.appendingPathComponent("package-lock.json").path) { return .npm }
        // Default to pnpm: node:22-slim ships npm v11 which has a known lockfile
        // compatibility bug ("Cannot read properties of undefined (reading 'extraneous')").
        // pnpm is pre-installed via corepack and avoids this issue.
        return .pnpm
    }

    private func nodeCandidates(packageManager: PackageManagerKind, scripts: [String: String]) -> [CommandCandidate] {
        var result: [CommandCandidate] = []
        let preferred = ["dev", "start"]
        for script in preferred where scripts[script] != nil {
            result.append(runScriptCandidate(packageManager: packageManager, script: script, reason: "package.json scripts.\(script)"))
        }
        if result.isEmpty, !scripts.isEmpty {
            if let first = scripts.keys.sorted().first {
                result.append(runScriptCandidate(packageManager: packageManager, script: first, reason: "package.json first script"))
            }
        }
        return result
    }

    private func runScriptCandidate(packageManager: PackageManagerKind, script: String, reason: String) -> CommandCandidate {
        switch packageManager {
        case .yarn:
            return .init(argv: ["yarn", script], reason: reason)
        case .pnpm:
            return .init(argv: ["pnpm", script], reason: reason)
        default:
            return .init(argv: ["npm", "run", script], reason: reason)
        }
    }
}
