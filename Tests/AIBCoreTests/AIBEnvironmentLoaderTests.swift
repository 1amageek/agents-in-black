import Foundation
import Testing
@testable import AIBCore

@Suite("AIBEnvironmentLoader — overlay parsing")
struct AIBEnvironmentLoaderTests {

    @Test("Returns nil when no environment name is requested")
    func nilNameReturnsNil() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let result = try AIBEnvironmentLoader.load(workspaceRoot: workspaceRoot, name: nil)
        #expect(result == nil)
    }

    @Test("Throws when environment file is missing")
    func missingFileThrows() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        #expect(throws: AIBEnvironmentLoaderError.self) {
            try AIBEnvironmentLoader.load(workspaceRoot: workspaceRoot, name: "missing")
        }
    }

    @Test("Parses target overrides and per-service env/secrets")
    func parsesOverlay() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let yaml = """
        version: 1
        name: staging
        target:
          gcpProject: salescore-ei-stg
          region: asia-northeast1
        services:
          storage-mcp/main:
            env:
              GCLOUD_PROJECT: salescore-ei-stg
              STORAGE_BUCKET: salescore-ei-stg.firebasestorage.app
            secrets:
              STORAGE_UPLOAD_SIGNING_SECRET:
                secret: storage-upload-signing-secret
                version: latest
          proposal-mcp/main:
            env:
              GCLOUD_PROJECT: salescore-ei-stg
        """
        try writeEnvironment(workspaceRoot: workspaceRoot, name: "staging", yaml: yaml)

        let config = try AIBEnvironmentLoader.load(workspaceRoot: workspaceRoot, name: "staging")
        let env = try #require(config)
        #expect(env.name == "staging")
        #expect(env.targetOverrides["gcpProject"] == "salescore-ei-stg")
        #expect(env.targetOverrides["region"] == "asia-northeast1")

        let storage = env.override(for: "storage-mcp/main")
        #expect(storage.env["GCLOUD_PROJECT"] == "salescore-ei-stg")
        #expect(storage.env["STORAGE_BUCKET"] == "salescore-ei-stg.firebasestorage.app")
        #expect(storage.secrets["STORAGE_UPLOAD_SIGNING_SECRET"]?.secret == "storage-upload-signing-secret")
        #expect(storage.secrets["STORAGE_UPLOAD_SIGNING_SECRET"]?.version == "latest")

        let proposal = env.override(for: "proposal-mcp/main")
        #expect(proposal.env["GCLOUD_PROJECT"] == "salescore-ei-stg")
        #expect(proposal.secrets.isEmpty)

        let absent = env.override(for: "unknown/service")
        #expect(absent.isEmpty)
    }

    @Test("Infers environment name from target GCP project")
    func infersEnvironmentNameFromTargetProject() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try writeEnvironment(workspaceRoot: workspaceRoot, name: "staging", yaml: """
        version: 1
        name: staging
        target:
          gcpProject: salescore-ei-stg
        services:
          proposal-mcp/main:
            env:
              GCLOUD_PROJECT: salescore-ei-stg
        """)

        let targetConfig = AIBDeployTargetConfig(
            providerID: "gcp-cloudrun",
            region: "asia-northeast1",
            providerConfig: ["gcpProject": "salescore-ei-stg"]
        )

        let inferred = try AIBDeployService.inferEnvironmentName(
            workspaceRoot: workspaceRoot,
            targetConfig: targetConfig
        )

        #expect(inferred == "staging")
    }

    @Test("Lists every shared environment file, including empty overlays")
    func listsEnvironmentOptionsIncludingEmptyOverlays() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        try writeTarget(workspaceRoot: workspaceRoot, providerID: "gcp-cloudrun", yaml: """
        version: 1
        target: gcp-cloudrun
        defaults:
          auth: public
          region: asia-northeast1
        gcpProject: base-project
        """)
        try writeEnvironment(workspaceRoot: workspaceRoot, name: "prod", yaml: """
        version: 1
        name: prod
        """)
        try writeEnvironment(workspaceRoot: workspaceRoot, name: "staging", yaml: """
        version: 1
        name: staging
        target:
          gcpProject: salescore-ei-stg
        """)

        let options = try AIBDeployService.listEnvironmentOptions(
            workspaceRoot: workspaceRoot,
            providerID: "gcp-cloudrun"
        )

        #expect(options.map(\.name) == ["prod", "staging"])
        #expect(options[0].targetProject == "base-project")
        #expect(options[0].region == "asia-northeast1")
        #expect(options[1].targetProject == "salescore-ei-stg")
        #expect(options[1].region == "asia-northeast1")
    }

    @Test("Missing secret name surfaces as a structural error")
    func secretWithoutNameThrows() throws {
        let workspaceRoot = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let yaml = """
        version: 1
        name: staging
        services:
          storage-mcp/main:
            secrets:
              FOO:
                version: latest
        """
        try writeEnvironment(workspaceRoot: workspaceRoot, name: "staging", yaml: yaml)

        #expect(throws: AIBEnvironmentLoaderError.self) {
            try AIBEnvironmentLoader.load(workspaceRoot: workspaceRoot, name: "staging")
        }
    }

    // MARK: - Helpers

    private func makeTempWorkspace() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aib-env-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeEnvironment(workspaceRoot: String, name: String, yaml: String) throws {
        let dir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".aib/environments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
    }

    private func writeTarget(workspaceRoot: String, providerID: String, yaml: String) throws {
        let dir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".aib/targets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(providerID).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
    }
}
