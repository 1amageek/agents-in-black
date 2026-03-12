import AIBConfig
import AIBCore
import AIBRuntimeCore
import Foundation
import Testing
@testable import AIBWorkspace

private struct MockDeploymentProvider: DeploymentProvider {
    let providerID: String = "mock"
    let displayName: String = "Mock"

    func preflightCheckers() -> [any PreflightChecker] { [] }
    func preflightDependencies() -> [PreflightCheckID: [PreflightCheckID]] { [:] }
    func extractDetectedConfig(from report: PreflightReport) -> [String: String] { [:] }
    func validateTargetConfig(_ config: AIBDeployTargetConfig) throws {}
    func deployedServiceName(from namespacedID: String) -> String {
        "mock-\(namespacedID.replacingOccurrences(of: "/", with: "-"))"
    }
    func resolveURL(
        serviceRef: String,
        region: String,
        path: String?,
        serviceNameMap: [String: String],
        existingServiceURLs: [String: String]
    ) -> String {
        "https://example.invalid\(path ?? "")"
    }
    func generateDeployConfig(service: AIBDeployServicePlan) -> String {
        "service: \(service.deployedServiceName)\n"
    }
    func registryImageTag(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> String {
        "mock/\(service.deployedServiceName):latest"
    }
    func registryAuthCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }
    func buildBackendPreparationCommands(targetConfig: AIBDeployTargetConfig) -> [DeployCommand] { [] }
    func ensureRegistryRepoCommands(
        service: AIBDeployServicePlan,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand] { [] }
    func buildAndPushCommands(
        imageTag: String,
        dockerfilePath: String,
        buildContext: String,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand] { [] }
    func deployCommands(
        service: AIBDeployServicePlan,
        imageTag: String,
        targetConfig: AIBDeployTargetConfig,
        secrets: [String: String]
    ) -> [DeployCommand] { [] }
    func authBindingCommands(
        binding: AIBDeployAuthBinding,
        targetConfig: AIBDeployTargetConfig
    ) -> [DeployCommand] { [] }
    func existingServiceURL(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> String? { nil }
    func existingEnvVarNames(
        serviceName: String,
        targetConfig: AIBDeployTargetConfig
    ) async -> Set<String> { [] }
    func parseDeployedURL(from output: String) -> String? { nil }
    func authBindingMember(
        sourceServiceName: String,
        targetConfig: AIBDeployTargetConfig
    ) -> String {
        "serviceAccount:\(sourceServiceName)"
    }
}

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
func workspaceSyncWritesRuntimeSkillArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-workspace-runtime-skills-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let repo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"agent-a","scripts":{"dev":"node server.js"}}
    """.write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".claude/skills/manual"),
        withIntermediateDirectories: true
    )
    try "{\"approval\":\"never\"}".write(
        to: repo.appendingPathComponent(".claude/settings.local.json"),
        atomically: true,
        encoding: .utf8
    )
    try "manual skill\n".write(
        to: repo.appendingPathComponent(".claude/skills/manual/SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "agent-a",
                path: "agent-a",
                runtime: .node,
                framework: .unknown,
                packageManager: .npm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "app",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["node", "server.js"],
                        watchMode: "internal",
                        skills: ["deploy"]
                    ),
                ]
            ),
        ],
        skills: [
            WorkspaceSkillConfig(
                id: "deploy",
                name: "Deploy",
                description: "Deploy the application",
                instructions: "Use scripts/deploy.sh."
            ),
        ]
    )

    let workspaceSkillsRoot = SkillBundleLoader.workspaceSkillsRootURL(workspaceRoot: root.path)
    let skillDir = SkillBundleLoader.skillURL(id: "deploy", rootURL: workspaceSkillsRoot)
    try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("agents"), withIntermediateDirectories: true)
    try """
    ---
    name: deploy
    description: Deploy the application
    ---

    Use scripts/deploy.sh.
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho deploy\n".write(
        to: skillDir.appendingPathComponent("scripts/deploy.sh"),
        atomically: true,
        encoding: .utf8
    )
    try "{\"interface\":{\"display_name\":\"Deploy\"}}".write(
        to: skillDir.appendingPathComponent("agents/openai.yaml"),
        atomically: true,
        encoding: .utf8
    )

    let syncResult = try WorkspaceSyncer.sync(workspaceRoot: root.path, workspace: workspace)
    #expect(syncResult.serviceCount == 1)

    let stagedRoot = root
        .appendingPathComponent(".aib/generated/runtime/skills/agent-a__app")
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(".claude/settings.local.json").path))
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(".claude/skills/manual/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(".claude/skills/deploy/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(".claude/skills/deploy/scripts/deploy.sh").path))
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(".agents/skills/deploy/agents/openai.yaml").path))
    #expect(FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent("skills/deploy/SKILL.md").path))
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func workspaceDiscoveryIncludesExecutionDirectorySkills() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-discovery-native-skills-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let repo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"agent-a","scripts":{"dev":"node server.js"}}
    """.write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".claude/skills/manual"),
        withIntermediateDirectories: true
    )
    try """
    ---
    name: manual
    description: Local manual skill
    ---

    Use the manual workflow.
    """.write(
        to: repo.appendingPathComponent(".claude/skills/manual/SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "agent-a",
                path: "agent-a",
                runtime: .node,
                framework: .unknown,
                packageManager: .npm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "app",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["node", "server.js"],
                        watchMode: "internal"
                    ),
                ]
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    let snapshot = try WorkspaceDiscoveryService().loadWorkspace(at: root)
    let service = try #require(snapshot.services.first)
    let manualSkill = try #require(snapshot.skills.first(where: { $0.id == "manual" }))

    #expect(service.nativeSkillIDs.contains("manual"))
    #expect(!service.assignedSkillIDs.contains("manual"))
    #expect(manualSkill.source == .executionDirectory)
    #expect(!manualSkill.isWorkspaceManaged)
    #expect(manualSkill.discoveredInServices.contains(service.namespacedID))
}

@Test(.timeLimit(.minutes(1)))
func assignSkillImportsDiscoveredExecutionSkill() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-assign-discovered-skill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let repo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {"name":"agent-a","scripts":{"dev":"node server.js"}}
    """.write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".claude/skills/manual"),
        withIntermediateDirectories: true
    )
    try """
    ---
    name: manual
    description: Local manual skill
    ---

    Use the manual workflow.
    """.write(
        to: repo.appendingPathComponent(".claude/skills/manual/SKILL.md"),
        atomically: true,
        encoding: .utf8
    )

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "agent-a",
                path: "agent-a",
                runtime: .node,
                framework: .unknown,
                packageManager: .npm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "app",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["node", "server.js"],
                        watchMode: "internal"
                    ),
                ]
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    try AIBWorkspaceManager.assignSkill(
        workspaceRoot: root.path,
        skillID: "manual",
        namespacedServiceID: "agent-a/app"
    )

    let saved = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: root.path)
    #expect(saved.skills?.contains(where: { $0.id == "manual" }) == true)
    #expect(saved.repos.first?.services?.first?.skills?.contains("manual") == true)
    #expect(
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".aib/skills/manual/SKILL.md").path
        )
    )
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

