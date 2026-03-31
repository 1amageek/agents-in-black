import AIBRuntimeCore
import AIBWorkspace
import Foundation

/// Reads and writes `.aib/targets/{providerID}.yaml`.
/// Separated from `AIBDeployService` so the App layer can persist cloud settings
/// without depending on the full deploy pipeline.
public protocol DeployTargetConfigStore: Sendable {
    func load(workspaceRoot: String, providerID: String) throws -> AIBDeployTargetConfig
    func save(workspaceRoot: String, config: AIBDeployTargetConfig) throws
    func isConfigured(workspaceRoot: String, providerID: String, provider: any DeploymentProvider) -> Bool
}

/// Default implementation that delegates load to `AIBDeployService` and writes YAML back.
public struct DefaultDeployTargetConfigStore: DeployTargetConfigStore, Sendable {

    public init() {}

    public func load(workspaceRoot: String, providerID: String) throws -> AIBDeployTargetConfig {
        try AIBDeployService.loadTargetConfig(workspaceRoot: workspaceRoot, providerID: providerID)
    }

    public func save(workspaceRoot: String, config: AIBDeployTargetConfig) throws {
        let targetsDir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".aib/targets")
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetsDir.path) {
            try fm.createDirectory(at: targetsDir, withIntermediateDirectories: true)
        }

        let filePath = targetsDir.appendingPathComponent("\(config.providerID).yaml")

        var root: [String: Any] = [
            "version": 1,
            "target": config.providerID,
            "buildMode": config.buildMode.rawValue,
            "defaults": [
                "auth": config.defaultAuth.rawValue,
                "region": config.region,
            ],
        ]

        for key in config.providerConfig.keys.sorted() {
            if key != "region" && key != "auth", let value = config.providerConfig[key] {
                root[key] = value
            }
        }

        if !config.sourceCredentials.isEmpty {
            root["sourceCredentials"] = config.sourceCredentials.map { credential in
                var item: [String: Any] = [
                    "type": credential.type.rawValue,
                    "host": credential.host,
                ]
                if let localPrivateKeyPath = credential.localPrivateKeyPath, !localPrivateKeyPath.isEmpty {
                    item["localPrivateKeyPath"] = localPrivateKeyPath
                }
                if let localKnownHostsPath = credential.localKnownHostsPath, !localKnownHostsPath.isEmpty {
                    item["localKnownHostsPath"] = localKnownHostsPath
                }
                if let localPrivateKeyPassphraseEnv = credential.localPrivateKeyPassphraseEnv,
                   !localPrivateKeyPassphraseEnv.isEmpty
                {
                    item["localPrivateKeyPassphraseEnv"] = localPrivateKeyPassphraseEnv
                }
                if let localAccessTokenEnv = credential.localAccessTokenEnv,
                   !localAccessTokenEnv.isEmpty
                {
                    item["localAccessTokenEnv"] = localAccessTokenEnv
                }
                if let cloudPrivateKeySecret = credential.cloudPrivateKeySecret, !cloudPrivateKeySecret.isEmpty {
                    item["cloudPrivateKeySecret"] = cloudPrivateKeySecret
                }
                if let cloudKnownHostsSecret = credential.cloudKnownHostsSecret, !cloudKnownHostsSecret.isEmpty {
                    item["cloudKnownHostsSecret"] = cloudKnownHostsSecret
                }
                return item
            }
        }

        if let convenience = config.convenience {
            root["convenience"] = [
                "useHostCorepackCache": convenience.useHostCorepackCache,
                "useHostPNPMStore": convenience.useHostPNPMStore,
                "useRepoLocalPNPMStore": convenience.useRepoLocalPNPMStore,
            ]
        }

        if var defaults = root["defaults"] as? [String: Any] {
            let kindEntries: [(yamlKey: String, kind: AIBServiceKind)] = [
                ("agent", .agent), ("mcp", .mcp), ("other", .unknown),
            ]
            for (yamlKey, kind) in kindEntries {
                guard let override = config.kindDefaults[kind] else { continue }
                let baseline = AIBDeployResourceConfig.defaults(for: kind)
                guard override != baseline else { continue }
                defaults[yamlKey] = [
                    "memory": override.memory,
                    "cpu": override.cpu,
                    "max_instances": override.maxInstances,
                    "min_instances": override.minInstances,
                    "concurrency": override.concurrency,
                    "timeout": override.timeout,
                ]
            }
            root["defaults"] = defaults
        }

        let yamlString = YAMLUtility.emitYAML(root) + "\n"
        try yamlString.write(to: filePath, atomically: true, encoding: .utf8)
    }

    public func isConfigured(
        workspaceRoot: String,
        providerID: String,
        provider: any DeploymentProvider
    ) -> Bool {
        do {
            let config = try load(workspaceRoot: workspaceRoot, providerID: providerID)
            try provider.validateTargetConfig(config)
            return true
        } catch {
            return false
        }
    }
}
