import Foundation
import Testing
@testable import AIBWorkspace

@Suite("workspace.yaml round-trip — secrets")
struct SecretsRoundTripTests {

    @Test("Loading then saving preserves a secret reference (with and without version)")
    func roundTripPreservesSecretRefs() throws {
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
                secrets:
                  ANTHROPIC_API_KEY:
                    secret: anthropic-api-key
                  STRIPE_SK:
                    secret: stripe-sk
                    version: "7"
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretsRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("workspace.yaml")
        try yaml.write(to: source, atomically: true, encoding: .utf8)

        let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: source.path)
        let svc = try #require(loaded.repos.first?.services?.first)
        let secrets = try #require(svc.secrets)
        #expect(secrets.count == 2)
        #expect(secrets["ANTHROPIC_API_KEY"]?.secret == "anthropic-api-key")
        // Absent version must round-trip as nil — the absence of `version` is
        // how the user expresses "track latest"; do not silently bake it in.
        #expect(secrets["ANTHROPIC_API_KEY"]?.version == nil)
        #expect(secrets["STRIPE_SK"]?.secret == "stripe-sk")
        #expect(secrets["STRIPE_SK"]?.version == "7")

        let target = dir.appendingPathComponent("written.yaml")
        try WorkspaceYAMLCodec.saveWorkspace(loaded, to: target.path)

        let reloaded = try WorkspaceYAMLCodec.loadWorkspace(at: target.path)
        let reloadedSvc = try #require(reloaded.repos.first?.services?.first)
        #expect(reloadedSvc.secrets == svc.secrets)
    }

    @Test("Empty / absent secrets are omitted from saved YAML to keep diffs minimal")
    func emptySecretsAreOmittedOnSave() throws {
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
            .appendingPathComponent("SecretsRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("workspace.yaml")
        try yaml.write(to: source, atomically: true, encoding: .utf8)

        let loaded = try WorkspaceYAMLCodec.loadWorkspace(at: source.path)
        let target = dir.appendingPathComponent("written.yaml")
        try WorkspaceYAMLCodec.saveWorkspace(loaded, to: target.path)

        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(!written.contains("secrets"))
    }
}