// MARK: - Skill Management Tests

@Test(.timeLimit(.minutes(1)))
func skillYAMLRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [],
        skills: [
            WorkspaceSkillConfig(
                id: "deploy",
                name: "Deploy",
                description: "Deploy the application to production",
                instructions: "1. Run tests\n2. Build\n3. Push to target",
                allowedTools: ["Bash"],
                tags: ["ops"]
            ),
            WorkspaceSkillConfig(
                id: "code-review",
                name: "Code Review",
                description: "Review code for quality",
                instructions: "Check for: readability, correctness, tests"
            ),
        ]
    )

    let configPath = root.appendingPathComponent("workspace.yaml").path
    try WorkspaceYAMLCodec.saveWorkspace(workspace, to: configPath)
    let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: configPath)

    #expect(loaded.skills?.count == 2)
    let deploy = loaded.skills?.first(where: { $0.id == "deploy" })
    #expect(deploy?.name == "Deploy")
    #expect(deploy?.description == "Deploy the application to production")
    #expect(deploy?.instructions == "1. Run tests\n2. Build\n3. Push to target")
    #expect(deploy?.allowedTools == ["Bash"])
    #expect(deploy?.tags == ["ops"])

    let review = loaded.skills?.first(where: { $0.id == "code-review" })
    #expect(review?.name == "Code Review")
    #expect(review?.instructions == "Check for: readability, correctness, tests")
    #expect(review?.allowedTools == nil)
}

