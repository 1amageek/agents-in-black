import AIBConfig
import AIBRuntimeCore
import Foundation

public struct DenoRuntimeAdapter: RuntimeAdapter, Sendable {
    public var runtimeKind: RuntimeKind { .deno }

    public init() {}

    public func canHandle(repoURL: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoURL.appendingPathComponent("deno.json").path)
            || fm.fileExists(atPath: repoURL.appendingPathComponent("deno.jsonc").path)
    }

    public func detect(repoURL: URL) -> RuntimeDetectionResult {
        let denoJSONURL = FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("deno.json").path)
            ? repoURL.appendingPathComponent("deno.json")
            : repoURL.appendingPathComponent("deno.jsonc")
        let text = readTextFileOrEmpty(url: denoJSONURL)

        let framework: FrameworkKind
        if text.localizedCaseInsensitiveContains("fresh") {
            framework = .fresh
        } else if text.localizedCaseInsensitiveContains("hono") {
            framework = .hono
        } else if text.localizedCaseInsensitiveContains("oak") {
            framework = .oak
        } else {
            framework = .plain
        }

        var candidates: [CommandCandidate] = []
        if text.contains("\"dev\"") || text.contains("dev:") {
            candidates.append(.init(argv: ["deno", "task", "dev"], reason: "deno task dev"))
        }

        return RuntimeDetectionResult(
            runtime: .deno,
            framework: framework,
            packageManager: .deno,
            confidence: candidates.isEmpty ? .low : .medium,
            candidates: candidates
        )
    }

    public func defaults(packageManager: PackageManagerKind) -> RuntimeDefaults {
        RuntimeDefaults(
            watchMode: .internal,
            buildCommand: nil,
            installCommand: nil,
            watchPaths: ["deno.json", "deno.jsonc", "deno.lock"],
            serviceKind: .agent
        )
    }
}
