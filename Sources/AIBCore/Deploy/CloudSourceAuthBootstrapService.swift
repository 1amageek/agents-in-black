import AIBRuntimeCore
import Foundation

public protocol CloudSourceCredentialProvisioning: Sendable {
    func provisionFromLocalSSH(
        request: CloudSourceCredentialProvisioningService.Request
    ) async throws -> CloudSourceCredentialProvisioningService.Result
}

extension CloudSourceCredentialProvisioningService: CloudSourceCredentialProvisioning {}

public struct CloudSourceAuthBootstrapService: Sendable {
    public struct Result: Sendable {
        public var privateKeySecretName: String
        public var knownHostsSecretName: String?
        public var createdPrivateKeySecret: Bool
        public var createdKnownHostsSecret: Bool

        public init(
            privateKeySecretName: String,
            knownHostsSecretName: String?,
            createdPrivateKeySecret: Bool,
            createdKnownHostsSecret: Bool
        ) {
            self.privateKeySecretName = privateKeySecretName
            self.knownHostsSecretName = knownHostsSecretName
            self.createdPrivateKeySecret = createdPrivateKeySecret
            self.createdKnownHostsSecret = createdKnownHostsSecret
        }
    }

    private let configStore: any DeployTargetConfigStore
    private let provisioningService: any CloudSourceCredentialProvisioning

    public init(
        configStore: any DeployTargetConfigStore = DefaultDeployTargetConfigStore(),
        provisioningService: any CloudSourceCredentialProvisioning = CloudSourceCredentialProvisioningService()
    ) {
        self.configStore = configStore
        self.provisioningService = provisioningService
    }

    public func provisionGCPCloudRunSourceAuth(
        workspaceRoot: String,
        projectID: String,
        host: String,
        preferredPrivateKeySecretName: String? = nil,
        preferredKnownHostsSecretName: String? = nil,
        secretLookup: (String) throws -> String?
    ) async throws -> Result {
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectID.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Set a Google Cloud project before creating source auth secrets.")
        }
        guard !normalizedHost.isEmpty else {
            throw AIBDeployError(phase: "gcloud-secrets", message: "Set a source auth host before creating cloud source auth secrets.")
        }

        let localConfig = try configStore.load(workspaceRoot: workspaceRoot, providerID: "local")
        guard let localCredential = localConfig.sourceCredentials.first(where: {
            $0.type == .ssh && $0.host.caseInsensitiveCompare(normalizedHost) == .orderedSame
        }) else {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "No local SSH source credential for '\(normalizedHost)' was found in .aib/targets/local.yaml."
            )
        }

        guard let localPrivateKeyPath = localCredential.localPrivateKeyPath,
              !localPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIBDeployError(
                phase: "gcloud-secrets",
                message: "The local SSH source credential for '\(normalizedHost)' is missing localPrivateKeyPath."
            )
        }

        var cloudConfig = try configStore.load(workspaceRoot: workspaceRoot, providerID: "gcp-cloudrun")
        let existingCloudCredential = cloudConfig.sourceCredentials.first(where: {
            $0.type == .ssh && $0.host.caseInsensitiveCompare(normalizedHost) == .orderedSame
        })

        let resolvedEnvironment = try AIBLocalSourceAuthEnvironmentResolver.resolvedSourceAuthEnvironment(
            targetConfig: localConfig
        ) { environmentKey in
            if let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty {
                return value
            }
            return try secretLookup(environmentKey)
        }
        let passphrase = localCredential.localPrivateKeyPassphraseEnv.flatMap { resolvedEnvironment[$0] }

        let privateKeySecretName = normalizedSecretName(
            preferredPrivateKeySecretName
                ?? existingCloudCredential?.cloudPrivateKeySecret
                ?? AIBSourceCredentialNaming.suggestedPrivateKeySecretName(
                    workspaceRoot: workspaceRoot,
                    host: normalizedHost
                )
        )
        let knownHostsSecretName = normalizedOptionalSecretName(
            preferredKnownHostsSecretName
                ?? existingCloudCredential?.cloudKnownHostsSecret
                ?? AIBSourceCredentialNaming.suggestedKnownHostsSecretName(
                    workspaceRoot: workspaceRoot,
                    host: normalizedHost
                )
        )

        let provisioned = try await provisioningService.provisionFromLocalSSH(request: .init(
            projectID: normalizedProjectID,
            host: normalizedHost,
            localPrivateKeyPath: localPrivateKeyPath,
            localKnownHostsPath: localCredential.localKnownHostsPath,
            localPrivateKeyPassphrase: passphrase,
            privateKeySecretName: privateKeySecretName,
            knownHostsSecretName: knownHostsSecretName
        ))

        let mergedCredential = Self.mergeCloudCredential(
            host: normalizedHost,
            localCredential: localCredential,
            existingCloudCredential: existingCloudCredential,
            privateKeySecretName: provisioned.privateKeySecretName,
            knownHostsSecretName: provisioned.knownHostsSecretName
        )

        upsertSourceCredential(
            credential: mergedCredential,
            into: &cloudConfig.sourceCredentials
        )
        cloudConfig.providerConfig["gcpProject"] = normalizedProjectID
        try configStore.save(workspaceRoot: workspaceRoot, config: cloudConfig)

        return Result(
            privateKeySecretName: provisioned.privateKeySecretName,
            knownHostsSecretName: provisioned.knownHostsSecretName,
            createdPrivateKeySecret: provisioned.createdPrivateKeySecret,
            createdKnownHostsSecret: provisioned.createdKnownHostsSecret
        )
    }

    static func mergeCloudCredential(
        host: String,
        localCredential: AIBSourceCredential,
        existingCloudCredential: AIBSourceCredential?,
        privateKeySecretName: String,
        knownHostsSecretName: String?
    ) -> AIBSourceCredential {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existingCloudCredential

        let localPrivateKeyPath = firstNonEmpty(
            existing?.localPrivateKeyPath,
            localCredential.localPrivateKeyPath
        )
        let localKnownHostsPath = firstNonEmpty(
            existing?.localKnownHostsPath,
            localCredential.localKnownHostsPath
        )
        let localPrivateKeyPassphraseEnv = firstNonEmpty(
            existing?.localPrivateKeyPassphraseEnv,
            localCredential.localPrivateKeyPassphraseEnv
        )
        let localAccessTokenEnv = firstNonEmpty(
            existing?.localAccessTokenEnv,
            localCredential.localAccessTokenEnv
        )
        let cloudKnownHostsSecret = firstNonEmpty(
            existing?.cloudKnownHostsSecret,
            knownHostsSecretName
        )

        return AIBSourceCredential(
            type: .ssh,
            host: normalizedHost,
            localPrivateKeyPath: localPrivateKeyPath,
            localKnownHostsPath: localKnownHostsPath,
            localPrivateKeyPassphraseEnv: localPrivateKeyPassphraseEnv,
            localAccessTokenEnv: localAccessTokenEnv,
            cloudPrivateKeySecret: privateKeySecretName,
            cloudKnownHostsSecret: cloudKnownHostsSecret
        )
    }

    private func upsertSourceCredential(
        credential: AIBSourceCredential,
        into sourceCredentials: inout [AIBSourceCredential]
    ) {
        if let index = sourceCredentials.firstIndex(where: {
            $0.type == credential.type && $0.host.caseInsensitiveCompare(credential.host) == .orderedSame
        }) {
            sourceCredentials[index] = credential
        } else {
            sourceCredentials.append(credential)
        }
    }

    private func normalizedSecretName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptionalSecretName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for candidate in values {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return candidate
            }
        }
        return nil
    }
}