@Test(.timeLimit(.minutes(1)))
func skillServiceAssignmentYAMLRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-assign-rt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

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
                        id: "main",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["swift", "run"],
                        skills: ["deploy", "code-review"]
                    ),
                ]
            ),
        ],
        skills: [
            WorkspaceSkillConfig(id: "deploy", name: "Deploy", instructions: "Deploy steps"),
            WorkspaceSkillConfig(id: "code-review", name: "Code Review", instructions: "Review steps"),
        ]
    )

    let configPath = root.appendingPathComponent("workspace.yaml").path
    try WorkspaceYAMLCodec.saveWorkspace(workspace, to: configPath)
    let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: configPath)

    let service = loaded.repos.first?.services?.first
    #expect(service?.skills == ["deploy", "code-review"])
}

@Test(.timeLimit(.minutes(1)))
func skillAssignmentPreservesInResolveConfig() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-resolve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let agentRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: agentRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: agentRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

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
                        skills: ["deploy"]
                    ),
                ]
            ),
        ],
        skills: [
            WorkspaceSkillConfig(
                id: "deploy",
                name: "Deploy",
                description: "Deploy to production",
                instructions: "1. Run tests\n2. Build\n3. Deploy"
            ),
        ]
    )

    // Skills do not affect MCP connections — they are instruction packages
    let resolved = try WorkspaceSyncer.resolveConfig(workspaceRoot: root.path, workspace: workspace)
    let agentService = resolved.config.services.first(where: { $0.id.rawValue == "agent-a/app" })
    #expect(agentService != nil)

    // No MCP connections should be added by skills
    let mcpRefs = agentService?.connections.mcpServers.compactMap(\.serviceRef) ?? []
    #expect(mcpRefs.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func skillManagerCRUDOperations() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-crud-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let aibDir = root.appendingPathComponent(".aib")
    try FileManager.default.createDirectory(at: aibDir, withIntermediateDirectories: true)

    let agentRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: agentRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: agentRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

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
                        id: "main",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["swift", "run"]
                    ),
                ]
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    // List skills — initially empty
    let emptySkills = try AIBWorkspaceManager.listSkills(workspaceRoot: root.path)
    #expect(emptySkills.isEmpty)

    // Add a skill
    let skill = WorkspaceSkillConfig(
        id: "deploy",
        name: "Deploy",
        description: "Deploy to production",
        instructions: "Run tests, build, push"
    )
    try AIBWorkspaceManager.addSkill(workspaceRoot: root.path, skill: skill)

    let afterAdd = try AIBWorkspaceManager.listSkills(workspaceRoot: root.path)
    #expect(afterAdd.count == 1)
    #expect(afterAdd.first?.id == "deploy")
    #expect(afterAdd.first?.instructions == "Run tests, build, push")

    // Add duplicate — should throw
    #expect(throws: ConfigError.self) {
        try AIBWorkspaceManager.addSkill(workspaceRoot: root.path, skill: skill)
    }

    // Assign skill to service
    try AIBWorkspaceManager.assignSkill(workspaceRoot: root.path, skillID: "deploy", namespacedServiceID: "agent-a/main")

    let afterAssign = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: root.path)
    let serviceSkills = afterAssign.repos.first?.services?.first?.skills
    #expect(serviceSkills == ["deploy"])

    // Assign same skill again — idempotent, no error
    try AIBWorkspaceManager.assignSkill(workspaceRoot: root.path, skillID: "deploy", namespacedServiceID: "agent-a/main")
    let afterReAssign = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: root.path)
    #expect(afterReAssign.repos.first?.services?.first?.skills == ["deploy"])

    // Unassign skill
    try AIBWorkspaceManager.unassignSkill(workspaceRoot: root.path, skillID: "deploy", namespacedServiceID: "agent-a/main")
    let afterUnassign = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: root.path)
    #expect(afterUnassign.repos.first?.services?.first?.skills == nil)

    // Remove skill
    try AIBWorkspaceManager.removeSkill(workspaceRoot: root.path, skillID: "deploy")
    let afterRemove = try AIBWorkspaceManager.listSkills(workspaceRoot: root.path)
    #expect(afterRemove.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func removeSkillCascadesAssignments() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-cascade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let aibDir = root.appendingPathComponent(".aib")
    try FileManager.default.createDirectory(at: aibDir, withIntermediateDirectories: true)

    let agentRepo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: agentRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\nimport PackageDescription\n".write(to: agentRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

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
                        id: "main",
                        kind: "agent",
                        mountPath: "/agents/a",
                        run: ["swift", "run"],
                        skills: ["deploy", "code-review"]
                    ),
                    WorkspaceRepoServiceConfig(
                        id: "helper",
                        kind: "agent",
                        mountPath: "/agents/helper",
                        run: ["swift", "run"],
                        skills: ["deploy"]
                    ),
                ]
            ),
        ],
        skills: [
            WorkspaceSkillConfig(id: "deploy", name: "Deploy", instructions: "Deploy steps"),
            WorkspaceSkillConfig(id: "code-review", name: "Code Review", instructions: "Review steps"),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    // Remove deploy — should cascade to both services
    try AIBWorkspaceManager.removeSkill(workspaceRoot: root.path, skillID: "deploy")

    let afterRemove = try AIBWorkspaceManager.loadWorkspace(workspaceRoot: root.path)

    // Skill definition removed
    #expect(afterRemove.skills?.count == 1)
    #expect(afterRemove.skills?.first?.id == "code-review")

    // Assignments cascaded
    let mainService = afterRemove.repos.first?.services?.first(where: { $0.id == "main" })
    #expect(mainService?.skills == ["code-review"])

    let helperService = afterRemove.repos.first?.services?.first(where: { $0.id == "helper" })
    #expect(helperService?.skills == nil) // was only ["deploy"], now empty → nil
}

