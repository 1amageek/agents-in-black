import Foundation
import Testing
@testable import AIBWorkspace

@Test(.timeLimit(.minutes(1)))
func workspaceInitDiscoversReposAndGeneratesServices() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-workspace-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let swiftRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: swiftRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: swiftRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: swiftRepo.appendingPathComponent(".aib"), withIntermediateDirectories: true)
    try """
    version: 1
    services:
      - id: app
        mount_path: /agents/a
        port: 0
        run: [swift, run]
        watch_mode: external
        health:
          readiness_path: /health/ready
    """.write(to: swiftRepo.appendingPathComponent(".aib/services.yaml"), atomically: true, encoding: .utf8)

    let nodeRepo = root.appendingPathComponent("mcp-web", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"mcp-web","scripts":{"dev":"node server.js"},"dependencies":{"fastify":"^5.0.0"}}
    """.write(to: nodeRepo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let result = try AIBWorkspaceManager.initWorkspace(
        options: .init(workspaceRoot: root.path, scanPath: root.path, force: false, scanEnabled: true)
    )

    #expect(result.workspaceConfig.repos.count == 2)
    let names = Set(result.workspaceConfig.repos.map(\.name))
    #expect(names.contains("agent-a"))
    #expect(names.contains("mcp-web"))

    let managed = result.workspaceConfig.repos.first(where: { $0.name == "agent-a" })
    #expect(managed?.status == .managed)

    let discoverable = result.workspaceConfig.repos.first(where: { $0.name == "mcp-web" })
    #expect(discoverable?.status == .discoverable)
    #expect(discoverable?.selectedCommand == ["npm", "run", "dev"])

    let generated = root.appendingPathComponent(".aib/services.yaml")
    let generatedText = try String(contentsOf: generated, encoding: .utf8)
    #expect(generatedText.contains("agent-a/app"))
    #expect(generatedText.contains("mcp-web/main"))
}
