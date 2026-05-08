import Foundation
import Testing
@testable import AIBCore

/// Locks in the env-flag contract for `gcloud run deploy`. AIB previously used
/// `--update-env-vars`, which is *additive* on Cloud Run — keys removed from
/// workspace.yaml stayed on the deployed service forever (which is how
/// FIRESTORE_EMULATOR_HOST kept leaking even after the workspace was cleaned).
/// The deploy must apply env *authoritatively*: `--set-env-vars` when there is
/// at least one var, `--clear-env-vars` when the set is empty.
@Suite("GCPCloudRunProvider — deploy env flag is authoritative, never additive")
struct GCPCloudRunProviderDeployCommandTests {

    @Test("Non-empty envVars uses --set-env-vars (replaces, not merges)")
    func nonEmptyEnvUsesSetEnvVars() {
        let provider = GCPCloudRunProvider()
        let plan = makePlan(envVars: ["GCLOUD_PROJECT": "vi-dev"])
        let target = makeTarget()

        let commands = provider.deployCommands(service: plan, imageTag: "img:latest", targetConfig: target)
        let args = try! #require(commands.first).arguments

        #expect(args.contains("--set-env-vars"))
        #expect(!args.contains("--update-env-vars"))
        #expect(!args.contains("--clear-env-vars"))
    }

    @Test("Empty envVars uses --clear-env-vars to wipe leaked keys from prior deploys")
    func emptyEnvUsesClearEnvVars() {
        let provider = GCPCloudRunProvider()
        let plan = makePlan(envVars: [:])
        let target = makeTarget()

        let commands = provider.deployCommands(service: plan, imageTag: "img:latest", targetConfig: target)
        let args = try! #require(commands.first).arguments

        #expect(args.contains("--clear-env-vars"))
        #expect(!args.contains("--set-env-vars"))
        #expect(!args.contains("--update-env-vars"))
    }

    @Test("Secrets are merged into the same authoritative --set-env-vars batch")
    func secretsMergedIntoSetEnvVars() {
        let provider = GCPCloudRunProvider()
        let plan = makePlan(envVars: ["GCLOUD_PROJECT": "vi-dev"])
        let target = makeTarget()
        let secrets = ["INTERNAL_SIGNING_SECRET": "s3cret"]

        let commands = provider.deployCommands(
            service: plan,
            imageTag: "img:latest",
            targetConfig: target,
            secrets: secrets
        )
        let args = try! #require(commands.first).arguments
        let envIndex = try! #require(args.firstIndex(of: "--set-env-vars"))
        let envValue = args[envIndex + 1]

        #expect(envValue.contains("GCLOUD_PROJECT=vi-dev"))
        #expect(envValue.contains("INTERNAL_SIGNING_SECRET=s3cret"))
    }

    // MARK: - Helpers

    private func makePlan(envVars: [String: String]) -> AIBDeployServicePlan {
        AIBDeployServicePlan(
            id: "svc",
            serviceKind: .mcp,
            runtime: "node",
            repoPath: "svc",
            deployedServiceName: "svc",
            region: "asia-northeast1",
            artifacts: AIBDeployArtifactSet(
                dockerfile: AIBDeployArtifact(relativePath: "Dockerfile", content: "", source: .generated),
                deployConfig: AIBDeployArtifact(relativePath: "clouddeploy.yaml", content: "", source: .generated)
            ),
            envVars: envVars,
            isPublic: true
        )
    }

    private func makeTarget() -> AIBDeployTargetConfig {
        AIBDeployTargetConfig(
            providerID: "gcp-cloudrun",
            region: "asia-northeast1",
            providerConfig: ["gcpProject": "vi-dev"]
        )
    }
}
