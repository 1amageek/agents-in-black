import Foundation

/// A shell command to be executed during deployment.
/// Returned by `DeploymentProvider` to abstract provider-specific CLI tools.
public struct DeployCommand: Sendable {
    /// Human-readable label for progress display (e.g., "Building container")
    public var label: String

    /// Shell arguments (e.g., ["docker", "build", "-t", ...])
    public var arguments: [String]

    /// Step identifier for progress tracking (e.g., "dockerBuild", "serviceDeploy")
    public var stepID: String

    public init(label: String, arguments: [String], stepID: String) {
        self.label = label
        self.arguments = arguments
        self.stepID = stepID
    }
}
