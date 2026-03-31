import AIBCore
import Testing

@Test(.timeLimit(.minutes(1)))
func cloudSourceCredentialProvisioningSuggestedNamesAreSanitized() {
    let privateKeySecret = CloudSourceCredentialProvisioningService.suggestedPrivateKeySecretName(
        workspaceRoot: "/tmp/My Workspace",
        host: "github.com"
    )
    let knownHostsSecret = CloudSourceCredentialProvisioningService.suggestedKnownHostsSecretName(
        workspaceRoot: "/tmp/My Workspace",
        host: "github.com"
    )

    #expect(privateKeySecret == "aib-my-workspace-github-com-ssh-key")
    #expect(knownHostsSecret == "aib-my-workspace-github-com-known-hosts")
}
