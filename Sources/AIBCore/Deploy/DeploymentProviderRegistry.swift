import Foundation

/// Registry of available deployment providers.
/// Follows the same pattern as `RuntimeAdapterRegistry`.
public enum DeploymentProviderRegistry {

    public static let providers: [any DeploymentProvider] = [
        GCPCloudRunProvider(),
    ]

    /// Look up a provider by its identifier.
    public static func provider(for id: String) -> (any DeploymentProvider)? {
        providers.first(where: { $0.providerID == id })
    }

    /// The default deployment provider.
    public static var `default`: any DeploymentProvider {
        providers[0]
    }

    /// Auto-detect the deployment provider from `.aib/targets/` directory.
    /// Scans for `{providerID}.yaml` files and returns the first matching provider.
    /// Falls back to the default provider if none is found.
    ///
    /// - Throws: Propagates unexpected filesystem errors (permissions, I/O).
    ///   "Directory not found" is expected when no targets are configured and returns the default.
    public static func detect(workspaceRoot: String) throws -> any DeploymentProvider {
        let targetsDir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".aib/targets")

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: targetsDir.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Self.default
        }

        for file in contents where file.hasSuffix(".yaml") || file.hasSuffix(".yml") {
            let providerID = file
                .replacingOccurrences(of: ".yaml", with: "")
                .replacingOccurrences(of: ".yml", with: "")
            if let provider = Self.provider(for: providerID) {
                return provider
            }
        }
        return Self.default
    }
}