@Test(.timeLimit(.minutes(1)))
func skillSlugifyGeneratesCorrectIDs() throws {
    #expect(WorkspaceSkillConfig.slugify("Web Tools") == "web-tools")
    #expect(WorkspaceSkillConfig.slugify("DB / Query") == "db-query")
    #expect(WorkspaceSkillConfig.slugify("deploy") == "deploy")
    #expect(WorkspaceSkillConfig.slugify("Code Review!!!") == "code-review")
    #expect(WorkspaceSkillConfig.slugify("  Spaces  Around  ") == "spaces-around")
}

// MARK: - Skill Bundle Loader Tests

@Test(.timeLimit(.minutes(1)))
func skillBundleFrontmatterParsing() throws {
    let content = """
    ---
    name: deploy
    description: Deploy the application to production
    allowed-tools: Bash, Read
    tags: [ops, deploy]
    ---

    When deploying:
    1. Run tests
    2. Build
    3. Push
    """

    let (frontmatter, body) = SkillBundleLoader.parseFrontmatter(content)
    #expect(frontmatter != nil)
    #expect(frontmatter?.contains("name: deploy") == true)
    #expect(body.contains("When deploying:"))
    #expect(body.contains("1. Run tests"))
}

@Test(.timeLimit(.minutes(1)))
func skillBundleFrontmatterMissing() throws {
    let content = "Just plain instructions\nNo frontmatter"

    let (frontmatter, body) = SkillBundleLoader.parseFrontmatter(content)
    #expect(frontmatter == nil)
    #expect(body == content)
}

@Test(.timeLimit(.minutes(1)))
func skillBundleRoundTrip() throws {
    let skill = WorkspaceSkillConfig(
        id: "deploy",
        name: "Deploy",
        description: "Deploy to production",
        instructions: "1. Run tests\n2. Build\n3. Push",
        allowedTools: ["Bash", "Read"],
        tags: ["ops"]
    )

    let rendered = SkillBundleLoader.renderSkillMD(skill)
    #expect(rendered.contains("---"))
    #expect(rendered.contains("name: Deploy"))
    #expect(rendered.contains("description: Deploy to production"))
    #expect(rendered.contains("allowed-tools: Bash, Read"))
    #expect(rendered.contains("tags: [ops]"))
    #expect(rendered.contains("1. Run tests"))

    // Parse it back
    let (frontmatter, body) = SkillBundleLoader.parseFrontmatter(rendered)
    #expect(frontmatter != nil)
    #expect(body.trimmingCharacters(in: .whitespacesAndNewlines).contains("1. Run tests"))
}

