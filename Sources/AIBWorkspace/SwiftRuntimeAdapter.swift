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
        let candidates = [CommandCandidate(argv: ["swift", "run"], reason: "SwiftPM repository")]
        return RuntimeDetectionResult(
            runtime: .swift,
            framework: framework,
            packageManager: .swiftpm,
            confidence: .medium,
            candidates: candidates
        )
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
