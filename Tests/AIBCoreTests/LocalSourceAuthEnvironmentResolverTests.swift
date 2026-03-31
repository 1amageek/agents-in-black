import AIBCore
import AIBRuntimeCore
import Foundation
import Testing

@Test(.timeLimit(.minutes(1)))
func appManagedPassphraseEnvironmentKeyIsStable() {
    let first = AIBLocalSourceAuthEnvironmentResolver.appManagedPassphraseEnvironmentKey(
        workspaceRoot: "/tmp/workspace",
        providerID: "local",
        host: "GitHub.com",
        privateKeyPath: "/Users/example/.ssh/id_ed25519"
    )
    let second = AIBLocalSourceAuthEnvironmentResolver.appManagedPassphraseEnvironmentKey(
        workspaceRoot: "/tmp/workspace",
        providerID: "local",
        host: "github.com",
        privateKeyPath: "/Users/example/.ssh/id_ed25519"
    )

    #expect(first == second)
    #expect(first.hasPrefix("AIB_SOURCE_AUTH_PASSPHRASE_"))
}

@Test(.timeLimit(.minutes(1)))
func resolvedSourceAuthEnvironmentIncludesOnlyAvailableSecrets() throws {
    let targetConfig = AIBDeployTargetConfig(
        providerID: "local",
        region: "local",
        sourceCredentials: [
            AIBSourceCredential(
                type: .ssh,
                host: "github.com",
                localPrivateKeyPath: "/Users/example/.ssh/id_ed25519",
                localPrivateKeyPassphraseEnv: "AIB_SOURCE_AUTH_PASSPHRASE_TEST"
            ),
            AIBSourceCredential(
                type: .ssh,
                host: "gitlab.com",
                localPrivateKeyPath: "/Users/example/.ssh/id_gitlab",
                localPrivateKeyPassphraseEnv: "AIB_SOURCE_AUTH_PASSPHRASE_MISSING"
            ),
            AIBSourceCredential(
                type: .githubToken,
                host: "github.com",
                localAccessTokenEnv: "AIB_SOURCE_AUTH_TOKEN_TEST"
            ),
        ]
    )

    let environment = try AIBLocalSourceAuthEnvironmentResolver.resolvedSourceAuthEnvironment(
        targetConfig: targetConfig
    ) { key in
        if key == "AIB_SOURCE_AUTH_PASSPHRASE_TEST" {
            return "top-secret"
        }
        if key == "AIB_SOURCE_AUTH_TOKEN_TEST" {
            return "ghp_test_token"
        }
        return nil
    }

    #expect(environment == [
        "AIB_SOURCE_AUTH_PASSPHRASE_TEST": "top-secret",
        "AIB_SOURCE_AUTH_TOKEN_TEST": "ghp_test_token",
    ])
}

@Test(.timeLimit(.minutes(1)))
func resolvedSourceAuthEnvironmentPreservesWhitespaceInSecrets() throws {
    let targetConfig = AIBDeployTargetConfig(
        providerID: "local",
        region: "local",
        sourceCredentials: [
            AIBSourceCredential(
                type: .ssh,
                host: "github.com",
                localPrivateKeyPath: "/Users/example/.ssh/id_ed25519",
                localPrivateKeyPassphraseEnv: "AIB_SOURCE_AUTH_PASSPHRASE_TEST"
            ),
        ]
    )

    let environment = try AIBLocalSourceAuthEnvironmentResolver.resolvedSourceAuthEnvironment(
        targetConfig: targetConfig
    ) { _ in
        "  top-secret  "
    }

    #expect(environment == ["AIB_SOURCE_AUTH_PASSPHRASE_TEST": "  top-secret  "])
}
