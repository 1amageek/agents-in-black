import AIBRuntimeCore
import Testing
@testable import AIBCore

@Test(.timeLimit(.minutes(1)))
func cloudSourceAuthBootstrapMergePreservesLocalFieldsAndExistingCloudNames() {
    let localCredential = AIBSourceCredential(
        type: .ssh,
        host: "github.com",
        localPrivateKeyPath: "/tmp/id_ed25519",
        localKnownHostsPath: "/tmp/known_hosts",
        localPrivateKeyPassphraseEnv: "AIB_GITHUB_KEY_PASSPHRASE"
    )
    let existingCloudCredential = AIBSourceCredential(
        type: .ssh,
        host: "github.com",
        cloudPrivateKeySecret: "github-private-key",
        cloudKnownHostsSecret: "github-known-hosts"
    )

    let merged = CloudSourceAuthBootstrapService.mergeCloudCredential(
        host: "github.com",
        localCredential: localCredential,
        existingCloudCredential: existingCloudCredential,
        privateKeySecretName: "github-private-key",
        knownHostsSecretName: "github-known-hosts"
    )

    #expect(merged.host == "github.com")
    #expect(merged.localPrivateKeyPath == "/tmp/id_ed25519")
    #expect(merged.localKnownHostsPath == "/tmp/known_hosts")
    #expect(merged.localPrivateKeyPassphraseEnv == "AIB_GITHUB_KEY_PASSPHRASE")
    #expect(merged.cloudPrivateKeySecret == "github-private-key")
    #expect(merged.cloudKnownHostsSecret == "github-known-hosts")
}

@Test(.timeLimit(.minutes(1)))
func cloudSourceAuthBootstrapMergeUsesProvisionedSecretNamesWhenCloudCredentialMissing() {
    let localCredential = AIBSourceCredential(
        type: .ssh,
        host: "github.com",
        localPrivateKeyPath: "/tmp/id_ed25519"
    )

    let merged = CloudSourceAuthBootstrapService.mergeCloudCredential(
        host: "github.com",
        localCredential: localCredential,
        existingCloudCredential: nil,
        privateKeySecretName: "aib-example-github-com-ssh-key",
        knownHostsSecretName: "aib-example-github-com-known-hosts"
    )

    #expect(merged.localPrivateKeyPath == "/tmp/id_ed25519")
    #expect(merged.cloudPrivateKeySecret == "aib-example-github-com-ssh-key")
    #expect(merged.cloudKnownHostsSecret == "aib-example-github-com-known-hosts")
}
