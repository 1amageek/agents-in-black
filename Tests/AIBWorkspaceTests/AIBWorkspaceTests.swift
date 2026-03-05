import AIBConfig
import Foundation
import Testing
@testable import AIBWorkspace

@Test(.timeLimit(.minutes(1)))
func workspaceInitDiscoversRepos() throws {
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

    let agentA = result.workspaceConfig.repos.first(where: { $0.name == "agent-a" })
    #expect(agentA?.status == .discoverable)
    #expect(agentA?.runtime == .swift)

    let discoverable = result.workspaceConfig.repos.first(where: { $0.name == "mcp-web" })
    #expect(discoverable?.status == .discoverable)
    #expect(discoverable?.selectedCommand == ["npm", "run", "dev"])
}

@Test(.timeLimit(.minutes(1)))
func resolveConfigFlattensWorkspaceServices() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-resolve-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let agentRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: agentRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: agentRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let mcpRepo = root.appendingPathComponent("mcp-web", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"mcp-web","scripts":{"dev":"node server.js"}}
    """.write(to: mcpRepo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "agent-a",
                path: "agent-a",
                runtime: .swift,
                framework: .unknown,
                packageManager: .swiftpm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "app",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["swift", "run"],
                        watchMode: "external",
                        connections: WorkspaceRepoConnectionsConfig(
                            mcpServers: [WorkspaceRepoConnectionTarget(serviceRef: "mcp-web/web")]
                        )
                    ),
                ]
            ),
            WorkspaceRepo(
                name: "mcp-web",
                path: "mcp-web",
                runtime: .node,
                framework: .unknown,
                packageManager: .npm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "web",
                        kind: "mcp",
                        mountPath: "/mcp/web",
                        run: ["node", "server.js"],
                        watchMode: "internal",
                        mcp: WorkspaceRepoMCPConfig(transport: "streamable_http", path: "/mcp")
                    ),
                ]
            ),
        ]
    )

    let resolved = try WorkspaceSyncer.resolveConfig(workspaceRoot: root.path, workspace: workspace)
    #expect(resolved.config.services.count == 2)
    let agentService = resolved.config.services.first(where: { $0.id.rawValue == "agent-a/app" })
    #expect(agentService != nil)
    #expect(agentService?.kind == .agent)
    #expect(agentService?.connections.mcpServers.first?.serviceRef == "mcp-web/web")

    let mcpService = resolved.config.services.first(where: { $0.id.rawValue == "mcp-web/web" })
    #expect(mcpService != nil)
    #expect(mcpService?.kind == .mcp)
    #expect(mcpService?.mcp?.transport == .streamableHTTP)
}

@Test(.timeLimit(.minutes(1)))
func workspaceSyncWritesRuntimeConnectionArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-workspace-connections-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let agentRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: agentRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: agentRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let mcpRepo = root.appendingPathComponent("mcp-web", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"mcp-web","scripts":{"dev":"node server.js"}}
    """.write(to: mcpRepo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    // Init to discover repos
    let initResult = try AIBWorkspaceManager.initWorkspace(
        options: .init(workspaceRoot: root.path, scanPath: root.path, force: false, scanEnabled: true)
    )

    // Update workspace.yaml to add inline services with connections
    var workspace = initResult.workspaceConfig
    for index in workspace.repos.indices {
        if workspace.repos[index].name == "agent-a" {
            workspace.repos[index].services = [
                WorkspaceRepoServiceConfig(
                    id: "app",
                    kind: "agent",
                    mountPath: "/agents/a",
                    run: ["swift", "run"],
                    watchMode: "external",
                    connections: WorkspaceRepoConnectionsConfig(
                        mcpServers: [WorkspaceRepoConnectionTarget(serviceRef: "mcp-web/web")],
                        a2aAgents: [WorkspaceRepoConnectionTarget(serviceRef: "helper")]
                    )
                ),
                WorkspaceRepoServiceConfig(
                    id: "helper",
                    kind: "agent",
                    mountPath: "/agents/helper",
                    run: ["swift", "run"],
                    watchMode: "external"
                ),
            ]
        }
        if workspace.repos[index].name == "mcp-web" {
            workspace.repos[index].services = [
                WorkspaceRepoServiceConfig(
                    id: "web",
                    kind: "mcp",
                    mountPath: "/mcp/web",
                    run: ["node", "server.js"],
                    watchMode: "internal",
                    mcp: WorkspaceRepoMCPConfig(transport: "streamable_http", path: "/mcp")
                ),
            ]
        }
    }

    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)
    _ = try WorkspaceSyncer.sync(workspaceRoot: root.path, workspace: workspace)

    let runtimeConnections = root
        .appendingPathComponent(".aib/generated/runtime/connections")
        .appendingPathComponent("agent-a__app.json")
    let runtimeData = try Data(contentsOf: runtimeConnections)
    let decoded = try JSONSerialization.jsonObject(with: runtimeData) as? [String: Any]
    let mcpServers = decoded?["mcp_servers"] as? [[String: Any]] ?? []
    let a2aAgents = decoded?["a2a_agents"] as? [[String: Any]] ?? []
    #expect(mcpServers.contains(where: { $0["service_ref"] as? String == "mcp-web/web" }))
    #expect(a2aAgents.contains(where: { $0["service_ref"] as? String == "agent-a/helper" }))

    let mcpProjectConfig = root
        .appendingPathComponent(".aib/generated/runtime/mcp")
        .appendingPathComponent("agent-a__app/.mcp.json")
    let mcpProjectData = try Data(contentsOf: mcpProjectConfig)
    let mcpProjectDecoded = try JSONSerialization.jsonObject(with: mcpProjectData) as? [String: Any]
    let mcpProjectServers = mcpProjectDecoded?["mcpServers"] as? [String: Any]
    #expect(mcpProjectServers?["mcp-web-web"] != nil)

    let claudeConfig = root
        .appendingPathComponent(".aib/generated/runtime/mcp")
        .appendingPathComponent("agent-a__app/.claude.json")
    let claudeConfigData = try Data(contentsOf: claudeConfig)
    let claudeConfigDecoded = try JSONSerialization.jsonObject(with: claudeConfigData) as? [String: Any]
    let claudeServers = claudeConfigDecoded?["mcpServers"] as? [String: Any]
    #expect(claudeServers?["mcp-web-web"] != nil)
}

@Test(.timeLimit(.minutes(1)))
func runtimeAdapterRegistryDetectsSwift() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-adapter-test-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"test\", dependencies: [.package(url: \"https://github.com/vapor/vapor.git\", from: \"4.0.0\")])\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let result = RuntimeAdapterRegistry.detect(repoURL: root)
        #expect(result.runtime == .swift)
        #expect(result.framework == .vapor)
        #expect(result.packageManager == .swiftpm)
        #expect(!result.candidates.isEmpty)
    } catch {
        Issue.record("Adapter test setup failed: \(error)")
    }
    try? FileManager.default.removeItem(at: root)
}

@Test(.timeLimit(.minutes(1)))
func runtimeAdapterRegistryDetectsNode() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-adapter-node-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {"name":"test","scripts":{"dev":"node index.js","start":"node index.js"},"dependencies":{"express":"^4.0.0"}}
        """.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let result = RuntimeAdapterRegistry.detect(repoURL: root)
        #expect(result.runtime == .node)
        #expect(result.framework == .express)
        #expect(result.packageManager == .npm)
        #expect(result.candidates.count >= 1)
        #expect(result.candidates.first?.argv == ["npm", "run", "dev"])
    } catch {
        Issue.record("Adapter test setup failed: \(error)")
    }
    try? FileManager.default.removeItem(at: root)
}
