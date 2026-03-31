import CryptoKit
import Foundation

public enum AIBLocalSourceAuthEnvironmentResolver {
    public static func appManagedPassphraseEnvironmentKey(
        workspaceRoot: String,
        providerID: String,
        host: String,
        privateKeyPath: String
    ) -> String {
        let material = [
            workspaceRoot,
            providerID,
            host.lowercased(),
            privateKeyPath,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        let suffix = digest.prefix(16).map { String(format: "%02X", $0) }.joined()
        return "AIB_SOURCE_AUTH_PASSPHRASE_\(suffix)"
    }

    public static func appManagedAccessTokenEnvironmentKey(
        workspaceRoot: String,
        providerID: String,
        host: String
    ) -> String {
        let material = [
            workspaceRoot,
            providerID,
            host.lowercased(),
            "github-token",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        let suffix = digest.prefix(16).map { String(format: "%02X", $0) }.joined()
        return "AIB_SOURCE_AUTH_TOKEN_\(suffix)"
    }

    public static func resolvedSourceAuthEnvironment(
        targetConfig: AIBDeployTargetConfig,
        secretLookup: (String) throws -> String?
    ) throws -> [String: String] {
        var environment: [String: String] = [:]
        for credential in targetConfig.sourceCredentials {
            let environmentKeys = [
                credential.localPrivateKeyPassphraseEnv,
                credential.localAccessTokenEnv,
            ]

            for candidate in environmentKeys {
                guard let environmentKey = candidate?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !environmentKey.isEmpty
                else {
                    continue
                }
                guard let secret = try secretLookup(environmentKey),
                      !secret.isEmpty
                else {
                    continue
                }
                environment[environmentKey] = secret
            }
        }
        return environment
    }
}
