import Foundation
import Yams

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

        // Build structured YAML content
        var doc: [String: Any] = [
            "version": 1,
            "target": config.providerID,
        ]

        var defaults: [String: Any] = [
            "region": config.region,
            "auth": config.defaultAuth.rawValue,
        ]

        // Resource defaults (only include non-default values)
        let baseline = AIBDeployTargetConfig(providerID: config.providerID, region: config.region)
        if config.defaultMemory != baseline.defaultMemory { defaults["memory"] = config.defaultMemory }
        if config.defaultCPU != baseline.defaultCPU { defaults["cpu"] = config.defaultCPU }
        if config.defaultMaxInstances != baseline.defaultMaxInstances { defaults["max_instances"] = config.defaultMaxInstances }
        if config.defaultConcurrency != baseline.defaultConcurrency { defaults["concurrency"] = config.defaultConcurrency }
        if config.defaultTimeout != baseline.defaultTimeout { defaults["timeout"] = config.defaultTimeout }

        doc["defaults"] = defaults

        // Provider-specific top-level keys (e.g., gcpProject, artifactRegistryHost)
        for (key, value) in config.providerConfig {
            if key != "region" && key != "auth" {
                doc[key] = value
            }
        }

        let yamlString = try Yams.dump(object: doc, sortKeys: true)
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
