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

        var lines: [String] = []
        lines.append("version: 1")
        lines.append("target: \(config.providerID)")

        // Provider-specific top-level keys (e.g., gcpProject, artifactRegistryHost)
        for key in config.providerConfig.keys.sorted() {
            if key != "region" && key != "auth" {
                lines.append("\(key): \(config.providerConfig[key]!)")
            }
        }

        lines.append("defaults:")
        lines.append("  auth: \(config.defaultAuth.rawValue)")
        lines.append("  region: \(config.region)")

        // Per-kind resource overrides (only include kinds that differ from smart defaults)
        let kindEntries: [(yamlKey: String, kind: AIBServiceKind)] = [
            ("agent", .agent), ("mcp", .mcp), ("other", .unknown),
        ]
        for (yamlKey, kind) in kindEntries {
            guard let override = config.kindDefaults[kind] else { continue }
            let baseline = AIBDeployResourceConfig.defaults(for: kind)
            guard override != baseline else { continue }
            lines.append("  \(yamlKey):")
            lines.append("    memory: \(override.memory)")
            lines.append("    cpu: \(override.cpu)")
            lines.append("    max_instances: \(override.maxInstances)")
            lines.append("    min_instances: \(override.minInstances)")
            lines.append("    concurrency: \(override.concurrency)")
            lines.append("    timeout: \(override.timeout)")
        }

        let yamlString = lines.joined(separator: "\n") + "\n"
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
