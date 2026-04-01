import AIBCore
import AIBRuntimeCore
import Foundation
import Testing
@testable import AIBWorkspace

@Test(.timeLimit(.minutes(1)))
func workspaceSyncReportsPrivateGitRequirementWithLocalCredential() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-source-auth-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
        }
    }

    let repo = root.appendingPathComponent("valuemap-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {
      "name": "valuemap-mcp",
      "packageManager": "pnpm@10.8.0",
      "dependencies": {
        "valuemap-api": "github:salescore-inc/valuemap-api"
      },
      "scripts": { "dev": "tsx watch src/index.ts" }
    }
    """.write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "valuemap-mcp",
                path: "valuemap-mcp",
                runtime: .node,
                framework: .hono,
                packageManager: .pnpm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "main",
                        kind: "mcp",
                        mountPath: "/valuemap-mcp",
                        run: ["pnpm", "dev"],
                        watchMode: "internal"
                    ),
                ]
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    let store = DefaultDeployTargetConfigStore()
    try store.save(workspaceRoot: root.path, config: AIBDeployTargetConfig(
        providerID: "local",
        region: "local",
        defaultAuth: .private,
        buildMode: .strict,
        sourceCredentials: [
            AIBSourceCredential(
                type: .ssh,
                host: "github.com",
                localPrivateKeyPath: "/tmp/id_ed25519",
                localKnownHostsPath: "/tmp/known_hosts"
            ),
        ]
    ))

    let result = try AIBWorkspaceManager.syncWorkspace(workspaceRoot: root.path)

    #expect(result.sourceAuthRequirements.count == 1)
    let requirement = try #require(result.sourceAuthRequirements.first)
    #expect(requirement.serviceIDs == ["valuemap-mcp/main"])
    #expect(requirement.host == "github.com")
    #expect(requirement.hasLocalCredential)
    #expect(!requirement.hasCloudCredential)
    #expect(
        requirement.suggestedPrivateKeySecretName == AIBSourceCredentialNaming.suggestedPrivateKeySecretName(
            workspaceRoot: root.path,
            host: "github.com"
        )
    )
    #expect(result.warnings.contains(where: { $0.contains("Cloud Run source auth is not configured yet") }))
}

@Test(.timeLimit(.minutes(1)))
func workspaceSyncMarksCloudCredentialAsSatisfied() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aib-source-auth-satisfied-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
        }
    }

    let repo = root.appendingPathComponent("valuemap-mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try """
    {
      "name": "valuemap-mcp",
      "packageManager": "pnpm@10.8.0",
      "dependencies": {
        "valuemap-api": "github:salescore-inc/valuemap-api"
      },
      "scripts": { "dev": "tsx watch src/index.ts" }
    }
    """.write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let workspace = AIBWorkspaceConfig(
        workspaceName: "test",
        repos: [
            WorkspaceRepo(
                name: "valuemap-mcp",
                path: "valuemap-mcp",
                runtime: .node,
                framework: .hono,
                packageManager: .pnpm,
                status: .discoverable,
                detectionConfidence: .high,
                services: [
                    WorkspaceRepoServiceConfig(
                        id: "main",
                        kind: "mcp",
                        mountPath: "/valuemap-mcp",
                        run: ["pnpm", "dev"],
                        watchMode: "internal"
                    ),
                ]
            ),
        ]
    )
    try AIBWorkspaceManager.saveWorkspace(workspace, workspaceRoot: root.path)

    let store = DefaultDeployTargetConfigStore()
    try store.save(workspaceRoot: root.path, config: AIBDeployTargetConfig(
        providerID: "gcp-cloudrun",
        region: "us-central1",
        defaultAuth: .private,
        buildMode: .strict,
        sourceCredentials: [
            AIBSourceCredential(
                type: .ssh,
                host: "github.com",
                cloudPrivateKeySecret: "github-private-key",
                cloudKnownHostsSecret: "github-known-hosts"
            ),
        ]
    ))

    let result = try AIBWorkspaceManager.syncWorkspace(workspaceRoot: root.path)

    #expect(result.sourceAuthRequirements.count == 1)
    let requirement = try #require(result.sourceAuthRequirements.first)
    #expect(requirement.hasCloudCredential)
    #expect(!result.warnings.contains(where: { $0.contains("Cloud Run source auth is not configured yet") }))
}
