import Foundation
import Testing
@testable import AIBWorkspace

@Suite("workspace.yaml round-trip — env / local_env / deploy_env")
struct EnvScopeYAMLRoundTripTests {

    @Test("Loading then saving preserves all three env scopes verbatim")
    func roundTripPreservesAllScopes() throws {
        let yaml = """
        version: 1
        workspace_name: test
        gateway:
          port: 9090
        repos:
          - name: proposal-mcp
            path: proposal-mcp
            runtime: node
            framework: hono
            package_manager: pnpm
            status: discoverable
            detection_confidence: medium
            command_candidates: []
            enabled: true
            services_namespace: proposal-mcp
            services:
              - id: main
                mount_path: /proposal-mcp
                run:
                  - pnpm
                  - dev
                env:
                  GCLOUD_PROJECT: vi-prod
                local_env:
                  FIRESTORE_EMULATOR_HOST: host.container.internal:8080
                deploy_env:
                  LOG_LEVEL: warn
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvScopeYAMLRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("workspace.yaml")
        try yaml.write(to: source, atomically: true, encoding: .utf8)

        let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: source.path)
        let svc = try #require(loaded.repos.first?.services?.first)
        #expect(svc.env == ["GCLOUD_PROJECT": "vi-prod"])
        #expect(svc.localEnv == ["FIRESTORE_EMULATOR_HOST": "host.container.internal:8080"])
        #expect(svc.deployEnv == ["LOG_LEVEL": "warn"])

        let target = dir.appendingPathComponent("written.yaml")
        try WorkspaceYAMLCodec.saveWorkspace(loaded, to: target.path)

        let reloaded = try WorkspaceYAMLCodec.loadWorkspace(at: target.path)
        let reloadedSvc = try #require(reloaded.repos.first?.services?.first)
        #expect(reloadedSvc.env == svc.env)
        #expect(reloadedSvc.localEnv == svc.localEnv)
        #expect(reloadedSvc.deployEnv == svc.deployEnv)
    }

    @Test("Empty local_env / deploy_env are omitted from saved YAML to keep diffs minimal")
    func emptyScopesAreOmittedOnSave() throws {
        let yaml = """
        version: 1
        workspace_name: test
        gateway:
          port: 9090
        repos:
          - name: simple
            path: simple
            runtime: node
            framework: hono
            package_manager: pnpm
            status: discoverable
            detection_confidence: medium
            command_candidates: []
            enabled: true
            services_namespace: simple
            services:
              - id: main
                mount_path: /simple
                run:
                  - pnpm
                  - dev
                env:
                  ONLY_KEY: value
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvScopeYAMLRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("workspace.yaml")
        try yaml.write(to: source, atomically: true, encoding: .utf8)

        let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: source.path)
        let target = dir.appendingPathComponent("written.yaml")
        try WorkspaceYAMLCodec.saveWorkspace(loaded, to: target.path)

        let written = try String(contentsOf: target, encoding: .utf8)
        // Empty local_env / deploy_env should not be emitted at all — otherwise
        // every workspace.yaml that doesn't use them gets noise on the next save.
        #expect(!written.contains("local_env"))
        #expect(!written.contains("deploy_env"))
    }
}