@Test(.timeLimit(.minutes(1)))
func skillBundleLoadFromFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-bundle-\(UUID().uuidString)", isDirectory: true)
    let skillDir = root.appendingPathComponent("deploy")
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let skillFile = skillDir.appendingPathComponent("SKILL.md")
    let content = """
    ---
    name: Deploy
    description: Deploy the application
    allowed-tools: Bash
    tags: [ops]
    ---

    Steps:
    1. Run tests
    2. Build artifacts
    3. Push to target
    """
    try content.write(to: skillFile, atomically: true, encoding: .utf8)

    let loaded = try SkillBundleLoader.loadSkill(at: skillFile, id: "deploy")
    #expect(loaded.id == "deploy")
    #expect(loaded.name == "Deploy")
    #expect(loaded.description == "Deploy the application")
    #expect(loaded.allowedTools == ["Bash"])
    #expect(loaded.tags == ["ops"])
    #expect(loaded.instructions?.contains("1. Run tests") == true)
}

@Test(.timeLimit(.minutes(1)))
func skillBundleCopyPreservesSupportingFilesAndConfigs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-skill-copy-\(UUID().uuidString)", isDirectory: true)
    let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
    let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let sourceSkillDir = SkillBundleLoader.skillURL(id: "deploy", rootURL: sourceRoot)
    try FileManager.default.createDirectory(at: sourceSkillDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceSkillDir.appendingPathComponent("agents"), withIntermediateDirectories: true)

    try """
    ---
    name: deploy
    description: Deploy the application
    tags:
    - ops
    ---

    Use scripts/deploy.sh.
    """.write(
        to: sourceSkillDir.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    try "#!/bin/sh\necho deploy\n".write(
        to: sourceSkillDir.appendingPathComponent("scripts/deploy.sh"),
        atomically: true,
        encoding: .utf8
    )
    try "{\"interface\":{\"display_name\":\"Deploy\"}}".write(
        to: sourceSkillDir.appendingPathComponent("agents/openai.yaml"),
        atomically: true,
        encoding: .utf8
    )

    try SkillBundleLoader.copySkill(id: "deploy", from: sourceRoot, to: destinationRoot)

    let copiedFiles = try SkillBundleLoader.bundleFiles(id: "deploy", rootURL: destinationRoot)
    let copiedPaths = Set(copiedFiles.map(\.relativePath))
    #expect(copiedPaths == Set(["SKILL.md", "agents/openai.yaml", "scripts/deploy.sh"]))

    let loaded = try SkillBundleLoader.loadSkill(id: "deploy", rootURL: destinationRoot)
    #expect(loaded.id == "deploy")
    #expect(loaded.name == "Deploy")
    #expect(loaded.tags == ["ops"])
}

@Test(.timeLimit(.minutes(1)))
func executionDirectoryInspectorFindsAgentArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-execution-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".claude/commands"),
        withIntermediateDirectories: true
    )
    try "Be precise.\n".write(
        to: root.appendingPathComponent("CLAUDE.md"),
        atomically: true,
        encoding: .utf8
    )
    try "explain\n".write(
        to: root.appendingPathComponent(".claude/commands/explain.md"),
        atomically: true,
        encoding: .utf8
    )

    let entries = try AIBExecutionDirectoryInspector.discoverEntries(at: root)
    let relativePaths = Set(entries.map(\.relativePath))
    #expect(relativePaths.contains(".claude"))
    #expect(relativePaths.contains(".claude/commands"))
    #expect(relativePaths.contains(".claude/commands/explain.md"))
    #expect(relativePaths.contains("CLAUDE.md"))

    let markers = AIBExecutionDirectoryInspector.topLevelMarkers(for: entries)
    #expect(markers == [".claude", "CLAUDE.md"])
}

@Test(.timeLimit(.minutes(1)))
func deployPlanProjectsAssignedSkillBundlesIntoRuntimeDirectories() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-deploy-skills-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // Best-effort cleanup for temp test directory.
        }
    }

    let repo = root.appendingPathComponent("agent-a", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "agent-a",
        targets: [.executableTarget(name: "agent-a")]
    )
    """.write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "FROM swift:6.2-jammy\nWORKDIR /app\n".write(
        to: repo.appendingPathComponent("Dockerfile"),
        atomically: true,
        encoding: .utf8
    )

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
                        skills: ["deploy"]
                    ),
                ]
            ),
        ],
        skills: [
            WorkspaceSkillConfig(
                id: "deploy",
                name: "Deploy",
                description: "Deploy the application",
                instructions: "Use scripts/deploy.sh."
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    let workspaceSkillsRoot = SkillBundleLoader.workspaceSkillsRootURL(workspaceRoot: root.path)
    let skillDir = SkillBundleLoader.skillURL(id: "deploy", rootURL: workspaceSkillsRoot)
    try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("agents"), withIntermediateDirectories: true)
    try """
    ---
    name: deploy
    description: Deploy the application
    ---

    Use scripts/deploy.sh.
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho deploy\n".write(
        to: skillDir.appendingPathComponent("scripts/deploy.sh"),
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".claude/commands"),
        withIntermediateDirectories: true
    )
    try "{\"interface\":{\"display_name\":\"Deploy\"}}".write(
        to: skillDir.appendingPathComponent("agents/openai.yaml"),
        atomically: true,
        encoding: .utf8
    )
    try "Use local tools carefully.\n".write(
        to: repo.appendingPathComponent("CLAUDE.md"),
        atomically: true,
        encoding: .utf8
    )
    try "deploy docs\n".write(
        to: repo.appendingPathComponent(".claude/commands/deploy.md"),
        atomically: true,
        encoding: .utf8
    )

    let provider = MockDeploymentProvider()
    let targetConfig = AIBDeployTargetConfig(providerID: provider.providerID, region: "us-central1")
    let plan = try await AIBDeployService.generatePlan(
        workspaceRoot: root.path,
        targetConfig: targetConfig,
        provider: provider
    )

    #expect(plan.services.count == 1)
    let service = try #require(plan.services.first)
    let skillPaths = Set(service.artifacts.skillConfigs.map(\.relativePath))
    let executionPaths = Set(service.artifacts.executionDirectoryConfigs.map(\.relativePath))
    #expect(skillPaths.contains("__aib_deploy/claude/skills/deploy/SKILL.md"))
    #expect(skillPaths.contains("__aib_deploy/claude/skills/deploy/scripts/deploy.sh"))
    #expect(skillPaths.contains("__aib_deploy/agents/skills/deploy/agents/openai.yaml"))
    #expect(skillPaths.contains("__aib_deploy/skills/deploy/SKILL.md"))
    #expect(executionPaths.contains("__aib_deploy/claude/commands/deploy.md"))
    #expect(executionPaths.contains("__aib_deploy/root/CLAUDE.md"))

    try AIBDeployService.writeArtifacts(plan: plan, workspaceRoot: root.path)

    let stagedSkillFile = root
        .appendingPathComponent(".aib")
        .appendingPathComponent("generated")
        .appendingPathComponent("deploy")
        .appendingPathComponent("services")
        .appendingPathComponent(service.deployedServiceName)
        .appendingPathComponent("skills")
        .appendingPathComponent("__aib_deploy")
        .appendingPathComponent("claude")
        .appendingPathComponent("skills")
        .appendingPathComponent("deploy")
        .appendingPathComponent("scripts")
        .appendingPathComponent("deploy.sh")
    #expect(FileManager.default.fileExists(atPath: stagedSkillFile.path))

    let stagedExecutionFile = root
        .appendingPathComponent(".aib")
        .appendingPathComponent("generated")
        .appendingPathComponent("deploy")
        .appendingPathComponent("services")
        .appendingPathComponent(service.deployedServiceName)
        .appendingPathComponent("execution-directory")
        .appendingPathComponent("__aib_deploy")
        .appendingPathComponent("claude")
        .appendingPathComponent("commands")
        .appendingPathComponent("deploy.md")
    #expect(FileManager.default.fileExists(atPath: stagedExecutionFile.path))
}
